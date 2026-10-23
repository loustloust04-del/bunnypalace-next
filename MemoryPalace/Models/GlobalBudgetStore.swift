import Foundation

/// 全局保险闸 — 水库总闸门。
///
/// 粟粟决策（2026-04-23）：所有 API 请求（无论 provider、无论主/副模型）汇总到
/// 一份总账，对照一份总预算。和 provider / model 路由本身无关。
///
/// 旧的 per-provider `budgetUSD/spentUSD/budgetEnabled` 字段和 `providerBudgets`
/// UserDefaults key 不再使用（按"清零重来"策略不迁移），但 APIProvider 里的
/// Codable 字段保留避免破坏老 customProviders JSON 的兼容性。
@Observable
final class GlobalBudgetStore {
    static let shared = GlobalBudgetStore()

    /// 从未拨款时的**默认有效额度**（粟粟 08-27 拍：10 美元）。
    /// 不是「不限」——不限要用户自己填一个大数。明确填 0 仍然是全停。
    static let defaultBudgetUSD: Double = 10

    private let enabledKey = "globalBudgetEnabled"
    private let budgetKey  = "globalBudgetUSD"
    private let spentKey   = "globalSpentUSD"
    private let spentResetAtKey = "globalSpentResetAt"
    @ObservationIgnored private var correctionCharges: [String: Double] = [:]

    private(set) var enabled: Bool
    private(set) var budgetUSD: Double
    private(set) var spentUSD: Double

    /// **从未拨过款**（`globalBudgetUSD` 这个 key 在 UserDefaults 里根本不存在）。
    ///
    /// 必须和「明确填了 0」分开：`UserDefaults.double(forKey:)` 对不存在的 key 返回 0，
    /// 而闸门把 `budget <= 0` 判成「未拨款一律拦截」——两件事撞在一起的结果是
    /// **全新安装第一条消息就被自己的保险闸拦死**（BUG-1，codex 在新模拟器容器上撞到）。
    /// 现在：没填过 = 按 `defaultBudgetUSD`（10 美元）计闸，明确填 0 = 拦死（那是「全停」的意思）。
    private(set) var isBudgetSet: Bool

    /// 上次「重置已用」的时刻（nil = 从没重置过）。账本汇总 spent 从这里算起。
    private(set) var spentResetAt: Date?

    private init() {
        let defaults = UserDefaults.standard
        // 默认开启保险闸（粟粟习惯是"防止烧干 key"，不是"默认放行"）
        if defaults.object(forKey: enabledKey) != nil {
            self.enabled = defaults.bool(forKey: enabledKey)
        } else {
            self.enabled = true
        }
        self.isBudgetSet = defaults.object(forKey: budgetKey) != nil
        self.budgetUSD = defaults.double(forKey: budgetKey)
        self.spentUSD  = defaults.double(forKey: spentKey)
        self.spentResetAt = defaults.object(forKey: spentResetAtKey) as? Date
    }

    // MARK: - Mutations

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    func setBudgetUSD(_ value: Double) {
        let clamped = max(0, value)
        budgetUSD = clamped
        isBudgetSet = true
        UserDefaults.standard.set(clamped, forKey: budgetKey)
    }

    /// 清回「没填过」= 回到默认 10（不是不限）。UI 里把预算框清空再保存走这条。
    func clearBudget() {
        budgetUSD = 0
        isBudgetSet = false
        UserDefaults.standard.removeObject(forKey: budgetKey)
    }

    /// 发送后把实际 cost（USD）累加到 spent。
    func commitSpend(_ amount: Double) {
        guard amount > 0 else { return }
        spentUSD += amount
        UserDefaults.standard.set(spentUSD, forKey: spentKey)
    }

    static func costCorrectionDelta(original: UsageRecord, corrected: UsageRecord, previousCharge: Double? = nil) -> Double {
        (corrected.costUSD ?? 0) - (previousCharge ?? original.budgetChargeUSD ?? original.costUSD ?? 0)
    }

    func applyCostCorrection(original: UsageRecord, corrected: UsageRecord) {
        if let spentResetAt, original.time < spentResetAt { return }
        let id = original.invocationId ?? corrected.invocationId
        let previous = id.flatMap { correctionCharges[$0] }
        spentUSD = max(0, spentUSD + Self.costCorrectionDelta(original: original, corrected: corrected, previousCharge: previous))
        if let id { correctionCharges[id] = corrected.costUSD }
        UserDefaults.standard.set(spentUSD, forKey: spentKey)
    }

    /// 重置"已用"；预算上限保留。
    func resetSpent() {
        correctionCharges = [:]
        spentUSD = 0
        UserDefaults.standard.set(0.0, forKey: spentKey)
        spentResetAt = Date()
        UserDefaults.standard.set(spentResetAt, forKey: spentResetAtKey)
    }

    // MARK: - 账本汇总（research-magpie 2.1）
    //
    // `spentUSD` 仍是闸门的实时标量（兼容：各调用点照旧 commitSpend）；账本上线后它**可以**由 usage.jsonl
    // 汇总重算。两者口径略有差：标量对缺 usage 的请求按 pre-send 估算扣，账本只有真实 usage。
    // 所以不自动覆盖，粟粟在用量页点「按账本校准」时才重算。

    /// 账本口径的「已用」：`since` 之后的 API 调用按 cache-aware 标价求和；查不到价按 `budgetFallback`
    /// 保守价（与闸门一致，宁可多算）；订阅通道、Code 会话不花 API 钱不计。
    static func ledgerSpentUSD(
        records: [UsageRecord],
        since: Date?,
        price: (String) -> ModelPricing? = { PricingCatalog.price(for: $0) }
    ) -> Double {
        UsageLedger.latestRecords(records).reduce(0) { sum, r in
            if let since, r.time < since { return sum }
            if r.tokensOnly || r.subscription { return sum }
            if let charge = r.budgetChargeUSD { return sum + charge }
            if r.costSource != nil { return sum + r.budgetCost(estimatedCost: 0, price: price) }
            return sum + (r.cost(price: price) ?? r.cost(price: { _ in PricingCatalog.budgetFallback }) ?? 0)
        }
    }

    /// 用账本重算「已用」（从上次重置起；没重置过就是账本全部）。
    func calibrateSpent(fromLedger records: [UsageRecord]) {
        for row in UsageLedger.latestRecords(records) where row.correction {
            if let spentResetAt, row.time < spentResetAt { continue }
            if let id = row.invocationId { correctionCharges[id] = row.budgetChargeUSD ?? row.costUSD }
        }
        spentUSD = Self.ledgerSpentUSD(records: records, since: spentResetAt)
        UserDefaults.standard.set(spentUSD, forKey: spentKey)
    }
}
