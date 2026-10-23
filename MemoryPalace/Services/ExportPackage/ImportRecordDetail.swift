import Foundation
import SwiftData

/// 导入详情（#061 A 期）：从撤回记录（ImportConversationChange）反查这次导进来的东西现在在哪。
/// 只读当前值：对话后来挪了文件夹 / 删了，这里看到的就是挪过 / 删过的样子。
struct ImportRecordDetail {
    struct ConversationItem: Identifiable {
        let id: String
        let title: String
        let messageCount: Int
        let updateTime: Date
        let trashed: Bool
        /// 当前所在文件夹；"" = 没在文件夹里
        let folderId: String
    }

    struct FolderGroup: Identifiable {
        /// 文件夹 id；"" = 没在文件夹里
        let id: String
        let name: String
        let items: [ConversationItem]
    }

    struct FolderItem: Identifiable {
        let id: String
        let name: String
        let note: String?
        let missing: Bool
    }

    struct MemoryItem: Identifiable {
        enum State {
            case unchanged, edited, deleted
            var rank: Int { self == .unchanged ? 0 : self == .edited ? 1 : 2 }
        }
        let id: String
        let content: String
        let state: State
    }

    var created: [FolderGroup] = []
    var updated: [FolderGroup] = []
    var createdCount = 0
    var updatedCount = 0
    /// 撤回记录里有、库里已经没有的对话（删掉了，或撤回到一半）
    var missingConversations = 0
    var folders: [FolderItem] = []
    var memories: [MemoryItem] = []
    /// 导入清单（#061 B 期起的记录才有）
    var manifest: ImportManifest?
    /// 清单里的对话 id → 现在的标题（删掉的没有）
    var titles: [String: String] = [:]

    private static let batchSize = 500

    static func load(recordId: UUID, profileId: String, context: ModelContext) throws -> ImportRecordDetail {
        var detail = ImportRecordDetail()
        var recordDescriptor = FetchDescriptor<ImportRecord>(predicate: #Predicate {
            $0.id == recordId && $0.profileId == profileId
        })
        recordDescriptor.fetchLimit = 1
        detail.manifest = ImportManifest.decode(try context.fetch(recordDescriptor).first?.detailData)
        let created = ImportConversationChangeKind.created.rawValue
        let updated = ImportConversationChangeKind.updated.rawValue
        let memoryKind = ImportConversationChangeKind.createdMemory.rawValue
        let folderKind = ImportConversationChangeKind.createdFolder.rawValue

        // .updated 带整条对话的快照：只取 id 和种类，别把快照读进来
        var light = FetchDescriptor<ImportConversationChange>(predicate: #Predicate {
            $0.recordId == recordId && $0.profileId == profileId
        })
        light.propertiesToFetch = [\.conversationId, \.changeKindRaw]
        var createdIds: [String] = [], updatedIds: [String] = [], folderIds: [String] = []
        for change in try context.fetch(light) {
            switch change.changeKindRaw {
            case created: createdIds.append(change.conversationId)
            case updated: updatedIds.append(change.conversationId)
            case folderKind: folderIds.append(change.conversationId)
            default: break
            }
        }

        let tags = try context.fetch(FetchDescriptor<ConversationTag>(predicate: #Predicate { $0.profileId == profileId }))
        let tagById = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let conversations = try fetchConversations(Set(createdIds + updatedIds), profileId: profileId, context: context)
        detail.missingConversations = Set(createdIds + updatedIds).subtracting(conversations.keys).count
        detail.createdCount = Set(createdIds).count
        detail.updatedCount = Set(updatedIds).count
        detail.titles = conversations.mapValues(\.title)
        detail.created = grouped(createdIds, conversations, tagById)
        detail.updated = grouped(updatedIds, conversations, tagById)

        detail.folders = folderIds.map { id in
            guard let tag = tagById[id] else { return FolderItem(id: id, name: "（已删除）", note: nil, missing: true) }
            let note = tag.instructions.split(whereSeparator: \.isNewline).first.map(String.init)
            return FolderItem(id: id, name: tag.name, note: note, missing: false)
        }
        .sorted { a, b in a.missing != b.missing ? !a.missing : a.name.localizedStandardCompare(b.name) == .orderedAscending }

        let memoryChanges = try context.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate {
            $0.recordId == recordId && $0.profileId == profileId && $0.changeKindRaw == memoryKind
        }))
        let memoryIds = memoryChanges.compactMap { UUID(uuidString: $0.conversationId) }
        var memoryById: [UUID: Memory] = [:]
        for start in stride(from: 0, to: memoryIds.count, by: batchSize) {
            let chunk = Array(memoryIds[start..<min(start + batchSize, memoryIds.count)])
            for memory in try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate {
                chunk.contains($0.id) && $0.profileId == profileId
            })) {
                memoryById[memory.id] = memory
            }
        }
        detail.memories = memoryChanges.map { change in
            let imported = change.beforeConversationData.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard let id = UUID(uuidString: change.conversationId), let memory = memoryById[id] else {
                return MemoryItem(id: change.conversationId, content: imported, state: .deleted)
            }
            return MemoryItem(id: change.conversationId, content: memory.content,
                              state: memory.content == imported ? .unchanged : .edited)
        }
        // 撤回记录取出来没有固定顺序：没动的、改过的、删了的依次，各自按内容排
        .sorted { a, b in
            a.state.rank != b.state.rank ? a.state.rank < b.state.rank
                : a.content.localizedStandardCompare(b.content) == .orderedAscending
        }
        return detail
    }

    private static func fetchConversations(_ ids: Set<String>, profileId: String,
                                           context: ModelContext) throws -> [String: ConversationItem] {
        let all = Array(ids)
        var out: [String: ConversationItem] = [:]
        for start in stride(from: 0, to: all.count, by: batchSize) {
            let chunk = Array(all[start..<min(start + batchSize, all.count)])
            for c in try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate {
                chunk.contains($0.id) && $0.profileId == profileId
            })) {
                out[c.id] = ConversationItem(id: c.id, title: c.title, messageCount: c.nodeCount,
                                             updateTime: c.updateTime, trashed: c.isTrashed, folderId: c.folderId ?? "")
            }
        }
        return out
    }

    /// 按当前文件夹分组：有名字的按名字排，没在文件夹里的放最后；组内新的在前
    private static func grouped(_ ids: [String], _ conversations: [String: ConversationItem],
                                _ tags: [String: ConversationTag]) -> [FolderGroup] {
        var byFolder: [String: [ConversationItem]] = [:]
        for id in Set(ids) {
            guard let item = conversations[id] else { continue }
            let folder = tags[item.folderId] == nil ? "" : item.folderId
            byFolder[folder, default: []].append(item)
        }
        return byFolder.map { folder, items in
            FolderGroup(id: folder, name: tags[folder]?.name ?? "没在文件夹里",
                        items: items.sorted { $0.updateTime > $1.updateTime })
        }
        .sorted { a, b in
            if a.id.isEmpty != b.id.isEmpty { return !a.id.isEmpty }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
