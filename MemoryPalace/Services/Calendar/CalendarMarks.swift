import Foundation

// MARK: - 月历每一天画什么（plan-calendar §六）
// 档位 = 按天统计 + 分档；记号优先级：生日 → 蝴蝶结；其它纪念日 → 星；写了日记 → 框里的心；
// 心情开心 → 小花；单个对话当天 ≥ 100 条 → 螺旋。一格只画一个。

enum CalendarMarks {

    static let longChatThreshold = 100

    struct Inputs {
        var summary: DailyActivity.Summary
        var metric: ActivityMetric = .messages
        var who: ActivityWho = .all
        var journalDates: Set<String> = []
        var moods: [String: JournalMood] = [:]
        /// dayKey → 是不是生日
        var anniversaryDays: [String: Bool] = [:]
        var periodDays: Set<String> = []
        /// 待办：dayKey → 全做完了没（`TodoManager.marks`）
        var todoMarks: [String: Bool] = [:]
    }

    /// 过去 90 天（到 `today`）的每日取值，给分档用
    static func recentValues(_ summary: DailyActivity.Summary, metric: ActivityMetric, who: ActivityWho, today: Date, calendar: Calendar) -> [Int] {
        (0..<90).compactMap { i in
            calendar.date(byAdding: .day, value: -i, to: today).map {
                DailyActivity.value(summary.days[DailyActivity.dayKey($0, calendar: calendar)], metric: metric, who: who)
            }
        }
    }

    static func month(_ firstOfMonth: Date, daysInMonth: Int, inputs: Inputs, thresholds: [Int], calendar: Calendar) -> [Int: PencilMonthDay] {
        var out: [Int: PencilMonthDay] = [:]
        for d in 1...daysInMonth {
            guard let date = calendar.date(byAdding: .day, value: d - 1, to: firstOfMonth) else { continue }
            let key = DailyActivity.dayKey(date, calendar: calendar)
            let value = DailyActivity.value(inputs.summary.days[key], metric: inputs.metric, who: inputs.who)
            var day = PencilMonthDay(level: DailyActivity.level(value, thresholds: thresholds))
            day.doodle = doodle(key: key, inputs: inputs)
            day.periodMark = inputs.periodDays.contains(key)
            day.todo = inputs.todoMarks[key]
            out[d] = day
        }
        return out
    }

    static func doodle(key: String, inputs: Inputs) -> CalendarInk.Doodle? {
        if let isBirthday = inputs.anniversaryDays[key] { return isBirthday ? .bow : .star }
        if inputs.journalDates.contains(key) { return .heartBox }
        if inputs.moods[key] == .happy { return .flower }
        if let convs = inputs.summary.conversationsByDay[key], (convs.values.max() ?? 0) >= longChatThreshold { return .spiral }
        return nil
    }
}

extension AnniversaryMath {
    /// 这条纪念日落在 `firstOfMonth` 这个月的哪些日子（dayKey）
    static func occurrenceKeys(of a: Anniversary, inMonth firstOfMonth: Date, gregorian: Calendar, chinese: Calendar) -> [String] {
        guard let base = date(fromKey: a.date, calendar: gregorian),
              let range = gregorian.range(of: .day, in: .month, for: firstOfMonth),
              let last = gregorian.date(byAdding: .day, value: range.count - 1, to: firstOfMonth) else { return [] }
        func inMonth(_ d: Date) -> Bool { gregorian.isDate(d, equalTo: firstOfMonth, toGranularity: .month) }
        switch a.kind {
        case .countdown, .since:
            return inMonth(base) ? [DailyActivity.dayKey(base, calendar: gregorian)] : []
        case .yearly:
            if let lunar = a.lunar {
                guard let d = nextLunar(lunar, onOrAfter: firstOfMonth, gregorian: gregorian, chinese: chinese), d <= last else { return [] }
                return [DailyActivity.dayKey(d, calendar: gregorian)]
            }
            let md = gregorian.dateComponents([.month, .day], from: base)
            let y = gregorian.component(.year, from: firstOfMonth)
            guard let d = gregorian.date(from: DateComponents(year: y, month: md.month, day: md.day)), inMonth(d),
                  gregorian.component(.year, from: d) >= gregorian.component(.year, from: base) else { return [] }
            return [DailyActivity.dayKey(d, calendar: gregorian)]
        }
    }
}
