import Foundation

// 通用的后台 agent 循环（plan-agent-workspace §2.1）。不认识任何具体工具：工具 = 说明 + 处理函数。
// 行为照 `OrganizeAgent.run`：轮数上限、裁上下文、截断提醒、不调工具时提醒一次、最后几轮只留交卷相关的工具。

public struct AgentToolOutput: Sendable, Equatable {
    public var content: String
    public var isError: Bool
    /// 非 nil = 这次调用成功结束了整份活（值是它给的一句总结）
    public var finished: String?

    public init(_ content: String, isError: Bool = false, finished: String? = nil) {
        self.content = content
        self.isError = isError
        self.finished = finished
    }
}

public struct AgentTool: Sendable {
    public let spec: AgentToolSpec
    /// 参数是模型给的 JSON 文本
    public let run: @Sendable (String) async -> AgentToolOutput

    public init(name: String, description: String, schema: String, run: @escaping @Sendable (String) async -> AgentToolOutput) {
        self.spec = AgentToolSpec(name: name, description: description, schema: schema)
        self.run = run
    }
}

public enum AgentLoop {
    public struct Notes: Sendable, Equatable {
        /// 最后三轮只留这几个工具
        public var closingTools: Set<String>
        public var closing: String
        public var truncated: String
        public var idle: String
        public var elided: String

        public init(closingTools: Set<String>, closing: String, truncated: String, idle: String, elided: String) {
            self.closingTools = closingTools
            self.closing = closing
            self.truncated = truncated
            self.idle = idle
            self.elided = elided
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var stop: OrganizeAgent.Stop
        public var summary: String?
        public var error: String?
        public var rounds: [OrganizeAgent.Round]

        public var inputTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.input ?? 0) } }
        public var outputTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.output ?? 0) } }
        public var cacheReadTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.cacheRead ?? 0) } }
    }

    /// `allow` 是调用方的预算闸：每轮发请求前问一次，false 就停
    public static func run(system: String, opening: String, tools: [AgentTool], caller: any ToolModelCaller,
                           limits: OrganizeAgent.Limits, notes: Notes,
                           allow: @escaping @Sendable () async -> Bool = { true }) async -> Outcome {
        var outcome = Outcome(stop: .rounds, summary: nil, error: nil, rounds: [])
        let byName = Dictionary(tools.map { ($0.spec.name, $0) }, uniquingKeysWith: { a, _ in a })
        let specs = tools.map(\.spec)
        var turns: [AgentTurn] = [.user(opening)]
        var nudged = false

        for round in 0..<limits.rounds {
            if Task.isCancelled { outcome.stop = .cancelled; break }
            guard await allow() else { outcome.stop = .budget; break }
            let closing = round >= limits.rounds - 3
            let available = closing ? specs.filter { notes.closingTools.contains($0.name) } : specs
            if closing, round == limits.rounds - 3 { turns.append(.user(notes.closing)) }
            let clock = ContinuousClock.now
            let step: AgentStep
            do {
                turns = OrganizeAgent.trimmed(turns, limit: limits.contextChars, elided: notes.elided)
                step = try await caller.step(system: system, turns: turns, tools: available)
            } catch is CancellationError {
                outcome.stop = .cancelled
                break
            } catch {
                outcome.stop = .failed
                outcome.error = error.localizedDescription
                break
            }
            let elapsed = ContinuousClock.now - clock
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            outcome.rounds.append(.init(tools: step.calls.map(\.name), usage: step.usage, ms: ms))
            turns.append(step.turn)

            if step.calls.isEmpty, step.truncated {
                turns.removeLast()
                turns.append(.user(notes.truncated))
                continue
            }
            if step.calls.isEmpty {
                if nudged { break }
                nudged = true
                turns.append(.user(notes.idle))
                continue
            }
            nudged = false
            var results: [AgentToolResult] = []
            var finished: String?
            for call in step.calls {
                let done = await byName[call.name]?.run(call.arguments) ?? AgentToolOutput("没有叫 \(call.name) 的工具", isError: true)
                let content = done.content.count > limits.resultChars
                    ? String(done.content.prefix(limits.resultChars)) + "\n…（太长，截断了；缩小范围再调）" : done.content
                results.append(AgentToolResult(callId: call.id, content: content, isError: done.isError))
                if let summary = done.finished { finished = summary }
            }
            turns.append(.toolResults(results))
            if let finished {
                outcome.stop = .finished
                outcome.summary = finished
                break
            }
        }
        return outcome
    }
}
