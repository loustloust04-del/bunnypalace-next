import Foundation

/// 记忆的「一天」从凌晨 05:00 算起（plan-memory-v4-1 §二）：05:00 以前的事归前一天。
/// 所有记忆的归日、归月（时间轴归日 / 归月、注入取哪两个月、写手按天切、CC 跨过 05:00、记忆 app 按天分组、记忆起点）都走这里。
/// 行里显示的「23:40 – 次日 00:30」照旧按日历写，那是钟点，不是归日
enum MemoryDay {
    static let boundaryHour = 5

    /// 归到哪天：那个日历日的 00:00（分组、「今天 / 昨天」用）。按钟面算（墙上 05:00 以前归前一天），
    /// 不按「减 5 小时」——夏令时切换那天减固定秒数会差一小时
    static func dayStart(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        guard calendar.component(.hour, from: date) < boundaryHour else { return start }
        return calendar.date(byAdding: .day, value: -1, to: start) ?? start
    }

    /// 「yyyy-MM-dd」：凌晨 5 点以前的算前一天
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: dayStart(date, calendar: calendar))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 「yyyy-MM」：归到的那天所在的月（时间轴月文件名）
    static func month(_ date: Date, calendar: Calendar = .current) -> String {
        String(key(date, calendar: calendar).prefix(7))
    }

    /// 「2026-10-11」→ 那天的 00:00（日历日期）；写坏了 nil
    static func date(ofKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 一个日历日的记忆起点（那天钟面 05:00）。用日期组件拼，不用「午夜 + 5 小时」——夏令时那天会差一小时
    static func boundary(of day: Date, calendar: Calendar = .current) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: day)
        c.hour = boundaryHour
        c.minute = 0
        c.second = 0
        return calendar.date(from: c) ?? calendar.startOfDay(for: day)
    }

    /// 纯函数（可测）：按天切成几组（连续同一天的一组），返回下标区间；没时间的消息跟着前后的走
    static func split(_ dates: [Date?], calendar: Calendar = .current) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        var current: String?
        for (i, d) in dates.enumerated() {
            guard let d else { continue }
            let k = key(d, calendar: calendar)
            if let c = current, c != k {
                out.append(start..<i)
                start = i
            }
            current = k
        }
        if start < dates.count { out.append(start..<dates.count) }
        return out
    }
}
