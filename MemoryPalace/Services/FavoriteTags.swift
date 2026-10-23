import Foundation
import SwiftData

/// 收藏页自己的标签组（10-02 粟粟拍板，`docs/design-favorites-tag-groups.html` 方案 A）：
/// tag 就是一段文字，复用 FavoriteItem 一行一个 tag，`tagId = "fav:" + 名字`，和指向文件夹 UUID 的老行一眼分开。
/// 一条收藏可以打多个 tag；`nodeId` 为空 = 整个对话的 tag，有值 = 那条气泡的 tag。
/// 没有单独的 tag 表：没有收藏用它了，tag 自然消失。不同步（FavoriteItem 本来就不进 iCloud 对话同步）。
enum FavoriteTags {
    static let prefix = "fav:"

    static func isTagRow(_ item: FavoriteItem) -> Bool { item.tagId.hasPrefix(prefix) }
    static func name(of item: FavoriteItem) -> String { String(item.tagId.dropFirst(prefix.count)) }
    static func tagId(_ name: String) -> String { prefix + name }
    static func normalized(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 一条收藏：气泡（nodeId 有值）或整个对话
    struct Target: Identifiable, Hashable {
        let nodeId: String?
        let conversationId: String
        let profileId: String
        let preview: String
        var id: String { nodeId ?? "conv:" + conversationId }

        init(node: MessageNode) {
            nodeId = node.id
            conversationId = node.conversationId
            profileId = node.profileId
            preview = String(node.content.prefix(100))
        }

        init(conversation: Conversation) {
            nodeId = nil
            conversationId = conversation.id
            profileId = conversation.profileId
            preview = String(conversation.title.prefix(100))
        }
    }

    /// 收藏页用的一份快照：谁挂了哪些 tag、每个 tag 最近一次用的时间（胶囊排序）
    struct Index {
        var nodeTags: [String: [String]] = [:]
        var conversationTags: [String: [String]] = [:]
        var lastUsed: [String: Date] = [:]
    }

    /// 一个楼层的全部 tag 行（行数 = 收藏数 × 各自 tag 数，不大）
    static func rows(profileId: String, context: ModelContext) -> [FavoriteItem] {
        let pid = profileId
        let desc = FetchDescriptor<FavoriteItem>(predicate: #Predicate<FavoriteItem> { $0.profileId == pid },
                                                 sortBy: [SortDescriptor(\FavoriteItem.createTime)])
        return ((try? context.fetch(desc)) ?? []).filter(isTagRow)
    }

    /// 这条收藏上的 tag 行。nodeId 是 optional 不进 predicate（已知陷阱），按楼层 + 对话取出来内存判
    static func rows(for target: Target, context: ModelContext) -> [FavoriteItem] {
        let pid = target.profileId
        let cid = target.conversationId
        let desc = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { $0.profileId == pid && $0.conversationId == cid },
            sortBy: [SortDescriptor(\FavoriteItem.createTime)])
        return ((try? context.fetch(desc)) ?? []).filter { isTagRow($0) && $0.nodeId == target.nodeId }
    }

    static func tags(for target: Target, context: ModelContext) -> [String] {
        unique(rows(for: target, context: context).map(name(of:)))
    }

    /// 楼层里所有用过的 tag，最近用过的在前
    static func allTags(profileId: String, context: ModelContext) -> [String] {
        sortedByRecent(index(profileId: profileId, context: context).lastUsed)
    }

    static func index(profileId: String, context: ModelContext) -> Index {
        var index = Index()
        for row in rows(profileId: profileId, context: context) {
            let n = name(of: row)
            if let nid = row.nodeId {
                index.nodeTags[nid, default: []].append(n)
            } else {
                index.conversationTags[row.conversationId, default: []].append(n)
            }
            index.lastUsed[n] = max(index.lastUsed[n] ?? .distantPast, row.createTime)
        }
        index.nodeTags = index.nodeTags.mapValues(unique)
        index.conversationTags = index.conversationTags.mapValues(unique)
        return index
    }

    /// 胶囊一排：给定这一分段里每条收藏的 tag，数每个 tag 几条，最近用过的在前
    static func chips(_ tagLists: [[String]], lastUsed: [String: Date]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for list in tagLists { for n in list { counts[n, default: 0] += 1 } }
        return sortedByRecent(lastUsed.filter { counts[$0.key] != nil })
            .map { (name: $0, count: counts[$0] ?? 0) }
    }

    /// 把这条收藏的 tag 换成 `names`（「收藏到标签」sheet 的完成）。已有的行留着（保住最近使用时间），多余 / 重复的删
    static func set(_ names: [String], for target: Target, context: ModelContext) {
        let wanted = unique(names.map(normalized).filter { !$0.isEmpty })
        var kept = Set<String>()
        for row in rows(for: target, context: context) {
            let n = name(of: row)
            if wanted.contains(n), !kept.contains(n) {
                kept.insert(n)
            } else {
                context.delete(row)
            }
        }
        for n in wanted where !kept.contains(n) {
            context.insert(FavoriteItem(nodeId: target.nodeId, conversationId: target.conversationId,
                                        tagId: tagId(n), contentPreview: target.preview, profileId: target.profileId))
        }
        try? context.save()
    }

    /// 改名：同一条收藏已经有新名字的，旧行直接删（合并）
    static func rename(_ old: String, to new: String, profileId: String, context: ModelContext) {
        let newName = normalized(new)
        guard !newName.isEmpty, newName != old else { return }
        let all = rows(profileId: profileId, context: context)
        let owners = Set(all.filter { name(of: $0) == newName }.map { "\($0.conversationId)|\($0.nodeId ?? "")" })
        for row in all where name(of: row) == old {
            if owners.contains("\(row.conversationId)|\(row.nodeId ?? "")") {
                context.delete(row)
            } else {
                row.tagId = tagId(newName)
            }
        }
        try? context.save()
    }

    /// 删掉这个 tag（收藏本身还在）
    static func delete(_ tag: String, profileId: String, context: ModelContext) {
        for row in rows(profileId: profileId, context: context) where name(of: row) == tag {
            context.delete(row)
        }
        try? context.save()
    }

    // MARK: - 收藏 / 取消收藏（拍板③：取消收藏时 tag 一起清掉）

    static func setFavorite(_ node: MessageNode, _ on: Bool) {
        node.isFavorite = on
        if !on, let context = node.modelContext { set([], for: Target(node: node), context: context) }
    }

    static func setFavorite(_ conversation: Conversation, _ on: Bool) {
        conversation.isFavorite = on
        if !on, let context = conversation.modelContext { set([], for: Target(conversation: conversation), context: context) }
    }

    // MARK: - helpers

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func sortedByRecent(_ lastUsed: [String: Date]) -> [String] {
        lastUsed.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// 拍板④：老的气泡级「收藏到文件夹」行（nodeId 有值、tagId = 文件夹 id）一次性转成同名 tag（`fav:文件夹名`），
/// 并确保那条气泡已标星。只改 FavoriteItem.tagId 的值和 MessageNode.isFavorite，不删不插行；文件夹本身不动；
/// 对话级老行（nodeId 为空）是 09-26 之前「在哪个文件夹」的连接行，不动（FolderMigration 留着备回滚）。
/// 幂等：已经是 `fav:` 的行不再是候选；文件夹找不到 / 气泡找不到的行原样留着。跑完记 UserDefaults 标记，只跑一次。
enum FavoriteTagMigration {
    static let doneKey = "favoriteTagMigrationV1Done"

    @MainActor
    static func runIfNeeded(context: ModelContext) {
        // 测试宿主 = app 本体、共用真库和真偏好：别在跑测试时把「已迁移」标记写进她的偏好（同 FolderMigration）
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        guard let result = try? migrate(context: context) else { return }
        UserDefaults.standard.set(true, forKey: doneKey)
        print("[favtags] 文件夹收藏→标签迁移完成：转了 \(result.converted) / \(result.candidates) 行，补标星 \(result.starred) 条气泡")
    }

    static func migrate(context: ModelContext) throws -> (candidates: Int, converted: Int, starred: Int) {
        let items = try context.fetch(FetchDescriptor<FavoriteItem>())
        let candidates = items.filter { $0.nodeId != nil && !FavoriteTags.isTagRow($0) }
        print("[favtags] 迁移前：FavoriteItem 共 \(items.count) 行，其中气泡级收藏到文件夹 \(candidates.count) 行")
        guard !candidates.isEmpty else { return (0, 0, 0) }
        var folderNames: [String: String] = [:]
        for folder in try context.fetch(FetchDescriptor<ConversationTag>()) where folderNames[folder.id] == nil {
            folderNames[folder.id] = folder.name
        }
        var converted = 0
        var starred = 0
        for item in candidates {
            guard let nodeId = item.nodeId,
                  let folderName = folderNames[item.tagId].map(FavoriteTags.normalized), !folderName.isEmpty else { continue }
            var desc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.id == nodeId })
            desc.fetchLimit = 1
            guard let node = try context.fetch(desc).first else { continue }
            item.tagId = FavoriteTags.tagId(folderName)
            converted += 1
            if !node.isFavorite {
                node.isFavorite = true
                starred += 1
            }
        }
        if converted > 0 { try context.save() }
        return (candidates.count, converted, starred)
    }
}
