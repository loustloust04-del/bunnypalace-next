import XCTest
@testable import 记忆花园

/// plan-reply-error-report-1106 第 2 步 T9：卡住看门狗。
/// 阈值注入毫秒级 tick + 假时钟（边界仍是 30/600、45/180 秒）；SSE 走真帧（含 `: keep-alive` 注释行），不发真请求。
@MainActor
final class ReplyOutcomeWatchdogTests: XCTestCase {

    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private final class Recorder {
        var notices: [String] = []
        var tokens: [String] = []
        var completed: [String] = []
        var errors: [String] = []
    }

    /// async 测试里不能用 `wait(for:)`（会堵住主线程，排队中的回调永远不落地）
    private func drain() async {
        await pause(0.05)
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 轮询到条件成立（默认 2 秒）；用于等 Task 的判定落地
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.005)
        }
        return condition()
    }

    private static func sse(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n\n").utf8)
    }

    private static let keepAlive = Data(": keep-alive\n\n".utf8)

    private static func content(_ text: String) -> Data {
        sse(["data: " + #"{"choices":[{"delta":{"content":"\#(text)"}}]}"#])
    }

    private static func reasoning(_ text: String) -> Data {
        sse(["data: " + #"{"choices":[{"delta":{"reasoning_content":"\#(text)"}}]}"#])
    }

    /// 假时钟 + 10ms tick：判定由真 Task 做，边界由测试推进假时钟控制
    private func makeProvider(_ config: StallWatchdogConfig, clock: FakeClock) -> (OpenAICompatibleProvider, Recorder) {
        let p = OpenAICompatibleProvider()
        let r = Recorder()
        p.clock = { clock.now }
        p.stallConfig = config
        p.onStallNotice = { r.notices.append($0) }
        p.resetState(onToken: { r.tokens.append($0) },
                     onComplete: { text, _ in r.completed.append(text) },
                     onError: { r.errors.append($0) })
        p.startStallWatchdog()
        return (p, r)
    }

    // MARK: - 只有 keep-alive：30 秒提示 / 600 秒硬停

    func testKeepAliveOnlyNotifiesAt30sAndStopsAt600s() async {
        let clock = FakeClock()
        var config = StallWatchdogConfig(tick: 0.01)
        config.firstByteNotice = 30
        config.firstByteHardStop = 600
        let (p, r) = makeProvider(config, clock: clock)
        p.processData(Self.keepAlive)
        await drain()

        clock.advance(29)
        await pause(0.1)                       // 十几次 tick，都没到 30 秒
        XCTAssertEqual(r.notices, [], "没到 30 秒不提示")

        clock.advance(2)                       // 31 秒
        let reached = await waitUntil { !r.notices.isEmpty }
        XCTAssertTrue(reached)
        XCTAssertEqual(r.notices, ["已连上，上游在排队"])

        p.processData(Self.keepAlive)          // keep-alive 只更新 lastByteAt，不续阶段计时
        await drain()
        clock.advance(100)                     // 131 秒
        await pause(0.1)
        XCTAssertEqual(r.notices.count, 1, "每个阶段最多提示一次")
        XCTAssertTrue(r.completed.isEmpty, "还没到硬停档")

        clock.advance(469)                     // 从流开始 600 秒
        let stopped = await waitUntil { !r.completed.isEmpty }
        XCTAssertTrue(stopped)

        XCTAssertEqual(r.completed, [""], "正文为空也要收尾，灰胶囊才落得下去")
        XCTAssertTrue(r.errors.isEmpty, "硬停不是报错")
        XCTAssertTrue(r.tokens.isEmpty)
        XCTAssertEqual(p.outcome, .stalledFirstByte)
        XCTAssertTrue(p.stoppedByWatchdog)
        XCTAssertNil(p.finishReason)
        XCTAssertFalse(r.completed.joined().contains("（已停止）"))
        XCTAssertFalse(p.isStallWatchdogRunning, "硬停后检查 Task 一起停")
    }

    // MARK: - 出过增量后不动：45 秒提示 / 180 秒硬停，正文保留

    func testMidStreamNotifiesAt45sAndStopsAt180sKeepingContent() async {
        let clock = FakeClock()
        var config = StallWatchdogConfig(tick: 0.01)
        config.midStreamNotice = 45
        config.midStreamHardStop = 180
        let (p, r) = makeProvider(config, clock: clock)
        p.processData(Self.content("写到一半"))
        await drain()
        XCTAssertEqual(r.tokens, ["写到一半"])

        clock.advance(44)
        await pause(0.1)
        XCTAssertEqual(r.notices, [], "没到 45 秒不提示")

        clock.advance(2)                       // 距上次增量 46 秒
        let reached = await waitUntil { !r.notices.isEmpty }
        XCTAssertTrue(reached)
        XCTAssertEqual(r.notices, ["上游中途停住了"])

        p.processData(Self.keepAlive)          // keep-alive 不算增量
        await drain()
        clock.advance(100)                     // 146 秒
        await pause(0.1)
        XCTAssertTrue(r.completed.isEmpty, "keep-alive 不续增量计时")
        XCTAssertEqual(r.notices.count, 1)

        clock.advance(40)                      // 距上次增量 186 秒
        let stopped = await waitUntil { !r.completed.isEmpty }
        XCTAssertTrue(stopped)

        XCTAssertEqual(p.outcome, .stalledMidStream)
        XCTAssertEqual(r.completed, ["写到一半"], "已出的正文保留")
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertFalse(r.completed.joined().contains("（已停止）"), "硬停不能当成用户点停止")
        XCTAssertFalse(p.isStallWatchdogRunning)
    }

    // MARK: - 持续有增量（含只有思考）不误停

    func testContinuousReasoningDeltasNeverTripTheWatchdog() async {
        let clock = FakeClock()
        var config = StallWatchdogConfig(tick: 0.01)
        config.midStreamNotice = 45
        config.midStreamHardStop = 180
        let (p, r) = makeProvider(config, clock: clock)

        for i in 0..<12 {                      // 12 格 × 30 秒 = 360 秒，远超 180 秒硬停档
            clock.advance(30)
            p.processData(Self.reasoning("想第 \(i) 段"))
            await pause(0.03)                  // 让 Task 真检查一两轮
            XCTAssertTrue(r.notices.isEmpty, "第 \(i) 格：只有思考增量也不算卡住")
            XCTAssertTrue(r.completed.isEmpty, "第 \(i) 格")
        }
        XCTAssertEqual(p.outcome, .normal)

        // 增量停了才开始重新计时：45 秒档提示，但还没到 180 秒硬停
        clock.advance(50)
        let reached = await waitUntil { !r.notices.isEmpty }
        XCTAssertTrue(reached)
        XCTAssertEqual(r.notices, ["上游中途停住了"])
        XCTAssertEqual(p.outcome, .normal)
        XCTAssertTrue(r.completed.isEmpty)
        p.stopStallWatchdog()
    }

    // MARK: - cancel() 后检查 Task 停掉，不再回调

    func testCancelStopsTheCheckTask() async {
        let clock = FakeClock()
        var config = StallWatchdogConfig(tick: 0.01)
        config.firstByteNotice = 500
        config.firstByteHardStop = 600
        let (p, r) = makeProvider(config, clock: clock)
        XCTAssertTrue(p.isStallWatchdogRunning)

        clock.advance(100)                     // 还没到任何一档
        p.cancel()
        XCTAssertFalse(p.isStallWatchdogRunning)

        clock.advance(10_000)                  // Task 若还活着，下一次 tick 就会硬停
        await pause(0.15)

        XCTAssertTrue(r.notices.isEmpty, "取消后不再提示")
        XCTAssertTrue(r.completed.isEmpty, "取消后不再收尾")
        XCTAssertFalse(p.stoppedByWatchdog)
    }

    // MARK: - 流式请求 timeoutInterval 90 秒；非流式保持 600

    func testStreamingRequestTimeoutIs90AndNonStreamingStays600() async throws {
        let server = try ScriptedHTTPServer { index, _ in
            index == 0
                ? (200, "text/event-stream", Self.sse(["data: [DONE]"]))
                : (200, "application/json", Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"好"}}]}"#.utf8))
        }
        try server.start()
        defer { server.stop() }

        let streamed = OpenAICompatibleProvider()
        var streamRequests: [URLRequest] = []
        streamed.onRequestSent = { streamRequests.append($0) }
        let first = expectation(description: "流式完成")
        streamed.sendStreaming(messages: [(role: "user", content: "hi")], model: "xctest-watchdog-timeout",
                               systemPrompt: nil, apiKey: "test-key", baseURL: server.baseURL, extraHeaders: [:],
                               samplingParams: nil,
                               onToken: { _ in }, onComplete: { _, _ in first.fulfill() },
                               onError: { XCTFail($0); first.fulfill() })
        await fulfillment(of: [first], timeout: 5)

        let plain = OpenAICompatibleProvider()
        var plainRequests: [URLRequest] = []
        plain.onRequestSent = { plainRequests.append($0) }
        var sampling = SamplingParams()
        sampling.streaming = false
        let second = expectation(description: "非流式完成")
        plain.sendStreaming(messages: [(role: "user", content: "hi")], model: "xctest-watchdog-timeout",
                            systemPrompt: nil, apiKey: "test-key", baseURL: server.baseURL, extraHeaders: [:],
                            samplingParams: sampling,
                            onToken: { _ in }, onComplete: { _, _ in second.fulfill() },
                            onError: { XCTFail($0); second.fulfill() })
        await fulfillment(of: [second], timeout: 5)

        XCTAssertEqual(streamRequests.first?.timeoutInterval, 90)
        XCTAssertEqual(streamRequests.first?.timeoutInterval, StallWatchdogConfig.streamingTimeout)
        XCTAssertEqual(plainRequests.first?.timeoutInterval, 600)
    }

    // MARK: - VM 落节点：硬停不出现「（已停止）」、灰胶囊落地

    private func vmFixture(_ response: ScriptedHTTPServer.Response) async throws -> (PromptRealPathHarness, ProviderModel, ScriptedHTTPServer) {
        let h = try await PromptRealPathHarness.make(.init(name: "reply-watchdog-\(UUID().uuidString)",
                                                          profileId: "xctest-watchdog-\(UUID().uuidString)",
                                                          memoryEnabled: false, voiceHint: false,
                                                          memoryFixtures: false))
        let server = try ScriptedHTTPServer { _, _ in response }
        try server.start()
        let credentialId = "xctest-watchdog-vm-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "xctest-watchdog-vm", name: "Watchdog VM")
        h.providerManager.addCredential(APICredential(id: credentialId, name: "看门狗 VM 卡", emoji: "🧪",
                                                      type: .openaiCompatible, baseURL: server.baseURL,
                                                      models: [model], toolsSupported: false))
        h.providerManager.setApiKey("test-key", for: credentialId)
        h.viewModel.selectedConversation?.selectedModelId = model.id
        return (h, model, server)
    }

    func testVMStalledFirstByteLandsCapsuleWithoutStopMarker() async throws {
        // 只发 keep-alive，连接一直挂着（脚本服务器 0.3 秒后才断）；看门狗 0.15 秒先硬停
        var config = StallWatchdogConfig(tick: 0.01)
        config.firstByteNotice = 0.05
        config.firstByteHardStop = 0.15
        config.midStreamNotice = 5
        config.midStreamHardStop = 5
        let (h, model, server) = try await vmFixture(.init(status: 200, contentType: "text/event-stream",
                                                          body: Data(": keep-alive\n\n".utf8), declaredLength: 4096))
        defer { server.stop() }
        h.viewModel.providerRouter.stallWatchdogConfig = config

        XCTAssertTrue(h.viewModel.sendMessage("在吗", model: model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight, "15 秒没回完")

        let node = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(node.replyOutcome, "stalled_first_byte")
        XCTAssertEqual(node.content, "", "正文为空，但不能是「（已停止）」")
        XCTAssertFalse(node.content.contains("（已停止）"))
        XCTAssertEqual(h.viewModel.providerRouter.lastReplyOutcome, .stalledFirstByte)
        await h.tearDown()
    }

    func testVMStalledMidStreamKeepsContentWithoutStopMarker() async throws {
        var config = StallWatchdogConfig(tick: 0.01)
        config.firstByteNotice = 0.05
        config.firstByteHardStop = 5      // 别让它抢在增量之前
        config.midStreamNotice = 0.05
        config.midStreamHardStop = 0.25   // 脚本服务器 0.3 秒才断，看门狗先停
        let body = Self.sse([
            "data: " + #"{"choices":[{"delta":{"content":"写到一半"}}]}"#,
            ": keep-alive",
        ])
        let (h, model, server) = try await vmFixture(.init(status: 200, contentType: "text/event-stream",
                                                          body: body, declaredLength: 4096))
        defer { server.stop() }
        h.viewModel.providerRouter.stallWatchdogConfig = config

        XCTAssertTrue(h.viewModel.sendMessage("写点什么", model: model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight, "15 秒没回完")

        let node = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(node.content, "写到一半", "已出的正文保留在气泡里")
        XCTAssertEqual(node.replyOutcome, "stalled_mid_stream")
        XCTAssertFalse(node.content.contains("（已停止）"), "硬停不能当成用户点停止")
        await h.tearDown()
    }
}
