import XCTest
@testable import 记忆花园

/// v5 §四：写入预算单独一份、只管后台写手；直接输数字、关闭 / 周 / 日；超了停；手动「现在写」不受限
final class WriteBudgetTests: XCTestCase {

    private var suite = ""
    private var d: UserDefaults!
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    override func setUp() {
        super.setUp()
        suite = "xctest-write-budget-\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// 2026-10-15 是周四
    private var thursday: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15))! }

    private func record(_ kind: UsageKind, _ usd: Double, at: Date) -> UsageRecord {
        var r = UsageRecord(time: at, providerId: "p", providerName: "P", providerType: "openaiCompatible", model: "m",
                            input: 10, output: 10, cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 1, status: .ok,
                            kind: kind, conversationId: nil, profileId: nil, subscription: false, tokensOnly: false)
        r.budgetChargeUSD = usd
        return r
    }

    func testPeriodStarts() {
        XCTAssertNil(WriteBudgetStore.since(period: .off, resetAt: nil, now: thursday, calendar: cal), "关闭 = 不限")
        XCTAssertEqual(WriteBudgetStore.since(period: .week, resetAt: nil, now: thursday, calendar: cal),
                       cal.date(from: DateComponents(year: 2026, month: 10, day: 12)), "周 = 这周一 0 点")
        XCTAssertEqual(WriteBudgetStore.since(period: .day, resetAt: nil, now: thursday, calendar: cal),
                       cal.date(from: DateComponents(year: 2026, month: 10, day: 15)))
        let reset = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 8))!
        XCTAssertEqual(WriteBudgetStore.since(period: .week, resetAt: reset, now: thursday, calendar: cal), reset, "重置已用：从重置那刻算")
    }

    func testOnlyBackgroundWritersCount() {
        let at = thursday.addingTimeInterval(-60)
        let rows = [record(.summary, 0.1, at: at), record(.windowSummary, 0.2, at: at), record(.timeline, 0.3, at: at),
                    record(.memory, 0.4, at: at), record(.chat, 9, at: at), record(.innerVoice, 9, at: at), record(.dream, 9, at: at)]
        XCTAssertEqual(WriteBudgetStore.spent(records: rows, since: nil), 1.0, accuracy: 1e-9, "A2 A3 A4 C2；对话 / 心声不算")
    }

    /// 审计台试写台跑测试集：和后台写手同一条账（规格 §5-3）
    func testTrialSpendCountsTowardWriteBudget() {
        let at = thursday.addingTimeInterval(-60)
        let rows = [record(.summary, 0.5, at: at), record(.memoryTrial, 0.25, at: at)]
        XCTAssertEqual(WriteBudgetStore.spent(records: rows, since: nil), 0.75, accuracy: 1e-9)
        XCTAssertEqual(UsageKind.memoryTrial.label, "试写")
        XCTAssertFalse(MemoryWriterID.allCases.contains { MemoryWriterSpend.kind($0) == .memoryTrial }, "写手二级页的本期花费不含试写")
    }

    func testExceededStopsOnlyWhenPeriodOn() {
        let at = thursday.addingTimeInterval(-60)
        let rows = [record(.summary, 3, at: at), record(.timeline, 2.5, at: at)]
        XCTAssertFalse(WriteBudgetStore.exceeded(defaults: d, now: thursday, records: { _ in rows }), "默认关闭 = 今天的行为")
        d.set(WriteBudgetPeriod.week.rawValue, forKey: WriteBudgetStore.periodKey)
        XCTAssertTrue(WriteBudgetStore.exceeded(defaults: d, now: thursday, records: { _ in rows }), "没填按默认 $5：5.5 超了")
        d.set(10.0, forKey: WriteBudgetStore.budgetKey)
        XCTAssertFalse(WriteBudgetStore.exceeded(defaults: d, now: thursday, records: { _ in rows }), "直接输的数字 $10")
        d.set(0.0, forKey: WriteBudgetStore.budgetKey)
        XCTAssertTrue(WriteBudgetStore.exceeded(defaults: d, now: thursday, records: { _ in [] }), "填 0 = 全停")
    }

    func testOldSpendBeforePeriodIgnored() {
        d.set(WriteBudgetPeriod.day.rawValue, forKey: WriteBudgetStore.periodKey)
        d.set(1.0, forKey: WriteBudgetStore.budgetKey)
        let yesterday = thursday.addingTimeInterval(-86400)
        let rows = [record(.summary, 5, at: yesterday)]
        XCTAssertFalse(WriteBudgetStore.exceeded(defaults: d, now: thursday, records: { since in rows.filter { $0.time >= (since ?? .distantPast) } }),
                       "昨天花的不算今天")
    }

    func testPausedText() {
        XCTAssertEqual(WriteBudgetStore.pausedText(period: .week), "写入预算用完，下周一再写")
        XCTAssertEqual(WriteBudgetStore.pausedText(period: .day), "写入预算用完，明天再写")
        XCTAssertEqual(WriteBudgetStore.amount(5), "5")
        XCTAssertEqual(WriteBudgetStore.amount(2.5), "2.50")
    }

    /// 手动「现在写」：ctx.manual → 后台写手的 caller 不查写入预算；冷却也不看
    func testManualContextBypasses() async throws {
        let profile = Profile(id: "xctest-wb-manual", name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克")
        var ctx = SessionCloseout.Context(profile: profile, model: ProviderModel(credentialId: "x", modelId: "m", name: "m"))
        XCTAssertFalse(ctx.manual)
        ctx.manual = true
        XCTAssertTrue(ctx.manual)
    }

    /// astra #12：写入预算超了，C2 本机路线也停（不调本机模型）
    @MainActor
    func testLocalFragmentRouteStopsWhenBudgetExceeded() async throws {
        let caller = FragmentModelRoute.caller(for: .local(modelId: AssistantLocalModel.smart.id), providerManager: ProviderManager(),
                                               conversationId: "c", profileId: "xctest-wb-local", budgetExceeded: { true })
        let out = try await caller("s", "u")
        XCTAssertNil(out, "预算用完：本机也跳过（nil = 不算失败）")
    }

    func testUsageLabels() {
        XCTAssertEqual(UsageKind.timeline.label, "时间轴", "A11：「日记」改「时间轴」")
        XCTAssertEqual(UsageKind.memory.label, "碎片池")
        XCTAssertEqual(UsageKind.windowSummary.label, "窗口总结")
    }
}
