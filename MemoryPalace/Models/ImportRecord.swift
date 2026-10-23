import Foundation
import SwiftData

enum ImportMode: String, Codable {
    case normal
    case merge
    /// #057 补原图：只往已有对话的占位里填图，撤回只换回占位
    case backfill
}

@Model
final class ImportRecord {
    #if os(iOS)
    #Index<ImportRecord>(
        [\.profileId, \.importDate]
    )
    #endif

    var id: UUID = UUID()
    /// 楼层隔离
    var profileId: String = ""
    var fileName: String
    var importDate: Date
    var provider: String          // Conversation.importedProviders 之一
    var conversationCount: Int
    var nodeCount: Int
    var modeRaw: String = ""
    var supportsUndo: Bool = false
    var addedConversationCount: Int = 0
    var updatedConversationCount: Int = 0
    var skippedConversationCount: Int = 0
    var ignoredConversationCount: Int = 0
    /// 已在其他楼层、这次跳过的（#061 起单独计；之前的记录并在 ignored 里）
    var conflictConversationCount: Int = 0
    /// 导入清单（#061 B 期，`ImportManifest` 的 JSON）：哪个文件去了哪、跳过了哪些、文件库写到哪。旧记录为 nil
    @Attribute(.externalStorage) var detailData: Data? = nil

    var mode: ImportMode {
        get { ImportMode(rawValue: modeRaw) ?? .normal }
        set { modeRaw = newValue.rawValue }
    }

    var isLegacyRecord: Bool {
        !supportsUndo &&
        addedConversationCount == 0 &&
        updatedConversationCount == 0 &&
        skippedConversationCount == 0 &&
        ignoredConversationCount == 0 &&
        conflictConversationCount == 0 &&
        conversationCount > 0
    }

    init(
        fileName: String,
        provider: String,
        conversationCount: Int = 0,
        nodeCount: Int = 0,
        mode: ImportMode = .normal,
        supportsUndo: Bool = false,
        addedConversationCount: Int = 0,
        updatedConversationCount: Int = 0,
        skippedConversationCount: Int = 0,
        ignoredConversationCount: Int = 0,
        profileId: String = ""
    ) {
        self.fileName = fileName
        self.importDate = Date()
        self.provider = provider
        self.conversationCount = conversationCount
        self.nodeCount = nodeCount
        self.modeRaw = mode.rawValue
        self.supportsUndo = supportsUndo
        self.addedConversationCount = addedConversationCount
        self.updatedConversationCount = updatedConversationCount
        self.skippedConversationCount = skippedConversationCount
        self.ignoredConversationCount = ignoredConversationCount
        self.profileId = profileId
    }
}
