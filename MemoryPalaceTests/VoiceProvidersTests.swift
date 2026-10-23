import XCTest
@testable import 记忆花园

/// plan-voice-providers V2：三家请求格式（URLProtocol mock）+ 错误映射 + ElevenLabs 模型分流 / WSS 帧编解码 / 流式会话。
final class VoiceProvidersTests: XCTestCase {

    final class MockProtocol: URLProtocol {
        struct Reply {
            var status = 200
            var headers: [String: String] = [:]
            var body = Data()
        }
        static var reply: (URLRequest) -> Reply = { _ in Reply() }
        static var lastRequest: URLRequest?
        static var lastBody: Data?
        static var requests = LockedLog<URLRequest>()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            Self.requests.append(request)
            Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
            let r = Self.reply(request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: r.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }
    }

    private let tuning = VoiceTuning.Settings(stability: 0.5, similarityBoost: 0.75, style: 0.88, speed: 1.1)

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockProtocol.reply = { _ in MockProtocol.Reply() }
        MockProtocol.lastRequest = nil
        MockProtocol.lastBody = nil
        MockProtocol.requests = LockedLog<URLRequest>()
        super.tearDown()
    }

    private func lastJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(MockProtocol.lastBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func eleven(key: String? = "k-eleven") -> ElevenLabsSynthesizer {
        ElevenLabsSynthesizer(keyProvider: { key }, session: session)
    }

    private func assertThrows(_ expected: VoiceSynthError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("应抛 \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VoiceSynthError, expected, file: file, line: line)
        }
    }

    // MARK: - ElevenLabs：模型分流

    func testElevenV4UsesDialogueEndpoint() async throws {
        MockProtocol.reply = { _ in .init(body: Data([0xFF, 0xFB])) }
        let clip = try await eleven().synthesize(text: "[whispering] 嗨。", voice: "v1", model: "eleven_v4", tuning: tuning)
        XCTAssertEqual(clip, AudioClip(data: Data([0xFF, 0xFB]), format: .mp3, sampleRate: 44_100))

        let req = try XCTUnwrap(MockProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-dialogue?output_format=mp3_44100_128")
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "k-eleven")
        let json = try lastJSON()
        XCTAssertEqual(json["model_id"] as? String, "eleven_v4")
        let inputs = try XCTUnwrap(json["inputs"] as? [[String: String]])
        XCTAssertEqual(inputs, [["text": "[whispering] 嗨。", "voice_id": "v1"]])
        let settings = try XCTUnwrap(json["settings"] as? [String: Double])
        XCTAssertEqual(settings, ["stability": 0.5, "similarity": 0.75], "v4 只带表演感 + 相似度")
        XCTAssertNil(json["voice_settings"])
    }

    func testElevenDialogueSendsNeighborContextOnlyWhenGiven() async throws {
        MockProtocol.reply = { _ in .init(body: Data([1])) }
        let long = String(repeating: "前", count: 150) + "尾"
        _ = try await eleven().synthesize(text: "好", voice: "v1", model: "eleven_v4", tuning: tuning,
                                          context: VoiceSynthesisContext(previous: long, next: "晚安"))
        var json = try lastJSON()
        XCTAssertEqual((json["previous_text"] as? String)?.count, 100, "官方单边上限 100 字，取前文的尾巴")
        XCTAssertEqual((json["previous_text"] as? String)?.last, "尾")
        XCTAssertEqual(json["future_text"] as? String, "晚安")

        _ = try await eleven().synthesize(text: "好", voice: "v1", model: "eleven_v4", tuning: tuning, context: nil)
        json = try lastJSON()
        XCTAssertNil(json["previous_text"]); XCTAssertNil(json["future_text"])

        _ = try await eleven().synthesize(text: "好", voice: "v1", model: "eleven_v3", tuning: tuning,
                                          context: VoiceSynthesisContext(previous: "前", next: "后"))
        json = try lastJSON()
        XCTAssertNil(json["previous_text"]); XCTAssertNil(json["next_text"], "v3 不支持请求拼接，不带")
    }

    func testElevenV4TurboSynthesizeAlsoDialogue() async throws {
        MockProtocol.reply = { _ in .init(body: Data([1])) }
        _ = try await eleven().synthesize(text: "好", voice: "v1", model: "eleven_v4_turbo", tuning: tuning)
        XCTAssertEqual(MockProtocol.lastRequest?.url?.path, "/v1/text-to-dialogue")
        XCTAssertEqual(try lastJSON()["model_id"] as? String, "eleven_v4_turbo")
    }

    func testElevenV3KeepsLegacyTTSEndpoint() async throws {
        MockProtocol.reply = { _ in .init(body: Data([1])) }
        _ = try await eleven().synthesize(text: "[softly] 好。", voice: "v9", model: "eleven_v3", tuning: tuning)
        XCTAssertEqual(MockProtocol.lastRequest?.url?.absoluteString,
                       "https://api.elevenlabs.io/v1/text-to-speech/v9?output_format=mp3_44100_128")
        let json = try lastJSON()
        XCTAssertEqual(json["text"] as? String, "[softly] 好。")
        XCTAssertEqual(json["model_id"] as? String, "eleven_v3")
        let vs = try XCTUnwrap(json["voice_settings"] as? [String: Double])
        XCTAssertEqual(vs, ["stability": 0.5, "similarity_boost": 0.75, "style": 0.88, "speed": 1.1])
    }

    func testV3StabilityClampedToThreeLevelsV4Continuous() async throws {
        MockProtocol.reply = { _ in .init(body: Data([1])) }
        var t = tuning
        t.stability = 0.3
        _ = try await eleven().synthesize(text: "a", voice: "v", model: "eleven_v3", tuning: t)
        XCTAssertEqual((try lastJSON()["voice_settings"] as? [String: Double])?["stability"], 0.5, "v3 钳到最近档")
        _ = try await eleven().synthesize(text: "a", voice: "v", model: "eleven_v4", tuning: t)
        XCTAssertEqual((try lastJSON()["settings"] as? [String: Double])?["stability"], 0.3, "v4 连续值原样")
        XCTAssertEqual(ElevenLabsSynthesizer.v3Stability(0.8), 1.0)
        XCTAssertEqual(ElevenLabsSynthesizer.v3Stability(0.1), 0.0)
    }

    func testElevenUnknownOrNilModelFallsBackToV4() async throws {
        MockProtocol.reply = { _ in .init(body: Data([1])) }
        _ = try await eleven().synthesize(text: "a", voice: "v", model: nil, tuning: tuning)
        XCTAssertEqual(try lastJSON()["model_id"] as? String, "eleven_v4")
        _ = try await eleven().synthesize(text: "a", voice: "v", model: "eleven_v9", tuning: tuning)
        XCTAssertEqual(try lastJSON()["model_id"] as? String, "eleven_v4")
    }

    func testElevenErrorsMapped() async {
        let synth = eleven()
        MockProtocol.reply = { _ in .init(status: 401) }
        await assertThrows(.invalidKey) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        MockProtocol.reply = { _ in .init(status: 429) }
        await assertThrows(.quotaOrRateLimited) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        MockProtocol.reply = { _ in .init(status: 422, body: Data(#"{"detail":{"status":"x","message":"bad stability"}}"#.utf8)) }
        await assertThrows(.server(422, "bad stability")) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        await assertThrows(.missingKey) { _ = try await self.eleven(key: nil).synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        await assertThrows(.missingVoice) { _ = try await synth.synthesize(text: "a", voice: "", model: nil, tuning: self.tuning) }
    }

    func testElevenFetchVoices() async throws {
        MockProtocol.reply = { _ in
            .init(body: Data(#"{"voices":[{"voice_id":"a1","name":"Ann","preview_url":"https://x/p.mp3","category":"cloned"}]}"#.utf8))
        }
        let voices = try await eleven().fetchVoices()
        XCTAssertEqual(MockProtocol.lastRequest?.url?.absoluteString, "https://api.elevenlabs.io/v1/voices")
        XCTAssertEqual(MockProtocol.lastRequest?.value(forHTTPHeaderField: "xi-api-key"), "k-eleven")
        XCTAssertEqual(voices, [VoiceOption(id: "a1", name: "Ann", previewURL: URL(string: "https://x/p.mp3"), detail: "cloned")])
    }

    func testElevenPrewarmConnectionIsKeylessHeadAndThrottled() async throws {
        let keyReads = LockedLog<Int>()
        let synth = ElevenLabsSynthesizer(keyProvider: { keyReads.append(1); return "k-eleven" }, session: session)
        synth.prewarmConnection()
        synth.prewarmConnection()
        let copy = synth
        copy.prewarmConnection()
        let deadline = ContinuousClock.now + .seconds(2)
        while MockProtocol.requests.all.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        let reqs = MockProtocol.requests.all
        XCTAssertEqual(reqs.count, 1, "20s 内（含拷贝）只发一次")
        let req = try XCTUnwrap(reqs.first)
        XCTAssertEqual(req.httpMethod, "HEAD")
        XCTAssertEqual(req.url, ElevenLabsSynthesizer.prewarmURL)
        XCTAssertNil(req.value(forHTTPHeaderField: "xi-api-key"), "预连接不带 key")
        XCTAssertTrue(keyReads.all.isEmpty, "预连接不读 key")
    }

    func testPrewarmThrottleReopensAfterInterval() {
        let throttle = PrewarmThrottle(interval: 20)
        let t0 = Date()
        XCTAssertTrue(throttle.claim(now: t0))
        XCTAssertFalse(throttle.claim(now: t0.addingTimeInterval(19)))
        XCTAssertTrue(throttle.claim(now: t0.addingTimeInterval(20)))
    }

    func testElevenCapabilitiesByModel() {
        let caps = eleven().capabilities
        XCTAssertTrue(caps.supportsTags)
        XCTAssertTrue(caps.supportsStreaming)
        XCTAssertTrue(caps.canFetchVoices)
        XCTAssertEqual(caps.models.map(\.id), ["eleven_v4", "eleven_v4_turbo", "eleven_v3"])
        XCTAssertEqual(caps.tunables(for: "eleven_v4"), [.stability, .similarity])
        XCTAssertEqual(caps.tunables(for: "eleven_v4_turbo"), [.stability, .similarity])
        XCTAssertEqual(caps.tunables(for: "eleven_v3"), [.stability, .similarity, .style, .speed])
        XCTAssertNil(eleven().openStream(voice: "v", model: "eleven_v4"), "v4 不流式")
        XCTAssertNil(eleven().openStream(voice: "v", model: "eleven_v3"))
        XCTAssertNil(eleven().openStream(voice: nil, model: "eleven_v4_turbo"), "没声音不开")
        XCTAssertNotNil(eleven().openStream(voice: "v", model: "eleven_v4_turbo"))
    }

    // MARK: - ElevenLabs：WSS 帧

    func testDialogueFramesEncode() {
        XCTAssertEqual(ElevenLabsDialogueFrames.streamURL(model: "eleven_v4_turbo").absoluteString,
                       "wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input?model_id=eleven_v4_turbo&output_format=pcm_24000")
        XCTAssertEqual(ElevenLabsDialogueFrames.initFrame(voiceId: "v1", apiKey: "k"), #"{"voices":["v1"],"xi_api_key":"k"}"#)
        XCTAssertEqual(ElevenLabsDialogueFrames.textFrame("你好。", voiceId: "v1"), #"{"inputs":[{"text":"你好。","voice_id":"v1"}]}"#)
        XCTAssertEqual(ElevenLabsDialogueFrames.flushFrame, #"{"flush":true}"#)
        XCTAssertEqual(ElevenLabsDialogueFrames.keepAliveFrame, #"{"keep_alive":true}"#)
        XCTAssertEqual(ElevenLabsDialogueFrames.closeFrame, #"{"close_socket":true}"#)
    }

    func testDialogueFramesDecode() {
        let pcm = Data([1, 0, 2, 0])
        XCTAssertEqual(ElevenLabsDialogueFrames.decode(#"{"audio":"\#(pcm.base64EncodedString())","is_final":false,"alignment":{}}"#),
                       .init(audio: pcm, isFinal: false, error: nil))
        XCTAssertEqual(ElevenLabsDialogueFrames.decode(#"{"is_final":true}"#), .init(audio: nil, isFinal: true, error: nil))
        XCTAssertEqual(ElevenLabsDialogueFrames.decode(#"{"audio":null,"isFinal":true}"#).isFinal, true)
        let err = ElevenLabsDialogueFrames.decode(#"{"error":"invalid_api_key","message":"Invalid API key"}"#)
        XCTAssertEqual(err.error, "invalid_api_key: Invalid API key")
        XCTAssertEqual(ElevenLabsDialogueFrames.mapError(err.error!, secrets: []), .invalidKey)
        XCTAssertEqual(ElevenLabsDialogueFrames.mapError("quota_exceeded", secrets: []), .quotaOrRateLimited)
        XCTAssertEqual(ElevenLabsDialogueFrames.mapError("boom", secrets: []), .server(0, "boom"))
        XCTAssertNotNil(ElevenLabsDialogueFrames.decode("not json").error)
    }

    // MARK: - ElevenLabs：流式会话（假 WebSocket）

    final class FakeTransport: VoiceWebSocketTransport {
        private let lock = NSLock()
        private var _sent: [String] = []
        private(set) var connected = false
        private(set) var closed = false
        let incoming: AsyncStream<String>
        private let feed: AsyncStream<String>.Continuation
        private var iterator: AsyncStream<String>.Iterator

        init() {
            (incoming, feed) = AsyncStream.makeStream(of: String.self)
            iterator = incoming.makeAsyncIterator()
        }

        var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
        func push(_ text: String) { feed.yield(text) }

        func connect() { connected = true }
        func send(_ text: String) async throws { lock.lock(); _sent.append(text); lock.unlock() }
        func receive() async throws -> String? { await iterator.next() }
        func close() { closed = true; feed.finish() }
    }

    private func makeStream(_ fake: FakeTransport, key: String? = "k", keepAlive: TimeInterval = 10) -> ElevenLabsDialogueStream {
        ElevenLabsDialogueStream(url: ElevenLabsDialogueFrames.streamURL(model: "eleven_v4_turbo"), voiceId: "v1",
                                 keyProvider: { key }, transportFactory: { _ in fake }, keepAliveInterval: keepAlive)
    }

    func testStreamSendsFramesAndYieldsPCM() async throws {
        let fake = FakeTransport()
        let stream = makeStream(fake)
        XCTAssertFalse(fake.connected, "没说话不连")
        try await stream.send("你好。")
        try await stream.send("  ")
        try await stream.flush()
        try await stream.finish()
        XCTAssertTrue(fake.connected)
        XCTAssertEqual(fake.sent, [
            #"{"voices":["v1"],"xi_api_key":"k"}"#,
            #"{"inputs":[{"text":"你好。","voice_id":"v1"}]}"#,
            #"{"flush":true}"#,
            #"{"close_socket":true}"#,
        ])
        let pcm = Data([1, 0, 2, 0, 3, 0])
        fake.push(#"{"audio":"\#(pcm.base64EncodedString())","is_final":false}"#)
        fake.push(#"{"audio":"\#(Data([4, 0]).base64EncodedString())"}"#)
        fake.push(#"{"is_final":true}"#)
        var clips: [AudioClip] = []
        for try await clip in stream.chunks { clips.append(clip) }
        XCTAssertEqual(clips, [AudioClip(data: pcm, format: .pcm16, sampleRate: 24_000),
                               AudioClip(data: Data([4, 0]), format: .pcm16, sampleRate: 24_000)])
        XCTAssertTrue(fake.closed)
    }

    func testStreamFinishWithoutTextEndsWithoutConnecting() async throws {
        let fake = FakeTransport()
        let stream = makeStream(fake)
        try await stream.flush()
        try await stream.finish()
        var count = 0
        for try await _ in stream.chunks { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(fake.connected)
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testStreamErrorFrameFailsChunks() async throws {
        let fake = FakeTransport()
        let stream = makeStream(fake)
        try await stream.send("嗨。")
        fake.push(#"{"error":"invalid_api_key","message":"Invalid API key"}"#)
        do {
            for try await _ in stream.chunks {}
            XCTFail("应抛错")
        } catch {
            XCTAssertEqual(error as? VoiceSynthError, .invalidKey)
        }
    }

    /// 通话预建连：未连 → 建连 + 只发首帧；已连 → keep_alive 帧；之后第一句复用连接、flush 真发
    func testKeepAliveConnectsThenPings() async throws {
        let fake = FakeTransport()
        let stream = makeStream(fake)
        let keepAlive: VoiceStreamKeepAlive = stream
        try await keepAlive.keepAlive()
        XCTAssertTrue(fake.connected)
        XCTAssertEqual(fake.sent, [#"{"voices":["v1"],"xi_api_key":"k"}"#], "只注册声音不发字")
        try await keepAlive.keepAlive()
        XCTAssertEqual(fake.sent.last, #"{"keep_alive":true}"#)
        try await stream.send("第一句。")
        try await stream.flush()
        XCTAssertEqual(fake.sent, [
            #"{"voices":["v1"],"xi_api_key":"k"}"#,
            #"{"keep_alive":true}"#,
            #"{"inputs":[{"text":"第一句。","voice_id":"v1"}]}"#,
            #"{"flush":true}"#,
        ], "复用同一连接，不重发首帧")
        stream.cancel()
    }

    func testKeepAliveWithoutKeyThrows() async {
        let stream = makeStream(FakeTransport(), key: nil)
        await assertThrows(.missingKey) { try await stream.keepAlive() }
    }

    func testStreamWithoutKeyThrows() async {
        let stream = makeStream(FakeTransport(), key: nil)
        await assertThrows(.missingKey) { try await stream.send("嗨。") }
    }

    func testStreamKeepAliveWhenIdle() async throws {
        let fake = FakeTransport()
        let stream = makeStream(fake, keepAlive: 0.2)
        try await stream.send("嗨。")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(fake.sent.contains(ElevenLabsDialogueFrames.keepAliveFrame), "闲着要保活：\(fake.sent)")
        stream.cancel()
        let n = fake.sent.count
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fake.sent.count, n, "cancel 后不再保活")
        XCTAssertTrue(fake.closed)
    }

    // MARK: - OpenAI 兼容

    private func openAI(base: String? = nil, key: String? = "sk-test") -> OpenAICompatibleSynthesizer {
        var s = VoiceService.blank(kind: .openAICompatible)
        s.baseURL = base
        s.openAICompatibleOptions.models = ["tts-1", "gpt-4o-mini-tts"]
        return OpenAICompatibleSynthesizer(service: s, keyProvider: { key }, session: session)
    }

    func testOpenAIRequestShape() async throws {
        MockProtocol.reply = { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: Data([0xFF, 0xF3])) }
        let clip = try await openAI(base: "https://api.siliconflow.cn/v1/").synthesize(
            text: "你好", voice: "alloy", model: "gpt-4o-mini-tts", tuning: tuning)
        XCTAssertEqual(clip.format, .mp3)
        XCTAssertEqual(clip.data, Data([0xFF, 0xF3]))
        let req = try XCTUnwrap(MockProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.siliconflow.cn/v1/audio/speech")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let json = try lastJSON()
        XCTAssertEqual(Set(json.keys), ["model", "input", "voice", "response_format"])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(json["input"] as? String, "你好")
        XCTAssertEqual(json["voice"] as? String, "alloy")
        XCTAssertEqual(json["response_format"] as? String, "mp3")
    }

    func testOpenAIDefaultsBaseURLAndModel() async throws {
        MockProtocol.reply = { _ in .init(body: Data([1])) }
        _ = try await openAI().synthesize(text: "a", voice: "nova", model: nil, tuning: tuning)
        XCTAssertEqual(MockProtocol.lastRequest?.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(try lastJSON()["model"] as? String, "tts-1", "没选模型用列表第一个")
    }

    func testOpenAIErrors() async {
        let synth = openAI()
        MockProtocol.reply = { _ in .init(status: 401) }
        await assertThrows(.invalidKey) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        MockProtocol.reply = { _ in .init(status: 400, body: Data(#"{"error":{"message":"bad voice"}}"#.utf8)) }
        await assertThrows(.server(400, "bad voice")) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        MockProtocol.reply = { _ in .init(headers: ["Content-Type": "application/json"], body: Data(#"{"message":"no balance"}"#.utf8)) }
        await assertThrows(.server(200, "no balance")) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        await assertThrows(.missingKey) { _ = try await self.openAI(key: nil).synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
    }

    func testOpenAICapabilitiesAndVoices() async throws {
        let synth = openAI()
        XCTAssertFalse(synth.capabilities.supportsTags)
        XCTAssertFalse(synth.capabilities.supportsStreaming)
        XCTAssertEqual(synth.capabilities.models.map(\.id), ["tts-1", "gpt-4o-mini-tts"])
        XCTAssertNil(synth.openStream(voice: "alloy", model: nil))
        let voices = try await synth.fetchVoices()
        XCTAssertEqual(voices.map(\.id), OpenAICompatibleSynthesizer.builtinVoices)
    }

    // MARK: - MiniMax

    private func miniMax(base: String? = nil, groupId: String = "", key: String? = "mm-key") -> MiniMaxSynthesizer {
        var s = VoiceService.blank(kind: .miniMax)
        s.baseURL = base
        s.miniMaxOptions.groupId = groupId
        return MiniMaxSynthesizer(service: s, keyProvider: { key }, session: session)
    }

    private func sse(_ events: [String]) -> Data {
        Data(events.map { "data: \($0)\n\n" }.joined().utf8)
    }

    func testMiniMaxRequestShapeAndSSEHexDecode() async throws {
        MockProtocol.reply = { _ in
            .init(headers: ["Content-Type": "text/event-stream"], body: self.sse([
                #"{"data":{"audio":"fffb","status":1},"base_resp":{"status_code":0,"status_msg":""}}"#,
                #"{"data":{"audio":"9001","status":1},"base_resp":{"status_code":0,"status_msg":""}}"#,
                #"{"data":{"audio":"","status":2},"extra_info":{"audio_length":10},"base_resp":{"status_code":0,"status_msg":"success"}}"#,
            ]))
        }
        let clip = try await miniMax().synthesize(text: "你好呀", voice: "female-shaonv", model: "speech-2.8-turbo", tuning: tuning)
        XCTAssertEqual(clip.data, Data([0xFF, 0xFB, 0x90, 0x01]))
        XCTAssertEqual(clip.format, .mp3)

        let req = try XCTUnwrap(MockProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.minimax.cn/v1/t2a_v2")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer mm-key")
        let json = try lastJSON()
        XCTAssertEqual(json["model"] as? String, "speech-2.8-turbo")
        XCTAssertEqual(json["text"] as? String, "你好呀")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual((json["stream_options"] as? [String: Bool])?["exclude_aggregated_audio"], true)
        let vs = try XCTUnwrap(json["voice_setting"] as? [String: Any])
        XCTAssertEqual(vs["voice_id"] as? String, "female-shaonv")
        XCTAssertEqual(vs["speed"] as? Double, 1.1)
        let audio = try XCTUnwrap(json["audio_setting"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "mp3")
        XCTAssertEqual(audio["sample_rate"] as? Int, 32_000)
    }

    func testMiniMaxGroupIdAndBaseURL() async throws {
        MockProtocol.reply = { _ in .init(body: self.sse([#"{"data":{"audio":"01"},"base_resp":{"status_code":0}}"#])) }
        _ = try await miniMax(base: "https://api.minimax.io/v1/", groupId: " g123 ").synthesize(
            text: "a", voice: "v", model: nil, tuning: tuning)
        XCTAssertEqual(MockProtocol.lastRequest?.url?.absoluteString, "https://api.minimax.io/v1/t2a_v2?GroupId=g123")
        XCTAssertEqual(try lastJSON()["model"] as? String, "speech-2.8-hd", "没选模型用第一个")
    }

    func testMiniMaxBusinessErrorEvenOn200() async {
        let synth = miniMax()
        // 鉴权失败：HTTP 200 + 单个 JSON（实测 10-04 回包形状）
        MockProtocol.reply = { _ in
            .init(body: Data(#"{"base_resp":{"status_code":1004,"status_msg":"login fail: Please carry the API secret key"}}"#.utf8))
        }
        await assertThrows(.invalidKey) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        // 流到一半出业务错
        MockProtocol.reply = { _ in
            .init(body: self.sse([
                #"{"data":{"audio":"01"},"base_resp":{"status_code":0}}"#,
                #"{"base_resp":{"status_code":2013,"status_msg":"invalid params"}}"#,
            ]))
        }
        await assertThrows(.server(2013, "invalid params")) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        MockProtocol.reply = { _ in .init(body: Data(#"{"base_resp":{"status_code":1039,"status_msg":"tpm"}}"#.utf8)) }
        await assertThrows(.quotaOrRateLimited) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        MockProtocol.reply = { _ in .init(body: self.sse([#"{"data":{"audio":"","status":2},"base_resp":{"status_code":0}}"#])) }
        await assertThrows(.badAudio) { _ = try await synth.synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        await assertThrows(.missingVoice) { _ = try await synth.synthesize(text: "a", voice: nil, model: nil, tuning: self.tuning) }
    }

    func testMiniMaxFetchVoices() async throws {
        MockProtocol.reply = { _ in
            .init(body: Data(#"""
            {"system_voice":[{"voice_id":"female-shaonv","voice_name":"少女音色","description":["清亮"],"created_time":"1970-01-01"}],
             "voice_cloning":[{"voice_id":"my-clone","description":[],"created_time":"2026-10-01"}],
             "voice_generation":null,
             "base_resp":{"status_code":0,"status_msg":"success"}}
            """#.utf8))
        }
        let voices = try await miniMax().fetchVoices()
        XCTAssertEqual(MockProtocol.lastRequest?.url?.absoluteString, "https://api.minimax.cn/v1/get_voice")
        XCTAssertEqual(try lastJSON()["voice_type"] as? String, "all")
        XCTAssertEqual(voices, [
            VoiceOption(id: "my-clone", name: "my-clone", detail: "克隆"),
            VoiceOption(id: "female-shaonv", name: "少女音色", detail: "清亮"),
        ])
    }

    func testMiniMaxHexAndEvents() {
        XCTAssertEqual(MiniMaxSynthesizer.hexDecode("00ffA0"), Data([0x00, 0xFF, 0xA0]))
        XCTAssertNil(MiniMaxSynthesizer.hexDecode("abc"))
        XCTAssertNil(MiniMaxSynthesizer.hexDecode("zz"))
        let body = Data("event: x\r\ndata: {\"a\":1}\r\n\r\n: comment\ndata: [DONE]\n\n".utf8)
        XCTAssertEqual(MiniMaxSynthesizer.events(in: body), [#"{"a":1}"#, "[DONE]"])
    }

    func testMiniMaxCapabilities() {
        let caps = miniMax().capabilities
        XCTAssertFalse(caps.supportsTags)
        XCTAssertTrue(caps.canFetchVoices)
        XCTAssertEqual(caps.tunables, [.speed])
        XCTAssertEqual(caps.models.first?.id, "speech-2.8-hd")
    }

    // MARK: - 去敏（sol P1-1）：先用本次 key 整段去敏，再截断

    /// 没有 sk- / Bearer 形状的裸 key，恰好被 160 字截断点切开
    private static let bareKey = "ELKEY1234567890ABCDEFGHIJ"
    private static var bodySplittingKey: String { String(repeating: "x", count: 150) + bareKey + " tail" }

    private func assertNoKeyLeak(_ error: VoiceSynthError?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .server(_, let detail?) = error else { return XCTFail("应是带正文的 server 错：\(String(describing: error))", file: file, line: line) }
        XCTAssertFalse(detail.contains("ELKEY"), "key 前缀漏了：\(detail)", file: file, line: line)
        XCTAssertTrue(detail.contains("•••"), file: file, line: line)
        XCTAssertLessThanOrEqual(detail.count, VoiceHTTP.detailLimit, file: file, line: line)
    }

    private func capture(_ body: () async throws -> Void) async -> VoiceSynthError? {
        do { try await body(); return nil } catch { return error as? VoiceSynthError }
    }

    func testNaiveTruncationWouldSplitKey() {
        XCTAssertTrue(String(Self.bodySplittingKey.prefix(160)).hasSuffix("ELKEY12345"), "夹具确实把 key 切在截断点上")
        XCTAssertFalse(VoiceHTTP.clip(Self.bodySplittingKey, secrets: [Self.bareKey]).contains("ELKEY"))
    }

    func testElevenHTTPErrorRedactedWithRequestKey() async {
        let body = Data(Self.bodySplittingKey.utf8)
        MockProtocol.reply = { _ in .init(status: 500, body: body) }
        let err = await capture { _ = try await self.eleven(key: Self.bareKey).synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        assertNoKeyLeak(err)
    }

    func testOpenAIJSONErrorRedacted() async {
        let json = try! JSONSerialization.data(withJSONObject: ["error": ["message": Self.bodySplittingKey]])
        MockProtocol.reply = { _ in .init(status: 400, body: json) }
        let err = await capture { _ = try await self.openAI(key: Self.bareKey).synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        assertNoKeyLeak(err)
    }

    func testMiniMaxStatusMsgRedacted() async {
        let json = try! JSONSerialization.data(withJSONObject: ["base_resp": ["status_code": 2013, "status_msg": Self.bodySplittingKey]])
        MockProtocol.reply = { _ in .init(body: json) }
        let err = await capture { _ = try await self.miniMax(key: Self.bareKey).synthesize(text: "a", voice: "v", model: nil, tuning: self.tuning) }
        assertNoKeyLeak(err)
    }

    func testStreamErrorFrameRedactedWithConnectKey() async throws {
        let fake = FakeTransport()
        let stream = makeStream(fake, key: Self.bareKey)
        try await stream.send("嗨。")
        let frame = try JSONSerialization.data(withJSONObject: ["error": "boom", "message": Self.bodySplittingKey])
        fake.push(String(decoding: frame, as: UTF8.self))
        var err: VoiceSynthError?
        do { for try await _ in stream.chunks {} } catch { err = error as? VoiceSynthError }
        assertNoKeyLeak(err)
    }

    // MARK: - 单次请求上限（sol P2-4）：超了直接报清楚的错，不发请求

    func testTextLimitsGuarded() async {
        let synth = eleven()
        let v4Long = String(repeating: "字", count: 2_001)
        var err = await capture { _ = try await synth.synthesize(text: v4Long, voice: "v", model: "eleven_v4", tuning: self.tuning) }
        XCTAssertEqual(err, .textTooLong(2_000))
        err = await capture { _ = try await synth.synthesize(text: v4Long, voice: "v", model: "eleven_v4_turbo", tuning: self.tuning) }
        XCTAssertEqual(err, .textTooLong(2_000))
        err = await capture { _ = try await synth.synthesize(text: String(repeating: "字", count: 3_001), voice: "v", model: "eleven_v3", tuning: self.tuning) }
        XCTAssertEqual(err, .textTooLong(3_000))
        err = await capture { _ = try await self.openAI().synthesize(text: String(repeating: "a", count: 4_097), voice: "v", model: nil, tuning: self.tuning) }
        XCTAssertEqual(err, .textTooLong(4_096))
        var groq = VoiceService.blank(kind: .openAICompatible)
        groq.openAICompatibleOptions.models = ["canopylabs/orpheus-v1-english"]
        err = await capture {
            _ = try await OpenAICompatibleSynthesizer(service: groq, keyProvider: { "k-test" }, session: self.session)
                .synthesize(text: String(repeating: "a", count: 201), voice: "v", model: nil, tuning: self.tuning)
        }
        XCTAssertEqual(err, .textTooLong(200))
        err = await capture { _ = try await self.miniMax().synthesize(text: String(repeating: "字", count: 10_000), voice: "v", model: nil, tuning: self.tuning) }
        XCTAssertEqual(err, .textTooLong(9_999))
        XCTAssertNil(MockProtocol.lastRequest, "超长不发请求")
        XCTAssertTrue(VoiceSynthError.textTooLong(2_000).message.contains("2000"))
    }

    // MARK: - OpenAI 兼容输出格式（sol P2-7）

    func testOpenAIGroqDefaultsToWavAndClipIsWav() async throws {
        let riff = Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)
        MockProtocol.reply = { _ in .init(headers: ["Content-Type": "audio/wav"], body: riff) }
        let clip = try await openAI(base: "https://api.groq.com/openai/v1").synthesize(text: "hi", voice: "troy", model: nil, tuning: tuning)
        XCTAssertEqual(try lastJSON()["response_format"] as? String, "wav")
        XCTAssertEqual(clip.format, .wav)
        XCTAssertEqual(VoiceMessageWriter.fileInfo(for: clip).ext, "wav")
        XCTAssertEqual(VoiceMessageWriter.fileInfo(for: clip).mime, "audio/wav")
    }

    func testOpenAIExplicitFormatWins() async throws {
        MockProtocol.reply = { _ in .init(body: Data([0x49, 0x44, 0x33, 4])) }
        var s = VoiceService.blank(kind: .openAICompatible)
        s.baseURL = "https://api.groq.com/openai/v1"
        s.openAICompatibleOptions.responseFormat = "mp3"
        let clip = try await OpenAICompatibleSynthesizer(service: s, keyProvider: { "k-test" }, session: session)
            .synthesize(text: "hi", voice: "v", model: nil, tuning: tuning)
        XCTAssertEqual(try lastJSON()["response_format"] as? String, "mp3")
        XCTAssertEqual(clip.format, .mp3)

        XCTAssertEqual(OpenAICompatibleOptions().effectiveFormat(baseURL: nil), "mp3")
        XCTAssertEqual(OpenAICompatibleOptions(responseFormat: "wav").effectiveFormat(baseURL: nil), "wav")
        XCTAssertEqual(OpenAICompatibleOptions(responseFormat: "ogg").effectiveFormat(baseURL: nil), "mp3", "不认识的回落")
    }

    func testSniffFormatByHeader() {
        XCTAssertEqual(OpenAICompatibleSynthesizer.sniffFormat(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8), requested: "mp3"), .wav)
        XCTAssertEqual(OpenAICompatibleSynthesizer.sniffFormat(Data([0xFF, 0xFB, 0x90]), requested: "wav"), .mp3)
        XCTAssertEqual(OpenAICompatibleSynthesizer.sniffFormat(Data([0x49, 0x44, 0x33]), requested: "wav"), .mp3)
        XCTAssertEqual(OpenAICompatibleSynthesizer.sniffFormat(Data([1, 2]), requested: "wav"), .wav)
    }

    func testOpenAIOptionsDecodeWithoutFormat() throws {
        let old = #"{"models":["tts-1"]}"#
        let opts = try JSONDecoder().decode(OpenAICompatibleOptions.self, from: Data(old.utf8))
        XCTAssertEqual(opts, OpenAICompatibleOptions(models: ["tts-1"]))
        XCTAssertNil(opts.responseFormat)
    }

    // MARK: - 系统音

    func testSystemCapabilities() {
        let caps = SystemSynthesizer().capabilities
        XCTAssertFalse(caps.supportsTags)
        XCTAssertFalse(caps.supportsStreaming)
        XCTAssertTrue(caps.canFetchVoices)
        XCTAssertTrue(caps.models.isEmpty)
        XCTAssertTrue(caps.tunables.isEmpty, "系统音语速跟朗读页，不吃声音效果参数")
        XCTAssertNil(SystemSynthesizer().openStream(voice: nil, model: nil))
    }
}
