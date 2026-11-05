import Foundation

/// 写入预算的周期（plan §四）：关闭 = 不限（默认 = 今天的行为）
enum WriteBudgetPeriod: String, CaseIterable, Identifiable {
    case off, week, day
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .week: return "周"
        case .day: return "日"
        }
    }
}

/// 写入预算（plan §四，粟粟 10-15「控件一样，单独」）：单独一份、只管后台写手 A2 A3 A4 C2 C3。
/// B1 / B4 是{助手}本人调工具，不算；本机模型记 $0。已花 = 账本里本期这几类用途相加（照 `GlobalBudgetStore.ledgerSpentUSD`），不另记。
/// 超了：后台写手跳过（不算失败、不变红）；手动「现在写」不看它（Q10），全局总闸照查
@Observable
final class WriteBudgetStore: BudgetAccount {
    static let shared = WriteBudgetStore()

    static let periodKey = "mem_wb_period"
    static let budgetKey = "mem_wb_usd"
    static let resetAtKey = "mem_wb_reset_at"
    static let defaultBudget: Double = 5

    /// 后台写手记账的用途：A2 上下文摘要（.summary）、A3 窗口总结、A4 时间轴、C2 碎片池（.memory）、C3 整理编目；
    /// 加上试写台的试写（同一条账，规格 §5-3：算进合计，但试写自己不被拦）
    static let kinds: Set<UsageKind> = [.summary, .windowSummary, .timeline, .memory, .catalog, .memoryTrial]

    private(set) var period: WriteBudgetPeriod
    private(set) var budgetUSD: Double
    private(set) var isBudgetSet: Bool
    private(set) var resetAt: Date?
    /// 界面显示用：后台从账本算好推上来（`refreshSpent`），主线程不读盘
    private(set) var spentUSD: Double = 0

    var defaultBudgetUSD: Double { Self.defaultBudget }

    private init(defaults: UserDefaults = .standard) {
        period = defaults.string(forKey: Self.periodKey).flatMap(WriteBudgetPeriod.init(rawValue:)) ?? .off
        isBudgetSet = defaults.object(forKey: Self.budgetKey) != nil
        budgetUSD = defaults.double(forKey: Self.budgetKey)
        resetAt = defaults.object(forKey: Self.resetAtKey) as? Date
    }

    var effectiveBudget: Double { isBudgetSet ? budgetUSD : Self.defaultBudget }

    // MARK: - 改

    func setPeriod(_ p: WriteBudgetPeriod) {
        period = p
        UserDefaults.standard.set(p.rawValue, forKey: Self.periodKey)
        Task { await self.refreshSpent() }
    }

    func setBudgetUSD(_ value: Double) {
        budgetUSD = max(0, value)
        isBudgetSet = true
        UserDefaults.standard.set(budgetUSD, forKey: Self.budgetKey)
    }

    func clearBudget() {
        budgetUSD = 0
        isBudgetSet = false
        UserDefaults.standard.removeObject(forKey: Self.budgetKey)
    }

    /// 重置已用：从现在起算（本期开头和重置时刻取晚的）
    func resetSpent() {
        let now = Date()
        resetAt = now
        spentUSD = 0
        UserDefaults.standard.set(now, forKey: Self.resetAtKey)
    }

    /// 后台读账本算本期已花，算完回主线程更新
    func refreshSpent() async {
        let since = Self.since(period: period, resetAt: resetAt, now: Date())
        let value = await Task.detached(priority: .utility) {
            Self.spent(records: UsageLedger.shared.load(since: since), since: since)
        }.value
        await MainActor.run { self.spentUSD = value }
    }

    // MARK: - 纯函数（可测）

    /// 本期从哪天起：周 = 这周一 0 点，日 = 今天 0 点；和「重置已用」取晚的。关闭 = nil
    static func since(period: WriteBudgetPeriod, resetAt: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        let start: Date
        switch period {
        case .off: return nil
        case .day:
            start = calendar.startOfDay(for: now)
        case .week:
            var cal = calendar
            cal.firstWeekday = 2
            start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        }
        guard let resetAt else { return start }
        return max(start, resetAt)
    }

    /// 账本里本期后台写手那几类用途相加（口径同全局闸）
    static func spent(records: [UsageRecord], since: Date?) -> Double {
        GlobalBudgetStore.ledgerSpentUSD(records: records.filter { kinds.contains($0.kind) }, since: since)
    }

    /// 后台写手动笔前查（在后台线程调）：周期开着且本期已花 ≥ 上限 = 超了
    static func exceeded(defaults: UserDefaults = .standard, now: Date = Date(),
                         records: (Date?) -> [UsageRecord] = { UsageLedger.shared.load(since: $0) }) -> Bool {
        let period = defaults.string(forKey: periodKey).flatMap(WriteBudgetPeriod.init(rawValue:)) ?? .off
        guard period != .off else { return false }
        let limit = defaults.object(forKey: budgetKey) != nil ? defaults.double(forKey: budgetKey) : defaultBudget
        let since = since(period: period, resetAt: defaults.object(forKey: resetAtKey) as? Date, now: now)
        return spent(records: records(since), since: since) >= limit
    }

    /// 状态卡灰字：「写入预算用完，下周一再写」
    static func pausedText(period: WriteBudgetPeriod) -> String {
        period == .day ? "写入预算用完，明天再写" : "写入预算用完，下周一再写"
    }

    /// 主页那一行的副标题：「后台写记忆的钱 · $0.42 / $5 · 每周」/「后台写记忆的钱 · 不限」
    func summary() -> String {
        guard period != .off else { return "后台写记忆的钱 · 不限" }
        let per = period == .week ? "每周" : "每天"
        return String(format: "后台写记忆的钱 · $%.2f / $%@ · %@", spentUSD, Self.amount(effectiveBudget), per)
    }

    static func amount(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}
