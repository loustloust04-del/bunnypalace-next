import MemoryCore
import Foundation
import SwiftData

/// `ConversationSource` 的真实实现：六个查询 = 原 app 侧谓词原样（研究 §5 表）。
/// 每次调用自开一个 `ModelContext`（照原 `RecallTool.execute` 的后台 context 现状），不在接口上收 context。
final class SwiftDataConversationSource: ConversationSource, Sendable {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    static func window(_ conversation: Conversation) -> ConversationWindow {
        ConversationWindow(
            id: conversation.id, profileId: conversation.profileId, title: conversation.title,
            createTime: conversation.createTime, updateTime: conversation.updateTime,
            isTrashed: conversation.isTrashed, memoryEnabled: conversation.memoryEnabled,
            currentNodeId: conversation.currentNodeId, branchSelection: conversation.branchSelectionData,
            isCC: conversation.ccBridgeSessionName != nil, lastRealChatAt: conversation.lastRealChatAt,
            provider: conversation.provider, importBatchId: conversation.importBatchId?.uuidString,
            archiveKind: conversation.archiveKind)
    }

    func windows(profileId: String, updatedSince: Date?, includeTrashed: Bool) throws -> [ConversationWindow] {
        let pid = profileId
        let descriptor: FetchDescriptor<Conversation>
        switch (updatedSince, includeTrashed) {
        case let (since?, true):
            descriptor = FetchDescriptor(predicate: #Predicate { $0.profileId == pid && $0.updateTime >= since })
        case let (since?, false):
            descriptor = FetchDescriptor(predicate: #Predicate { $0.profileId == pid && $0.isTrashed == false && $0.updateTime >= since })
        case (nil, true):
            descriptor = FetchDescriptor(predicate: #Predicate { $0.profileId == pid })
        case (nil, false):
            descriptor = FetchDescriptor(predicate: #Predicate { $0.profileId == pid && $0.isTrashed == false })
        }
        return try context().fetch(descriptor).map(Self.window)
    }

    func window(profileId: String, idOrPrefix: String) throws -> ConversationWindow? {
        let pid = profileId, wanted = idOrPrefix
        let ctx = context()
        var exact = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == pid && $0.id == wanted && $0.isTrashed == false })
        exact.fetchLimit = 1
        if let match = try ctx.fetch(exact).first { return Self.window(match) }
        guard wanted.count >= 8 else { return nil }
        let all = try ctx.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == pid && $0.isTrashed == false }))
        let matches = all.filter { $0.id.hasPrefix(wanted) }
        guard matches.count <= 1 else { throw ConversationSourceError.ambiguousIdPrefix(idOrPrefix) }
        return matches.first.map(Self.window)
    }

    func nodes(profileId: String, conversationId: String) throws -> [ConversationMessage] {
        let pid = profileId, cid = conversationId
        let descriptor = FetchDescriptor<MessageNode>(predicate: #Predicate {
            $0.profileId == pid && $0.conversationId == cid
        })
        return try context().fetch(descriptor).map { ConversationMessage($0) }
    }

    func messages(profileId: String, ids: [String]) throws -> [ConversationMessage] {
        let pid = profileId, wanted = ids
        let descriptor = FetchDescriptor<MessageNode>(predicate: #Predicate {
            $0.profileId == pid && wanted.contains($0.id)
        })
        return try context().fetch(descriptor).map { ConversationMessage($0) }
    }

    func search(profileId: String, text: String, conversationId: String?) throws -> [ConversationMessage] {
        let pid = profileId, search = text
        let descriptor: FetchDescriptor<MessageNode>
        if let cid = conversationId {
            descriptor = FetchDescriptor(predicate: #Predicate { node in
                node.profileId == pid && node.conversationId == cid && node.isTrashed == false
                    && node.content.localizedStandardContains(search)
            }, sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)])
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { node in
                node.profileId == pid && node.isTrashed == false && node.content.localizedStandardContains(search)
            }, sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)])
        }
        return try context().fetch(descriptor).map { ConversationMessage($0) }.filter {
            ($0.role == "user" || $0.role == "assistant") && !$0.isSourceHidden && !$0.isSyntheticRoot
        }
    }

    func titles(profileId: String, ids: [String]) throws -> [String: String] {
        let pid = profileId, wanted = ids
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate {
            $0.profileId == pid && wanted.contains($0.id)
        })
        var out: [String: String] = [:]
        for conversation in try context().fetch(descriptor) { out[conversation.id] = conversation.title }
        return out
    }
}
