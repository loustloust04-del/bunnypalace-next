import Foundation

/// 保险闸用的 token 粗估器协议（和 PromptPostProcessor 里的 TokenEstimator 区分）。
protocol BudgetTokenEstimator {
    func estimate(_ text: String) -> Int
}

/// 轻量启发式：CJK 字符 × 1.0；非 CJK × (1/3.5)。
/// 符合 Anthropic 官方"1 token ≈ 3.5 英文字符"的经验值；中文每字常约 1 token。
/// 误差 ±15-25%，给保险闸 pre-send 估算够用。精算靠响应 usage 字段回填。
struct HeuristicEstimator: BudgetTokenEstimator {
    func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return cjk + Int(ceil(Double(other) / 3.5))
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)         // CJK Unified
            || (0x3400...0x4DBF).contains(v)         // CJK Extension A
            || (0x20000...0x2A6DF).contains(v)       // CJK Extension B
            || (0x3000...0x303F).contains(v)         // CJK Symbols & Punctuation
            || (0xFF00...0xFFEF).contains(v)         // Halfwidth/Fullwidth
            || (0x3040...0x309F).contains(v)         // Hiragana
            || (0x30A0...0x30FF).contains(v)         // Katakana
            || (0xAC00...0xD7AF).contains(v)         // Hangul
    }
}
