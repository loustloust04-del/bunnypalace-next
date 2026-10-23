import Foundation

enum UsageCompleteness: String, Codable, Sendable {
    case complete, snapshot, missing
}

/// API 响应里回传的 token 计数。流式要合并多个 event 取最终值。
struct TokenUsage: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    /// prompt cache 命中读取的 token 数（Anthropic cache_read_input_tokens / OAI cached_tokens）。nil = 响应没带
    var cacheReadTokens: Int? = nil
    /// prompt cache 写入的 token 数（Anthropic cache_creation_input_tokens；OAI 无此概念）
    var cacheWriteTokens: Int? = nil
    /// 推理 token（OAI completion_tokens_details.reasoning_tokens / Responses output_tokens_details），已含在 outputTokens 里
    var reasoningTokens: Int? = nil
    var reportedCostUSD: Double? = nil
    var cacheWrite1hTokens: Int? = nil
    var webSearches: Int? = nil
    var responseId: String? = nil
    /// Router 记账时冻结的同一金额，供 footer / 预算读取。
    var ledgerCostUSD: Double? = nil
    var ledgerCostRecorded = false
    var ledgerSpendRecorded = false
    var ledgerRecord: UsageRecord? = nil
    var completeness: UsageCompleteness = .complete
}

/// 预算保险闸的门控结果。
enum BudgetGate: Equatable {
    case ok
    /// 当前花费占比已过警戒线（0.8-0.99）
    case warning(percent: Double, spent: Double, budget: Double)
    /// 已用完或本次估算会超额
    case blocked(spent: Double, budget: Double)
    /// 放行且不计闸：开关未启用
    case disabled
}

/// 卡片心智重构后（D1 清理）：每个 credential 的 ratio 字段已删，公式不再乘任何 per-credential 系数。
/// `credential` 参数保留只为签名兼容上游调用，内部仅取 modelId 查 PricingCatalog。
enum BudgetCalculator {
    /// 发送前粗估。output 按调用方给的期望输出估（OutputTokenCap.budgetEstimate）。
    static func estimateCost(
        provider: APICredential,
        modelId: String,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        maxOutputTokens: Int,
        estimator: BudgetTokenEstimator
    ) -> Double {
        var input = ""
        if let sp = systemPrompt, !sp.isEmpty { input += sp + "\n" }
        input += messages.map(\.content).joined(separator: "\n")
        let inputTokens = estimator.estimate(input)
        return rawCost(
            modelId: modelId,
            inputTokens: Double(inputTokens),
            outputTokens: Double(max(0, maxOutputTokens))
        )
    }

    /// 发送后按真实 usage 精算。
    static func actualCost(
        provider: APICredential,
        modelId: String,
        usage: TokenUsage
    ) -> Double {
        if usage.ledgerCostRecorded { return usage.ledgerCostUSD ?? 0 }
        return UsageRecord(provider: provider, modelId: modelId, usage: usage,
                           started: Date(), ended: Date(), status: .ok, context: UsageContext()).costUSD
            ?? rawCost(modelId: modelId, inputTokens: Double(usage.inputTokens), outputTokens: Double(usage.outputTokens))
    }

    /// 检查全局保险闸是否放行 estimatedCost。粟粟决策（2026-04-23）：
    /// 水库总闸门，无论哪个 provider 哪个 model 的调用都汇总到 GlobalBudgetStore。
    static func gate(estimatedCost: Double) -> BudgetGate {
        let store = GlobalBudgetStore.shared
        return gate(
            enabled: store.enabled,
            isBudgetSet: store.isBudgetSet,
            budgetUSD: store.budgetUSD,
            spentUSD: store.spentUSD,
            estimatedCost: estimatedCost
        )
    }

    /// 纯函数版（单例读不进测试，判定全在这里；上面那个只负责把单例的三个值喂进来）。
    static func gate(
        enabled: Bool,
        isBudgetSet: Bool,
        budgetUSD budget: Double,
        spentUSD spent: Double,
        estimatedCost: Double
    ) -> BudgetGate {
        guard enabled else { return .disabled }
        // **从未拨款 = 按默认额度计闸**（BUG-1，粟粟 08-27 拍 10 美元）。不能靠 `budget <= 0`
        // 判「未拨款」——UserDefaults 对不存在的 key 就返回 0，全新安装会被自己的保险闸拦死。
        let budget = isBudgetSet ? budget : GlobalBudgetStore.defaultBudgetUSD
        // 明确填了 0 = 「全停」，照拦（默认额度是 10，走不到这里）
        if budget <= 0 {
            return .blocked(spent: spent, budget: budget)
        }
        if spent + estimatedCost >= budget {
            return .blocked(spent: spent, budget: budget)
        }
        let percent = (spent + estimatedCost) / budget
        if percent >= 0.8 {
            return .warning(percent: percent, spent: spent, budget: budget)
        }
        return .ok
    }

    /// 显示用 cache-aware 费用（每条消息 footer / 仪表盘）。
    /// 不进预算——粟粟批注（2026-06-11）：预算扣费等精算+缓存自动路由一起再动。
    /// 缓存读写价 models.dev 有就用，没有按输入价 0.1× / 1.25×（`ModelPricing.cost`）。
    /// 查不到价返回 nil（不知道），不拿兜底价冒充。
    static func displayCost(
        provider: APICredential,
        modelId: String,
        promptTokens: Int,        // 归一化总 prompt（含缓存部分）
        completionTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double? {
        guard let pricing = PricingCatalog.price(for: modelId) else { return nil }
        return pricing.cost(promptTokens: promptTokens, completionTokens: completionTokens,
                            cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
    }

    /// 缓存命中省下的钱（显示用）：命中部分按全价算 vs 实际缓存读价，差额即节省；查不到价 = 0
    static func displaySavings(provider: APICredential, modelId: String, cacheReadTokens: Int) -> Double {
        guard cacheReadTokens > 0, let pricing = PricingCatalog.price(for: modelId) else { return 0 }
        return Double(cacheReadTokens) * (pricing.inputUSDPerMTok - pricing.effectiveCacheReadUSDPerMTok) / 1_000_000
    }

    // MARK: - Private

    private static func rawCost(
        modelId: String,
        inputTokens: Double,
        outputTokens: Double
    ) -> Double {
        // 保险闸宁可多估：查不到价按保守价（`price(for:)` 本身已不再兜底）
        let pricing = PricingCatalog.price(for: modelId) ?? PricingCatalog.budgetFallback
        let inputUSD = inputTokens / 1_000_000 * pricing.inputUSDPerMTok
        let outputUSD = outputTokens / 1_000_000 * pricing.outputUSDPerMTok
        return inputUSD + outputUSD
    }
}
