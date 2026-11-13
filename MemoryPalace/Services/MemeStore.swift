import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// 表情包消息记号：整条消息正文 = `[meme:UUID]`
enum MemeToken {
    private static let prefix = "[meme:"

    static func make(_ id: UUID) -> String { "\(prefix)\(id.uuidString)]" }

    /// 整条（去首尾空白）恰好是一个记号才算
    static func match(_ content: String) -> UUID? {
        let s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix), s.hasSuffix("]") else { return nil }
        return UUID(uuidString: String(s.dropFirst(prefix.count).dropLast()))
    }

    /// 给模型 / 标题看的文字
    static func promptText(name: String?, detail: String?) -> String {
        guard let name, !name.isEmpty else { return "〖表情包〗" }
        if let detail, !detail.isEmpty { return "〖表情包：\(name)——\(detail)〗" }
        return "〖表情包：\(name)〗"
    }
}

/// 表情包文件：~/Library/Application Support/MemoryPalace/stickers/{profileId}/memes/
enum MemeStore {
    static let maxBytes = 5 * 1024 * 1024
    static let lookAtImageKey = "memeSendImageToModel"

    /// 设置 › 贴纸 ›「AI 看原图」：只在发出那一轮把图给模型
    static var sendsImageToModel: Bool {
        UserDefaults.standard.object(forKey: lookAtImageKey) as? Bool ?? true
    }

    enum Failure: LocalizedError {
        case tooLarge, notImage
        var errorDescription: String? {
            switch self {
            case .tooLarge: "图片超过 5 MB"
            case .notImage: "读不出这张图"
            }
        }
    }

    static func directory(profileId: String) -> URL {
        let dir = AppPaths.checked(StickerFileManager.stickerDirectory(profileId: profileId)
            .appendingPathComponent("memes", isDirectory: true))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(_ fileName: String, profileId: String) -> URL {
        AppPaths.checked(directory(profileId: profileId).appendingPathComponent(fileName))
    }

    static func thumbURL(id: UUID, profileId: String) -> URL {
        AppPaths.checked(directory(profileId: profileId).appendingPathComponent("\(id.uuidString)_thumb.png"))
    }

    /// 识别类型（只认图片），返回 (mime, ext)
    static func sniff(_ data: Data) -> (mime: String, ext: String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(src) as String?,
              let type = UTType(uti), type.conforms(to: .image) else { return nil }
        let mime = type.preferredMIMEType ?? "image/png"
        let ext = type.preferredFilenameExtension ?? "png"
        return (mime, ext)
    }

    /// 存原文件 + 缩略图；后台调用
    static func save(_ data: Data, id: UUID, profileId: String) throws -> (fileName: String, mimeType: String) {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let kind = sniff(data) else { throw Failure.notImage }
        let fileName = "\(id.uuidString).\(kind.ext)"
        try data.write(to: fileURL(fileName, profileId: profileId))
        if let thumb = firstFramePNG(data, maxPixel: 240) {
            try? thumb.write(to: thumbURL(id: id, profileId: profileId))
        }
        return (fileName, kind.mime)
    }

    static func delete(id: UUID, fileName: String, profileId: String) {
        try? FileManager.default.removeItem(at: fileURL(fileName, profileId: profileId))
        try? FileManager.default.removeItem(at: thumbURL(id: id, profileId: profileId))
    }

    static func loadOriginal(_ fileName: String, profileId: String) -> Data? {
        try? Data(contentsOf: fileURL(fileName, profileId: profileId))
    }

    /// 首帧 PNG（缩略图 / 给模型看 / 看图起名）；maxPixel nil = 原尺寸
    static func firstFramePNG(_ data: Data, maxPixel: Int? = nil) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let cg: CGImage?
        if let maxPixel {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        } else {
            cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let cg else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func fetch(_ id: UUID, in ctx: ModelContext?) -> ChatMeme? {
        guard let ctx else { return nil }
        var fd = FetchDescriptor<ChatMeme>(predicate: #Predicate { $0.id == id })
        fd.fetchLimit = 1
        return try? ctx.fetch(fd).first
    }

    /// 给模型的一条表情包消息：文字永远是「〖表情包：名字——描述〗」；attachImage（最新一轮 + 开关 + 权限）才附图
    static func promptParts(for meme: ChatMeme?, attachImage: Bool) -> (text: String, image: PendingChatAttachment?) {
        let text = MemeToken.promptText(name: meme?.name, detail: meme?.detail)
        guard attachImage, let meme, let img = imageForModel(meme) else { return (text, nil) }
        let ext = img.mime == "image/jpeg" ? "jpg" : "png"
        let att = try? PendingChatAttachment.image(name: "\(meme.name.isEmpty ? "表情包" : meme.name).\(ext)",
                                                   typeDescription: "表情包", mimeType: img.mime, data: img.data)
        return (text, att)
    }

    /// 发给模型的那张：静图原样，动图取首帧 PNG
    static func imageForModel(_ meme: ChatMeme) -> (data: Data, mime: String)? {
        guard let data = loadOriginal(meme.fileName, profileId: meme.profileId) else { return nil }
        if meme.isAnimated || !["image/png", "image/jpeg"].contains(meme.mimeType) {
            return firstFramePNG(data, maxPixel: 1024).map { ($0, "image/png") }
        }
        return (data, meme.mimeType)
    }
}
