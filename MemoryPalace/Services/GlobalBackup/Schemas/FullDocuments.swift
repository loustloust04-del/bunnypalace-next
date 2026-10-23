import Foundation

// MARK: - Full Documents (.mpb schemaVersion = 4)
//
// 全量备份的 SwiftData @Model dump schema。**不复用** SyncStore.ConversationDocument /
// NodeDocument，那两个只覆盖跨设备同步需要的字段子集（codex Round 1 / 2 整改）。
//
// 每个 Full*Document 按 @Model 真值**全字段穷举**（包括 zombie 字段 isDeleted/deletedAt —
// UnifiedContainerMigration 启动会自动迁移到 isTrashed，但备份保留 schema 完整性）。
//
// schemaVersion 在每个 Document 都标，便于未来单 Model 字段升级时局部 bump。
// **G-A.1.8 字段覆盖比对脚本**会用 Mirror 反射真实 @Model 比对这里的字段，任何漏字段 =
// build 阶段不能通过。

// MARK: - Conversation / MessageNode

/// 按 Models/Conversation.swift:5-92 的 Conversation @Model 27 字段穷举
struct FullConversationDocument: Codable {
    let schemaVersion: Int

    let id: String                      // @Attribute(.unique)
    let profileId: String
    let title: String
    let createTime: Date
    let updateTime: Date
    let currentNodeId: String
    let isFavorite: Bool
    let folderId: String?
    let pinnedAt: Date?
    let unreadCount: Int
    let nodeCount: Int
    let lastOpenedAt: Date?
    // zombie（业务读写一律 isTrashed）
    let isDeleted: Bool
    let deletedAt: Date?
    // 业务真相
    let isTrashed: Bool
    let trashedAt: Date?
    let provider: String
    let importBatchId: UUID?
    let memoryEnabled: Bool
    let ccBridgeSessionName: String?
    let selectedModelId: String
    let currentStyleId: String
    let permGrantsRaw: String?    // 权限 P1 后加字段：optional 保旧备份可解码，导入回填 ""
    let mcpServerIds: [String]
    let draftText: String
    let draftAttachmentsData: Data?     // @Attribute(.externalStorage)
    let draftQuotePreview: String
    let draftQuoteReplyTo: String

    let nodes: [FullNodeDocument]
    /// 卡库 ③b 分支选择表：optional 保旧备份可解码，缺键 = nil（加载时从 currentNodeId 路径重建）
    var branchSelectionData: Data? = nil
    /// 卡库 ⑧c：optional 保旧备份可解码，缺键 = nil
    var personaId: String? = nil
    var archiveKind: String? = nil
    var sourceMetadata: Data? = nil
    /// 卡库第二批 B4：optional 保旧备份可解码，缺键 = nil
    var cardVariablesData: Data? = nil
}

/// 按 Models/Conversation.swift:94-231 的 MessageNode @Model 31 字段穷举
struct FullNodeDocument: Codable {
    let schemaVersion: Int

    let id: String                      // @Attribute(.unique)
    let profileId: String
    let role: String
    let content: String
    let contentType: String
    let createTime: Date?
    let parentId: String?
    let childrenIds: [String]
    let conversationId: String
    let isFavorite: Bool
    let isPinned: Bool
    let pinnedAt: Date?
    let isDeleted: Bool                 // zombie
    let deletedAt: Date?                // zombie
    let isTrashed: Bool
    let trashedAt: Date?
    let segmentsData: Data?             // @Attribute(.externalStorage)
    let ccMessageId: String?
    let replyToId: String?
    let replyQuote: String?
    let ccEdited: Bool
    let styleIdSnapshot: String?
    let ccThinking: String?
    // usage 6 标量（不是单个 Data — codex Round 2 强烈纠正）
    let usagePromptTokens: Int?
    let usageCompletionTokens: Int?
    let usageCacheReadTokens: Int?
    let usageCacheWriteTokens: Int?
    let usageCostUSD: Double?
    let usageSavedUSD: Double?
    let imageDescsData: Data?
    let bookRef: String?
    let webSourcesData: Data?
    let thinkingSummary: String?
    var toolSummariesData: Data? = nil
    var isSyntheticRoot: Bool? = nil
    /// 卡库 ⑧c：optional 保旧备份可解码，缺键 = nil
    var sourceMetadata: Data? = nil
    var sourceVisibility: String? = nil
    /// 卡库第二批 B4：optional 保旧备份可解码，缺键 = nil
    var cardVariablesData: Data? = nil
    var cardEditedAt: Date? = nil
    /// §13 网页卡事件捎带：optional 保旧备份可解码
    var cardEventsData: Data? = nil
}

// MARK: - UserCard

/// 按 Models/Conversation.swift:233-257
struct FullUserCardDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let profileId: String
    let content: String
    let imageData: Data?                // **不是** externalStorage（codex Round 3 修正）
    let attachedToNodeId: String?
    let positionX: Double
    let positionY: Double
    let createTime: Date
}

// MARK: - ConversationTag / FavoriteItem

/// 按 Models/ConversationTag.swift:5-29
struct FullConversationTagDocument: Codable {
    let schemaVersion: Int

    let id: String
    let profileId: String
    let name: String
    let emoji: String
    let order: Int
    let createTime: Date
    // 09-26 文件夹化新增；老备份没有这三个键 → nil
    let symbol: String?
    let colorHex: String?
    let instructions: String?
}

/// 按 Models/ConversationTag.swift:32-58
struct FullFavoriteItemDocument: Codable {
    let schemaVersion: Int

    let id: String
    let profileId: String
    let nodeId: String?
    let conversationId: String
    let tagId: String
    let contentPreview: String
    let createTime: Date
}

// MARK: - ImportRecord / ImportConversationChange

/// 按 Models/ImportRecord.swift:9-72
struct FullImportRecordDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let profileId: String
    let fileName: String
    let importDate: Date
    let provider: String
    let conversationCount: Int
    let nodeCount: Int
    let modeRaw: String
    let supportsUndo: Bool
    let addedConversationCount: Int
    let updatedConversationCount: Int
    let skippedConversationCount: Int
    let ignoredConversationCount: Int
    /// #061 起有；旧备份没有 = 0
    let conflictConversationCount: Int?
    /// #061 B 期导入清单；旧备份没有 = nil
    let detailData: Data?
}

/// 按 Models/ImportConversationChange.swift:9-46
struct FullImportConversationChangeDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let profileId: String
    let recordId: UUID
    let conversationId: String
    let changeKindRaw: String
    let beforeConversationData: Data?
    let beforeNodesData: Data?
}

// MARK: - Memory / MemoryNote

/// 按 Models/MemoryNote.swift:4-26
struct FullMemoryNoteDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let content: String
    let profileId: String
    let createdAt: Date
    let updatedAt: Date
    let source: String
    let isActive: Bool
}

/// 按 Models/Memory.swift:6-82
struct FullMemoryDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let content: String
    let category: String
    let keywords: [String]
    let tokenCount: Int
    let accessCount: Int
    let lastAccessedAt: Date
    let decayWeight: Double
    let validUntil: Date?
    let sourceConversationId: String?
    let extractedBy: String
    let isUserExplicit: Bool
    let sourceQuote: String?
    let sourceNodeId: String?
    let supersededAt: Date?
    let profileId: String
    let createdAt: Date
    let updatedAt: Date
    let embeddingData: Data?
    let embeddingRevision: Int?
    let relatedIds: [UUID]
    let parentId: UUID?
}

// MARK: - WorldBook

/// 按 Models/WorldBook.swift:100-130 的 WorldBook @Model
/// entries 嵌在 entriesData Data（JSON [WorldBookEntry]）里，照原样保留
struct FullWorldBookDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let name: String
    let profileId: String
    let scopeConversationId: String?
    let rawJSONData: Data?
    /// ⑥ 整本开关；旧备份缺键 = 开
    let isEnabled: Bool?
    let entriesData: Data
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - Stickers

/// 按 Models/StickerAsset.swift:5-70
/// imagePath/thumbnailPath/originalImagePath 是相对贴纸根目录的**文件名**（不是绝对路径）
/// 包内贴纸图片**平铺镜像**到 stickers/{pid}/{filename}（codex Round 2 严重整改）
struct FullStickerAssetDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let name: String
    let assetType: String               // "image" | "note"
    let imagePath: String               // 相对文件名（"{uuid}.png"）
    let thumbnailPath: String           // 相对文件名（"{uuid}_thumb.png"）
    let originalImagePath: String?      // 相对文件名（"{uuid}_original.png"）
    let borderStyle: String
    let borderWidth: Double
    let filterStyle: String
    let noteContent: String?
    let noteStyle: String?
    let tags: [String]
    let createdAt: Date
    let profileId: String
}

/// 按 Models/PlacedSticker.swift:6-66
struct FullPlacedStickerDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let stickerAssetId: UUID?
    let conversationId: String
    let nearestMessageId: String?
    let positionX: Double
    let positionY: Double
    let rotation: Double
    let scale: Double
    let zIndex: Int
    let noteContent: String?
    let noteStyle: String?
    let isLocked: Bool
    let placedAt: Date
    let profileId: String
}

// MARK: - Books / Audiobooks

/// 按 Models/BookEntry.swift:14-53
struct FullBookEntryDocument: Codable {
    let schemaVersion: Int

    let id: String                      // safeName
    let profileId: String
    let name: String
    let author: String
    let format: String
    let totalChapters: Int
    let currentChapter: Int
    let scrollRatio: Double
    let addedAt: Date
    let lastReadAt: Date?
    let updateTime: Date
    let coverData: Data?                // @Attribute(.externalStorage)
}

/// 按 Models/AudiobookItem.swift:9-44
/// **不 dump** `bookmarks: [AudiobookBookmark]` 反向 relationship — bookmarks 自己有 bookId 冗余，
/// 导入时按 bookId 重建关系（避免循环 dump）
struct FullAudiobookItemDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let profileId: String
    let title: String
    let fileName: String
    let fileSizeBytes: Int64
    let totalDuration: Double
    let currentTime: Double
    let lastPlayedAt: Date?
    let importedAt: Date
}

/// 按 Models/AudiobookBookmark.swift:13-46
/// **不 dump** `book: AudiobookItem?` 反向 relationship — 导入时按 bookId 关联回去
struct FullAudiobookBookmarkDocument: Codable {
    let schemaVersion: Int

    let id: UUID
    let profileId: String
    let bookId: UUID
    let timestamp: Double
    let note: String
    let bookTitleSnapshot: String
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - Document Schema Version Default

extension FullConversationDocument {
    static let currentSchemaVersion: Int = 4
}
extension FullNodeDocument {
    static let currentSchemaVersion: Int = 4
}
// 其他 Document 共享同一 schemaVersion（manifest 顶层有版本，per-doc 字段留备用未来局部升级）
