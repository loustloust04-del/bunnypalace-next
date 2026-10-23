import Foundation
import SwiftData

/// 09-26 标签（多对多，FavoriteItem join）→ 文件夹（一对一，`Conversation.folderId`）一次性迁移。
/// 一个对话挂了多个标签的取最早挂上的那个；已有 folderId 的不覆盖。
/// 老的会话级 FavoriteItem 行先不删（留着能回滚），界面已不再读它们。
enum FolderMigration {
    static let doneKey = "folderMigrationV1Done"

    @MainActor
    static func runIfNeeded(context: ModelContext) {
        // 测试宿主 = app 本体、共用真库和真偏好：别在跑测试时把「已迁移」标记写进她的偏好
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        guard let moved = try? migrate(context: context) else { return }
        UserDefaults.standard.set(true, forKey: doneKey)
        print("[folder] 标签→文件夹迁移完成：\(moved) 个对话")
    }

    /// 返回写了 folderId 的对话数。幂等：再跑一次不会改任何东西。
    static func migrate(context: ModelContext) throws -> Int {
        let items = try context.fetch(FetchDescriptor<FavoriteItem>(sortBy: [SortDescriptor(\FavoriteItem.createTime)]))
        let tagIds = Set(try context.fetch(FetchDescriptor<ConversationTag>()).map(\.id))
        var target: [String: String] = [:]   // conversationId → 最早的 tagId
        for item in items where item.nodeId == nil && tagIds.contains(item.tagId) && target[item.conversationId] == nil {
            target[item.conversationId] = item.tagId
        }
        var moved = 0
        for (convId, tagId) in target {
            let id = convId
            var desc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == id })
            desc.fetchLimit = 1
            guard let conv = try context.fetch(desc).first, conv.folderId == nil else { continue }
            conv.folderId = tagId
            moved += 1
        }
        if moved > 0 { try context.save() }
        return moved
    }
}
