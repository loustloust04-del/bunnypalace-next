import Foundation

/// 改良粗算 token 估算器（原住 PromptPostProcessor.swift，PT1 删死代码时活体迁出——
/// S1 检查器/组装 tab 在用）。SC-B4 刀1 的"单一真源"候选。
struct TokenEstimator {
    /// 改良粗算：英文 ~4 字符/token，中文 ~1.5 字符/token
    /// 标注 ≈ 表示估算。未来可接 API 精确计数。
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var tokens: Double = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                tokens += 0.25  // 英文 ~4 chars/token
            } else {
                tokens += 1.5   // CJK ~1.5 tokens/char
            }
        }
        // JSON overhead: role/content keys, quotes, commas
        return max(Int(tokens.rounded(.up)), 1)
    }

    /// 估算 messages 列表的总 token
    static func estimate(systemPrompt: String?, messages: [(role: String, content: String)]) -> Int {
        var total = 0
        if let sys = systemPrompt { total += estimate(sys) + 4 } // system overhead
        for msg in messages {
            total += estimate(msg.content) + 4  // per-message overhead (role, delimiters)
        }
        total += 3  // request priming
        return total
    }
}
