import XCTest
@testable import 记忆花园

/// #089 P0-b：历史工具回合 → 真 tool_use / tool_result（替代「〔我在本对话做过的文件操作〕」前缀）
final class ToolReplayTests: XCTestCase {

    private func use(_ id: String, _ name: String, _ input: String = "{}") -> MessageSegment {
        .toolUse(id: id, name: name, inputJSON: input, integrationName: nil, iconName: nil)
    }

    private func result(_ id: String, _ text: String, error: Bool = false) -> MessageSegment {
        .toolResult(toolUseId: id, text: text, isError: error, integrationName: nil)
    }

    // MARK: 节点 → 回合

    func testRoundsSplitOnTextAndOrderResultsByCall() throws {
        let segs: [MessageSegment] = [
            .text("我找找"), use("a", "fs_search", #"{"keyword":"密码"}"#), use("b", "card_guide"),
            result("b", "格式"), result("a", "命中 2 条"),
            .text("再读一下"), use("c", "fs_read", #"{"path":"x.md"}"#), result("c", "内容"),
            .text("给你："),
        ]
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: segs))
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds[0].text, "我找找")
        XCTAssertEqual(rounds[0].calls.map(\.id), ["a", "b"])
        XCTAssertEqual(rounds[0].results.map(\.toolUseId), ["a", "b"], "结果按调用顺序")
        XCTAssertEqual(rounds[1].text, "再读一下")
        XCTAssertEqual(rounds[1].results.first?.text, "内容")
    }

    func testMissingResultBecomesError() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [use("a", "fs_read")]))
        XCTAssertEqual(rounds.first?.results.first?.text, ToolReplay.missingResultText)
        XCTAssertEqual(rounds.first?.results.first?.isError, true)
    }

    func testUnreplayableFallsBack() {
        XCTAssertNil(ToolReplay.rounds(from: [use("", "fs_read")]), "导入的空 id")
        XCTAssertNil(ToolReplay.rounds(from: [use("a", "")]))
        XCTAssertEqual(ToolReplay.rounds(from: [.text("只有字")])?.count, 0)
    }

    func testIdSanitizedConsistently() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [use("call:1/2", "fs_read"), result("call:1/2", "ok")]))
        XCTAssertEqual(rounds[0].calls[0].id, "call_1_2")
        XCTAssertEqual(rounds[0].results[0].toolUseId, "call_1_2")
        XCTAssertEqual(rounds[0].results[0].text, "ok")
    }

    /// astra #2：清洗后撞车的 id 各配各的结果，线上 id 不重复
    func testSanitizedIdCollisionKeepsPairs() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [
            use("call:1", "fs_read"), use("call/1", "fs_read"), result("call:1", "结果A"), result("call/1", "结果B"),
        ]))
        let calls = rounds[0].calls.map(\.id)
        XCTAssertEqual(Set(calls).count, 2, "\(calls)")
        XCTAssertEqual(rounds[0].results.map(\.text), ["结果A", "结果B"])
        XCTAssertEqual(rounds[0].results.map(\.toolUseId), calls)
    }

    /// astra #5：中间夹着 [动态上下文] 也去重；Q/A 是最新一条时后面贴了写作风格，只去掉开头那段；超 2KB 的回答用原文比
    func testAskDedupSurvivesInjectedMessageAndStyleSuffix() throws {
        let qa = "Q: 吃啥\nA: " + String(repeating: "面", count: 1000)
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [use("q", AskUserTool.toolName), result("q", qa)]))
        XCTAssertEqual(rounds[0].askAnswer, qa, "去重用没截断的原文")
        let messages = [
            PromptWire.Message(role: "assistant", chunks: [(text: "", attachments: [])], toolRounds: rounds),
            PromptWire.Message(role: "user", chunks: [(text: "[动态上下文｜仅供参考，不要复述]\n〔状态〕", attachments: [])]),
            PromptWire.Message(role: "user", chunks: [(text: qa + "\n<style>短</style>", attachments: [])]),
        ]
        let anthropic = AnthropicProvider.anthropicWire(messages, toolNames: [AskUserTool.toolName])
        let merged = try XCTUnwrap(anthropic.last?["content"] as? [[String: Any]])
        XCTAssertEqual(merged.map { $0["type"] as? String }, ["tool_result", "text", "text"])
        XCTAssertEqual(merged.last?["text"] as? String, "<style>短</style>", "Q/A 只在 tool_result 里出现一次")

        let openAI = OpenAICompatibleProvider.openAIWire(messages, toolNames: [AskUserTool.toolName])
        XCTAssertEqual(openAI.last?["content"] as? String, "<style>短</style>")
    }

    func testAskAnswerRecorded() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [use("q", AskUserTool.toolName), result("q", "Q: 吃啥\nA: 面")]))
        XCTAssertEqual(rounds[0].askAnswer, "Q: 吃啥\nA: 面")
    }

    func testHistoryResultTruncationIsStableAndPointsToArchive() {
        let long = String(repeating: "字", count: 1000)   // 3000 字节
        let a = ToolReplay.historyResultText(long, archivePath: "tool-results/c/a-fs_search.txt")
        XCTAssertEqual(a, ToolReplay.historyResultText(long, archivePath: "tool-results/c/a-fs_search.txt"), "同一结果每轮字节一样")
        XCTAssertTrue(a.hasPrefix(String(repeating: "字", count: 682)))
        XCTAssertTrue(a.contains("原结果在 tool-results/c/a-fs_search.txt"), a)
        XCTAssertTrue(ToolReplay.historyResultText(long, archivePath: nil).hasSuffix("需要时重新调用]"))
        XCTAssertEqual(ToolReplay.historyResultText("短", archivePath: "x"), "短")
        let offloaded = long + "\n…全文在 tool-results/c/z-mcp.txt"
        XCTAssertTrue(ToolReplay.historyResultText(offloaded, archivePath: nil).contains("tool-results/c/z-mcp.txt"), "已外置的沿用原路径")
    }

    // MARK: 文字退路 / 副模型

    func testTextFallbackMovesRecordToNextUser() {
        let rounds = ToolReplay.rounds(from: [use("a", "fs_search", #"{"keyword":"密码"}"#), result("a", "x")]) ?? []
        var assistant = PromptMessage(role: "assistant", content: "", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false)
        assistant.toolRounds = rounds
        let user = PromptMessage(role: "user", content: "嘿嘿", source: .chatHistory, nodeId: "u2", pinnedToSystemPrefix: false)
        let out = ToolReplay.textFallback([assistant, user])
        XCTAssertEqual(out[0].content, ToolReplay.toolOnlyPlaceholder)
        XCTAssertTrue(out[0].toolRounds.isEmpty)
        XCTAssertTrue(out[1].content.hasPrefix("〔系统记录"), out[1].content)
        XCTAssertTrue(out[1].content.contains(#"fs_search("密码")"#))
        XCTAssertTrue(out[1].content.hasSuffix("\n嘿嘿"))
        XCTAssertTrue(RequestBodyDiag.fakeMarkers(in: out[0].content).isEmpty, "assistant 正文里不再有任何工具标记")
    }

    func testSideModelText() {
        let rounds = ToolReplay.rounds(from: [use("a", "fs_read", #"{"path":"a.md"}"#), result("a", "x")]) ?? []
        XCTAssertEqual(ToolReplay.sideModelText(content: "好", rounds: rounds), "[调用了 fs_read(a.md)]\n好")
        XCTAssertEqual(ToolReplay.sideModelText(content: "好", rounds: []), "好")
    }

    // MARK: 线上

    private func wireMessages(final: String, nextUser: String, rounds: [ToolReplayRound]) -> [PromptWire.Message] {
        [PromptWire.Message(role: "user", chunks: [(text: "发一下那个卡", attachments: [])]),
         PromptWire.Message(role: "assistant", chunks: [(text: final, attachments: [])], toolRounds: rounds),
         PromptWire.Message(role: "user", chunks: [(text: nextUser, attachments: [])])]
    }

    func testAnthropicExpansion() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [.text("我找找"), use("a", "fs_search", #"{"keyword":"密码"}"#), result("a", "命中")]))
        let out = AnthropicProvider.anthropicWire(wireMessages(final: "给你", nextUser: "嘿嘿", rounds: rounds), toolNames: ["fs_search"])
        XCTAssertEqual(out.map { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        let call = try XCTUnwrap((out[1]["content"] as? [[String: Any]]))
        XCTAssertEqual(call.map { $0["type"] as? String }, ["text", "tool_use"])
        XCTAssertEqual((call[1]["input"] as? [String: Any])?["keyword"] as? String, "密码")
        let res = try XCTUnwrap(out[2]["content"] as? [[String: Any]])
        XCTAssertEqual(res.first?["tool_use_id"] as? String, "a")
        XCTAssertEqual(out[3]["content"] as? String, "给你")
    }

    func testAnthropicToolOnlyMergesNextUserAndDedupesAsk() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [use("q", AskUserTool.toolName), result("q", "Q: 吃啥\nA: 面")]))
        let out = AnthropicProvider.anthropicWire(wireMessages(final: "", nextUser: "Q: 吃啥\nA: 面", rounds: rounds),
                                                  toolNames: [AskUserTool.toolName])
        XCTAssertEqual(out.map { $0["role"] as? String }, ["user", "assistant", "user"], "Q/A 只在 tool_result 里出现一次")

        let rounds2 = try XCTUnwrap(ToolReplay.rounds(from: [use("a", "fs_read"), result("a", "x")]))
        let out2 = AnthropicProvider.anthropicWire(wireMessages(final: "", nextUser: "下一条", rounds: rounds2), toolNames: ["fs_read"])
        XCTAssertEqual(out2.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let merged = try XCTUnwrap(out2[2]["content"] as? [[String: Any]])
        XCTAssertEqual(merged.map { $0["type"] as? String }, ["tool_result", "text"], "tool_result 排最前，后面接用户的话")
    }

    func testTuckedToolRewrappedAsInvoke() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [use("a", "local_twitter", #"{"q":"x"}"#), result("a", "ok")]))
        let out = AnthropicProvider.anthropicWire(wireMessages(final: "好", nextUser: "嗯", rounds: rounds),
                                                  toolNames: [MetaTools.invokeName])
        let block = try XCTUnwrap((out[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(block["name"] as? String, MetaTools.invokeName)
        XCTAssertEqual((block["input"] as? [String: Any])?["name"] as? String, "local_twitter")
    }

    func testOpenAIExpansion() throws {
        let rounds = try XCTUnwrap(ToolReplay.rounds(from: [use("a", "fs_read"), result("a", "x")]))
        let out = OpenAICompatibleProvider.openAIWire(wireMessages(final: "好", nextUser: "嗯", rounds: rounds), toolNames: ["fs_read"])
        XCTAssertEqual(out.map { $0["role"] as? String }, ["user", "assistant", "tool", "assistant", "user"])
        XCTAssertEqual((out[1]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, "a")
        XCTAssertEqual(out[2]["tool_call_id"] as? String, "a")
    }

    /// 历史里调过这一轮没下发的工具（关了的 MCP）：只那条退纯文字，别的照发真块
    func testUnknownToolNameFallsBackForThatMessageOnly() throws {
        var gone = PromptMessage(role: "assistant", content: "查了", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false)
        gone.toolRounds = ToolReplay.rounds(from: [use("a", "old_mcp_tool"), result("a", "x")]) ?? []
        var known = PromptMessage(role: "assistant", content: "读了", source: .chatHistory, nodeId: "a2", pinnedToSystemPrefix: false)
        known.toolRounds = ToolReplay.rounds(from: [use("b", "fs_read"), result("b", "y")]) ?? []
        let user = { (id: String) in PromptMessage(role: "user", content: "嗯", source: .chatHistory, nodeId: id, pinnedToSystemPrefix: false) }
        let out = ToolReplay.wireOrdered([user("u1"), gone, user("u2"), known, user("u3")], toolNames: ["fs_read"])
        XCTAssertTrue(out[1].toolRounds.isEmpty)
        XCTAssertTrue(out[2].content.hasPrefix("〔系统记录"))
        XCTAssertEqual(out[3].toolRounds.count, 1)
        XCTAssertEqual(out[4].content, "嗯")
    }

    /// #093：抽屉 / 权限关掉的工具（这一轮调不到）那条退纯文字；收起的留着，交给 wireCall 包回 tool_invoke
    func testOfferedOnlyFallsBackOnlyForToolsNotOfferedThisTurn() throws {
        var off = PromptMessage(role: "assistant", content: "写了", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false)
        off.toolRounds = ToolReplay.rounds(from: [use("a", "fs_write", #"{"path":"x.md"}"#), result("a", "ok")]) ?? []
        var tucked = PromptMessage(role: "assistant", content: "掷了", source: .chatHistory, nodeId: "a2", pinnedToSystemPrefix: false)
        tucked.toolRounds = ToolReplay.rounds(from: [use("b", "roll_dice"), result("b", "6")]) ?? []
        let user = { (id: String) in PromptMessage(role: "user", content: "嗯", source: .chatHistory, nodeId: id, pinnedToSystemPrefix: false) }
        let toolNames: Set<String> = ["fs_read", MetaTools.invokeName]
        let offered = toolNames.union(["roll_dice"])
        let out = ToolReplay.offeredOnly([user("u1"), off, user("u2"), tucked, user("u3")], offered: offered)
        XCTAssertTrue(out[1].toolRounds.isEmpty, "关掉的不包成 tool_invoke")
        XCTAssertEqual(out[1].content, "写了")
        XCTAssertTrue(out[2].content.hasPrefix("〔系统记录"), out[2].content)
        XCTAssertTrue(out[2].content.contains("fs_write"))
        XCTAssertEqual(out[3].toolRounds.count, 1, "收起的不退")
        XCTAssertEqual(out[4].content, "嗯")
        let wired = ToolReplay.wireOrdered(out, toolNames: toolNames)
        XCTAssertEqual(wired[3].toolRounds.count, 1)
        XCTAssertEqual(ToolReplay.wireCall(wired[3].toolRounds[0].calls[0], toolNames: toolNames).name, MetaTools.invokeName)
        // 以前（没有这一步）：关掉的 fs_write 会被包成 tool_invoke
        XCTAssertEqual(ToolReplay.wireCall(off.toolRounds[0].calls[0], toolNames: toolNames).name, MetaTools.invokeName)
        // 都调得到 / 没有工具回合 → 原样
        let all = [user("u1"), off, user("u2")]
        XCTAssertEqual(ToolReplay.offeredOnly(all, offered: ["fs_write"]).map(\.content), all.map(\.content))
        XCTAssertEqual(ToolReplay.offeredOnly(all, offered: ["fs_write"])[1].toolRounds.count, 1)
        XCTAssertEqual(ToolReplay.offeredOnly([user("u1")], offered: []).map(\.content), ["嗯"])
    }

    /// astra #2：MCP 经 tool_invoke 调的，节点里存的是外层 tool_invoke——看包着的 MCP 这一轮还在不在
    func testOfferedOnlyLooksInsideStoredToolInvoke() {
        var viaInvoke = PromptMessage(role: "assistant", content: "查了", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false)
        viaInvoke.toolRounds = ToolReplay.rounds(from: [use("a", MetaTools.invokeName, #"{"name":"current_time","arguments":{}}"#), result("a", "12 点")]) ?? []
        let user = PromptMessage(role: "user", content: "嗯", source: .chatHistory, nodeId: "u2", pinnedToSystemPrefix: false)
        let gone = ToolReplay.offeredOnly([viaInvoke, user], offered: [MetaTools.invokeName, "ocr_image"])
        XCTAssertTrue(gone[0].toolRounds.isEmpty, "MCP 关了（不在目录里）→ 退纯文字")
        let kept = ToolReplay.offeredOnly([viaInvoke, user], offered: [MetaTools.invokeName, "current_time"])
        XCTAssertEqual(kept[0].toolRounds.count, 1, "还在目录里 → 照旧回放 tool_invoke")
        let decorated = ToolReplay.isOffered(ToolCallBlock(id: "b", name: MetaTools.invokeName, argumentsJSON: #"{"name":"mcp:时钟/current_time"}"#),
                                             offered: [MetaTools.invokeName, "current_time"])
        XCTAssertTrue(decorated, "名字带命名空间照 MetaTools.resolve 的容错认")
        XCTAssertTrue(ToolReplay.isOffered(ToolCallBlock(id: "c", name: MetaTools.invokeName, argumentsJSON: "坏的"), offered: [MetaTools.invokeName]),
                      "读不出名字的不动")
    }

    func testNoClientToolsFallsBackToTextInBody() throws {
        var assistant = PromptMessage(role: "assistant", content: "给你", source: .chatHistory, nodeId: "a1", pinnedToSystemPrefix: false)
        assistant.toolRounds = ToolReplay.rounds(from: [use("a", "fs_read"), result("a", "x")]) ?? []
        let ordered = [PromptMessage(role: "user", content: "发", source: .chatHistory, nodeId: "u1", pinnedToSystemPrefix: false),
                       assistant,
                       PromptMessage(role: "user", content: "嗯", source: .chatHistory, nodeId: "u2", pinnedToSystemPrefix: false)]
        let body = AnthropicProvider.buildRequestBody(ordered: ordered, model: "claude-x", samplingParams: nil, tools: nil)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1]["content"] as? String, "给你")
        XCTAssertTrue((messages[2]["content"] as? String)?.hasPrefix("〔系统记录") == true)
    }
}
