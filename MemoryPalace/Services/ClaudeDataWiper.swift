import Foundation
import SwiftData

/// 一次性清除指定楼层的 Claude provider 导入数据。
///
/// 清除范围：
/// - `Conversation` where provider == "claude" && profileId == pid
/// - `MessageNode` 属于这些 conversation（通过 deleteConversationArtifacts 级联，
///   顺带清掉对应的 FavoriteItem / UserCard.attachedToNodeId 引用）
/// - `ImportRecord` where provider == "claude" && profileId == pid
/// - `ImportConversationChange` 属于这些 ImportRecord（通过 recordId）
/// - 这些导入顺带建的花园记忆 / 文件夹（#043，按撤回规则：被改写过的记忆留着）
///
/// 不动：API/Preset/WorldBook 等配置、你自己的记忆；ChatGPT 导入数据。
/// 粟粟点击确认后调用，用于 P5 切换到新 segments 格式前把旧 Claude 数据清干净。
enum ClaudeDataWiper {

    struct Preview {
        let conversationCount: Int
        let nodeCount: Int
        let importRecordCount: Int
    }

    /// 预览：统计将被删除的内容数量。不改数据库。
    static func preview(profileId: String, context: ModelContext) throws -> Preview {
        let pid = profileId
        let convDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.provider == "claude" && $0.profileId == pid }
        )
        let conversations = try context.fetch(convDescriptor)

        var nodeCount = 0
        for conv in conversations {
            let nodes = try fetchConversationNodes(
                conversationId: conv.id,
                profileId: pid,
                in: context
            )
            nodeCount += nodes.count
        }

        let recordDescriptor = FetchDescriptor<ImportRecord>(
            predicate: #Predicate<ImportRecord> { $0.provider == "claude" && $0.profileId == pid }
        )
        let importRecords = try context.fetch(recordDescriptor)

        return Preview(
            conversationCount: conversations.count,
            nodeCount: nodeCount,
            importRecordCount: importRecords.count
        )
    }

    /// 实际执行清除。幂等：再次运行什么都不做。
    @discardableResult
    static func wipe(profileId: String, context: ModelContext) throws -> Preview {
        let pid = profileId

        // 1) fetch conversations + import records first
        let convDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.provider == "claude" && $0.profileId == pid }
        )
        let conversations = try context.fetch(convDescriptor)

        let recordDescriptor = FetchDescriptor<ImportRecord>(
            predicate: #Predicate<ImportRecord> { $0.provider == "claude" && $0.profileId == pid }
        )
        let importRecords = try context.fetch(recordDescriptor)
        let recordIds = Set(importRecords.map(\.id))

        // 2) delete import changes first（按 recordId 聚合）
        for recordId in recordIds {
            let rid = recordId
            let changeDescriptor = FetchDescriptor<ImportConversationChange>(
                predicate: #Predicate<ImportConversationChange> { $0.recordId == rid && $0.profileId == pid }
            )
            let changes = try context.fetch(changeDescriptor)
            for change in changes {
                // 导入顺带建的记忆 / 文件夹走撤回逻辑清掉，不然删了记录它们就再也撤不了
                if change.changeKind == .createdMemory || change.changeKind == .createdFolder {
                    try restoreConversationChange(change, in: context)
                }
                context.delete(change)
            }
        }

        // 3) delete each conversation + its nodes + favorites via existing helper
        var nodeCountBefore = 0
        for conversation in conversations {
            let nodes = try fetchConversationNodes(
                conversationId: conversation.id,
                profileId: pid,
                in: context
            )
            nodeCountBefore += nodes.count
            try deleteConversationArtifacts(
                conversationId: conversation.id,
                profileId: pid,
                in: context
            )
        }

        // 4) delete import records
        for record in importRecords {
            context.delete(record)
        }

        try context.save()

        return Preview(
            conversationCount: conversations.count,
            nodeCount: nodeCountBefore,
            importRecordCount: importRecords.count
        )
    }
}
