import XCTest
@testable import 记忆花园

/// thinking 回传 §3.5：「默认」档的新模型显式 adaptive + 默认档余量、display 跟「思考过程」设置、老模型不发 display
final class ThinkingParamTests: XCTestCase {

    private var savedDisplayMode: Any?

    override func setUp() {
        super.setUp()
        savedDisplayMode = UserDefaults.standard.object(forKey: DisclosureKind.thinking.key)
    }

    override func tearDown() {
        if let savedDisplayMode {
            UserDefaults.standard.set(savedDisplayMode, forKey: DisclosureKind.thinking.key)
        } else {
            UserDefaults.standard.removeObject(forKey: DisclosureKind.thinking.key)
        }
        super.tearDown()
    }

    private func wire(_ model: String, effort: String = "auto", summarize: Bool = true, visible: Int = 32768,
                      thinkingAllowed: Bool = true, displayAllowed: Bool = true) -> ReasoningEffort.AnthropicWire {
        ReasoningEffort.anthropicThinking(route: ReasoningEffort.needsAdaptive(model) ? .anthropicAdaptive : .anthropicBudget,
                                          effort: effort, visible: visible, limit: 128_000, modelId: model, summarize: summarize,
                                          thinkingAllowed: thinkingAllowed, displayAllowed: displayAllowed)
    }

    func testDefaultTierOnModelsThatThinkByDefault() {
        let opus = wire("claude-opus-5-5")
        XCTAssertEqual(opus.thinking?["type"] as? String, "adaptive")
        XCTAssertEqual(opus.thinking?["display"] as? String, "summarized")
        XCTAssertNil(opus.outputConfig, "默认档不发 output_config（档位还是官方默认）")
        XCTAssertEqual(opus.maxTokens, 32768 + 4096, "opus 5.5 默认 medium：留 4096 余量")
        XCTAssertEqual(wire("claude-sonnet-5").maxTokens, 32768 + 10000, "sonnet 5 默认 high")
        XCTAssertEqual(wire("claude-opus-5-5", visible: 126_000).maxTokens, 128_000, "总数不超过模型上限")
    }

    func testDefaultTierStaysOffOnOlderModels() {
        for m in ["claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-haiku-5"] {
            let w = wire(m)
            XCTAssertNil(w.thinking, m)
            XCTAssertEqual(w.maxTokens, 32768, m)
        }
        XCTAssertNil(ReasoningEffort.anthropicThinking(route: .anthropicAdaptive, effort: "auto", visible: 8000, limit: nil).thinking,
                     "不给 modelId（老调用点）照旧不发")
    }

    func testDisplayRules() {
        XCTAssertNil(wire("claude-opus-5-5", summarize: false).thinking?["display"], "思考过程隐藏：不要摘要（omitted 首字更快）")
        XCTAssertNil(wire("claude-opus-5-5", displayAllowed: false).thinking?["display"], "学到中转不认 display")
        let picked = wire("claude-opus-4-7", effort: "high")
        XCTAssertEqual(picked.thinking?["display"] as? String, "summarized", "opus 4.7 默认 omitted：选了档也要摘要")
        XCTAssertEqual(picked.outputConfig?["effort"] as? String, "high")
        XCTAssertEqual(picked.maxTokens, 32768 + 10000)
        let old = wire("claude-sonnet-4-5", effort: "high")
        XCTAssertEqual(old.thinking?["type"] as? String, "enabled")
        XCTAssertNil(old.thinking?["display"], "默认就是摘要的老模型不发 display")
    }

    func testThinkingNotAllowedSendsNothing() {
        let w = wire("claude-opus-5-5", thinkingAllowed: false)
        XCTAssertNil(w.thinking)
        XCTAssertNil(w.outputConfig)
        XCTAssertEqual(w.maxTokens, 32768)
    }

    func testBuilderFollowsDisplaySettingAndLearnedGroups() {
        var s = SamplingParams()
        s.maxTokens = 32768
        func build(_ compat: ParamCompat? = nil) -> [String: Any] {
            AnthropicProvider.buildRequestBody(messages: [(role: "user", content: "hi")], model: "claude-opus-5-5", systemPrompt: nil,
                                               samplingParams: s, compat: compat.map { ResolvedCompat(params: $0) })
        }
        UserDefaults.standard.set(DisclosureMode.inline.rawValue, forKey: DisclosureKind.thinking.key)
        var b = build()
        XCTAssertEqual((b["thinking"] as? [String: Any])?["display"] as? String, "summarized")
        XCTAssertEqual(b["max_tokens"] as? Int, 32768 + 4096)
        XCTAssertNil(b["output_config"])
        XCTAssertNil(b["temperature"]); XCTAssertNil(b["top_p"]); XCTAssertNil(b["top_k"])

        UserDefaults.standard.set(DisclosureMode.hidden.rawValue, forKey: DisclosureKind.thinking.key)
        b = build()
        XCTAssertEqual((b["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertNil((b["thinking"] as? [String: Any])?["display"])

        UserDefaults.standard.set(DisclosureMode.sheet.rawValue, forKey: DisclosureKind.thinking.key)
        var compat = ParamCompat()
        compat.anthropicAdaptive = true
        compat.dropped = [ParamCompat.Group.thinkingDisplay]
        b = build(compat)
        XCTAssertEqual((b["thinking"] as? [String: Any])?["type"] as? String, "adaptive", "只去 display，思考照开")
        XCTAssertNil((b["thinking"] as? [String: Any])?["display"])
        compat.dropped = [ParamCompat.Group.reasoning]
        XCTAssertNil(build(compat)["thinking"], "学到不收思考参数：默认档也不发")
    }

    func testBudgetEstimateAddsThinkingHeadroom() {
        var s = SamplingParams()
        s.maxTokens = 32768
        XCTAssertEqual(OutputTokenCap.budgetEstimate(s, modelId: "claude-opus-5-5"), 4096 + 4096)
        XCTAssertEqual(OutputTokenCap.budgetEstimate(s, modelId: "claude-sonnet-4-6"), 4096)
        XCTAssertEqual(OutputTokenCap.budgetEstimate(s, modelId: "gpt-4o"), 4096)
        s.reasoningEffort = "high"
        XCTAssertEqual(OutputTokenCap.budgetEstimate(s, modelId: "claude-sonnet-4-6"), 4096 + 10000)
    }
}
