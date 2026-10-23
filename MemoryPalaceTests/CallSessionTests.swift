import XCTest
@testable import 记忆花园

@MainActor
final class MockSpeechSink: CallSpeechSink {
    var log: [String] = []
    func prepareTurn() { log.append("<prepare>") }
    func speak(_ sentence: String) { log.append(sentence) }
    func endSegment() { log.append("<segment>") }
    func endTurn() { log.append("<turn>") }
    func cancel() { log.append("<cancel>") }
    var spoken: [String] { log.filter { !$0.hasPrefix("<") } }
}

/// 语音通话 T1 + V4c：CallSession 状态机——[voice] 协议 / 流式下行（gate → sink）/ 半双工时序 / 挂断清理。
/// V4c 改语义：原「turn 收口整段入队 + speakOne」换成「流式 delta 过 gate 进 sink，收口只 flush」；
/// 半双工由管线回调 playbackStarted / playbackIdle 驱动（原队列测试按新语义改写）。
@MainActor
final class CallSessionTests: XCTestCase {

    var session: CallSession!
    var sink: MockSpeechSink!
    var sent: [String] = []
    var micLog: [String] = []   // "start" / "stop" 时序

    override func setUp() async throws {
        session = CallSession()
        sink = MockSpeechSink()
        sent = []; micLog = []
        session.resumeDelay = .zero
        session.speech = sink
        session.sendUserText = { [weak self] text in self?.sent.append(text); return true }
        session.startListening = { [weak self] in self?.micLog.append("start") }
        session.stopListening = { [weak self] in self?.micLog.append("stop") }
    }

    override func tearDown() async throws {
        session.end()
        session = nil
    }

    /// 等 resume 任务（sleep(0) + syncMic）跑完
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(10))
    }

    private func stream(_ text: String, node: String = "n1", conv: String = "c1") {
        for ch in text { session.assistantStreamDelta(String(ch), nodeId: node, conversationId: conv) }
    }

    // MARK: - [voice] 协议

    func testPreambleOnlyOnFirstMessage() {
        session.begin(conversationId: "c1")
        session.userFinalTranscript("你好呀")
        session.userFinalTranscript("在干嘛")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], CallSession.preamble + "\n[voice] 你好呀")
        XCTAssertEqual(sent[1], "[voice] 在干嘛")
    }

    func testPreambleRetriedWhenSendRejected() {
        session.sendUserText = { [weak self] text in
            self?.sent.append(text)
            return self!.sent.count >= 2   // 第一条被拒（如预算拦截），第二条受理
        }
        session.begin(conversationId: "c1")
        session.userFinalTranscript("第一句")
        session.userFinalTranscript("第二句")
        XCTAssertTrue(sent[0].hasPrefix(CallSession.preamble), "首条带前缀")
        XCTAssertTrue(sent[1].hasPrefix(CallSession.preamble), "首条被拒后前缀应保留到下一条")
    }

    func testAcceptedTranscriptPreparesSpeechForTurn() {
        session.sendUserText = { [weak self] text in
            self?.sent.append(text)
            return self!.sent.count >= 2
        }
        session.begin(conversationId: "c1")
        session.userFinalTranscript("被拒")
        XCTAssertEqual(sink.log, [], "没发出去不预建连")
        session.userFinalTranscript("受理")
        XCTAssertEqual(sink.log, ["<prepare>"])
    }

    func testCCBridgePreparesTurn() {
        session.replyLandsExternally = { true }   // CC 桥接
        session.sentUserNodeId = { "request-1" }
        session.begin(conversationId: "c1")
        session.userFinalTranscript("你好")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sink.log, ["<prepare>"], "CC 也预建连，回复不来由管线预热上限收口")
        XCTAssertTrue(session.expectsExternalReply(requestId: "request-1", conversationId: "c1"))
    }

    func testEmptyAndInactiveTranscriptNotSent() {
        XCTAssertFalse(session.userFinalTranscript("通话没开"))
        session.begin(conversationId: "c1")
        XCTAssertFalse(session.userFinalTranscript("   \n"))
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - 流式下行

    func testStreamDeltasReleaseSentencesThenTurnEndFlushes() {
        session.begin(conversationId: "c1")
        stream("好呀，一起听。我去放歌")
        XCTAssertEqual(sink.log, ["好呀，一起听。"], "句子写完就交给管线，不等整轮")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { XCTFail("流式念过的不取整段"); return nil }
        XCTAssertEqual(sink.log, ["好呀，一起听。", "我去放歌", "<turn>"])
    }

    func testTurnFinishDoesNotRepeatStreamedText() {
        session.begin(conversationId: "c1")
        stream("第一句。第二句。")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { "第一句。第二句。" }
        XCTAssertEqual(sink.spoken, ["第一句。", "第二句。"], "收口只 flush，不再整段入队")
    }

    func testToolBoundaryFlushesAndEndsSegment() {
        session.begin(conversationId: "c1")
        stream("我查一下天气")
        session.assistantStreamSegmentBreak(nodeId: "n1", conversationId: "c1")
        stream("今天晴。")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { nil }
        XCTAssertEqual(sink.log, ["我查一下天气", "<segment>", "今天晴。", "<turn>"], "工具调用前的话也念")
    }

    func testFallbackWholeTextWhenNoStreamDeltas() {
        session.begin(conversationId: "c1")
        let raw = "好呀！\n```voice\n（凑近）表演脚本不该被读\n```\n**去听**那首歌吧"
        session.assistantTurnFinished(nodeId: "n9", conversationId: "c1") { raw }
        XCTAssertEqual(sink.log, ["好呀！", "去听那首歌吧", "<turn>"])
    }

    func testThinkingAndVoiceBlocksNotSpokenWhileStreaming() {
        session.begin(conversationId: "c1")
        stream("<thinking>她想听歌。</thinking>好。\n```voice\n[soft] 晚安\n```\n睡吧。")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { nil }
        XCTAssertEqual(sink.spoken, ["好。", "睡吧。"])
    }

    func testNewNodeResetsGate() {
        session.begin(conversationId: "c1")
        stream("<thinking>没写完的思考", node: "n1")
        stream("新回复。", node: "n2")
        session.assistantTurnFinished(nodeId: "n2", conversationId: "c1") { nil }
        XCTAssertEqual(sink.spoken, ["新回复。"])
    }

    func testDownlinkIgnoredWhenConversationMismatchOrInactive() {
        stream("没通话。")
        session.begin(conversationId: "c1")
        stream("别的对话。", conv: "c2")
        session.assistantStreamSegmentBreak(nodeId: "n1", conversationId: "c2")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c2") { "别的对话。" }
        XCTAssertTrue(sink.log.isEmpty)
    }

    // MARK: - 半双工

    func testHalfDuplexDrivenByPlaybackCallbacks() async {
        session.begin(conversationId: "c1")
        XCTAssertEqual(micLog, ["start"])
        stream("好呀。")
        XCTAssertEqual(micLog, ["start"], "还没出声不闭麦")
        session.playbackStarted()
        XCTAssertEqual(session.uiState, .speaking)
        session.playbackStarted()
        XCTAssertEqual(micLog, ["start", "stop"], "重复开播回调只闭一次")
        session.utteranceChanged("好呀。")
        XCTAssertEqual(session.currentUtterance, "好呀。")
        session.playbackIdle()
        await settle()
        XCTAssertEqual(micLog, ["start", "stop", "start"])
        XCTAssertEqual(session.uiState, .listening)
        XCTAssertEqual(session.currentUtterance, "")
    }

    func testPlaybackRestartDuringResumeDelayKeepsMicClosed() async {
        session.resumeDelay = .milliseconds(50)
        session.begin(conversationId: "c1")
        session.playbackStarted()
        session.playbackIdle()
        session.playbackStarted()   // 间隙里又开播
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(micLog.filter { $0 == "start" }.count, 1, "间隙里又开播就不开麦")
        XCTAssertEqual(micLog.last, "stop")
        XCTAssertTrue(session.speaking)
    }

    func testIdleWithoutPlaybackIsNoop() async {
        session.begin(conversationId: "c1")
        session.playbackIdle()
        await settle()
        XCTAssertEqual(micLog, ["start"])
    }

    func testEndCancelsSpeechResetsGateAndKeepsMicOff() async {
        session.begin(conversationId: "c1")
        stream("说到一半")
        session.playbackStarted()
        session.end()
        XCTAssertEqual(sink.log, ["<cancel>"])
        XCTAssertEqual(micLog.last, "stop", "挂断后不恢复开麦")
        XCTAssertEqual(session.uiState, .idle)
        session.playbackIdle()
        await settle()
        XCTAssertEqual(micLog.last, "stop", "挂断后迟到的空了回调不开麦")

        session.begin(conversationId: "c1")
        stream("新通话。")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { nil }
        XCTAssertEqual(sink.spoken, ["新通话。"], "挂断时 gate 已清空，上一通的半句不带过来")
    }

    // MARK: - 静音 / 状态

    func testMuteTogglesMic() {
        session.begin(conversationId: "c1")
        session.muted = true
        XCTAssertEqual(micLog, ["start", "stop"])
        session.muted = false
        XCTAssertEqual(micLog, ["start", "stop", "start"])
    }

    func testMutePersistsThroughPlaybackResume() async {
        session.begin(conversationId: "c1")
        session.muted = true
        session.playbackStarted()
        session.playbackIdle()
        await settle()
        XCTAssertEqual(micLog.last, "stop", "静音时播完不该偷偷开麦")
        XCTAssertEqual(session.uiState, .listening, "UI 态仍是 listening（由静音图标表达）")
    }

    func testThinkingState() {
        session.begin(conversationId: "c1")
        session.turnInFlight = true
        XCTAssertEqual(session.uiState, .thinking)
        session.turnInFlight = false
        XCTAssertEqual(session.uiState, .listening)
    }

    func testBeginIsIdempotentWhileActive() {
        session.begin(conversationId: "c1")
        let firstCallId = session.callId
        session.begin(conversationId: "c2")
        XCTAssertEqual(session.callId, firstCallId)
        XCTAssertEqual(session.conversationId, "c1")
    }

    func testExternalReplyRequiresOriginalRequestAndWaitsForCompletion() {
        session.replyLandsExternally = { true }
        session.sentUserNodeId = { "request-1" }
        session.begin(conversationId: "c1")
        session.userFinalTranscript("你好")
        XCTAssertEqual(session.uiState, .thinking)
        session.externalReply("旧消息。", nodeId: "old", conversationId: "c1", requestId: "old-request", streaming: false)
        session.externalReply("别的对话。", nodeId: "other", conversationId: "c2", requestId: "request-1", streaming: false)
        session.externalReply("", nodeId: "placeholder", conversationId: "c1", requestId: "request-1", streaming: false)
        session.externalReply("还没写完", nodeId: "reply", conversationId: "c1", requestId: "request-1", streaming: true)
        XCTAssertTrue(sink.spoken.isEmpty)
        session.externalReply("我在呢。", nodeId: "reply", conversationId: "c1", requestId: "request-1", streaming: false)
        session.externalReply("我在呢。", nodeId: "reply", conversationId: "c1", requestId: "request-1", streaming: false)
        XCTAssertEqual(sink.spoken, ["我在呢。"])
        XCTAssertEqual(sink.log.last, "<turn>")
    }

    func testInterruptInvalidatesBeforeSynchronousCancelNotification() {
        session.begin(conversationId: "c1")
        session.activeReplyNodeId = { "n1" }
        session.turnInFlight = true
        stream("第一句。未写完")
        session.playbackStarted()
        session.cancelReply = { [unowned self] in
            self.session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") {
                XCTFail("取消收口不应重新取旧回复朗读"); return "第一句。未写完"
            }
        }
        session.interruptReply()
        stream("迟到的尾巴。")
        session.assistantStreamSegmentBreak(nodeId: "n1", conversationId: "c1")
        XCTAssertEqual(sink.spoken, ["第一句。"])
        XCTAssertEqual(sink.log.last, "<cancel>")
        XCTAssertEqual(session.uiState, .listening)
        XCTAssertEqual(micLog.last, "start")
        stream("新的回应。", node: "n2")
        session.assistantTurnFinished(nodeId: "n2", conversationId: "c1") { nil }
        XCTAssertEqual(sink.spoken.last, "新的回应。")
    }

    func testInterruptBeforeFirstDeltaRejectsThatNode() {
        session.begin(conversationId: "c1")
        session.activeReplyNodeId = { "n1" }
        session.interruptReply()
        stream("第一块晚到。")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { "晚到的整段" }
        XCTAssertTrue(sink.spoken.isEmpty)
    }

    func testExternalReplyAfterInterruptOrNewCallIsNotSpoken() {
        session.replyLandsExternally = { true }
        session.sentUserNodeId = { "request-1" }
        session.begin(conversationId: "c1")
        session.userFinalTranscript("你好")
        session.interruptReply()
        session.externalReply("迟到。", nodeId: "old", conversationId: "c1", requestId: "request-1", streaming: false)
        session.end()
        session.begin(conversationId: "c1")
        session.externalReply("旧通话回复。", nodeId: "old", conversationId: "c1", requestId: "request-1", streaming: false)
        XCTAssertTrue(sink.spoken.isEmpty)
    }

    func testMutedOrPlaybackLateFinalDoesNotSendUserMessage() {
        session.begin(conversationId: "c1")
        session.muted = true
        XCTAssertFalse(session.userFinalTranscript("静音期间迟到"))
        session.muted = false
        session.playbackStarted()
        XCTAssertFalse(session.userFinalTranscript("停止识别时迟到"))
        XCTAssertTrue(sent.isEmpty)
    }

    func testDuplicateCompletedTurnDoesNotReadFallbackOrSpeakAgain() {
        session.begin(conversationId: "c1")
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { "你好。" }
        session.assistantTurnFinished(nodeId: "n1", conversationId: "c1") { XCTFail("重复收口"); return "你好。" }
        stream("重复尾巴。")
        XCTAssertEqual(sink.spoken, ["你好。"])
    }

    func testCCCorrelationDoesNotUseQuotedMessageAsRequest() {
        XCTAssertNil(CCCallReply.fromFrame(["reply_to": "request-1"]))
        XCTAssertNil(CCCallReply.fromFrame(["message_id": ""]))
        let meta = CCCallReply.fromFrame(["message_id": "request-1", "streaming": true])
        XCTAssertEqual(meta?.requestId, "request-1")
        XCTAssertEqual(meta?.streaming, true)
    }
}
