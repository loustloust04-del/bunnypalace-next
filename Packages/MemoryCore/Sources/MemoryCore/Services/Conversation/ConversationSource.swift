import Foundation

/// 记忆后端读对话的唯一入口（摘包刀 2，plan §2.1）。
/// 同步 `throws`：现有调用点都在自己的后台 `Task` / `ModelContext` 里同步查，协议不改线程模型。
/// 只读；不碰落盘格式，也不给对话模型加字段。
public protocol ConversationSource: Sendable {
    /// ①按楼层列窗口；`updatedSince` 为 nil = 不限；`includeTrashed` 控制回收站
    func windows(profileId: String, updatedSince: Date?, includeTrashed: Bool) throws -> [ConversationWindow]
    /// ②按 id / ≥8 位前缀取窗口（精确优先；只返回未删窗口）
    func window(profileId: String, idOrPrefix: String) throws -> ConversationWindow?
    /// ③一个窗口的全部节点（含已删，建树用）
    func nodes(profileId: String, conversationId: String) throws -> [ConversationMessage]
    /// ④按 id 批量取消息（带 profileId；顺序不保证）
    func messages(profileId: String, ids: [String]) throws -> [ConversationMessage]
    /// ⑤消息全文 contains（b4 原语义：未删、user/assistant、非隐藏、非合成根；createTime 倒序、无上限、可限窗口）
    func search(profileId: String, text: String, conversationId: String?) throws -> [ConversationMessage]
    /// ⑥批量取标题（不过滤回收站）
    func titles(profileId: String, ids: [String]) throws -> [String: String]
}

public enum ConversationSourceError: Error, Equatable, Sendable {
    /// 前缀命中多个窗口：不猜
    case ambiguousIdPrefix(String)
}

extension ConversationSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ambiguousIdPrefix: "conversation_id 前缀有歧义，请给完整 ID；不会猜另一个窗口。"
        }
    }
}

/// 楼层里的一场对话（协议值类型，plan §1）。
public struct ConversationWindow: Sendable, Codable, Equatable {
    public var id: String
    public var profileId: String
    public var title: String
    public var createTime: Date
    public var updateTime: Date
    public var isTrashed: Bool
    public var memoryEnabled: Bool
    /// 派生出的路径末端缓存；`visiblePath` 只在没有 `branchSelection` 时用它
    public var currentNodeId: String
    /// `BranchSelection.encode` 的 `[父 id: 选中孩子 id]` JSON
    public var branchSelection: Data?
    /// `ccBridgeSessionName != nil`
    public var isCC: Bool
    public var lastRealChatAt: Date?
    public var provider: String
    public var importBatchId: String?
    public var archiveKind: String?

    public init(id: String, profileId: String, title: String, createTime: Date, updateTime: Date,
                isTrashed: Bool = false, memoryEnabled: Bool = true, currentNodeId: String = "",
                branchSelection: Data? = nil, isCC: Bool = false, lastRealChatAt: Date? = nil,
                provider: String = "chatgpt", importBatchId: String? = nil, archiveKind: String? = nil) {
        self.id = id
        self.profileId = profileId
        self.title = title
        self.createTime = createTime
        self.updateTime = updateTime
        self.isTrashed = isTrashed
        self.memoryEnabled = memoryEnabled
        self.currentNodeId = currentNodeId
        self.branchSelection = branchSelection
        self.isCC = isCC
        self.lastRealChatAt = lastRealChatAt
        self.provider = provider
        self.importBatchId = importBatchId
        self.archiveKind = archiveKind
    }
}

/// 一条消息（协议值类型，plan §1）。
public struct ConversationMessage: Sendable, Codable, Equatable {
    public var id: String
    public var conversationId: String
    public var role: String
    public var content: String
    /// nil = 没有分段数据（对应 `MessageNode.segmentsData == nil`）
    public var segments: [ConversationSegment]?
    public var contentType: String
    public var createTime: Date?
    public var parentId: String?
    public var childrenIds: [String]
    public var isTrashed: Bool
    public var isSyntheticRoot: Bool
    /// nil = 普通；"hidden" / "uiSystem" 不进显示、记忆、API
    public var sourceVisibility: String?
    public var ccMessageId: String?
    /// 正文被卡里网页改过的时间（`MessageNode.cardEditedAt`）；nil = 没改过
    public var cardEditedAt: Date?
    /// CC edit_message 改过（`MessageNode.ccEdited`）；默认 false
    public var ccEdited: Bool

    public init(id: String, conversationId: String, role: String, content: String,
                segments: [ConversationSegment]? = nil, contentType: String = "text",
                createTime: Date? = nil, parentId: String? = nil, childrenIds: [String] = [],
                isTrashed: Bool = false, isSyntheticRoot: Bool = false,
                sourceVisibility: String? = nil, ccMessageId: String? = nil,
                cardEditedAt: Date? = nil, ccEdited: Bool = false) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.segments = segments
        self.contentType = contentType
        self.createTime = createTime
        self.parentId = parentId
        self.childrenIds = childrenIds
        self.isTrashed = isTrashed
        self.isSyntheticRoot = isSyntheticRoot
        self.sourceVisibility = sourceVisibility
        self.ccMessageId = ccMessageId
        self.cardEditedAt = cardEditedAt
        self.ccEdited = ccEdited
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, role, content, segments, contentType, createTime, parentId
        case childrenIds, isTrashed, isSyntheticRoot, sourceVisibility, ccMessageId, cardEditedAt, ccEdited
    }

    /// 自定义解码：`cardEditedAt` / `ccEdited` 是 E3-W2 才加的两个键，旧 JSON 没有；
    /// 合成解码会因缺键整条抛错，这里按 nil / false 兜底。其余字段仍是必填（写端一直带）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        segments = try c.decodeIfPresent([ConversationSegment].self, forKey: .segments)
        contentType = try c.decode(String.self, forKey: .contentType)
        createTime = try c.decodeIfPresent(Date.self, forKey: .createTime)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        childrenIds = try c.decode([String].self, forKey: .childrenIds)
        isTrashed = try c.decode(Bool.self, forKey: .isTrashed)
        isSyntheticRoot = try c.decode(Bool.self, forKey: .isSyntheticRoot)
        sourceVisibility = try c.decodeIfPresent(String.self, forKey: .sourceVisibility)
        ccMessageId = try c.decodeIfPresent(String.self, forKey: .ccMessageId)
        cardEditedAt = try c.decodeIfPresent(Date.self, forKey: .cardEditedAt)
        ccEdited = try c.decodeIfPresent(Bool.self, forKey: .ccEdited) ?? false
    }

    /// 逐字照抄 `Models/Conversation.swift:284`：源里隐藏的消息（酒馆 /hide、界面提示）
    public var isSourceHidden: Bool { sourceVisibility == "hidden" || sourceVisibility == "uiSystem" }

    /// 逐字照抄 `Models/Conversation.swift:304-306`：文字非空 **或** 带 segment（图/文件附件）。
    /// `segments != nil` 对应 `segmentsData != nil`。
    public var hasDisplayableContent: Bool {
        !isSyntheticRoot && !isSourceHidden && (!content.isEmpty || segments != nil)
    }
}

/// 正文口径用到的分段（`CatalogOriginalText.body` 只读 text 与 audioRef 两种 kind）。
public enum ConversationSegment: Sendable, Codable, Equatable {
    case text(String)
    /// 思考分段（`MessageSegment.thinking` 的正文；签名 / 密文不进值类型）：正文口径不读
    case thinking(String)
    /// 语音条：正文仍在 content，script 不是正文
    case audioRef
    /// 其余分段（工具 / 附件 …）：正文口径不读
    case other

    private enum CodingKeys: String, CodingKey { case kind, text }
    private enum Kind: String, Codable { case text, thinking, audioRef, other }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 新导出端会写出旧解码器不认识的 kind（如 thinking）：未知一律退回 `.other`，
        // 别让一条分段炸掉整份快照（旧版 MemoryCore / 还在跑的旧 memoryd 二进制读新快照）。
        switch Kind(rawValue: try c.decode(String.self, forKey: .kind)) ?? .other {
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        case .thinking: self = .thinking(try c.decode(String.self, forKey: .text))
        case .audioRef: self = .audioRef
        case .other: self = .other
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(value, forKey: .text)
        case .thinking(let value):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(value, forKey: .text)
        case .audioRef:
            try c.encode(Kind.audioRef, forKey: .kind)
        case .other:
            try c.encode(Kind.other, forKey: .kind)
        }
    }
}
