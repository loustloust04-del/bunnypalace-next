import XCTest
@testable import 记忆花园

final class BaseURLNormalizerTests: XCTestCase {
    private func n(_ s: String, _ t: ProviderType = .openaiCompatible) -> String {
        BaseURLNormalizer.normalize(s, type: t)
    }

    func testHostOnlyGetsV1() {
        XCTAssertEqual(n("https://relay.example.com"), "https://relay.example.com/v1")
        XCTAssertEqual(n("https://relay.example.com", .anthropic), "https://relay.example.com/v1")
        XCTAssertEqual(n("http://192.168.31.20:8793", .anthropic), "http://192.168.31.20:8793/v1")
    }

    func testTrailingSlashesAndWhitespace() {
        XCTAssertEqual(n("https://relay.example.com/v1/"), "https://relay.example.com/v1")
        XCTAssertEqual(n("https://relay.example.com/v1//"), "https://relay.example.com/v1")
        XCTAssertEqual(n("  https://relay.example.com/v1\n"), "https://relay.example.com/v1")
        XCTAssertEqual(n("https://relay.example.com/\n"), "https://relay.example.com/v1")
    }

    func testMissingSchemeGetsHTTPS() {
        XCTAssertEqual(n("relay.example.com/v1"), "https://relay.example.com/v1")
        XCTAssertEqual(n("relay.example.com"), "https://relay.example.com/v1")
    }

    func testPastedEndpointTailIsStripped() {
        XCTAssertEqual(n("https://relay.example.com/v1/chat/completions"), "https://relay.example.com/v1")
        XCTAssertEqual(n("https://relay.example.com/v1/messages", .anthropic), "https://relay.example.com/v1")
        XCTAssertEqual(n("https://relay.example.com/v1/models/"), "https://relay.example.com/v1")
        XCTAssertEqual(n("https://relay.example.com/chat/completions"), "https://relay.example.com/v1")
        XCTAssertEqual(n("https://relay.example.com/V1/Chat/Completions"), "https://relay.example.com/V1")
    }

    func testNonEmptyPathKeptAsIs() {
        XCTAssertEqual(n("https://relay.example.com/openai"), "https://relay.example.com/openai")
        XCTAssertEqual(n("https://open.bigmodel.cn/api/paas/v4"), "https://open.bigmodel.cn/api/paas/v4")
    }

    func testEveryPresetBaseURLIsAlreadyNormal() {
        for p in APIProvider.presets where p.type == .openaiCompatible || p.type == .anthropic {
            guard !p.baseURL.isEmpty else { continue }
            if p.id == "kimi-p" { continue }   // Debug 自用预设只填了域名，规整后补 /v1（kimi-proxy 只认 /v1/messages）
            XCTAssertEqual(n(p.baseURL, p.type), p.baseURL, p.id)
        }
    }

    func testNonHTTPCardsUntouched() {
        XCTAssertEqual(n("ws://127.0.0.1:7890/cc/", .ccBridge), "ws://127.0.0.1:7890/cc/")
        XCTAssertEqual(n("https://chatgpt.com/backend-api/codex/", .chatgptOAuth), "https://chatgpt.com/backend-api/codex/")
        XCTAssertEqual(n("", .localMLX), "")
        XCTAssertEqual(n("   "), "")
    }

    func testChatEndpoint() {
        XCTAssertEqual(BaseURLNormalizer.chatEndpoint(base: "https://relay.example.com", type: .openaiCompatible),
                       "https://relay.example.com/v1/chat/completions")
        XCTAssertEqual(BaseURLNormalizer.chatEndpoint(base: "https://relay.example.com/v1/", type: .anthropic),
                       "https://relay.example.com/v1/messages")
        XCTAssertNil(BaseURLNormalizer.chatEndpoint(base: "", type: .openaiCompatible))
        XCTAssertNil(BaseURLNormalizer.chatEndpoint(base: "ws://x", type: .ccBridge))
    }
}
