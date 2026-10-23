import Foundation

/// 单个模型的官方参考价（USD per 1M tokens）。
/// 缓存读写价：models.dev 有就用；没有按输入价 0.1× / 1.25×（Anthropic 官方口径）。
struct ModelPricing: Equatable, Codable, Sendable {
    let inputUSDPerMTok: Double
    let outputUSDPerMTok: Double
    var cacheReadUSDPerMTok: Double? = nil
    var cacheWriteUSDPerMTok: Double? = nil
    var cacheWrite1hUSDPerMTok: Double? = nil
    var webSearchUSDPerCall: Double? = nil
    var tiers: [Tier]? = nil
    var priceVersion: String? = nil
    var missingInputPrice: Bool? = nil
    var missingOutputPrice: Bool? = nil
    var cachedDimensionsUnknown: Bool? = nil
    var additionalPriceUnknown: Bool? = nil

    struct Tier: Equatable, Codable, Sendable {
        let aboveInputTokens: Int
        let pricing: ModelPricing
    }

    struct Cost: Equatable, Sendable {
        let usd: Double
        let partial: Bool
    }

    init(_ input: Double, _ output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil,
         cacheWrite1h: Double? = nil, webSearch: Double? = nil, tiers: [Tier]? = nil,
         priceVersion: String? = "builtin-2026-10", additionalPriceUnknown: Bool = false) {
        self.inputUSDPerMTok = input
        self.outputUSDPerMTok = output
        self.cacheReadUSDPerMTok = cacheRead
        self.cacheWriteUSDPerMTok = cacheWrite
        self.cacheWrite1hUSDPerMTok = cacheWrite1h
        self.webSearchUSDPerCall = webSearch
        self.tiers = tiers
        self.priceVersion = priceVersion
        self.additionalPriceUnknown = additionalPriceUnknown ? true : nil
    }

    var effectiveCacheReadUSDPerMTok: Double { cacheReadUSDPerMTok ?? inputUSDPerMTok * 0.1 }
    var effectiveCacheWriteUSDPerMTok: Double { cacheWriteUSDPerMTok ?? inputUSDPerMTok * 1.25 }

    /// cache-aware 费用。promptTokens = 归一化总 prompt（含缓存读写部分）。
    func cost(promptTokens: Int, completionTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int,
              cacheWrite1hTokens: Int = 0, webSearches: Int = 0) -> Double {
        evaluatedCost(promptTokens: promptTokens, completionTokens: completionTokens,
                      cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
                      cacheWrite1hTokens: cacheWrite1hTokens, webSearches: webSearches).usd
    }

    func evaluatedCost(promptTokens: Int, completionTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int,
                       cacheWrite1hTokens: Int = 0, webSearches: Int = 0) -> Cost {
        let rate = (tiers ?? []).filter { promptTokens > $0.aboveInputTokens }
            .max { $0.aboveInputTokens < $1.aboveInputTokens }?.pricing ?? self
        let read = max(0, cacheReadTokens)
        let write = max(0, cacheWriteTokens)
        let oneHour = min(write, max(0, cacheWrite1hTokens))
        let fresh = max(0, promptTokens - read - write)
        let usd = (Double(fresh) * rate.inputUSDPerMTok
            + Double(read) * rate.effectiveCacheReadUSDPerMTok
            + Double(write - oneHour) * rate.effectiveCacheWriteUSDPerMTok
            + Double(oneHour) * (rate.cacheWrite1hUSDPerMTok ?? rate.inputUSDPerMTok * 2)
            + Double(max(0, completionTokens)) * rate.outputUSDPerMTok) / 1_000_000
            + Double(max(0, webSearches)) * (rate.webSearchUSDPerCall ?? webSearchUSDPerCall ?? 0)
        let partial = cachedDimensionsUnknown == true || additionalPriceUnknown == true || (webSearches > 0 && rate.webSearchUSDPerCall == nil && webSearchUSDPerCall == nil)
            || (promptTokens > 0 && rate.missingInputPrice == true)
            || (completionTokens > 0 && rate.missingOutputPrice == true)
        return Cost(usd: usd, partial: partial)
    }

    // 价格目录的现有缓存格式不扩展；新维度只驻内存，金额与版本在 usage.jsonl 冻结。
    private enum CodingKeys: String, CodingKey {
        case inputUSDPerMTok, outputUSDPerMTok, cacheReadUSDPerMTok, cacheWriteUSDPerMTok
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(Double.self, forKey: .inputUSDPerMTok),
                  try c.decode(Double.self, forKey: .outputUSDPerMTok),
                  cacheRead: try c.decodeIfPresent(Double.self, forKey: .cacheReadUSDPerMTok),
                  cacheWrite: try c.decodeIfPresent(Double.self, forKey: .cacheWriteUSDPerMTok), priceVersion: nil)
        cachedDimensionsUnknown = true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputUSDPerMTok, forKey: .inputUSDPerMTok)
        try c.encode(outputUSDPerMTok, forKey: .outputUSDPerMTok)
        try c.encodeIfPresent(cacheReadUSDPerMTok, forKey: .cacheReadUSDPerMTok)
        try c.encodeIfPresent(cacheWriteUSDPerMTok, forKey: .cacheWriteUSDPerMTok)
    }

}

enum PricingCatalog {
    /// 查价：models.dev 目录优先（`ModelCatalog`），目录没有再查下面的手写表（首次无网的离线兜底）。
    /// **查不到返回 nil = 不知道**（research-magpie 2.5），不再给 fallback 价；调用方自己决定怎么处理
    /// （保险闸按 `budgetFallback` 保守估，显示 / 账本记「未计价」）。
    /// 目录里只有中转 / 聚合商收录的旧模型（一方已下架），手写表的官方价比中转价可信 → 排在它们前面。
    static func price(for modelId: String, catalog: ModelCatalog = .shared) -> ModelPricing? {
        let entry = catalog.model(for: modelId)
        if let entry, let p = entry.pricing, ModelCatalog.preferredProviders.contains(entry.providerId) { return p }
        return builtinPrice(for: modelId) ?? entry?.pricing
    }

    /// 手写表查价。前缀/包含模糊匹配，支持 "anthropic/claude-sonnet-4-5" 或 "custom/claude-sonnet-4-5"
    /// 这类中转站写法，剥离 vendor 前缀后找表。
    static func builtinPrice(for modelId: String) -> ModelPricing? {
        let lower = modelId.lowercased()
        // 先尝试精确匹配
        if let exact = table[lower] { return exact }
        // 再尝试去掉 vendor/ 前缀后匹配
        if let slash = lower.firstIndex(of: "/") {
            let stripped = String(lower[lower.index(after: slash)...])
            if let m = table[stripped] { return m }
            // 按前缀匹配表里的键
            for key in table.keys.sorted(by: { $0.count > $1.count }) where stripped.hasPrefix(key) {
                return table[key]
            }
        }
        // 最后按 contains 匹配表里键
        for key in table.keys.sorted(by: { $0.count > $1.count }) where lower.contains(key) {
            return table[key]
        }
        return nil
    }

    /// 公开价格表（USD per 1M tokens）。数值取自各家 2026-10 官方公开价（Anthropic / OpenAI 官方 pricing，models.dev 交叉核对），供保险闸粗估。
    /// 实际扣费按响应的 usage 回填，不依赖这里的绝对精确。
    private static let table: [String: ModelPricing] = [
        // 2026-10 新型号：缓存价与长上下文价一起兜底。
        "claude-opus-5": ModelPricing(5, 25, cacheRead: 0.5, cacheWrite: 6.25, webSearch: 0.01),
        "claude-sonnet-5": ModelPricing(2, 10, cacheRead: 0.2, cacheWrite: 2.5, webSearch: 0.01),
        "claude-opus-5-5": ModelPricing(4, 20, cacheRead: 0.2, cacheWrite: 5, webSearch: 0.01),
        "claude-sonnet-5-5": ModelPricing(2, 10, cacheRead: 0.1, cacheWrite: 2.5, webSearch: 0.01),
        "claude-haiku-5-5": ModelPricing(0.1, 0.5, cacheRead: 0.01, cacheWrite: 0.125, webSearch: 0.01, tiers: [.init(aboveInputTokens: 100000, pricing: ModelPricing(0.5, 2.5, cacheRead: 0.05, cacheWrite: 0.625))]),
        "claude-opus-4-5": ModelPricing(5, 25, cacheRead: 0.5, cacheWrite: 6.25, webSearch: 0.01),
        "claude-opus-4-8": ModelPricing(5, 25, cacheRead: 0.5, cacheWrite: 6.25, webSearch: 0.01),
        "gpt-6.1-sol": ModelPricing(2, 10, cacheRead: 0.1, cacheWrite: 2.5, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(4, 15, cacheRead: 0.2, cacheWrite: 5))]),
        "gpt-6-astra": ModelPricing(10, 50, cacheRead: 1, cacheWrite: 12.5, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(20, 75, cacheRead: 2, cacheWrite: 25))]),
        "gpt-6-luna": ModelPricing(0.1, 0.5, cacheRead: 0.01, cacheWrite: 0.125, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(0.2, 0.75, cacheRead: 0.02, cacheWrite: 0.25))]),
        "gpt-6-sol": ModelPricing(2, 10, cacheRead: 0.2, cacheWrite: 2.5, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(4, 15, cacheRead: 0.4, cacheWrite: 5))]),
        "gpt-5.6-sol": ModelPricing(4, 20, cacheRead: 0.4, cacheWrite: 5, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(8, 30, cacheRead: 0.8, cacheWrite: 10))]),
        "gpt-5.6-terra": ModelPricing(2, 12, cacheRead: 0.2, cacheWrite: 2.5, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(4, 18, cacheRead: 0.4, cacheWrite: 5))]),
        "gpt-5.6-luna": ModelPricing(0.2, 1.2, cacheRead: 0.02, cacheWrite: 0.25, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(0.4, 1.8, cacheRead: 0.04, cacheWrite: 0.5))]),
        "gpt-5.5": ModelPricing(5, 30, cacheRead: 0.5, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(10, 45, cacheRead: 1))]),
        "gpt-5.4": ModelPricing(2.5, 15, cacheRead: 0.25, tiers: [.init(aboveInputTokens: 272000, pricing: ModelPricing(5, 22.5, cacheRead: 0.5))]),
        "gpt-5": ModelPricing(1.25, 10, cacheRead: 0.125),
        "gpt-5-mini": ModelPricing(0.25, 2, cacheRead: 0.025),
        "gpt-5-nano": ModelPricing(0.05, 0.4, cacheRead: 0.005),

        // Anthropic
        "claude-opus-4-7":           ModelPricing(5, 25, cacheRead: 0.5, cacheWrite: 6.25, webSearch: 0.01),
        "claude-opus-4-6":           ModelPricing(5, 25, cacheRead: 0.5, cacheWrite: 6.25, webSearch: 0.01),
        "claude-opus-4-0":           ModelPricing(15, 75),
        "claude-opus-4":             ModelPricing(15, 75),
        "claude-sonnet-4-6":         ModelPricing(3, 15, cacheRead: 0.3, cacheWrite: 3.75, webSearch: 0.01),
        "claude-sonnet-4-5":         ModelPricing(3, 15, cacheRead: 0.3, cacheWrite: 3.75, webSearch: 0.01),
        "claude-sonnet-4-0":         ModelPricing(3, 15),
        "claude-sonnet-4":           ModelPricing(3, 15),
        "claude-haiku-4-5":          ModelPricing(1, 5, cacheRead: 0.1, cacheWrite: 1.25, webSearch: 0.01),
        "claude-haiku-4":            ModelPricing(0.8, 4),
        "claude-3-7-sonnet":         ModelPricing(3, 15),
        "claude-3-5-haiku":          ModelPricing(0.8, 4),

        // OpenAI
        "gpt-4o":                    ModelPricing(2.5, 10, cacheRead: 1.25),
        "gpt-4o-mini":               ModelPricing(0.15, 0.6, cacheRead: 0.075),
        "gpt-4.1":                   ModelPricing(2, 8, cacheRead: 0.5),
        "gpt-4.1-mini":              ModelPricing(0.4, 1.6, cacheRead: 0.1),
        "gpt-4.1-nano":              ModelPricing(0.1, 0.4, cacheRead: 0.025),
        "o3":                        ModelPricing(2, 8, cacheRead: 0.5),
        "o3-mini":                   ModelPricing(1.1, 4.4, cacheRead: 0.55),
        "o4-mini":                   ModelPricing(1.1, 4.4, cacheRead: 0.275),

        // DeepSeek：当前型号按官方 off-peak 基础部分列价；峰时 / 中国节假日维度未覆盖，标 partial。
        "deepseek-flash":            ModelPricing(0.15, 0.6, cacheRead: 0.003, additionalPriceUnknown: true),
        "deepseek-v4-flash":         ModelPricing(0.15, 0.6, cacheRead: 0.003, additionalPriceUnknown: true),
        "deepseek-v4-flash-vision-exp": ModelPricing(0.15, 0.6, cacheRead: 0.003, additionalPriceUnknown: true),
        "deepseek-v4-pro":           ModelPricing(0.66, 1.98, cacheRead: 0.022, additionalPriceUnknown: true),
        // 旧官方别名已退役，保留历史参考价供旧账本估算，不映射到 V4 的当前价。
        "deepseek-chat":             ModelPricing(0.27, 1.1),
        "deepseek-reasoner":         ModelPricing(0.55, 2.19),

        // Google Gemini
        "gemini-2.5-pro":            ModelPricing(1.25, 10, cacheRead: 0.125, tiers: [.init(aboveInputTokens: 200000, pricing: ModelPricing(2.5, 15, cacheRead: 0.25))]),
        "gemini-2.5-flash":          ModelPricing(0.3, 2.5, cacheRead: 0.03),

        // xAI Grok
        "grok-3":                    ModelPricing(3, 15),
        "grok-3-mini":               ModelPricing(0.3, 0.5),

        // Groq / Llama etc. — 给个保守价
        "llama-3.3-70b-versatile":   ModelPricing(0.59, 0.79),
        "llama-3.1-8b-instant":      ModelPricing(0.05, 0.08),
    ]

    /// **只给保险闸用**：查不到价时按这个保守偏贵的价估，防止 runaway 烧钱。显示 / 账本不用它。
    static let budgetFallback = ModelPricing(3, 15)
}
