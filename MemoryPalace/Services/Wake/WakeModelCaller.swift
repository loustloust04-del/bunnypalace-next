import Foundation
import MemoryCore

/// 小 pi 循环在 app 里的模型调用口（plan-wake-heartbeat H2；research-small-pi 第 5 条）：
/// `AgentTurn` 换成 app 现有的「历史 + 工具回合」，走 `AssistantCloudBackend`（= ProviderRouter，账本记 `.wake`）。
/// 带签名的思考块：每轮回来的原样内容块按这一轮第一个工具调用 id 记下，下一轮拼 `ToolTurn` 时原样带回去
final class WakeModelCaller: ToolModelCaller, @unchecked Sendable {
    private let model: ProviderModel
    private let providerManager: ProviderManager
    private let usage: UsageContext
    @MainActor private var extras: [String: AssistantTurnExtras] = [:]
    @MainActor private var backend: AssistantCloudBackend?
    /// 这次醒来一共花了多少（每轮从账本那一行加）
    @MainActor private(set) var costUSD: Double = 0

    init(model: ProviderModel, providerManager: ProviderManager, usage: UsageContext) {
        self.model = model
        self.providerManager = providerManager
        self.usage = usage
    }

    func step(system: String, turns: [AgentTurn], tools: [AgentToolSpec]) async throws -> AgentStep {
        try await stepOnMain(system: system, turns: turns, tools: tools)
    }

    @MainActor func cancel() { backend?.cancel() }

    @MainActor
    private func stepOnMain(system: String, turns: [AgentTurn], tools: [AgentToolSpec]) async throws -> AgentStep {
        let (history, toolTurns) = Self.wire(turns, extras: extras)
        let anthropic = providerManager.provider(for: model)?.type == .anthropic
        let request = AssistantBackendRequest(system: system, history: history,
                                              tools: tools.map { Self.render($0, anthropic: anthropic) }, toolTurns: toolTurns)
        let backend = AssistantCloudBackend(model: model, providerManager: providerManager, usage: usage)
        self.backend = backend
        var text = ""
        let event: AssistantBackendEvent = try await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                var resumed = false
                backend.run(request) { event in
                    switch event {
                    case .token(let t): text += t
                    case .toolCalls, .finished, .failed:
                        guard !resumed else { return }
                        resumed = true
                        cont.resume(returning: event)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in backend.cancel() }
        }
        try Task.checkCancellation()
        costUSD += backend.lastCostUSD ?? 0
        let record = backend.lastUsage
        let usage = record.map { AgentUsage(input: $0.input, output: $0.output, cacheRead: $0.cacheRead) }
        switch event {
        case .toolCalls(let calls):
            if let first = calls.first, let turnExtras = backend.lastTurnExtras { extras[first.id] = turnExtras }
            return AgentStep(text: text, calls: calls.map { AgentToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON) },
                             usage: usage, stop: "tool_use")
        case .finished(let full):
            return AgentStep(text: full, usage: usage, stop: "end_turn")
        case .failed(let message):
            throw WakeModelError(message: message)
        case .token:
            throw WakeModelError(message: "没有收到结束事件")
        }
    }

    /// AgentTurn 序列 → 第一条 user 进历史；之后每对「带调用的 assistant + 结果」= 一个 ToolTurn；
    /// 没调工具的回话和随后的提醒挂到前一个 ToolTurn 的 followUps（还没有工具回合时直接进历史）
    static func wire(_ turns: [AgentTurn], extras: [String: AssistantTurnExtras]) -> (history: [(role: String, content: String)], toolTurns: [ToolTurn]) {
        var history: [(role: String, content: String)] = []
        var toolTurns: [ToolTurn] = []
        var pending: (text: String, calls: [AgentToolCall])?
        var reply: String?
        for turn in turns {
            switch turn {
            case .user(let text):
                if toolTurns.isEmpty {
                    if let r = reply { history.append((role: "assistant", content: r)) }
                    history.append((role: "user", content: text))
                } else {
                    toolTurns[toolTurns.count - 1].followUps.append(ToolFollowUp(reply: reply ?? "", note: text))
                }
                reply = nil
            case .assistant(let text, let calls, _):
                if calls.isEmpty { reply = text } else { pending = (text, calls) }
            case .toolResults(let results):
                guard let p = pending else { continue }
                pending = nil
                let turnExtras = p.calls.first.flatMap { extras[$0.id] }
                toolTurns.append(ToolTurn(
                    calls: p.calls.map { ToolCallBlock(id: $0.id, name: $0.name, argumentsJSON: $0.arguments) },
                    results: results.map { ToolResultBlock(toolUseId: $0.callId, text: $0.content, isError: $0.isError) },
                    assistantContent: turnExtras?.assistantContent, thinkingTokens: turnExtras?.thinkingTokens,
                    reasoning: turnExtras?.reasoning, text: p.text.isEmpty ? nil : p.text))
            }
        }
        return (history, toolTurns)
    }

    /// 小 pi 的 schema 文本 → 两家的工具定义（同 ToolSchemaRenderer）
    static func render(_ spec: AgentToolSpec, anthropic: Bool) -> [String: Any] {
        let schema = (try? JSONSerialization.jsonObject(with: Data(spec.schema.utf8))) as? [String: Any] ?? [:]
        let def = ToolDefinition(name: spec.name, description: spec.description,
                                 properties: schema["properties"] as? [String: Any] ?? [:],
                                 required: schema["required"] as? [String] ?? [])
        return anthropic ? ToolSchemaRenderer.anthropic(def) : ToolSchemaRenderer.openAI(def)
    }
}

struct WakeModelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
