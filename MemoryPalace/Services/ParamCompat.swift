import Foundation

/// 这个模型在这个端点上收哪些参数（#094 plan-param-autoadapt §3.1–3.2，抄 oh-my-pi `withSupportedSamplingParams`）。
/// 判断顺序（先命中先用）：学到的 > models.dev 目录 > 血统 > 推理档 > 默认发。
/// 实发（ProviderRouter.sendStreaming）和检查器预览（previewRequestBody）都先过 `supported(_:)`，预览 = 实发。
struct ParamCompat: Equatable {
    enum Source: String, Equatable {
        case learned, catalog, lineage, effort, `default`
    }

    /// 参数组（记忆表 / 剥参数共用的名字）
    enum Group {
        /// temperature / top_p / top_k / frequency_penalty / presence_penalty
        static let sampling = "sampling"
        static let seed = "seed"
        static let streamOptions = "stream_options"
        /// reasoning_effort / reasoning / Anthropic thinking
        static let reasoning = "reasoning"
        static let outputConfig = "output_config"
        /// temperature 和 top_p 只收一个：两个都要发时去掉 top_p（不是整组不收，Q1 整组规则的例外）
        static let singleSampler = "single_sampler"
        /// Anthropic `thinking.display`（中转不认就只去掉它，思考照开，plan-thinking §3.6）
        static let thinkingDisplay = "thinking_display"
        /// 工具续轮不回传思考（Mistral 那类 422 extra_forbidden 点名 messages.N.reasoning_content，plan-model-compat-p0 §5.2）
        static let reasoningReplay = "reasoning_replay"
        /// 工具续轮要回传思考（DeepSeek「must be passed back」）。和 reasoningReplay 互斥，存表时后学到的顶掉前一个
        static let reasoningReplayRequired = "reasoning_replay_required"
        /// 不是「不发某参数」、由 ResolvedCompat 读的组
        static let replayGroups: Set<String> = [reasoningReplay, reasoningReplayRequired]
    }

    /// temperature / top_p / top_k / 两种 penalty 发不发
    var sendsSampling = true
    /// 采样组以外、学到不收的组：seed / stream_options / reasoning / output_config
    var dropped: Set<String> = []
    /// temperature 和 top_p 只发一个（Anthropic opus ≥4.1 / sonnet ≥4.5 / haiku ≥4.5，或学到的）：两个都要发时不发 top_p
    var singleSampler = false
    /// OpenAI 兼容口的输出上限键名
    var maxTokensKey = "max_tokens"
    /// Anthropic 思考格式：adaptive（4.7+ / 5 系）还是 budget_tokens
    var anthropicAdaptive = false
    /// sendsSampling 是哪一层定的（设置页提示、日志用）
    var source: Source = .default

    /// 老调用点 / 测试直接调 builder 时的默认：全发、`max_tokens`
    static let permissive = ParamCompat()

    /// 记忆表里一条（按地址 + 模型）学到的东西
    struct Learned: Codable, Equatable {
        var groups: Set<String> = []
        /// 学到的键名（`max_completion_tokens` / `max_tokens`）
        var maxTokensKey: String?
        /// 学到的 Anthropic 思考格式：adaptive / budget
        var thinkingFormat: String?

        /// 「不发 temperature、top_p、seed · 改用 max_completion_tokens」
        var summary: String {
            var drops: [String] = []
            if groups.contains(Group.sampling) { drops.append("temperature、top_p") }
            if groups.contains(Group.singleSampler), !groups.contains(Group.sampling) { drops.append(ParamCompat.groupLabel(Group.singleSampler)) }
            for group in groups.sorted() where group != Group.sampling && group != Group.singleSampler && !Group.replayGroups.contains(group) {
                drops.append(ParamCompat.groupLabel(group))
            }
            var parts: [String] = []
            if !drops.isEmpty { parts.append("不发 " + drops.joined(separator: "、")) }
            if groups.contains(Group.reasoningReplayRequired) { parts.append("工具续轮回传思考") }
            if groups.contains(Group.reasoningReplay) { parts.append("不回传思考") }
            if let maxTokensKey { parts.append("改用 \(maxTokensKey)") }
            if let thinkingFormat { parts.append(thinkingFormat == "adaptive" ? "思考用 adaptive" : "思考用 budget_tokens") }
            return parts.joined(separator: " · ")
        }
    }

    static func resolve(providerType: ProviderType, baseURL: String, modelId: String, reasoningEffort: String,
                        learned explicit: Learned? = nil, store: ParamAdaptStore? = .shared,
                        catalog: (String) -> CatalogModel? = { ModelCatalog.shared.model(for: $0) }) -> ParamCompat {
        let learned = explicit ?? store?.entry(providerType: providerType, baseURL: baseURL, modelId: modelId)?.learned
        var c = ParamCompat()
        let official = KnownHost.detect(baseURL) == .openai
        c.maxTokensKey = learned?.maxTokensKey ?? (official ? "max_completion_tokens" : "max_tokens")
        c.anthropicAdaptive = learned?.thinkingFormat.map { $0 == "adaptive" } ?? ModelLineage.anthropicAdaptive(modelId)
        c.dropped = (learned?.groups ?? []).subtracting([Group.sampling, Group.singleSampler]).subtracting(Group.replayGroups)
        c.singleSampler = learned?.groups.contains(Group.singleSampler) == true || ModelLineage.singleSampler(modelId)

        if learned?.groups.contains(Group.sampling) == true {
            c.sendsSampling = false
            c.source = .learned
            return c
        }
        if let accepts = catalog(modelId)?.temperature {
            c.sendsSampling = accepts
            c.source = .catalog
        } else if let rejects = ModelLineage.rejectsSampling(modelId) {
            c.sendsSampling = !rejects
            c.source = .lineage
        }
        // 推理档开着的 OpenAI 推理模型不收采样参数（官方 latest-model 指南）；不再只认官方地址
        if c.sendsSampling, reasoningEffort != ReasoningEffort.auto, reasoningEffort != "none",
           official || ModelLineage.classify(modelId)?.vendor == .openai {
            c.sendsSampling = false
            c.source = .effort
        }
        return c
    }

    /// 组名说人话（聊天小灰字 / 设置页）
    static func groupLabel(_ group: String) -> String {
        switch group {
        case Group.sampling: return "temperature / top_p"
        case Group.reasoning: return "推理强度参数"
        case Group.singleSampler: return "top_p（和 temperature 只收一个）"
        case Group.thinkingDisplay: return "思考摘要参数（thinking.display）"
        case Group.reasoningReplay: return "回传的思考（reasoning_content）"
        default: return group
        }
    }

    /// 这次发不发 top_p：只收一个采样参数的模型，temperature 已经要发就不发 top_p（temperature 是默认值不发时，top_p 照发）
    func sendsTopP(temperatureSent: Bool) -> Bool {
        !(singleSampler && temperatureSent)
    }

    /// 组 body 前统一剥一次：不发的字段改成 builder 当「不发」的值（temperature / top_p 1.0、top_k 0、penalty 0、seed -1、推理档 auto）。
    /// 只动这一次请求，预设不变
    func supported(_ s: SamplingParams) -> SamplingParams {
        var r = s
        if !sendsSampling {
            r.temperature = 1.0
            r.topP = 1.0
            r.topK = 0
            r.frequencyPenalty = 0
            r.presencePenalty = 0
        }
        if dropped.contains(Group.seed) { r.seed = -1 }
        if dropped.contains(Group.reasoning) { r.reasoningEffort = ReasoningEffort.auto }
        return r
    }
}
