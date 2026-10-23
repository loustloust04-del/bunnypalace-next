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

    /// 保险闸按「期望输出」预估，不按上限全额
    static func budgetEstimate(_ s: SamplingParams, modelId: String) -> Int {
        min(visibleCap(s, limit: modelLimit(modelId)), budgetExpected)
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

    static func mentionsOutputLimit(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("max_tokens") || m.contains("max_completion_tokens") || m.contains("max_output_tokens")
    }

    static func annotateLimitError(_ message: String, cap: Int?) -> String {
        guard let cap, mentionsOutputLimit(message) else { return message }
        return message + "\n（本次输出上限 \(cap) 可能超出了这个模型允许的范围，可以在预设里把 Max Tokens 改成手动、调小一点）"
    }
}
