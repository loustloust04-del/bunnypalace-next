import Foundation
import SwiftData

/// #057 补原图：已导进来的 Claude / ChatGPT 对话里，图片只留了占位 `.file(name, uuid)`（导出包没给字节）。
/// 用户在自己浏览器里按编号把原图下到一个文件夹（文件名 = 编号），这里**只按编号**填回占位，不按名字 / 大小猜。
/// 一次补图 = 每个来源一条导入记录（mode = .backfill），撤回只把补进去的图换回占位（`ImportSupport` 的 `.backfilledImage`）。
enum ImageBackfill {
    enum Source: String, CaseIterable, Identifiable {
        case claude, chatgpt
        var id: String { rawValue }
        var displayName: String { self == .claude ? "Claude" : "ChatGPT" }
    }

    /// 对话里的一处占位
    struct Placeholder: Hashable {
        let conversationId: String
        let nodeId: String
        let name: String
    }

    /// 这个楼层还缺原图的占位
    struct Inventory {
        /// 编号 → 用到它的占位（同一编号可能多处引用）
        var byId: [String: [Placeholder]] = [:]
        /// 编号 → 来源
        var sourceOf: [String: Source] = [:]
        /// 这个楼层里每个来源的对话数（未进回收站）——有对话却一个占位都没有，提示先叠加再导
        var conversationCount: [Source: Int] = [:]

        func missingIds(_ source: Source) -> [String] {
            sourceOf.filter { $0.value == source }.map(\.key).sorted()
        }

        func conversationsWithPlaceholders(_ source: Source) -> Int {
            Set(byId.filter { sourceOf[$0.key] == source }.values.flatMap { $0.map(\.conversationId) }).count
        }
    }

    /// 明显不是图片的扩展名：这单只补图（R2），文档类占位不列进清单
    static let documentExtensions: Set<String> = [
        "pdf", "md", "markdown", "txt", "html", "htm", "json", "csv", "tsv", "xml", "yaml", "yml",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "zip", "py", "js", "ts", "swift", "sh", "zshrc",
        "mp3", "m4a", "wav", "ogg", "mp4", "mov",
    ]

    static func isLikelyImage(name: String) -> Bool {
        !documentExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 找占位：先筛出本楼层的 Claude / ChatGPT 对话，再按正文含「🖼」分页取节点（占位和真图压出来都是「🖼 名字」）。
    /// 不全量取节点；回收站里的对话 / 节点不算。
    static func scan(profileId: String, context: ModelContext, pageSize: Int = 500) throws -> Inventory {
        var inventory = Inventory()
        let pid = profileId
        let sources = Source.allCases.map(\.rawValue)
        let conversations = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate {
            $0.profileId == pid && !$0.isTrashed && sources.contains($0.provider)
        }))
        var sourceOfConversation: [String: Source] = [:]
        for conversation in conversations {
            guard let source = Source(rawValue: conversation.provider) else { continue }
            sourceOfConversation[conversation.id] = source
            inventory.conversationCount[source, default: 0] += 1
        }
        guard !sourceOfConversation.isEmpty else { return inventory }

        let decoder = JSONDecoder()
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<MessageNode>(
                predicate: #Predicate { $0.profileId == pid && !$0.isTrashed && $0.content.contains("🖼") },
                sortBy: [SortDescriptor(\.id)])
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            for node in page {
                guard let source = sourceOfConversation[node.conversationId], let data = node.segmentsData,
                      let segments = try? decoder.decode([MessageSegment].self, from: data) else { continue }
                for case .file(let name, let uuid) in segments where !uuid.isEmpty && isLikelyImage(name: name) {
                    let placeholder = Placeholder(conversationId: node.conversationId, nodeId: node.id, name: name)
                    if !(inventory.byId[uuid]?.contains(placeholder) ?? false) {
                        inventory.byId[uuid, default: []].append(placeholder)
                    }
                    inventory.sourceOf[uuid] = source
                }
            }
            if page.count < pageSize { break }
            offset += page.count
        }
        return inventory
    }
}

// MARK: - 浏览器脚本

extension ImageBackfill {
    enum ScriptError: Error {
        case templateMissing
    }

    private struct ScriptConfig: Encodable {
        struct Item: Encodable {
            let id: String
            let name: String
            let conversationId: String?
        }
        let source: String
        let items: [Item]
    }

    /// 给用户在自己浏览器里跑的脚本（`Resources/BackfillScripts/backfill-images.js`）：清单按 JSON 编码塞进模板，不拼字符串。
    /// limit = 只带前几张（「先试 3 张」）
    static func script(for source: Source, inventory: Inventory, limit: Int? = nil) throws -> String {
        guard let url = Bundle.main.url(forResource: "backfill-images", withExtension: "js", subdirectory: "BackfillScripts")
                ?? Bundle.main.url(forResource: "backfill-images", withExtension: "js") else { throw ScriptError.templateMissing }
        return try script(template: String(contentsOf: url, encoding: .utf8), source: source, inventory: inventory, limit: limit)
    }

    static func script(template: String, source: Source, inventory: Inventory, limit: Int? = nil) throws -> String {
        var ids = inventory.missingIds(source)
        if let limit { ids = Array(ids.prefix(limit)) }
        let items = ids.map { id in
            let first = inventory.byId[id]?.first
            // ChatGPT 的生成图可能要带对话 id 才取得到；Claude 不用
            return ScriptConfig.Item(id: id, name: first?.name ?? "", conversationId: source == .chatgpt ? first?.conversationId : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(ScriptConfig(source: source.rawValue, items: items)), as: UTF8.self)
        return template.replacingOccurrences(of: "__BACKFILL_CONFIG__", with: json)
    }
}

// MARK: - 下好的文件夹

extension ImageBackfill {
    /// 文件夹里的一张：文件名去掉扩展名就是编号
    struct FolderItem: Hashable {
        let id: String
        let url: URL
        let size: UInt64
    }

    struct Folder {
        var items: [String: FolderItem] = [:]
        /// 脚本写的 `backfill-manifest.json`：编号 → 状态（ok / notFound / error）。没有这个文件也能用
        var manifestStatus: [String: String] = [:]
    }

    static let manifestFileName = "backfill-manifest.json"

    /// 读文件夹（不递归）。隐藏文件、清单本身跳过；同一编号多个文件（不同扩展名）取先列到的
    static func readFolder(_ directory: URL) throws -> Folder {
        var folder = Folder()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            if name == manifestFileName {
                folder.manifestStatus = (try? parseManifest(Data(contentsOf: url))) ?? [:]
                continue
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let id = (name as NSString).deletingPathExtension
            guard !id.isEmpty, folder.items[id] == nil else { continue }
            folder.items[id] = FolderItem(id: id, url: url, size: UInt64(values?.fileSize ?? 0))
        }
        return folder
    }

    private struct ManifestFile: Decodable {
        struct Item: Decodable {
            let id: String
            let status: String
        }
        let items: [Item]
    }

    static func parseManifest(_ data: Data) throws -> [String: String] {
        let file = try JSONDecoder().decode(ManifestFile.self, from: data)
        return Dictionary(file.items.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
    }

    /// 文件头是不是图片（只读前 12 字节）
    static func sniffImageMime(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        return ImportAssetResolver.imageMime(head, name: "")
    }
}

// MARK: - 预览

extension ImageBackfill {
    struct Preview {
        /// 能补的：编号 → 文件
        var fillable: [String: FolderItem] = [:]
        var fillableBytes: UInt64 = 0
        /// 能补的占位处数 / 对话数（按来源）
        var placeholderCount: [Source: Int] = [:]
        var conversationCount: [Source: Int] = [:]
        /// 文件夹里有、这层楼没有这个编号的
        var notInFloor = 0
        /// 文件头不是图片（报错页、HTML…）或超过单张上限的
        var notImage: [String] = []
        /// 这层楼缺、文件夹里也没有的（按来源）；其中脚本说服务器上找不到的
        var stillMissing: [Source: Int] = [:]
        var reportedNotFound = 0

        var isEmpty: Bool { fillable.isEmpty }
        var sources: [Source] { Source.allCases.filter { (placeholderCount[$0] ?? 0) > 0 } }
    }

    static func preview(inventory: Inventory, folder: Folder) -> Preview {
        var preview = Preview()
        for (id, item) in folder.items {
            guard let placeholders = inventory.byId[id], let source = inventory.sourceOf[id] else {
                preview.notInFloor += 1
                continue
            }
            guard item.size <= ImportAssetRef.maxBytes, sniffImageMime(item.url) != nil else {
                preview.notImage.append(id)
                continue
            }
            preview.fillable[id] = item
            preview.fillableBytes += item.size
            preview.placeholderCount[source, default: 0] += placeholders.count
        }
        for source in Source.allCases {
            let conversations = Set(preview.fillable.keys.filter { inventory.sourceOf[$0] == source }
                .flatMap { inventory.byId[$0] ?? [] }.map(\.conversationId))
            if !conversations.isEmpty { preview.conversationCount[source] = conversations.count }
        }
        for (id, source) in inventory.sourceOf where folder.items[id] == nil {
            preview.stillMissing[source, default: 0] += 1
            if folder.manifestStatus[id] == "notFound" { preview.reportedNotFound += 1 }
        }
        preview.notImage.sort()
        return preview
    }
}

// MARK: - 写库

extension ImageBackfill {
    /// 撤回用：一个节点里补进去的一张
    struct UndoEntry: Codable, Equatable {
        let nodeId: String
        let uuid: String
        /// 占位原来的名字（撤回换回 `.file(name, uuid)`）
        let name: String
        /// 写进文件库的路径（`.imageRef` 的 path）
        let path: String
    }

    /// 撤回用：一段对话一条（`ImportConversationChange.beforeNodesData` = 条目，`beforeConversationData` = 这次新建的文件）
    struct UndoPayload: Codable, Equatable {
        var entries: [UndoEntry]
        var createdFiles: [String]
    }

    struct Result: Equatable {
        var filled: [Source: Int] = [:]
        var conversations: [Source: Int] = [:]
        /// 读不出来 / 落盘失败，保持占位的
        var failed: [String] = []
        var recordIds: [UUID] = []
    }

    /// 写库（后台线程调）。每个来源一条导入记录；每段对话一次 save，中途失败已补的照样能撤。
    static func apply(preview: Preview, inventory: Inventory, folderName: String, profileId: String,
                      container: ModelContainer, progress: (Double) -> Void = { _ in }) throws -> Result {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var result = Result()

        // 对话 → (编号 → 文件)
        var plan: [String: [String: FolderItem]] = [:]
        for (id, item) in preview.fillable {
            for placeholder in inventory.byId[id] ?? [] {
                plan[placeholder.conversationId, default: [:]][id] = item
            }
        }
        let conversationIds = plan.keys.sorted()
        var records: [Source: ImportRecord] = [:]
        var manifests: [Source: ImportManifest.Source] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()

        for (index, conversationId) in conversationIds.enumerated() {
            defer { progress(Double(index + 1) / Double(max(conversationIds.count, 1))) }
            guard let files = plan[conversationId], let firstId = files.keys.first,
                  let source = inventory.sourceOf[firstId] else { continue }
            let cid = conversationId
            let pid = profileId
            guard let conversation = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate {
                $0.id == cid && $0.profileId == pid
            })).first else { continue }
            let nodes = try fetchConversationNodes(conversationId: conversationId, profileId: profileId, in: context)
            let before = attachmentFiles(conversationId: conversationId, profileId: profileId)
            var entries: [UndoEntry] = []
            // 同一段对话里同一编号只落盘一次，别处引用同一路径（名字可能不同）
            var stored: [String: (path: String, mime: String)] = [:]
            func store(_ uuid: String, name: String) -> (path: String, mime: String)? {
                if let hit = stored[uuid] { return hit }
                guard let item = files[uuid], let bytes = try? Data(contentsOf: item.url, options: .mappedIfSafe),
                      let mime = ImportAssetResolver.imageMime(bytes, name: "") else { return nil }
                let out = AttachmentStore.externalize([.image(name: name, type: mime, data: bytes)],
                                                      conversationId: conversationId,
                                                      conversationTitle: conversation.title, profileId: profileId)
                // 落盘失败 externalize 会留内联 → 不写进库，保持占位
                guard case .imageRef(_, _, let path) = out.first else { return nil }
                stored[uuid] = (path, mime)
                return (path, mime)
            }

            for node in nodes where !node.isTrashed {
                guard let data = node.segmentsData,
                      let segments = try? decoder.decode([MessageSegment].self, from: data) else { continue }
                var out = segments
                for (i, segment) in segments.enumerated() {
                    guard case .file(let name, let uuid) = segment, files[uuid] != nil else { continue }
                    guard let hit = store(uuid, name: name) else {
                        if !result.failed.contains(uuid) { result.failed.append(uuid) }
                        continue
                    }
                    out[i] = .imageRef(name: name, type: hit.mime, path: hit.path)
                    entries.append(UndoEntry(nodeId: node.id, uuid: uuid, name: name, path: hit.path))
                }
                if out != segments { node.segmentsData = try encoder.encode(out) }
            }
            guard !entries.isEmpty else { continue }

            let record: ImportRecord
            if let existing = records[source] {
                record = existing
            } else {
                record = ImportRecord(fileName: "补原图 · \(folderName)", provider: source.rawValue, mode: .backfill,
                                      supportsUndo: true, profileId: profileId)
                context.insert(record)
                records[source] = record
                manifests[source] = ImportManifest.Source(label: folderName, kind: .conversations)
                result.recordIds.append(record.id)
            }
            let created = attachmentFiles(conversationId: conversationId, profileId: profileId)
                .subtracting(before)
                .intersection(entries.map(\.path))
            let payload = UndoPayload(entries: entries, createdFiles: created.sorted())
            context.insert(ImportConversationChange(
                recordId: record.id, conversationId: conversationId, changeKind: .backfilledImage,
                beforeNodesData: try encoder.encode(payload), profileId: profileId))
            record.conversationCount += 1
            record.updatedConversationCount += 1
            record.nodeCount += entries.count
            manifests[source]?.updated.append(conversationId)
            if let manifest = manifests[source] {
                record.detailData = ImportManifest(packages: [folderName], sources: [manifest], notIncluded: [],
                                                   failures: []).encoded()
            }
            result.filled[source, default: 0] += entries.count
            result.conversations[source, default: 0] += 1
            try context.save()
        }
        result.failed.sort()
        return result
    }

    /// 这段对话附件目录里现有的文件（文件库相对路径）。补之前、补之后各取一次，差集 = 这次新建的
    static func attachmentFiles(conversationId: String, profileId: String) -> Set<String> {
        let root = FileLibraryStore.libraryRoot(profileId: profileId)
            .appendingPathComponent(AttachmentStore.folderName, isDirectory: true)
        let prefix = String(conversationId.prefix(8)) + "-"
        let fm = FileManager.default
        var out: Set<String> = []
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where dir.hasPrefix(prefix) {
            let dirURL = root.appendingPathComponent(dir, isDirectory: true)
            for file in (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? [] {
                out.insert("\(AttachmentStore.folderName)/\(dir)/\(file)")
            }
        }
        return out
    }

    /// 撤回一段对话的补图：只把指向这次路径的 `.imageRef` 换回占位，其它内容不动；最后删这次新建、已没人引用的文件。
    /// 节点被删 / 图被换过的跳过。
    static func undo(_ payload: UndoPayload, conversationId: String, profileId: String, context: ModelContext) throws {
        let nodes = try fetchConversationNodes(conversationId: conversationId, profileId: profileId, in: context)
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()
        for (nodeId, entries) in Dictionary(grouping: payload.entries, by: \.nodeId) {
            guard let node = byId[nodeId], let data = node.segmentsData,
                  var segments = try? decoder.decode([MessageSegment].self, from: data) else { continue }
            var changed = false
            for entry in entries {
                guard let i = segments.firstIndex(where: {
                    if case .imageRef(_, _, let path) = $0 { return path == entry.path }
                    return false
                }) else { continue }
                segments[i] = .file(name: entry.name, uuid: entry.uuid)
                changed = true
            }
            if changed { node.segmentsData = try encoder.encode(segments) }
        }
        let stillUsed = Set(nodes.flatMap { node -> [String] in
            guard let data = node.segmentsData,
                  let segments = try? decoder.decode([MessageSegment].self, from: data) else { return [] }
            return segments.compactMap {
                if case .imageRef(_, _, let path) = $0 { return path }
                return nil
            }
        })
        for path in payload.createdFiles where !stillUsed.contains(path) {
            try? FileLibraryStore.delete(path, profileId: profileId)
        }
    }
}
