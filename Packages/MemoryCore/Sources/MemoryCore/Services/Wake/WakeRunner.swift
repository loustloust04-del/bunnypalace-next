import Foundation

/// 醒来能用的一个工具：执行 + 怎么记成人话（plan §3.3「每个工具外面包一层」）
public struct WakeTool: Sendable {
    public let spec: AgentToolSpec
    /// 工具次数那栏的人话名：「搜索」「读网页」
    public let label: String
    /// 参数 JSON → 这一步的人话动作：「搜索『AI news today』」
    public let describe: @Sendable (String) -> String
    /// 这一步碰到的来源（网址）；nil = 不算来源
    public let source: @Sendable (_ arguments: String, _ output: AgentToolOutput) -> WakeSource?
    /// 做完截一张（浏览器类）；nil = 不截
    public let snapshot: (@Sendable () async -> Data?)?
    public let run: @Sendable (String) async -> AgentToolOutput

    public init(spec: AgentToolSpec, label: String, describe: @escaping @Sendable (String) -> String,
                source: @escaping @Sendable (String, AgentToolOutput) -> WakeSource? = { _, _ in nil },
                snapshot: (@Sendable () async -> Data?)? = nil,
                run: @escaping @Sendable (String) async -> AgentToolOutput) {
        self.spec = spec
        self.label = label
        self.describe = describe
        self.source = source
        self.snapshot = snapshot
        self.run = run
    }
}

/// 跑一次（plan §3.3）：小 pi 的 AgentLoop + 每一步记录 + finish / note_for_next；不认识具体工具，也不碰界面
public enum WakeRunner {
    public static let finishName = "finish"
    public static let noteName = "note_for_next"

    public struct Input: Sendable {
        public var task: WakeTask
        public var runId: String
        public var trigger: WakeTrigger
        public var system: String
        public var opening: String
        public var tools: [WakeTool]
        public var withheld: [String]
        public var caller: any ToolModelCaller
        public var maxRounds: Int
        /// 每轮前问一次（花费 / 被打断）
        public var allow: @Sendable () async -> Bool
        public var store: WakeStore?
        public var now: @Sendable () -> Date

        public init(task: WakeTask, runId: String = UUID().uuidString, trigger: WakeTrigger, system: String, opening: String,
                    tools: [WakeTool], withheld: [String] = [], caller: any ToolModelCaller, maxRounds: Int,
                    allow: @escaping @Sendable () async -> Bool = { true }, store: WakeStore?, now: @escaping @Sendable () -> Date = { Date() }) {
            self.task = task
            self.runId = runId
            self.trigger = trigger
            self.system = system
            self.opening = opening
            self.tools = tools
            self.withheld = withheld
            self.caller = caller
            self.maxRounds = maxRounds
            self.allow = allow
            self.store = store
            self.now = now
        }
    }

    /// 跑完回一份执行记录（还没存、没交付；status ok = 它用 finish 交了结果）。note = 它留给下次的话
    public static func run(_ input: Input) async -> (run: WakeRun, note: String?) {
        let recorder = Recorder()
        let started = input.now()
        var tools = input.tools.map { tool in
            AgentTool(name: tool.spec.name, description: tool.spec.description, schema: tool.spec.schema) { args in
                let out = await tool.run(args)
                let index = await recorder.nextIndex()
                var shot: String?
                if !out.isError, let snapshot = tool.snapshot, let jpeg = await snapshot(), let store = input.store {
                    shot = try? store.saveShot(jpeg, runId: input.runId, index: index)
                }
                let source = out.isError ? nil : tool.source(args, out)
                await recorder.record(WakeStep(time: input.now(), tool: tool.spec.name, action: tool.describe(args), ok: !out.isError,
                                               result: String(out.content.prefix(300)), url: source?.url, shot: shot),
                                      label: tool.label, source: source)
                return out
            }
        }
        tools.append(AgentTool(name: finishName, description: Self.finishDescription, schema: Self.finishSchema) { args in
            let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
            let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !summary.isEmpty else { return AgentToolOutput("summary 不能空：用一句话说这次做成了什么", isError: true) }
            let message = (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            await recorder.finish(summary: summary, message: message?.isEmpty == true ? nil : message)
            return AgentToolOutput("交了", finished: summary)
        })
        tools.append(AgentTool(name: noteName, description: Self.noteDescription, schema: Self.noteSchema) { args in
            let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
            let note = ((obj["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            await recorder.setNote(String(note.prefix(300)))
            return AgentToolOutput("记下了，下次醒来会看到")
        })

        let outcome = await AgentLoop.run(
            system: input.system, opening: input.opening, tools: tools, caller: input.caller,
            limits: OrganizeAgent.Limits(rounds: max(input.maxRounds, 4), contextChars: 60_000, resultChars: 12_000),
            notes: AgentLoop.Notes(
                closingTools: [finishName, noteName],
                closing: "轮数快用完了：现在就用 finish 交结果（summary 一句话说做成了什么；要告诉她的话写在 message）。",
                truncated: "上一条写太长被截断了，短一点再来。",
                idle: "你没调工具。做完了就用 finish 交结果；还要做就继续调工具。",
                elided: "（早先的工具结果太长，已省略）"),
            allow: input.allow)

        let snap = await recorder.snapshot()
        var run = WakeRun(id: input.runId, taskId: input.task.id, taskTitle: input.task.title, startedAt: started,
                          endedAt: input.now(), trigger: input.trigger, status: .ok,
                          summary: snap.summary, message: snap.message,
                          inputTokens: outcome.inputTokens, outputTokens: outcome.outputTokens, rounds: outcome.rounds.count,
                          sources: snap.sources, tools: snap.tools, steps: snap.steps, withheldTools: input.withheld)
        switch outcome.stop {
        case .finished: break
        case .cancelled:
            run.status = .interrupted
            run.statusNote = "被打断了"
        case .budget:
            run.status = .failed
            run.statusNote = "到花费上限，没交结果就停了"
        case .failed:
            run.status = .failed
            run.statusNote = "出错：\(outcome.error ?? "模型调用失败")"
        default:
            run.status = .failed
            run.statusNote = "到轮数上限还没交结果"
        }
        return (run, snap.note)
    }

    static let finishDescription = """
    这次的活做完了就调它交结果（调了就结束这次醒来）。summary：一句话说这次做成了什么（给 heartbeat 看）。\
    message：要告诉她的话（早报正文、提醒、问候），按你平时跟她说话的样子写；这次没什么要告诉她就不填。
    """
    static let finishSchema = #"{"type":"object","properties":{"summary":{"type":"string","description":"一句话：这次做成了什么"},"message":{"type":"string","description":"要发给她的话；没有就不填"}},"required":["summary"]}"#

    static let noteDescription = "给下次醒来的自己留一句话（≤300 字），比如「今天报过 xx，明天别重复」。会覆盖上次留的。"
    static let noteSchema = #"{"type":"object","properties":{"note":{"type":"string","description":"留给下次的话"}},"required":["note"]}"#

    /// 一次执行里收集的东西（工具可能并发回调，放 actor 里）
    actor Recorder {
        private var steps: [WakeStep] = []
        private var sources: [WakeSource] = []
        private var counts: [(name: String, label: String, count: Int)] = []
        private var summary: String?
        private var message: String?
        private var note: String?
        private var index = 0

        func nextIndex() -> Int {
            index += 1
            return index
        }

        func record(_ step: WakeStep, label: String, source: WakeSource?) {
            steps.append(step)
            if let i = counts.firstIndex(where: { $0.name == step.tool }) { counts[i].count += 1 } else { counts.append((step.tool, label, 1)) }
            if let source, !sources.contains(where: { $0.url == source.url }) { sources.append(source) }
        }

        func finish(summary: String, message: String?) {
            self.summary = summary
            self.message = message
        }

        func setNote(_ note: String) { self.note = note.isEmpty ? nil : note }

        func snapshot() -> (steps: [WakeStep], sources: [WakeSource], tools: [WakeToolCount], summary: String?, message: String?, note: String?) {
            (steps, sources, counts.map { WakeToolCount(name: $0.name, label: $0.label, count: $0.count) }, summary, message, note)
        }
    }
}
