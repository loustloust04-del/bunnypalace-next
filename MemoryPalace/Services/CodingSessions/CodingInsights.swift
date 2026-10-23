#if os(macOS)
import Foundation

// W-N N2「统计」（plan-wake-native-n2）：Wake `InsightsData` 与派生逐字移植（`models.rs:434-567`、`db.rs:1858-1875`、
// `workbench.rs` 的纯逻辑部分）。查询在 `CodingSessionIndex.insights(today:)`。

/// 本地日（年 / 月 / 日）：统计的日键。不拿 `Date` 当键（免时区歧义）；加减天用固定公历（UTC 下算，不受夏令时影响）
struct CodingDay: Comparable, Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// SQLite `date()` 的 `YYYY-MM-DD`
    init?(sqlite: String) {
        let parts = sqlite.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// 某一刻在给定日历（默认本地）里落在哪天
    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    static func < (lhs: CodingDay, rhs: CodingDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private var utcDate: Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    func adding(days: Int) -> CodingDay {
        CodingDay(Self.utc.date(byAdding: .day, value: days, to: utcDate) ?? utcDate, calendar: Self.utc)
    }

    func days(since other: CodingDay) -> Int {
        Self.utc.dateComponents([.day], from: other.utcDate, to: utcDate).day ?? 0
    }

    /// 周一 = 0 … 周日 = 6
    var weekdayFromMonday: Int {
        (Self.utc.component(.weekday, from: utcDate) + 5) % 7
    }

    /// 所在周的周一（Insights 所有「按周」口径只此一处）
    var weekStart: CodingDay { adding(days: -weekdayFromMonday) }
}

struct CodingDayCount: Equatable, Sendable {
    var day: CodingDay
    var count: Int64
}

/// 榜单的一行（agent / 项目 / 模型共用）。tokens = 0 表示该组不报 Token（不是用了 0），界面据此隐藏
struct CodingUsageTally: Equatable, Sendable {
    var name: String
    var sessions: Int64
    var prompts: Int64
    var tokens: Int64
}

struct CodingWindowStats: Equatable, Sendable {
    var sessions: Int64 = 0
    var prompts: Int64 = 0
    var activeDays: Int64 = 0
}

/// 趋势图的一条序列：`weekly` 长 trendWeeks，末项是今天所在周
struct CodingTrendSeries: Equatable, Sendable {
    var name: String
    var weekly: [Int64]

    var total: Int64 { weekly.reduce(0, +) }
}

/// 统计快照（口径：archived 不计；「提问」= 主线用户消息）。daily 是全时段活跃日谱（升序，仅有效且不在未来的日）
struct CodingInsightsData: Equatable, Sendable {
    static let trendWeeks = 53

    /// 快照的「今天」：streak 与热力图末列共用，渲染层不各自读时钟
    var asOf: CodingDay
    var sessions: Int64 = 0
    var prompts: Int64 = 0
    var tokens: Int64 = 0
    var projectCount: Int64 = 0
    /// 最早会话 created_at（ms）；0 = 库里没有有效时间
    var firstTs: Int64 = 0
    var currentStreak: Int64 = 0
    var longestStreak: Int64 = 0
    var daily: [CodingDayCount] = []
    var hourly = [Int64](repeating: 0, count: 24)
    /// 周一起
    var weekday = [Int64](repeating: 0, count: 7)
    var monthly = [Int64](repeating: 0, count: 12)
    var agents: [CodingUsageTally] = []
    /// 全量不截断：top-N 由界面按当前度量排序后取
    var projects: [CodingUsageTally] = []
    var models: [CodingUsageTally] = []
    /// 按会话创建日的会话数（升序）
    var dailySessions: [CodingDayCount] = []
    /// 各 agent 近 53 周每周提问，按总量降序、平局名称升序
    var trendAgents: [CodingTrendSeries] = []

    var activeDays: Int64 { Int64(daily.count) }

    /// 最忙的一天（同为最大取靠后的，同 Rust `max_by_key`）
    var busiestDay: CodingDayCount? {
        var best: CodingDayCount?
        for entry in daily where entry.count >= (best?.count ?? .min) { best = entry }
        return best
    }

    /// 以 `ending` 收尾的 7 天闭区间：会话按创建日、提问与活跃天按消息日
    func weekEnding(_ ending: CodingDay) -> CodingWindowStats {
        let start = ending.adding(days: -6)
        var stats = CodingWindowStats()
        for entry in daily where entry.day >= start && entry.day <= ending {
            stats.prompts += entry.count
            stats.activeDays += 1
        }
        for entry in dailySessions where entry.day >= start && entry.day <= ending {
            stats.sessions += entry.count
        }
        return stats
    }

    /// 最近 7 天与其前 7 天
    var lastWeekPair: (current: CodingWindowStats, previous: CodingWindowStats) {
        (weekEnding(asOf), weekEnding(asOf.adding(days: -7)))
    }

    /// 趋势图 / 热力图窗口的首个周一（末列 = 今天所在周）
    var trendStart: CodingDay { asOf.weekStart.adding(days: -(Self.trendWeeks - 1) * 7) }

    /// 日 → 趋势窗口内的周下标（末项 = 今天所在周）；窗外 / 未来为 nil。与 `trendStart` 互逆
    static func trendWeekIndex(asOf: CodingDay, day: CodingDay) -> Int? {
        let weeksBack = asOf.weekStart.days(since: day.weekStart) / 7
        guard (0..<trendWeeks).contains(weeksBack) else { return nil }
        return trendWeeks - 1 - weeksBack
    }

    /// 连续活跃天：daily 升序找连续段；current = 最后活跃日距今 ≤ 1 天时的末段长度（今天还没活动从昨天起算）
    static func streaks(_ daily: [CodingDayCount], today: CodingDay) -> (current: Int64, longest: Int64) {
        var longest: Int64 = 0
        var run: Int64 = 0
        var previous: CodingDay?
        for entry in daily {
            if let previous, entry.day.days(since: previous) == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = entry.day
        }
        guard let previous, today.days(since: previous) <= 1 else { return (0, longest) }
        return (run, longest)
    }
}

// MARK: - 界面用的纯逻辑（Wake `workbench.rs` / `format.rs`）

/// 榜单度量；循环序与概览行同：会话 / Token / 提问
enum CodingInsightsMetric: CaseIterable, Sendable {
    case sessions, tokens, prompts

    var label: String {
        switch self {
        case .sessions: return "会话"
        case .tokens: return "Token"
        case .prompts: return "提问"
        }
    }

    func value(_ row: CodingUsageTally) -> Int64 {
        switch self {
        case .sessions: return row.sessions
        case .tokens: return row.tokens
        case .prompts: return row.prompts
        }
    }

    func display(_ row: CodingUsageTally) -> String {
        self == .tokens ? CodingInsightsFormat.tokens(row.tokens) : CodingInsightsFormat.thousands(value(row))
    }

    /// 组内无人报 Token 时 Token 档不进循环
    static func available(for rows: [CodingUsageTally]) -> [CodingInsightsMetric] {
        rows.contains { $0.tokens > 0 } ? [.sessions, .tokens, .prompts] : [.sessions, .prompts]
    }

    /// 存的档位不可用了（比如 Token 档消失）落回首档
    static func resolved(_ stored: CodingInsightsMetric, in available: [CodingInsightsMetric]) -> CodingInsightsMetric {
        available.contains(stored) ? stored : available[0]
    }

    /// Token 档只列报过用量的组；按当前度量降序（稳定，平局保持 SQL 基线序）后截断
    static func ranked(_ rows: [CodingUsageTally], by metric: CodingInsightsMetric, limit: Int?) -> [CodingUsageTally] {
        let sorted = rows.enumerated()
            .filter { metric != .tokens || $0.element.tokens > 0 }
            .sorted { a, b in
                let (va, vb) = (metric.value(a.element), metric.value(b.element))
                return va != vb ? va > vb : a.offset < b.offset
            }
            .map(\.element)
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }
}

/// 趋势图的一层：前五个 agent 各一层，其余合并成「其他」（不参评领先者）
struct CodingTrendLayer: Equatable, Sendable {
    var name: String
    var agent: CodingAgent?
    var weekly: [Int64]
    var isOther: Bool
}

enum CodingInsightsFormat {
    static let trendTop = 5

    static func thousands(_ n: Int64) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// K / M / B 一位小数；0 = 空（不报）
    static func tokens(_ n: Int64) -> String {
        switch n {
        case ..<1: return ""
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1e3)
        default: return String(n)
        }
    }

    /// 相对变化行：(文案, 是否用强调色)
    static func change(now: Int64, before: Int64) -> (text: String, emphasized: Bool) {
        if now == 0 && before == 0 { return ("没有活动", false) }
        if before == 0 { return ("本周新增", true) }
        let percent = Int64((Double(now - before) * 100 / Double(before)).rounded())
        if percent == 0 { return ("与上周持平", false) }
        return ("较上周 \(percent > 0 ? "+" : "")\(percent)%", percent > 0)
    }

    /// 热力格强度：0 = 空格；否则 ceil(n / 峰值 × 4) 取 1…4（线性四档，峰值至少 1）
    static func heatLevel(_ n: Int64, peak: Int64) -> Int {
        guard n > 0 else { return 0 }
        let level = Int((Double(n) / Double(max(peak, 1)) * 4).rounded(.up))
        return min(max(level, 1), 4)
    }

    static let heatOpacity: [Double] = [0.25, 0.5, 0.75, 1]

    /// 月份刻度：该列周一与前一列周一不同月时标（首列同规则）。返回 (列, 月)
    static func monthTicks(start: CodingDay) -> [(column: Int, month: Int)] {
        (0..<CodingInsightsData.trendWeeks).compactMap { column in
            let monday = start.adding(days: column * 7)
            return monday.month != monday.adding(days: -7).month ? (column, monday.month) : nil
        }
    }

    static func promptsLabel(_ n: Int64) -> String {
        n == 0 ? "没有提问" : "\(thousands(n)) 次提问"
    }

    static func dayLabel(_ day: CodingDay, withYear: Bool = true) -> String {
        withYear ? "\(day.year)年\(day.month)月\(day.day)日" : "\(day.month)月\(day.day)日"
    }

    /// 副行「自 {首会话月份} 起」；拿不到时间回落
    static func subtitle(_ data: CodingInsightsData?) -> String {
        guard let data, data.sessions > 0, data.firstTs > 0 else { return "你的 coding agent 活动" }
        let day = CodingDay(Date(timeIntervalSince1970: TimeInterval(data.firstTs) / 1000))
        return "自 \(day.year)年\(day.month)月 起"
    }

    /// 12 小时制时段名
    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "凌晨 12 点"
        case 1...11: return "上午 \(hour) 点"
        case 12: return "中午 12 点"
        default: return "下午 \(hour - 12) 点"
        }
    }

    static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    static func agentLabel(_ raw: String) -> String {
        CodingAgent(rawValue: raw)?.displayName ?? raw
    }

    static func trendLayers(_ series: [CodingTrendSeries]) -> [CodingTrendLayer] {
        var layers = series.prefix(trendTop).map { item in
            CodingTrendLayer(name: agentLabel(item.name), agent: CodingAgent(rawValue: item.name), weekly: item.weekly, isOther: false)
        }
        if series.count > trendTop {
            var other = [Int64](repeating: 0, count: CodingInsightsData.trendWeeks)
            for item in series.dropFirst(trendTop) {
                for (i, n) in item.weekly.enumerated() where i < other.count { other[i] += n }
            }
            layers.append(CodingTrendLayer(name: "其他", agent: nil, weekly: other, isOther: true))
        }
        return layers
    }

    /// 本周领先者：本周 prompts 最多的一层（同为最大取靠后的）；本周都为零退回上一周
    static func trendLeader(_ layers: [CodingTrendLayer]) -> String? {
        let last = CodingInsightsData.trendWeeks - 1
        for week in [last, last - 1] {
            var best: CodingTrendLayer?
            for layer in layers where !layer.isOther && layer.weekly[week] > 0 && layer.weekly[week] >= (best?.weekly[week] ?? .min) {
                best = layer
            }
            if let best { return best.name }
        }
        return nil
    }

    static func trendCaption(_ layers: [CodingTrendLayer]) -> String {
        trendLeader(layers).map { "各 agent 每周提问数 · 本周 \($0) 领先" } ?? "各 agent 每周提问数"
    }
}
#endif
