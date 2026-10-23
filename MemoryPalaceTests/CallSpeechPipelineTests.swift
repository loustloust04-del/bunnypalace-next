import XCTest
@testable import 记忆花园

// MARK: - mocks

/// 跨线程记账（synthesize / send 在后台跑）
final class LockedLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor
final class MockCallOutput: CallAudioOutput {
    var log: [String] = []
    var failPCM = false
    var failPlay = false

    func schedulePCM(_ clip: AudioClip) throws {
        if failPCM { throw VoiceSynthError.badAudio }
        log.append("pcm:" + String(decoding: clip.data, as: UTF8.self))
    }
    /// 设了就卡在排空上，测试手动放行
    var drainGate: TestGate?
    func waitPCMDrained() async {
        if let drainGate { await drainGate.wait() }
    }
    func play(_ clip: AudioClip) async throws {
        if failPlay { throw VoiceSynthError.badAudio }
        log.append("clip:" + String(decoding: clip.data, as: UTF8.self))
        await Task.yield()
    }
    func speakSystem(_ text: String, voice: String?) async {
        log.append("system:" + text)
        await Task.yield()
    }
    func stop() { log.append("stop") }
}

class MockStream: VoiceStream, @unchecked Sendable {
    let chunks: AsyncThrowingStream<AudioClip, Error>
    private let continuation: AsyncThrowingStream<AudioClip, Error>.Continuation
    let sent = LockedLog<String>()
    let ops = LockedLog<String>()
    /// 每 send 一句就回一块同文字的 PCM
    var echo = true
    var failOnSend: String?

    init() {
        (chunks, continuation) = AsyncThrowingStream<AudioClip, Error>.makeStream()
    }

    func send(_ text: String) async throws {
        if text == failOnSend { throw VoiceSynthError.network }
        sent.append(text)
        if echo { continuation.yield(AudioClip(data: Data(text.utf8), format: .pcm16, sampleRate: 24_000)) }
    }
    func flush() async throws { ops.append("flush") }
    /// 手动吐一块（模拟「首包只含第一句开头」）
    func emit(_ text: String) {
        continuation.yield(AudioClip(data: Data(text.utf8), format: .pcm16, sampleRate: 24_000))
    }
    /// 模拟断流
    func breakConnection() { continuation.finish(throwing: VoiceSynthError.network) }
    func finish() async throws {
        ops.append("finish")
        continuation.finish()
    }
    func cancel() {
        ops.append("cancel")
        continuation.finish()
    }
    var finished: Bool { ops.all.contains("finish") }
}

final class MockKeepAliveStream: MockStream, VoiceStreamKeepAlive {
    func keepAlive() async throws { ops.append("keepAlive") }
}

/// 测试手动放行（不靠计时，机器忙也稳）
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }
    func open() {
        lock.lock(); opened = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
}

final class MockSynth: VoiceSynthesizer, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    let started = LockedLog<String>()
    var gates: [String: TestGate] = [:]
    var failing: Set<String> = []
    var makeStream: (() -> MockStream)?
    private(set) var streams: [MockStream] = []
    let prewarms = LockedLog<Int>()

    var capabilities: VoiceCapabilities { VoiceCapabilities(supportsStreaming: makeStream != nil) }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
        started.append(text)
        lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
        defer { lock.lock(); inFlight -= 1; lock.unlock() }
        if let g = gates[text] { await g.wait() }
        if failing.contains(text) { throw VoiceSynthError.network }
        return AudioClip(data: Data(text.utf8), format: .mp3)
    }

    func prewarmConnection() { prewarms.append(1) }

    func openStream(voice: String?, model: String?) -> (any VoiceStream)? {
        guard let makeStream else { return nil }
        let s = makeStream()
        streams.append(s)
        return s
    }
}

// MARK: - tests

/// V4b：通话朗读管线——流式顺序 / 分句预取 / generation 丢弃 / 出错降级系统音 / 空了回调
@MainActor
final class CallSpeechPipelineTests: XCTestCase {

    var output: MockCallOutput!
    var synth: MockSynth!
    var idleCount = 0
    var startedCount = 0
    var utterances: [String] = []
    var errors: [String] = []

    override func setUp() async throws {
        output = MockCallOutput()
        synth = MockSynth()
        idleCount = 0; startedCount = 0; utterances = []; errors = []
    }

    private func makePipeline(route: CallSpeechPipeline.Route? = nil) -> CallSpeechPipeline {
        let p = CallSpeechPipeline(route: route ?? .init(synthesizer: synth, voice: "v1", model: "m1"), output: output)
        p.tuning = { VoiceTuning.Settings(stability: 0.5, similarityBoost: 0.75, style: 0, speed: 1) }
        p.onIdle = { [weak self] in self?.idleCount += 1 }
        p.onPlaybackStarted = { [weak self] in self?.startedCount += 1 }
        p.onUtterance = { [weak self] in self?.utterances.append($0) }
        p.reportError = { [weak self] in self?.errors.append($0) }
        return p
    }

    private func waitUntil(_ timeout: Duration = .seconds(2), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待超时", file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    // MARK: - 流式

    func testStreamingSendsInOrderAndPlaysPCMThenIdle() async {
        synth.makeStream = { MockStream() }
        let p = makePipeline()
        XCTAssertTrue(synth.streams.isEmpty, "没话说不开流")
        p.speak("第一句。")
        p.speak("第二句。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(synth.streams.count, 1)
        XCTAssertEqual(synth.streams[0].sent.all, ["第一句。", "第二句。"])
        XCTAssertTrue(synth.streams[0].finished)
        XCTAssertEqual(synth.streams[0].ops.all, ["flush", "finish"], "只有第一句后强制出声一次")
        XCTAssertEqual(output.log, ["pcm:第一句。", "pcm:第二句。"])
        XCTAssertGreaterThanOrEqual(startedCount, 1)
        XCTAssertTrue(synth.started.all.isEmpty, "流式不走整段合成")
    }

    func testSegmentBoundaryClosesStreamAndNextSentenceReopens() async {
        synth.makeStream = { MockStream() }
        let p = makePipeline()
        p.speak("工具前。")
        p.endSegment()
        p.speak("工具后。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(synth.streams.count, 2)
        XCTAssertEqual(synth.streams[0].sent.all, ["工具前。"])
        XCTAssertTrue(synth.streams[0].finished)
        XCTAssertEqual(synth.streams[1].sent.all, ["工具后。"])
        XCTAssertEqual(output.log, ["pcm:工具前。", "pcm:工具后。"])
    }

    func testStreamIdleTimeoutFinishesWithoutKeepAlive() async {
        synth.makeStream = { MockStream() }
        let p = makePipeline()
        p.streamIdleTimeout = .milliseconds(30)
        p.speak("一句。")
        await waitUntil { self.synth.streams.first?.finished == true }
        p.speak("隔了很久。")
        XCTAssertEqual(synth.streams.count, 2, "收口后下一句开新流")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
    }

    func testStreamKeepAliveWhenSupported() async {
        synth.makeStream = { MockKeepAliveStream() }
        let p = makePipeline()
        p.streamIdleTimeout = .milliseconds(20)
        p.speak("一句。")
        await waitUntil { (self.synth.streams.first?.ops.all.filter { $0 == "keepAlive" }.count ?? 0) >= 2 }
        XCTAssertFalse(synth.streams[0].finished, "能保活就不收口")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertTrue(synth.streams[0].finished)
    }

    func testPrepareTurnPrewarmsKeepAliveStreamAndFirstSentenceReusesIt() async {
        synth.makeStream = { MockKeepAliveStream() }
        let p = makePipeline()
        p.streamIdleTimeout = .milliseconds(20)
        p.prepareTurn()
        XCTAssertEqual(synth.streams.count, 1, "这一轮一开始就开流")
        await waitUntil { (self.synth.streams[0].ops.all.filter { $0 == "keepAlive" }.count) >= 2 }
        XCTAssertTrue(synth.streams[0].sent.all.isEmpty, "预建连不发字")
        p.speak("第一句。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(synth.streams.count, 1, "第一句复用预建的流")
        XCTAssertEqual(synth.streams[0].sent.all, ["第一句。"])
        XCTAssertEqual(output.log, ["pcm:第一句。"])
        XCTAssertTrue(synth.streams[0].finished)
    }

    func testPrewarmWithoutTextClosesAtLimitAndNextSentenceOpensNewStream() async {
        synth.makeStream = { MockKeepAliveStream() }
        let p = makePipeline()
        p.streamIdleTimeout = .milliseconds(10)
        p.prewarmLimit = .milliseconds(60)
        p.prepareTurn()
        await waitUntil { self.synth.streams[0].finished }
        XCTAssertTrue(synth.streams[0].sent.all.isEmpty, "预热流一个字没发")
        XCTAssertTrue(synth.streams[0].ops.all.contains("keepAlive"), "上限前照常保活")
        p.speak("回复终于来了。")
        XCTAssertEqual(synth.streams.count, 2, "上限收口后下一句开新流")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(synth.streams[1].sent.all, ["回复终于来了。"])
        XCTAssertEqual(output.log, ["pcm:回复终于来了。"])
    }

    func testPrewarmThenTextBeforeLimitKeepsAliveWithoutClosing() async {
        synth.makeStream = { MockKeepAliveStream() }
        let p = makePipeline()
        p.streamIdleTimeout = .milliseconds(20)
        p.prewarmLimit = .milliseconds(80)
        p.prepareTurn()
        p.speak("一句。")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(synth.streams[0].finished, "来过字就不按预热上限收口")
        XCTAssertGreaterThanOrEqual(synth.streams[0].ops.all.filter { $0 == "keepAlive" }.count, 2, "保活照常")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(synth.streams.count, 1)
        XCTAssertTrue(synth.streams[0].finished)
    }

    func testPreparedTurnWithNothingToSayFinishesAndGoesIdle() async {
        synth.makeStream = { MockKeepAliveStream() }
        let p = makePipeline()
        p.prepareTurn()
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertTrue(synth.streams[0].finished)
        XCTAssertTrue(output.log.isEmpty)
        XCTAssertEqual(startedCount, 0)
    }

    func testPrepareWithoutKeepAliveDoesNotTouchStreamUntilText() async {
        synth.makeStream = { MockStream() }
        let p = makePipeline()
        p.prepareTurn()
        await settle()
        XCTAssertTrue(synth.streams[0].ops.all.isEmpty, "不能保活的流不提前动")
        p.speak("一句。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(synth.streams.count, 1)
        XCTAssertEqual(output.log, ["pcm:一句。"])
    }

    func testSegmentBoundaryPrewarmsNextStream() async {
        synth.makeStream = { MockKeepAliveStream() }
        let p = makePipeline()
        p.speak("工具前。")
        p.endSegment()
        XCTAssertEqual(synth.streams.count, 2, "工具边界后下一段的流先建好")
        await waitUntil { self.synth.streams[1].ops.all.contains("keepAlive") }
        p.speak("工具后。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(synth.streams.count, 2)
        XCTAssertEqual(synth.streams[1].sent.all, ["工具后。"])
        XCTAssertEqual(output.log, ["pcm:工具前。", "pcm:工具后。"])
    }

    func testPrepareOnChunkedServiceIsNoop() async {
        let p = makePipeline()
        p.prepareTurn()
        p.speak("一句。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["clip:一句。"])
    }

    func testPrepareOnChunkedRoutePrewarmsConnection() async {
        let p = makePipeline()
        p.prepareTurn()
        XCTAssertEqual(synth.prewarms.all.count, 1, "非流式模型：整段路线预连接")
        p.speak("一句。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
    }

    func testPrepareOnStreamRouteDoesNotPrewarmConnection() {
        synth.makeStream = { MockKeepAliveStream() }
        let p = makePipeline()
        p.prepareTurn()
        XCTAssertEqual(synth.streams.count, 1)
        XCTAssertTrue(synth.prewarms.all.isEmpty, "流式路线靠预建流，不另发预连接")
        p.cancel()
    }

    func testPrepareOnEffectsRoutePrewarmsConnection() {
        synth.makeStream = { MockKeepAliveStream() }
        var config = VoiceEffectConfiguration(); config.enabled = true; config.callEnabled = true
        config.kissIDs = [UUID().uuidString]
        let p = makePipeline(route: .init(synthesizer: synth, voice: "v1", effects: config, profileID: "p"))
        p.prepareTurn()
        XCTAssertTrue(synth.streams.isEmpty)
        XCTAssertEqual(synth.prewarms.all.count, 1, "音效路线整段合成，也预连接")
    }

    func testDegradedTurnDoesNotPrewarmConnection() async {
        synth.failing = ["坏。"]
        let p = makePipeline()
        p.speak("坏。")
        await waitUntil { self.output.log.contains("system:坏。") }
        p.endSegment()   // 本轮还没完 → prepareTurn，但已降级
        XCTAssertTrue(synth.prewarms.all.isEmpty, "降级后不预连接")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
    }

    func testStreamErrorBeforeAudioFallsBackToSystemForAllItsSentences() async {
        synth.makeStream = {
            let s = MockStream()
            s.echo = false
            s.failOnSend = "甲。"
            return s
        }
        let p = makePipeline()
        p.speak("甲。")
        p.speak("乙。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["system:甲。", "system:乙。"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(synth.streams[0].ops.all.contains("cancel"))
    }

    func testStreamErrorThenLaterSentencesGoSystem() async {
        synth.makeStream = {
            let s = MockStream()
            s.failOnSend = "乙。"
            return s
        }
        let p = makePipeline()
        p.speak("甲。")
        await waitUntil { self.output.log.contains("pcm:甲。") }
        p.speak("乙。")
        await waitUntil { self.synth.streams[0].ops.all.contains("cancel") }
        p.speak("丙。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["pcm:甲。", "system:甲。", "system:乙。", "system:丙。"],
                       "断了的那段没正常收尾 → 整段系统音补念（宁可重一句）；之后的句子走系统音")
        XCTAssertEqual(synth.streams.count, 1, "出错后本轮不再开流")
        XCTAssertEqual(errors.count, 1)
    }

    func testStreamBreakAfterPartialFirstChunkReplaysAllSentences() async {
        synth.makeStream = {
            let s = MockStream()
            s.echo = false
            return s
        }
        let p = makePipeline()
        p.speak("甲句很长。")
        p.speak("乙句。")
        p.speak("丙句。")
        await waitUntil { self.synth.streams[0].sent.all.count == 3 }
        synth.streams[0].emit("甲句")   // 首包只含第一句开头
        await waitUntil { self.output.log == ["pcm:甲句"] }
        synth.streams[0].breakConnection()
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["pcm:甲句", "system:甲句很长。", "system:乙句。", "system:丙句。"],
                       "未确认念完的三句都补念")
    }

    func testHangupWhileFallbackWaitsForDrainNeverSpeaks() async {
        synth.makeStream = {
            let s = MockStream()
            s.echo = false
            return s
        }
        let drain = TestGate()
        output.drainGate = drain
        let p = makePipeline()
        p.speak("一句。")
        await waitUntil { self.synth.streams[0].sent.all == ["一句。"] }
        synth.streams[0].emit("一")
        await waitUntil { self.output.log == ["pcm:一"] }
        synth.streams[0].breakConnection()
        await waitUntil { self.errors.count == 1 }   // 已进系统音兜底，卡在等 PCM 排空
        await settle()
        let captionsBefore = utterances
        p.cancel()
        drain.open()
        await settle()
        XCTAssertEqual(output.log, ["pcm:一", "stop"], "挂断后绝不再开口")
        XCTAssertEqual(utterances, captionsBefore, "挂断后字幕也不再动")
        XCTAssertEqual(idleCount, 0)
    }

    func testPCMPlaybackFailureFallsBackToSystem() async {
        synth.makeStream = { MockStream() }
        output.failPCM = true
        let p = makePipeline()
        p.speak("放不出来。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["system:放不出来。"])
    }

    // MARK: - 分句 + 预取

    func testChunkedPrefetchAtMostThreeAndPlaysInOrder() async {
        let first = TestGate()
        synth.gates = ["1。": first]
        let p = makePipeline()
        for i in 1...5 { p.speak("\(i)。") }
        await waitUntil { self.synth.started.all.count == 3 }
        await settle()
        XCTAssertEqual(Set(synth.started.all), ["1。", "2。", "3。"], "第一句没播完前最多预取 3 句")
        XCTAssertTrue(output.log.isEmpty)
        first.open()
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["clip:1。", "clip:2。", "clip:3。", "clip:4。", "clip:5。"])
        XCTAssertLessThanOrEqual(synth.maxInFlight, 3)
        XCTAssertEqual(utterances, ["1。", "2。", "3。", "4。", "5。"])
    }

    func testCancelDiscardsStaleGeneration() async {
        let old = TestGate()
        synth.gates = ["旧的。": old]
        let p = makePipeline()
        p.speak("旧的。")
        await waitUntil { self.synth.started.all == ["旧的。"] }
        p.cancel()
        p.speak("新的。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        old.open()   // 挂断前发出的合成这时才回来
        await settle()
        XCTAssertEqual(output.log, ["stop", "clip:新的。"], "挂断前的合成结果回来也不播")
        XCTAssertEqual(idleCount, 1)
    }

    func testSynthesisErrorDegradesCurrentAndRestOfTurnThenNextTurnRetries() async {
        synth.failing = ["二。"]
        let p = makePipeline()
        for s in ["一。", "二。", "三。", "四。"] { p.speak(s) }
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["clip:一。", "system:二。", "system:三。", "system:四。"])
        XCTAssertEqual(errors, ["网络不行"])

        p.speak("下一轮。")
        p.endTurn()
        await waitUntil { self.idleCount == 2 }
        XCTAssertEqual(output.log.last, "clip:下一轮。", "新一轮重新试楼层服务")
    }

    func testPlaybackErrorFallsBackToSystem() async {
        output.failPlay = true
        let p = makePipeline()
        p.speak("播不了。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["system:播不了。"])
    }

    // MARK: - 空了回调

    func testIdleOnlyAfterTurnEnds() async {
        let p = makePipeline()
        p.speak("还没完。")
        await waitUntil { self.output.log == ["clip:还没完。"] }
        await settle()
        XCTAssertEqual(idleCount, 0, "本轮没结束不算空")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
    }

    func testEmptyTurnStillReportsIdle() async {
        let p = makePipeline()
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(startedCount, 0)
    }

    func testNoIdleAfterCancel() async {
        let p = makePipeline()
        p.speak("一句。")
        p.endTurn()
        p.cancel()
        await settle()
        XCTAssertEqual(idleCount, 0)
    }

    func testSystemRouteSpeaksWithSystemVoice() async {
        let p = makePipeline(route: .system)
        p.speak("系统音。")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertEqual(output.log, ["system:系统音。"])
    }

    func testCallEffectsExplicitlyUsesClipPathAndMissingCuesDoNotReachTTS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p4-call-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = MockKeepAliveStream()
        synth.makeStream = { stream }
        var config = VoiceEffectConfiguration(); config.enabled = true; config.callEnabled = true
        config.kissIDs = [UUID().uuidString]
        let p = makePipeline(route: .init(synthesizer: synth, voice: "v1", effects: config, profileID: "p"))
        p.effectLibrary = VoiceEffectLibrary { _ in root }
        p.prepareTurn()
        p.speak("[sfx:kiss]")  // 缺素材，不能因此将本轮降级成系统音
        p.speak("你好[sfx:kiss]晚安")
        p.endTurn()
        await waitUntil { self.idleCount == 1 }
        XCTAssertTrue(synth.streams.isEmpty)
        XCTAssertEqual(synth.started.all, ["你好晚安"])
        XCTAssertEqual(output.log, ["clip:你好晚安"])
        XCTAssertTrue(errors.isEmpty)
    }

    func testCancellingEffectsTurnDiscardsLateSynthesis() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p4-call-cancel-\(UUID().uuidString)")
        let gate = TestGate()
        synth.gates["你好"] = gate
        var config = VoiceEffectConfiguration(); config.enabled = true; config.callEnabled = true
        config.kissIDs = [UUID().uuidString]
        let p = makePipeline(route: .init(synthesizer: synth, effects: config, profileID: "p"))
        p.effectLibrary = VoiceEffectLibrary { _ in root }
        p.speak("你好[sfx:kiss]"); p.endTurn()
        await waitUntil { self.synth.started.all == ["你好"] }
        p.cancel(); gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(output.log, ["stop"])
        XCTAssertEqual(idleCount, 0)
    }

    // MARK: - 楼层 → 路由

    private func makeStore() -> (VoiceServiceStore, () -> Void) {
        let suite = "CallSpeechPipelineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = VoiceServiceStore(defaults: defaults, keychainService: "com.susu.MemoryPalace.test.callpipe-\(UUID().uuidString)")
        return (store, { defaults.removePersistentDomain(forName: suite) })
    }

    private func profile() -> Profile {
        Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
    }

    func testRouteResolution() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        XCTAssertNil(CallSpeechPipeline.Route.resolve(profile: nil, store: store, legacyKey: { nil }).synthesizer)

        let system = VoiceService.blank(kind: .system)
        store.add(system)
        var p = profile()
        p.voiceServiceId = system.id
        p.voiceId = "com.apple.voice.zh"
        let sysRoute = CallSpeechPipeline.Route.resolve(profile: p, store: store, legacyKey: { nil })
        XCTAssertNil(sysRoute.synthesizer, "系统音服务直接走 AVSpeech")
        XCTAssertEqual(sysRoute.systemVoice, "com.apple.voice.zh")

        let eleven = VoiceService.blank(kind: .elevenLabs)
        store.add(eleven)
        p.voiceServiceId = eleven.id
        p.voiceId = "voice-x"
        let elevenRoute = CallSpeechPipeline.Route.resolve(profile: p, store: store, legacyKey: { nil })
        XCTAssertNotNil(elevenRoute.synthesizer)
        XCTAssertEqual(elevenRoute.voice, "voice-x")
        XCTAssertEqual(elevenRoute.serviceId, eleven.id)
        XCTAssertEqual(elevenRoute.model, elevenRoute.synthesizer?.capabilities.resolvedModel(nil))

        var legacy = profile()
        legacy.elevenVoiceId = "old-voice"
        let legacyRoute = CallSpeechPipeline.Route.resolve(profile: legacy, store: store, legacyKey: { "k" })
        XCTAssertTrue(legacyRoute.synthesizer is LegacyElevenLabsCallSynthesizer)
        XCTAssertEqual(legacyRoute.voice, "old-voice")
        XCTAssertNil(CallSpeechPipeline.Route.resolve(profile: legacy, store: store, legacyKey: { nil }).synthesizer,
                     "老楼层没 key 走系统音")
    }
}
