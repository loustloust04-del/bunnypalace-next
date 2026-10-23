import Foundation

/// 「记忆从哪天开始」（设置 → 记忆，plan-memory-app-three-views §4）：这天以前的消息不交给任何写手
///（收尾、首次补写、压缩）；已经写下的照常显示、照常注入（Q8）。全局一个 AppStorage，存 yyyy-MM-dd，空 = 不限。
/// 一天从 05:00 算（`MemoryDay`），起点那天也从 05:00 起
enum MemoryStartDay {
    static let key = "mem_start_day"

    /// 每次新建：后台写手和界面都会调，不共用一个可变的 DateFormatter
    private static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f
    }

    /// 「2026-10-01」→ 那天 05:00（记忆的一天从 05:00 算，`MemoryDay`）；空 / 写坏了 = nil（不限）
    static func parse(_ raw: String, calendar: Calendar = .current) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let d = formatter(calendar).date(from: t) else { return nil }
        return MemoryDay.boundary(of: d, calendar: calendar)
    }

    static func format(_ date: Date, calendar: Calendar = .current) -> String {
        formatter(calendar).string(from: date)
    }

    /// 现在的起点；nil = 不限
    static var current: Date? {
        parse(UserDefaults.standard.string(forKey: key) ?? "")
    }

    /// 纯函数（可测）：路径里第一条能交给写手的下标 = 起点以前最后一条的下一条（路径时间不一定单调，取最后一条才保证一条不漏进去）。
    /// 没有起点 / 全在起点以后 = 0；全在起点以前 = count；没有时间的消息不算「以前」
    static func firstAllowedIndex(_ dates: [Date?], startDay: Date?) -> Int {
        guard let s = startDay, let i = dates.lastIndex(where: { ($0 ?? .distantFuture) < s }) else { return 0 }
        return i + 1
    }
}
