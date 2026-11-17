import MemoryCore
import Foundation

/// 记忆实验台问模型的小循环（plan-memory-lab §2 第 8 步）：聊天的形状——模型回了字就是回复；
/// 调了 recall 就执行、回灌、再问。收尾照真聊天（主对话工具循环那一段，11-16 对过）：
/// - 一句话里 recall 最多执行 `maximumCalls` 次；超出的调用**不执行、照样给回包**（那句「本轮 recall 已到 N 次…」），
///   工具每一圈都照给——模型看到这句自己收尾。到了上限就把工具收走的话，还想接着翻的模型会回一段空的（11-16 😷 实测）。
/// - 工具回合最多 `maximumRounds` 圈；满了模型还要调工具，就停在这（不执行、不再问），记成没问成。
/// - 最后那段字是空的（只有空白）不算回复，记成没问成。
/// 只有两个口子，都能换成假的：`send` 问一次模型，`execute` 执行一次 recall。读回执只留在返回值里，不落任何地方；
/// 翻到的记忆条目不加访问数（真聊天在这里会 `recordAccess`，这里故意没有）。
@MainActor
enum MemoryLabModelLoop {
    struct Reply {
        enum Kind {
            case text(String)
            case toolCalls([ToolCallBlock])
            case failed(String)
        }

        var kind: Kind
        /// 带思考的模型：这一次回复的全部内容块原样，下一圈回传（plan-thinking §3.3）
        var assistantContent: [[String: Any]]? = nil
        var thinkingTokens: Int? = nil
        var reasoning: ReasoningCapture? = nil
        /// 这一次是「思考块被拒、去块重发」成功的：前面几圈之后也不带思考块
        var droppedThinking = false
        var usage: UsageRecord? = nil
    }

    /// 问一次模型：`toolTurns` = 前面几圈的工具来回，`offerTool` = 这一圈给不给 recall
    typealias Send = @MainActor (_ toolTurns: [ToolTurn], _ offerTool: Bool) async -> Reply
    typealias Execute = @MainActor (_ argumentsJSON: String) async -> RecallTool.ExecResult

    struct Outcome {
        var reply: String?
        var error: String?
        var rounds: [MemoryLabRecord.Round] = []
        var reads: [RecallReadReceipt] = []
        var usage = MemoryLabRecord.Usage(requests: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    }

    /// 工具回合的总上限：同真聊天的 `ConversationViewModel.maxToolRounds`（那个是 private，引用不到）
    static let maximumRounds = 8

    static func run(recallTool: Bool, maximumCalls: Int, maximumRounds: Int = maximumRounds, turnId: String,
                    send: Send, execute: Execute) async -> Outcome {
        var outcome = Outcome()
        var turns: [ToolTurn] = []
        var executed = 0
        var lastLayer = "原文"
        while true {
            let reply = await send(turns, recallTool)
            count(reply.usage, into: &outcome.usage)
            switch reply.kind {
            case .text(let text):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    outcome.error = "模型回了空的"
                } else {
                    outcome.reply = text
                }
                return outcome
            case .failed(let message):
                outcome.error = message
                return outcome
            case .toolCalls(let calls):
                guard recallTool else {
                    outcome.error = "没给工具，模型却调了工具"
                    return outcome
                }
                guard outcome.rounds.count < maximumRounds else {
                    outcome.error = "工具调用达到上限 \(maximumRounds) 轮，已停止"
                    return outcome
                }
                var results: [ToolResultBlock] = []
                var recorded: [MemoryLabRecord.Call] = []
                for call in calls {
                    let result: (text: String, isError: Bool)
                    if call.truncated {
                        result = ("\(call.name) 的参数写到一半被输出上限截断，未执行。请缩短参数再调。", true)
                    } else if call.name != RecallTool.toolName {
                        result = ("没有 \(call.name) 这个工具，这里只有 \(RecallTool.toolName)。", true)
                    } else if executed >= maximumCalls {
                        // 文字同真聊天连环 recall 熔断那一句
                        result = ("在 \(lastLayer) 层 · 本次 0 条 · 下一步 下一轮继续\n本轮 recall 已到 \(maximumCalls) 次，目前读到 \(lastLayer)，余下可下一轮继续", true)
                        outcome.reads.append(RecallReadReceipt(
                            toolCallId: call.id, turnId: turnId, layer: lastLayer, target: call.argumentsJSON, status: "limited",
                            returnedRange: [], next: .init(hasMore: false, cursorIssued: false), returnedCount: 0))
                    } else {
                        executed += 1
                        let done = await execute(call.argumentsJSON)
                        if let read = done.read {
                            lastLayer = read.layer
                            outcome.reads.append(RecallReadReceipt(
                                toolCallId: call.id, turnId: turnId, layer: read.layer, target: read.target,
                                sourceVersion: read.sourceVersion, status: read.status, returnedRange: read.returnedRange,
                                next: read.next, returnedCount: read.returnedCount, gate: read.gate))
                        }
                        result = (done.text, done.isError)
                    }
                    results.append(ToolResultBlock(toolUseId: call.id, text: result.text, isError: result.isError))
                    recorded.append(.init(id: call.id, name: call.name, arguments: call.argumentsJSON,
                                          result: result.text, isError: result.isError))
                }
                outcome.rounds.append(.init(calls: recorded))
                if reply.droppedThinking { turns = turns.map { $0.droppingThinking() } }
                turns.append(ToolTurn(calls: calls, results: results, assistantContent: reply.assistantContent,
                                      thinkingTokens: reply.thinkingTokens, reasoning: reply.reasoning))
            }
        }
    }

    private static func count(_ record: UsageRecord?, into usage: inout MemoryLabRecord.Usage) {
        usage.requests = (usage.requests ?? 0) + 1
        guard let record else { return }
        usage.input = (usage.input ?? 0) + record.input
        usage.output = (usage.output ?? 0) + record.output
        usage.cacheRead = (usage.cacheRead ?? 0) + record.cacheRead
        usage.cacheWrite = (usage.cacheWrite ?? 0) + record.cacheWrite
        if let cost = record.costUSD { usage.costUSD = (usage.costUSD ?? 0) + cost }
    }

    /// 真问模型的那个 `send`：把 `ProviderRouter.sendStreaming` 的回调包成一次 await。
    /// `router` 的用量要记在「试写」名下（调用方建 router 时给 `UsageContext(kind: .memoryTrial)`），不是「对话」。
    static func routerSend(router: ProviderRouter, model: ProviderModel, providers: ProviderManager, ordered: [PromptMessage],
                           sampling: SamplingParams, tools: [[String: Any]]) -> Send {
        let legacy = PromptMessage.legacyShape(ordered)
        return { toolTurns, offerTool in
            await withCheckedContinuation { (continuation: CheckedContinuation<Reply, Never>) in
                let once = Once()
                /// 回调可能不在主线程上：都回主线程再收，只收第一个终止事件
                func finish(_ kind: Reply.Kind, thinking: Int? = nil) {
                    Task { @MainActor in
                        guard !once.done else { return }
                        once.done = true
                        var reply = Reply(kind: kind, usage: router.lastUsageRecord)
                        if case .toolCalls = kind {
                            reply.assistantContent = router.lastAssistantBlocks.wireContent
                            reply.thinkingTokens = thinking
                            reply.reasoning = router.lastReasoning
                            reply.droppedThinking = router.lastRequestDroppedThinking
                        }
                        continuation.resume(returning: reply)
                    }
                }
                router.sendStreaming(
                    model: model, messages: legacy.messages, systemPrompt: legacy.systemPrompt, providerManager: providers,
                    samplingParams: sampling, tools: offerTool ? tools : nil, toolTurns: toolTurns, ordered: ordered,
                    onToken: { _ in },
                    onComplete: { text, _ in finish(.text(text)) },
                    onError: { message in finish(.failed(message)) },
                    onToolCalls: { calls, usage in finish(.toolCalls(calls), thinking: usage?.reasoningTokens) })
            }
        }
    }

    private final class Once {
        var done = false
    }
}
