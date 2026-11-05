import Foundation

/// 按血统认模型（#094 plan-param-autoadapt §3.1，抄 oh-my-pi pi-catalog `compat/taxonomy.ts` + `rules/taxonomy/{anthropic,openai}.kdl`）。
/// 不管走哪家端点（官方 / 中转 / OpenRouter / Bedrock），`claude-opus-4.7`、`anthropic/claude-opus-4-7`、
/// `us.anthropic.claude-opus-4-7-v1:0` 都认成 anthropic · opus · 4.7。只认 anthropic、openai 两类，其余返回 nil（认不出）。
enum ModelLineage {
    enum Vendor: Equatable { case anthropic, openai }

    struct Info: Equatable {
        var vendor: Vendor
        /// anthropic：opus / sonnet / haiku / fable / mythos，认不出家族是 "claude"；openai：gpt / o
        var family: String
        /// 版本段，如 [4, 7]；读不出是空
        var version: [Int]
    }

    static let anthropicFamilies = ["opus", "sonnet", "haiku", "fable", "mythos"]

    static func classify(_ modelId: String) -> Info? {
        let full = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !full.isEmpty else { return nil }
        let bare = full.split(separator: "/").last.map(String.init) ?? full
        let segments = full.split(whereSeparator: { "/.:".contains($0) }).map(String.init)
        let tokens = bare.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        let isAnthropic = segments.contains { bounded($0, "anthropic") || bounded($0, "claude") }
            || tokens.first.map(anthropicFamilies.contains) == true
        if isAnthropic {
            let family = tokens.first(where: anthropicFamilies.contains) ?? "claude"
            return Info(vendor: .anthropic, family: family, version: claudeVersion(bare))
        }

        if let first = bare.first, first == "o", bare.dropFirst().first?.isNumber == true {
            return Info(vendor: .openai, family: "o", version: readVersion(bare.dropFirst()))
        }
        let isOpenAI = ["gpt-", "chatgpt-", "codex-"].contains(where: bare.hasPrefix)
            || segments.contains("openai")
        if isOpenAI {
            var version: [Int] = []
            if let r = bare.range(of: "gpt-") { version = readVersion(bare[r.upperBound...]) }
            return Info(vendor: .openai, family: "gpt", version: version)
        }
        return nil
    }

    /// 不收 temperature / top_p / top_k（oh-my-pi `supports-sampling-params #false`）：
    /// opus ≥4.7、sonnet / fable / mythos ≥5、haiku ≥5.5、OpenAI o 系、GPT ≥5；都 <10（防 `claude-opus-45` 读成 45）。
    /// nil = 认不出（血统或版本），交给下一层
    static func rejectsSampling(_ modelId: String) -> Bool? {
        guard let info = classify(modelId) else { return nil }
        switch info.vendor {
        case .anthropic:
            switch info.family {
            case "opus": return inRange(info.version, from: [4, 7])
            case "sonnet": return inRange(info.version, from: [5])
            case "haiku": return inRange(info.version, from: [5, 5])
            case "fable", "mythos": return info.version.isEmpty ? true : inRange(info.version, from: [5])
            default: return nil
            }
        case .openai:
            if info.family == "o" { return true }
            return inRange(info.version, from: [5])
        }
    }

    /// temperature 和 top_p 不许同时发（400「`temperature` and `top_p` cannot both be specified for this model」）：
    /// Anthropic 从 opus 4.1、sonnet 4.5、haiku 4.5 起（没有官方清单，公开报告点名 Opus 4.1 / Sonnet 4.5 / Sonnet 4.6，粟粟 10-14 Opus 4.6 实撞）。
    /// 整组不收采样的（rejectsSampling）不算；只认 anthropic 血统，认不出 = false（交给 400 自愈）
    static func singleSampler(_ modelId: String) -> Bool {
        guard let info = classify(modelId), info.vendor == .anthropic, rejectsSampling(modelId) != true else { return false }
        switch info.family {
        case "opus": return inRange(info.version, from: [4, 1]) ?? false
        case "sonnet", "haiku": return inRange(info.version, from: [4, 5]) ?? false
        default: return false
        }
    }

    /// Anthropic 思考只认 adaptive：opus ≥4.7、sonnet / fable / mythos ≥5、haiku ≥5（沿用原 needsAdaptive 的范围）
    static func anthropicAdaptive(_ modelId: String) -> Bool {
        guard let info = classify(modelId), info.vendor == .anthropic else { return false }
        switch info.family {
        case "opus": return inRange(info.version, from: [4, 7]) ?? false
        case "sonnet", "haiku": return inRange(info.version, from: [5]) ?? false
        case "fable", "mythos": return info.version.isEmpty || inRange(info.version, from: [5]) == true
        default: return false
        }
    }

    /// 不发 thinking 字段也在想（adaptive 默认开，plan-thinking R1）：opus ≥5、sonnet ≥5、haiku ≥5.5、fable / mythos。
    /// Opus 4.6–4.8 / Sonnet 4.6 及更老 = 不发就不想
    static func thinksByDefault(_ modelId: String) -> Bool {
        guard let info = classify(modelId), info.vendor == .anthropic else { return false }
        switch info.family {
        case "opus", "sonnet": return inRange(info.version, from: [5]) ?? false
        case "haiku": return inRange(info.version, from: [5, 5]) ?? false
        case "fable", "mythos": return info.version.isEmpty || inRange(info.version, from: [5]) == true
        default: return false
        }
    }

    /// 官方默认 effort（R16）：opus 5.5 / haiku 5.5 是 medium，其余 high
    static func defaultEffort(_ modelId: String) -> String {
        guard let info = classify(modelId), info.vendor == .anthropic,
              ["opus", "haiku"].contains(info.family), info.version.count >= 2,
              info.version[0] == 5, info.version[1] == 5 else { return "high" }
        return "medium"
    }

    /// thinking.display 默认 omitted（思考块文字为空，R2）：opus ≥4.7、sonnet ≥5、haiku ≥5.5、fable / mythos
    static func displayDefaultOmitted(_ modelId: String) -> Bool {
        guard let info = classify(modelId), info.vendor == .anthropic else { return false }
        switch info.family {
        case "opus": return inRange(info.version, from: [4, 7]) ?? false
        case "sonnet": return inRange(info.version, from: [5]) ?? false
        case "haiku": return inRange(info.version, from: [5, 5]) ?? false
        case "fable", "mythos": return info.version.isEmpty || inRange(info.version, from: [5]) == true
        default: return false
        }
    }

    // MARK: - 纯解析

    /// 等于 token，或 token 后面紧跟 `- _ . :` 或数字（oh-my-pi bounded）
    static func bounded(_ segment: String, _ token: String) -> Bool {
        guard segment.hasPrefix(token) else { return false }
        guard let next = segment.dropFirst(token.count).first else { return true }
        return "-_.:".contains(next) || next.isNumber
    }

    /// `claude-` 之后（跳过一个家族名）读版本：`claude-opus-4.7` / `claude-3-7-sonnet` / `us.anthropic.claude-opus-4-7-v1:0`
    static func claudeVersion(_ bare: String) -> [Int] {
        guard let r = bare.range(of: "claude-") else {
            // 没有 claude- 前缀的（`opus-4-7`）：家族名后面读
            guard let family = anthropicFamilies.first(where: { bare.hasPrefix($0 + "-") }) else { return [] }
            return readVersion(bare.dropFirst(family.count + 1))
        }
        var rest = bare[r.upperBound...]
        if let family = anthropicFamilies.first(where: { rest.hasPrefix($0 + "-") }) {
            rest = rest.dropFirst(family.count + 1)
        }
        return readVersion(rest)
    }

    /// 开头必须是数字；最多三段，段间是 `.` 或 `-`（后面紧跟数字），每段 ≤255（日期段自然停下）
    static func readVersion(_ s: Substring) -> [Int] {
        var out: [Int] = []
        var i = s.startIndex
        while out.count < 3, i < s.endIndex, s[i].isNumber {
            var j = i
            while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
            guard let n = Int(s[i..<j]), n <= 255 else { break }
            out.append(n)
            guard j < s.endIndex, s[j] == "." || s[j] == "-" else { break }
            let next = s.index(after: j)
            guard next < s.endIndex, s[next].isNumber else { break }
            i = next
        }
        return out
    }

    /// 版本 ≥ from 且主版本 <10；读不出版本 = nil
    static func inRange(_ version: [Int], from: [Int]) -> Bool? {
        guard let major = version.first else { return nil }
        guard major < 10 else { return false }
        for k in 0..<max(version.count, from.count) {
            let a = k < version.count ? version[k] : 0
            let b = k < from.count ? from[k] : 0
            if a != b { return a > b }
        }
        return true
    }
}
