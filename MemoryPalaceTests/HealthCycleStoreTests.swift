import XCTest
import SwiftData
@testable import 记忆花园

/// 月经追踪（plan-health-cycle §5 矩阵）：
/// 打点 upsert/改档/取消 · 周期聚合 · 预测 · 文案 · profileId 隔离。
@MainActor
final class HealthCycleStoreTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-cycle"

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: CycleDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func seed(_ offsets: [Int], flow: CycleFlow = .medium) {
        for o in offsets {
            HealthCycleStore.upsertDay(context: context, profileId: pid, date: day(o), flow: flow)
        }
    }

    // MARK: 打点

    func testUpsertSameDayChangesFlow() {
        HealthCycleStore.upsertDay(context: context, profileId: pid, date: day(0), flow: .light)
        HealthCycleStore.upsertDay(context: context, profileId: pid, date: day(0), flow: .heavy)
        let days = HealthCycleStore.fetchDays(context: context, profileId: pid)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].flow, "heavy")
    }

    func testToggleSameFlowRemoves() {
        XCTAssertEqual(HealthCycleStore.toggleToday(context: context, profileId: pid, flow: .medium), .medium)
        XCTAssertEqual(HealthCycleStore.toggleToday(context: context, profileId: pid, flow: .light), .light, "点别档=改档")
        XCTAssertNil(HealthCycleStore.toggleToday(context: context, profileId: pid, flow: .light), "点同档=取消")
        XCTAssertTrue(HealthCycleStore.fetchDays(context: context, profileId: pid).isEmpty)
    }

    func testProfileIsolation() {
        seed([0])
        HealthCycleStore.upsertDay(context: context, profileId: "other", date: day(0), flow: .light)
        XCTAssertEqual(HealthCycleStore.fetchDays(context: context, profileId: pid).count, 1)
    }

    // MARK: 聚合

    func testPeriodsSingleSpell() {
        seed([-4, -3, -2])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods[0].start, day(-4))
        XCTAssertEqual(periods[0].end, day(-2))
        XCTAssertEqual(periods[0].dayCount, 3)
    }

    func testPeriodsMissedOneDayStillSameSpell() {
        seed([-5, -3])  // 中间漏记一天（日期差 2）
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(periods.count, 1, "漏记一天不断周期")
    }

    func testPeriodsGapOfThreeBreaks() {
        seed([-33, -32, -3, -2])  // 日期差 29 断开
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(periods.count, 2)
    }

    // MARK: 预测

    func testPredictionNeedsTwoPeriods() {
        seed([-3, -2])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertNil(HealthCycleStore.prediction(periods: periods), "单段无预测")
    }

    func testPredictionAverageAndWindow() {
        // 两段：起始日差 28 天 → avg 28
        seed([-31, -30, -29, -3, -2, -1])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        let pred = HealthCycleStore.prediction(periods: periods)
        XCTAssertEqual(pred?.averageLength, 28)
        XCTAssertEqual(pred?.nextStart, day(-3 + 28))
        XCTAssertEqual(pred?.windowStart, day(-3 + 26))
        XCTAssertEqual(pred?.windowEnd, day(-3 + 30))
    }

    func testPredictionFiltersDirtyLengths() {
        // 起始日差 5 天（<15 域外）→ 过滤后无长度 → 不预测
        seed([-8, -3])  // 差 5 = 两段（>2 断开），长度 5 被滤
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(periods.count, 2)
        XCTAssertNil(HealthCycleStore.prediction(periods: periods), "脏长度不进预测")
    }

    func testCurrentCycleDay() {
        seed([-3, -2])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(HealthCycleStore.currentCycleDay(periods: periods, now: Date()), 4, "-3 天开始 = 今天第 4 天")
    }

    // MARK: 文案

    func testStatusLineInPeriod() {
        seed([-1, 0])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(HealthCycleStore.statusLine(todayFlow: .medium, periods: periods, now: Date()),
                       "经期第 2 天 · 经量中")
    }

    func testStatusLineNoPrediction() {
        seed([-2])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(HealthCycleStore.statusLine(todayFlow: nil, periods: periods, now: Date()),
                       "记录不足，暂无预测")
    }

    func testStatusLineCountdown() {
        // 起始日差 28 → avg 28，上段起始 -20 → 还有 8 天
        seed([-48, -47, -20, -19])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(HealthCycleStore.statusLine(todayFlow: nil, periods: periods, now: Date()),
                       "距下次预计还有 8 天")
    }

    func testStatusLineLate() {
        // avg 28，上段起始 -33 → 预计 -5 天 → 晚了 5 天（独立楼层避免脏数据）
        let pid2 = "xctest-cycle-late"
        for o in [-61, -60, -33, -32] {
            HealthCycleStore.upsertDay(context: context, profileId: pid2, date: day(o), flow: .medium)
        }
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid2))
        XCTAssertEqual(HealthCycleStore.statusLine(todayFlow: nil, periods: periods, now: Date()),
                       "比预计晚了 5 天")
    }

    func testInjectionLineVerbatim() {
        seed([-1, 0])
        let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: pid))
        XCTAssertEqual(HealthCycleStore.injectionLine(todayFlow: .medium, periods: periods, now: Date()),
                       "月经周期第 2 天（经量中）。")
    }

    // MARK: flow 解析

    func testFlowParse() {
        XCTAssertEqual(CycleFlow.parse("medium"), .medium)
        XCTAssertEqual(CycleFlow.parse("HEAVY"), .heavy)
        XCTAssertEqual(CycleFlow.parse("点滴"), .spotting)
        XCTAssertEqual(CycleFlow.parse("中"), .medium)
        XCTAssertNil(CycleFlow.parse("超多"))
    }
}
