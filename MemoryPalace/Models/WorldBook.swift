import Foundation
import SwiftData

// MARK: - World Book Entry (Codable, stored as JSON inside WorldBook)

struct WorldBookEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var isEnabled: Bool = true

    // --- 触发条件 ---
    var keys: [String] = []                         // 主关键词（OR，命中任一即触发）
    var secondaryKeys: [String] = []                // 次关键词
    var selectiveLogic: SelectiveLogic = .andAny     // 主次关键词组合逻辑
    var scanDepth: Int?                              // 扫描最近几条消息（nil = 全局默认 10）
    var matchWholeWords: Bool = false
    var caseSensitive: Bool = false
    var isConstant: Bool = false                     // 常驻注入（跳过关键词匹配）

    // --- 注入内容 ---
    var content: String = ""
    var position: InsertionPosition = .afterCharDef
    var insertionOrder: Int = 100                    // 排序权重（小的先注入）
    var depth: Int? = 4                              // nil 保留缺键，扫描时默认 4；0 不折叠

    // --- 元数据 ---
    var comment: String = ""
    var probability: Int = 100                       // 0-100 触发概率
    var rawJSONData: Data?
    var selectiveEnabled: Bool?
    var useProbability: Bool?

    // MARK: - Enums

    enum SelectiveLogic: Int, Codable, Hashable {
        case andAny  = 0    // 主词命中 AND 至少一个次词命中
        case notAll  = 1    // 主词命中 AND 非全部次词命中
        case notAny  = 2    // 主词命中 AND 无次词命中
        case andAll  = 3    // 主词命中 AND 全部次词命中
    }

    enum InsertionPosition: Int, Codable, Hashable {
        case unsupported    = -1    // 原位置留 raw，不注入
        case beforeCharDef  = 0     // 角色描述之前
        case afterCharDef   = 1     // 角色描述之后
        case authorNoteTop  = 2     // Author's Note 顶部
        case authorNoteBot  = 3     // Author's Note 底部
        case atDepth        = 4     // 对话历史指定深度
        case beforeExamples = 5     // 对话示例之前
        case afterExamples  = 6     // 对话示例之后
    }
}

// MARK: - 缺键兼容（旧 entriesData）

extension WorldBookEntry {
    enum CodingKeys: String, CodingKey {
        case id, isEnabled, keys, secondaryKeys, selectiveLogic, scanDepth
        case matchWholeWords, caseSensitive, isConstant, content, position, insertionOrder, depth
        case comment, probability, rawJSONData, selectiveEnabled, useProbability
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        keys = try c.decodeIfPresent([String].self, forKey: .keys) ?? []
        secondaryKeys = try c.decodeIfPresent([String].self, forKey: .secondaryKeys) ?? []
        selectiveLogic = try c.decodeIfPresent(SelectiveLogic.self, forKey: .selectiveLogic) ?? .andAny
        scanDepth = try c.decodeIfPresent(Int.self, forKey: .scanDepth)
        matchWholeWords = try c.decodeIfPresent(Bool.self, forKey: .matchWholeWords) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        isConstant = try c.decodeIfPresent(Bool.self, forKey: .isConstant) ?? false
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        position = try c.decodeIfPresent(InsertionPosition.self, forKey: .position) ?? .afterCharDef
        insertionOrder = try c.decodeIfPresent(Int.self, forKey: .insertionOrder) ?? 100
        depth = try c.decodeIfPresent(Int.self, forKey: .depth)
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        probability = try c.decodeIfPresent(Int.self, forKey: .probability) ?? 100
        rawJSONData = try c.decodeIfPresent(Data.self, forKey: .rawJSONData)
        selectiveEnabled = try c.decodeIfPresent(Bool.self, forKey: .selectiveEnabled)
        useProbability = try c.decodeIfPresent(Bool.self, forKey: .useProbability)
    }
}

// MARK: - World Book (SwiftData Model)

@Model
final class WorldBook {
    #if os(iOS)
    #Index<WorldBook>([\.profileId])
    #endif

    @Attribute(.unique) var id: UUID = UUID()
    var name: String
    var profileId: String                            // 所属楼层
    var scopeConversationId: String?                 // nil=楼层全体，有值=仅该对话生效
    var entriesData: Data                            // JSON encoded [WorldBookEntry]
    var rawJSONData: Data?                           // 导入的整本原文
    var isEnabled: Bool = true                       // 整本开关（⑥）；关掉的书扫描时跳过
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 解码条目列表
    var entries: [WorldBookEntry] {
        get {
            (try? JSONDecoder().decode([WorldBookEntry].self, from: entriesData)) ?? []
        }
        set {
            entriesData = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }

    init(name: String, profileId: String, entries: [WorldBookEntry] = []) {
        self.name = name
        self.profileId = profileId
        self.entriesData = (try? JSONEncoder().encode(entries)) ?? Data()
    }
}
