import XCTest
@testable import 记忆花园

/// thinking 回传 §3.3：当轮工具循环原样回传（只换审批卡改过的 input）、老形状不变、预算收尾去块、BP4 不落在思考块
final class ThinkingReplayTests: XCTestCase {

    /// 思考 + 正文 + 进度更新思考 + tool_use（input 是模型原来写的）
    static let content: [[String: Any]] = [
        ["type": "thinking", "thinking": "先想", "signature": "sig-0"],
        ["type": "text", "text": "我查一下"],
        ["type": "thinking", "thinking": "", "signature": "sig-progress"],
        ["type": "tool_use", "id": "toolu_1", "name": "run_command", "input": ["command": "rm -rf /"]],
    ]

    /// 审批卡上改过命令：发出去的调用是改过的
    static let editedTurn = ToolTurn(
        calls: [ToolCallBlock(id: "toolu_1", name: "run_command", argumentsJSON: #"{"command":"ls"}"#)],
        results: [ToolResultBlock(toolUseId: "toolu_1", text: "a.md", isError: false)],
        assistantContent: content)

    private func body(_ turns: [ToolTurn], cacheFriendly: Bool = false) -> [String: Any] {
        var s = SamplingParams()
        s.cacheFriendly = cacheFriendly
        return AnthropicProvider.buildRequestBody(messages: [(role: "user", content: "看看目录")], model: "claude-sonnet-4-5",
                                                  systemPrompt: nil, samplingParams: s, toolTurns: turns)
    }

    private func assistant(_ body: [String: Any]) throws -> [[String: Any]] {
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.last { $0["role"] as? String == "assistant" }?["content"] as? [[String: Any]])
    }

    func testVerbatimEchoOnlyInputReplaced() throws {
        let blocks = try assistant(body([Self.editedTurn]))
        XCTAssertEqual(blocks.count, 4)
        for i in 0..<3 {
            XCTAssertTrue(NSDictionary(dictionary: blocks[i]).isEqual(to: Self.content[i]), "第 \(i) 块一个字节不动")
        }
        XCTAssertEqual(blocks[3]["id"] as? String, "toolu_1")
        XCTAssertEqual(blocks[3]["name"] as? String, "run_command")
        XCTAssertEqual((blocks[3]["input"] as? [String: Any])?["command"] as? String, "ls", "只换审批卡改过的 input")
        let messages = try XCTUnwrap(body([Self.editedTurn])["messages"] as? [[String: Any]])
        XCTAssertEqual((messages.last?["content"] as? [[String: Any]])?.first?["type"] as? String, "tool_result")
    }

    func testLegacyShapeWhenNoContentOrIdsDiffer() throws {
        let legacy = ToolTurn(calls: Self.editedTurn.calls, results: Self.editedTurn.results)
        XCTAssertEqual(try assistant(body([legacy])).map { $0["type"] as? String }, ["tool_use"], "nil = 老形状")
        let mismatched = ToolTurn(calls: [ToolCallBlock(id: "other", name: "fs_read", argumentsJSON: "{}")],
                                  results: [ToolResultBlock(toolUseId: "other", text: "x", isError: false)],
                                  assistantContent: Self.content)
        let blocks = try assistant(body([mismatched]))
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["tool_use"], "id 对不上就退回老形状，不发错配的块")
        XCTAssertEqual(blocks.first?["id"] as? String, "other")
    }

    func testDroppingThinkingKeepsEverythingElse() throws {
        let dropped = Self.editedTurn.droppingThinking()
        XCTAssertEqual(Self.editedTurn.thinkingBlockCount, 2)
        XCTAssertEqual(dropped.thinkingBlockCount, 0)
        XCTAssertEqual(try assistant(body([dropped])).map { $0["type"] as? String }, ["text", "tool_use"])
        let redacted = ToolTurn(calls: [], results: [], assistantContent: [["type": "redacted_thinking", "data": "E"], ["type": "text", "text": "x"]])
        XCTAssertEqual(redacted.droppingThinking().assistantContent?.count, 1, "redacted 一起去")
    }

    func testBP4SkipsThinkingBlocks() throws {
        var trailing = Self.content
        trailing.append(["type": "thinking", "thinking": "", "signature": "sig-tail"])
        // 没改 input（改了的话 astra #2 会把后面的思考块去掉，就测不到 BP4 了）
        let turn = ToolTurn(calls: [ToolCallBlock(id: "toolu_1", name: "run_command", argumentsJSON: #"{"command":"rm -rf /"}"#)],
                            results: Self.editedTurn.results, assistantContent: trailing)
        let blocks = try assistant(body([turn], cacheFriendly: true))
        XCTAssertNil(blocks.last?["cache_control"], "思考块不能挂 cache_control")
        XCTAssertNotNil(blocks[3]["cache_control"], "挂到它前面最后一个非思考块（tool_use）")
        XCTAssertEqual(blocks.filter { $0["cache_control"] != nil }.count, 1)

        let allThinking = ToolTurn(calls: [], results: [], assistantContent: [["type": "thinking", "thinking": "", "signature": "s"]])
        XCTAssertEqual(try assistant(body([allThinking], cacheFriendly: true)).filter { $0["cache_control"] != nil }.count, 0,
                       "整条都是思考就不挂")
        XCTAssertNotNil(try assistant(body([ToolTurn(calls: Self.editedTurn.calls, results: Self.editedTurn.results)], cacheFriendly: true))
            .last?["cache_control"], "老形状照旧挂最后一块")
    }

    func testWireContentDropsEmptyTextAndIncomplete() {
        let blocks = [
            ReplyBlock(raw: ["type": "text", "text": ""], complete: true),
            ReplyBlock(raw: ["type": "thinking", "thinking": "半截", "signature": ""], complete: false),
            ReplyBlock(raw: ["type": "server_tool_use", "id": "srv", "name": "web_search", "input": ["query": "q"]], complete: true),
            ReplyBlock(raw: ["type": "web_search_tool_result", "tool_use_id": "srv", "content": [[String: Any]]()], complete: true),
        ]
        XCTAssertEqual(blocks.wireContent?.map { $0["type"] as? String }, ["server_tool_use", "web_search_tool_result"],
                       "服务端搜索块原样带上；空正文 / 不完整的不带")
        XCTAssertNil([ReplyBlock]().wireContent)
    }

    /// astra #2：思考 A → tool_use X → 思考 B → 正文 → tool_use Y，审批卡改了 X：B 的签名覆盖了改前的 X，从 X 起往后的思考块都去掉，A 和其余块照留
    func testEditedInputDropsLaterThinkingOnly() throws {
        let interleaved: [[String: Any]] = [
            ["type": "thinking", "thinking": "A", "signature": "sig-A"],
            ["type": "tool_use", "id": "x", "name": "run_command", "input": ["command": "rm -rf /"]],
            ["type": "thinking", "thinking": "", "signature": "sig-B"],
            ["type": "redacted_thinking", "data": "R"],
            ["type": "text", "text": "再看一个"],
            ["type": "tool_use", "id": "y", "name": "run_command", "input": ["command": "pwd"]],
        ]
        let results = [ToolResultBlock(toolUseId: "x", text: "1", isError: false), ToolResultBlock(toolUseId: "y", text: "2", isError: false)]
        func turn(x: String, y: String) -> ToolTurn {
            ToolTurn(calls: [ToolCallBlock(id: "x", name: "run_command", argumentsJSON: #"{"command":"\#(x)"}"#),
                             ToolCallBlock(id: "y", name: "run_command", argumentsJSON: #"{"command":"\#(y)"}"#)],
                     results: results, assistantContent: interleaved)
        }
        let editedX = try assistant(body([turn(x: "ls", y: "pwd")]))
        XCTAssertEqual(editedX.map { $0["type"] as? String }, ["thinking", "tool_use", "text", "tool_use"])
        XCTAssertEqual(editedX.first?["signature"] as? String, "sig-A", "改动前面的思考照留")
        XCTAssertEqual((editedX[1]["input"] as? [String: Any])?["command"] as? String, "ls")

        let untouched = try assistant(body([turn(x: "rm -rf /", y: "pwd")]))
        XCTAssertEqual(untouched.count, 6, "没改 input：整条原样")

        let editedY = try assistant(body([turn(x: "rm -rf /", y: "ls")]))
        XCTAssertEqual(editedY.map { $0["type"] as? String }, ["thinking", "tool_use", "thinking", "redacted_thinking", "text", "tool_use"],
                       "改的是最后一个 tool_use：后面没有思考块，全留")
    }
}
