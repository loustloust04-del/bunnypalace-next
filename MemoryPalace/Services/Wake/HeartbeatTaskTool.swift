import Foundation
import MemoryCore

/// 聊天里让 AI 自己建任务（plan-wake-heartbeat §4）：一个工具用 action 分 create / update / pause / resume / delete / list。
/// 数值范围代码卡死：一个人最多 10 个、一次性最多排到 30 天后、落在安静时段的挪到安静时段结束（回话里告诉 AI）
enum HeartbeatTaskTool {
    static let name = "heartbeat_task"

    static var definition: ToolDefinition {
        ToolDefinition(name: name, description: """
        管你自己的任务：到点你会自己醒来去做，做完按设定告诉她。她说「以后每天早上给我做个早报」「明晚提醒我 / 问问我考得怎么样」时用 create。\
        醒来时你能用的只有她设成自动允许的工具（搜索、读网页这类），醒来后用 finish 交结果。
        action：create 新建 / update 改 / pause 停 / resume 恢复 / delete 删 / list 看全部。
        create 要 title、instruction（写给醒来的自己：要做什么、怎么做、做成什么样）、repeat + time（+ weekdays）或 repeat=once + at。
        """, properties: [
            "action": ["type": "string", "enum": ["create", "update", "pause", "resume", "delete", "list"], "description": "做什么"] as [String: Any],
            "task_id": ["type": "string", "description": "update / pause / resume / delete 要改的任务 id（list 里有）"] as [String: Any],
            "title": ["type": "string", "description": "任务名，短：「AI 早报」"] as [String: Any],
            "instruction": ["type": "string", "description": "醒来要做的事，写给醒来的自己"] as [String: Any],
            "repeat": ["type": "string", "enum": ["daily", "weekly", "once"], "description": "每天 / 每周几 / 一次"] as [String: Any],
            "time": ["type": "string", "description": "daily / weekly 几点，24 小时制 HH:mm，按她那边的时间"] as [String: Any],
            "weekdays": ["type": "array", "items": ["type": "integer"], "description": "weekly 用：1 = 周一 … 7 = 周日"] as [String: Any],
            "at": ["type": "string", "description": "once 用：yyyy-MM-dd HH:mm，按她那边的时间"] as [String: Any],
            "notify": ["type": "string", "enum": ["mainsession", "conversation", "heartbeat"],
                       "description": "做完怎么告诉她：mainsession = 发到 main session 并推通知（默认；你在别的对话里也会知道自己做了什么）；conversation = 发回这个对话（她明说要发回这里才用）；heartbeat = 只记在 heartbeat"] as [String: Any],
        ], required: ["action"])
    }

    /// 没写 / 写错 = mainsession（plan-floor-main-thread 默认）
    static func notify(_ raw: String?, conversationId: String) -> WakeNotify {
        switch raw {
        case "heartbeat": return .heartbeatOnly
        case "conversation": return .conversation(id: conversationId, push: true)
        default: return .mainSession(push: true)
        }
    }

    @MainActor
    static func execute(inputJSON: String, profileId: String, conversationId: String) -> (text: String, isError: Bool) {
        let args = DeviceToolIO.args(inputJSON)
        let engine = WakeEngine.shared
        let store = engine.store(profileId: profileId)
        let tz = engine.timeZone(profileId: profileId)
        func str(_ k: String) -> String? {
            (args[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let action = str("action") ?? ""
        let switchNote = engine.settings.enabled ? "" : "\n注意：设置里「自己醒来」总开关现在关着，要她打开才会真的醒来。"

        switch action {
        case "list":
            let tasks = store.tasks()
            guard !tasks.isEmpty else { return ("还没有任务", false) }
            return (tasks.map { line($0, tz: tz) }.joined(separator: "\n"), false)

        case "create":
            guard let title = str("title"), let instruction = str("instruction") else { return ("create 要 title 和 instruction", true) }
            guard store.tasks().filter({ !$0.done }).count < WakeSettings.maxTasksPerPerson else {
                return ("已经有 \(WakeSettings.maxTasksPerPerson) 个任务了，先删掉不要的再建", true)
            }
            let schedule: WakeSchedule
            switch parseSchedule(args, tz: tz) {
            case .success(let s): schedule = s
            case .failure(let e): return (e.message, true)
            }
            let notify = Self.notify(str("notify"), conversationId: conversationId)
            var task = WakeTask(title: String(title.prefix(40)), instruction: String(instruction.prefix(2000)), schedule: schedule,
                                createdBy: .ai(conversationId: conversationId), notify: notify)
            task = engine.scheduled(task, profileId: profileId)
            guard task.nextRunAt != nil else { return ("这个时间已经过了，换一个以后的时间", true) }
            engine.save(task, profileId: profileId)
            return ("建好了：\(line(task, tz: tz))\(quietNote(schedule, task: task, tz: tz))\(switchNote)", false)

        case "update", "pause", "resume", "delete":
            guard let id = str("task_id"), var task = store.task(id) else { return ("没有这个 task_id，先 list 看看", true) }
            switch action {
            case "delete":
                engine.delete(id, profileId: profileId)
                return ("删了「\(task.title)」", false)
            case "pause":
                task.enabled = false
            case "resume":
                task.enabled = true
                task.failureStreak = 0
            default:
                if let title = str("title") { task.title = String(title.prefix(40)) }
                if let instruction = str("instruction") { task.instruction = String(instruction.prefix(2000)) }
                if str("repeat") != nil {
                    switch parseSchedule(args, tz: tz) {
                    case .success(let s):
                        task.schedule = s
                        task.done = false
                    case .failure(let e): return (e.message, true)
                    }
                }
                if let n = str("notify") { task.notify = Self.notify(n, conversationId: conversationId) }
            }
            task = engine.scheduled(task, profileId: profileId)
            engine.save(task, profileId: profileId)
            return ("改好了：\(line(task, tz: tz))\(switchNote)", false)

        default:
            return ("action 只能是 create / update / pause / resume / delete / list", true)
        }
    }

    struct ScheduleError: Error { let message: String }

    /// repeat + time / weekdays / at → WakeSchedule（weekdays 人话 1 = 周一 … 7 = 周日 → Calendar 2 … 1）
    static func parseSchedule(_ args: [String: Any], tz: TimeZone, now: Date = Date()) -> Result<WakeSchedule, ScheduleError> {
        let kind = (args["repeat"] as? String) ?? ""
        switch kind {
        case "daily", "weekly":
            guard let time = args["time"] as? String, let (h, m) = hourMinute(time) else {
                return .failure(ScheduleError(message: "time 要 HH:mm，比如 08:00"))
            }
            var weekdays: [Int]?
            if kind == "weekly" {
                let days = (args["weekdays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter { (1...7).contains($0) }
                guard !days.isEmpty else { return .failure(ScheduleError(message: "weekly 要 weekdays：1 = 周一 … 7 = 周日")) }
                weekdays = Array(Set(days.map { $0 % 7 + 1 })).sorted()
            }
            return .success(.daily(hour: h, minute: m, weekdays: weekdays))
        case "once":
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let raw = args["at"] as? String, let date = f.date(from: raw.trimmingCharacters(in: .whitespaces)) else {
                return .failure(ScheduleError(message: "at 要 yyyy-MM-dd HH:mm"))
            }
            guard date > now else { return .failure(ScheduleError(message: "这个时间已经过了，换一个以后的时间")) }
            guard date < now.addingTimeInterval(Double(WakeSettings.maxOnceDays) * 86400) else {
                return .failure(ScheduleError(message: "一次性的最多排到 \(WakeSettings.maxOnceDays) 天后"))
            }
            return .success(.once(date))
        default:
            return .failure(ScheduleError(message: "repeat 要 daily / weekly / once"))
        }
    }

    static func hourMinute(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// 「[id] AI 早报 · 每天 08:00 · 下次 11月13日 08:00 · 开着」
    static func line(_ task: WakeTask, tz: TimeZone) -> String {
        let state = task.done ? "做完了" : task.enabled ? "开着" : "停了"
        let next = task.nextRunAt.map { " · 下次 \(WakeText.dateTime($0, tz: tz))" } ?? ""
        return "[\(task.id)] \(task.title) · \(WakeText.schedule(task.schedule, tz: tz))\(next) · \(state)"
    }

    /// 排的时间落在安静时段、被挪了：告诉 AI
    private static func quietNote(_ schedule: WakeSchedule, task: WakeTask, tz: TimeZone) -> String {
        guard let next = task.nextRunAt else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let wanted: (Int, Int)
        switch schedule {
        case .daily(let h, let m, _): wanted = (h, m)
        case .once(let d): wanted = (cal.component(.hour, from: d), cal.component(.minute, from: d))
        }
        let got = (cal.component(.hour, from: next), cal.component(.minute, from: next))
        return got == wanted ? "" : "\n这个点在她设的安静时段里，挪到了 \(String(format: "%02d:%02d", got.0, got.1))。"
    }
}

/// heartbeat 里的人话时间
enum WakeText {
    static func schedule(_ s: WakeSchedule, tz: TimeZone) -> String {
        switch s {
        case .daily(let h, let m, let weekdays):
            let time = String(format: "%02d:%02d", h, m)
            guard let weekdays, weekdays.count < 7 else { return "每天 \(time)" }
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            // 周一在前：Calendar 2…7, 1
            let ordered = weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
            return "每周" + ordered.map { names[($0 - 1) % 7] }.joined(separator: "、") + " \(time)"
        case .once(let d):
            return "一次 · \(dateTime(d, tz: tz))"
        }
    }

    static func dateTime(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = tz
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}
