import Foundation
import SwiftData

/// 列表详细模式第二行：模型最后说的那句。按 currentNodeId 单条取（不全量 fetch MessageNode），
/// key 带 currentNodeId，有新消息 key 就变，旧条目自然失效。
@MainActor
enum ConversationPreviewCache {
    private static var cache: [String: String] = [:]

    static func key(_ conversation: Conversation) -> String {
        "\(conversation.id)|\(conversation.currentNodeId)"
    }

    static func preview(for conversation: Conversation, context: ModelContext) -> String {
        let cacheKey = key(conversation)
        if let hit = cache[cacheKey] { return hit }

        let pid = conversation.profileId
        var nodeId = conversation.currentNodeId
        var userFallback = ""
        var result = ""
        // 末尾是用户刚发的 / 工具空壳 → 往上找最近一条有字的 assistant，最多看 4 个
        for _ in 0..<4 where !nodeId.isEmpty {
            let id = nodeId
            var desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id && $0.profileId == pid })
            desc.fetchLimit = 1
            guard let node = try? context.fetch(desc).first else { break }
            let text = ConversationTitler.plainText(node.content)
            if node.role == "assistant", !text.isEmpty { result = text; break }
            if node.role == "user", userFallback.isEmpty, !text.isEmpty { userFallback = "你：" + text }
            nodeId = node.parentId ?? ""
        }
        if result.isEmpty { result = userFallback }
        result = String(result.prefix(120))
        if cache.count > 500 { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = result
        return result
    }
}
