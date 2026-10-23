import Foundation

// MARK: - 按天统计：值类型与口径（plan-calendar §2.1）
// 纯函数，不碰 SwiftData。缓存与扫描见 CalendarActivityIndex。

/// 一个对话在某一天的贡献。
struct DayContribution: Codable, Equatable, Sendable {
    var user = 0
    var assistant = 0
    var userChars = 0
    var assistantChars = 0
    /// 这一天 0–23 点各几条（日历日口径）
    var hours = [Int](repeating: 0, count: 24)
    /// 熬夜口径的「最晚」：从这一天 00:00 起的分钟数；凌晨 4 点前的消息记到前一天，所以可以 ≥ 1440
    var lateMinute: Int?

    var messages: Int { user + assistant }

    mutating func merge(_ o: DayContribution) {
        user += o.user
        assistant += o.assistant
        userChars += o.userChars
        assistantChars += o.assistantChars
        for i in 0..<24 { hours[i] += o.hours[i] }
        if let l = o.lateMinute { lateMinute = max(lateMinute ?? l, l) }
    }
}

/// 一个对话的全部贡献：可整体替换（删对话 = 去掉它这一份）。
struct ConversationContribution: Codable, Equatable, Sendable {
    let convId: String
    /// 扫描时的节点数（未进回收站的，含所有角色）：对账用
    var nodeCount: Int
    var days: [String: DayContribution]
}

/// 扫描时从 MessageNode 里取出的最小信息（值类型，跨线程安全）。
struct ActivityNodeSample: Sendable {
    let role: String
    let createTime: Date?
    let charCount: Int
    let isDeleted: Bool
}

enum ActivityMetric: String, CaseIterable, Sendable { case messages, chars }
enum ActivityWho: String, CaseIterable, Sendable { case all, me, ai }

enum DailyActivity {

    /// 熬夜分界：这个钟点之前的消息算前一天的「最晚」
    static let nightCutoffHour = 4

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        // 本地正午：避免跨时区时差一天
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// 口径：只算 user / assistant、未删除、有时间的节点；所有分支都算。
    static func contribution(convId: String, nodeCount: Int, samples: [ActivityNodeSample], calendar: Calendar) -> ConversationContribution {
        var days: [String: DayContribution] = [:]
        for s in samples {
            guard !s.isDeleted, let t = s.createTime, s.role == "user" || s.role == "assistant" else { continue }
            let key = dayKey(t, calendar: calendar)
            var d = days[key] ?? DayContribution()
            if s.role == "user" { d.user += 1; d.userChars += s.charCount } else { d.assistant += 1; d.assistantChars += s.charCount }
            let hour = calendar.component(.hour, from: t)
            d.hours[hour] += 1
            days[key] = d

            // 熬夜口径：凌晨 4 点前记到前一天，分钟数 +1440
            let minute = hour * 60 + calendar.component(.minute, from: t)
            let lateKey: String
            let lateMinute: Int
            if hour < nightCutoffHour, let prev = calendar.date(byAdding: .day, value: -1, to: t) {
                lateKey = dayKey(prev, calendar: calendar)
                lateMinute = minute + 1440
            } else {
                lateKey = key
                lateMinute = minute
            }
            var ld = days[lateKey] ?? DayContribution()
            ld.lateMinute = max(ld.lateMinute ?? lateMinute, lateMinute)
            days[lateKey] = ld
        }
        return ConversationContribution(convId: convId, nodeCount: nodeCount, days: days)
    }

    // MARK: 汇总

    struct Summary: Equatable, Sendable {
        var days: [String: DayContribution] = [:]
        /// day → convId → 那天这个对话的条数（「这天聊了」反查）
        var conversationsByDay: [String: [String: Int]] = [:]
    }

    static func aggregate<C: Collection>(_ contributions: C) -> Summary where C.Element == ConversationContribution {
        var s = Summary()
        for c in contributions {
            for (key, d) in c.days {
                var total = s.days[key] ?? DayContribution()
                total.merge(d)
                s.days[key] = total
                if d.messages > 0 { s.conversationsByDay[key, default: [:]][c.convId] = d.messages }
            }
        }
        return s
    }

    static func value(_ d: DayContribution?, metric: ActivityMetric, who: ActivityWho) -> Int {
        guard let d else { return 0 }
        switch (metric, who) {
        case (.messages, .all): return d.messages
        case (.messages, .me): return d.user
        case (.messages, .ai): return d.assistant
        case (.chars, .all): return d.userChars + d.assistantChars
        case (.chars, .me): return d.userChars
        case (.chars, .ai): return d.assistantChars
        }
    }

    // MARK: 分档（plan §2.3）

    /// 三个阈值 [t2, t3, t4]：value < t2 → 1 档；< t3 → 2；< t4 → 3；否则 4。
    /// 用过去 90 天有聊的日子的 40 / 70 / 90 分位；不足 14 天退回固定阈值。
    static func thresholds(recentValues: [Int], metric: ActivityMetric) -> [Int] {
        let active = recentValues.filter { $0 > 0 }.sorted()
        guard active.count >= 14 else {
            return metric == .messages ? [40, 100, 180] : [2_000, 6_000, 12_000]
        }
        func q(_ p: Double) -> Int { active[min(active.count - 1, Int((Double(active.count - 1) * p).rounded()))] }
        var t = [q(0.4), q(0.7), q(0.9)]
        // 保证严格递增（数据很整齐时分位会重合）
        for i in 1..<t.count where t[i] <= t[i - 1] { t[i] = t[i - 1] + 1 }
        return t
    }

    static func level(_ value: Int, thresholds t: [Int]) -> Int {
        guard value > 0 else { return 0 }
        if value < t[0] { return 1 }
        if value < t[1] { return 2 }
        if value < t[2] { return 3 }
        return 4
    }
}
