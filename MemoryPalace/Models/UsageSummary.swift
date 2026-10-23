import Foundation

/// 用量页的时间范围（仿 magpie `usage.Period`）
enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "今天"
        case .week: "7 天"
        case .month: "30 天"
        case .all: "全部"
        }
    }
}

enum UsageBucket: Sendable { case hour, day, week }

/// 「对话 / Code」筛选
enum UsageScope: String, CaseIterable, Identifiable, Sendable {
    case all, chat, code
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部"
        case .chat: "对话"
        case .code: "Code"
        }
    }

    func includes(_ r: UsageRecord) -> Bool {
        switch self {
        case .all: true
        case .chat: r.kind != .code
        case .code: r.kind == .code
        }
    }
}

struct UsageTotals: Equatable, Sendable {
    var calls = 0
    var errors = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0
    /// 已计价调用的标价费用
    var costUSD: Double = 0
    /// 有 token 但查不到价的调用次数
    var unpriced = 0
    var partial = 0
    var estimated = 0

    var tokens: Int { input + output }

    mutating func add(_ r: UsageRecord, cost: Double?) {
        calls += 1
        if r.status == .error { errors += 1 }
        input += r.input
        output += r.output
        cacheRead += r.cacheRead
        cacheWrite += r.cacheWrite
        reasoning += r.reasoning
        if r.tokensOnly || r.subscription { return }
        if r.effectiveCostSource == .partial && r.requestSent != false { partial += 1 }
        if r.input + r.output == 0 && r.costUSD == nil && r.webSearches == 0 { return }
        if r.effectiveCostSource == .estimated { estimated += 1 }
        if let cost { costUSD += cost } else { unpriced += 1 }
    }
}

/// 榜单一行（按模型 / 按 provider）
struct UsageGroup: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var totals = UsageTotals()
}

/// 时间柱的一根
struct UsagePoint: Identifiable, Equatable, Sendable {
    let start: Date
    let label: String
    var totals = UsageTotals()
    var id: Date { start }
}

struct UsageSummary: Equatable, Sendable {
    var period: UsagePeriod
    var since: Date
    var bucket: UsageBucket
    var totals = UsageTotals()
    var series: [UsagePoint] = []
    var models: [UsageGroup] = []
    var providers: [UsageGroup] = []
}

/// 仿 magpie `summarize()`：先铺空时间轴（今天按时、7 / 30 天按天、全部 ≤60 天按天否则按周），
/// 再把记录落桶；同时出按模型 / 按 provider 两张榜。纯函数，时钟 / 日历 / 价目表都从参数进。
enum UsageSummarizer {
    static func summarize(
        _ period: UsagePeriod,
        now: Date,
        records: [UsageRecord],
        calendar: Calendar = .current,
        scope: UsageScope = .all,
        price: (String) -> ModelPricing? = { PricingCatalog.price(for: $0) }
    ) -> UsageSummary {
        let records = UsageLedger.latestRecords(records).filter(scope.includes)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, from base: Date) -> Date { calendar.date(byAdding: .day, value: offset, to: base) ?? base }

        var since = today
        var bucket = UsageBucket.day
        var count = 1
        switch period {
        case .today:
            bucket = .hour
            count = 24
        case .week:
            since = day(-6, from: today)
            count = 7
        case .month:
            since = day(-29, from: today)
            count = 30
        case .all:
            if let first = records.map(\.time).min() {
                since = min(calendar.startOfDay(for: first), today)
            }
            count = days(from: since, to: today, calendar) + 1
            if count > 60 {
                bucket = .week
                // 从第一周的周一起
                let weekdayFromMonday = (calendar.component(.weekday, from: since) + 5) % 7
                since = day(-weekdayFromMonday, from: since)
                count = days(from: since, to: today, calendar) / 7 + 1
            }
        }

        var summary = UsageSummary(period: period, since: since, bucket: bucket)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = bucket == .hour ? "HH" : "M/d"
        summary.series = (0..<count).map { i in
            let start: Date
            switch bucket {
            case .hour: start = calendar.date(byAdding: .hour, value: i, to: since) ?? since
            case .day: start = day(i, from: since)
            case .week: start = day(7 * i, from: since)
            }
            return UsagePoint(start: start, label: formatter.string(from: start))
        }

        var priceMemo: [String: ModelPricing?] = [:]
        func cost(_ r: UsageRecord) -> Double? {
            r.cost { model in
                if let hit = priceMemo[model] { return hit }
                let p = price(model)
                priceMemo[model] = p
                return p
            }
        }

        var models: [String: UsageGroup] = [:]
        var providers: [String: UsageGroup] = [:]
        for r in records where r.time >= since {
            let c = cost(r)
            summary.totals.add(r, cost: c)
            let index: Int
            switch bucket {
            case .hour: index = calendar.dateComponents([.hour], from: since, to: r.time).hour ?? -1
            case .day: index = days(from: since, to: calendar.startOfDay(for: r.time), calendar)
            case .week: index = days(from: since, to: calendar.startOfDay(for: r.time), calendar) / 7
            }
            if summary.series.indices.contains(index) { summary.series[index].totals.add(r, cost: c) }
            models[r.model, default: UsageGroup(id: r.model, label: r.model)].totals.add(r, cost: c)
            providers[r.providerId, default: UsageGroup(id: r.providerId, label: r.providerName)].totals.add(r, cost: c)
            providers[r.providerId]?.label = r.providerName   // 记录升序 → 留下最近一次的名字
        }
        summary.models = ranked(models)
        summary.providers = ranked(providers)
        return summary
    }

    private static func days(from: Date, to: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 花费降序 → token 降序 → 次数降序 → id
    private static func ranked(_ groups: [String: UsageGroup]) -> [UsageGroup] {
        groups.values.sorted {
            if $0.totals.costUSD != $1.totals.costUSD { return $0.totals.costUSD > $1.totals.costUSD }
            if $0.totals.tokens != $1.totals.tokens { return $0.totals.tokens > $1.totals.tokens }
            if $0.totals.calls != $1.totals.calls { return $0.totals.calls > $1.totals.calls }
            return $0.id < $1.id
        }
    }
}
