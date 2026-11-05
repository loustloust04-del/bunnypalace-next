import XCTest
@testable import 记忆花园

/// 模型兼容 P0 阶段 3 · B：OpenAI 兼容路解析思考（plan-model-compat-p0 §4.5）。不发真请求
final class OpenAIReasoningStreamTests: XCTestCase {

    private func drain() {
        let e = expectation(description: "主队列排空")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private static func chunk(_ delta: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: ["choices": [["delta": delta]]], options: [.sortedKeys]),
                          as: UTF8.self) + "\n\n"
    }

    private static func content(_ pieces: [String]) -> String { pieces.map { chunk(["content": $0]) }.joined() }

    private struct Result {
        var content: String
        var tokens: [String]
        var reasoning: ReasoningCapture
        var completed: [String]
    }

    private func run(_ sse: String, split: Bool = true, done: Bool = true) -> Result {
        let p = OpenAICompatibleProvider()
        var tokens: [String] = []
        var completed: [String] = []
        p.resetState(onToken: { tokens.append($0) }, onComplete: { t, _ in completed.append(t) }, onError: { _ in })
        p.splitsLeadingThinkTag = split
        p.processData(Data((sse + (done ? "data: [DONE]\n\n" : "")).utf8))
        drain()
        return Result(content: p.streamingContent, tokens: tokens, reasoning: p.reasoning, completed: completed)
    }

    // MARK: - 字段名

    func testTextFieldsRecordSourceField() {
        for field in ReasoningCapture.textFields {
            let r = run(Self.chunk([field: "先想"]) + Self.chunk([field: "一下"]) + Self.content(["正文"]))
            XCTAssertEqual(r.reasoning.text, "先想一下", field)
            XCTAssertEqual(r.reasoning.field, field)
            XCTAssertEqual(r.content, "正文", field)
            XCTAssertEqual(r.reasoning.segment, .thinking(text: "先想一下", signature: nil))
        }
    }

    func testSameChunkTwoNamesTakenOnce() {
        let r = run(Self.chunk(["reasoning_content": "想", "reasoning": "想"]) + Self.content(["答"]))
        XCTAssertEqual(r.reasoning.text, "想")
        XCTAssertEqual(r.reasoning.field, "reasoning_content")
    }

    func testEmptyReasoningEveryChunkIsNotThinking() {
        let sse = [Self.chunk(["reasoning_content": "", "content": "你"]), Self.chunk(["reasoning_content": NSNull(), "content": "好"])].joined()
        let r = run(sse)
        XCTAssertTrue(r.reasoning.isEmpty)
        XCTAssertNil(r.reasoning.field)
        XCTAssertNil(r.reasoning.segment)
        XCTAssertEqual(r.content, "你好")
    }

    func testReasoningObjectIsSkipped() {
        let r = run(Self.chunk(["reasoning": ["effort": "high"], "content": "答"]))
        XCTAssertTrue(r.reasoning.isEmpty)
        XCTAssertEqual(r.content, "答")
    }

    /// OpenRouter：三种 type 分 3 片、带 index；同一片已有 reasoning 字符串时不从 details 再补一份
    func testReasoningDetailsMergedByIndex() throws {
        let sse = [
            Self.chunk(["reasoning": "第一", "reasoning_details": [["type": "reasoning.text", "text": "第一", "index": 0, "format": "anthropic-claude-v1"]]]),
            Self.chunk(["reasoning_details": [["type": "reasoning.text", "text": "段", "index": 0, "signature": "sig-A"]]]),
            Self.chunk(["reasoning_details": [["type": "reasoning.summary", "summary": "摘要", "index": 1]]]),
            Self.chunk(["reasoning_details": [["type": "reasoning.encrypted", "data": "ENC1", "index": 2, "id": "r-2"]]]),
            Self.chunk(["reasoning_details": [["type": "reasoning.encrypted", "data": "ENC2", "index": 2]]]),
            Self.content(["答"]),
        ].joined()
        let r = run(sse)
        XCTAssertEqual(r.reasoning.field, "reasoning_details")
        XCTAssertEqual(r.reasoning.text, "第一段摘要")
        let d = r.reasoning.details
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d[0]["text"] as? String, "第一段")
        XCTAssertEqual(d[0]["signature"] as? String, "sig-A")
        XCTAssertEqual(d[0]["format"] as? String, "anthropic-claude-v1")
        XCTAssertEqual(d[1]["summary"] as? String, "摘要")
        XCTAssertEqual(d[2]["data"] as? String, "ENC1ENC2")
        XCTAssertEqual(d[2]["id"] as? String, "r-2")
        XCTAssertEqual(d.map { $0["index"] as? Int }, [0, 1, 2])
        XCTAssertEqual(r.content, "答")
    }

    func testEncryptedOnlyDetailsReplayableButNoSegment() {
        let r = run(Self.chunk(["reasoning_details": [["type": "reasoning.encrypted", "data": "ENC", "index": 0]]]) + Self.content(["答"]))
        XCTAssertFalse(r.reasoning.isEmpty)
        XCTAssertNil(r.reasoning.segment, "只有密文不存段")
    }

    // MARK: - 正文开头的 <think>

    func testLeadingThinkTagSplitAcrossChunks() {
        let r = run(Self.content(["<thi", "nk>想", "法</th", "ink>正文"]))
        XCTAssertEqual(r.reasoning.text, "想法")
        XCTAssertEqual(r.reasoning.field, "think_tag")
        XCTAssertEqual(r.content, "正文")
        XCTAssertEqual(r.completed, ["正文"])
    }

    func testThinkTagSplitAtEveryCharacterMatchesWhole() {
        let whole = "\n<think>\n先想想\n</think>\n\n回答：<b>好</b>"
        let chars = Array(whole)
        for cut in 1..<chars.count {
            let r = run(Self.content([String(chars[..<cut]), String(chars[cut...])]))
            XCTAssertEqual(r.reasoning.text, "先想想", "切在第 \(cut) 字")
            XCTAssertEqual(r.content, "回答：<b>好</b>", "切在第 \(cut) 字")
        }
    }

    func testThinkTagInMiddleIsLeftAlone() {
        let r = run(Self.content(["好的。<think>人设要求写的</think>", "继续"]))
        XCTAssertTrue(r.reasoning.isEmpty)
        XCTAssertEqual(r.content, "好的。<think>人设要求写的</think>继续")
    }

    func testSwitchOffKeepsTagInBody() {
        let r = run(Self.content(["<think>想</think>正文"]), split: false)
        XCTAssertTrue(r.reasoning.isEmpty)
        XCTAssertEqual(r.content, "<think>想</think>正文")
    }

    func testNativeReasoningDisablesTagSplit() {
        let r = run(Self.chunk(["reasoning_content": "原生"]) + Self.content(["<think>x</think>正文"]))
        XCTAssertEqual(r.reasoning.text, "原生")
        XCTAssertEqual(r.reasoning.field, "reasoning_content")
        XCTAssertEqual(r.content, "<think>x</think>正文")
    }

    /// 原生思考迟到（审查 #4）：原生优先，拆到一半的标签原文整段还给正文，结果同「先收到原生就不拆」；回传字段名用原生的
    func testLateNativeInTagPrefixLeavesTagInBody() {
        let r = run(Self.content(["<thi"]) + Self.chunk(["reasoning_content": "原生", "content": "nk>标签</think>正文"]))
        XCTAssertEqual(r.reasoning.text, "原生")
        XCTAssertEqual(r.reasoning.field, "reasoning_content")
        XCTAssertEqual(r.content, "<think>标签</think>正文")
    }

    func testLateNativeInsideTagGivesTagBack() {
        let r = run(Self.content([" <think>标签"]) + Self.chunk(["reasoning": "原生"]) + Self.content(["</think>正文"]))
        XCTAssertEqual(r.reasoning.text, "原生", "标签候选不混进原生思考")
        XCTAssertEqual(r.reasoning.field, "reasoning", "回传写回原生字段，不退回默认 reasoning_content")
        XCTAssertTrue(r.reasoning.hasNative)
        XCTAssertEqual(r.content, " <think>标签</think>正文")
        XCTAssertEqual(r.completed, [" <think>标签</think>正文"])
    }

    func testLateNativeDetailsInsideTagThenDone() {
        let detail: [String: Any] = ["type": "reasoning.text", "text": "原生", "index": 0]
        let r = run(Self.content(["<think>标签", "还在想"]) + Self.chunk(["reasoning_details": [detail]]))
        XCTAssertEqual(r.reasoning.text, "原生")
        XCTAssertEqual(r.reasoning.field, "reasoning_details")
        XCTAssertEqual(r.content, "<think>标签还在想", "[DONE] 收尾时也还给正文")
    }

    func testLateNativeAfterTagClosedBeforeBody() {
        let r = run(Self.content(["<think>标签</think>\n"]) + Self.chunk(["reasoning_content": "原生"]) + Self.content(["正文"]))
        XCTAssertEqual(r.reasoning.text, "原生")
        XCTAssertEqual(r.content, "<think>标签</think>\n正文")
    }

    func testHeldPrefixReleasedWhenNotATag() {
        let r = run(Self.content(["  <th", "ing>不是标签"]))
        XCTAssertTrue(r.reasoning.isEmpty)
        XCTAssertEqual(r.content, "  <thing>不是标签")
    }

    func testUnclosedThinkIsAllThinkingAtDone() {
        let r = run(Self.content(["<think>想到一半", "</thi"]))
        XCTAssertEqual(r.reasoning.text, "想到一半</thi")
        XCTAssertEqual(r.content, "")
    }

    func testHeldPrefixFlushedAtDone() {
        let r = run(Self.content(["<thi"]))
        XCTAssertEqual(r.content, "<thi")
        XCTAssertEqual(r.completed, ["<thi"], "[DONE] 先冲刷压着的正文再完成")
    }

    // MARK: - 没收到 [DONE] 的结束：真实 delegate 入口

    private func deliverWithoutDone(_ sse: String, errorTail: String? = nil) -> (events: [String], provider: OpenAICompatibleProvider) {
        let p = OpenAICompatibleProvider()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.invalid/v1")!)
        let delegate = ChatRequestDelegate(owner: p, generation: p.pacedGeneration + 1)
        var events: [String] = []
        p.resetState(onToken: { events.append("token:\($0)") }, onComplete: { t, _ in events.append("complete:\(t)") },
                     onError: { events.append("error:\($0)") })
        p.splitsLeadingThinkTag = true
        p.urlSession = session
        p.sessionGeneration = p.pacedGeneration
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
        delegate.urlSession(session, dataTask: task, didReceive: Data((sse + (errorTail ?? "")).utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        drain()
        return (events, p)
    }

    func testEOFWithoutDoneFlushesHeldThenCompletesOnce() {
        let r = deliverWithoutDone(Self.content(["<thi"]))
        XCTAssertEqual(r.events, ["token:<thi", "complete:<thi"])
    }

    func testEOFWithoutDoneUnclosedThinkSettlesAsNoReply() {
        let r = deliverWithoutDone(Self.content(["<think>想"]))
        XCTAssertEqual(r.events, ["error:未收到回复"], "只有思考没正文：照旧报没回复（思考由 router 挂到节点上）")
        XCTAssertEqual(r.provider.reasoning.text, "想")
    }

    func testErrorTailWithHeldContentTerminatesOnce() {
        let r = deliverWithoutDone(Self.content(["<thi"]), errorTail: #"data: {"error":{"message":"上游炸了"}}"#)
        XCTAssertEqual(r.events, ["error:上游炸了"], "流内报错后不再吐压着的正文、只终止一次")
    }

    /// 审查 #3：报错之后的 [DONE] 不冲刷正文、不派完成（同批 / 跨批）
    private static let streamError = "data: {\"error\":{\"message\":\"上游炸了\"}}\n\n"

    func testErrorThenDoneSameBatchIsSilent() {
        let r = deliverWithoutDone(Self.content(["<thi"]) + Self.streamError + "data: [DONE]\n\n" + Self.content(["迟到"]))
        XCTAssertEqual(r.events, ["error:上游炸了"])
        XCTAssertEqual(r.provider.streamingContent, "")
    }

    func testErrorThenDoneAcrossBatchesIsSilent() {
        for head in [Self.content(["<thi"]), Self.content(["答"])] {
            let p = OpenAICompatibleProvider()
            var events: [String] = []
            p.resetState(onToken: { events.append("token:\($0)") }, onComplete: { t, _ in events.append("complete:\(t)") },
                         onError: { events.append("error:\($0)") })
            p.splitsLeadingThinkTag = true
            for batch in [head, Self.streamError, "data: [DONE]\n\n", Self.content(["迟到"])] {
                p.processData(Data(batch.utf8))
                drain()
            }
            let tokens = head.contains("答") ? ["token:答"] : []
            XCTAssertEqual(events, tokens + ["error:上游炸了"], "onError 之后零 onToken / onComplete")
        }
    }

    // MARK: - 非流式整包

    func testNonStreamReasoningContent() throws {
        let p = OpenAICompatibleProvider()
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"答","reasoning_content":"想"},"finish_reason":"stop"}]}"#.utf8)
        let r = try p.parseNonStreamBody(body)
        XCTAssertEqual(r.text, "答")
        XCTAssertEqual(r.reasoning.text, "想")
        XCTAssertEqual(r.reasoning.field, "reasoning_content")
    }

    func testNonStreamReasoningDetailsKeptVerbatim() throws {
        let p = OpenAICompatibleProvider()
        let body = Data(#"{"choices":[{"message":{"content":"答","reasoning_details":[{"type":"reasoning.text","text":"想","signature":"s","index":0},{"type":"reasoning.encrypted","data":"E","index":1}]}}]}"#.utf8)
        let r = try p.parseNonStreamBody(body)
        XCTAssertEqual(r.reasoning.field, "reasoning_details")
        XCTAssertEqual(r.reasoning.text, "想")
        XCTAssertEqual(r.reasoning.details.count, 2)
        XCTAssertEqual(r.reasoning.details[0]["signature"] as? String, "s")
    }

    func testNonStreamThinkTagFollowsSwitch() throws {
        let body = Data(#"{"choices":[{"message":{"content":"<think>想</think>\n答"}}]}"#.utf8)
        let on = OpenAICompatibleProvider()
        on.splitsLeadingThinkTag = true
        let split = try on.parseNonStreamBody(body)
        XCTAssertEqual(split.text, "答")
        XCTAssertEqual(split.reasoning.text, "想")
        let off = try OpenAICompatibleProvider().parseNonStreamBody(body)
        XCTAssertEqual(off.text, "<think>想</think>\n答", "后台任务的独立实例不拆，和以前一样")
        XCTAssertTrue(off.reasoning.isEmpty)
    }

    // MARK: - VM 段形状

    func testReplySegmentsWithReasoning() {
        var reasoning = ReasoningCapture()
        reasoning.field = "reasoning_content"
        reasoning.text = "想"
        XCTAssertEqual(ConversationViewModel.replySegments([], text: "说", reasoning: reasoning),
                       [.thinking(text: "想", signature: nil), .text("说")], "工具轮：思考在正文前")
        XCTAssertEqual(ConversationViewModel.replySegments([], text: "", reasoning: reasoning), [.thinking(text: "想", signature: nil)])
        XCTAssertEqual(ConversationViewModel.replySegments([], text: "说", reasoning: ReasoningCapture()), [.text("说")])
        let blocks = [ReplyBlock(raw: ["type": "thinking", "thinking": "块", "signature": "s"], complete: true),
                      ReplyBlock(raw: ["type": "text", "text": "说"], complete: true)]
        XCTAssertEqual(ConversationViewModel.replySegments(blocks, text: "说", reasoning: reasoning),
                       ConversationViewModel.replySegments(blocks, text: "说"), "Anthropic 块的段和改前一致")
    }

    func testPlainReplyAttachesThinkingAfterText() {
        let node = MessageNode(id: "n1", role: "assistant", content: "正文", contentType: "text", createTime: nil, parentId: nil,
                               childrenIds: [], conversationId: "c")
        ConversationViewModel.attachThinking([.thinking(text: "想", signature: nil)], to: node, base: nil)
        XCTAssertEqual(node.segments, [.text("正文"), .thinking(text: "想", signature: nil)])
    }
}

/// router：这一次的思考才给（序号守卫），思考也算已输出（Q11）
@MainActor
final class OpenAIReasoningRouterTests: XCTestCase {
    typealias Server = OutputTokenCapTests.ScriptedHTTPServer

    static let thinkingReply = OutputTokenCapTests.sse([
        #"data: {"choices":[{"delta":{"reasoning_content":"先想"}}]}"#,
        #"data: {"choices":[{"delta":{"reasoning_content":"一下","content":""}}]}"#,
        #"data: {"choices":[{"delta":{"content":"答"}}]}"#,
        "data: [DONE]",
    ])

    private var cleanups: [() -> Void] = []

    override func tearDown() async throws {
        cleanups.forEach { $0() }
        cleanups = []
    }

    private func fixture(_ server: Server) -> (ProviderRouter, ProviderManager, ProviderModel) {
        let credentialId = "xctest-reasoning-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "xctest-thinker", name: "Reasoning Test")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "思考测试卡", emoji: "🧠", type: .openaiCompatible,
                                       baseURL: server.baseURL, models: [model], toolsSupported: true))
        pm.setApiKey("test-key", for: credentialId)
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("reasoning-\(UUID().uuidString).jsonl"))
        cleanups.append {
            pm.removeCredential(id: credentialId)
            server.stop()
        }
        return (router, pm, model)
    }

    func testLastThinkingSegmentsThenEarlyFailureReadsEmpty() async throws {
        let server = try Server { _, _ in (200, "text/event-stream", Self.thinkingReply) }
        try server.start()
        let (router, pm, model) = fixture(server)
        let done = expectation(description: "done")
        var text = ""
        router.sendStreaming(model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil, providerManager: pm,
                             onToken: { _ in }, onComplete: { t, _ in text = t; done.fulfill() }, onError: { _ in done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(text, "答")
        XCTAssertEqual(router.lastReasoning?.field, "reasoning_content")
        XCTAssertEqual(router.lastThinkingSegments, [.thinking(text: "先想一下", signature: nil)])

        let failed = expectation(description: "failed")
        let missing = ProviderModel(credentialId: "xctest-missing-\(UUID().uuidString)", modelId: "m", name: "m")
        router.sendStreaming(model: missing, messages: [(role: "user", content: "hi")], systemPrompt: nil, providerManager: pm,
                             onToken: { _ in }, onComplete: { _, _ in failed.fulfill() }, onError: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNil(router.lastReasoning, "提前失败读不到上一次的思考")
        XCTAssertEqual(router.lastThinkingSegments, [])
    }
}
