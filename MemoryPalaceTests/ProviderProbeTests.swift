import XCTest
@testable import 记忆花园

/// #092 B/C：草稿探测只认 2xx、测试模型取卡清单第一个、空清单先拉 /models。全部走 URLProtocol 桩，不出网。
final class ProviderProbeTests: XCTestCase {
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
        nonisolated(unsafe) static var seen: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var req = request
            if req.httpBody == nil, let stream = req.httpBodyStream {
                stream.open()
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                stream.close()
                req.httpBody = data
            }
            Stub.seen.append(req)
            let url = request.url!
            let (code, body) = Stub.routes[url.absoluteString] ?? (404, "<html>not found</html>")
            let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var session: URLSession!
    private let key = "sk-test-000"

    override func setUp() {
        super.setUp()
        Stub.routes = [:]
        Stub.seen = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        session = URLSession(configuration: config)
    }

    private func card(_ base: String, _ type: ProviderType = .openaiCompatible, models: [String] = []) -> APICredential {
        APICredential(id: "draft", name: "t", emoji: "🧪", type: type, baseURL: base,
                      models: models.map { ProviderModel(credentialId: "draft", modelId: $0, name: $0) })
    }

    private func sentModel(_ r: URLRequest) -> String? {
        guard let body = r.httpBody, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj["model"] as? String
    }

    func test2xxIsSuccessAndUsesFirstModelAndNormalizedURL() async {
        Stub.routes["https://relay.test/v1/chat/completions"] = (200, "{}")
        let r = await ProviderProbe.test(draft: card("https://relay.test/", models: ["text-embedding-3", "m-a", "m-b"]),
                                         key: key, session: session)
        guard case .success(let ok) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(ok.model, "m-a")
        XCTAssertEqual(sentModel(Stub.seen[0]), "m-a")
        XCTAssertEqual(Stub.seen[0].value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-000")
    }

    func testNon2xxAreFailuresWithStatusAndReason() async {
        for (code, body) in [(400, #"{"error":{"message":"model not found"}}"#), (404, "<html>nope</html>"),
                             (429, #"{"error":{"message":"rate limited"}}"#), (500, "upstream down"), (401, "{}")] {
            Stub.routes["https://relay.test/v1/chat/completions"] = (code, body)
            let r = await ProviderProbe.test(draft: card("https://relay.test/v1", models: ["m-a"]), key: key, session: session)
            guard case .failure(let err as ProviderProbe.Failure) = r else { return XCTFail("\(code) should fail: \(r)") }
            XCTAssertEqual(err.status, code)
            XCTAssertEqual(err.url, "https://relay.test/v1/chat/completions")
            XCTAssertTrue(err.message.contains("\(code)"), err.message)
        }
    }

    func testFailureMessagesCarryUpstreamReason() {
        let body = Data(#"{"error":{"message":"model m-x does not exist"}}"#.utf8)
        XCTAssertEqual(ProviderProbe.describe(status: 400, body: body, model: "m-x"),
                       "模型 m-x 在这家不可用（400）：model m-x does not exist")
        XCTAssertTrue(ProviderProbe.describe(status: 404, body: Data("<html/>".utf8), model: nil).hasPrefix("地址不对（404）"))
        XCTAssertEqual(ProviderProbe.describe(status: 502, body: Data("Bad Gateway".utf8), model: nil),
                       "服务端暂时不可用（502）：Bad Gateway")
    }

    func testEmptyModelListFetchesModelsFirst() async {
        Stub.routes["https://relay.test/v1/models"] = (200, #"{"data":[{"id":"zz-chat"},{"id":"aa-chat"},{"id":"text-embedding-x"}]}"#)
        Stub.routes["https://relay.test/v1/chat/completions"] = (200, "{}")
        let r = await ProviderProbe.test(draft: card("relay.test"), key: key, session: session)
        guard case .success(let ok) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(ok.fetchedModels.map(\.modelId), ["aa-chat", "zz-chat"])
        XCTAssertEqual(ok.model, "aa-chat")
        XCTAssertEqual(Stub.seen.map { $0.url!.path }, ["/v1/models", "/v1/chat/completions"])
    }

    func testEmptyListAndModelsFailIsFailure() async {
        Stub.routes["https://relay.test/v1/models"] = (401, #"{"error":{"message":"bad key"}}"#)
        let r = await ProviderProbe.test(draft: card("https://relay.test/v1"), key: key, session: session)
        guard case .failure(let err as ProviderProbe.Failure) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(err.status, 401)
        XCTAssertTrue(err.message.contains("手填"), err.message)
    }

    func testAnthropicUsesCardModelAndHeaders() async {
        Stub.routes["https://relay.test/v1/messages"] = (200, "{}")
        let r = await ProviderProbe.test(draft: card("https://relay.test", .anthropic, models: ["kimi-k3"]), key: key, session: session)
        guard case .success = r else { return XCTFail("\(r)") }
        XCTAssertEqual(sentModel(Stub.seen[0]), "kimi-k3")
        XCTAssertEqual(Stub.seen[0].value(forHTTPHeaderField: "x-api-key"), "sk-test-000")
        XCTAssertEqual(Stub.seen[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testFetchModelsFailureKeepsBody() async {
        Stub.routes["https://relay.test/v1/models"] = (403, #"{"error":{"message":"region blocked"}}"#)
        let r = await ProviderProbe.fetchModels(draft: card("https://relay.test/v1"), key: key, session: session)
        guard case .failure(let err as ProviderProbe.Failure) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(err.message.contains("region blocked"), err.message)
    }

    func testMissingKeyFailsWithoutRequest() async {
        let r = await ProviderProbe.test(draft: card("https://relay.test/v1", models: ["m"]), key: "  ", session: session)
        guard case .failure = r else { return XCTFail("\(r)") }
        XCTAssertTrue(Stub.seen.isEmpty)
    }

    func testTestModelPicking() {
        let ms = ["bge-m3", "chat-1"].map { ProviderModel(credentialId: "d", modelId: $0, name: $0) }
        XCTAssertEqual(ProviderProbe.testModel(preferred: "p", lastUsed: "chat-1", models: ms), "p")
        XCTAssertEqual(ProviderProbe.testModel(preferred: nil, lastUsed: "chat-1", models: ms), "chat-1")
        XCTAssertEqual(ProviderProbe.testModel(preferred: nil, lastUsed: "gone", models: ms), "chat-1")
        XCTAssertNil(ProviderProbe.testModel(preferred: nil, lastUsed: nil, models: []))
    }
}
