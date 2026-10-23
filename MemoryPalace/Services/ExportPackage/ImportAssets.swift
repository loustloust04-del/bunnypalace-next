import Foundation

/// 导出包里带的附件字节在哪（#050 E6）。扫描时只记位置，写库时才读——
/// `PayloadImportEngine` 只对真写进去的对话读，跳过 / 冲突的不读，文件库不留孤儿。
struct ImportAssetRef: Hashable {
    enum Location: Hashable {
        case file(URL)
        case zipEntry(zip: URL, entry: TwitterZipExtractor.Entry)
    }

    let location: Location
    /// 包里的文件名（不含目录）
    let fileName: String
    let size: UInt64

    static let maxBytes: UInt64 = 512 << 20

    /// 读字节。单个附件上限 512 MB
    func read() throws -> Data {
        switch location {
        case .file(let url):
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard UInt64(size) <= Self.maxBytes else { throw ZipLimitError.entryTooLarge(fileName) }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        case .zipEntry(let zip, let entry):
            return try TwitterZipExtractor.readEntry(zip, entry: entry, maxBytes: Self.maxBytes)
        }
    }
}

/// ChatGPT 包里的附件索引（#050 E6）。粟粟真包（隐私门户三分卷）实测：图片指针的 id 几乎不出现在文件名里，
/// 要靠 `metadata.attachments` 的「文件名 + 大小」对；新版包（`file-<id>.dat`）按 id 对。
struct ChatGPTAssetIndex {
    /// 文件名以 `file-xxx` / `file_xxx` 开头的：按 id
    private(set) var byId: [String: ImportAssetRef] = [:]
    /// 按文件名（同名可能多个）
    private(set) var byName: [String: [ImportAssetRef]] = [:]
    /// Dall-E 分卷：`…/conversations/<对话 id>/<随机名>.webp`
    private(set) var byConversation: [String: [ImportAssetRef]] = [:]
    /// `conversation_asset_file_names.json`：包里文件名 → 原始文件名
    var displayNames: [String: String] = [:]

    var count: Int { Set(byId.values).union(byName.values.flatMap { $0 }).union(byConversation.values.flatMap { $0 }).count }
    var isEmpty: Bool { byId.isEmpty && byName.isEmpty && byConversation.isEmpty }

    /// 收一个文件。`path` 是包内相对路径（判 Dall-E 目录用）
    mutating func add(_ ref: ImportAssetRef, path: String) {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        if let i = parts.lastIndex(of: "conversations"), parts.count == i + 3, parts.contains("chatgptgenerations") {
            byConversation[parts[i + 1], default: []].append(ref)
            return
        }
        if let id = Self.leadingFileId(ref.fileName) { byId[id] = ref }
        byName[ref.fileName, default: []].append(ref)
    }

    /// `file-AbC123-IMG_1.jpeg` → `file-AbC123`；`file_00ab.dat` → `file_00ab`
    static func leadingFileId(_ name: String) -> String? {
        guard name.hasPrefix("file-") || name.hasPrefix("file_") else { return nil }
        let body = name.dropFirst(5).prefix { $0.isLetter || $0.isNumber }
        return body.isEmpty ? nil : String(name.prefix(5)) + body
    }

    /// 先按 id，再按「文件名 + 大小」唯一对上；大小不知道时文件名唯一也算。对不上 / 有歧义返回 nil
    func lookup(id: String, name: String?, size: UInt64?) -> ImportAssetRef? {
        if let ref = byId[id] { return ref }
        guard let name, let candidates = byName[name] ?? byName[displayNames[name] ?? ""] else { return nil }
        let unique = Set(candidates)
        if let size {
            let hits = unique.filter { $0.size == size }
            return hits.count == 1 ? hits.first : nil
        }
        return unique.count == 1 ? unique.first : nil
    }

    /// Dall-E：这段对话只有一张生成图、分卷里这段对话也只有一个文件时才对
    func soleGeneration(conversationId: String) -> ImportAssetRef? {
        guard let refs = byConversation[conversationId], refs.count == 1 else { return nil }
        return refs[0]
    }

    /// 图片 / 文件类扩展名（Files 分卷里除了这些还有代码沙盒的 csv / json，也算附件）
    static func isAssetPath(_ path: String) -> Bool {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let last = parts.last, !last.hasPrefix(".") else { return false }
        if last.hasSuffix(".dat") { return true }
        if parts.contains("files") || parts.contains("dalle-generations") || parts.contains("chatgptgenerations") { return true }
        if parts.contains(where: { $0.hasPrefix("user-") }) { return true }
        return leadingFileId(last) != nil
    }
}

/// 写库前把附件换成文件库里的真文件（#050 E6）。`PayloadImportEngine` 只对真写入 / 要合并的对话调。
/// 读不出来的保持占位，记一条注意事项，不中断导入。
enum ImportAssetResolver {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    static func resolve(_ payload: ImportedConversationPayload, profileId: String,
                        warnings: ImportWarnings?) -> ImportedConversationPayload {
        guard !payload.pendingAssets.isEmpty || payload.externalizeOnWrite else { return payload }
        let nodes = payload.nodes.map { node -> ImportedNodePayload in
            guard let data = node.segmentsData,
                  let segments = try? JSONDecoder().decode([MessageSegment].self, from: data) else { return node }
            var touched = false
            var inlined = segments.map { seg -> MessageSegment in
                switch seg {
                case .image, .fileData:
                    touched = touched || payload.externalizeOnWrite
                    return seg
                case .file(let name, let uuid):
                    guard let ref = payload.pendingAssets[uuid] else { return seg }
                    do {
                        let bytes = try ref.read()
                        touched = true
                        if let mime = imageMime(bytes, name: name.isEmpty ? ref.fileName : name) {
                            return .image(name: name, type: mime, data: bytes)
                        }
                        return .fileData(name: name, mime: fileMime(name), data: bytes)
                    } catch {
                        warnings?.add("有附件读不出来，保留了占位", name)
                        return seg
                    }
                default:
                    return seg
                }
            }
            guard touched else { return node }
            inlined = AttachmentStore.externalize(inlined, conversationId: payload.id,
                                                  conversationTitle: payload.title, profileId: profileId)
            // 正文（搜索用）不动：占位和真图压出来都是「🖼 名字」
            var out = node
            out.segmentsData = try? encoder.encode(inlined)
            return out
        }
        return ImportedConversationPayload(
            id: payload.id, title: payload.title, createTime: payload.createTime, updateTime: payload.updateTime,
            currentNodeId: payload.currentNodeId, provider: payload.provider, nodes: nodes,
            branchSelectionData: payload.branchSelectionData, personaId: payload.personaId,
            archiveKind: payload.archiveKind, sourceMetadata: payload.sourceMetadata, folderId: payload.folderId)
    }

    /// 扩展名或文件头是图片 → MIME；不是图片 nil
    static func imageMime(_ data: Data, name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: break
        }
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return nil }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return "image/webp"
        }
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "image/heic" }
        return nil
    }

    private static func fileMime(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "txt", "md": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

/// 导入注意事项（#050 E9）：同一类合并计数，每类留几个例子，完成页折叠显示
final class ImportWarnings {
    struct Group: Equatable {
        let title: String
        var count: Int
        var examples: [String]
    }

    private(set) var groups: [Group] = []

    func add(_ title: String, _ example: String? = nil, count: Int = 1) {
        if let i = groups.firstIndex(where: { $0.title == title }) {
            groups[i].count += count
            if let example, groups[i].examples.count < 3 { groups[i].examples.append(example) }
        } else {
            groups.append(Group(title: title, count: count, examples: example.map { [$0] } ?? []))
        }
    }
}
