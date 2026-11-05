import Foundation

extension SamplingParams {
    /// 老数据（nil）：正好 4096 = 当年的默认值，按「自动」解读；其他数是她设过的，按手动
    var isMaxTokensAuto: Bool { maxTokensAuto ?? (maxTokens == 4096) }
}

/// 输出上限（plan-output-token-cap）：发送、预览、保险闸、设置页共用的一组纯函数。
/// provider 层只看解析后的 `maxTokens`，永远是一个确定的数。
enum OutputTokenCap {
    static let autoCeiling = 32_768
    static let fallback = 16_384
    static let budgetExpected = 4_096
    static let retryCap = 8_192

    static func modelLimit(_ modelId: String) -> Int? {
        guard let n = ModelCatalog.shared.model(for: modelId)?.outputTokens, n > 0 else { return nil }
        return n
    }

    static func visibleCap(_ s: SamplingParams, limit: Int?) -> Int {
        if s.isMaxTokensAuto { return min(limit ?? fallback, autoCeiling) }
        return max(1, min(s.maxTokens, limit ?? .max))
    }

    static func resolved(_ s: SamplingParams, modelId: String) -> SamplingParams {
        var r = s
        r.maxTokens = visibleCap(s, limit: modelLimit(modelId))
        r.maxTokensAuto = false
        return r
    }

    /// 保险闸按「期望输出」预估，不按上限全额；Claude 开思考时加这一档余量（thinking 回传 Q9-A，宁可多估）
    static func budgetEstimate(_ s: SamplingParams, modelId: String) -> Int {
        min(visibleCap(s, limit: modelLimit(modelId)), budgetExpected) + thinkingHeadroom(effort: s.reasoningEffort, modelId: modelId)
    }

    /// Claude 会想的那部分输出：选了档 = 这一档余量；「默认」档 + 默认就会想的模型 = 官方默认档的余量；其余 0
    static func thinkingHeadroom(effort: String, modelId: String) -> Int {
        guard ModelLineage.classify(modelId)?.vendor == .anthropic else { return 0 }
        if let tier = ReasoningEffort.headroom(effort) { return tier }
        guard effort == ReasoningEffort.auto, ModelLineage.thinksByDefault(modelId) else { return 0 }
        return ReasoningEffort.headroom(ModelLineage.defaultEffort(modelId)) ?? 0
    }

    /// Anthropic：thinking 预算加在可见上限之上，不再从里面扣；总数不超过模型上限，预算不足 1024 就不开 thinking
    static func anthropicLimits(visible: Int, effort: String, limit: Int?) -> (maxTokens: Int, thinkingBudget: Int?) {
        let cap = limit ?? .max
        let tier: Int
        switch effort {
        case "low": tier = 1024
        case "medium": tier = 4096
        case "high": tier = 10000
        default: return (min(visible, cap), nil)
        }
        let total = min(visible + tier, cap)
        let budget = min(tier, total - 1024)
        guard budget >= 1024 else { return (min(visible, cap), nil) }
        return (total, budget)
    }

    /// R2 按 max_tokens 预扣被拒：看实发上限（Anthropic 含思考余量）。实发不超过 8192 = 不重发（nil）。
    /// 重发让实发 ≤ 8192：可见上限只降不升；带着思考时余量占不下（high 及以上 / 默认档）就压到 low，budget_tokens 仍小于 max_tokens
    static func prepaidRetry(_ s: SamplingParams, sentMaxTokens: Int) -> SamplingParams? {
        guard sentMaxTokens > retryCap else { return nil }
        var r = s
        guard sentMaxTokens > s.maxTokens else {
            r.maxTokens = min(s.maxTokens, retryCap)
            return r
        }
        let low = ReasoningEffort.headroom("low") ?? 1024
        var tier = ReasoningEffort.headroom(s.reasoningEffort) ?? retryCap
        if retryCap - tier < low {
            r.reasoningEffort = "low"
            tier = low
        }
        r.maxTokens = min(s.maxTokens, retryCap - tier)
        return r
    }

    /// 说的是思考预算比上限大（R4）不算：那是要压预算，不是降上限
    static func mentionsOutputLimit(_ message: String) -> Bool {
        let m = message.lowercased()
        guard !ParamErrorClassifier.mentionsThinkingBudget(m) else { return false }
        return m.contains("max_tokens") || m.contains("max_completion_tokens") || m.contains("max_output_tokens")
    }

    static func annotateLimitError(_ message: String, cap: Int?) -> String {
        guard let cap, mentionsOutputLimit(message) else { return message }
        return message + "\n（本次输出上限 \(cap) 可能超出了这个模型允许的范围，可以在预设里把 Max Tokens 改成手动、调小一点）"
    }
}
