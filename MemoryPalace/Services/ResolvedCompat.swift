import Foundation

/// 端点 × 模型的兼容配置：建请求前算一次，builder / 解析只读字段（抄 omp resolve.ts「发请求的代码不做探测」）。
/// 解析顺序：协议默认 → baseURL 主机探测（KnownHost）→ 按血统规则 → 学到的（ParamAdaptStore）。卡上的用户覆盖留 P1
struct ResolvedCompat: Equatable {
    var params: ParamCompat = .permissive
    var host: KnownHost = .other
    /// 序列内（非首位）system 原位发（④b）：只对确认支持的开，其余一律降级成 <system_note> user 块。
    /// - api.openai.com：Chat Completions 的 messages 对 system（新模型视作 developer）没有位置限制（官方文档）。
    /// - OpenRouter 的 openai/*：上游就是 OpenAI，OR 以 OpenAI Chat 格式为规范透传 messages（待核：没有实打验证）。
    /// - DeepSeek / 硅基流动 / Kimi / 通义 / 智谱 / 豆包 / Groq / xAI / Gemini 兼容层 / Ollama / 各中转：不确定 → false。
    var interleavedSystem = false
    /// OpenRouter 上的 Claude 系 + cacheFriendly：per-block 挂 cache_control。其他模型（DeepSeek/OpenAI/Gemini）上游自动缓存，不需要它
    var orCacheControl = false
    /// OpenRouter + cacheFriendly：指定一方提供商优先（缓存支持最好且最便宜的上游），只映射已知系列
    var orProviderOrder: [String]?
    var reasoningRoute: ReasoningEffort.Route = .chatCompletions
    // —— 思考解析 / 回传（plan-model-compat-p0 §4、§5）——
    /// 抓到的思考没有来源字段（<think> 拆出来的）时回传写哪个
    var reasoningContentField = "reasoning_content"
    /// C1：工具续轮把当轮思考按原字段回传。默认 DeepSeek / Kimi / OpenRouter（官方文档），其余靠报错学
    var requiresReasoningContentForToolCalls = false
    /// C2（3b，未做）
    var requiresReasoningContentForAllAssistantTurns = false
    /// tool_calls 那条 assistant 的 content 写 "."（Q12，默认全关，等实测）
    var requiresAssistantContentForToolCalls = false
    /// B：正文开头的 <think> 拆成思考（Q3：所有 OpenAI 兼容卡开）
    var splitsLeadingThinkTag = false

    /// 老调用点 / 测试直接调 builder 时的默认：全发、`max_tokens`、不挂 OR 标、system 降级
    static let permissive = ResolvedCompat()

    static func resolve(providerType: ProviderType, baseURL: String, modelId: String, sampling: SamplingParams?,
                        store: ParamAdaptStore? = .shared,
                        catalog: (String) -> CatalogModel? = { ModelCatalog.shared.model(for: $0) }) -> ResolvedCompat {
        var c = ResolvedCompat()
        let learned = store?.entry(providerType: providerType, baseURL: baseURL, modelId: modelId)?.learned
        c.params = ParamCompat.resolve(providerType: providerType, baseURL: baseURL, modelId: modelId,
                                       reasoningEffort: sampling?.reasoningEffort ?? ReasoningEffort.auto,
                                       learned: learned, store: nil, catalog: catalog)
        c.host = KnownHost.detect(baseURL)
        c.reasoningRoute = ReasoningEffort.route(providerType: providerType, credentialId: "", baseURL: baseURL, modelId: modelId)
        guard providerType == .openaiCompatible else { return c }
        let m = modelId.lowercased()
        c.interleavedSystem = c.host == .openai || (c.host == .openrouter && m.hasPrefix("openai/"))
        let cacheFriendly = sampling?.cacheFriendly == true
        c.orCacheControl = cacheFriendly && c.host == .openrouter && (m.hasPrefix("anthropic/") || m.contains("claude"))
        if cacheFriendly, c.host == .openrouter, m.hasPrefix("deepseek/") { c.orProviderOrder = ["deepseek"] }
        c.splitsLeadingThinkTag = true
        let groups = learned?.groups ?? []
        if groups.contains(ParamCompat.Group.reasoningReplayRequired) {
            c.requiresReasoningContentForToolCalls = true
        } else if groups.contains(ParamCompat.Group.reasoningReplay) {
            c.requiresReasoningContentForToolCalls = false
        } else {
            c.requiresReasoningContentForToolCalls = [.deepseek, .moonshot, .openrouter].contains(c.host)
        }
        return c
    }
}

/// 认得出的端点主机。都按小写 host 判，不按整串子串（plan-model-compat-p0 Q2）
enum KnownHost: Equatable {
    case openai, openrouter, anthropic, deepseek, moonshot, other

    static func detect(_ baseURL: String) -> KnownHost {
        guard let host = URL(string: baseURL.lowercased())?.host else { return .other }
        switch host {
        case "api.openai.com": return .openai
        case "api.anthropic.com": return .anthropic
        case "api.moonshot.ai", "api.moonshot.cn", "api.kimi.com", "api.kimi.ai": return .moonshot
        default: break
        }
        if matches(host, "openrouter.ai") { return .openrouter }
        if matches(host, "deepseek.com") { return .deepseek }
        return .other
    }

    /// 等于该域名或是它的子域；`xopenrouter.ai` / `openrouter.ai.evil.com` 不算
    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
