import XCTest
@testable import 记忆花园

/// 模型兼容 P0 阶段 1：SSE 解码器（行尾三种、多字节跨分片、data: 无空格）
final class SSELineDecoderTests: XCTestCase {

    private func decode(_ chunks: [String]) throws -> [SSELineDecoder.Field] {
        var d = SSELineDecoder()
        var out: [SSELineDecoder.Field] = []
        for c in chunks { out += try d.feed(Data(c.utf8)) }
        return out + d.finish()
    }

    func testLineEndingsLFCRLFAndLoneCR() throws {
        let expected: [SSELineDecoder.Field] = [.data("a"), .data("b"), .data("c")]
        XCTAssertEqual(try decode(["data: a\ndata: b\ndata: c\n"]), expected)
        XCTAssertEqual(try decode(["data: a\r\ndata: b\r\ndata: c\r\n"]), expected)
        XCTAssertEqual(try decode(["data: a\rdata: b\rdata: c\r"]), expected)
        XCTAssertEqual(try decode(["data: a\r\ndata: b\rdata: c\n"]), expected)
    }

    func testCRAtChunkEndWaitsForNextChunk() throws {
        var d = SSELineDecoder()
        XCTAssertEqual(try d.feed(Data("data: a\r".utf8)), [], "\\r 在末尾先不判")
        XCTAssertEqual(try d.feed(Data("\ndata: b\n".utf8)), [.data("a"), .data("b")], "\\r\\n 跨片只算一个行尾")
        XCTAssertEqual(try d.feed(Data("data: c\r".utf8)), [])
        XCTAssertEqual(try d.feed(Data("data: d\n".utf8)), [.data("c"), .data("d")], "单独 \\r 后面跟的不是 \\n 也能切")
        XCTAssertEqual(d.finish(), [])
    }

    func testEmptyLineAndComment() throws {
        XCTAssertEqual(try decode([": keep-alive\n\ndata: x\n\n"]), [.comment, .other, .data("x"), .other])
    }

    func testFieldValueSpaceRules() {
        XCTAssertEqual(SSELineDecoder.parse(line: "data:x"), .data("x"))
        XCTAssertEqual(SSELineDecoder.parse(line: "data: x"), .data("x"))
        XCTAssertEqual(SSELineDecoder.parse(line: "data:  x"), .data(" x"), "冒号后最多去一个空格")
        XCTAssertEqual(SSELineDecoder.parse(line: "event:message_stop"), .event("message_stop"))
        XCTAssertEqual(SSELineDecoder.parse(line: "data"), .data(""), "没冒号 = 整行是字段名、值为空")
        XCTAssertEqual(SSELineDecoder.parse(line: "id: 3"), .other)
        XCTAssertEqual(SSELineDecoder.parse(line: ":"), .comment)
        XCTAssertEqual(SSELineDecoder.parse(line: "data: {\"a\":\"b:c\"}"), .data("{\"a\":\"b:c\"}"), "只按第一个冒号切")
    }

    func testFinishFlushesUnterminatedLastLine() throws {
        var d = SSELineDecoder()
        XCTAssertEqual(try d.feed(Data("data: a\ndata: [DONE]".utf8)), [.data("a")])
        XCTAssertEqual(d.finish(), [.data("[DONE]")])
        XCTAssertEqual(d.finish(), [], "finish 后清空")
        _ = try d.feed(Data("data: z\r".utf8))
        XCTAssertEqual(d.finish(), [.data("z")], "末尾单独 \\r 也算行尾")
    }

    func testResetDropsPending() throws {
        var d = SSELineDecoder()
        _ = try d.feed(Data("data: half".utf8))
        d.reset()
        XCTAssertEqual(try d.feed(Data("data: b\n".utf8)), [.data("b")])
    }

    func testMultibyteSplitAtEveryByte() throws {
        let sse = "data: 你好🌱\r\nevent: 事件\n"
        let bytes = Array(sse.utf8)
        for cut in 1..<bytes.count {
            var d = SSELineDecoder()
            let fields = try d.feed(Data(bytes[..<cut])) + d.feed(Data(bytes[cut...])) + d.finish()
            XCTAssertEqual(fields, [.data("你好🌱"), .event("事件")], "切在第 \(cut) 字节")
        }
    }

    func testBadUTF8BecomesReplacementNotDroppedLine() throws {
        var d = SSELineDecoder()
        var bytes = Data("data: a".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Array("b\ndata: c\n".utf8))
        XCTAssertEqual(try d.feed(bytes), [.data("a\u{FFFD}b"), .data("c")])
    }

    func testLineOver32MBThrows() throws {
        var d = SSELineDecoder()
        let mb = Data(repeating: 0x61, count: 1024 * 1024)
        for _ in 0..<32 { XCTAssertEqual(try d.feed(mb), []) }
        XCTAssertThrowsError(try d.feed(Data([0x61])))
        XCTAssertEqual(try d.feed(Data("data: ok\n".utf8)), [.data("ok")], "报错后清空，能接着用")
    }

    func testCustomLimitCountsEachLineWithoutTerminator() throws {
        var d = SSELineDecoder(maxLineBytes: 8)
        XCTAssertEqual(try d.feed(Data("data: 1\ndata: 2\ndata: 3\n".utf8)).count, 3, "每行单独量，不累加")
        XCTAssertThrowsError(try d.feed(Data("data: 123456".utf8)))
    }

    func testOverLimitLineWithNewlineInSameChunkThrows() throws {
        var line = Data(repeating: 0x61, count: SSELineDecoder.maxLineBytes + 1)
        line.append(0x0A)
        var d = SSELineDecoder()
        XCTAssertThrowsError(try d.feed(line), "超限的完整行和换行同片到达也要拒")
        XCTAssertEqual(try d.feed(Data("data: ok\n".utf8)), [.data("ok")], "报错后清空，能接着用")
    }

    func testExactLimitWithCRLFAcrossChunksAccepted() throws {
        let prefix = Data("data: ".utf8)
        var line = prefix
        line.append(Data(repeating: 0x61, count: SSELineDecoder.maxLineBytes - prefix.count))
        XCTAssertEqual(line.count, SSELineDecoder.maxLineBytes)
        for chunks in [[line, Data([0x0D]), Data([0x0A])], [line + Data([0x0D]), Data([0x0A])]] {
            var d = SSELineDecoder()
            var fields: [SSELineDecoder.Field] = []
            for c in chunks { fields += try d.feed(c) }
            XCTAssertEqual(fields.count, 1, "恰好上限 + 跨片 CRLF：行尾不计长度")
            guard case .data(let v)? = fields.first else { return XCTFail("应切出一行 data") }
            XCTAssertEqual(v.utf8.count, SSELineDecoder.maxLineBytes - prefix.count)
            XCTAssertEqual(d.finish(), [])
        }
    }

    /// 上限判定和切片方式无关：每个两刀切法（三片）都和整段一次喂结果一致
    func testLimitVerdictIndependentOfChunking() {
        func run(_ chunks: [Data]) -> [SSELineDecoder.Field]? {
            var d = SSELineDecoder(maxLineBytes: 8)
            var out: [SSELineDecoder.Field] = []
            for c in chunks {
                guard let fields = try? d.feed(c) else { return nil }
                out += fields
            }
            return out + d.finish()
        }
        let cases: [(String, Bool)] = [
            ("data: 12\r\ndata: 1\rdata: 34\n", true),
            ("data: 12\rdata: 34\r", true),
            ("data: 1\ndata: 123\r\n", false),
            ("data: 123\rdata: 1\n", false),
            ("data: 1\ndata: 123", false),
        ]
        for (sse, accepted) in cases {
            let bytes = Data(sse.utf8)
            let whole = run([bytes])
            XCTAssertEqual(whole != nil, accepted, sse.debugDescription)
            for a in 0...bytes.count {
                for b in a...bytes.count {
                    let split = run([bytes.prefix(a), bytes[a..<b], bytes.suffix(from: b)])
                    XCTAssertEqual(split, whole, "\(sse.debugDescription) 切在 \(a)/\(b)")
                }
            }
        }
    }
}

/// 三家 provider 喂流：逐字节切两片 / CRLF / 无空格 和整段一次喂结果一致
final class SSEProviderFeedTests: XCTestCase {

    private func drain() {
        let e = expectation(description: "主队列排空")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    // MARK: OpenAI 兼容

    private static func oaiChunk(_ obj: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self) + "\n\n"
    }

    static let openAISSE: String = [
        ": OPENROUTER PROCESSING\n\n",
        oaiChunk(["choices": [["delta": ["content": "你好，"]]]]),
        oaiChunk(["choices": [["delta": ["content": "花园🌱开了"]]]]),
        oaiChunk(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "fs_read", "arguments": "{\"path\":"]]]]]]]),
        oaiChunk(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"笔记.md\"}"]]]]]]]),
        oaiChunk(["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]], "usage": ["prompt_tokens": 12, "completion_tokens": 34]]),
        "data: [DONE]\n\n",
    ].joined()

    private struct OpenAIResult: Equatable {
        var content: String
        var tokens: [String]
        var calls: [String]
        var usage: TokenUsage?
        var done: Bool
    }

    private func runOpenAI(_ chunks: [Data]) -> OpenAIResult {
        let p = OpenAICompatibleProvider()
        var tokens: [String] = []
        var calls: [String] = []
        p.resetState(onToken: { tokens.append($0) }, onComplete: { _, _ in }, onError: { _ in })
        p.onToolCalls = { calls = $0.map { "\($0.id)|\($0.name)|\($0.argumentsJSON)" } }
        for c in chunks { p.processData(c) }
        drain()
        return OpenAIResult(content: p.streamingContent, tokens: tokens, calls: calls, usage: p.finalUsage, done: p.receivedDone)
    }

    func testOpenAISplitAtEveryByteMatchesWhole() {
        for sse in [Self.openAISSE, Self.openAISSE.replacingOccurrences(of: "\n", with: "\r\n")] {
            let bytes = Data(sse.utf8)
            let whole = runOpenAI([bytes])
            XCTAssertEqual(whole.content, "你好，花园🌱开了")
            XCTAssertEqual(whole.calls, ["call_1|fs_read|{\"path\":\"笔记.md\"}"])
            XCTAssertEqual(whole.usage?.inputTokens, 12)
            XCTAssertTrue(whole.done)
            for cut in 1..<bytes.count {
                XCTAssertEqual(runOpenAI([bytes.prefix(cut), bytes.suffix(from: cut)]), whole, "切在第 \(cut) 字节")
            }
        }
    }

    func testOpenAIDataWithoutSpaceAndDoneEnds() {
        let sse = Self.openAISSE.replacingOccurrences(of: "data: ", with: "data:")
        let r = runOpenAI([Data(sse.utf8)])
        XCTAssertEqual(r.content, "你好，花园🌱开了")
        XCTAssertTrue(r.done, "data:[DONE] 无空格也能结束")
    }

    func testOpenAINonOKErrorBodySplitInMultibyte() {
        let body = Data(#"{"error":{"message":"额度不足，请充值"}}"#.utf8)
        let cut = body.firstIndex(of: Array("额".utf8)[0])! + 1
        let p = OpenAICompatibleProvider()
        p.httpStatusCode = 429
        p.processData(body.prefix(cut))
        p.processData(body.suffix(from: cut))
        XCTAssertEqual(p.handleErrorBody(), "额度不足，请充值")
    }

    func testOpenAIUnterminatedLastLineFlushedOnFinish() {
        let p = OpenAICompatibleProvider()
        p.processData(Data(#"data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":6}}"#.utf8))
        XCTAssertNil(p.finalUsage, "没换行的行先不处理")
        p.handle(p.sseDecoder.finish())
        XCTAssertEqual(p.finalUsage?.outputTokens, 6)
    }

    // MARK: Anthropic

    private struct AnthropicResult: Equatable {
        var blocks: [String]
        var content: String
        var usage: TokenUsage?
        var reasoning: Int?
    }

    private func runAnthropic(_ chunks: [Data]) -> AnthropicResult {
        let p = AnthropicProvider()
        p.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in })
        for c in chunks { p.processData(c) }
        drain()
        let blocks = p.replyBlocks.map { b in
            "\(b.complete)|" + String(decoding: try! JSONSerialization.data(withJSONObject: b.raw, options: [.sortedKeys]), as: UTF8.self)
        }
        return AnthropicResult(blocks: blocks, content: p.streamingContent, usage: p.finalUsage, reasoning: p.accumulatedReasoningTokens)
    }

    static let anthropicSSE: String = ThinkingStreamTests.toolTurnSSE
        .replacingOccurrences(of: "我查", with: "我查🌱花园")

    func testAnthropicSplitAtEveryByteMatchesWhole() {
        for sse in [Self.anthropicSSE, Self.anthropicSSE.replacingOccurrences(of: "\n", with: "\r\n")] {
            let bytes = Data(sse.utf8)
            let whole = runAnthropic([bytes])
            XCTAssertEqual(whole.blocks.count, 4)
            XCTAssertEqual(whole.content, "我查🌱花园一下")
            XCTAssertEqual(whole.reasoning, 220)
            for cut in 1..<bytes.count {
                XCTAssertEqual(runAnthropic([bytes.prefix(cut), bytes.suffix(from: cut)]), whole, "切在第 \(cut) 字节")
            }
        }
    }

    func testAnthropicCRLFToolTurnMatchesLF() throws {
        let lf = runAnthropic([Data(ThinkingStreamTests.toolTurnSSE.utf8)])
        let crlf = runAnthropic([Data(ThinkingStreamTests.toolTurnSSE.replacingOccurrences(of: "\n", with: "\r\n").utf8)])
        XCTAssertEqual(crlf, lf)
        let p = AnthropicProvider()
        p.processData(Data(ThinkingStreamTests.toolTurnSSE.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        let blocks = p.replyBlocks
        XCTAssertEqual(blocks.map(\.type), ["thinking", "text", "thinking", "tool_use"])
        XCTAssertTrue(blocks.allSatisfy(\.complete))
        XCTAssertEqual(blocks[0].raw["thinking"] as? String, "先想一下")
        XCTAssertEqual(blocks[0].raw["signature"] as? String, "sig-0")
        XCTAssertEqual((blocks[3].raw["input"] as? [String: Any])?["path"] as? String, "a.md")
        XCTAssertEqual(p.finalUsage?.reasoningTokens, 220)
    }

    func testAnthropicEventWithoutSpace() {
        let sse = ThinkingStreamTests.toolTurnSSE
            .replacingOccurrences(of: "event: ", with: "event:")
            .replacingOccurrences(of: "data: ", with: "data:")
        XCTAssertEqual(runAnthropic([Data(sse.utf8)]), runAnthropic([Data(ThinkingStreamTests.toolTurnSSE.utf8)]))
    }

    // MARK: ChatGPT OAuth（Responses）

    func testOAuthDeltaSplitAtEveryByte() {
        let sse = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"你好🌱\"}\r\n\r\n"
            + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"花园\"}\n\ndata: [DONE]\n\n"
        let bytes = Data(sse.utf8)
        for cut in 1..<bytes.count {
            let p = ChatGPTOAuthProvider()
            p.processData(bytes.prefix(cut))
            p.processData(bytes.suffix(from: cut))
            XCTAssertEqual(p.streamingContent, "你好🌱花园", "切在第 \(cut) 字节")
            XCTAssertTrue(p.receivedDone)
        }
    }

    func testOAuthNonOKBodyGoesToErrorBody() {
        let body = Data(#"{"error":{"message":"登录已过期，请重新登录"}}"#.utf8)
        let cut = body.firstIndex(of: Array("登".utf8)[0])! + 2
        let p = ChatGPTOAuthProvider()
        p.httpStatusCode = 401
        p.processData(body.prefix(cut))
        p.processData(body.suffix(from: cut))
        XCTAssertEqual(p.handleErrorBody(), "登录已过期，请重新登录")
        XCTAssertEqual(p.streamingContent, "")
    }

    // MARK: 真实 delegate 入口（响应头 → didReceive data → didCompleteWithError）

    /// 记下对外回调的先后：token / complete / tools / error
    private final class Stream {
        let provider: BaseChatProvider
        let session = URLSession(configuration: .ephemeral)
        let task: URLSessionDataTask
        let delegate: ChatRequestDelegate
        var events: [String] = []

        init(_ p: BaseChatProvider, maxLineBytes: Int = SSELineDecoder.maxLineBytes) {
            provider = p
            task = session.dataTask(with: URL(string: "https://example.invalid/v1")!)
            delegate = ChatRequestDelegate(owner: p, generation: p.pacedGeneration + 1)
            p.resetState(onToken: { [unowned self] in events.append("token:\($0)") },
                         onComplete: { [unowned self] text, _ in events.append("complete:\(text)") },
                         onError: { [unowned self] in events.append("error:\($0)") })
            p.onToolCalls = { [unowned self] in events.append("tools:\($0.count)") }
            p.sseDecoder = SSELineDecoder(maxLineBytes: maxLineBytes)
            p.urlSession = session
            p.sessionGeneration = p.pacedGeneration
            let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
        }

        func feed(_ sse: String) { delegate.urlSession(session, dataTask: task, didReceive: Data(sse.utf8)) }
        func eof() { delegate.urlSession(session, task: task, didCompleteWithError: nil) }
        var terminals: [String] { events.filter { !$0.hasPrefix("token:") } }
    }

    private static let oaiToken = oaiChunk(["choices": [["delta": ["content": "半句"]]]])
    private static let oaiErrorTail = #"data: {"error":{"message":"上游炸了"}}"#
    private static let anthropicToken = "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
        + "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"半句\"}}\n\n"
    private static let anthropicErrorTail = "event: error\r\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"上游炸了\"}}"
    private static let oauthErrorTail = #"data: {"type":"response.error","error":{"message":"上游炸了"}}"#

    func testDelegateTokensThenSingleCompleteOnDone() {
        let s = Stream(OpenAICompatibleProvider())
        s.feed(Self.openAISSE)
        s.eof()
        drain()
        XCTAssertEqual(s.events, ["token:你好，", "token:花园🌱开了", "tools:1"])
    }

    func testDelegateUnterminatedLastTokenThenEOFCompletesOnce() {
        let s = Stream(OpenAICompatibleProvider())
        s.feed(Self.oaiToken + "data: {\"choices\":[{\"delta\":{\"content\":\"尾巴\"}}]}")
        s.eof()
        drain()
        XCTAssertEqual(s.events, ["token:半句", "token:尾巴", "complete:半句尾巴"], "末行正文先落地，再结算一次")
    }

    func testDelegateErrorTailSettlesExactlyOnce() {
        let providers: [(String, () -> BaseChatProvider, String, String)] = [
            ("OpenAI", { OpenAICompatibleProvider() }, Self.oaiToken, Self.oaiErrorTail),
            ("Anthropic", { AnthropicProvider() }, Self.anthropicToken, Self.anthropicErrorTail),
            ("OAuth", { ChatGPTOAuthProvider() },
             "data: {\"type\":\"response.output_text.delta\",\"delta\":\"半句\"}\n\n", Self.oauthErrorTail),
        ]
        for (name, make, token, tail) in providers {
            for withContent in [false, true] {
                let s = Stream(make())
                s.feed((withContent ? token : "") + tail)
                s.eof()
                drain()
                XCTAssertEqual(s.terminals, ["error:上游炸了"], "\(name) 有正文=\(withContent)：错误末行 + EOF 只终止一次")
                XCTAssertEqual(s.provider.error, name == "OAuth" ? nil : "上游炸了", "\(name) 错误不被「未收到回复」覆盖")
            }
        }
    }

    func testDelegateOverLimitInvalidatesQueuedCallbacks() {
        for queued in [Self.oaiToken, Self.oaiToken + "data: [DONE]\n\n"] {
            let s = Stream(OpenAICompatibleProvider(), maxLineBytes: 64)
            s.feed(queued)
            s.feed("data: " + String(repeating: "a", count: 80) + "\n")
            s.feed(Self.oaiToken)
            s.eof()
            drain()
            XCTAssertEqual(s.events, ["error:回包一行太长（超过 32 MB），已停止接收"], "已排队的 token / DONE 作废，报错后零回调")
            XCTAssertFalse(s.provider.isStreaming)
        }
    }

    func testDelegateCancelAndNewTurnDropOldCallbacks() {
        let p = OpenAICompatibleProvider()
        let s = Stream(p)
        s.feed(Self.oaiToken)
        p.cancel()
        s.feed(Self.oaiToken)
        s.eof()
        drain()
        XCTAssertEqual(s.events, [], "cancel 后已排队和迟到的回调都不落地")

        let old = Stream(p)
        old.feed(Self.oaiToken)
        let next = Stream(p)
        old.feed("data: [DONE]\n\n")
        old.eof()
        next.feed(Self.oaiToken + "data: [DONE]\n\n")
        drain()
        XCTAssertEqual(old.events, [], "换代后旧轮零回调")
        XCTAssertEqual(next.events, ["token:半句", "complete:半句"])
    }
}
