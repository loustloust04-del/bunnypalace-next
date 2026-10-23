import Foundation
import SwiftData

enum ImportConversationChangeKind: String, Codable {
    case created
    case updated
    /// #043 D9：导入顺带建的花园记忆 / 文件夹，撤回时一起删。`conversationId` 字段存的是记忆 id / 文件夹 id
    case createdMemory
    case createdFolder
    /// #057 补原图：`beforeNodesData` 存 `ImageBackfill.UndoPayload`，撤回只把补进去的图换回占位
    case backfilledImage
}

@Model
final class ImportConversationChange {
    #if os(iOS)
    #Index<ImportConversationChange>(
        [\.profileId, \.recordId]
    )
    #endif

    var id: UUID = UUID()
    /// 楼层隔离
    var profileId: String = ""
    var recordId: UUID
    var conversationId: String
    var changeKindRaw: String
    var beforeConversationData: Data?
    var beforeNodesData: Data?

    var changeKind: ImportConversationChangeKind {
        get { ImportConversationChangeKind(rawValue: changeKindRaw) ?? .created }
        set { changeKindRaw = newValue.rawValue }
    }

    init(
        recordId: UUID,
        conversationId: String,
        changeKind: ImportConversationChangeKind,
        beforeConversationData: Data? = nil,
        beforeNodesData: Data? = nil,
        profileId: String = ""
    ) {
        self.recordId = recordId
        self.conversationId = conversationId
        self.changeKindRaw = changeKind.rawValue
        self.beforeConversationData = beforeConversationData
        self.beforeNodesData = beforeNodesData
        self.profileId = profileId
    }
}

struct ConversationSnapshot: Codable {
    let id: String
    let title: String
    let createTime: Date
    let updateTime: Date
    let currentNodeId: String
    let isFavorite: Bool
    let folderId: String?
    let nodeCount: Int
    let lastOpenedAt: Date?
    let isDeleted: Bool
    let deletedAt: Date?
    let provider: String
    let importBatchId: UUID?
    let mcpServerIds: [String]?
    /// 卡库 ③b：老快照 JSON 无此 key，解码为 nil
    let branchSelectionData: Data?
    /// 卡库 ⑧c：老快照无这些 key，解码为 nil
    let personaId: String?
    let archiveKind: String?
    let sourceMetadata: Data?

    init(conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        createTime = conversation.createTime
        updateTime = conversation.updateTime
        currentNodeId = conversation.currentNodeId
        isFavorite = conversation.isFavorite
        folderId = conversation.folderId
        nodeCount = conversation.nodeCount
        lastOpenedAt = conversation.lastOpenedAt
        // 字段名沿用 isDeleted/deletedAt 兼容老 ImportRecord 快照 JSON；
        // 模型读写一律走 isTrashed/trashedAt（避开 NSManagedObject 框架冲突）。
        isDeleted = conversation.isTrashed
        deletedAt = conversation.trashedAt
        provider = conversation.provider
        importBatchId = conversation.importBatchId
        mcpServerIds = conversation.mcpServerIds
        branchSelectionData = conversation.branchSelectionData
        personaId = conversation.personaId
        archiveKind = conversation.archiveKind
        sourceMetadata = conversation.sourceMetadata
    }

    func apply(to conversation: Conversation) {
        conversation.title = title
        conversation.createTime = createTime
        conversation.updateTime = updateTime
        conversation.currentNodeId = currentNodeId
        conversation.isFavorite = isFavorite
        conversation.folderId = folderId
        conversation.nodeCount = nodeCount
        conversation.lastOpenedAt = lastOpenedAt
        conversation.isTrashed = isDeleted
        conversation.trashedAt = deletedAt
        conversation.provider = provider
        conversation.importBatchId = importBatchId
        conversation.mcpServerIds = mcpServerIds ?? []
        conversation.branchSelectionData = branchSelectionData
        conversation.personaId = personaId
        conversation.archiveKind = archiveKind
        conversation.sourceMetadata = sourceMetadata
    }

    func makeConversation(profileId: String) -> Conversation {
        let conversation = Conversation(
            id: id,
            title: title,
            createTime: createTime,
            updateTime: updateTime,
            currentNodeId: currentNodeId,
            provider: provider,
            profileId: profileId
        )
        apply(to: conversation)
        return conversation
    }
}

struct MessageNodeSnapshot: Codable {
    let id: String
    let role: String
    let content: String
    let contentType: String
    let createTime: Date?
    let parentId: String?
    let childrenIds: [String]
    let conversationId: String
    let isFavorite: Bool
    let isDeleted: Bool
    let deletedAt: Date?
    /// Claude v2 segmentsData snapshot；老数据或解码失败时为 nil，undo 走老路径即可。
    let segmentsData: Data?
    /// 卡库 ⑧c：老快照无这些 key，解码为 nil
    let sourceMetadata: Data?
    let sourceVisibility: String?

    init(node: MessageNode) {
        id = node.id
        role = node.role
        content = node.content
        contentType = node.contentType
        createTime = node.createTime
        parentId = node.parentId
        childrenIds = node.childrenIds
        conversationId = node.conversationId
        isFavorite = node.isFavorite
        // 见 ConversationSnapshot 同款注释
        isDeleted = node.isTrashed
        deletedAt = node.trashedAt
        segmentsData = node.segmentsData
        sourceMetadata = node.sourceMetadata
        sourceVisibility = node.sourceVisibility
    }

    func apply(to node: MessageNode) {
        node.role = role
        node.content = content
        node.contentType = contentType
        node.createTime = createTime
        node.parentId = parentId
        node.childrenIds = childrenIds
        node.conversationId = conversationId
        node.isFavorite = isFavorite
        node.isTrashed = isDeleted
        node.trashedAt = deletedAt
        node.segmentsData = segmentsData
        node.sourceMetadata = sourceMetadata
        node.sourceVisibility = sourceVisibility
    }

    func makeNode(profileId: String) -> MessageNode {
        let node = MessageNode(
            id: id,
            role: role,
            content: content,
            contentType: contentType,
            createTime: createTime,
            parentId: parentId,
            childrenIds: childrenIds,
            conversationId: conversationId,
            profileId: profileId
        )
        apply(to: node)
        return node
    }
}
