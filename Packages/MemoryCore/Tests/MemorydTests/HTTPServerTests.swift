import XCTest
@testable import memoryd

final class HTTPServerTests: XCTestCase {
    private var floor: URL!
    private var server: HTTPServer!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
        let service = try MemorydFixture.service(floor, profileId: "memoryd-server-test")
        server = try HTTPServer(port: 0, service: service)
    }

    override func tearDownWithError() throws {
        server?.stop()
        if let floor { MemorydFixture.remove(floor) }
    }

    private func url(_ path: String, port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func testRealHTTPRoundTrip() async throws {
        let port = try server.start()
        XCTAssertNotEqual(port, 0)

        let (data, response) = try await URLSession.shared.data(from: url("/api/bench/sets", port: port))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((body["sets"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == "wiki-probe" })

        var request = URLRequest(url: url("/api/bench/run", port: port))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"setId":"wiki-probe"}"#.utf8)
        let (runData, runResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((runResponse as? HTTPURLResponse)?.statusCode, 200)
        let run = try XCTUnwrap(try JSONSerialization.jsonObject(with: runData) as? [String: Any])
        XCTAssertNotNil(run["runId"] as? String)
        XCTAssertEqual(run["measurable"] as? Int, 4)

        let (missingData, missingResponse) = try await URLSession.shared.data(from: url("/nope", port: port))
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)
        let missing = try XCTUnwrap(try JSONSerialization.jsonObject(with: missingData) as? [String: Any])
        XCTAssertNotNil(missing["error"] as? String)
    }

    func testServesPWA() async throws {
        let port = try server.start()
        let (html, response) = try await URLSession.shared.data(from: url("/", port: port))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("测试台"))
        let (js, jsResponse) = try await URLSession.shared.data(from: url("/app.js", port: port))
        XCTAssertEqual((jsResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: js, as: UTF8.self).contains("/api/bench/sets"))
    }

    /// N1：期限只管读请求。respond 比期限慢很多，照样收到 200（跑批可能跑几十秒）
    func testSlowResponseIsNotCutByReadTimeout() async throws {
        let slow = try HTTPServer(port: 0, service: SlowResponder(delay: 1), readTimeout: 0.25)
        defer { slow.stop() }
        let port = try slow.start()
        let (data, response) = try await URLSession.shared.data(from: url("/api/bench/sets", port: port))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["slow"] as? Bool, true)
    }
}

/// 回响应比读期限慢的假服务（N1 的注入点）
private actor SlowResponder: HTTPResponder {
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    nonisolated func bind(port: UInt16) {}

    func respond(_ request: HTTPRequest) async -> HTTPResponse {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return .json(["slow": true])
    }
}
