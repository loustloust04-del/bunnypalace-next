import XCTest
import SwiftData
@testable import 记忆花园

/// plan-reply-error-report-1106 第 1 步 T1–T8：结局枚举、provider 映射、判空 / 判流断、router 抄写、VM 落节点、胶囊文案、超时文案。
/// 全部用假 SSE / 本机假服务器，不发真请求。
@MainActor
final class ReplyOutcomeTests: XCTestCase {

    private func drain() {
        let e = expectation(description: "主队列排空")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private static func sse(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n\n").utf8)
    }

    private static func openAI(_ json: String) -> String { "data: " + json }

    // MARK: - T1 OpenAI finish_reason 全量映射

    func testOpenAIFinishReasonMapping() {
        let cases: [(String, ReplyOutcome)] = [
            ("stop", .normal),
            ("tool_calls", .normal),
            ("length", .truncatedLength),
            ("content_filter", .filtered),
            ("insufficient_system_resource", .noResource),
            ("aborted", .aborted),
            ("something_new", .normal),
        ]
        for (reason, expected) in cases {
            let p = OpenAICompatibleProvider()
            p.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { XCTFail($0) })
            p.processData(Data((Self.openAI(#"{"choices":[{"delta":{"content":"x"},"finish_reason":"\#(reason)"}]}"#) + "\n\n").utf8))
            drain()
            XCTAssertEqual(p.outcome, expected, reason)
            XCTAssertEqual(p.finishReason, reason, "认不出的值也要原样存")
            XCTAssertEqual(p.hitOutputLimit, expected == .truncatedLength, reason)
        }
    }

    func testOpenAINonStreamFinishReasonMapping() throws {
        let length = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"半截"}}]}"#.utf8)
        let r1 = try OpenAICompatibleProvider().parseNonStreamBody(length)
        XCTAssertEqual(r1.outcome, .truncatedLength)
        XCTAssertEqual(r1.finishReason, "length")
        XCTAssertTrue(r1.hitOutputLimit)

        let filtered = Data(#"{"choices":[{"finish_reason":"content_filter","message":{"content":""}}]}"#.utf8)
        let r2 = try OpenAICompatibleProvider().parseNonStreamBody(filtered)
        XCTAssertEqual(r2.outcome, .filtered)
        XCTAssertFalse(r2.hitOutputLimit)
    }

    // MARK: - T2 Anthropic stop_reason 映射

    func testAnthropicStopReasonMapping() {
        let cases: [(String, ReplyOutcome)] = [
            ("max_tokens", .truncatedLength),
            ("refusal", .filtered),
            ("end_turn", .normal),
            ("tool_use", .normal),
            ("pause_turn", .normal),
        ]
        for (reason, expected) in cases {
            let p = AnthropicProvider()
            p.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { XCTFail($0) })
            p.processData(Self.sse([
                "event: message_delta",
                Self.openAI(#"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":1}}"#),
            ]))
            drain()
            XCTAssertEqual(p.outcome, expected, reason)
            XCTAssertEqual(p.finishReason, reason)
        }
    }

    func testAnthropicNonStreamStopReasonMapping() throws {
        let refused = Data(#"{"stop_reason":"refusal","content":[{"type":"text","text":""}]}"#.utf8)
        let r = try AnthropicProvider().parseNonStreamBody(refused)
        XCTAssertEqual(r.outcome, .filtered)
        XCTAssertEqual(r.finishReason, "refusal")
        XCTAssertFalse(r.hitOutputLimit)
    }

    // MARK: - T3 [DONE] 收尾判空

    func testDoneWithEmptyBodyIsEmptyReply() {
        let p = OpenAICompatibleProvider()
        var completed: [String] = []
        p.resetState(onToken: { _ in }, onComplete: { t, _ in completed.append(t) }, onError: { XCTFail($0) })
        p.processData(Data("data: [DONE]\n\n".utf8))
        drain()
        XCTAssertEqual(completed, [""])
        XCTAssertEqual(p.outcome, .emptyReply)
    }

    func testDoneWithReasoningOnlyIsEmptyReply() {
        let p = OpenAICompatibleProvider()
        var completed: [String] = []
        p.resetState(onToken: { _ in }, onComplete: { t, _ in completed.append(t) }, onError: { XCTFail($0) })
        p.processData(Data((Self.openAI(#"{"choices":[{"delta":{"reasoning_content":"只有思考"}}]}"#) + "\n\ndata: [DONE]\n\n").utf8))
        drain()
        XCTAssertEqual(completed, [""])
        XCTAssertEqual(p.outcome, .emptyReply)
    }

    func testDoneWithToolCallsIsNotEmptyReply() {
        let p = OpenAICompatibleProvider()
        var calls: [ToolCallBlock] = []
        p.onToolCalls = { calls = $0 }
        p.resetState(onToken: { _ in }, onComplete: { _, _ in XCTFail("工具轮不该走 onComplete") }, onError: { XCTFail($0) })
        p.processData(Data([
            Self.openAI(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t1","function":{"name":"fs_read","arguments":"{}"}}]}}]}"#),
            "data: [DONE]",
        ].joined(separator: "\n\n").appending("\n\n").utf8))
        drain()
        XCTAssertEqual(calls.map(\.name), ["fs_read"])
        XCTAssertEqual(p.outcome, .normal, "有工具调用、没有正文不算空回")
    }

    func testDoneWithContentStaysNormal() {
        let p = OpenAICompatibleProvider()
        var completed: [String] = []
        p.resetState(onToken: { _ in }, onComplete: { t, _ in completed.append(t) }, onError: { XCTFail($0) })
        p.processData(Data((Self.openAI(#"{"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}"#) + "\n\ndata: [DONE]\n\n").utf8))
        drain()
        XCTAssertEqual(completed, ["好"])
        XCTAssertEqual(p.outcome, .normal)
    }

    func testAnthropicMessageStopEmptyIsEmptyReply() {
        let p = AnthropicProvider()
        var completed: [String] = []
        p.resetState(onToken: { _ in }, onComplete: { t, _ in completed.append(t) }, onError: { XCTFail($0) })
        p.processData(Self.sse([
            "event: message_delta",
            Self.openAI(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}"#),
            "event: message_stop",
            Self.openAI(#"{"type":"message_stop"}"#),
        ]))
        drain()
        XCTAssertEqual(completed, [""])
        XCTAssertEqual(p.outcome, .emptyReply)
    }

    // MARK: - T4 流断（没 [DONE] 也没 finish_reason）

    /// 真实 delegate 入口：拼一个已经挂上的 session，再模拟连接正常结束
    private func deliverWithoutDone(_ sse: String) -> (events: [String], provider: OpenAICompatibleProvider) {
        let p = OpenAICompatibleProvider()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.invalid/v1")!)
        var events: [String] = []
        p.resetState(onToken: { events.append("token:\($0)") }, onComplete: { t, _ in events.append("complete:\(t)") },
                     onError: { events.append("error:\($0)") })
        p.urlSession = session
        p.sessionGeneration = p.pacedGeneration
        p.isEventStream = true
        p.httpStatusCode = 200
        p.processData(Data(sse.utf8))
        drain()   // 让正文回调先落地，再模拟连接结束（真实 delegate 两次回调之间主队列会排空）
        p.urlSession(session, task: task, didCompleteWithError: nil)
        drain()
        let e = expectation(description: "主队列排空 2")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
        return (events, p)
    }

    func testEOFWithoutDoneNorFinishReasonIsStreamCut() {
        let r = deliverWithoutDone(Self.openAI(#"{"choices":[{"delta":{"content":"写到一半"}}]}"#) + "\n\n")
        XCTAssertEqual(r.events, ["token:写到一半", "complete:写到一半"])
        XCTAssertEqual(r.provider.outcome, .streamCut)
        XCTAssertNil(r.provider.finishReason)
        XCTAssertEqual(r.provider.streamingContent, "写到一半", "正文照常保留")
    }

    func testEOFWithFinishReasonIsNotStreamCut() {
        let r = deliverWithoutDone(Self.openAI(#"{"choices":[{"delta":{"content":"写"},"finish_reason":"stop"}]}"#) + "\n\n")
        XCTAssertEqual(r.events, ["token:写", "complete:写"])
        XCTAssertEqual(r.provider.outcome, .normal)
        XCTAssertEqual(r.provider.finishReason, "stop")
    }

    // MARK: - T5 Router 抄写

    private static let unknownModel = "xctest-outcome-model"

    private func sampling(_ maxTokens: Int) -> SamplingParams {
        var s = SamplingParams()
        s.maxTokens = maxTokens
        s.maxTokensAuto = false
        s.reasoningEffort = "auto"
        return s
    }

    func testRouterCopiesOutcomeAndFinishReason() async throws {
        let streams: [Data] = [
            Self.sse([
                Self.openAI(#"{"choices":[{"delta":{"content":"很长的讲解"},"finish_reason":"length"}]}"#),
                "data: [DONE]",
            ]),
            Self.sse([
                Self.openAI(#"{"choices":[{"delta":{"content":""},"finish_reason":"content_filter"}]}"#),
                "data: [DONE]",
            ]),
            Self.sse([
                Self.openAI(#"{"choices":[{"delta":{"content":"正常"},"finish_reason":"stop"}]}"#),
                "data: [DONE]",
            ]),
        ]
        let server = try ScriptedHTTPServer { index, _ in
            (200, "text/event-stream", streams[min(index, streams.count - 1)])
        }
        try server.start()
        defer { server.stop() }
        let credentialId = "xctest-outcome-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: Self.unknownModel, name: "Outcome Test")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "结局测试卡", emoji: "🧪", type: .openaiCompatible,
                                       baseURL: server.baseURL, models: [model], toolsSupported: false))
        pm.setApiKey("test-key", for: credentialId)
        defer { pm.removeCredential(id: credentialId) }
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("outcome-\(UUID().uuidString).jsonl"))

        let expected: [(ReplyOutcome, String, Bool)] = [
            (.truncatedLength, "length", true),
            (.filtered, "content_filter", false),
            (.normal, "stop", false),
        ]
        for (outcome, reason, hit) in expected {
            let done = expectation(description: "complete")
            router.sendStreaming(
                model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
                providerManager: pm, samplingParams: sampling(4096),
                onToken: { _ in }, onComplete: { _, _ in done.fulfill() }, onError: { XCTFail($0); done.fulfill() }
            )
            await fulfillment(of: [done], timeout: 5)
            XCTAssertEqual(router.lastReplyOutcome, outcome, reason)
            XCTAssertEqual(router.lastFinishReason, reason)
            XCTAssertEqual(router.lastReplyHitOutputLimit, hit, reason)
        }
    }

    // MARK: - T6 VM 落节点

    private func vmFixture(_ stream: Data) async throws -> (PromptRealPathHarness, ProviderModel, ScriptedHTTPServer) {
        let h = try await PromptRealPathHarness.make(.init(name: "reply-outcome-\(UUID().uuidString)",
                                                          profileId: "xctest-outcome-\(UUID().uuidString)",
                                                          memoryEnabled: false, voiceHint: false,
                                                          memoryFixtures: false))
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", stream) }
        try server.start()
        let credentialId = "xctest-outcome-vm-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "xctest-outcome-vm", name: "Outcome VM")
        h.providerManager.addCredential(APICredential(id: credentialId, name: "结局 VM 卡", emoji: "🧪",
                                                      type: .openaiCompatible, baseURL: server.baseURL,
                                                      models: [model], toolsSupported: false))
        h.providerManager.setApiKey("test-key", for: credentialId)
        h.viewModel.selectedConversation?.selectedModelId = model.id
        return (h, model, server)
    }

    func testVMStoresAbnormalOutcomeOnNodeAndKeepsContentClean() async throws {
        let stream = Self.sse([
            Self.openAI(#"{"choices":[{"delta":{"content":"写到一半"},"finish_reason":"length"}]}"#),
            "data: [DONE]",
        ])
        let (h, model, server) = try await vmFixture(stream)
        defer { server.stop() }
        XCTAssertTrue(h.viewModel.sendMessage("继续写", model: model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight, "15 秒没回完")
        let node = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(node.content, "写到一半")
        XCTAssertFalse(node.content.contains("⚠️"))
        XCTAssertFalse(node.content.contains("输出上限"), "提示文字不能写进 node.content")
        XCTAssertEqual(node.replyOutcome, "length")
        XCTAssertEqual(node.finishReason, "length")
        await h.tearDown()
    }

    func testVMLeavesNormalOutcomeNil() async throws {
        let stream = Self.sse([
            Self.openAI(#"{"choices":[{"delta":{"content":"正常回复"},"finish_reason":"stop"}]}"#),
            "data: [DONE]",
        ])
        let (h, model, server) = try await vmFixture(stream)
        defer { server.stop() }
        XCTAssertTrue(h.viewModel.sendMessage("你好", model: model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.assistantTurnInFlight, "15 秒没回完")
        let node = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(node.content, "正常回复")
        XCTAssertNil(node.replyOutcome, "正常结局不写列")
        XCTAssertEqual(node.finishReason, "stop", "上游原样的 finish_reason 照存")
        await h.tearDown()
    }

    // MARK: - 换设备 / 备份：两列跟着文档走

    func testOutcomeSurvivesNodeDocumentRoundTrip() throws {
        let node = MessageNode(id: "xctest-outcome-doc", role: "assistant", content: "正文", contentType: "text",
                               createTime: Date(), parentId: nil, childrenIds: [],
                               conversationId: "sample", profileId: "test")
        node.replyOutcome = "length"
        node.finishReason = "length"

        let full = FullNodeDocument(model: node)
        let decodedFull = try JSONDecoder().decode(FullNodeDocument.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(decodedFull.toNodeModel().replyOutcome, "length")
        XCTAssertEqual(decodedFull.toNodeModel().finishReason, "length")

        var legacy = full
        legacy.replyOutcome = nil
        legacy.finishReason = nil
        let legacyBytes = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: legacyBytes, as: UTF8.self).contains("replyOutcome"))
        let legacyDecoded = try JSONDecoder().decode(FullNodeDocument.self, from: legacyBytes)
        XCTAssertNil(legacyDecoded.toNodeModel().replyOutcome)
        XCTAssertNil(legacyDecoded.toNodeModel().finishReason)

        let syncDoc = SyncStore.NodeDocument(
            id: "xctest-sync", role: "assistant", content: "正文", contentType: "text",
            createTime: nil, parentId: nil, childrenIds: [], isFavorite: false, isPinned: false, pinnedAt: nil,
            segmentsData: nil, ccMessageId: nil, replyToId: nil, replyQuote: nil, ccEdited: false, ccThinking: nil,
            imageDescsData: nil, replyOutcome: "stream_cut", finishReason: nil
        )
        let decodedSync = try JSONDecoder().decode(SyncStore.NodeDocument.self, from: JSONEncoder().encode(syncDoc))
        XCTAssertEqual(decodedSync.replyOutcome, "stream_cut")
        XCTAssertNil(decodedSync.finishReason)
    }

    // MARK: - T7 胶囊文案 / 按钮

    func testCapsuleTextAndButtonsPerOutcome() {
        let table: [(ReplyOutcome, String)] = [
            (.truncatedLength, "到输出上限，被截断了"),
            (.filtered, "被服务商的审核拦下了"),
            (.noResource, "上游资源不足，中断了"),
            (.aborted, "上游中止了这条回复"),
            (.emptyReply, "上游这次什么都没回"),
            (.streamCut, "连接断了，回复可能不完整"),
        ]
        for (outcome, text) in table {
            let latest = ReplyOutcomePresentation.make(outcome: outcome, isLatestAssistant: true, isStreaming: false)
            XCTAssertEqual(latest.text, text, "\(outcome)")
            XCTAssertEqual(latest.actionTitle, outcome == .truncatedLength ? "继续" : "重试", "\(outcome)")
            XCTAssertEqual(latest.secondaryTitle, outcome == .truncatedLength ? "重试" : nil, "\(outcome)")

            let history = ReplyOutcomePresentation.make(outcome: outcome, isLatestAssistant: false, isStreaming: false)
            XCTAssertEqual(history.text, text, "\(outcome)")
            XCTAssertNil(history.actionTitle, "历史节点没按钮：\(outcome)")
            XCTAssertNil(history.secondaryTitle, "历史节点没按钮：\(outcome)")
        }
    }

    func testRawValueDecodeIsStable() {
        XCTAssertEqual(ReplyOutcome(rawValue: "length"), .truncatedLength)
        XCTAssertEqual(ReplyOutcome(rawValue: "filtered"), .filtered)
        XCTAssertEqual(ReplyOutcome(rawValue: "stream_cut"), .streamCut)
        XCTAssertNil(ReplyOutcome(rawValue: "从来没写过的值"))
    }

    // MARK: - T8 超时文案 / 200 不拼尾巴

    func testTimeoutMapsToChinese() {
        XCTAssertEqual(BaseChatProvider.networkErrorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
                       "上游太久没回，请求超时了")
        XCTAssertEqual(BaseChatProvider.networkErrorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)),
                       NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost).localizedDescription)
    }

    func testHTTP200DoesNotAppendStatusTail() {
        let text = ProviderRouter.failureMessage("上游太久没回，请求超时了", status: 200, host: "api.deepseek.com",
                                                 modelId: "deepseek-chat", cap: nil,
                                                 sent: ParamErrorClassifier.SentShape(), errorBody: "",
                                                 providerType: .openaiCompatible, learnedNow: ParamCompat.Learned())
        XCTAssertTrue(text.contains("上游太久没回，请求超时了"))
        XCTAssertFalse(text.contains("HTTP 200"), text)

        let withStatus = ProviderRouter.failureMessage("服务器忙", status: 503, host: "api.deepseek.com",
                                                       modelId: "deepseek-chat", cap: nil,
                                                       sent: ParamErrorClassifier.SentShape(), errorBody: "",
                                                       providerType: .openaiCompatible, learnedNow: ParamCompat.Learned())
        XCTAssertTrue(withStatus.contains("HTTP 503"), withStatus)
    }
}
