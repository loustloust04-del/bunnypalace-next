import Foundation
import CryptoKit

/// 整包导入报告（plan §6.3）。只有数字、相对路径、行号 / 字段和原因，不含私密正文。
struct SillyTavernImportReport: Codable {
    struct Category: Codable, Equatable {
        var key: String
        var title: String
        var sourceFiles = 0
        /// 新建了对象
        var created = 0
        /// 同来源同文件同 hash：零增量
        var skipped = 0
        /// 只归档原字节
        var archivedOnly = 0
        /// 内容变了：保留新版原件，未覆盖
        var changed = 0
        var failed = 0
        /// 盘点中被排除（原件仍归档）
        var excluded = 0
        /// 读进来但功能未支持 / 不执行的项数（不是文件数，见 issues）
        var unsupported = 0
    }

    struct Issue: Codable, Equatable {
        var relativePath: String
        var line: Int?
        var field: String?
        var reason: String
        var action: String
        var retryable: Bool
        /// 相对 cardlibrary/ 的原件位置；nil = 没有原件（凭据不读不存）
        var archivePath: String?
    }

    /// 内容数字（区分「带 swipes 的消息」和「真多候选」）
    struct Numbers: Codable, Equatable {
        var messages = 0
        /// 带 swipes 数组的消息（含只有 1 个候选的）
        var messagesWithSwipes = 0
        /// swipes 多于 1 个：真多候选
        var multiCandidateMessages = 0
        var candidates = 0
        var contentNodes = 0
        var syntheticRoots = 0
        /// mes 与选中 swipe 不同：正文取 mes，源 swipe 放 metadata，两份都在
        var mesDiffers = 0
        var hiddenMessages = 0
        var swipeIdOutOfRange = 0
        var badLines = 0
        var placeholderFloors = 0
        var groupArchiveFloors = 0
        var attachmentRefsResolved = 0
        var attachmentRefsMissing = 0
        var archivedBlobsNew = 0
        var archivedBlobsReused = 0
        var globalRegexDisabledOnImport = 0
        var unboundWorldsDisabled = 0
    }

    var batchId: String
    var sourceId: String
    var sourceName: String
    var createdAt: Date
    var isReimport: Bool
    var categories: [Category]
    /// 目标类别 → 本批新建对象数；与来源清单、实际对象数一致
    var objects: [String: Int]
    var numbers: Numbers
    var issues: [Issue]
    var warnings: [String]
}

/// 撤回报告（plan §6.2-5）：逐项删 / 留及原因
struct SillyTavernRetractReport: Codable {
    struct Item: Codable, Equatable {
        enum Action: String, Codable { case deleted, kept, alreadyGone }
        var kind: String
        var id: String
        var relativePath: String
        var action: Action
        var reason: String
    }

    var sourceId: String
    var batchIds: [String]
    var date: Date
    var items: [Item]

    func count(_ action: Item.Action, kind: ImportTarget.Kind? = nil) -> Int {
        items.filter { $0.action == action && (kind == nil || $0.kind == kind!.rawValue) }.count
    }
}

/// 首次内容 hash：撤回时与当前值比，判断「仍未修改」
enum ImportFingerprint {
    static func of<T: Encodable>(_ value: T) -> String {
        (try? CardLibraryStorage.encoder.encode(value)).map(CardLibraryStorage.sha256) ?? "unencodable"
    }

    /// ⑧c-4 之前的卡编码（原件内嵌、没有引用字段），原件从文件读回
    static func legacyCard(_ card: CharacterCard) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[CharacterCard.legacyInlineEncoding] = true
        return (try? encoder.encode(card)).map(CardLibraryStorage.sha256) ?? "unencodable"
    }

    /// 第二批 B1 之前的卡编码（脚本数缓存按旧算法、没有版本号）：B1 重算脚本数后，B1 前导入的卡仍能比对上
    static func preB1Card(_ card: CharacterCard) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[CharacterCard.preB1Encoding] = true
        return (try? encoder.encode(card)).map(CardLibraryStorage.sha256) ?? "unencodable"
    }

    static func worldBook(_ book: WorldBook) -> String {
        hash([book.name, book.profileId, book.scopeConversationId ?? "", CardLibraryStorage.sha256(book.entriesData),
              book.rawJSONData.map(CardLibraryStorage.sha256) ?? "", "\(book.isEnabled)"])
    }

    /// 对话 + 全部节点：加消息、切支、编辑、收藏、删除都会改变；打开 / 草稿 / 未读不算
    static func conversation(_ conversation: Conversation, nodes: [MessageNode]) -> String {
        let selection = BranchSelection.decode(conversation.branchSelectionData).sorted { $0.key < $1.key }
            .map { "\($0.key)>\($0.value)" }.joined(separator: ",")
        var parts = [conversation.title, conversation.currentNodeId, conversation.profileId, "\(conversation.isTrashed)",
                     "\(conversation.isFavorite)", "\(conversation.pinnedAt != nil)", conversation.personaId ?? "",
                     conversation.archiveKind ?? "", "\(conversation.memoryEnabled)", conversation.folderId ?? "", selection]
        for node in nodes.sorted(by: { $0.id < $1.id }) {
            parts.append([node.id, node.role, node.content, node.parentId ?? "", node.childrenIds.joined(separator: ","),
                          "\(node.isTrashed)", "\(node.isFavorite)", "\(node.isPinned)",
                          node.segmentsData.map(CardLibraryStorage.sha256) ?? "", node.sourceVisibility ?? ""].joined(separator: "\u{1F}"))
        }
        return hash(parts)
    }

    private static func hash(_ parts: [String]) -> String {
        CardLibraryStorage.sha256(Data(parts.joined(separator: "\u{1E}").utf8))
    }
}
