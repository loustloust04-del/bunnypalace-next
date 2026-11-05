import XCTest
@testable import 记忆花园

/// 缓存保留时长（粟粟 10-15：默认 1 小时，预设能改回 5 分钟；中转不认 1 小时自动退回 5 分钟）
final class CacheTTLTests: XCTestCase {

    private let relay = "https://relay-ttl-test.invalid"
    private let key = "anthropicCacheLongTTLHostBlacklist"
    private var saved: Any?

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func marks(_ sampling: SamplingParams) -> [[String: Any]] {
        let body = AnthropicProvider.buildRequestBody(
            messages: [("user", "你好"), ("assistant", "在呢"), ("user", "今天好累")],
            model: "claude-sonnet-4-5", systemPrompt: "你是小岚", samplingParams: sampling)
        var out: [[String: Any]] = []
        if let system = body["system"] as? [[String: Any]] { out += system.compactMap { $0["cache_control"] as? [String: Any] } }
        for msg in body["messages"] as? [[String: Any]] ?? [] {
            out += (msg["content"] as? [[String: Any]] ?? []).compactMap { $0["cache_control"] as? [String: Any] }
        }
        return out
    }

    private func cacheFriendly(longTTL: Bool?) -> SamplingParams {
        var p = SamplingParams()
        p.cacheFriendly = true
        p.cacheLongTTL = longTTL
        return p
    }

    func testDefaultIsOneHour() {
        let m = marks(cacheFriendly(longTTL: nil))
        XCTAssertEqual(m.count, 2, "system + 最后一条 assistant")
        XCTAssertTrue(m.allSatisfy { $0["ttl"] as? String == "1h" && $0["type"] as? String == "ephemeral" })
    }

    func testFiveMinutesWhenChosen() {
        let m = marks(cacheFriendly(longTTL: false))
        XCTAssertEqual(m.count, 2)
        XCTAssertTrue(m.allSatisfy { $0["ttl"] == nil })
    }

    func testRelayThatRejectsTTLFallsBackToFiveMinutes() {
        XCTAssertEqual(AnthropicProvider.samplingForHost(cacheFriendly(longTTL: nil), baseURL: relay)?.cacheLongTTL, nil)
        AnthropicProvider.addToLongTTLBlacklist(relay)
        let p = AnthropicProvider.samplingForHost(cacheFriendly(longTTL: nil), baseURL: relay)
        XCTAssertEqual(p?.cacheLongTTL, false)
        XCTAssertTrue(marks(p!).allSatisfy { $0["ttl"] == nil })
        XCTAssertEqual(AnthropicProvider.samplingForHost(cacheFriendly(longTTL: nil), baseURL: "https://api.anthropic.com")?.cacheLongTTL, nil,
                       "别的地址不受影响")
    }

    func testRejectionClassifier() {
        let ttlError = #"{"type":"error","error":{"type":"invalid_request_error","message":"cache_control.ttl: Extra inputs are not permitted"}}"#
        XCTAssertEqual(AnthropicProvider.cacheRejection(status: 400, body: ttlError, longTTLSent: true), .longTTL, "提到 ttl：只退回 5 分钟")
        XCTAssertEqual(AnthropicProvider.cacheRejection(status: 400, body: ttlError, longTTLSent: false), .cacheControl)
        XCTAssertEqual(AnthropicProvider.cacheRejection(status: 400, body: "cache_control not supported", longTTLSent: true), .cacheControl)
        XCTAssertNil(AnthropicProvider.cacheRejection(status: 500, body: ttlError, longTTLSent: true))
        XCTAssertNil(AnthropicProvider.cacheRejection(status: 400, body: "max_tokens too large", longTTLSent: true))
        XCTAssertNil(AnthropicProvider.cacheRejection(status: 429, body: #"{"error":{"message":"Request throttled"}}"#, longTTLSent: true), "限流不算")
        XCTAssertNil(AnthropicProvider.cacheRejection(status: 400, body: "ThrottlingException: slow down", longTTLSent: true))
        XCTAssertEqual(AnthropicProvider.cacheRejection(status: 422, body: #"{"detail":[{"loc":["body","system",0,"cache_control","ttl"],"msg":"Extra inputs are not permitted"}]}"#, longTTLSent: true), .longTTL)
    }
}
