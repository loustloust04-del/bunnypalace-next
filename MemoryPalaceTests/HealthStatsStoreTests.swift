import XCTest
import SwiftData
@testable import 记忆花园

/// 卡详情统计纯函数（plan-health-card-details §三）：
/// 完成度/依从率/漏服/月均/月频次——空数据/单条/跨月边界/部分完成/计划外不计入/createdAt 截断。
@MainActor
final class HealthStatsStoreTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-health-stats"
    let cal = Calendar.current

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: WeightEntry.self, Medication.self, MedicationLog.self, IntimacyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func day(_ offset: Int, hour: Int = 0) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
            .addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func med(_ name: String = "维生素 D", times: [Int] = [480], createdDaysAgo: Int = 30) -> Medication {
        let m = Medication(profileId: pid, name: name, dosage: "1 片", timesOfDay: times)
        m.createdAt = day(-createdDaysAgo)
        context.insert(m)
        try! context.save()
        return m
    }

    private func take(_ med: Medication, dayOffset: Int, minute: Int) -> MedicationLog {
        let slot = HealthLogStore.scheduledDate(minuteOfDay: minute, on: day(dayOffset))
        let log = MedicationLog(profileId: pid, medicationId: med.id, scheduledAt: slot, takenAt: slot)
        context.insert(log)
        try! context.save()
        return log
    }

    // MARK: 完成度

    func testDayCompletionFullPartialNone() {
        let m = med(times: [480, 1260])
        let now = day(0, hour: 23)
        _ = take(m, dayOffset: -1, minute: 480)
        XCTAssertEqual(HealthStatsStore.dayCompletion(meds: [m], logs: fetchLogs(), day: day(-1), now: now)!, 0.5, accuracy: 0.001, "两 slot 打一 = 0.5")
        _ = take(m, dayOffset: -1, minute: 1260)
        XCTAssertEqual(HealthStatsStore.dayCompletion(meds: [m], logs: fetchLogs(), day: day(-1), now: now)!, 1.0, accuracy: 0.001)
        XCTAssertEqual(HealthStatsStore.dayCompletion(meds: [m], logs: fetchLogs(), day: day(-2), now: now)!, 0.0, accuracy: 0.001, "全漏 = 0")
    }

    func testDayCompletionExtraDoseNotCounted() {
        let m = med(times: [480])
        let now = day(0, hour: 23)
        context.insert(MedicationLog(profileId: pid, medicationId: m.id, scheduledAt: nil, takenAt: day(-1, hour: 15)))
        try! context.save()
        XCTAssertEqual(HealthStatsStore.dayCompletion(meds: [m], logs: fetchLogs(), day: day(-1), now: now)!, 0.0, accuracy: 0.001, "计划外补服不进完成度")
    }

    func testDayCompletionBoundaries() {
        let m = med(times: [480], createdDaysAgo: 2)
        let now = day(0, hour: 9)
        XCTAssertNil(HealthStatsStore.dayCompletion(meds: [m], logs: [], day: day(-5), now: now), "createdAt 前的天不欠账")
        XCTAssertNil(HealthStatsStore.dayCompletion(meds: [m], logs: [], day: day(1), now: now), "未来日无计划")
        XCTAssertNil(HealthStatsStore.dayCompletion(meds: [], logs: [], day: day(-1), now: now), "无药 = nil")
    }

    func testDayCompletionTodayFutureSlotNotOwed() {
        let m = med(times: [480, 1260])
        let now = day(0, hour: 9)   // 21:00 未到
        _ = take(m, dayOffset: 0, minute: 480)
        XCTAssertEqual(HealthStatsStore.dayCompletion(meds: [m], logs: fetchLogs(), day: day(0), now: now)!, 1.0, accuracy: 0.001, "今天未到点的 slot 不算欠")
    }

    func testMonthCompletionSpansOnlyThisMonth() {
        let m = med(times: [480], createdDaysAgo: 40)
        let now = day(0, hour: 23)
        let map = HealthStatsStore.medMonthCompletion(meds: [m], logs: [], month: now, now: now)
        let interval = cal.dateInterval(of: .month, for: now)!
        XCTAssertTrue(map.keys.allSatisfy { $0 >= interval.start && $0 < interval.end }, "只含本月的天")
        XCTAssertTrue(map.keys.allSatisfy { $0 <= cal.startOfDay(for: now) }, "不含未来天")
    }

    // MARK: 依从率 / 漏服

    func testAdherenceAndMissCount() {
        let m = med(times: [480])
        let now = day(0, hour: 23)
        _ = take(m, dayOffset: 0, minute: 480)
        _ = take(m, dayOffset: -1, minute: 480)
        // 近 3 天：打 2 漏 1
        XCTAssertEqual(HealthStatsStore.medAdherence(med: m, logs: fetchLogs(), days: 3, now: now)!, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(HealthStatsStore.medMissCount(med: m, logs: fetchLogs(), days: 3, now: now), 1)
    }

    func testMissCountRespectsGrace() {
        let m = med(times: [480])
        let now = day(0, hour: 9)   // 8:00 slot 过点 1h < 2h 缓冲
        XCTAssertEqual(HealthStatsStore.medMissCount(med: m, logs: [], days: 1, now: now), 0, "缓冲期内不算漏")
    }

    func testAdherenceNoPlanNil() {
        let m = med(times: [], createdDaysAgo: 5)
        XCTAssertNil(HealthStatsStore.medAdherence(med: m, logs: [], days: 7, now: day(0, hour: 9)))
    }

    // MARK: 体重月均

    func testWeightMonthlyAvg() {
        HealthLogStore.upsertWeight(context: context, profileId: pid, date: day(-1), weightKg: 52.0)
        HealthLogStore.upsertWeight(context: context, profileId: pid, date: day(0), weightKg: 53.0)
        let entries = HealthLogStore.fetchRecentWeights(context: context, profileId: pid)
        let sameMonth = cal.dateInterval(of: .month, for: day(-1))?.start == cal.dateInterval(of: .month, for: day(0))?.start
        let avgs = HealthStatsStore.weightMonthlyAvg(entries: entries)
        if sameMonth {
            XCTAssertEqual(avgs.count, 1)
            XCTAssertEqual(avgs[0].avgKg, 52.5, accuracy: 0.001)
        } else {
            XCTAssertEqual(avgs.count, 2, "跨月各归各月")
            XCTAssertEqual(avgs.map(\.avgKg), [52.0, 53.0], "升序")
        }
    }

    func testWeightMonthlyAvgEmpty() {
        XCTAssertTrue(HealthStatsStore.weightMonthlyAvg(entries: []).isEmpty)
    }

    // MARK: 亲密月频次

    func testIntimacyMonthlyCountIncludesZeroMonths() {
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: day(0))
        let entries = [HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: day(0))!]
        let counts = HealthStatsStore.intimacyMonthlyCount(entries: entries, months: 3, now: day(0, hour: 9))
        XCTAssertEqual(counts.count, 3, "无记录月也出（=0）")
        XCTAssertEqual(counts.last?.count, 1)
        XCTAssertEqual(counts.dropLast().map(\.count), [0, 0])
        XCTAssertTrue(counts[0].month < counts[1].month, "升序")
    }

    private func fetchLogs() -> [MedicationLog] {
        (try? context.fetch(FetchDescriptor<MedicationLog>())) ?? []
    }
}
