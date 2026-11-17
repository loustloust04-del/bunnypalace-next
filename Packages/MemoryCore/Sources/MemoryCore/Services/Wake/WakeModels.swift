import Foundation

// 自唤醒 + heartbeat（docs/plan-wake-heartbeat.md）：AI 自己的任务、每次执行、每一步。
// 一级 = WakeTask（人页任务列表）；二级 = WakeRun（每次执行的摘要）；三级 = WakeStep（每一步 + 截图）

/// 什么时候醒：每天（可限星期几）几点，或者某个时刻一次
public enum WakeSchedule: Codable, Equatable, Sendable {
    /// weekdays：Calendar 的星期（1 = 周日 … 7 = 周六）；nil = 每天
    case daily(hour: Int, minute: Int, weekdays: [Int]?)
    case once(Date)

    public var isOnce: Bool { if case .once = self { return true } else { return false } }
}

/// 谁建的
public enum WakeCreator: Codable, Equatable, Sendable {
    case user
    /// AI 在这个对话里建的
    case ai(conversationId: String)
}

/// 做完怎么告诉她（每个任务自己选，粟粟 11-11 Q3）
public enum WakeNotify: Codable, Equatable, Sendable {
    /// 发到这个对话（插一条 AI 消息），push = 再推一条通知
    case conversation(id: String, push: Bool)
    /// 只记在 heartbeat
    case heartbeatOnly
    /// 发到这一层的 mainsession（plan-floor-main-thread，新任务默认）
    case mainSession(push: Bool)
}

public enum WakeRunStatus: String, Codable, Sendable {
    case ok, failed, skipped, interrupted
}

public enum WakeTrigger: String, Codable, Sendable {
    /// 准点（保活叫醒时正好到点）
    case scheduled
    /// 错过了，app 醒来补一次
    case catchUp
    /// 她在 heartbeat 里点「现在跑一次」
    case manual
}

public struct WakeTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// 醒来要做的事（写给醒来的自己）
    public var instruction: String
    public var schedule: WakeSchedule
    public var createdBy: WakeCreator
    public var notify: WakeNotify
    /// 上次留给这次的话（≤300 字）
    public var note: String?
    public var enabled: Bool
    public var createdAt: Date
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var lastStatus: WakeRunStatus?
    /// 连续失败几次（到 3 就自动停，plan §3.2）
    public var failureStreak: Int
    /// 一次性任务跑完了（挪进「已完成」）
    public var done: Bool
    /// 这个任务用哪个模型（ProviderModel id）；nil = 跟对话 → 人页 → 全局（老任务没有这个字段）
    public var modelId: String? = nil

    public init(id: String = UUID().uuidString, title: String, instruction: String, schedule: WakeSchedule,
                createdBy: WakeCreator, notify: WakeNotify, note: String? = nil, enabled: Bool = true,
                createdAt: Date = Date(), nextRunAt: Date? = nil, lastRunAt: Date? = nil, lastStatus: WakeRunStatus? = nil,
                failureStreak: Int = 0, done: Bool = false) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.schedule = schedule
        self.createdBy = createdBy
        self.notify = notify
        self.note = note
        self.enabled = enabled
        self.createdAt = createdAt
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.failureStreak = failureStreak
        self.done = done
    }

    /// 还会跑：开着、没做完、排了下次
    public var isActive: Bool { enabled && !done && nextRunAt != nil }
}

public struct WakeSource: Codable, Equatable, Hashable, Sendable {
    public var url: String
    public var title: String?

    public init(url: String, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

public struct WakeToolCount: Codable, Equatable, Sendable {
    public var name: String
    /// 人话：「搜索」「读网页」
    public var label: String
    public var count: Int

    public init(name: String, label: String, count: Int) {
        self.name = name
        self.label = label
        self.count = count
    }
}

public struct WakeStep: Codable, Equatable, Sendable {
    public var time: Date
    public var tool: String
    /// 人话动作：「搜索『AI news today』」「打开 openai.com/blog/…」
    public var action: String
    public var ok: Bool
    /// 工具回的结果前 300 字
    public var result: String
    public var url: String?
    /// 截图文件名（shots/<runId>/ 下）；nil = 这一步没截（不是浏览器类，或在后台截不到）
    public var shot: String?

    public init(time: Date, tool: String, action: String, ok: Bool, result: String, url: String? = nil, shot: String? = nil) {
        self.time = time
        self.tool = tool
        self.action = action
        self.ok = ok
        self.result = result
        self.url = url
        self.shot = shot
    }
}

public struct WakeRun: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var taskId: String
    public var taskTitle: String
    public var startedAt: Date
    public var endedAt: Date?
    public var trigger: WakeTrigger
    public var status: WakeRunStatus
    /// 没成 / 跳过的原因（人话）
    public var statusNote: String?
    /// 模型 finish 时交的一句话摘要
    public var summary: String?
    /// 发给她的话（finish 的 message）
    public var message: String?
    /// 插进对话的那条消息
    public var deliveredConversationId: String?
    public var deliveredMessageId: String?
    public var notified: Bool
    public var usd: Double?
    public var inputTokens: Int
    public var outputTokens: Int
    public var rounds: Int
    /// 由代码从每一步汇总，不让模型自己报
    public var sources: [WakeSource]
    public var tools: [WakeToolCount]
    public var steps: [WakeStep]
    /// 这次没给的工具（要她点头的那些，后台没人点卡）
    public var withheldTools: [String]

    public init(id: String = UUID().uuidString, taskId: String, taskTitle: String, startedAt: Date, endedAt: Date? = nil,
                trigger: WakeTrigger, status: WakeRunStatus, statusNote: String? = nil, summary: String? = nil,
                message: String? = nil, deliveredConversationId: String? = nil, deliveredMessageId: String? = nil,
                notified: Bool = false, usd: Double? = nil, inputTokens: Int = 0, outputTokens: Int = 0, rounds: Int = 0,
                sources: [WakeSource] = [], tools: [WakeToolCount] = [], steps: [WakeStep] = [], withheldTools: [String] = []) {
        self.id = id
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trigger = trigger
        self.status = status
        self.statusNote = statusNote
        self.summary = summary
        self.message = message
        self.deliveredConversationId = deliveredConversationId
        self.deliveredMessageId = deliveredMessageId
        self.notified = notified
        self.usd = usd
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.rounds = rounds
        self.sources = sources
        self.tools = tools
        self.steps = steps
        self.withheldTools = withheldTools
    }

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}
