import Foundation

/// 思考强度跟着模型走（docs/research-reasoning-effort.md §2，粟粟 10-02；学 magpie internal/provider）。
/// 一处说清：这个模型走哪条路、有哪几档、换模型取最近一档、每个模型各记各的、每条路怎么发。
/// 值的约定：`auto` = 「默认」（不发，用官方默认）；其余是总顺序里的一档（none = 关）
enum ReasoningEffort {
    static let auto = "auto"
    /// 总顺序（magpie `Levels`）
    static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    enum Route: Equatable {
        /// Claude 4.7+ / 5 系：`thinking: {type: adaptive}` + `output_config.effort`（旧格式 400）
        case anthropicAdaptive
        /// 老 Claude：`thinking: {type: enabled, budget_tokens}`
        case anthropicBudget
        /// OpenAI 兼容口：`reasoning_effort`（OpenAI 官方、Gemini 兼容口、中转）
        case chatCompletions
        /// OpenRouter：`reasoning: {effort}`
        case openRouter
        /// ChatGPT 登录（Responses API）：`reasoning: {effort}`
        case responses
        /// CC 会话：发消息时带给 hub，hub 用 `/effort` / `--effort`
        case claudeCode
        /// codex 会话：hub 开会话带 `-c model_reasoning_effort`
        case codex
        /// 本机 Qwen3：只有开 / 关
        case local
        /// 不支持
        case unsupported
    }

    static func route(providerType: ProviderType, credentialId: String, baseURL: String, modelId: String) -> Route {
        switch providerType {
        case .anthropic: return needsAdaptive(modelId) ? .anthropicAdaptive : .anthropicBudget
        case .openaiCompatible:
            return URL(string: baseURL.lowercased())?.host?.hasSuffix("openrouter.ai") == true ? .openRouter : .chatCompletions
        case .chatgptOAuth: return .responses
        case .ccBridge: return credentialId == "codex-bridge" ? .codex : .claudeCode
        case .localMLX: return .local
        case .unsupported: return .unsupported
        }
    }

    /// Opus 4.7 起、Sonnet / Opus / Haiku 5 系、Fable、Mythos 只认 adaptive（官方 thinking troubleshooting 表）
    static func needsAdaptive(_ modelId: String) -> Bool {
        let m = modelId.lowercased()
        return ["opus-4-7", "opus-4-8", "opus-5", "sonnet-5", "haiku-5", "fable", "mythos"].contains { m.contains($0) }
    }

    /// 这个模型能选的档位（不含「默认」）。顺序：模型目录 → 小补表 → 不知道给通用三档；目录说不推理 → 空（只有默认）
    static func levels(route: Route, modelId: String,
                       catalog: (String) -> CatalogModel? = { ModelCatalog.shared.model(for: $0) }) -> [String] {
        switch route {
        case .claudeCode: return ["low", "medium", "high", "xhigh", "max"]
        case .codex: return ["low", "medium", "high", "xhigh"]
        case .local: return ["none", "high"]
        case .unsupported: return []
        default: break
        }
        if let entry = catalog(modelId) {
            let known = entry.reasoningEfforts.filter(order.contains)
            if !known.isEmpty { return sorted(known) }
            if !entry.reasoning { return [] }
        }
        switch route {
        case .anthropicAdaptive: return ["low", "medium", "high", "xhigh", "max"]
        case .anthropicBudget: return ["low", "medium", "high", "max"]
        default: return ["low", "medium", "high"]
        }
    }

    private static func sorted(_ levels: [String]) -> [String] {
        order.filter(levels.contains)
    }

    /// 想要的档位不在这个模型里：取最近一档，一样近取高的（magpie nearestEffort）；不往 none 上靠；没档位 = 默认
    static func nearest(_ want: String, in levels: [String]) -> String {
        guard want != auto else { return auto }
        guard !levels.isEmpty else { return auto }
        if levels.contains(want) { return want }
        guard let at = order.firstIndex(of: want) else { return auto }
        var best = auto
        var distance = Int.max
        for level in levels where level != "none" {
            guard let i = order.firstIndex(of: level) else { continue }
            let d = abs(i - at)
            if d < distance || (d == distance && i > at) { best = level; distance = d }
        }
        return best
    }

    /// 发出去的值：这个模型记过的优先，没记过拿预设当起点，再按它的档位取最近
    static func effective(stored: String?, presetDefault: String, levels: [String]) -> String {
        nearest(stored ?? presetDefault, in: levels)
    }

    // MARK: - 每个模型各记各的（本机）

    private static let storeKey = "reasoningEffortByModel.v1"

    static func stored(credentialId: String, modelId: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: storeKey) as? [String: String])?["\(credentialId)/\(modelId)"]
    }

    static func store(_ value: String, credentialId: String, modelId: String, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        all["\(credentialId)/\(modelId)"] = value
        defaults.set(all, forKey: storeKey)
    }

    // MARK: - 显示

    static func label(_ level: String, route: Route? = nil) -> String {
        if route == .local, level == "high" { return "开" }
        switch level {
        case auto: return "默认"
        case "none": return "关"
        case "minimal": return "最低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "更高"
        case "max": return "极限"
        default: return level
        }
    }

    /// 选择器副标题：这家怎么叫
    static func subtitle(_ route: Route) -> String {
        switch route {
        case .anthropicAdaptive: return "Adaptive Thinking · effort"
        case .anthropicBudget: return "Extended Thinking"
        case .chatCompletions, .openRouter, .responses: return "Reasoning Effort"
        case .claudeCode: return "Claude Code /effort"
        case .codex: return "Codex reasoning effort"
        case .local: return "思考开关"
        case .unsupported: return "不支持"
        }
    }

    // MARK: - 怎么发

    struct AnthropicWire {
        var thinking: [String: Any]?
        var outputConfig: [String: Any]?
        var maxTokens: Int
        /// 开了思考：temperature / top_k 不能发
        var thinkingOn: Bool { thinking != nil }
    }

    /// 思考余量（老模型就是 budget_tokens）：low 1024 / medium 4096 / high 10000 / xhigh 16000 / max 32000
    static func headroom(_ effort: String) -> Int? {
        switch effort {
        case "low": return 1024
        case "medium": return 4096
        case "high": return 10000
        case "xhigh": return 16000
        case "max": return 32000
        default: return nil
        }
    }

    static func anthropicThinking(route: Route, effort: String, visible: Int, limit: Int?) -> AnthropicWire {
        let cap = limit ?? .max
        guard let tier = headroom(effort) else { return AnthropicWire(maxTokens: min(visible, cap)) }
        let total = min(visible + tier, cap)
        if route == .anthropicAdaptive {
            return AnthropicWire(thinking: ["type": "adaptive"], outputConfig: ["effort": effort], maxTokens: total)
        }
        let budget = min(tier, total - 1024)
        guard budget >= 1024 else { return AnthropicWire(maxTokens: min(visible, cap)) }
        return AnthropicWire(thinking: ["type": "enabled", "budget_tokens": budget], maxTokens: total)
    }

    /// OpenAI 兼容口：OpenRouter 用 `reasoning: {effort}`，其余 `reasoning_effort`；默认不发
    static func applyChatCompletions(route: Route, effort: String, to body: inout [String: Any]) {
        guard effort != auto else { return }
        if route == .openRouter {
            body["reasoning"] = ["effort": effort]
        } else {
            body["reasoning_effort"] = effort
        }
    }
}

/// 本机 Qwen3 开思考后吐 `<think>…</think>`：换成 app 的 `[thinking]…[/thinking]`，收进思考气泡。
/// 标签可能被切在两个 token 之间：疑似标签开头的尾巴先压着，等下一段再判。
/// 用 class：流式回调里要改它的状态（闭包里改捕获的 struct 不安全）
final class ThinkTagConverter {
    private var pending = ""
    private static let pairs = [("<think>", "[thinking]"), ("</think>", "[/thinking]")]

    func feed(_ chunk: String) -> String {
        var text = pending + chunk
        pending = ""
        for (from, to) in Self.pairs { text = text.replacingOccurrences(of: from, with: to) }
        // 结尾是某个标签的开头（如 "<thi"）：压到下一段
        for len in stride(from: min(text.count, 8), through: 1, by: -1) {
            let tail = String(text.suffix(len))
            if Self.pairs.contains(where: { $0.0.hasPrefix(tail) }) {
                pending = tail
                return String(text.dropLast(len))
            }
        }
        return text
    }

    func flush() -> String {
        defer { pending = "" }
        return pending
    }
}
