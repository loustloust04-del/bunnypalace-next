import XCTest
@testable import 记忆花园

/// 5xx / 429 有限重试（plan-model-compat-p0 §7.4 / §7.7）：本机假服务器，不发真请求；等待时间注入成 0 并记下来
@MainActor
final class ChatRetryRouterTests: XCTestCase {
    typealias Server = ScriptedHTTPServer
    typealias Response = Server.Response

    static let unavailable503 = Data(#"{"error":{"message":"Service Unavailable","type":"server_error"}}"#.utf8)
    static let rate429 = Data(#"{"error":{"message":"Rate limit reached for requests per min (RPM)","type":"requests","code":"rate_limit_exceeded"}}"#.utf8)
    static let overloadedEvent = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#

    private var cleanups: [() -> Void] = []
    private var waits: [TimeInterval] = []

    override func tearDown() async throws {
        cleanups.forEach { $0() }
        cleanups = []
        waits = []
    }

    private func fixture(_ server: Server, type: ProviderType = .openaiCompatible,
                         modelId: String = "xctest-retry-model") -> (ProviderRouter, ProviderManager, ProviderModel) {
        let credentialId = "xctest-retry-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: modelId, name: "Retry Test")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "重试测试卡", emoji: "⏳", type: type,
                                       baseURL: server.baseURL, models: [model], toolsSupported: true))
        pm.setApiKey("test-key", for: credentialId)
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID().uuidString).jsonl"))
        router.retryDelay = { [weak self] wait in
            self?.waits.append(wait)
            return 0
        }
        let baseURL = pm.provider(for: model)?.baseURL ?? server.baseURL
        cleanups.append {
            pm.removeCredential(id: credentialId)
            ParamAdaptStore.shared.remove(key: ParamAdaptStore.key(providerType: type, baseURL: baseURL, modelId: modelId))
            server.stop()
        }
        return (router, pm, model)
    }

    private enum Outcome: Equatable { case ok(String), error(String) }

    private struct Result {
        var outcome: Outcome
        var tokens: String
        var notices: [String]
        var effectiveEvents = 0
        var attempts = 0
    }

    private func send(_ router: ProviderRouter, _ pm: ProviderManager, _ model: ProviderModel) async -> Result {
        let done = expectation(description: "done")
        done.assertForOverFulfill = false
        var result = Result(outcome: .error("没回调"), tokens: "", notices: [])
        var sampling = SamplingParams()
        sampling.maxTokens = 4096
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
            providerManager: pm, samplingParams: sampling,
            onToken: { result.tokens += $0 }, onComplete: { t, _ in result.outcome = .ok(t); done.fulfill() },
            onError: { result.outcome = .error($0); done.fulfill() },
            onRetry: { result.notices.append($0) },
            onEffectiveEvent: { result.effectiveEvents += 1 },
            onRequestAttempt: { result.attempts += 1 }
        )
        await fulfillment(of: [done], timeout: 5)
        return result
    }

    func test503Twice200Succeeds() async throws {
        let server = try Server(responding: { index, _ in
            index < 2 ? Response(status: 503, contentType: "application/json", body: Self.unavailable503)
                : Response(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
        })
        try server.start()
        let (router, pm, model) = fixture(server)

        let r = await send(router, pm, model)
        XCTAssertEqual(r.outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 3)
        XCTAssertEqual(r.attempts, 3, "每次真实提交都记录 attempt，包括自动重试")
        XCTAssertEqual(r.effectiveEvents, 1, "503 不生效；成功正文只生效一次")
        XCTAssertEqual(waits, [1, 3])
        XCTAssertEqual(r.notices, ["⏳ 服务器有点忙，1 秒后自动重试（1/2）", "⏳ 服务器有点忙，3 秒后自动重试（2/2）"])
        let rows = router.ledger.load()
        XCTAssertEqual(rows.map(\.status), [.error, .error, .ok])
        XCTAssertEqual(rows.prefix(2).map(\.budgetChargeUSD), [0, 0], "被拒那两次不扣预算")
        XCTAssertFalse(router.isStreaming)
    }

    func test503ThriceGivesUp() async throws {
        let server = try Server { _, _ in (503, "application/json", Self.unavailable503) }
        try server.start()
        let (router, pm, model) = fixture(server)

        let r = await send(router, pm, model)
        guard case .error(let message) = r.outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 3, "最多重试 2 次")
        XCTAssertEqual(r.attempts, 3)
        XCTAssertEqual(r.effectiveEvents, 0)
        XCTAssertTrue(message.hasPrefix("服务器暂时出问题，已自动重试 2 次还是不行"), message)
        XCTAssertTrue(message.contains("HTTP 503）"), message)
        XCTAssertEqual(r.notices.count, 2)
        let rows = router.ledger.load()
        XCTAssertEqual(rows.map(\.status), [.error, .error, .error])
        XCTAssertEqual(rows.map(\.budgetChargeUSD), [0, 0, 0], "最后一次被拒也不扣预算（审查 #3）")
    }

    func test429RetryAfterShortWaits() async throws {
        let server = try Server(responding: { index, _ in
            index == 0 ? Response(status: 429, contentType: "application/json", body: Self.rate429, headers: ["Retry-After": "1"])
                : Response(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
        })
        try server.start()
        let (router, pm, model) = fixture(server)

        let r = await send(router, pm, model)
        XCTAssertEqual(r.outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let wait = try XCTUnwrap(waits.first)
        XCTAssertTrue((1...1.5).contains(wait), "照 Retry-After 等 + 0–0.5 抖动：\(wait)")
        XCTAssertEqual(r.notices, ["⏳ 请求太频繁被限流了，1 秒后自动重试（1/2）"])
    }

    func test429RetryAfterLongDoesNotWait() async throws {
        let server = try Server(responding: { _, _ in
            Response(status: 429, contentType: "application/json", body: Self.rate429, headers: ["Retry-After": "30"])
        })
        try server.start()
        let (router, pm, model) = fixture(server)

        let r = await send(router, pm, model)
        guard case .error(let message) = r.outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 1)
        XCTAssertTrue(message.hasPrefix("被限流了，大约 30 秒后再发"), message)
        XCTAssertTrue(r.notices.isEmpty)
        XCTAssertTrue(waits.isEmpty)
        XCTAssertEqual(router.ledger.load().map(\.budgetChargeUSD), [0], "不重试的明确拒绝也不扣预算（审查 #3）")
    }

    /// 流内 overloaded_error 之后连接又异常结束：两条错误回调只排一个重试（审查 #1）
    static let overloadedThenDropped = Response(status: 200, contentType: "text/event-stream",
                                                body: OutputTokenCapTests.sse([": " + String(repeating: "x", count: 1024), "data: " + overloadedEvent]),
                                                declaredLength: 8192)   // 注释行垫过 URLSession 的 512 字节嗅探缓冲，流内 error 先到

    func testStreamErrorThenConnectionDropRetriesOnce() async throws {
        let server = try Server(responding: { index, _ in
            index == 0 ? Self.overloadedThenDropped : Response(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
        })
        try server.start()
        let (router, pm, model) = fixture(server)
        router.retryDelay = { _ in 0.6 }   // 比服务器断连（0.3s）晚：等待期间第二条错误回调已到

        let r = await send(router, pm, model)
        XCTAssertEqual(r.outcome, .ok("ok"))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(server.requestBodies.count, 2, "只重试一次")
        XCTAssertEqual(r.notices.count, 1)
        XCTAssertEqual(router.ledger.load().map(\.status), [.error, .ok])
    }

    func testCancelAfterDoubleErrorSendsNothing() async throws {
        let server = try Server(responding: { _, _ in Self.overloadedThenDropped })
        try server.start()
        let (router, pm, model) = fixture(server)
        router.retryDelay = { _ in 1.0 }

        let retried = expectation(description: "retry scheduled")
        retried.assertForOverFulfill = false
        var finished = false
        var notices = 0
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil, providerManager: pm,
            onToken: { _ in }, onComplete: { _, _ in finished = true }, onError: { _ in finished = true },
            onRetry: { _ in
                notices += 1
                retried.fulfill()
            }
        )
        await fulfillment(of: [retried], timeout: 5)
        try await Task.sleep(nanoseconds: 600_000_000)   // 服务器 0.3s 后断连：第二条错误回调在等待期间落地
        router.cancel()
        XCTAssertFalse(router.isStreaming)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(server.requestBodies.count, 1, "停止后零重发")
        XCTAssertEqual(notices, 1)
        XCTAssertFalse(finished)
    }

    func testStaleRetryDoesNotInterruptNewRequest() async throws {
        let server = try Server(responding: { index, _ in
            index == 0 ? Self.overloadedThenDropped : Response(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
        })
        try server.start()
        let (router, pm, model) = fixture(server)
        router.retryDelay = { _ in 1.0 }

        let retried = expectation(description: "retry scheduled")
        retried.assertForOverFulfill = false
        var firstFinished = false
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil, providerManager: pm,
            onToken: { _ in }, onComplete: { _, _ in firstFinished = true }, onError: { _ in firstFinished = true },
            onRetry: { _ in retried.fulfill() }
        )
        await fulfillment(of: [retried], timeout: 5)
        try await Task.sleep(nanoseconds: 600_000_000)

        router.retryDelay = { _ in 0 }
        let r = await send(router, pm, model)   // 新一轮发送：旧的重试作废
        XCTAssertEqual(r.outcome, .ok("ok"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(server.requestBodies.count, 2, "旧重试没再发")
        XCTAssertFalse(firstFinished)
        XCTAssertFalse(router.isStreaming)
    }

    func testNoRetryAfterTextStarted() async throws {
        let stream = OutputTokenCapTests.sse([
            #"data: {"choices":[{"delta":{"content":"半"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"截"}}]}"#,
            "data: " + Self.overloadedEvent,
        ])
        let server = try Server { _, _ in (200, "text/event-stream", stream) }
        try server.start()
        let (router, pm, model) = fixture(server)

        let r = await send(router, pm, model)
        guard case .error(let message) = r.outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(r.tokens, "半截", "已出的正文照样到了 VM")
        XCTAssertEqual(server.requestBodies.count, 1, "已开始输出不重试")
        XCTAssertTrue(r.notices.isEmpty)
        XCTAssertTrue(message.contains("Overloaded"), message)
    }

    func testNoRetryAfterReasoningStarted() async throws {
        let stream = OutputTokenCapTests.sse([
            #"data: {"choices":[{"delta":{"reasoning_content":"先想想"}}]}"#,
            "data: " + Self.overloadedEvent,
        ])
        let server = try Server { _, _ in (200, "text/event-stream", stream) }
        try server.start()
        let (router, pm, model) = fixture(server)

        let r = await send(router, pm, model)
        guard case .error = r.outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 1, "思考也算已输出（Q11）")
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(r.effectiveEvents, 0, "思考阻止旧重试策略，但不推进召回状态")
    }

    func testAnthropicNoRetryAfterThinkingStarted() async throws {
        let stream = Data((ThinkingStreamTests.event("message_start", ["message": ["usage": ["input_tokens": 3, "output_tokens": 0]]])
            + ThinkingStreamTests.start(0, ["type": "thinking", "thinking": ""])
            + ThinkingStreamTests.delta(0, ["type": "thinking_delta", "thinking": "嗯"])
            + "event: error\ndata: \(Self.overloadedEvent)\n\n").utf8)
        let server = try Server { _, _ in (200, "text/event-stream", stream) }
        try server.start()
        let (router, pm, model) = fixture(server, type: .anthropic, modelId: "claude-opus-5-5")

        let r = await send(router, pm, model)
        guard case .error = r.outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 1)
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(r.effectiveEvents, 0)
    }

    func testAnthropicOverloadedRightAfterStartRetries() async throws {
        let failing = Data((ThinkingStreamTests.event("message_start", ["message": ["usage": ["input_tokens": 3, "output_tokens": 0]]])
            + "event: error\ndata: \(Self.overloadedEvent)\n\n").utf8)
        let server = try Server { index, _ in
            index == 0 ? (200, "text/event-stream", failing) : (200, "text/event-stream", ParamAutoAdaptRouterTests.anthropicOK)
        }
        try server.start()
        let (router, pm, model) = fixture(server, type: .anthropic, modelId: "claude-opus-5-5")

        let r = await send(router, pm, model)
        XCTAssertEqual(r.outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertEqual(r.attempts, 2)
        XCTAssertEqual(r.effectiveEvents, 1, "message_start 的用量不算首个有效响应")
        XCTAssertEqual(r.notices, ["⏳ 服务器有点忙，1 秒后自动重试（1/2）"])
        XCTAssertEqual(router.ledger.load().map(\.status), [.error, .ok])
    }

    func testParamFixThen503Then200() async throws {
        let server = try Server(responding: { index, _ in
            switch index {
            case 0: return Response(status: 400, contentType: "application/json", body: ParamAutoAdaptRouterTests.temperature400)
            case 1: return Response(status: 503, contentType: "application/json", body: Self.unavailable503)
            default: return Response(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
            }
        })
        try server.start()
        let (router, pm, model) = fixture(server)

        let r = await send(router, pm, model)
        XCTAssertEqual(r.outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 3)
        XCTAssertEqual(r.attempts, 3, "参数自适配和瞬态重试都必须传递回调")
        XCTAssertEqual(r.effectiveEvents, 1)
        let third = try XCTUnwrap(JSONSerialization.jsonObject(with: server.requestBodies[2]) as? [String: Any])
        XCTAssertNil(third["temperature"], "服务器重试沿用参数自愈后的请求")
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        XCTAssertEqual(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId)?.learned.groups,
                       [ParamCompat.Group.sampling])
        XCTAssertEqual(router.consumeParamAdaptation(), "这个模型不收 temperature / top_p，已自动去掉", "服务器重试不清掉自愈提示")
        XCTAssertEqual(router.ledger.load().map(\.status), [.error, .error, .ok])
    }

    func testCancelDuringBackoff() async throws {
        let server = try Server { _, _ in (503, "application/json", Self.unavailable503) }
        try server.start()
        let (router, pm, model) = fixture(server)
        router.retryDelay = { _ in 0.4 }

        let retried = expectation(description: "retry scheduled")
        var finished = false
        var streamingWhileWaiting = false
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil, providerManager: pm,
            onToken: { _ in }, onComplete: { _, _ in finished = true }, onError: { _ in finished = true },
            onRetry: { _ in
                streamingWhileWaiting = router.isStreaming
                retried.fulfill()
            }
        )
        await fulfillment(of: [retried], timeout: 5)
        XCTAssertTrue(streamingWhileWaiting, "等待重试期间算还在生成（停止按钮可用）")
        XCTAssertTrue(router.isStreaming)
        router.cancel()
        XCTAssertFalse(router.isStreaming)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(server.requestBodies.count, 1, "取消后不再发")
        XCTAssertFalse(finished, "取消后不再回调")
    }

    func testAuthAndURLErrorsUnchanged() async throws {
        for (status, phrase) in [(401, FixJump.badKeyPhrase), (404, FixJump.badURLPhrase)] {
            let server = try Server { _, _ in (status, "application/json", Data(#"{"error":{"message":"nope"}}"#.utf8)) }
            try server.start()
            let (router, pm, model) = fixture(server)
            let r = await send(router, pm, model)
            guard case .error(let message) = r.outcome else { return XCTFail("不该成功") }
            XCTAssertEqual(server.requestBodies.count, 1)
            XCTAssertTrue(message.hasPrefix(phrase + "。原文：nope"), message)
            XCTAssertTrue(r.notices.isEmpty)
        }
        let server = try Server { _, _ in (400, "application/json", ParamAutoAdaptRouterTests.prefill400) }
        try server.start()
        let (router, pm, model) = fixture(server)
        let r = await send(router, pm, model)
        guard case .error(let message) = r.outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 1)
        XCTAssertTrue(message.hasPrefix("这个模型不收预填"), message)
    }
}
