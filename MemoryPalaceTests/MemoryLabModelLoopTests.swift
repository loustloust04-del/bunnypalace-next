import MemoryCore
import XCTest
@testable import 记忆花园

/// 记忆实验台问模型的小循环（plan-memory-lab §2 第 8 步），全用假的发送和假的 recall：不翻 / 翻一次 / 翻到上限 /
/// 工具回合到总上限 / 回了空的
@MainActor
final class MemoryLabModelLoopTests: XCTestCase {
    /// 假模型：按脚本一圈回一样；记下每一圈收到的工具来回和给没给工具
    private final class Script {
        var replies: [MemoryLabModelLoop.Reply]
        var seen: [(turns: [ToolTurn], offered: Bool)] = []

        init(_ replies: [MemoryLabModelLoop.Reply]) { self.replies = replies }

        var send: MemoryLabModelLoop.Send {
            { turns, offered in
                self.seen.append((turns, offered))
                return self.replies.isEmpty ? .init(kind: .failed("脚本用完了")) : self.replies.removeFirst()
            }
        }
    }

    private final class Recall {
        var arguments: [String] = []

        var execute: MemoryLabModelLoop.Execute {
            { json in
                self.arguments.append(json)
                return RecallTool.ExecResult(
                    text: "第 \(self.arguments.count) 次翻到：林栖在云桥城开了皮影小店", isError: false, hitMemoryIds: [UUID()],
                    read: .init(layer: "wiki页", target: "人/林栖", sourceVersion: "v1", status: "success", returnedCount: 1))
            }
        }
    }

    private func call(_ id: String, name: String = RecallTool.toolName, truncated: Bool = false) -> ToolCallBlock {
        ToolCallBlock(id: id, name: name, argumentsJSON: #"{"op":"search","query":"林栖","scope":"c","n":"\#(id)"}"#, truncated: truncated)
    }

    private func usage(input: Int, output: Int) -> UsageRecord {
        var row = UsageRecord(time: Date(), providerId: "card", providerName: "星砚的卡", providerType: "anthropic", model: "fictional",
                              input: input, output: output, cacheRead: 1, cacheWrite: 2, reasoning: 0, durationMs: 1, status: .ok,
                              kind: .memoryTrial, conversationId: nil, profileId: "floor", subscription: false, tokensOnly: false)
        row.costUSD = 0.001
        return row
    }

    func testNoRecallIsOneRequest() async {
        let script = Script([.init(kind: .text("还开着。"), usage: usage(input: 100, output: 5))])
        let recall = Recall()
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 3, turnId: "t1", send: script.send, execute: recall.execute)
        XCTAssertEqual(outcome.reply, "还开着。")
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.rounds.isEmpty)
        XCTAssertTrue(outcome.reads.isEmpty)
        XCTAssertTrue(recall.arguments.isEmpty)
        XCTAssertEqual(script.seen.count, 1)
        XCTAssertEqual(script.seen.first?.offered, true)
        XCTAssertEqual(outcome.usage, .init(requests: 1, input: 100, output: 5, cacheRead: 1, cacheWrite: 2, costUSD: 0.001))
    }

    /// 主动翻关着：不下发工具
    func testRecallOffNeverOffersTheTool() async {
        let script = Script([.init(kind: .text("不记得了。"))])
        let outcome = await MemoryLabModelLoop.run(recallTool: false, maximumCalls: 3, turnId: "t1", send: script.send, execute: Recall().execute)
        XCTAssertEqual(outcome.reply, "不记得了。")
        XCTAssertEqual(script.seen.map(\.offered), [false])
    }

    func testOneRecallRoundFeedsResultBackThenAnswers() async {
        let thinking: [[String: Any]] = [["type": "thinking", "thinking": "翻一下", "signature": "sig"],
                                         ["type": "tool_use", "id": "c1", "name": "recall", "input": ["op": "search"]]]
        let script = Script([
            .init(kind: .toolCalls([call("c1")]), assistantContent: thinking, thinkingTokens: 7, usage: usage(input: 100, output: 20)),
            .init(kind: .text("开了，在云桥城。"), usage: usage(input: 150, output: 10)),
        ])
        let recall = Recall()
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 3, turnId: "t1", send: script.send, execute: recall.execute)
        XCTAssertEqual(outcome.reply, "开了，在云桥城。")
        XCTAssertEqual(recall.arguments, [call("c1").argumentsJSON], "参数原样交给 recall")
        XCTAssertEqual(outcome.rounds.count, 1)
        XCTAssertEqual(outcome.rounds.first?.calls.first, .init(id: "c1", name: "recall", arguments: call("c1").argumentsJSON,
                                                                 result: "第 1 次翻到：林栖在云桥城开了皮影小店", isError: false))
        XCTAssertEqual(outcome.reads.count, 1)
        XCTAssertEqual(outcome.reads.first?.toolCallId, "c1")
        XCTAssertEqual(outcome.reads.first?.turnId, "t1")
        XCTAssertEqual(outcome.reads.first?.layer, "wiki页")
        XCTAssertEqual(outcome.reads.first?.status, "success")
        XCTAssertEqual(outcome.usage.requests, 2)
        XCTAssertEqual(outcome.usage.input, 250)

        // 第二圈：工具照给，带着第一圈的调用、回包、原样的思考块
        XCTAssertEqual(script.seen.count, 2)
        XCTAssertTrue(script.seen[0].turns.isEmpty)
        XCTAssertEqual(script.seen[1].offered, true)
        let turn = try? XCTUnwrap(script.seen[1].turns.first)
        XCTAssertEqual(script.seen[1].turns.count, 1)
        XCTAssertEqual(turn?.calls.map(\.id), ["c1"])
        XCTAssertEqual(turn?.results.map(\.toolUseId), ["c1"])
        XCTAssertEqual(turn?.results.first?.text, "第 1 次翻到：林栖在云桥城开了皮影小店")
        XCTAssertEqual(turn?.results.first?.isError, false)
        XCTAssertEqual(turn?.thinkingBlockCount, 1)
        XCTAssertEqual(turn?.thinkingTokens, 7)
    }

    /// 上限 2：第一圈一口气调三次 → 前两次执行、第三次不执行、回「到上限了」；下一圈工具照给（同真聊天），思考块照带
    func testCallsBeyondTheLimitGetTheLimitedReplyAndTheToolStaysOffered() async {
        let thinking: [[String: Any]] = [["type": "thinking", "thinking": "多翻几次", "signature": "sig"]]
        let script = Script([
            .init(kind: .toolCalls([call("c1"), call("c2"), call("c3")]), assistantContent: thinking),
            .init(kind: .text("翻到这些。")),
        ])
        let recall = Recall()
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 2, turnId: "t1", send: script.send, execute: recall.execute)
        XCTAssertEqual(outcome.reply, "翻到这些。")
        XCTAssertEqual(recall.arguments.count, 2, "recall 只执行到上限")
        XCTAssertEqual(outcome.rounds.first?.calls.map(\.isError), [false, false, true])
        XCTAssertEqual(outcome.rounds.first?.calls.last?.result?.contains("本轮 recall 已到 2 次"), true)
        XCTAssertEqual(outcome.reads.map(\.status), ["success", "success", "limited"])
        XCTAssertEqual(outcome.reads.last?.returnedCount, 0)
        XCTAssertEqual(script.seen.map(\.offered), [true, true], "到了 recall 上限，工具照给")
        XCTAssertEqual(script.seen[1].turns.first?.results.count, 3, "三个调用都有回包，配对不断")
        XCTAssertEqual(script.seen[1].turns.first?.thinkingBlockCount, 1)
    }

    /// 上限 2：一圈一次地翻，到了上限还接着调 → 那几次不执行、回「到上限了」，工具一直给；模型看到这句自己收尾
    func testOneCallPerRoundKeepsAnsweringLimitedUntilTheModelStops() async {
        let script = Script([
            .init(kind: .toolCalls([call("c1")])),
            .init(kind: .toolCalls([call("c2")])),
            .init(kind: .toolCalls([call("c3")])),
            .init(kind: .toolCalls([call("c4")])),
            .init(kind: .text("就这些。")),
        ])
        let recall = Recall()
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 2, turnId: "t1", send: script.send, execute: recall.execute)
        XCTAssertEqual(outcome.reply, "就这些。")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(script.seen.map(\.offered), [true, true, true, true, true])
        XCTAssertEqual(script.seen.map(\.turns.count), [0, 1, 2, 3, 4])
        XCTAssertEqual(recall.arguments.count, 2, "recall 只执行到上限")
        XCTAssertEqual(outcome.reads.map(\.status), ["success", "success", "limited", "limited"])
        XCTAssertEqual(outcome.rounds.map { $0.calls.map(\.isError) }, [[false], [false], [true], [true]])
        XCTAssertEqual(outcome.rounds.last?.calls.first?.result,
                       "在 wiki页 层 · 本次 0 条 · 下一步 下一轮继续\n本轮 recall 已到 2 次，目前读到 wiki页，余下可下一轮继续", "文字同真聊天那一句")
        XCTAssertEqual(script.seen[4].turns.last?.results.first?.isError, true)
        XCTAssertEqual(outcome.usage.requests, 5)
    }

    /// 工具回合的总上限（同真聊天，8 圈）：满了模型还要调工具 → 停在这，那几个调用不执行、不再问，记成没问成
    func testToolRoundsStopAtTheTotalLimit() async {
        XCTAssertEqual(MemoryLabModelLoop.maximumRounds, 8)
        let script = Script((1...12).map { .init(kind: .toolCalls([call("c\($0)")])) })
        let recall = Recall()
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 2, turnId: "t1", send: script.send, execute: recall.execute)
        XCTAssertNil(outcome.reply)
        XCTAssertEqual(outcome.error, "工具调用达到上限 8 轮，已停止")
        XCTAssertEqual(outcome.rounds.count, 8, "第九次要调的没执行、没进回合")
        XCTAssertEqual(script.seen.count, 9, "八圈工具之后只再问了一次")
        XCTAssertTrue(script.seen.allSatisfy(\.offered), "从头到尾工具都给，没有哪一圈把工具收走")
        XCTAssertEqual(recall.arguments.count, 2)
        XCTAssertEqual(outcome.reads.count, 8)

        // 上限能传（测试用小的）
        let short = Script((1...5).map { .init(kind: .toolCalls([call("d\($0)")])) })
        let stopped = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 5, maximumRounds: 3, turnId: "t2",
                                                   send: short.send, execute: Recall().execute)
        XCTAssertEqual(stopped.error, "工具调用达到上限 3 轮，已停止")
        XCTAssertEqual(short.seen.count, 4)
    }

    /// 最后那段字是空的（只有空白）不算回复：记成没问成，原因写明
    func testEmptyTextIsNotAReply() async {
        for blank in ["", "  \n\t "] {
            let direct = Script([.init(kind: .text(blank))])
            let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 3, turnId: "t1", send: direct.send, execute: Recall().execute)
            XCTAssertNil(outcome.reply)
            XCTAssertEqual(outcome.error, "模型回了空的")
            XCTAssertEqual(outcome.usage.requests, 1)
        }
        // 翻过之后回了空的：翻到的照留
        let after = Script([.init(kind: .toolCalls([call("c1")])), .init(kind: .text(""))])
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 3, turnId: "t1", send: after.send, execute: Recall().execute)
        XCTAssertNil(outcome.reply)
        XCTAssertEqual(outcome.error, "模型回了空的")
        XCTAssertEqual(outcome.rounds.count, 1)
        XCTAssertEqual(outcome.reads.count, 1)
        // 前后带空白的正常回复原样留着
        let padded = Script([.init(kind: .text("  还开着。\n"))])
        let kept = await MemoryLabModelLoop.run(recallTool: false, maximumCalls: 3, turnId: "t1", send: padded.send, execute: Recall().execute)
        XCTAssertEqual(kept.reply, "  还开着。\n")
        XCTAssertNil(kept.error)
    }

    /// 思考块被拒、去块重发成功的那一圈之后：前面几圈的思考块也不再带
    func testDroppedThinkingStaysDropped() async {
        let thinking: [[String: Any]] = [["type": "thinking", "thinking": "想", "signature": "sig"]]
        let script = Script([
            .init(kind: .toolCalls([call("c1")]), assistantContent: thinking),
            .init(kind: .toolCalls([call("c2")]), assistantContent: thinking, droppedThinking: true),
            .init(kind: .text("好。")),
        ])
        _ = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 5, turnId: "t1", send: script.send, execute: Recall().execute)
        XCTAssertEqual(script.seen[1].turns.map(\.thinkingBlockCount), [1])
        XCTAssertEqual(script.seen[2].turns.map(\.thinkingBlockCount), [0, 1])
    }

    func testFailureKeepsWhatWasAlreadyRead() async {
        let script = Script([.init(kind: .toolCalls([call("c1")])), .init(kind: .failed("401 没有钥匙"))])
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 3, turnId: "t1", send: script.send, execute: Recall().execute)
        XCTAssertNil(outcome.reply)
        XCTAssertEqual(outcome.error, "401 没有钥匙")
        XCTAssertEqual(outcome.rounds.count, 1)
        XCTAssertEqual(outcome.reads.count, 1)
        XCTAssertEqual(outcome.usage.requests, 2)
    }

    /// 没写完的调用、不认识的工具都不执行，但都有回包（调用和回包必须配对）
    func testTruncatedAndUnknownCallsAreAnsweredWithoutExecuting() async {
        let script = Script([
            .init(kind: .toolCalls([call("c1", truncated: true), call("c2", name: "fs_read")])),
            .init(kind: .text("好。")),
        ])
        let recall = Recall()
        let outcome = await MemoryLabModelLoop.run(recallTool: true, maximumCalls: 3, turnId: "t1", send: script.send, execute: recall.execute)
        XCTAssertTrue(recall.arguments.isEmpty)
        XCTAssertEqual(outcome.rounds.first?.calls.map(\.isError), [true, true])
        XCTAssertTrue(outcome.reads.isEmpty)
        XCTAssertEqual(script.seen[1].turns.first?.results.map(\.toolUseId), ["c1", "c2"])
        XCTAssertEqual(script.seen[1].offered, true, "没执行的不占次数")
    }
}
