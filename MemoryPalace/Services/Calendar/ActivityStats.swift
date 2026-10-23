import Foundation

// MARK: - 年视图统计（plan-calendar §九 P3）
// 全部从逐对话贡献派生出的 Summary 里算，不碰数据库。

enum ActivityStats {

    /// 现在连续几天：今天有聊就从今天往回数；今天还没聊就从昨天数（不打断连续）
    static func currentStreak(_ s: DailyActivity.Summary, today: Date, calendar: Calendar) -> Int {
        func active(_ d: Date) -> Bool { (s.days[DailyActivity.dayKey(d, calendar: calendar)]?.messages ?? 0) > 0 }
        var cursor = calendar.startOfDay(for: today)
        if !active(cursor), let y = calendar.date(byAdding: .day, value: -1, to: cursor) { cursor = y }
        var n = 0
        while active(cursor) {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return n
    }

    struct Streak: Equatable { let length: Int; let start: String; let end: String }

    /// 这一年里最长的连续（跨年的连续只算这一年里的部分）
    static func longestStreak(_ s: DailyActivity.Summary, year: Int, calendar: Calendar) -> Streak? {
        guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let days = calendar.range(of: .day, in: .year, for: first)?.count else { return nil }
        var best: Streak?
        var runStart: String?
        var runLen = 0
        var prevKey = ""
        for i in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: i, to: first) else { continue }
            let key = DailyActivity.dayKey(d, calendar: calendar)
            if (s.days[key]?.messages ?? 0) > 0 {
                if runLen == 0 { runStart = key }
                runLen += 1
                prevKey = key
                if runLen > (best?.length ?? 0), let runStart { best = Streak(length: runLen, start: runStart, end: prevKey) }
            } else {
                runLen = 0
            }
        }
        return best
    }

    static func keys(ofYear year: Int, in s: DailyActivity.Summary) -> [String] {
        let prefix = String(format: "%04d-", year)
        return s.days.keys.filter { $0.hasPrefix(prefix) }
    }

    /// 最多的一天
    static func busiestDay(_ s: DailyActivity.Summary, year: Int) -> (key: String, messages: Int)? {
        var best: (key: String, messages: Int)?
        for key in keys(ofYear: year, in: s).sorted() {
            let n = s.days[key]?.messages ?? 0
            // 一样多取更早的那天
            if n > 0, n > (best?.messages ?? 0) { best = (key, n) }
        }
        return best
    }

    /// 最晚的一次：熬夜口径（凌晨 4 点前算前一天），显示成 HH:mm
    static func latest(_ s: DailyActivity.Summary, year: Int) -> (key: String, time: String)? {
        guard let best = keys(ofYear: year, in: s)
            .compactMap({ k in s.days[k]?.lateMinute.map { (k, $0) } })
            .max(by: { $0.1 < $1.1 }) else { return nil }
        let m = best.1 % 1440
        return (best.0, String(format: "%02d:%02d", m / 60, m % 60))
    }

    static func activeDays(_ s: DailyActivity.Summary, year: Int) -> Int {
        keys(ofYear: year, in: s).filter { (s.days[$0]?.messages ?? 0) > 0 }.count
    }

    static func totalMessages(_ s: DailyActivity.Summary, year: Int) -> Int {
        keys(ofYear: year, in: s).reduce(0) { $0 + (s.days[$1]?.messages ?? 0) }
    }

    /// 星期 × 小时（周一在前）：[7][24]
    static func punchCard(_ s: DailyActivity.Summary, year: Int, calendar: Calendar) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for key in keys(ofYear: year, in: s) {
            guard let d = DailyActivity.date(fromKey: key, calendar: calendar), let day = s.days[key] else { continue }
            let w = (calendar.component(.weekday, from: d) + 5) % 7     // 周一 = 0
            for h in 0..<24 { grid[w][h] += day.hours[h] }
        }
        return grid
    }
}
