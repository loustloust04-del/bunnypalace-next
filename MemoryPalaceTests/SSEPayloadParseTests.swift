import XCTest
@testable import 记忆花园

/// StreamableHTTP 的 SSE 响应解析特征测试。
/// 背景：CRLF 在 Swift String 里是单个 grapheme cluster，split("\n") 切不开 "\r\n"——
/// FastMCP（kiwi-mem 等）按 HTTP 规范回 \r\n 行尾，曾导致整个 body 粘成一行 → 0 events → initialize 超时。
final class SSEPayloadParseTests: XCTestCase {

    func testCRLFLineEndings() {
        let body = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\r\n\r\n"
        let events = MCPStreamableHTTPTransport.parseSSEPayload(body)
        XCTAssertEqual(events.count, 1, "CRLF 行尾必须能切开（FastMCP/kiwi 实锤）")
        XCTAssertEqual((events.first as? [String: Any])?["id"] as? Int, 1)
    }

    func testLFLineEndings() {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n\n"
        let events = MCPStreamableHTTPTransport.parseSSEPayload(body)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual((events.first as? [String: Any])?["id"] as? Int, 2)
    }

    func testMultipleEvents() {
        let body = "data: {\"id\":1}\r\n\r\ndata: {\"id\":2}\r\n\r\n"
        XCTAssertEqual(MCPStreamableHTTPTransport.parseSSEPayload(body).count, 2, "空行分隔的多 event 各自解析")
    }

    func testMultilineDataJoined() {
        // SSE 规范：连续 data: 行用 \n 拼接为一个 payload
        let body = "data: {\"a\":\r\ndata: 1}\r\n\r\n"
        let events = MCPStreamableHTTPTransport.parseSSEPayload(body)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual((events.first as? [String: Any])?["a"] as? Int, 1)
    }

    func testNonJSONAndEmptyIgnored() {
        XCTAssertTrue(MCPStreamableHTTPTransport.parseSSEPayload("").isEmpty)
        XCTAssertTrue(MCPStreamableHTTPTransport.parseSSEPayload("event: ping\r\n\r\n").isEmpty, "无 data 行的 event 忽略")
        XCTAssertTrue(MCPStreamableHTTPTransport.parseSSEPayload("data: not-json\r\n\r\n").isEmpty, "非 JSON payload 丢弃不崩")
    }
}
