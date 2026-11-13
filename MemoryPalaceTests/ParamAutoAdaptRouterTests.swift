import XCTest
@testable import 记忆花园

/// #094 400 自愈（plan-param-autoadapt §4.2）：本机假服务器（ScriptedHTTPServer），不发真请求
@MainActor
final class ParamAutoAdaptRouterTests: XCTestCase {
    typealias Server = ScriptedHTTPServer

    static let temperature400 = Data(#"{"error":{"message":"Unsupported value: 'temperature' does not support 0.7 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#.utf8)
    static let maxTokens400 = Data(#"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","type":"invalid_request_error","param":"max_tokens","code":"unsupported_parameter"}}"#.utf8)
    static let both400 = Data(#"[{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","param":"max_tokens","code":"unsupported_parameter"}},{"error":{"message":"Unsupported value: 'temperature' does not support 0.7 with this model. Only the default (1) value is supported.","param":"temperature","code":"unsupported_value"}}]"#.utf8)
    static let fastAPI422 = Data(#"{"detail":[{"type":"extra_forbidden","loc":["body","top_p"],"msg":"Extra inputs are not permitted","input":0.95}]}"#.utf8)
    static let bothSamplers400 = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` and `top_p` cannot both be specified for this model. Please use only one."}}"#.utf8)
    static let prefill400 = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"This model does not support assistant message prefill."}}"#.utf8)

    private var cleanups: [() -> Void] = []

    override func tearDown() async throws {
        cleanups.forEach { $0() }
        cleanups = []
    }

    private func sampling(_ maxTokens: Int = 4096) -> SamplingParams {
        var s = SamplingParams()
        s.maxTokens = maxTokens
        return s
    }

    private func fixture(_ server: Server, modelId: String = "xctest-unknown-model",
                         type: ProviderType = .openaiCompatible) -> (ProviderRouter, ProviderManager, ProviderModel) {
        let credentialId = "xctest-adapt-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: modelId, name: "Adapt Test")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "自适配测试卡", emoji: "✂️", type: type,
                                       baseURL: server.baseURL, models: [model], toolsSupported: true))
        pm.setApiKey("test-key", for: credentialId)
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("adapt-\(UUID().uuidString).jsonl"))
        let baseURL = pm.provider(for: model)?.baseURL ?? server.baseURL
        cleanups.append {
            pm.removeCredential(id: credentialId)
            ParamAdaptStore.shared.remove(key: ParamAdaptStore.key(providerType: type, baseURL: baseURL, modelId: modelId))
            server.stop()
        }
        return (router, pm, model)
    }

    private enum Outcome: Equatable { case ok(String), error(String) }

    private func send(_ router: ProviderRouter, _ pm: ProviderManager, _ model: ProviderModel,
                      sampling: SamplingParams? = nil) async -> Outcome {
        let done = expectation(description: "done")
        done.assertForOverFulfill = false
        var outcome = Outcome.error("没回调")
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
            providerManager: pm, samplingParams: sampling ?? self.sampling(),
            onToken: { _ in }, onComplete: { t, _ in outcome = .ok(t); done.fulfill() },
            onError: { outcome = .error($0); done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 5)
        return outcome
    }

    private func body(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTemperature400RetriesOnceWithoutSamplingAndRemembers() async throws {
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Self.temperature400) : (200, "text/event-stream", OutputTokenCapTests.okText)
        }
        try server.start()
        let (router, pm, model) = fixture(server)

        let r1 = await send(router, pm, model)
        XCTAssertEqual(r1, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let first = try body(server.requestBodies[0]), second = try body(server.requestBodies[1])
        XCTAssertEqual(first["temperature"] as? Double, 0.7)
        XCTAssertNil(second["temperature"])
        XCTAssertNil(second["top_p"])
        XCTAssertEqual(second["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(router.ledger.load().map(\.status), [.error, .ok], "被拒那次也记账")
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        XCTAssertEqual(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId)?.learned.groups, [ParamCompat.Group.sampling])
        XCTAssertEqual(router.consumeParamAdaptation(), "这个模型不收 temperature / top_p，已自动去掉", "聊天小灰字")
        XCTAssertNil(router.consumeParamAdaptation(), "取一次就清")

        // 学到之后：第一次就不带，不再 400
        let r2 = await send(router, pm, model)
        XCTAssertEqual(r2, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 3)
        XCTAssertNil(try body(server.requestBodies[2])["temperature"])
        XCTAssertNil(router.consumeParamAdaptation(), "学到之后不再提示")
    }

    /// 粟粟 10-14 Opus 4.6：认不出血统的名字（中转起的）撞「cannot both be specified」→ 只去 top_p 重发一次、记住、闪提示
    func testBothSamplers400DropsTopPOnly() async throws {
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Self.bothSamplers400) : (200, "text/event-stream", OutputTokenCapTests.okText)
        }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "xctest-relay-claude")

        let r1 = await send(router, pm, model)
        XCTAssertEqual(r1, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let first = try body(server.requestBodies[0]), second = try body(server.requestBodies[1])
        XCTAssertEqual(first["top_p"] as? Double, 0.95)
        XCTAssertEqual(second["temperature"] as? Double, 0.7, "temperature 留着")
        XCTAssertNil(second["top_p"])
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        XCTAssertEqual(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId)?.learned.groups,
                       [ParamCompat.Group.singleSampler])
        XCTAssertEqual(router.consumeParamAdaptation(), "这个模型 temperature 和 top_p 只收一个，已去掉 top_p")

        let r2 = await send(router, pm, model)
        XCTAssertEqual(r2, .ok("ok"))
        let third = try body(server.requestBodies[2])
        XCTAssertEqual(third["temperature"] as? Double, 0.7)
        XCTAssertNil(third["top_p"], "学到之后第一次就只发一个")
    }

    func testTwo400sStopAfterOneRetry() async throws {
        let server = try Server { _, _ in (400, "application/json", Self.temperature400) }
        try server.start()
        let (router, pm, model) = fixture(server)
        guard case .error(let message) = await send(router, pm, model) else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 2, "只重试一次")
        XCTAssertTrue(message.contains("Unsupported value"), message)
    }

    func testRenameKeyKeepsCap() async throws {
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Self.maxTokens400) : (200, "text/event-stream", OutputTokenCapTests.okText)
        }
        try server.start()
        let (router, pm, model) = fixture(server)
        let r3 = await send(router, pm, model)
        XCTAssertEqual(r3, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let second = try body(server.requestBodies[1])
        XCTAssertEqual(second["max_completion_tokens"] as? Int, 16_384, "改键名，不降 8192（修 R8 误伤）")
        XCTAssertNil(second["max_tokens"])
    }

    func testRenameAndDropInOneRetry() async throws {
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Self.both400) : (200, "text/event-stream", OutputTokenCapTests.okText)
        }
        try server.start()
        let (router, pm, model) = fixture(server)
        let r4 = await send(router, pm, model)
        XCTAssertEqual(r4, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let second = try body(server.requestBodies[1])
        XCTAssertEqual(second["max_completion_tokens"] as? Int, 16_384)
        XCTAssertNil(second["temperature"])
    }

    func testFastAPI422Retries() async throws {
        let server = try Server { index, _ in
            index == 0 ? (422, "application/json", Self.fastAPI422) : (200, "text/event-stream", OutputTokenCapTests.okText)
        }
        try server.start()
        let (router, pm, model) = fixture(server)
        let r5 = await send(router, pm, model)
        XCTAssertEqual(r5, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertNil(try body(server.requestBodies[1])["top_p"])
    }

    func testNon400AndExplainDoNotRetry() async throws {
        for status in [500, 429] {
            let server = try Server { _, _ in (status, "application/json", Self.temperature400) }
            try server.start()
            let (router, pm, model) = fixture(server)
            router.retryDelay = { _ in 0 }
            guard case .error = await send(router, pm, model) else { return XCTFail() }
            XCTAssertEqual(server.requestBodies.count, 3, "HTTP \(status) 不进参数自愈，只走服务器重试（plan-model-compat-p0 §7.4）")
            for data in server.requestBodies {
                XCTAssertEqual(try body(data)["temperature"] as? Double, 0.7, "HTTP \(status) 不碰参数")
            }
            let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
            XCTAssertNil(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId))
        }
        let server = try Server { _, _ in (400, "application/json", Self.prefill400) }
        try server.start()
        let (router, pm, model) = fixture(server)
        guard case .error = await send(router, pm, model) else { return XCTFail() }
        XCTAssertEqual(server.requestBodies.count, 1, "预填说人话不重试（Q7）")
    }

    func testErrorAfterOutputDoesNotRetry() async throws {
        let partial = OutputTokenCapTests.sse([
            #"data: {"choices":[{"delta":{"content":"写到一半"}}]}"#,
            #"data: {"error":{"message":"'temperature' is not supported","type":"invalid_request_error"}}"#,
        ])
        let server = try Server { _, _ in (200, "text/event-stream", partial) }
        try server.start()
        let (router, pm, model) = fixture(server)
        _ = await send(router, pm, model)
        XCTAssertEqual(server.requestBodies.count, 1, "已经收到输出 → 不重试")
    }

    func testUnknown400GetsHostModelStatusTail() async throws {
        let html = Data("<html><body>400 Bad Request</body></html>".utf8)
        let server = try Server { _, _ in (400, "text/html", html) }
        try server.start()
        let (router, pm, model) = fixture(server)
        guard case .error(let message) = await send(router, pm, model) else { return XCTFail() }
        XCTAssertEqual(server.requestBodies.count, 1)
        XCTAssertEqual(message, "API 错误 (400)（127.0.0.1 · xctest-unknown-model · HTTP 400）")
    }

    func testPrefillExplainedInPlainWords() async throws {
        let server = try Server { _, _ in (400, "application/json", Self.prefill400) }
        try server.start()
        let (router, pm, model) = fixture(server)
        guard case .error(let message) = await send(router, pm, model) else { return XCTFail() }
        XCTAssertEqual(message, "这个模型不收预填（预设里深度 0 的 assistant 段 / 续写预填），去预设里关掉。原文：This model does not support assistant message prefill.（127.0.0.1 · xctest-unknown-model · HTTP 400）")
    }

    /// astra #1：被拒那次预算扣 0（账本照记 .error），余额只够一次请求时自愈重试照样发得出去
    func testRejectedRequestChargesNoBudgetSoRetryFits() async throws {
        let store = GlobalBudgetStore.shared
        let snapshot = (enabled: store.enabled, isSet: store.isBudgetSet, budget: store.budgetUSD, spent: store.spentUSD,
                        resetAt: UserDefaults.standard.object(forKey: "globalSpentResetAt"))
        defer {
            store.setEnabled(snapshot.enabled)
            if snapshot.isSet { store.setBudgetUSD(snapshot.budget) } else { store.clearBudget() }
            store.resetSpent()
            store.commitSpend(snapshot.spent)
            if let resetAt = snapshot.resetAt { UserDefaults.standard.set(resetAt, forKey: "globalSpentResetAt") }
            else { UserDefaults.standard.removeObject(forKey: "globalSpentResetAt") }
        }
        store.setEnabled(true)
        store.setBudgetUSD(100)
        store.resetSpent()

        // 先量一次这份 body 的预估：认不出的 400 不重试，按预估扣
        let probe = try Server { _, _ in (400, "text/html", Data("<html>bad</html>".utf8)) }
        try probe.start()
        let (probeRouter, probePM, probeModel) = fixture(probe, modelId: "gpt-4o")
        _ = await send(probeRouter, probePM, probeModel)
        let estimate = store.spentUSD
        XCTAssertGreaterThan(estimate, 0)

        store.resetSpent()
        store.setBudgetUSD(estimate * 1.5)   // 只够一次
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Self.temperature400) : (200, "text/event-stream", OutputTokenCapTests.okText)
        }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "gpt-4o")
        let r = await send(router, pm, model)
        XCTAssertEqual(r, .ok("ok"), "被拒那次不占预算，重试过得了闸")
        XCTAssertEqual(server.requestBodies.count, 2)
        let rows = router.ledger.load()
        XCTAssertEqual(rows.map(\.status), [.error, .ok])
        XCTAssertEqual(rows.first?.budgetChargeUSD, 0)
    }

    /// astra #5：429 / 500 正文提到 max_tokens 也不降上限、不重发
    func testNonParamStatusWithLimitTextDoesNotRetry() async throws {
        let body = Data(#"{"error":{"message":"Rate limit reached; reduce max_tokens or retry later"}}"#.utf8)
        for status in [429, 500] {
            let server = try Server { _, _ in (status, "application/json", body) }
            try server.start()
            let (router, pm, model) = fixture(server)
            router.retryDelay = { _ in 0 }
            guard case .error = await send(router, pm, model) else { return XCTFail() }
            XCTAssertEqual(server.requestBodies.count, 3, "HTTP \(status) 只走服务器重试（plan-model-compat-p0 §7.4）")
            for data in server.requestBodies {
                XCTAssertEqual(try self.body(data)["max_tokens"] as? Int, 16_384, "HTTP \(status) 上限没动")
            }
            XCTAssertEqual(router.lastRequestedMaxTokens, 16_384, "上限没动")
        }
    }

    /// astra #2：报错正文里带当前 key、metadata.raw 里带 ?key= → 气泡、记忆表、日志都看不到
    func testErrorTextAndStoreAreRedacted() async throws {
        let raw = #"{"error":{"message":"Provider returned error (key test-key)","code":400,"metadata":{"raw":"{\"error\":{\"message\":\"`temperature` is deprecated for this model. POST https://up.example/v1/messages?key=UPSECRET\"}}"}}}"#
        let server = try Server { _, _ in (400, "application/json", Data(raw.utf8)) }
        try server.start()
        let (router, pm, model) = fixture(server)
        guard case .error(let message) = await send(router, pm, model) else { return XCTFail() }
        XCTAssertEqual(server.requestBodies.count, 2, "认得出 temperature → 重试一次")
        XCTAssertFalse(message.contains("test-key"), message)
        XCTAssertFalse(message.contains("UPSECRET"), message)
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        let stored = try XCTUnwrap(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId))
        XCTAssertFalse(stored.rawError.contains("test-key"), stored.rawError)
        XCTAssertFalse(stored.rawError.contains("UPSECRET"), stored.rawError)
        try await Task.sleep(nanoseconds: 200_000_000)   // CacheDiagLog 异步落到主线程
        let logged = CacheDiagLog.shared.entries.filter { $0.text.contains("参数自适配") }
        XCTAssertFalse(logged.isEmpty)
        XCTAssertFalse(logged.contains { $0.text.contains("UPSECRET") || $0.text.contains("test-key") })
    }

    /// astra #3：开着 adaptive 思考、报「prefill is not supported with adaptive thinking」→ 说人话，不换格式、不学、不重试
    func testPrefillWithAdaptiveThinkingDoesNotLearnBudget() async throws {
        let errorJSON = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Assistant prefill is not supported with adaptive thinking."}}"#.utf8)
        let server = try Server { _, _ in (400, "application/json", errorJSON) }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-opus-5-5", type: .anthropic)
        var s = sampling()
        s.reasoningEffort = "high"
        guard case .error(let message) = await send(router, pm, model, sampling: s) else { return XCTFail() }
        XCTAssertEqual(server.requestBodies.count, 1)
        XCTAssertEqual((try body(server.requestBodies[0])["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertTrue(message.hasPrefix("这个模型不收预填"), message)
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        XCTAssertNil(ParamAdaptStore.shared.entry(providerType: .anthropic, baseURL: baseURL, modelId: model.modelId))
    }

    // MARK: - thinking 回传 §3.6

    static let anthropicOK = Data((ThinkingStreamTests.start(0, ["type": "text", "text": ""])
        + ThinkingStreamTests.delta(0, ["type": "text_delta", "text": "ok"]) + ThinkingStreamTests.stop(0)
        + ThinkingStreamTests.event("message_delta", ["delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]])
        + ThinkingStreamTests.event("message_stop", [:])).utf8)
    static let signature400 = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block"}}"#.utf8)
    static let display400 = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"thinking.display: Extra inputs are not permitted"}}"#.utf8)

    private func lastAssistantTypes(_ data: Data) throws -> [String] {
        let messages = try XCTUnwrap(try body(data)["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last { $0["role"] as? String == "assistant" }?["content"] as? [[String: Any]])
        return content.compactMap { $0["type"] as? String }
    }

    /// 当轮思考块被拒：不学不记，这一次去掉思考块重发一次，小灰字说一声
    func testThinkingBlocksRejectedRetriesOnceWithoutThem() async throws {
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Self.signature400) : (200, "text/event-stream", Self.anthropicOK)
        }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-opus-5-5", type: .anthropic)
        let turn = ToolTurn(calls: [ToolCallBlock(id: "toolu_1", name: "fs_read", argumentsJSON: #"{"path":"a"}"#)],
                            results: [ToolResultBlock(toolUseId: "toolu_1", text: "r", isError: false)],
                            assistantContent: ThinkingReplayTests.content.map { block in
                                block["type"] as? String == "tool_use" ? ["type": "tool_use", "id": "toolu_1", "name": "fs_read", "input": ["path": "a"]] : block
                            })
        let done = expectation(description: "done")
        var outcome = Outcome.error("没回调")
        router.sendStreaming(model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil, providerManager: pm,
                             samplingParams: sampling(), toolTurns: [turn],
                             onToken: { _ in }, onComplete: { t, _ in outcome = .ok(t); done.fulfill() },
                             onError: { outcome = .error($0); done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertEqual(try lastAssistantTypes(server.requestBodies[0]), ["thinking", "text", "thinking", "tool_use"])
        XCTAssertEqual(try lastAssistantTypes(server.requestBodies[1]), ["text", "tool_use"], "重发那次去掉思考块，其余照旧")
        XCTAssertEqual(router.consumeParamAdaptation(), "思考块没被接受，这一次没带")
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        XCTAssertNil(ParamAdaptStore.shared.entry(providerType: .anthropic, baseURL: baseURL, modelId: model.modelId), "不学")
    }

    /// 中转不认 thinking.display：只去 display、记住，思考照开
    func testThinkingDisplayRejectedDropsOnlyDisplay() async throws {
        let key = DisclosureKind.thinking.key
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(DisclosureMode.inline.rawValue, forKey: key)
        cleanups.append { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", Self.display400) : (200, "text/event-stream", Self.anthropicOK)
        }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-opus-5-5", type: .anthropic)
        let outcome = await send(router, pm, model)
        XCTAssertEqual(outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let first = try XCTUnwrap(try body(server.requestBodies[0])["thinking"] as? [String: Any])
        let second = try XCTUnwrap(try body(server.requestBodies[1])["thinking"] as? [String: Any])
        XCTAssertEqual(first["display"] as? String, "summarized")
        XCTAssertNil(second["display"])
        XCTAssertEqual(second["type"] as? String, "adaptive", "思考照开")
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        XCTAssertEqual(ParamAdaptStore.shared.entry(providerType: .anthropic, baseURL: baseURL, modelId: model.modelId)?.learned.groups,
                       [ParamCompat.Group.thinkingDisplay])
    }

    /// astra #7：上一次 Anthropic 回复留下的块，不能落进「没 key 提前失败」的这一次（按请求序号认，不按卡类型）
    func testEarlyFailureDoesNotReadPreviousRepliesBlocks() async throws {
        let reply = Data((ThinkingStreamTests.start(0, ["type": "thinking", "thinking": "", "signature": ""])
            + ThinkingStreamTests.delta(0, ["type": "thinking_delta", "thinking": "上一条的思考"])
            + ThinkingStreamTests.delta(0, ["type": "signature_delta", "signature": "sig-old"]) + ThinkingStreamTests.stop(0)
            + String(decoding: Self.anthropicOK, as: UTF8.self).replacingOccurrences(of: "\"index\":0", with: "\"index\":1")).utf8)
        let server = try Server { _, _ in (200, "text/event-stream", reply) }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-opus-5-5", type: .anthropic)
        let first = await send(router, pm, model)
        XCTAssertEqual(first, .ok("ok"))
        XCTAssertEqual(router.lastAssistantBlocks.first?.raw["signature"] as? String, "sig-old", "前提：上一条的块读得到")

        let noKeyId = "xctest-adapt-nokey-\(UUID().uuidString)"
        let noKey = ProviderModel(credentialId: noKeyId, modelId: "claude-opus-5-5", name: "No Key")
        pm.addCredential(APICredential(id: noKeyId, name: "没 key 的卡", emoji: "🔑", type: .anthropic,
                                       baseURL: server.baseURL, models: [noKey], toolsSupported: true))
        cleanups.append { pm.removeCredential(id: noKeyId) }
        guard case .error(let message) = await send(router, pm, noKey) else { return XCTFail("没 key 应提前失败") }
        XCTAssertTrue(message.contains("API Key"), message)
        XCTAssertTrue(router.lastAssistantBlocks.isEmpty, "提前失败的这一次读不到上一条的块")
        XCTAssertNil(router.lastRefusalCategory)
        XCTAssertFalse(router.lastRequestDroppedThinking)
    }

    /// 中转同时拒绝采样和缓存：沿现有参数自愈重发，拉黑后的 ordered / tools / 检查器全退回无标原文。
    func testOrderedCacheControlRejectedRetriesWithoutMarksAndPreviewMatches() async throws {
        for key in ["anthropicCacheHostBlacklist", "anthropicCacheLongTTLHostBlacklist"] {
            let saved = UserDefaults.standard.object(forKey: key)
            cleanups.append {
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
        let rejected = Data(#"{"error":{"message":"Unsupported parameter: 'temperature'; cache_control is also unsupported.","type":"invalid_request_error","param":"temperature","code":"unsupported_parameter"}}"#.utf8)
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", rejected) : (200, "text/event-stream", Self.anthropicOK)
        }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-sonnet-4-5", type: .anthropic)
        var s = sampling()
        s.cacheFriendly = true
        let stable = "你是虚构的纸桥向导。\n保留这一行。"
        let memory = "X：虚构旅客今天选择蓝桥。"
        let ordered = [
            PromptMessage(role: "system", content: stable, source: .slot(id: "main", name: "main"), nodeId: nil, pinnedToSystemPrefix: false),
            PromptMessage(role: "user", content: "历史问题", source: .chatHistory, nodeId: "u1", pinnedToSystemPrefix: false),
            PromptMessage(role: "assistant", content: "历史回答正文", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false),
            PromptMessage(role: "system", content: memory, source: .memory, nodeId: nil, pinnedToSystemPrefix: false),
            PromptMessage(role: "user", content: "继续走吧", source: .chatHistory, nodeId: "u2", pinnedToSystemPrefix: false)
        ]
        let tools: [[String: Any]] = ["paper_read", "paper_write"].map { name in
            ["type": "function", "function": ["name": name, "description": "虚构纸桥工具",
                "parameters": ["type": "object", "properties": [:]]] as [String: Any]]
        }
        let messages: [(role: String, content: String)] = [(role: "user", content: "旧入口占位，不应出现在 ordered 请求")]
        func canonical(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        func containsCacheControl(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                return object.keys.contains("cache_control") || object.values.contains(where: containsCacheControl)
            }
            if let array = value as? [Any] { return array.contains(where: containsCacheControl) }
            return false
        }
        func previews() throws -> (Data, Data) {
            let body = try XCTUnwrap(ProviderRouter.previewRequestBody(
                model: model, messages: messages, systemPrompt: "旧入口 system",
                providerManager: pm, samplingParams: s, tools: tools, ordered: ordered))
            let request = ProviderRouter.previewRequest(
                model: model, messages: messages, systemPrompt: "旧入口 system",
                providerManager: pm, samplingParams: s, tools: tools, ordered: ordered)
            return (try canonical(body), try canonical(XCTUnwrap(request.body)))
        }
        func turn() async -> Outcome {
            let done = expectation(description: "ordered cache turn")
            done.assertForOverFulfill = false
            var outcome = Outcome.error("没回调")
            router.sendStreaming(
                model: model, messages: messages, systemPrompt: "旧入口 system",
                providerManager: pm, samplingParams: s, tools: tools, ordered: ordered,
                onToken: { _ in }, onComplete: { text, _ in outcome = .ok(text); done.fulfill() },
                onError: { outcome = .error($0); done.fulfill() })
            await fulfillment(of: [done], timeout: 5)
            return outcome
        }

        let initialPreview = try previews()
        let firstOutcome = await turn()
        XCTAssertEqual(firstOutcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        guard server.requestBodies.count == 2 else { return }
        let first = try body(server.requestBodies[0])
        let retry = try body(server.requestBodies[1])
        XCTAssertEqual(first["temperature"] as? Double, 0.7)
        XCTAssertNil(retry["temperature"], "由现有参数自愈触发重发，不新增缓存重试策略")
        XCTAssertEqual(try canonical(first), initialPreview.0)
        XCTAssertEqual(try canonical(first), initialPreview.1)
        let system = try XCTUnwrap(first["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system.compactMap { $0["text"] as? String }, [stable, "\n\n" + memory])
        let mark = try XCTUnwrap(system.first?["cache_control"] as? [String: Any])
        XCTAssertNil(system.last?["cache_control"])
        let firstTools = try XCTUnwrap(first["tools"] as? [[String: Any]])
        XCTAssertEqual(firstTools.count, tools.count)
        XCTAssertNil(firstTools.first?["cache_control"])
        XCTAssertEqual(try canonical(XCTUnwrap(firstTools.last?["cache_control"])), try canonical(mark))
        let firstMessages = try XCTUnwrap(first["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(firstMessages.first { $0["role"] as? String == "assistant" })
        let blocks = try XCTUnwrap(assistant["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.last?["text"] as? String, "历史回答正文")
        XCTAssertEqual(try canonical(XCTUnwrap(blocks.last?["cache_control"])), try canonical(mark), "BP4 仍挂历史 assistant 末块")
        XCTAssertEqual(retry["system"] as? String, stable + "\n\n" + memory)
        XCTAssertFalse(containsCacheControl(retry), "重发体所有层级都不含 cache_control")
        let retryTools = try XCTUnwrap(retry["tools"] as? [[String: Any]])
        let unmarkedTools = firstTools.map { tool -> [String: Any] in
            var result = tool
            result.removeValue(forKey: "cache_control")
            return result
        }
        XCTAssertEqual(try canonical(retryTools), try canonical(unmarkedTools), "全部工具定义保留")
        let retryMessages = try XCTUnwrap(retry["messages"] as? [[String: Any]])
        XCTAssertEqual(retryMessages.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(retryMessages.compactMap { $0["content"] as? String }, ["历史问题", "历史回答正文", "继续走吧"])
        XCTAssertTrue(AnthropicProvider.cacheBlacklistContains(server.baseURL))
        XCTAssertFalse(AnthropicProvider.longTTLBlacklistContains(server.baseURL), "cache_control 不支持不是单独 ttl 降级")
        let blacklistedPreview = try previews()
        XCTAssertEqual(try canonical(retry), blacklistedPreview.0)
        XCTAssertEqual(try canonical(retry), blacklistedPreview.1)

        let secondOutcome = await turn()
        XCTAssertEqual(secondOutcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 3, "同地址记住黑名单，下一轮只发一次")
        guard server.requestBodies.count == 3 else { return }
        let remembered = try body(server.requestBodies[2])
        XCTAssertFalse(containsCacheControl(remembered))
        XCTAssertEqual(try canonical(remembered), try canonical(retry))
        XCTAssertEqual(try canonical(remembered), blacklistedPreview.0)
        XCTAssertEqual(try canonical(remembered), blacklistedPreview.1)
        let systemMarkCount = system.filter { $0["cache_control"] != nil }.count
        let toolMarkCount = firstTools.filter { $0["cache_control"] != nil }.count
        let bp4MarkCount = blocks.filter { $0["cache_control"] != nil }.count
        print("[ordered-cache-retry] firstSystemBlocks=\(system.count) marks(system/tools/BP4)=\(systemMarkCount)/\(toolMarkCount)/\(bp4MarkCount) retrySystemString=\(retry["system"] is String) requests=\(server.requestBodies.count) finalOK=\(secondOutcome == .ok("ok"))")
    }

    /// 粟粟 10-15 缓存默认 1 小时：中转不认 ttl → 这一条马上按 5 分钟重发、不报错，记住这个地址以后都 5 分钟
    func testLongTTLRejectedRetriesWithFiveMinutesAndRemembers() async throws {
        for key in ["anthropicCacheLongTTLHostBlacklist", "anthropicCacheHostBlacklist"] {
            let saved = UserDefaults.standard.object(forKey: key)
            cleanups.append { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        }
        let ttl400 = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"system.0.cache_control.ttl: Extra inputs are not permitted"}}"#.utf8)
        let server = try Server { index, _ in
            index == 0 ? (400, "application/json", ttl400) : (200, "text/event-stream", Self.anthropicOK)
        }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-sonnet-4-5", type: .anthropic)
        var s = sampling()
        s.cacheFriendly = true

        func turn() async -> Outcome {
            let done = expectation(description: "done")
            done.assertForOverFulfill = false
            var outcome = Outcome.error("没回调")
            router.sendStreaming(model: model, messages: [(role: "user", content: "hi")], systemPrompt: "你是小岚",
                                 providerManager: pm, samplingParams: s,
                                 onToken: { _ in }, onComplete: { t, _ in outcome = .ok(t); done.fulfill() },
                                 onError: { outcome = .error($0); done.fulfill() })
            await fulfillment(of: [done], timeout: 5)
            return outcome
        }
        func ttls(_ data: Data) throws -> [String?] {
            let system = try XCTUnwrap(try body(data)["system"] as? [[String: Any]])
            return system.compactMap { $0["cache_control"] as? [String: Any] }.map { $0["ttl"] as? String }
        }

        let r1 = await turn()
        XCTAssertEqual(r1, .ok("ok"), "被拒那条不报错")
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertEqual(try ttls(server.requestBodies[0]), ["1h"])
        XCTAssertEqual(try ttls(server.requestBodies[1]), [nil], "重发那次 5 分钟，缓存照挂")
        XCTAssertTrue(AnthropicProvider.longTTLBlacklistContains(server.baseURL))
        XCTAssertFalse(AnthropicProvider.cacheBlacklistContains(server.baseURL), "只退 ttl，不关缓存")

        let r2 = await turn()
        XCTAssertEqual(r2, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 3, "记住了，第二条一次就过")
        XCTAssertEqual(try ttls(server.requestBodies[2]), [nil])
    }

    /// astra #2：先撞参数自愈、重发又撞 ttl → 仍按 5 分钟再发一次，这一条不报错
    func testParamRetryThenLongTTLRejectedStillSucceeds() async throws {
        for key in ["anthropicCacheLongTTLHostBlacklist", "anthropicCacheHostBlacklist"] {
            let saved = UserDefaults.standard.object(forKey: key)
            cleanups.append { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        }
        let ttl400 = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"system.0.cache_control.ttl: Extra inputs are not permitted"}}"#.utf8)
        let server = try Server { index, _ in
            switch index {
            case 0: return (400, "application/json", Self.bothSamplers400)
            case 1: return (400, "application/json", ttl400)
            default: return (200, "text/event-stream", Self.anthropicOK)
            }
        }
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "xctest-relay-claude", type: .anthropic)
        var s = sampling()
        s.cacheFriendly = true
        s.topP = 0.95
        let done = expectation(description: "done")
        done.assertForOverFulfill = false
        var outcome = Outcome.error("没回调")
        router.sendStreaming(model: model, messages: [(role: "user", content: "hi")], systemPrompt: "你是小岚",
                             providerManager: pm, samplingParams: s,
                             onToken: { _ in }, onComplete: { t, _ in outcome = .ok(t); done.fulfill() },
                             onError: { outcome = .error($0); done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 3)
        let last = try body(server.requestBodies[2])
        XCTAssertNil(last["top_p"], "参数自愈那次学到的照样生效")
        let system = try XCTUnwrap(last["system"] as? [[String: Any]])
        XCTAssertEqual(system.compactMap { ($0["cache_control"] as? [String: Any]).map { $0["ttl"] as? String } }, [nil])
    }
}
