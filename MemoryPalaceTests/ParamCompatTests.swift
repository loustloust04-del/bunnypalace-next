import XCTest
@testable import 记忆花园

/// #094 参数自适配：血统 / compat 分层 / 剥参数（plan-param-autoadapt §4.4）
final class ParamCompatTests: XCTestCase {

    // MARK: - 血统

    func testLineageClassify() {
        typealias I = ModelLineage.Info
        XCTAssertEqual(ModelLineage.classify("claude-opus-4-7"), I(vendor: .anthropic, family: "opus", version: [4, 7]))
        XCTAssertEqual(ModelLineage.classify("claude-opus-4.7"), I(vendor: .anthropic, family: "opus", version: [4, 7]))
        XCTAssertEqual(ModelLineage.classify("anthropic/claude-opus-4.7"), I(vendor: .anthropic, family: "opus", version: [4, 7]))
        XCTAssertEqual(ModelLineage.classify("us.anthropic.claude-opus-4-7-v1:0"), I(vendor: .anthropic, family: "opus", version: [4, 7]))
        XCTAssertEqual(ModelLineage.classify("claude-opus-4-7-20260101"), I(vendor: .anthropic, family: "opus", version: [4, 7]), "日期段 >255 停")
        XCTAssertEqual(ModelLineage.classify("claude-3-7-sonnet-20250219"), I(vendor: .anthropic, family: "sonnet", version: [3, 7]))
        XCTAssertEqual(ModelLineage.classify("claude-opus-45"), I(vendor: .anthropic, family: "opus", version: [45]))
        XCTAssertEqual(ModelLineage.classify("gpt-4o"), I(vendor: .openai, family: "gpt", version: [4]))
        XCTAssertEqual(ModelLineage.classify("openai/gpt-5.4-mini"), I(vendor: .openai, family: "gpt", version: [5, 4]))
        XCTAssertEqual(ModelLineage.classify("openai/o4-mini"), I(vendor: .openai, family: "o", version: [4]))
        XCTAssertEqual(ModelLineage.classify("openai/gpt-oss-120b"), I(vendor: .openai, family: "gpt", version: []))
        XCTAssertNil(ModelLineage.classify("deepseek-reasoner"))
        XCTAssertNil(ModelLineage.classify("cc-claude-opus-4-7"), "中转起的怪名字认不出，交给 400 自愈")
        XCTAssertNil(ModelLineage.classify(""))
    }

    func testLineageRejectsSampling() {
        let rejects = ["claude-opus-4-7", "claude-opus-4.7", "anthropic/claude-opus-4.7", "us.anthropic.claude-opus-4-7-v1:0",
                       "claude-haiku-5-5", "claude-sonnet-5", "claude-opus-5-5", "claude-fable-5-1",
                       "openai/gpt-5", "gpt-5", "gpt-6-sol", "o3-mini", "o3", "openai/o4-mini"]
        for m in rejects { XCTAssertEqual(ModelLineage.rejectsSampling(m), true, m) }
        let accepts = ["claude-opus-45", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-haiku-5", "claude-3-7-sonnet-20250219",
                       "claude-opus-4-20250514", "gpt-4o", "gpt-4.1-mini", "chatgpt-4o-latest"]
        for m in accepts { XCTAssertEqual(ModelLineage.rejectsSampling(m), false, m) }
        for m in ["deepseek-reasoner", "openai/gpt-oss-120b", "claude-sonnet", "qwen3-235b"] {
            XCTAssertNil(ModelLineage.rejectsSampling(m), m)
        }
    }

    /// opus ≥4.1 / sonnet ≥4.5 / haiku ≥4.5：temperature 和 top_p 只收一个（粟粟 10-14 Opus 4.6 实撞 400）
    func testLineageSingleSampler() {
        for m in ["claude-opus-4-6", "claude-opus-4.6", "anthropic/claude-sonnet-4.5", "claude-haiku-4-5", "claude-opus-4-1-20250805",
                  "claude-sonnet-4-6", "us.anthropic.claude-sonnet-4-5-20250929-v1:0"] {
            XCTAssertTrue(ModelLineage.singleSampler(m), m)
        }
        for m in ["claude-3-7-sonnet-20250219", "claude-sonnet-4-0", "claude-sonnet-4-20250514", "claude-opus-4-20250514",
                  "claude-3-5-haiku", "claude-opus-4-7", "claude-sonnet-5", "gpt-4o", "deepseek-chat", "cc-claude-opus-4-6"] {
            XCTAssertFalse(ModelLineage.singleSampler(m), m)
        }
    }

    func testLineageAnthropicAdaptive() {
        for m in ["claude-opus-4-7", "claude-opus-4.7", "anthropic/claude-opus-4.7", "claude-opus-4-8", "claude-opus-5-5",
                  "claude-sonnet-5", "claude-haiku-5", "claude-fable-5-1", "claude-mythos", "opus-4-7"] {
            XCTAssertTrue(ModelLineage.anthropicAdaptive(m), m)
        }
        for m in ["claude-opus-4-5", "claude-opus-45", "claude-sonnet-4-5", "claude-3-7-sonnet-20250219", "gpt-5", "deepseek-reasoner"] {
            XCTAssertFalse(ModelLineage.anthropicAdaptive(m), m)
        }
    }

    func testReadVersion() {
        XCTAssertEqual(ModelLineage.readVersion("4-7-20260101"), [4, 7])
        XCTAssertEqual(ModelLineage.readVersion("4.7"), [4, 7])
        XCTAssertEqual(ModelLineage.readVersion("1.2.3.4"), [1, 2, 3])
        XCTAssertEqual(ModelLineage.readVersion("4o"), [4])
        XCTAssertEqual(ModelLineage.readVersion("oss-120b"), [])
        XCTAssertEqual(ModelLineage.readVersion("300"), [])
    }
}

// MARK: - compat 分层：学到的 > 目录 > 血统 > 推理档 > 默认

extension ParamCompatTests {
    static let relay = "https://relay.example.com/v1"
    static let official = "https://api.openai.com/v1"
    static let openRouter = "https://openrouter.ai/api/v1"

    func catalog(_ temperature: Bool?) -> (String) -> CatalogModel? {
        { id in
            temperature.map {
                CatalogModel(id: id, providerId: "x", name: id, contextTokens: nil, outputTokens: nil, reasoning: false,
                             reasoningEfforts: [], pricing: nil, temperature: $0)
            }
        }
    }

    func resolve(_ model: String, base: String = ParamCompatTests.relay, type: ProviderType = .openaiCompatible,
                 effort: String = "auto", learned: ParamCompat.Learned? = nil, temperature: Bool? = nil) -> ParamCompat {
        ParamCompat.resolve(providerType: type, baseURL: base, modelId: model, reasoningEffort: effort,
                            learned: learned, store: nil, catalog: catalog(temperature))
    }

    func testResolveLayers() {
        var c = resolve("gpt-4o", learned: .init(groups: [ParamCompat.Group.sampling]), temperature: true)
        XCTAssertFalse(c.sendsSampling, "目录说收、记忆表说不收 → 不发")
        XCTAssertEqual(c.source, .learned)

        c = resolve("deepseek-reasoner", temperature: false)
        XCTAssertFalse(c.sendsSampling)
        XCTAssertEqual(c.source, .catalog)

        c = resolve("gpt-5.4-mini", temperature: true)
        XCTAssertTrue(c.sendsSampling, "目录优先：gpt-5.4 收温度（Q2）")
        XCTAssertEqual(c.source, .catalog)

        c = resolve("openai/gpt-5", base: Self.openRouter, effort: "high")
        XCTAssertFalse(c.sendsSampling, "OpenRouter 上的 gpt-5 也不发（以前照发）")

        c = resolve("anthropic/claude-opus-4.7", base: Self.openRouter)
        XCTAssertFalse(c.sendsSampling)
        XCTAssertEqual(c.source, .lineage)

        c = resolve("gpt-4o")
        XCTAssertTrue(c.sendsSampling)
        XCTAssertEqual(c.source, .lineage)

        c = resolve("deepseek-reasoner")
        XCTAssertTrue(c.sendsSampling)
        XCTAssertEqual(c.source, .default)
    }

    func testResolveEffortRule() {
        XCTAssertFalse(resolve("gpt-4o", effort: "high").sendsSampling, "推理档开着的 OpenAI 血统一律不发，不再只认官方")
        XCTAssertEqual(resolve("gpt-4o", effort: "high").source, .effort)
        XCTAssertTrue(resolve("gpt-4o", effort: "none").sendsSampling)
        XCTAssertTrue(resolve("gpt-5.4-mini", effort: "none", temperature: true).sendsSampling)
        XCTAssertFalse(resolve("gpt-5.4-mini", effort: "low", temperature: true).sendsSampling)
        XCTAssertTrue(resolve("deepseek-chat", effort: "high").sendsSampling, "不是 OpenAI 血统、不是官方地址：推理档不管采样")
        XCTAssertFalse(resolve("some-model", base: Self.official, effort: "high").sendsSampling, "官方地址照旧")
    }

    /// 原 dropsSamplingTemperature 的断言（:138 那条翻转）
    func testFormerOfficialOnlyRuleCases() {
        XCTAssertFalse(resolve("gpt-5", base: Self.official).sendsSampling)
        XCTAssertFalse(resolve("o3", base: Self.official).sendsSampling)
        XCTAssertFalse(resolve("o4-mini", base: Self.official).sendsSampling)
        XCTAssertFalse(resolve("gpt-6-sol", base: Self.official).sendsSampling)
        XCTAssertTrue(resolve("gpt-4o", base: Self.official).sendsSampling)
        XCTAssertTrue(resolve("gpt-4.1-mini", base: Self.official).sendsSampling)
        XCTAssertFalse(resolve("gpt-4o", base: Self.official, effort: "high").sendsSampling)
        XCTAssertFalse(resolve("openai/gpt-5", base: Self.openRouter, effort: "high").sendsSampling, "以前照发，本单要修的")
        XCTAssertTrue(resolve("deepseek-reasoner", base: "https://api.deepseek.com").sendsSampling)
    }

    func testResolveKeysAndThinking() {
        XCTAssertEqual(resolve("gpt-5", base: Self.official).maxTokensKey, "max_completion_tokens")
        XCTAssertEqual(resolve("gpt-5").maxTokensKey, "max_tokens", "非官方默认不猜（Q8）")
        XCTAssertEqual(resolve("gpt-5", learned: .init(maxTokensKey: "max_completion_tokens")).maxTokensKey, "max_completion_tokens")

        XCTAssertTrue(resolve("claude-opus-4.7", type: .anthropic).anthropicAdaptive)
        XCTAssertFalse(resolve("claude-sonnet-4-5", type: .anthropic).anthropicAdaptive)
        XCTAssertFalse(resolve("claude-opus-4.7", type: .anthropic, learned: .init(thinkingFormat: "budget")).anthropicAdaptive)
        XCTAssertTrue(resolve("claude-sonnet-4-5", type: .anthropic, learned: .init(thinkingFormat: "adaptive")).anthropicAdaptive)

        let c = resolve("gpt-4o", learned: .init(groups: [ParamCompat.Group.seed, ParamCompat.Group.streamOptions]))
        XCTAssertTrue(c.sendsSampling)
        XCTAssertEqual(c.dropped, [ParamCompat.Group.seed, ParamCompat.Group.streamOptions])
    }

    func testResolveSingleSampler() {
        XCTAssertTrue(resolve("anthropic/claude-sonnet-4.5", base: Self.openRouter).singleSampler, "OpenRouter 上的 Anthropic 血统也算")
        XCTAssertTrue(resolve("claude-opus-4-6", type: .anthropic).singleSampler)
        XCTAssertFalse(resolve("claude-sonnet-4-0", type: .anthropic).singleSampler)
        let learned = resolve("xctest-relay-claude", learned: .init(groups: [ParamCompat.Group.singleSampler]))
        XCTAssertTrue(learned.singleSampler, "学到的")
        XCTAssertTrue(learned.sendsSampling, "不是整组不收")
        XCTAssertTrue(learned.dropped.isEmpty, "不进 dropped")
        XCTAssertEqual(ParamCompat.Learned(groups: [ParamCompat.Group.singleSampler]).summary, "不发 top_p（和 temperature 只收一个）")
    }

    /// 两个 builder：只收一个的模型，temperature 要发就不发 top_p；temperature 是默认值（不发）时 top_p 照发；思考分支不动
    func testSingleSamplerBodies() {
        var s = SamplingParams()
        s.temperature = 0.7; s.topP = 0.95; s.maxTokens = 8000; s.maxTokensAuto = false
        let msgs: [(role: String, content: String)] = [(role: "user", content: "hi")]

        let anth = AnthropicProvider.buildRequestBody(messages: msgs, model: "claude-opus-4-6", systemPrompt: nil, samplingParams: s)
        XCTAssertEqual(anth["temperature"] as? Double, 0.7)
        XCTAssertNil(anth["top_p"])
        let old = AnthropicProvider.buildRequestBody(messages: msgs, model: "claude-3-7-sonnet-20250219", systemPrompt: nil, samplingParams: s)
        XCTAssertEqual(old["top_p"] as? Double, 0.95, "老模型两个照发")

        var topPOnly = s
        topPOnly.temperature = 1.0
        let anthTopP = AnthropicProvider.buildRequestBody(messages: msgs, model: "claude-opus-4-6", systemPrompt: nil, samplingParams: topPOnly)
        XCTAssertNil(anthTopP["temperature"])
        XCTAssertEqual(anthTopP["top_p"] as? Double, 0.95, "temperature 没发时 top_p 单独发")

        var thinking = s
        thinking.reasoningEffort = "high"
        let anthThinking = AnthropicProvider.buildRequestBody(messages: msgs, model: "claude-opus-4-6", systemPrompt: nil, samplingParams: thinking)
        XCTAssertNotNil(anthThinking["thinking"])
        XCTAssertNil(anthThinking["temperature"])
        XCTAssertEqual(anthThinking["top_p"] as? Double, 0.95, "思考分支本来就只发 top_p，不动")

        let compat = resolve("anthropic/claude-sonnet-4.5", base: Self.openRouter)
        let or = OpenAICompatibleProvider.buildRequestBody(messages: msgs, model: "anthropic/claude-sonnet-4.5", systemPrompt: nil,
                                                           samplingParams: s, compat: ResolvedCompat(params: compat))
        XCTAssertEqual(or["temperature"] as? Double, 0.7)
        XCTAssertNil(or["top_p"])
        let gpt = OpenAICompatibleProvider.buildRequestBody(messages: msgs, model: "gpt-4o", systemPrompt: nil,
                                                            samplingParams: s, compat: ResolvedCompat(params: resolve("gpt-4o")))
        XCTAssertEqual(gpt["top_p"] as? Double, 0.95, "别家照发")
    }

    func testSupportedStripsOnlyThisRequest() {
        var s = SamplingParams()
        s.temperature = 0.7; s.topP = 0.95; s.topK = 40; s.frequencyPenalty = 0.3; s.presencePenalty = 0.2
        s.seed = 7; s.reasoningEffort = "high"; s.maxTokens = 8000

        XCTAssertEqual(ParamCompat.permissive.supported(s), s, "全收：原样")

        var c = ParamCompat()
        c.sendsSampling = false
        let r = c.supported(s)
        XCTAssertEqual([r.temperature, r.topP, r.frequencyPenalty, r.presencePenalty], [1, 1, 0, 0])
        XCTAssertEqual(r.topK, 0)
        XCTAssertEqual(r.seed, 7)
        XCTAssertEqual(r.reasoningEffort, "high")
        XCTAssertEqual(r.maxTokens, 8000)

        c = ParamCompat()
        c.dropped = [ParamCompat.Group.seed, ParamCompat.Group.reasoning]
        let d = c.supported(s)
        XCTAssertEqual(d.seed, -1)
        XCTAssertEqual(d.reasoningEffort, "auto")
        XCTAssertEqual(d.temperature, 0.7)
    }
}

// MARK: - Anthropic：点号写法（needsAdaptive 以前认不出 claude-opus-4.7）

extension ParamCompatTests {
    func testNeedsAdaptiveDotSpelling() {
        XCTAssertTrue(ReasoningEffort.needsAdaptive("claude-opus-4.7"))
        XCTAssertTrue(ReasoningEffort.needsAdaptive("anthropic/claude-sonnet-5"))
        XCTAssertEqual(ReasoningEffort.route(providerType: .anthropic, credentialId: "a", baseURL: "", modelId: "claude-opus-4.7"),
                       .anthropicAdaptive)
    }

    func testAnthropicBodyDotSpellingUsesAdaptiveAndDropsSampling() {
        var s = SamplingParams()
        s.temperature = 0.7; s.topP = 0.97; s.topK = 40; s.maxTokens = 8000; s.maxTokensAuto = false; s.reasoningEffort = "high"
        let body = AnthropicProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "claude-opus-4.7", systemPrompt: nil, samplingParams: s)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        XCTAssertNil(body["top_k"])

        let noOutputConfig = AnthropicProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "claude-opus-4.7", systemPrompt: nil, samplingParams: s,
            compat: ResolvedCompat(params: ParamCompat(sendsSampling: false, dropped: [ParamCompat.Group.outputConfig], anthropicAdaptive: true)))
        XCTAssertEqual((noOutputConfig["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertNil(noOutputConfig["output_config"], "学到不收 output_config")
    }
}
