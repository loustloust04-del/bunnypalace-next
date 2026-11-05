import XCTest
@testable import 记忆花园

/// 模型兼容 P0 阶段 3 · C1：当轮工具续轮回传思考（plan-model-compat-p0 §5.4）。不发真请求
final class ReasoningReplayTests: XCTestCase {

    private static let turn = ToolTurn(calls: [ToolCallBlock(id: "call_1", name: "fs_read", argumentsJSON: "{\"path\":\"a.md\"}")],
                                       results: [ToolResultBlock(toolUseId: "call_1", text: "文件内容", isError: false)])

    private static func capture(_ field: String, text: String = "先想", details: [[String: Any]] = []) -> ReasoningCapture {
        var r = ReasoningCapture()
        r.field = field
        r.text = text
        r.details = details
        return r
    }

    private static func turn(with reasoning: ReasoningCapture?) -> ToolTurn {
        var t = turn
        t.reasoning = reasoning
        return t
    }

    private func resolve(_ baseURL: String, store: ParamAdaptStore? = nil) -> ResolvedCompat {
        ResolvedCompat.resolve(providerType: .openaiCompatible, baseURL: baseURL, modelId: "deepseek-reasoner", sampling: nil,
                               store: store, catalog: { _ in nil })
    }

    private func toolAssistant(_ compat: ResolvedCompat, _ turns: [ToolTurn], tools: [[String: Any]]? = ProviderOrderingScenarios.tool) throws -> [String: Any] {
        let body = OpenAICompatibleProvider.buildRequestBody(messages: [(role: "user", content: "读一下")], model: "deepseek-reasoner",
                                                             systemPrompt: nil, samplingParams: nil, tools: tools, toolTurns: turns,
                                                             compat: compat)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.first { $0["tool_calls"] != nil })
    }

    private func store() -> ParamAdaptStore {
        ParamAdaptStore(defaults: UserDefaults(suiteName: "xctest-replay-\(UUID().uuidString)")!)
    }

    // MARK: - 默认表

    func testDefaultTable() {
        XCTAssertTrue(resolve("https://api.deepseek.com/v1").requiresReasoningContentForToolCalls)
        XCTAssertTrue(resolve("https://api.moonshot.cn/v1").requiresReasoningContentForToolCalls)
        XCTAssertTrue(resolve("https://api.kimi.com/coding/v1").requiresReasoningContentForToolCalls)
        XCTAssertTrue(resolve("https://openrouter.ai/api/v1").requiresReasoningContentForToolCalls)
        XCTAssertFalse(resolve("https://relay.example.com/v1").requiresReasoningContentForToolCalls)
        XCTAssertFalse(resolve("https://api.openai.com/v1").requiresReasoningContentForToolCalls)
        XCTAssertFalse(resolve("https://api.deepseek.com/v1").requiresAssistantContentForToolCalls, "Q12 默认全关")
        let anth = ResolvedCompat.resolve(providerType: .anthropic, baseURL: "https://api.deepseek.com/anthropic", modelId: "deepseek-chat",
                                          sampling: nil, store: nil, catalog: { _ in nil })
        XCTAssertFalse(anth.requiresReasoningContentForToolCalls)
        XCTAssertFalse(anth.splitsLeadingThinkTag)
    }

    // MARK: - 回传字段名

    func testReplayWritesBackSameField() throws {
        let compat = resolve("https://api.deepseek.com/v1")
        for field in ReasoningCapture.textFields {
            let msg = try toolAssistant(compat, [Self.turn(with: Self.capture(field))])
            XCTAssertEqual(msg[field] as? String, "先想", field)
            XCTAssertEqual(Set(msg.keys), ["role", "content", "tool_calls", field], field)
            XCTAssertEqual(msg["content"] as? String, "")
        }
        let tag = try toolAssistant(compat, [Self.turn(with: Self.capture("think_tag"))])
        XCTAssertEqual(tag["reasoning_content"] as? String, "先想", "<think> 拆出来的写 reasoning_content")
        XCTAssertNil(tag["think_tag"])
    }

    func testReplayDetailsVerbatim() throws {
        let details: [[String: Any]] = [
            ["type": "reasoning.text", "text": "想", "signature": "sig", "index": 0, "format": "anthropic-claude-v1"],
            ["type": "reasoning.encrypted", "data": "ENC", "index": 1, "id": "r1"],
        ]
        let msg = try toolAssistant(resolve("https://openrouter.ai/api/v1"), [Self.turn(with: Self.capture("reasoning_details", details: details))])
        let sent = try XCTUnwrap(msg["reasoning_details"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 2)
        for i in 0..<2 { XCTAssertTrue(NSDictionary(dictionary: sent[i]).isEqual(to: details[i]), "第 \(i) 项原样") }
        XCTAssertNil(msg["reasoning"])
    }

    /// 审查 #1：没 index 的两个不同 id 密文块（Gemini 经 OpenRouter）→ 解析成两块、回传原样两块，不串成一块
    func testDetailsWithoutIndexDifferentIdsParseAndReplaySeparately() throws {
        let a: [String: Any] = ["type": "reasoning.encrypted", "id": "call_A", "data": "ENC_A", "format": "google-gemini-v1"]
        let b: [String: Any] = ["type": "reasoning.encrypted", "id": "call_B", "data": "ENC_B", "format": "google-gemini-v1"]
        var r = ReasoningCapture()
        r.absorbDelta(["reasoning_details": [a]])
        r.absorbDelta(["reasoning_details": [b]])
        XCTAssertEqual(r.details.count, 2)
        XCTAssertEqual(r.field, "reasoning_details")
        let msg = try toolAssistant(resolve("https://openrouter.ai/api/v1"), [Self.turn(with: r)])
        let sent = try XCTUnwrap(msg["reasoning_details"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(NSDictionary(dictionary: sent[0]).isEqual(to: a), "第一块身份和密文原样")
        XCTAssertTrue(NSDictionary(dictionary: sent[1]).isEqual(to: b))
    }

    func testDetailsWithoutIndexMergeRules() {
        var noId = ReasoningCapture()
        noId.absorbDelta(["reasoning_details": [["type": "reasoning.encrypted", "data": "E1"]]])
        noId.absorbDelta(["reasoning_details": [["type": "reasoning.encrypted", "data": "E2"]]])
        XCTAssertEqual(noId.details.map { $0["data"] as? String }, ["E1", "E2"], "没身份的密文不拼")

        var sameId = ReasoningCapture()
        sameId.absorbDelta(["reasoning_details": [["type": "reasoning.text", "id": "r1", "text": "先"]]])
        sameId.absorbDelta(["reasoning_details": [["type": "reasoning.text", "id": "r1", "text": "想", "signature": "sig"]]])
        sameId.absorbDelta(["reasoning_details": [["type": "reasoning.text", "id": "r2", "text": "再想"]]])
        XCTAssertEqual(sameId.details.map { $0["text"] as? String }, ["先想", "再想"], "同 id 拼、不同 id 分块")
        XCTAssertEqual(sameId.details.first?["signature"] as? String, "sig")
        XCTAssertEqual(sameId.text, "先想再想")

        var fragments = ReasoningCapture()
        fragments.absorbDelta(["reasoning_details": [["type": "reasoning.text", "text": "一"]]])
        fragments.absorbDelta(["reasoning_details": [["type": "reasoning.text", "text": "二", "signature": "s"]]])
        fragments.absorbDelta(["reasoning_details": [["type": "reasoning.text", "text": "三"]]])
        XCTAssertEqual(fragments.details.map { $0["text"] as? String }, ["一二", "三"], "没身份的文字分片拼到签名为止")
    }

    func testSwitchOffOrNothingCapturedWritesNothing() throws {
        let relay = try toolAssistant(resolve("https://relay.example.com/v1"), [Self.turn(with: Self.capture("reasoning_content"))])
        XCTAssertEqual(Set(relay.keys), ["role", "content", "tool_calls"], "未知中转默认不回传")
        let stripped = try toolAssistant(resolve("https://api.deepseek.com/v1"), [Self.turn(with: nil)])
        XCTAssertEqual(Set(stripped.keys), ["role", "content", "tool_calls"], "没抓到思考：不编占位")
        let empty = try toolAssistant(resolve("https://api.deepseek.com/v1"), [Self.turn(with: ReasoningCapture())])
        XCTAssertEqual(Set(empty.keys), ["role", "content", "tool_calls"])
    }

    func testAssistantContentDotSwitch() throws {
        var compat = resolve("https://api.moonshot.cn/v1")
        compat.requiresAssistantContentForToolCalls = true
        XCTAssertEqual(try toolAssistant(compat, [Self.turn])["content"] as? String, ".")
    }

    /// 预算收尾 tools: nil 那次：droppingThinking 后 reasoning 还在、body 里照样回传
    func testDroppingThinkingKeepsReasoning() throws {
        var t = Self.turn(with: Self.capture("reasoning_content"))
        t.thinkingTokens = 42
        XCTAssertNotNil(t.droppingThinking().reasoning)
        XCTAssertEqual(t.droppingThinking().thinkingTokens, 42, "没有 Anthropic 块：原样返回")
        t.assistantContent = [["type": "thinking", "thinking": "块", "signature": "s"], ["type": "tool_use", "id": "call_1", "name": "fs_read", "input": [String: Any]()]]
        let dropped = t.droppingThinking()
        XCTAssertEqual(dropped.assistantContent?.count, 1)
        XCTAssertNil(dropped.thinkingTokens, "去掉思考块时 thinkingTokens 跟着清，同改前")
        XCTAssertEqual(dropped.reasoning?.text, "先想")
        let msg = try toolAssistant(resolve("https://api.deepseek.com/v1"), [dropped], tools: nil)
        XCTAssertEqual(msg["reasoning_content"] as? String, "先想")
    }

    func testResultsCopyKeepsReasoning() {
        var t = Self.turn(with: Self.capture("reasoning"))
        t.results = [ToolResultBlock(toolUseId: "call_1", text: "改过", isError: false)]
        XCTAssertEqual(t.reasoning?.field, "reasoning")
    }

    // MARK: - 学习

    func testLearnedOverridesDefaultAndGroupsAreExclusive() {
        let s = store()
        let relay = "https://relay.example.com/v1", deepseek = "https://api.deepseek.com/v1"
        s.learn(providerType: .openaiCompatible, baseURL: relay, modelId: "deepseek-reasoner",
                adding: ParamErrorClassifier.learned(from: [.require(ParamCompat.Group.reasoningReplay)]), rawError: "x")
        XCTAssertTrue(resolve(relay, store: s).requiresReasoningContentForToolCalls)
        s.learn(providerType: .openaiCompatible, baseURL: deepseek, modelId: "deepseek-reasoner",
                adding: ParamErrorClassifier.learned(from: [.drop(ParamCompat.Group.reasoningReplay)]), rawError: "x")
        XCTAssertFalse(resolve(deepseek, store: s).requiresReasoningContentForToolCalls)
        s.learn(providerType: .openaiCompatible, baseURL: deepseek, modelId: "deepseek-reasoner",
                adding: ParamErrorClassifier.learned(from: [.require(ParamCompat.Group.reasoningReplay)]), rawError: "x")
        let groups = s.entry(providerType: .openaiCompatible, baseURL: deepseek, modelId: "deepseek-reasoner")?.learned.groups
        XCTAssertEqual(groups, [ParamCompat.Group.reasoningReplayRequired], "后学到的顶掉前一个")
        XCTAssertTrue(resolve(deepseek, store: s).requiresReasoningContentForToolCalls)
        XCTAssertEqual(resolve(deepseek, store: s).params, resolve(deepseek).params, "回传组不进 ParamCompat.dropped")
    }

    func testSummaryAndNotice() {
        var learned = ParamCompat.Learned()
        learned.groups = [ParamCompat.Group.reasoningReplayRequired]
        XCTAssertEqual(learned.summary, "工具续轮回传思考")
        learned.groups = [ParamCompat.Group.reasoningReplay, ParamCompat.Group.seed]
        XCTAssertEqual(learned.summary, "不发 seed · 不回传思考")
        XCTAssertEqual(ParamErrorClassifier.notice([.require(ParamCompat.Group.reasoningReplay)]), "这个模型要在工具续轮回传思考，已自动调整")
        XCTAssertEqual(ParamErrorClassifier.notice([.drop(ParamCompat.Group.reasoningReplay)]), "这个模型不收 回传的思考（reasoning_content），已自动去掉")
    }

    // MARK: - 分类器

    static let deepseek400 = #"{"error":{"message":"The `reasoning_content` in the thinking mode must be passed back to the API.","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#
    static let reasoningText400 = #"{"error":{"message":"The reasoning_text in the thinking mode must be passed back"}}"#
    static let mistral422 = #"{"detail":[{"type":"extra_forbidden","loc":["body","messages",2,"reasoning_content"],"msg":"Extra inputs are not permitted","input":"先想"}]}"#

    static let unknownField400 = #"{"error":{"message":"Unknown field: reasoning_content"}}"#
    static let extraInputs422 = #"{"error":{"message":"Extra inputs are not permitted (messages.2.reasoning_details)"}}"#

    /// 回传字段名是 reasoning、顶层也发了 reasoning（推理档）：「messages.N.reasoning」只关回传，「reasoning: unknown」才关推理强度
    func testMessageReasoningRejectionIsNotTopLevelEffort() {
        var assistant: [String: Any] = ["role": "assistant", "content": "", "tool_calls": [[String: Any]]()]
        assistant["reasoning"] = "先想"
        let both = ParamErrorClassifier.SentShape(body: ["model": "m", "reasoning": ["effort": "high"],
                                                         "messages": [["role": "user", "content": "hi"], assistant]])
        let messageLevel = #"{"error":{"message":"messages.1.reasoning: Extra inputs are not permitted"}}"#
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: messageLevel, sent: both, host: "h"),
                       .fix([.drop(ParamCompat.Group.reasoningReplay)]), "不连带关推理强度")
        let topLevel = #"{"error":{"message":"Unknown parameter: reasoning"}}"#
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: topLevel, sent: both, host: "h"),
                       .fix([.drop(ParamCompat.Group.reasoning)]), "顶层 reasoning 拒收照旧关推理强度、不动回传")
    }

    private func shape(replay: Bool) -> ParamErrorClassifier.SentShape {
        var assistant: [String: Any] = ["role": "assistant", "content": "", "tool_calls": [[String: Any]]()]
        if replay { assistant["reasoning_content"] = "先想" }
        return ParamErrorClassifier.SentShape(body: ["model": "m", "messages": [["role": "user", "content": "hi"], assistant], "max_tokens": 100])
    }

    func testSentShapeRecordsReplay() {
        XCTAssertTrue(shape(replay: true).sentReasoningReplay)
        XCTAssertFalse(shape(replay: false).sentReasoningReplay)
        XCTAssertFalse(ParamErrorClassifier.SentShape(body: ["reasoning": ["effort": "high"], "messages": [["role": "user", "content": "x"]]]).sentReasoningReplay,
                       "顶层 reasoning（OR 推理档）不算回传")
    }

    func testClassifierRequireAndDrop() {
        let require = ParamErrorClassifier.Verdict.fix([.require(ParamCompat.Group.reasoningReplay)])
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: Self.deepseek400, sent: shape(replay: false), host: "api.deepseek.com"), require)
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: Self.reasoningText400, sent: shape(replay: false), host: "h"), require)
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: Self.deepseek400, sent: shape(replay: true), host: "h"), .unknown,
                       "已经回传了还报：不是这个能治的")
        XCTAssertEqual(ParamErrorClassifier.classify(status: 422, body: Self.mistral422, sent: shape(replay: true), host: "h"),
                       .fix([.drop(ParamCompat.Group.reasoningReplay)]))
        XCTAssertEqual(ParamErrorClassifier.classify(status: 422, body: Self.mistral422, sent: shape(replay: false), host: "h"), .unknown,
                       "没真发回传字段时不认")
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: Self.unknownField400, sent: shape(replay: true), host: "h"),
                       .fix([.drop(ParamCompat.Group.reasoningReplay)]), "文字点名 + 拒收词（审查 #5）")
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: Self.unknownField400, sent: shape(replay: false), host: "h"), .unknown)
        XCTAssertEqual(ParamErrorClassifier.classify(status: 422, body: Self.extraInputs422, sent: shape(replay: true), host: "h"),
                       .fix([.drop(ParamCompat.Group.reasoningReplay)]))
        XCTAssertEqual(ParamErrorClassifier.learned(from: [.require(ParamCompat.Group.reasoningReplay)]).groups,
                       [ParamCompat.Group.reasoningReplayRequired])
        XCTAssertEqual(ParamErrorClassifier.learned(from: [.drop(ParamCompat.Group.reasoningReplay)]).groups,
                       [ParamCompat.Group.reasoningReplay])
    }
}

/// 假服务器：400 must be passed back → 记住 + 带字段重发 → 200；下次同端点直接带；没有可回传的思考就不重发、说人话
@MainActor
final class ReasoningReplayRouterTests: XCTestCase {
    typealias Server = OutputTokenCapTests.ScriptedHTTPServer

    private var cleanups: [() -> Void] = []

    override func tearDown() async throws {
        cleanups.forEach { $0() }
        cleanups = []
    }

    private func fixture(_ server: Server) -> (ProviderRouter, ProviderManager, ProviderModel, String) {
        let credentialId = "xctest-replay-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "xctest-relay-deepseek-\(UUID().uuidString.prefix(6))", name: "Replay Test")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "回传测试卡", emoji: "🧠", type: .openaiCompatible,
                                       baseURL: server.baseURL, models: [model], toolsSupported: true))
        pm.setApiKey("test-key", for: credentialId)
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).jsonl"))
        let baseURL = pm.provider(for: model)?.baseURL ?? server.baseURL
        cleanups.append {
            pm.removeCredential(id: credentialId)
            ParamAdaptStore.shared.remove(key: ParamAdaptStore.key(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId))
            server.stop()
        }
        return (router, pm, model, baseURL)
    }

    private enum Outcome: Equatable { case ok(String), error(String) }

    private func send(_ router: ProviderRouter, _ pm: ProviderManager, _ model: ProviderModel, turns: [ToolTurn]) async -> Outcome {
        let done = expectation(description: "done")
        done.assertForOverFulfill = false
        var outcome = Outcome.error("没回调")
        var sampling = SamplingParams()
        sampling.maxTokens = 4096
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "读一下")], systemPrompt: nil, providerManager: pm,
            samplingParams: sampling, tools: ProviderOrderingScenarios.tool, toolTurns: turns,
            onToken: { _ in }, onComplete: { t, _ in outcome = .ok(t); done.fulfill() },
            onError: { outcome = .error($0); done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 5)
        return outcome
    }

    private func assistant(_ data: Data) throws -> [String: Any] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((body["messages"] as? [[String: Any]])?.first { $0["tool_calls"] != nil })
    }

    private static func turn(reasoning: String?) -> ToolTurn {
        var t = ToolTurn(calls: [ToolCallBlock(id: "call_1", name: "fs_read", argumentsJSON: "{}")],
                         results: [ToolResultBlock(toolUseId: "call_1", text: "内容", isError: false)])
        if let reasoning {
            var r = ReasoningCapture()
            r.field = "reasoning_content"
            r.text = reasoning
            t.reasoning = r
        }
        return t
    }

    func testMustBePassedBackLearnsAndRetriesWithField() async throws {
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Data(ReasoningReplayTests.deepseek400.utf8)) : (200, "text/event-stream", OutputTokenCapTests.okText)
        }
        try server.start()
        let (router, pm, model, baseURL) = fixture(server)

        let r1 = await send(router, pm, model, turns: [Self.turn(reasoning: "先想")])
        XCTAssertEqual(r1, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertNil(try assistant(server.requestBodies[0])["reasoning_content"], "未知中转默认不回传")
        XCTAssertEqual(try assistant(server.requestBodies[1])["reasoning_content"] as? String, "先想")
        XCTAssertEqual(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId)?.learned.groups,
                       [ParamCompat.Group.reasoningReplayRequired])
        XCTAssertEqual(router.consumeParamAdaptation(), "这个模型要在工具续轮回传思考，已自动调整")

        let r2 = await send(router, pm, model, turns: [Self.turn(reasoning: "再想")])
        XCTAssertEqual(r2, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 3)
        XCTAssertEqual(try assistant(server.requestBodies[2])["reasoning_content"] as? String, "再想", "学到之后第一次就带")
    }

    func testNoReasoningToReplayDoesNotRetry() async throws {
        let server = try Server { _, _ in (400, "application/json", Data(ReasoningReplayTests.deepseek400.utf8)) }
        try server.start()
        let (router, pm, model, baseURL) = fixture(server)
        guard case .error(let message) = await send(router, pm, model, turns: [Self.turn(reasoning: nil)]) else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 1, "这一轮没有可回传的思考：重发也一样，不重发")
        XCTAssertTrue(message.hasPrefix("这个接口要求把模型上一步的思考原样传回去"), message)
        XCTAssertEqual(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId)?.learned.groups,
                       [ParamCompat.Group.reasoningReplayRequired], "照样记住，下一轮有思考就带")
    }
}
