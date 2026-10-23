import XCTest
@testable import 记忆花园

/// 竞速探测的 URL 转换：ws 候选 → http /health（无鉴权 probe 端点）。
final class CCBridgeHealthURLTests: XCTestCase {

    func testWSWithTokenStripsQueryAndSwapsPath() {
        let ws = URL(string: "ws://192.168.31.20:7890/cc?token=abc123")!
        let health = CCBridgeWebSocketClient.healthURL(for: ws)
        XCTAssertEqual(health?.absoluteString, "http://192.168.31.20:7890/health")
    }

    func testWSSBecomesHTTPS() {
        let wss = URL(string: "wss://mimiair.example.ts.net:7890/cc?token=t")!
        let health = CCBridgeWebSocketClient.healthURL(for: wss)
        XCTAssertEqual(health?.absoluteString, "https://mimiair.example.ts.net:7890/health")
    }

    func testNoTokenNoPort() {
        let ws = URL(string: "ws://100.110.76.9:7890/cc")!
        let health = CCBridgeWebSocketClient.healthURL(for: ws)
        XCTAssertEqual(health?.absoluteString, "http://100.110.76.9:7890/health")
    }

    // MARK: - 探测认 hub 本尊（plan-hub-instant-connect）

    private func response(_ status: Int, hubHeader: Bool) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://100.110.76.9:7890/health")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: hubHeader ? ["X-MP-Hub": "1"] : [:])!
    }

    func testHubHeaderCountsWhateverStatus() {
        XCTAssertTrue(CCBridgeWebSocketClient.isHubProbeResponse(response(403, hubHeader: true)))
        XCTAssertTrue(CCBridgeWebSocketClient.isHubProbeResponse(response(200, hubHeader: true)))
    }

    func testOldHubWithoutHeaderStillCounts() {
        for status in [200, 401, 403] {
            XCTAssertTrue(CCBridgeWebSocketClient.isHubProbeResponse(response(status, hubHeader: false)), "\(status)")
        }
    }

    func testProxyStandInIsNotHub() {
        for status in [502, 503, 504, 404, 407] {
            XCTAssertFalse(CCBridgeWebSocketClient.isHubProbeResponse(response(status, hubHeader: false)), "\(status)")
        }
    }

    // MARK: - since 游标

    func testSinceAppendedWithMarginKeepingToken() {
        let ws = URL(string: "ws://192.168.31.20:7890/cc?token=t&bundle=b")!
        let out = CCBridgeWebSocketClient.urlWithReplySince(ws, cursor: 1_000_000, marginMs: 120_000)
        let items = URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "since" }?.value, "880000")
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "t")
        XCTAssertEqual(items.first { $0.name == "bundle" }?.value, "b")
    }

    func testNoCursorNoSince() {
        let ws = URL(string: "ws://192.168.31.20:7890/cc?token=t")!
        XCTAssertEqual(CCBridgeWebSocketClient.urlWithReplySince(ws, cursor: 0, marginMs: 120_000), ws)
    }

    func testSinceReplacedNotDuplicated() {
        let ws = URL(string: "ws://h:7890/cc?since=5")!
        let out = CCBridgeWebSocketClient.urlWithReplySince(ws, cursor: 1_000_000, marginMs: 0)
        let since = URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "since" }
        XCTAssertEqual(since?.map(\.value), ["1000000"])
    }
}
