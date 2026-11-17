import Foundation

/// 护栏（plan §3.2，粟粟 11-11 Q5 按默认）：设置页能改
public struct WakeSettings: Codable, Equatable, Sendable {
    /// 总开关（默认关）
    public var enabled: Bool
    /// 安静时段（本地钟点，[start, end)，可以跨午夜：23 → 7）；start == end = 没有安静时段
    public var quietStart: Int
    public var quietEnd: Int
    /// 每天最多醒几次（全部人加起来）
    public var dailyMax: Int
    /// 每次最多几轮 / 多少美元
    public var maxRounds: Int
    public var maxUSD: Double

    public init(enabled: Bool = false, quietStart: Int = 0, quietEnd: Int = 8, dailyMax: Int = 10,
                maxRounds: Int = 20, maxUSD: Double = 0.5) {
        self.enabled = enabled
        self.quietStart = quietStart
        self.quietEnd = quietEnd
        self.dailyMax = dailyMax
        self.maxRounds = maxRounds
        self.maxUSD = maxUSD
    }

    /// 她 N 分钟内在这个人的对话里说过话就让路
    public static let yieldMinutes: Double = 10
    /// 让路时往后推多久
    public static let deferMinutes: Double = 15
    /// 连续失败几次自动停
    public static let failureStop = 3
    /// 每天的任务错过超过这么久就不补，直接排下一次
    public static let catchUpWindow: TimeInterval = 12 * 3600
    /// 一次性任务错过超过这么久就不补
    public static let onceCatchUpWindow: TimeInterval = 7 * 24 * 3600
    /// 一个人最多几个任务（不算做完的）；一次性最多排到多少天后
    public static let maxTasksPerPerson = 10
    public static let maxOnceDays = 30
}

/// 下次什么时候：按这个人的时区算、避开安静时段（纯函数，单测钉住）
public enum WakeClock {
    /// 下一次（严格晚于 after）。once 已经过了 = nil
    public static func next(_ schedule: WakeSchedule, after: Date, timeZone: TimeZone, settings: WakeSettings) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        switch schedule {
        case .once(let at):
            let moved = outOfQuiet(at, calendar: cal, settings: settings)
            return moved > after ? moved : nil
        case .daily(let hour, let minute, let weekdays):
            let allowed = weekdays.map(Set.init)
            var day = cal.startOfDay(for: after)
            for _ in 0..<9 {
                if allowed == nil || allowed!.contains(cal.component(.weekday, from: day)),
                   let at = cal.date(bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0, of: day) {
                    let moved = outOfQuiet(at, calendar: cal, settings: settings)
                    if moved > after { return moved }
                }
                guard let tomorrow = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = tomorrow
            }
            return nil
        }
    }

    /// 落在安静时段里 → 挪到安静时段结束那个整点
    public static func outOfQuiet(_ date: Date, calendar cal: Calendar, settings: WakeSettings) -> Date {
        guard inQuiet(date, calendar: cal, settings: settings) else { return date }
        let hour = cal.component(.hour, from: date)
        let start = settings.quietStart, end = settings.quietEnd
        let day = cal.startOfDay(for: date)
        // 跨午夜（23 → 7）且现在在午夜前那段：挪到第二天的 end
        let base = (start > end && hour >= start) ? cal.date(byAdding: .day, value: 1, to: day) ?? day : day
        return cal.date(bySettingHour: end, minute: 0, second: 0, of: base) ?? date
    }

    public static func inQuiet(_ date: Date, calendar cal: Calendar, settings: WakeSettings) -> Bool {
        let start = settings.quietStart, end = settings.quietEnd
        guard start != end else { return false }
        let hour = cal.component(.hour, from: date)
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    /// 到点了吗：到了且没错过太久 = 跑（准点 / 补跑）；错过太久 = 跳过并排下次
    public enum Due: Equatable, Sendable {
        case notYet
        case run(WakeTrigger)
        case missed
    }

    public static func due(_ task: WakeTask, now: Date, tolerance: TimeInterval = 120) -> Due {
        guard task.isActive, let at = task.nextRunAt, at <= now else { return .notYet }
        let late = now.timeIntervalSince(at)
        let window = task.schedule.isOnce ? WakeSettings.onceCatchUpWindow : WakeSettings.catchUpWindow
        if late > window { return .missed }
        return .run(late <= tolerance ? .scheduled : .catchUp)
    }
}

/// 护栏判定（纯函数）：现在能不能跑这一件
public enum WakeGuard {
    public enum Decision: Equatable, Sendable {
        case go
        /// 往后推到这个时刻再看（她在聊天）
        case wait(until: Date)
        /// 这次不跑（总开关 / 人的开关 / 今天次数用完），原因写进 heartbeat
        case hold(String)
    }

    public struct Context: Sendable {
        public var settings: WakeSettings
        public var personEnabled: Bool
        /// 今天（这台设备本地日）已经跑了几次（全部人）
        public var runsToday: Int
        /// 她最后一次在这个人的对话里发消息
        public var lastUserMessageAt: Date?
        /// 她现在正在这个人的对话里打字
        public var typing: Bool
        /// 她点的「现在跑一次」：不管开关 / 次数 / 让路
        public var manual: Bool

        public init(settings: WakeSettings, personEnabled: Bool, runsToday: Int, lastUserMessageAt: Date?, typing: Bool, manual: Bool = false) {
            self.settings = settings
            self.personEnabled = personEnabled
            self.runsToday = runsToday
            self.lastUserMessageAt = lastUserMessageAt
            self.typing = typing
            self.manual = manual
        }
    }

    public static func decide(now: Date, _ c: Context) -> Decision {
        if c.manual { return .go }
        guard c.settings.enabled else { return .hold("总开关关着") }
        guard c.personEnabled else { return .hold("这个人的「自己醒来」关着") }
        guard c.runsToday < c.settings.dailyMax else { return .hold("今天已经醒了 \(c.runsToday) 次，到上限了") }
        let recent = c.lastUserMessageAt.map { now.timeIntervalSince($0) < WakeSettings.yieldMinutes * 60 } ?? false
        if c.typing || recent { return .wait(until: now.addingTimeInterval(WakeSettings.deferMinutes * 60)) }
        return .go
    }
}
