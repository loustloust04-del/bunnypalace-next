import XCTest
@testable import 记忆花园

/// 模型兼容 P0 阶段 2：ResolvedCompat / KnownHost（plan-model-compat-p0 §3.5）
final class ResolvedCompatTests: XCTestCase {

    struct Row {
        let baseURL: String
        let model: String
        let cacheFriendly: Bool
        let orCacheControl: Bool
        let orProviderOrder: [String]?
        let interleavedSystem: Bool
        let route: ReasoningEffort.Route
        let maxTokensKey: String
    }

    /// 改前四个旧函数（wantsORCacheControl / orPreferredProviderOrder / supportsInterleavedSystem / isOfficialOpenAI）的输出
    static let equivalence: [Row] = [
        Row(baseURL: "https://api.openai.com/v1", model: "gpt-4o", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: true, route: .chatCompletions, maxTokensKey: "max_completion_tokens"),
        Row(baseURL: "https://API.OpenAI.com/v1", model: "gpt-4o", cacheFriendly: false,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: true, route: .chatCompletions, maxTokensKey: "max_completion_tokens"),
        Row(baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5", cacheFriendly: true,
            orCacheControl: true, orProviderOrder: nil, interleavedSystem: false, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5", cacheFriendly: false,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://openrouter.ai/api/v1", model: "deepseek/deepseek-chat", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: ["deepseek"], interleavedSystem: false, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://openrouter.ai/api/v1", model: "deepseek/deepseek-chat", cacheFriendly: false,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: true, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://eu.openrouter.ai/api/v1", model: "anthropic/claude-opus-4.7", cacheFriendly: true,
            orCacheControl: true, orProviderOrder: nil, interleavedSystem: false, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://OpenRouter.ai/api/v1", model: "openai/gpt-5", cacheFriendly: false,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: true, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://openrouter.ai/api/v1", model: "claude-3-5-sonnet", cacheFriendly: true,
            orCacheControl: true, orProviderOrder: nil, interleavedSystem: false, route: .openRouter, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .chatCompletions, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://api.openai.com.evil.com/v1", model: "gpt-4o", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .chatCompletions, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .chatCompletions, maxTokensKey: "max_tokens"),
        Row(baseURL: "https://relay.example.com/v1", model: "claude-sonnet-4-5", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .chatCompletions, maxTokensKey: "max_tokens"),
    ]

    /// Q2（粟粟批：OpenRouter 统一按 host 后缀判）：路径里带 openrouter 的自建代理改前按整串子串算 OpenRouter，改后不算。
    /// 改前的值（orCacheControl / orProviderOrder / interleavedSystem）在注释里
    static let q2After: [Row] = [
        // 改前 orCacheControl = true
        Row(baseURL: "https://x.com/openrouter/v1", model: "anthropic/claude-sonnet-4.5", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .chatCompletions, maxTokensKey: "max_tokens"),
        // 改前 orProviderOrder = ["deepseek"]
        Row(baseURL: "https://x.com/openrouter/v1", model: "deepseek/deepseek-chat", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .chatCompletions, maxTokensKey: "max_tokens"),
        // 改前 interleavedSystem = true
        Row(baseURL: "https://x.com/openrouter.ai/v1", model: "openai/gpt-4o", cacheFriendly: true,
            orCacheControl: false, orProviderOrder: nil, interleavedSystem: false, route: .chatCompletions, maxTokensKey: "max_tokens"),
    ]

    private func sampling(cacheFriendly: Bool) -> SamplingParams {
        var s = SamplingParams()
        s.cacheFriendly = cacheFriendly
        return s
    }

    private func resolve(_ baseURL: String, _ model: String, type: ProviderType = .openaiCompatible,
                         sampling: SamplingParams? = nil) -> ResolvedCompat {
        ResolvedCompat.resolve(providerType: type, baseURL: baseURL, modelId: model, sampling: sampling,
                               store: nil, catalog: { _ in nil })
    }

    private func check(_ rows: [Row]) {
        for r in rows {
            let s = sampling(cacheFriendly: r.cacheFriendly)
            let tag = "\(r.baseURL) \(r.model) cache=\(r.cacheFriendly)"
            let c = resolve(r.baseURL, r.model, sampling: s)
            XCTAssertEqual(c.orCacheControl, r.orCacheControl, tag)
            XCTAssertEqual(c.orProviderOrder, r.orProviderOrder, tag)
            XCTAssertEqual(c.interleavedSystem, r.interleavedSystem, tag)
            XCTAssertEqual(c.reasoningRoute, r.route, tag)
            XCTAssertEqual(ReasoningEffort.route(providerType: .openaiCompatible, credentialId: "", baseURL: r.baseURL, modelId: r.model), r.route, tag)
            XCTAssertEqual(c.params.maxTokensKey, r.maxTokensKey, tag)
            XCTAssertEqual(c.params, ParamCompat.resolve(providerType: .openaiCompatible, baseURL: r.baseURL, modelId: r.model,
                                                         reasoningEffort: s.reasoningEffort, store: nil, catalog: { _ in nil }), tag)
        }
    }

    func testEquivalenceWithLegacyFunctions() {
        check(Self.equivalence)
    }

    func testQ2PathContainingOpenRouterIsNotOpenRouter() {
        check(Self.q2After)
        XCTAssertEqual(KnownHost.detect("https://x.com/openrouter/v1"), .other)
    }

    func testKnownHostDetect() {
        let cases: [(String, KnownHost)] = [
            ("https://api.openai.com/v1", .openai),
            ("HTTPS://API.OPENAI.COM/v1", .openai),
            ("https://api.openai.com", .openai),
            ("https://api.openai.com.evil.com/v1", .other),
            ("https://evil.com/api.openai.com/v1", .other),
            ("https://openrouter.ai/api/v1", .openrouter),
            ("https://eu.openrouter.ai/api/v1", .openrouter),
            ("https://OpenRouter.AI/api/v1", .openrouter),
            ("https://api.anthropic.com/v1", .anthropic),
            ("https://api.anthropic.com.relay.cn/v1", .other),
            ("https://api.deepseek.com/v1", .deepseek),
            ("https://api.deepseek.com", .deepseek),
            ("https://api.moonshot.ai/v1", .moonshot),
            ("https://api.moonshot.cn/v1", .moonshot),
            ("https://api.kimi.com/coding/v1", .moonshot),
            ("https://api.kimi.ai/coding/v1", .moonshot),
            ("https://xapi.kimi.ai/coding/v1", .other),
            ("https://api.kimi.ai.evil.com/coding/v1", .other),
            ("https://api.siliconflow.cn/v1", .other),
            ("http://localhost:11434/v1", .other),
            ("", .other),
            ("not a url", .other),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(KnownHost.detect(url), expected, url)
        }
    }

    /// 厂商规则只作用于这个厂商（magpie LESSONS）：DeepSeek / Moonshot 的 host 不改变采样层任何字段
    func testVendorHostDoesNotLeakIntoParams() {
        var s = SamplingParams()
        s.reasoningEffort = "high"
        for model in ["deepseek-chat", "deepseek-reasoner", "kimi-k2", "gpt-4o", "o3", "claude-sonnet-4-5", "anthropic/claude-opus-4.7"] {
            let baseline = resolve("https://relay.example.com/v1", model, sampling: s)
            for host in ["https://api.deepseek.com/v1", "https://api.moonshot.cn/v1", "https://api.kimi.com/coding/v1"] {
                let c = resolve(host, model, sampling: s)
                XCTAssertEqual(c.params, baseline.params, "\(host) \(model)")
                XCTAssertEqual(c.interleavedSystem, baseline.interleavedSystem, "\(host) \(model)")
                XCTAssertEqual(c.orCacheControl, baseline.orCacheControl, "\(host) \(model)")
                XCTAssertEqual(c.orProviderOrder, baseline.orProviderOrder, "\(host) \(model)")
                XCTAssertEqual(c.reasoningRoute, baseline.reasoningRoute, "\(host) \(model)")
            }
        }
    }

    /// 阶段 3 的开关：permissive 全关；OpenAI 兼容卡拆 <think>、DeepSeek / Kimi 续轮回传；3b / Q12 仍关；Anthropic 卡不带 OpenAI 兼容口的 host 判断
    func testStage3SwitchDefaultsAndAnthropicType() {
        let permissive = ResolvedCompat.permissive
        XCTAssertFalse(permissive.requiresReasoningContentForToolCalls)
        XCTAssertFalse(permissive.splitsLeadingThinkTag)
        for c in [permissive, resolve("https://api.deepseek.com/v1", "deepseek-reasoner"),
                  resolve("https://api.moonshot.cn/v1", "kimi-k2")] {
            XCTAssertEqual(c.reasoningContentField, "reasoning_content")
            XCTAssertFalse(c.requiresReasoningContentForAllAssistantTurns)
            XCTAssertFalse(c.requiresAssistantContentForToolCalls)
        }
        for c in [resolve("https://api.deepseek.com/v1", "deepseek-reasoner"), resolve("https://api.moonshot.cn/v1", "kimi-k2"),
                  resolve("https://api.kimi.ai/coding/v1", "kimi-k2")] {
            XCTAssertTrue(c.requiresReasoningContentForToolCalls)
            XCTAssertTrue(c.splitsLeadingThinkTag)
        }
        XCTAssertEqual(ResolvedCompat.permissive.params, .permissive)
        XCTAssertFalse(ResolvedCompat.permissive.interleavedSystem)
        XCTAssertEqual(ResolvedCompat.permissive.reasoningRoute, .chatCompletions)

        let anth = resolve("https://openrouter.ai/api/v1", "claude-opus-4-7", type: .anthropic, sampling: sampling(cacheFriendly: true))
        XCTAssertEqual(anth.host, .openrouter)
        XCTAssertFalse(anth.orCacheControl)
        XCTAssertNil(anth.orProviderOrder)
        XCTAssertFalse(anth.interleavedSystem)
        XCTAssertEqual(anth.reasoningRoute, .anthropicAdaptive)
        XCTAssertTrue(anth.params.anthropicAdaptive)
        XCTAssertFalse(anth.splitsLeadingThinkTag)
        XCTAssertFalse(anth.requiresReasoningContentForToolCalls)
    }

    // MARK: - 阶段 2 审查：host 边界（车头批：等于域名或以 `.域名` 结尾）

    func testKnownHostBoundaries() {
        let cases: [(String, KnownHost)] = [
            ("https://api.openai.com:443/v1", .openai),
            ("https://openrouter.ai:8443/api/v1", .openrouter),
            ("https://api.deepseek.com:443", .deepseek),
            ("https://api.moonshot.cn:443/v1", .moonshot),
            ("https://openrouter.ai@evil.com/api/v1", .other),
            ("https://evil.com@openrouter.ai/api/v1", .openrouter),
            ("https://xopenrouter.ai/api/v1", .other),
            ("https://openrouter.ai.evil.com/api/v1", .other),
            ("https://openrouter-proxy.example/api/v1", .other),
            ("https://xdeepseek.com/v1", .other),
            ("https://deepseek.com/v1", .deepseek),
            ("https://deepseek.com.evil.com/v1", .other),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(KnownHost.detect(url), expected, url)
        }
    }

    /// 收紧后缀是批准的行为变化：`xopenrouter.ai` 不再走 OpenRouter 的 `reasoning: {effort}`，改发 `reasoning_effort`，也不挂 OR 标 / 排序
    func testLookalikeOpenRouterHostIsNotOpenRouterInBody() {
        var s = SamplingParams()
        s.cacheFriendly = true
        s.reasoningEffort = "high"
        for url in ["https://xopenrouter.ai/api/v1", "https://openrouter.ai.evil.com/api/v1",
                    "https://openrouter-proxy.example/api/v1", "https://openrouter.ai@evil.com/api/v1"] {
            XCTAssertEqual(ReasoningEffort.route(providerType: .openaiCompatible, credentialId: "", baseURL: url, modelId: "deepseek/deepseek-chat"),
                           .chatCompletions, url)
            for model in ["deepseek/deepseek-chat", "anthropic/claude-sonnet-4.5", "openai/gpt-4o"] {
                let body = openAIBody(url, model, s)
                XCTAssertEqual(body["reasoning_effort"] as? String, "high", "\(url) \(model)")
                XCTAssertNil(body["reasoning"], "\(url) \(model)")
                XCTAssertNil(body["provider"], "\(url) \(model)")
                XCTAssertFalse(hasCacheControl(body), "\(url) \(model)")
                XCTAssertFalse(roles(body).dropFirst().contains("system"), "\(url) \(model)：非前缀 system 应降级")
            }
        }
        let real = openAIBody("https://evil.com@openrouter.ai/api/v1", "deepseek/deepseek-chat", s)
        XCTAssertEqual((real["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil(real["reasoning_effort"])
        XCTAssertEqual((real["provider"] as? [String: Any])?["order"] as? [String], ["deepseek"])
    }

    /// Anthropic 卡填了 OpenAI / OpenRouter 地址：不启用 OpenAI 专属 system 原位、OR 挂标、provider 排序——最终 body 与中性地址逐字节相同
    func testAnthropicCardOnOpenAIOrOpenRouterHostGetsNoOpenAIOnlyWiring() throws {
        var s = SamplingParams()
        s.cacheFriendly = true
        let model = "deepseek/deepseek-chat"
        let neutral = try json(anthropicBody("https://relay.example.com/v1", model, s))
        for url in ["https://api.openai.com/v1", "https://openrouter.ai/api/v1", "https://eu.openrouter.ai/api/v1"] {
            let c = resolve(url, model, type: .anthropic, sampling: s)
            XCTAssertFalse(c.interleavedSystem, url)
            XCTAssertFalse(c.orCacheControl, url)
            XCTAssertNil(c.orProviderOrder, url)
            let body = anthropicBody(url, model, s)
            XCTAssertNil(body["provider"], url)
            XCTAssertFalse(roles(body).contains("system"), url)
            let notes = (body["messages"] as? [[String: Any]] ?? []).filter { text($0).contains(PromptWire.systemNoteOpen) }
            XCTAssertEqual(notes.count, 1, "\(url)：非前缀 system 降级成 system_note user 块")
            XCTAssertEqual(try json(body), neutral, url)
        }
        for model in ["openai/gpt-4o", "anthropic/claude-sonnet-4.5"] {
            let neutral = try json(anthropicBody("https://relay.example.com/v1", model, s))
            for url in ["https://api.openai.com/v1", "https://openrouter.ai/api/v1"] {
                XCTAssertEqual(try json(anthropicBody(url, model, s)), neutral, "\(url) \(model)")
            }
        }
    }

    // MARK: - body 夹具

    private var orderedWithMidSystem: [PromptMessage] {
        [
            PromptMessage(role: "system", content: "你是助手", source: .slot(id: "main", name: "main"), nodeId: nil, pinnedToSystemPrefix: false),
            PromptMessage(role: "user", content: "早", source: .chatHistory, nodeId: "u1", pinnedToSystemPrefix: false),
            PromptMessage(role: "assistant", content: "早呀", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false),
            PromptMessage(role: "system", content: "注意语气", source: .slot(id: "mid", name: "mid"), nodeId: nil, pinnedToSystemPrefix: false),
            PromptMessage(role: "user", content: "在吗", source: .chatHistory, nodeId: "u2", pinnedToSystemPrefix: false),
        ]
    }

    private func openAIBody(_ url: String, _ model: String, _ s: SamplingParams) -> [String: Any] {
        OpenAICompatibleProvider.buildRequestBody(ordered: orderedWithMidSystem, model: model, samplingParams: s,
                                                  compat: resolve(url, model, sampling: s))
    }

    private func anthropicBody(_ url: String, _ model: String, _ s: SamplingParams) -> [String: Any] {
        AnthropicProvider.buildRequestBody(ordered: orderedWithMidSystem, model: model, samplingParams: s,
                                           allowCacheControl: true, compat: resolve(url, model, type: .anthropic, sampling: s))
    }

    private func roles(_ body: [String: Any]) -> [String] {
        (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
    }

    private func text(_ message: [String: Any]) -> String {
        if let s = message["content"] as? String { return s }
        return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "|")
    }

    private func hasCacheControl(_ body: [String: Any]) -> Bool {
        (body["messages"] as? [[String: Any]] ?? []).contains { m in
            (m["content"] as? [[String: Any]] ?? []).contains { $0["cache_control"] != nil }
        }
    }

    private func json(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
