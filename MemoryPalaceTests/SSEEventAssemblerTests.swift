import XCTest
@testable import 记忆花园

/// 铲屎二期 A-32：MCP SSE / MCP HTTP / MiniMax 三份手写解析收成 SSELineDecoder + 事件聚合器（顺手修 L-B13）
final class SSEEventAssemblerTests: XCTestCase {

    private func events(_ text: String) throws -> [SSEEventAssembler.Event] {
        try SSEEventAssembler.events(in: Data(text.utf8))
    }

    func testLoneCRLineEndings() throws {
        XCTAssertEqual(try events("event: endpoint\rdata: /msg\r\rdata: {}\r\r"), [
            .init(name: "endpoint", data: "/msg"),
            .init(name: "", data: "{}"),
        ], "孤立 \\r 当行尾，事件不粘连、事件名不串到下一个")
    }

    func testLastEventWithoutTrailingBlankLine() throws {
        XCTAssertEqual(try events("data: a\n\ndata: b"), [.init(name: "", data: "a"), .init(name: "", data: "b")])
        XCTAssertEqual(try events("data: a\r\ndata: b\r\n"), [.init(name: "", data: "a\nb")], "结尾没空行也吐，多行 data 用 \\n 拼")
    }

    func testDataLeadingSpaceRule() throws {
        XCTAssertEqual(try events("data:x\n\ndata:  y \n\n").map(\.data), ["x", " y "], "冒号后只去一个空格，不两端 trim")
    }

    func testEventsWithoutDataAreDropped() throws {
        XCTAssertEqual(try events("event: ping\r\n\r\n: keep-alive\n\nid: 1\n\n"), [])
    }

    func testStreamingFeedMatchesWholeBody() throws {
        let body = "event: endpoint\r\ndata: /m\r\n\r\ndata: {\"a\":1}\r\n\r\ndata: tail"
        var decoder = SSELineDecoder()
        var assembler = SSEEventAssembler()
        var got: [SSEEventAssembler.Event] = []
        for byte in Data(body.utf8) { got += assembler.add(try decoder.feed(Data([byte]))) }
        got += assembler.add(decoder.finish()) + assembler.finish()
        XCTAssertEqual(got, try events(body))
        XCTAssertEqual(got.count, 3)
    }

    func testMCPHTTPPayloadDropsNonJSON() {
        let parsed = MCPStreamableHTTPTransport.parseSSEPayload("data: {\"id\":1}\rdata: nope\r\rdata: {\"id\":2}")
        XCTAssertEqual(parsed.compactMap { ($0 as? [String: Any])?["id"] as? Int }, [2],
                       "同一事件里 JSON + 非 JSON 拼起来整体不是 JSON → 丢；结尾没空行的照样解析")
    }

    func testMiniMaxEventsLoneCR() {
        XCTAssertEqual(MiniMaxSynthesizer.events(in: Data("data: {\"a\":1}\r\rdata: [DONE]".utf8)), [#"{"a":1}"#, "[DONE]"])
    }
}
