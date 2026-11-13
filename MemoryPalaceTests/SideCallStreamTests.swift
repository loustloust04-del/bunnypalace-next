import XCTest
@testable import 记忆花园

/// 刀 4 返修：副调用默认走流式、卡上能关（research-非流式长请求断线）。
/// 拼包器纯函数 + router.sideCall 打本机脚本服务器（流式 / 非流式两种卡、中转不理 stream、流断、流里报错）+ 卡字段编解码
final class SideCallStreamTests: XCTestCase {
    // MARK: 拼包器

    private func assemble(_ format: SideStreamAssembler.Format, _ lines: [String]) throws -> [String: Any] {
        var a = SideStreamAssembler(format: format)
        for line in lines { try a.feed(line) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: a.body()) as? [String: Any])
    }

    func testOpenAIChunksBecomeNonStreamBody() throws {
        let obj = try assemble(.openAI, [
            #"data: {"id":"r-1","choices":[{"delta":{"role":"assistant","content":"你"}}]}"#,
            ": keep-alive",
            #"data: {"id":"r-1","choices":[{"delta":{"content":"好"},"finish_reason":"length"}]}"#,
            #"data: {"id":"r-1","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#,
            "data: [DONE]",
        ])
        let provider = OpenAICompatibleProvider()
        let parsed = try provider.parseNonStreamBody(JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(parsed.text, "你好")
        XCTAssertTrue(parsed.hitOutputLimit)
        XCTAssertEqual(parsed.usage?.inputTokens, 5)
        XCTAssertEqual(parsed.usage?.outputTokens, 2)
    }

    func testAnthropicEventsBecomeNonStreamBody() throws {
        let obj = try assemble(.anthropic, [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":12,"output_tokens":1,"cache_read_input_tokens":4}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"想"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"星"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"砚"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":8192,"cache_read_input_tokens":0}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        let parsed = try AnthropicProvider().parseNonStreamBody(JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(parsed.text, "星砚", "思考块不进正文")
        XCTAssertTrue(parsed.hitOutputLimit)
        XCTAssertEqual(parsed.usage?.inputTokens, 12)
        XCTAssertEqual(parsed.usage?.outputTokens, 8192)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 4, "delta 里的 0 不抹掉 start 的真值")
    }

    func testStreamWithoutEndMarkerIsIncomplete() {
        var a = SideStreamAssembler(format: .anthropic)
        XCTAssertNoThrow(try a.feed(#"data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}"#))
        XCTAssertNoThrow(try a.feed(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"半"}}"#))
        XCTAssertThrowsError(try a.body()) { XCTAssertEqual($0 as? SideStreamAssembler.Failure, .incomplete) }
    }

    func testErrorEventThrowsUpstream() {
        var a = SideStreamAssembler(format: .anthropic)
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertThrowsError(try a.feed(line)) {
            XCTAssertEqual($0 as? SideStreamAssembler.Failure, .upstream(String(line.dropFirst(6))))
        }
    }

    func testPlainJSONPassesThrough() throws {
        let json = #"{"choices":[{"message":{"content":"整包"},"finish_reason":"stop"}]}"#
        var a = SideStreamAssembler(format: .openAI)
        try a.feed(json)
        XCTAssertEqual(String(decoding: try a.body(), as: UTF8.self), json)
    }

    // MARK: router.sideCall

    private static func sse(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n\n") + "\n\n").utf8)
    }

    private static let openAIStream = sse([
        #"data: {"id":"r-1","choices":[{"delta":{"content":"流"}}]}"#,
        #"data: {"id":"r-1","choices":[{"delta":{"content":"式"},"finish_reason":"length"}]}"#,
        #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#,
        "data: [DONE]",
    ])

    private static let anthropicStream = sse([
        "event: message_start\n" + #"data: {"type":"message_start","message":{"id":"msg_1","content":[],"usage":{"input_tokens":7,"output_tokens":1}}}"#,
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"好"}}"#,
        #"data: {"type":"content_block_stop","index":0}"#,
        #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
        #"data: {"type":"message_stop"}"#,
    ])

    @MainActor
    private func sideCall(_ type: ProviderType, streaming: Bool?, respond: @escaping (Int, Data) -> (status: Int, contentType: String, body: Data))
        async throws -> (Result<SideCallResult, Error>, [String: Any]) {
        let server = try ScriptedHTTPServer(respond: respond)
        try server.start()
        defer { server.stop() }
        let id = "xctest-sidestream-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: "side-model", name: "side")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: id, name: "副调用流式", emoji: "🌊", type: type, baseURL: server.baseURL,
                                       extraHeaders: type == .anthropic ? ["anthropic-version": "2023-06-01"] : [:],
                                       models: [model], toolsSupported: false, sideCallStreaming: streaming))
        pm.setApiKey("test-key", for: id)
        defer { pm.removeCredential(id: id) }
        let router = ProviderRouter(usageContext: UsageContext(kind: .topic))
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("side-\(UUID().uuidString).jsonl"))
        let result: Result<SideCallResult, Error>
        do {
            result = .success(try await router.sideCall(model: model, messages: [(role: "user", content: "hi")],
                                                        systemPrompt: "sys", providerManager: pm))
        } catch {
            result = .failure(error)
        }
        let sent = try XCTUnwrap(server.requestBodies.first)
        return (result, try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any]))
    }

    @MainActor
    func testOpenAICardStreamsByDefault() async throws {
        let (result, body) = try await sideCall(.openaiCompatible, streaming: nil) { _, _ in (200, "text/event-stream", Self.openAIStream) }
        let r = try result.get()
        XCTAssertEqual(r.text, "流式")
        XCTAssertTrue(r.hitOutputLimit)
        XCTAssertEqual(r.usage?.outputTokens, 2)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
    }

    @MainActor
    func testAnthropicCardStreamsByDefault() async throws {
        let (result, body) = try await sideCall(.anthropic, streaming: true) { _, _ in (200, "text/event-stream", Self.anthropicStream) }
        let r = try result.get()
        XCTAssertEqual(r.text, "好")
        XCTAssertFalse(r.hitOutputLimit)
        XCTAssertEqual(r.usage?.inputTokens, 7)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    @MainActor
    func testStreamingOffSendsNonStream() async throws {
        let openAIJSON = Data(#"{"choices":[{"message":{"content":"整包"},"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":9}}"#.utf8)
        let (o, oBody) = try await sideCall(.openaiCompatible, streaming: false) { _, _ in (200, "application/json", openAIJSON) }
        XCTAssertEqual(try o.get().text, "整包")
        XCTAssertTrue(try o.get().hitOutputLimit)
        XCTAssertEqual(oBody["stream"] as? Bool, false)
        XCTAssertNil(oBody["stream_options"])

        let anthropicJSON = Data(#"{"content":[{"type":"text","text":"整包"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2}}"#.utf8)
        let (a, aBody) = try await sideCall(.anthropic, streaming: false) { _, _ in (200, "application/json", anthropicJSON) }
        XCTAssertEqual(try a.get().text, "整包")
        XCTAssertNil(aBody["stream"])
    }

    @MainActor
    func testRelayIgnoringStreamStillWorks() async throws {
        let json = Data(#"{"choices":[{"message":{"content":"中转整包"},"finish_reason":"stop"}]}"#.utf8)
        let (result, _) = try await sideCall(.openaiCompatible, streaming: nil) { _, _ in (200, "application/json", json) }
        XCTAssertEqual(try result.get().text, "中转整包")
    }

    @MainActor
    func testCutStreamAndErrorEventThrow() async throws {
        let cut = Self.sse([#"data: {"choices":[{"delta":{"content":"半截"}}]}"#])
        let (r1, _) = try await sideCall(.openaiCompatible, streaming: nil) { _, _ in (200, "text/event-stream", cut) }
        XCTAssertThrowsError(try r1.get()) { XCTAssertEqual(($0 as NSError).code, -4) }

        let err = Self.sse([#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded test-key"}}"#])
        let (r2, _) = try await sideCall(.anthropic, streaming: nil) { _, _ in (200, "text/event-stream", err) }
        XCTAssertThrowsError(try r2.get()) {
            let message = ($0 as NSError).localizedDescription
            XCTAssertTrue(message.contains("Overloaded"), message)
            XCTAssertFalse(message.contains("test-key"), "报错文案不带 key")
        }
    }

    @MainActor
    func testHTTPErrorWhileStreamingKeepsUpstreamReason() async throws {
        let body = Data(#"{"error":{"message":"bad model"}}"#.utf8)
        let (result, _) = try await sideCall(.openaiCompatible, streaming: nil) { _, _ in (404, "application/json", body) }
        XCTAssertThrowsError(try result.get()) {
            XCTAssertEqual(($0 as NSError).code, 404)
            XCTAssertTrue(($0 as NSError).localizedDescription.contains("bad model"))
        }
    }

    // MARK: 卡字段

    func testCardFieldCodecAndDraft() throws {
        let old = Data(#"{"id":"c","name":"n","type":"anthropic","baseURL":"https://x.invalid"}"#.utf8)
        let legacy = try JSONDecoder().decode(APICredential.self, from: old)
        XCTAssertNil(legacy.sideCallStreaming, "老存档没这个字段 = 默认流式")
        XCTAssertTrue(CredentialDraft.loaded(from: legacy).sideCallStreaming)

        var off = legacy
        off.sideCallStreaming = false
        let roundTrip = try JSONDecoder().decode(APICredential.self, from: JSONEncoder().encode(off))
        XCTAssertEqual(roundTrip.sideCallStreaming, false)

        var draft = CredentialDraft.loaded(from: roundTrip)
        XCTAssertFalse(draft.sideCallStreaming)
        XCTAssertEqual(draft.makeCredential(id: "c", existing: roundTrip).sideCallStreaming, false)
        draft.sideCallStreaming = true
        XCTAssertNil(draft.makeCredential(id: "c", existing: roundTrip).sideCallStreaming, "开 = 不写字段")

        let oldDraft = Data(#"{"slot":"__new__","emoji":"","nickname":"","presetSelection":"","customBaseURL":"","customType":"anthropic","toolsSupported":true,"models":[],"keyStored":false,"baseURLInSecret":false,"resumeOffered":false,"savedAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(APIDraft.self, from: oldDraft).sideCallStreaming, "旧草稿也解得出")
    }
}
