import Foundation

/// 模型自己掷骰子（粟粟 09-26）：真随机，结果回给模型，模型把返回的卡片块原样放进回复。
/// 输入规则与 cc-bridge/dice.ts 一致（plan-chat-cards-dice-tool v1.1 I1）：
/// dice / title 给了就必须是字符串，options 给了就必须是字符串数组；首尾空白含换行都去掉；
/// 去空白后为空的 dice / options 视为没给；两个都有、两个都没有都报错。
enum DiceTool {
    static let toolName = "roll_dice"

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "掷骰子或从选项里随机抽一个（真随机）。给 dice（如 \"2d6+1\"、\"d20\"：N 颗 M 面，N 1–20，M 2–1000，修正值不超过 1000）或 options（至少 2 个选项）二选一，可加 title；替对方掷已有的骰子卡时再给那张卡的 id。返回一段 card-dice 代码块和一行结果摘要——把代码块原样放进你的回复，对方会看到一张带结果的骰子卡。不要自己编结果。",
            properties: [
                "dice": ["type": "string", "description": "骰子表达式，如 2d6+1、d20"],
                "options": ["type": "array", "items": ["type": "string"], "description": "抽签选项（至少 2 个）"],
                "title": ["type": "string", "description": "卡片标题，可空"],
                "id": ["type": "string", "description": "替对方掷已有的骰子卡时填它的 id（d- 开头）；新掷不填"],
            ],
            required: []
        )
    }

    /// 替对方掷已有的卡时沿用它的 id（终审 I2）；与 cc-bridge/dice.ts CARD_ID 同规则
    private static let cardIdPattern = #/^d-[0-9A-Za-z_-]{1,32}$/#

    private enum Field<T> { case absent, value(T), invalid }

    private static func string(_ args: [String: Any], _ key: String) -> Field<String> {
        guard let raw = args[key] else { return .absent }
        if raw is NSNull { return .invalid }
        guard let s = raw as? String else { return .invalid }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .absent : .value(trimmed)
    }

    private static func strings(_ args: [String: Any], _ key: String) -> Field<[String]> {
        guard let raw = args[key] else { return .absent }
        guard let array = raw as? [Any] else { return .invalid }
        var out: [String] = []
        for item in array {
            guard let s = item as? String, !(item is NSNumber) else { return .invalid }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out.isEmpty ? .absent : .value(out)
    }

    static func execute(inputJSON: String, using rng: inout some RandomNumberGenerator, takenIds: Set<String>) -> (text: String, isError: Bool) {
        // 无参调用（有的 provider 发空串）按 {} 处理，与 CC 端同文案
        let raw = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : inputJSON
        guard let data = raw.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ("参数不是合法 JSON 对象", true)
        }
        let title: String
        switch string(args, "title") {
        case .invalid: return ("title 必须是字符串", true)
        case .absent: title = ""
        case .value(let t): title = t
        }
        let givenId: String?
        switch string(args, "id") {
        case .invalid: return ("id 必须是 d- 开头的骰子卡 id（替对方掷已有的卡时才给）", true)
        case .absent: givenId = nil
        case .value(let v):
            guard v.wholeMatch(of: cardIdPattern) != nil else { return ("id 必须是 d- 开头的骰子卡 id（替对方掷已有的卡时才给）", true) }
            givenId = v
        }
        let dice = string(args, "dice")
        let options = strings(args, "options")
        let card: DiceCard
        switch (dice, options) {
        case (.invalid, _): return ("dice 必须是字符串", true)
        case (_, .invalid): return ("options 必须是字符串数组", true)
        case (.value, .value): return ("dice 和 options 只能给一个", true)
        case (.absent, .absent): return ("要给 dice 或 options", true)
        case (.value(let expr), .absent):
            guard DiceExpression.parse(expr) != nil else {
                return ("骰子表达式不合法：\(expr)（格式 NdM±K，N 1–20，M 2–1000，K ≤ 1000）", true)
            }
            card = DiceCard(id: givenId ?? ChatCard.newId(prefix: "d", avoiding: takenIds), title: title, dice: expr, options: nil, result: nil)
        case (.absent, .value(let opts)):
            guard opts.count >= 2 else { return ("options 至少要 2 个", true) }
            card = DiceCard(id: givenId ?? ChatCard.newId(prefix: "d", avoiding: takenIds), title: title, dice: nil, options: opts, result: nil)
        }
        guard let rolled = DiceRoller.roll(card, using: &rng), let result = rolled.result else { return ("掷骰失败", true) }
        let summary: String
        if let rolls = result.rolls, let total = result.total, let expr = rolled.dice {
            let mod = DiceExpression.parse(expr)?.modifier ?? 0
            let parts = rolls.map(String.init) + (mod == 0 ? [] : [mod > 0 ? "\(mod)" : "(\(mod))"])
            summary = "\(expr) → \(parts.joined(separator: " + ")) = \(total)"
        } else if let pick = rolled.validPick, let opts = rolled.options {
            summary = "抽中：\(opts[pick])"
        } else {
            return ("掷骰失败", true)
        }
        // 卡片块原文 + 空行 + 摘要：模型把第一段原样放进回复即可，不必解 JSON（终审 I1）
        return ("\(ChatCard.dice(rolled).blockText)\n\n\(summary)", false)
    }
}
