import Foundation
import SwiftData

// MARK: - Memory (Atomic Fact)

@Model
final class Memory {
    #if os(iOS)
    #Index<Memory>(
        [\.profileId],
        [\.profileId, \.decayWeight],
        [\.profileId, \.updatedAt]
    )
    #endif

    @Attribute(.unique) var id: UUID = UUID()
    var content: String              // 原子事实："用户喜欢暖奶白配色"
    var category: String             // "preference" | "fact" | "relationship" | "goal" | "context"
    var keywords: [String]           // 预提取关键词，用于未来 BM25 检索
    var tokenCount: Int              // 粗算 token 数

    var accessCount: Int = 0         // 被注入/检索次数（强化信号）
    var lastAccessedAt: Date         // 上次被注入的时间
    var decayWeight: Double = 1.0    // 0.0–1.0，衰减权重
    var validUntil: Date?            // 可选时效性（过期自动降权）

    var sourceConversationId: String? // 来源对话 ID
    var extractedBy: String = ""     // 提取模型名
    var isUserExplicit: Bool = false // 用户手动创建 vs 自动提取

    // C2 归因（可选以轻量迁移；旧库不猜测、不回填）
    var subject: String? = nil       // 这条事实说的是谁 / 什么
    var speaker: String? = nil       // 用户自述 | AI 观察 | AI 承诺

    // SC-B2 出处锚 + 软失效
    var sourceQuote: String?         // 10-40 字逐字引用（机械校验过的出处证据）
    var sourceNodeId: String?        // 引用所在消息 node id（跳转锚）
    var supersededAt: Date?          // 软失效：nil=活着，有值=出排名不出库（可复活）

    // 召回卡片相关性反馈：累计 👎 数，≥2 触发软失效（isUserExplicit 豁免）
    var feedbackDownCount: Int = 0

    var profileId: String            // 楼层隔离
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // M2 向量检索
    var embeddingData: Data?         // 句向量 [Float32]，L2 已归一化
    var embeddingRevision: Int?      // 嵌入模型版本——不匹配的向量不参与比对（模型升级后重算）

    // M3 关系图谱：语义相近的记忆 id（对称边，每节点上限 5）
    var relatedIds: [UUID] = []

    // 预留（本轮不用）
    var parentId: UUID?              // 记忆层级（摘要的摘要）

    // v5 C2 碎片池（轻量迁移，四个可选字段；老条目都是 nil）
    var occurredDay: String?         // 发生在哪天 yyyy-MM-dd（05:00 日界，程序按出处消息时间算）
    var importance: Int?             // 1–5
    var emotion: Int?                // -2…2
    var resolved: Bool?              // 了结了没（nil = 说不上）

    // 审计台（轻量迁移，两个可选字段；老条目都是 nil）
    var reviewedAt: Date?            // 审过（留）；审计台改字 / 改类别也算
    var userEditedAt: Date?          // 你改过正文

    // C3 整理编目（轻量迁移，三个可选字段；老条目都是 nil）
    var organizedAt: Date?           // 整理过了：批了的提案用到了它，或分拣判「单条就够」
    var organizedPage: String?       // 整理进了哪一页（wiki 相对路径）；空 + organizedAt 有值 = 单条就够
    var organizeRejectedAt: Date?    // 整理时驳回，不再自动整理

    var isOrganized: Bool { organizedAt != nil }
    var isSingleEnough: Bool { organizedAt != nil && organizedPage == nil }

    /// v5 碎片池写的：只有 C2 写 occurredDay（`FragmentPool.write`，每条必写），手加 / 导入 / 改版前的都是 nil。
    /// 不看 importance：审计台谁都能拖重要度，拖了不能把老档案变成碎片池
    var isFragment: Bool { occurredDay != nil }

    /// 召回优先级 = 有效重要度（粟粟 10-17：「就是一个东西」）；召回加权、全量兜底排序、审计台滑条都读它（审计台卡片 plan ⧫5 / ⧫6）
    var recallPriority: Int { Self.effectiveImportance(importance) }

    /// 有效重要度：没定的按 3，库里越界的（老备份 / 手改库）先夹到 1–5 再用，`Int.min` / `Int.max` 也不溢出（10-17 astra #5）
    static func effectiveImportance(_ importance: Int?) -> Int { min(5, max(1, importance ?? 3)) }

    init(
        content: String,
        category: String,
        keywords: [String] = [],
        profileId: String,
        isUserExplicit: Bool = false,
        extractedBy: String = "",
        sourceConversationId: String? = nil
    ) {
        self.content = content
        self.category = category
        self.keywords = keywords
        self.tokenCount = Self.estimateTokens(content)
        self.lastAccessedAt = Date()
        self.profileId = profileId
        self.isUserExplicit = isUserExplicit
        self.extractedBy = extractedBy
        self.sourceConversationId = sourceConversationId
    }

    /// 粗算 token 数：中文字符 × 1.5，英文按空格分词
    static func estimateTokens(_ text: String) -> Int {
        var count = 0
        for char in text {
            if char.isASCII {
                if char == " " { count += 1 }
            } else {
                count += 2 // CJK 字符约 1.5 token，向上取整
            }
        }
        return max(count, 1)
    }
}
