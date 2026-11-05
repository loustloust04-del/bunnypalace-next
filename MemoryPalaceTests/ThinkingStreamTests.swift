import XCTest
@testable import 记忆花园

/// thinking 回传 §3.1：Anthropic 回复的全部内容块原样收（流式按 index、非流式 content[]），完整标记、签名、用量
final class ThinkingStreamTests: XCTestCase {

    static func event(_ type: String, _ obj: [String: Any]) -> String {
        var o = obj
        o["type"] = type
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return "event: \(type)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    static func start(_ i: Int, _ block: [String: Any]) -> String { event("content_block_start", ["index": i, "content_block": block]) }
    static func delta(_ i: Int, _ delta: [String: Any]) -> String { event("content_block_delta", ["index": i, "delta": delta]) }
    static func stop(_ i: Int) -> String { event("content_block_stop", ["index": i]) }

    /// summarized：思考（两段摘要 + 签名）→ 正文 → 进度更新思考 → tool_use（input 分片）
    static let toolTurnSSE: String = [
        event("message_start", ["message": ["usage": ["input_tokens": 10, "output_tokens": 0]]]),
        start(0, ["type": "thinking", "thinking": "", "signature": ""]),
        delta(0, ["type": "thinking_delta", "thinking": "先想"]),
        delta(0, ["type": "thinking_delta", "thinking": "一下"]),
        delta(0, ["type": "signature_delta", "signature": "sig-0"]),
        stop(0),
        start(1, ["type": "text", "text": ""]),
        delta(1, ["type": "text_delta", "text": "我查"]),
        delta(1, ["type": "text_delta", "text": "一下"]),
        stop(1),
        start(2, ["type": "thinking", "thinking": "", "signature": ""]),
        delta(2, ["type": "signature_delta", "signature": "sig-progress"]),
        stop(2),
        start(3, ["type": "tool_use", "id": "toolu_1", "name": "fs_read", "input": [String: Any]()]),
        delta(3, ["type": "input_json_delta", "partial_json": "{\"path\":"]),
        delta(3, ["type": "input_json_delta", "partial_json": "\"a.md\"}"]),
        stop(3),
        event("message_delta", ["delta": ["stop_reason": "tool_use"],
                                "usage": ["output_tokens": 300, "output_tokens_details": ["thinking_tokens": 220]]]),
        event("message_stop", [:]),
    ].joined()

    private func feed(_ sse: String) -> AnthropicProvider {
        let p = AnthropicProvider()
        p.processData(Data(sse.utf8))
        return p
    }

    func testStreamKeepsEveryBlockVerbatimInOrder() throws {
        let p = feed(Self.toolTurnSSE)
        let blocks = p.replyBlocks
        XCTAssertEqual(blocks.map(\.type), ["thinking", "text", "thinking", "tool_use"])
        XCTAssertTrue(blocks.allSatisfy(\.complete))
        XCTAssertEqual(blocks[0].raw["thinking"] as? String, "先想一下")
        XCTAssertEqual(blocks[0].raw["signature"] as? String, "sig-0")
        XCTAssertEqual(blocks[1].raw["text"] as? String, "我查一下")
        XCTAssertEqual(blocks[2].raw["thinking"] as? String, "", "omitted / 进度更新：文字为空、只有签名")
        XCTAssertEqual((blocks[3].raw["input"] as? [String: Any])?["path"] as? String, "a.md", "input 分片拼完解析回块里")
        let wire = try XCTUnwrap(blocks.wireContent)
        XCTAssertEqual(wire.count, 4)
        XCTAssertEqual(p.accumulatedReasoningTokens, 220, "thinking_tokens 在最后一个 message_delta 里")
        XCTAssertEqual(p.finalUsage?.reasoningTokens, 220)
    }

    func testThinkingSegmentsFromBlocks() {
        let segs = feed(Self.toolTurnSSE).replyBlocks.thinkingSegments
        XCTAssertEqual(segs, [.thinking(text: "先想一下", signature: "sig-0"), .thinking(text: "", signature: "sig-progress")])
    }

    func testRedactedBlockKeptAndStoredAsRedactedData() throws {
        let sse = [
            Self.start(0, ["type": "redacted_thinking", "data": "ENCRYPTED"]),
            Self.stop(0),
            Self.start(1, ["type": "text", "text": ""]),
            Self.delta(1, ["type": "text_delta", "text": "好"]),
            Self.stop(1),
        ].joined()
        let blocks = feed(sse).replyBlocks
        XCTAssertEqual(blocks.map(\.type), ["redacted_thinking", "text"])
        XCTAssertEqual(try XCTUnwrap(blocks.wireContent).first?["data"] as? String, "ENCRYPTED", "redacted 原样回传")
        XCTAssertEqual(blocks.thinkingSegments, [.thinking(text: "", signature: nil, redactedData: "ENCRYPTED")])
    }

    /// 中途断流 / 停止：没收到签名的思考块不完整——只存文字、签名 nil，绝不回传；空的不完整思考不存
    func testInterruptedThinkingIsIncompleteAndNeverEchoed() {
        let sse = [
            Self.start(0, ["type": "thinking", "thinking": "", "signature": ""]),
            Self.delta(0, ["type": "thinking_delta", "thinking": "想到一半"]),
            Self.start(1, ["type": "thinking", "thinking": "", "signature": ""]),
        ].joined()
        let blocks = feed(sse).replyBlocks
        XCTAssertEqual(blocks.map(\.complete), [false, false])
        XCTAssertNil(blocks.wireContent)
        XCTAssertEqual(blocks.thinkingSegments, [.thinking(text: "想到一半", signature: nil)])
    }

    /// 停在 max_tokens：最后一块是进度更新思考（R15），有签名就照常完整
    func testMaxTokensStopOnProgressThinking() {
        let sse = [
            Self.start(0, ["type": "text", "text": "说了一半"]),
            Self.stop(0),
            Self.start(1, ["type": "thinking", "thinking": "This part of the response was interrupted before it finished.", "signature": ""]),
            Self.delta(1, ["type": "signature_delta", "signature": "sig-x"]),
            Self.stop(1),
            Self.event("message_delta", ["delta": ["stop_reason": "max_tokens"], "usage": ["output_tokens": 5]]),
        ].joined()
        let p = feed(sse)
        XCTAssertTrue(p.hitOutputLimit)
        XCTAssertEqual(p.replyBlocks.map(\.complete), [true, true])
        XCTAssertEqual(p.replyBlocks.wireContent?.last?["signature"] as? String, "sig-x")
    }

    func testTextCitationsDeltaAppendsToBlock() {
        let sse = [
            Self.start(0, ["type": "text", "text": "", "citations": [Any]()]),
            Self.delta(0, ["type": "citations_delta", "citation": ["type": "web_search_result_location", "url": "https://a"]]),
            Self.delta(0, ["type": "text_delta", "text": "引用"]),
            Self.stop(0),
        ].joined()
        let block = feed(sse).replyBlocks[0]
        XCTAssertEqual((block.raw["citations"] as? [[String: Any]])?.first?["url"] as? String, "https://a")
        XCTAssertEqual(block.raw["text"] as? String, "引用")
    }

    func testRefusalCategoryCaptured() {
        let p = feed(Self.event("message_delta", ["delta": ["stop_reason": "refusal", "stop_details": ["category": "reasoning_extraction"]]]))
        XCTAssertEqual(p.refusalCategory, "reasoning_extraction")
    }

    // MARK: - 非流式同一份

    func testNonStreamKeepsBlocksAndUsage() throws {
        let body = Data(#"""
        {"stop_reason":"tool_use","usage":{"input_tokens":3,"output_tokens":9,"output_tokens_details":{"thinking_tokens":7}},
         "content":[{"type":"thinking","thinking":"想","signature":"s1"},{"type":"redacted_thinking","data":"R"},
                    {"type":"thinking","thinking":"没签名","signature":""},
                    {"type":"text","text":"正文"},{"type":"tool_use","id":"t1","name":"fs_read","input":{"path":"a"}}]}
        """#.utf8)
        let p = AnthropicProvider()
        let result = try p.parseNonStreamBody(body)
        XCTAssertEqual(result.text, "正文")
        XCTAssertEqual(result.toolCalls.map(\.id), ["t1"])
        XCTAssertEqual(result.usage?.reasoningTokens, 7)
        XCTAssertEqual(p.replyBlocks.map(\.type), ["thinking", "redacted_thinking", "thinking", "text", "tool_use"])
        XCTAssertEqual(p.replyBlocks.map(\.complete), [true, true, false, true, true])
        XCTAssertEqual(p.replyBlocks.wireContent?.count, 4, "没签名的思考块不回传")
    }

    func testUsageParserReadsThinkingTokens() {
        let u = APIUsageParser.anthropic(["input_tokens": 1, "output_tokens": 50, "output_tokens_details": ["thinking_tokens": 40]])
        XCTAssertEqual(u?.reasoningTokens, 40)
        XCTAssertNil(APIUsageParser.anthropic(["input_tokens": 1, "output_tokens": 2])?.reasoningTokens)
    }
}
