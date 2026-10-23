import XCTest
@testable import 记忆花园

/// 发语音条 M2：请求构造逐字段断言 + 状态码→错误映射。
final class ElevenLabsClientTests: XCTestCase {

    final class MockURLProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (Int, Data))?
        static var lastRequest: URLRequest?
        static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            // httpBody 在 URLProtocol 里被转成 stream，从 stream 读回
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                buf.deallocate()
                stream.close()
                Self.lastBody = data
            } else {
                Self.lastBody = request.httpBody
            }
            let (status, data) = Self.handler?(request) ?? (200, Data())
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> ElevenLabsClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ElevenLabsClient(session: URLSession(configuration: config))
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        super.tearDown()
    }

    func testSynthesizeRequestShape() async throws {
        MockURLProtocol.handler = { _ in (200, Data([0xFF, 0xFB])) }
        let client = makeClient()
        let settings = VoiceTuning.Settings(stability: 0.0, similarityBoost: 0.75, style: 0.88, speed: 1.1)
        let audio = try await client.synthesize(script: "[whispers] 嗨。", voiceId: "v123", apiKey: "k-abc", settings: settings)

        XCTAssertEqual(audio, Data([0xFF, 0xFB]))
        let req = MockURLProtocol.lastRequest!
        XCTAssertEqual(req.url?.path, "/v1/text-to-speech/v123")
        XCTAssertEqual(req.url?.query, "output_format=mp3_44100_128")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "k-abc")

        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.lastBody!) as! [String: Any]
        XCTAssertEqual(body["text"] as? String, "[whispers] 嗨。")
        XCTAssertEqual(body["model_id"] as? String, "eleven_v3")
        let vs = body["voice_settings"] as! [String: Any]
        XCTAssertEqual(vs["stability"] as? Double, 0.0)
        XCTAssertEqual(vs["style"] as? Double, 0.88)
        XCTAssertEqual(vs["speed"] as? Double, 1.1)
        XCTAssertEqual(vs["similarity_boost"] as? Double, 0.75)
    }

    func testFetchVoicesParsing() async throws {
        let json = """
        {"voices":[{"voice_id":"a1","name":"暖暖","preview_url":"https://x.example/p.mp3"},
                   {"voice_id":"b2","name":"Rachel","preview_url":null}]}
        """
        MockURLProtocol.handler = { _ in (200, Data(json.utf8)) }
        let voices = try await makeClient().fetchVoices(apiKey: "k")
        XCTAssertEqual(voices.count, 2)
        XCTAssertEqual(voices[0].voiceId, "a1")
        XCTAssertEqual(voices[0].name, "暖暖")
        XCTAssertNotNil(voices[0].previewURL)
        XCTAssertNil(voices[1].previewURL)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/voices")
    }

    func testStatusCodeErrorMapping() async {
        for (status, expected) in [(401, "key 无效"), (429, "额度不够或请求太频繁"), (500, "服务端出错 500")] {
            MockURLProtocol.handler = { _ in (status, Data()) }
            do {
                _ = try await makeClient().synthesize(script: "s", voiceId: "v", apiKey: "k",
                                                      settings: VoiceTuning.current())
                XCTFail("状态码 \(status) 应抛错")
            } catch let err as ElevenLabsError {
                XCTAssertEqual(err.shortPhrase, expected)
            } catch {
                XCTFail("错误类型不对：\(error)")
            }
        }
    }

    func testVoiceTuningDefaultsAndOverride() {
        let d = UserDefaults(suiteName: "xctest-voice-tuning")!
        d.removePersistentDomain(forName: "xctest-voice-tuning")
        XCTAssertEqual(VoiceTuning.current(defaults: d),
                       VoiceTuning.Settings(stability: 0.0, similarityBoost: 0.75, style: 0.88, speed: 1.1))
        d.set(0.5, forKey: VoiceTuning.stabilityKey)
        d.set(0.3, forKey: VoiceTuning.styleKey)
        XCTAssertEqual(VoiceTuning.current(defaults: d).stability, 0.5)
        XCTAssertEqual(VoiceTuning.current(defaults: d).style, 0.3)
        XCTAssertEqual(VoiceTuning.current(defaults: d).speed, 1.1, "没动的键保持默认")
        VoiceTuning.resetToDefaults(defaults: d)
        XCTAssertEqual(VoiceTuning.current(defaults: d).stability, 0.0)
        d.removePersistentDomain(forName: "xctest-voice-tuning")
    }
}
