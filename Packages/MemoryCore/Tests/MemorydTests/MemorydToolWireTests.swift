import XCTest
import MemoryCore
@testable import memoryd

/// memoryd 的带工具调用：两种接口形状的请求体和回包解析。假传输层，全虚构
final class MemorydToolWireTests: XCTestCase {
    private static let key = "sk-fake-not-a-real-key-0000"
    private let tools = [AgentToolSpec(name: "list_cards", description: "列卡", schema: #"{"type":"object","properties":{"offset":{"type":"integer"}}}"#)]
    private let turns: [AgentTurn] = [
        .user("开始吧。"),
        .assistant(text: "我先看卡。", calls: [AgentToolCall(id: "t1", name: "list_cards", arguments: #"{"offset":0}"#)], reasoning: "想了一下"),
        .toolResults([AgentToolResult(callId: "t1", content: "[1] 岚舟的模型船做成双帆。")]),
    ]

    private func model(_ wire: MemorydModel.Wire, reply: String) -> MemorydModel {
        MemorydModel(base: URL(string: "https://example.invalid/v1")!, modelId: "fake", key: Self.key, wire: wire) { request in
            (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testAnthropicRequestCarriesToolUseAndResultsWithCacheBreakpoints() throws {
        let request = try model(.anthropic, reply: "{}").toolRequest(system: "系统提示", turns: turns, tools: tools)
        let body = try body(request)
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "系统提示")
        XCTAssertNotNil(system.first?["cache_control"])
        let spec = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(spec["name"] as? String, "list_cards")
        XCTAssertNotNil(spec["input_schema"] as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["text", "tool_use"])
        XCTAssertEqual((assistant[1]["input"] as? [String: Any])?["offset"] as? Int, 0)
        let result = try XCTUnwrap((messages[2]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["type"] as? String, "tool_result")
        XCTAssertEqual(result["tool_use_id"] as? String, "t1")
        XCTAssertNotNil(result["cache_control"], "最后一段打断点，下一轮前面的都能命中")
    }

    func testAnthropicReplyParsesTextToolUseAndCachedUsage() async throws {
        let reply = #"{"content":[{"type":"text","text":"看完了。"},{"type":"tool_use","id":"t2","name":"record","input":{"items":[]}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":90,"cache_creation_input_tokens":20}}"#
        let step = try await model(.anthropic, reply: reply).step(system: "s", turns: turns, tools: tools)
        XCTAssertEqual(step.text, "看完了。")
        XCTAssertEqual(step.calls, [AgentToolCall(id: "t2", name: "record", arguments: #"{"items":[]}"#)])
        XCTAssertEqual(step.usage, AgentUsage(input: 120, output: 5, cacheRead: 90))
        XCTAssertEqual(step.stop, "tool_use")
    }

    func testOpenAIRequestCarriesToolCallsReasoningAndToolRole() throws {
        let request = try model(.openai, reply: "{}").toolRequest(system: "系统提示", turns: turns, tools: tools)
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/v1/chat/completions")
        let body = try body(request)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(messages[2]["reasoning_content"] as? String, "想了一下")
        let call = try XCTUnwrap((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, #"{"offset":0}"#)
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "t1")
        let spec = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(spec["type"] as? String, "function")
    }

    func testOpenAIReplyParsesToolCallsAndReasoning() async throws {
        let reply = #"{"choices":[{"message":{"content":"","reasoning_content":"先看再说","tool_calls":[{"id":"c9","type":"function","function":{"name":"check","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":200,"completion_tokens":30,"prompt_cache_hit_tokens":150}}"#
        let step = try await model(.openai, reply: reply).step(system: "s", turns: turns, tools: tools)
        XCTAssertEqual(step.calls, [AgentToolCall(id: "c9", name: "check", arguments: "{}")])
        XCTAssertEqual(step.reasoning, "先看再说")
        XCTAssertEqual(step.usage, AgentUsage(input: 200, output: 30, cacheRead: 150))
    }

    func testEmptyStepAndHTTPErrorThrowWithKeyRedacted() async {
        do {
            _ = try await model(.anthropic, reply: #"{"content":[],"stop_reason":"end_turn"}"#).step(system: "s", turns: turns, tools: tools)
            XCTFail("既没说话也没调工具应该抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("end_turn"))
        }
        // 写到上限被截断不算出错：交给循环去提醒它分批
        let cut = try? await model(.anthropic, reply: #"{"content":[],"stop_reason":"max_tokens"}"#).step(system: "s", turns: turns, tools: tools)
        XCTAssertEqual(cut?.truncated, true)
        let cutOpenAI = try? await model(.openai, reply: #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#).step(system: "s", turns: turns, tools: tools)
        XCTAssertEqual(cutOpenAI?.truncated, true)
        let failing = MemorydModel(base: URL(string: "https://example.invalid")!, modelId: "m", key: Self.key) { request in
            (Data("bad key \(Self.key)".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await failing.step(system: "s", turns: turns, tools: tools)
            XCTFail("401 应该抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains(Self.key))
        }
    }
}
