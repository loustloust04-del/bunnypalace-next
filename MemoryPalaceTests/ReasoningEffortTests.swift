import XCTest
@testable import 记忆花园

/// 思考强度跟着模型走（research-reasoning-effort §2，粟粟 10-02：跟模型记、默认、CC / codex / 本地都要能调；学 magpie）
final class ReasoningEffortTests: XCTestCase {

    private func catalog(_ table: [String: [String]], noReasoning: Set<String> = []) -> (String) -> CatalogModel? {
        { id in
            if noReasoning.contains(id) {
                return CatalogModel(id: id, providerId: "x", name: id, contextTokens: nil, outputTokens: nil,
                                    reasoning: false, reasoningEfforts: [], pricing: nil, temperature: nil)
            }
            guard let e = table[id] else { return nil }
            return CatalogModel(id: id, providerId: "x", name: id, contextTokens: nil, outputTokens: nil,
                                reasoning: true, reasoningEfforts: e, pricing: nil, temperature: nil)
        }
    }

    // MARK: - 走哪条路

    func testRoutes() {
        typealias R = ReasoningEffort.Route
        XCTAssertEqual(ReasoningEffort.route(providerType: .anthropic, credentialId: "a", baseURL: "", modelId: "claude-opus-5-5"), R.anthropicAdaptive)
        XCTAssertEqual(ReasoningEffort.route(providerType: .anthropic, credentialId: "a", baseURL: "", modelId: "claude-opus-4-7"), R.anthropicAdaptive)
        XCTAssertEqual(ReasoningEffort.route(providerType: .anthropic, credentialId: "a", baseURL: "", modelId: "claude-fable-5-1"), R.anthropicAdaptive)
        XCTAssertEqual(ReasoningEffort.route(providerType: .anthropic, credentialId: "a", baseURL: "", modelId: "claude-sonnet-4-5"), R.anthropicBudget)
        XCTAssertEqual(ReasoningEffort.route(providerType: .openaiCompatible, credentialId: "o", baseURL: "https://openrouter.ai/api/v1", modelId: "x"), R.openRouter)
        XCTAssertEqual(ReasoningEffort.route(providerType: .openaiCompatible, credentialId: "o", baseURL: "https://api.openai.com/v1", modelId: "gpt-5.5"), R.chatCompletions)
        XCTAssertEqual(ReasoningEffort.route(providerType: .chatgptOAuth, credentialId: "c", baseURL: "", modelId: "gpt-5.5"), R.responses)
        XCTAssertEqual(ReasoningEffort.route(providerType: .ccBridge, credentialId: "cc-bridge", baseURL: "", modelId: "cc"), R.claudeCode)
        XCTAssertEqual(ReasoningEffort.route(providerType: .ccBridge, credentialId: "codex-bridge", baseURL: "", modelId: "codex-local"), R.codex)
        XCTAssertEqual(ReasoningEffort.route(providerType: .localMLX, credentialId: "l", baseURL: "", modelId: "qwen3-4b-4bit"), R.local)
    }

    // MARK: - 档位

    func testLevelsFromCatalogFirst() {
        let cat = catalog(["gpt-5.5": ["none", "low", "medium", "high", "xhigh"], "claude-opus-5-5": ["low", "medium", "high", "xhigh", "max"]])
        XCTAssertEqual(ReasoningEffort.levels(route: .chatCompletions, modelId: "gpt-5.5", catalog: cat), ["none", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(ReasoningEffort.levels(route: .anthropicAdaptive, modelId: "claude-opus-5-5", catalog: cat), ["low", "medium", "high", "xhigh", "max"])
    }

    func testLevelsFallbacks() {
        let cat = catalog([:], noReasoning: ["kimi-k2"])
        XCTAssertEqual(ReasoningEffort.levels(route: .anthropicBudget, modelId: "claude-sonnet-4-5", catalog: cat), ["low", "medium", "high", "max"])
        XCTAssertEqual(ReasoningEffort.levels(route: .anthropicAdaptive, modelId: "claude-opus-4-7", catalog: cat), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ReasoningEffort.levels(route: .chatCompletions, modelId: "kimi-k2", catalog: cat), [], "目录说不推理：只有默认")
        XCTAssertEqual(ReasoningEffort.levels(route: .chatCompletions, modelId: "mystery", catalog: cat), ["low", "medium", "high"], "不知道：给通用三档")
        XCTAssertEqual(ReasoningEffort.levels(route: .claudeCode, modelId: "cc", catalog: cat), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ReasoningEffort.levels(route: .codex, modelId: "codex-local", catalog: cat), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(ReasoningEffort.levels(route: .local, modelId: "qwen3-4b-4bit", catalog: cat), ["none", "high"])
    }

    // MARK: - 最近一档（学 magpie nearestEffort）

    func testNearest() {
        XCTAssertEqual(ReasoningEffort.nearest("xhigh", in: ["low", "medium", "high"]), "high")
        XCTAssertEqual(ReasoningEffort.nearest("medium", in: ["low", "high"]), "high", "一样近取高的")
        XCTAssertEqual(ReasoningEffort.nearest("minimal", in: ["none", "low", "high"]), "low", "不往 none 上靠")
        XCTAssertEqual(ReasoningEffort.nearest("high", in: ["low", "high"]), "high")
        XCTAssertEqual(ReasoningEffort.nearest("auto", in: ["low"]), "auto")
        XCTAssertEqual(ReasoningEffort.nearest("high", in: []), "auto", "没有档位就用默认")
        XCTAssertEqual(ReasoningEffort.nearest("none", in: ["low", "high"]), "low", "关不了的模型：取最低")
    }

    // MARK: - 跟模型记

    private func freshDefaults() -> UserDefaults {
        let name = "ReasoningEffortTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testPerModelStoreAndEffectiveValue() {
        let d = freshDefaults()
        XCTAssertNil(ReasoningEffort.stored(credentialId: "c", modelId: "m", defaults: d))
        ReasoningEffort.store("xhigh", credentialId: "c", modelId: "m", defaults: d)
        XCTAssertEqual(ReasoningEffort.stored(credentialId: "c", modelId: "m", defaults: d), "xhigh")
        XCTAssertNil(ReasoningEffort.stored(credentialId: "c", modelId: "other", defaults: d), "别的模型各记各的")
        // 记过的优先；没记过拿预设当起点；都按当前模型的档位取最近
        XCTAssertEqual(ReasoningEffort.effective(stored: "xhigh", presetDefault: "low", levels: ["low", "medium", "high"]), "high")
        XCTAssertEqual(ReasoningEffort.effective(stored: nil, presetDefault: "medium", levels: ["low", "high"]), "high")
        XCTAssertEqual(ReasoningEffort.effective(stored: nil, presetDefault: "auto", levels: ["low", "high"]), "auto")
        XCTAssertEqual(ReasoningEffort.effective(stored: "auto", presetDefault: "high", levels: ["low", "high"]), "auto", "记过「默认」就是默认")
    }

    func testLabels() {
        XCTAssertEqual(ReasoningEffort.label("auto"), "默认")
        XCTAssertEqual(ReasoningEffort.label("none"), "关")
        XCTAssertEqual(ReasoningEffort.label("high"), "高")
        XCTAssertEqual(ReasoningEffort.label("xhigh"), "更高")
        XCTAssertEqual(ReasoningEffort.label("max"), "极限")
        XCTAssertEqual(ReasoningEffort.label("high", route: .local), "开", "本地只有开 / 关")
    }

    // MARK: - 怎么发

    func testAnthropicAdaptiveBody() {
        let wire = ReasoningEffort.anthropicThinking(route: .anthropicAdaptive, effort: "xhigh", visible: 8000, limit: 64000)
        XCTAssertEqual(wire.thinking?["type"] as? String, "adaptive")
        XCTAssertEqual(wire.outputConfig?["effort"] as? String, "xhigh")
        XCTAssertEqual(wire.maxTokens, 8000 + 16000, "留出思考的余量")
        XCTAssertTrue(wire.thinkingOn)
        let off = ReasoningEffort.anthropicThinking(route: .anthropicAdaptive, effort: "auto", visible: 8000, limit: 64000)
        XCTAssertNil(off.thinking); XCTAssertNil(off.outputConfig); XCTAssertEqual(off.maxTokens, 8000); XCTAssertFalse(off.thinkingOn)
    }

    func testAnthropicBudgetBodyIncludingMax() {
        let wire = ReasoningEffort.anthropicThinking(route: .anthropicBudget, effort: "max", visible: 8000, limit: 64000)
        XCTAssertEqual(wire.thinking?["type"] as? String, "enabled")
        XCTAssertEqual(wire.thinking?["budget_tokens"] as? Int, 32000, "Max 不再被丢")
        XCTAssertNil(wire.outputConfig)
        let high = ReasoningEffort.anthropicThinking(route: .anthropicBudget, effort: "high", visible: 8000, limit: 64000)
        XCTAssertEqual(high.thinking?["budget_tokens"] as? Int, 10000, "老模型 high 档和以前一样")
    }

    func testChatCompletionsFields() {
        var body: [String: Any] = [:]
        ReasoningEffort.applyChatCompletions(route: .openRouter, effort: "high", to: &body)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil(body["reasoning_effort"])
        body = [:]
        ReasoningEffort.applyChatCompletions(route: .chatCompletions, effort: "none", to: &body)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        body = [:]
        ReasoningEffort.applyChatCompletions(route: .chatCompletions, effort: "auto", to: &body)
        XCTAssertTrue(body.isEmpty)
    }

    func testOpenAIKeepsTemperatureWhenEffortNone() {
        XCTAssertFalse(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: "https://api.openai.com/v1", model: "gpt-4o", reasoningEffort: "none"))
        XCTAssertTrue(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: "https://api.openai.com/v1", model: "gpt-4o", reasoningEffort: "high"))
    }

    func testCCSendFrameCarriesEffort() {
        let frame = CCBridgeWebSocketClient.sendFrame(chatId: "c", messageId: "m", content: "hi", user: "u",
                                                      session: "mp-cc", replyTo: nil, attachments: [], effort: "xhigh")
        XCTAssertEqual(frame["effort"] as? String, "xhigh")
        let plain = CCBridgeWebSocketClient.sendFrame(chatId: "c", messageId: "m", content: "hi", user: "u",
                                                      session: "mp-cc", replyTo: nil, attachments: [], effort: "auto")
        XCTAssertNil(plain["effort"], "默认不带")
    }

    // MARK: - 本地：<think> 收进思考气泡

    func testThinkTagConverterAcrossChunks() {
        let c = ThinkTagConverter()
        let out = ["<thi", "nk>\n想一想", "</th", "ink>\n\n答案", "<"].map { c.feed($0) }.joined() + c.flush()
        XCTAssertEqual(out, "[thinking]\n想一想[/thinking]\n\n答案<")
    }
}
