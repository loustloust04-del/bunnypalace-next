import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// 附件一份存储：聊天附件落文件库（用户可见、Files 可达），SwiftData 只存 ref 路径。
/// filesystem/attachments/{convId前8}-{对话标题slug}/{文件名}
/// convId 前 8 是稳定锚（按前缀找目录），标题 slug 是可读糖。
enum AttachmentStore {
    static let folderName = "attachments"
    /// 图片压缩落盘开关（设置-文件库；默认关=存原图）
    static let compressImagesKey = "attachmentCompressImages"

    private static func prefix8(_ conversationId: String) -> String {
        String(conversationId.prefix(8))
    }

    /// 同 SummaryFileStore：保留中文，清洗文件系统危险字符，截 24 字
    private static func slugify(_ title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return "untitled" }
        var out = ""
        for ch in title {
            if "/\\:*?\"<>|#".contains(ch) || ch.isNewline || ch.isWhitespace { out.append("-") }
            else { out.append(ch) }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        if out.count > 24 { out = String(out.prefix(24)) }
        return out.isEmpty ? "untitled" : out
    }

    private static func sanitizeFileName(_ raw: String) -> String {
        let ext = (raw as NSString).pathExtension
        let base = (raw as NSString).deletingPathExtension
        let safeBase = slugify(base.isEmpty ? "附件" : base)
        let safeExt = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return safeExt.isEmpty ? safeBase : "\(safeBase).\(safeExt)"
    }

    private static func attachmentsRoot(profileId: String) -> URL {
        let dir = FileLibraryStore.libraryRoot(profileId: profileId)
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 对话附件目录名。已有同前缀目录优先复用（标题过时不丢内容），否则按当前标题生成。
    private static func conversationDirName(conversationId: String, conversationTitle: String?, profileId: String) -> String {
        let prefix = prefix8(conversationId) + "-"
        let root = attachmentsRoot(profileId: profileId)
        if let existing = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .first(where: { $0.hasPrefix(prefix) }) {
            return existing
        }
        return prefix + slugify(conversationTitle)
    }

    /// 落盘并返回 filesystem 相对路径（即 segment ref）。同名自动 -2/-3。
    static func save(
        fileName: String,
        data: Data,
        conversationId: String,
        conversationTitle: String?,
        profileId: String
    ) throws -> String {
        try MainThreadIO.tolerated("#033 附件外置落盘在主线程（发送 / setSegments）") {
            try saveUnchecked(fileName: fileName, data: data, conversationId: conversationId,
                              conversationTitle: conversationTitle, profileId: profileId)
        }
    }

    private static func saveUnchecked(
        fileName: String,
        data: Data,
        conversationId: String,
        conversationTitle: String?,
        profileId: String
    ) throws -> String {
        let dirName = conversationDirName(conversationId: conversationId, conversationTitle: conversationTitle, profileId: profileId)
        let safe = sanitizeFileName(fileName)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension

        var candidate = "\(folderName)/\(dirName)/\(safe)"
        var index = 2
        while FileLibraryStore.absoluteURL(candidate, profileId: profileId) != nil {
            // 同名同字节 → 复用（幂等：tool loop 每轮 setSegments 重复外置同一附件不产生副本）
            if (try? FileLibraryStore.readData(candidate, profileId: profileId)) == data {
                return candidate
            }
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = "\(folderName)/\(dirName)/\(name)"
            index += 1
        }
        try FileLibraryStore.writeData(candidate, data: data, profileId: profileId)
        return candidate
    }

    // MARK: - 外置化（setSegments 统一入口）

    /// 内联附件段 → 落盘 + ref 段。落盘失败保持内联（不丢数据）。幂等：重复调用同内容返回同 ref。
    static func externalize(
        _ segments: [MessageSegment],
        conversationId: String,
        conversationTitle: String?,
        profileId: String
    ) -> [MessageSegment] {
        guard !profileId.isEmpty, !conversationId.isEmpty else { return segments }
        return segments.map { seg in
            switch seg {
            case .image(let name, let type, let data):
                let processed = processImageForStorage(data: data, name: name)
                guard let path = try? save(
                    fileName: processed.name, data: processed.data,
                    conversationId: conversationId, conversationTitle: conversationTitle, profileId: profileId
                ) else { return seg }
                return .imageRef(name: processed.name, type: type, path: path)
            case .fileData(let name, let mime, let data):
                guard let path = try? save(
                    fileName: ensureExtension(name, fallback: "bin"), data: data,
                    conversationId: conversationId, conversationTitle: conversationTitle, profileId: profileId
                ) else { return seg }
                return .fileDataRef(name: name, mime: mime, path: path)
            default:
                return seg
            }
        }
    }

    // MARK: - 图片处理

    /// 补扩展名（图片按 magic bytes 嗅探）+ 可选压缩（>2048px 降采样 + JPEG 0.85）
    private static func processImageForStorage(data: Data, name: String) -> (data: Data, name: String) {
        let named = ensureExtension(name, fallback: sniffImageExtension(data) ?? "jpg")
        guard UserDefaults.standard.bool(forKey: compressImagesKey),
              let compressed = compressImage(data) else {
            return (data, named)
        }
        let base = (named as NSString).deletingPathExtension
        return (compressed, "\(base).jpg")
    }

    private static func ensureExtension(_ name: String, fallback: String) -> String {
        (name as NSString).pathExtension.isEmpty ? "\(name).\(fallback)" : name
    }

    private static func sniffImageExtension(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "heic" }
        return nil
    }

    private static func compressImage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func read(_ refPath: String, profileId: String) -> Data? {
        MainThreadIO.tolerated("#033 附件按需读盘在主线程（组 prompt 历史图 / 编辑恢复）") {
            try? FileLibraryStore.readData(refPath, profileId: profileId)
        }
    }

    /// 复制对话时整体复制附件目录（源目录不存在/目标已存在则返回 nil，ref 保持指向旧目录仍可显示）。
    /// 返回 (旧目录名, 新目录名) 供 segmentsData ref 重写。
    static func copyConversationAttachments(
        from oldConversationId: String,
        to newConversationId: String,
        newTitle: String?,
        profileId: String
    ) -> (oldDir: String, newDir: String)? {
        let root = attachmentsRoot(profileId: profileId)
        let oldPrefix = prefix8(oldConversationId) + "-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              let oldDir = names.first(where: { $0.hasPrefix(oldPrefix) }) else { return nil }
        let newDir = prefix8(newConversationId) + "-" + slugify(newTitle)
        do {
            try FileManager.default.copyItem(
                at: root.appendingPathComponent(oldDir),
                to: root.appendingPathComponent(newDir)
            )
        } catch {
            return nil
        }
        return (oldDir, newDir)
    }

    /// 复制对话时重写 segmentsData 里的附件 ref 路径前缀（旧目录 → 新目录）。解码失败原样返回。
    static func rewriteSegmentRefs(_ data: Data?, oldDir: String, newDir: String) -> Data? {
        guard let data,
              let segments = try? JSONDecoder().decode([MessageSegment].self, from: data) else { return data }
        let oldPrefix = "\(folderName)/\(oldDir)/"
        let newPrefix = "\(folderName)/\(newDir)/"
        let rewritten = segments.map { seg -> MessageSegment in
            switch seg {
            case .imageRef(let name, let type, let path) where path.hasPrefix(oldPrefix):
                return .imageRef(name: name, type: type, path: newPrefix + path.dropFirst(oldPrefix.count))
            case .fileDataRef(let name, let mime, let path) where path.hasPrefix(oldPrefix):
                return .fileDataRef(name: name, mime: mime, path: newPrefix + path.dropFirst(oldPrefix.count))
            case .audioRef(let name, let mime, let path, let duration, let script) where path.hasPrefix(oldPrefix):
                return .audioRef(name: name, mime: mime, path: newPrefix + path.dropFirst(oldPrefix.count), duration: duration, script: script)
            default:
                return seg
            }
        }
        return (try? JSONEncoder().encode(rewritten)) ?? data
    }

    /// 硬删除对话时清理它的附件目录（软删/回收站不调用）。
    static func deleteConversationAttachments(conversationId: String, profileId: String) {
        let prefix = prefix8(conversationId) + "-"
        let root = attachmentsRoot(profileId: profileId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let dir = root.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dir)
            FileLibraryStore.noteFolderRemoved(dir, profileId: profileId)
        }
    }
}
