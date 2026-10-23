import Foundation

/// 骰子表达式 NdM(+/-K)：N 1–20，M 2–1000，|K| ≤ 1000；N 省略视为 1（research-chat-cards §8.1）
struct DiceExpression: Equatable {
    let count: Int
    let sides: Int
    let modifier: Int

    private static let pattern = try! NSRegularExpression(pattern: #"^(\d{0,2})d(\d{1,4})(?:([+-])(\d{1,4}))?$"#, options: .caseInsensitive)

    static func parse(_ s: String) -> DiceExpression? {
        let compact = s.replacingOccurrences(of: " ", with: "")
        let ns = compact as NSString
        guard let m = pattern.firstMatch(in: compact, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let countText = ns.substring(with: m.range(at: 1))
        guard let count = countText.isEmpty ? 1 : Int(countText),
              let sides = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        var modifier = 0
        if m.range(at: 3).location != NSNotFound {
            guard let k = Int(ns.substring(with: m.range(at: 4))), k <= 1000 else { return nil }
            modifier = ns.substring(with: m.range(at: 3)) == "-" ? -k : k
        }
        guard (1...20).contains(count), (2...1000).contains(sides) else { return nil }
        return DiceExpression(count: count, sides: sides, modifier: modifier)
    }
}

enum DiceRoller {
    /// 掷不了时的原因（卡上显示这句，不再留一个点了没反应的「掷」，§8.6-4）；能掷 → nil
    static func problem(_ card: DiceCard) -> String? {
        if let text = card.dice {
            return DiceExpression.parse(text) == nil ? "骰子写法看不懂：\(text)（例：2d6+1、d20）" : nil
        }
        return (card.options ?? []).isEmpty ? "没有可抽的选项" : nil
    }

    /// 掷一次：返回带结果的同 id 新卡；数字骰优先，其次选项；都无效 → nil
    static func roll(_ card: DiceCard, using rng: inout some RandomNumberGenerator) -> DiceCard? {
        var next = card
        if let text = card.dice {
            guard let expr = DiceExpression.parse(text) else { return nil }
            let rolls = (0..<expr.count).map { _ in Int.random(in: 1...expr.sides, using: &rng) }
            next.result = DiceResult(rolls: rolls, total: rolls.reduce(0, +) + expr.modifier, pick: nil)
            return next
        }
        if let options = card.options, !options.isEmpty {
            next.result = DiceResult(rolls: nil, total: nil, pick: Int.random(in: 0..<options.count, using: &rng))
            return next
        }
        return nil
    }
}
