import XCTest
import SwiftData
@testable import 记忆花园

/// 健康模块 P0-1 数据层（plan-health-module §1）：
/// 同日体重覆盖 / 漏服三态推导 / 单位换算 / profileId 隔离 / 注入摘要纯函数。
@MainActor
final class HealthLogStoreTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-health"

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: WeightEntry.self, Medication.self, MedicationLog.self, IntimacyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.weightGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.medsGateKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HealthLogStore.weightGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.medsGateKey)
        container = nil
        super.tearDown()
    }

    private func at(hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date()))!
        return day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    // MARK: 体重

    func testUpsertWeightSameDayOverwrites() {
        let noon = at(hour: 12)
        HealthLogStore.upsertWeight(context: context, profileId: pid, date: noon, weightKg: 52.5)
        HealthLogStore.upsertWeight(context: context, profileId: pid, date: at(hour: 20), weightKg: 52.1)
        let all = HealthLogStore.fetchRecentWeights(context: context, profileId: pid)
        XCTAssertEqual(all.count, 1, "同日重录应覆盖不新增")
        XCTAssertEqual(all[0].weightKg, 52.1, accuracy: 0.001)
        XCTAssertEqual(all[0].date, Calendar.current.startOfDay(for: noon), "date 应归一 startOfDay")
    }

    func testWeightProfileIsolation() {
        HealthLogStore.upsertWeight(context: context, profileId: pid, date: Date(), weightKg: 52.0)
        HealthLogStore.upsertWeight(context: context, profileId: "other", date: Date(), weightKg: 80.0)
        let mine = HealthLogStore.fetchRecentWeights(context: context, profileId: pid)
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine[0].weightKg, 52.0, accuracy: 0.001)
    }

    func testWeightUnitConversionRoundTrip() {
        XCTAssertEqual(WeightUnit.lb.fromKg(50), 110.231, accuracy: 0.01)
        XCTAssertEqual(WeightUnit.lb.toKg(WeightUnit.lb.fromKg(52.3)), 52.3, accuracy: 0.0001)
        XCTAssertEqual(WeightUnit.kg.fromKg(52.3), 52.3, accuracy: 0.0001)
    }

    // MARK: 漏服三态

    func testMedStateThreeStates() {
        let med = Medication(profileId: pid, name: "维生素 D", dosage: "1 片", timesOfDay: [480, 1260]) // 8:00 / 21:00
        context.insert(med)

        // 上午 9 点：8:00 未打卡但没超 2h 缓冲 → pending；21:00 未到 → pending
        var now = at(hour: 9)
        XCTAssertEqual(HealthLogStore.medState(medication: med, minuteOfDay: 480, todayLogs: [], now: now), .pending)
        XCTAssertEqual(HealthLogStore.medState(medication: med, minuteOfDay: 1260, todayLogs: [], now: now), .pending)

        // 中午 12 点：8:00 过点超 2h 无打卡 → missed
        now = at(hour: 12)
        XCTAssertEqual(HealthLogStore.medState(medication: med, minuteOfDay: 480, todayLogs: [], now: now), .missed)

        // 打卡后 → taken（含实际时间）
        HealthLogStore.logIntake(context: context, profileId: pid, medication: med, minuteOfDay: 480, now: now)
        let logs = HealthLogStore.fetchTodayLogs(context: context, profileId: pid, now: now)
        XCTAssertEqual(HealthLogStore.medState(medication: med, minuteOfDay: 480, todayLogs: logs, now: now), .taken(now))
    }

    func testUndoIntakeRemovesOnlyThatSlot() {
        let med = Medication(profileId: pid, name: "褪黑素", dosage: "5mg", timesOfDay: [480, 1260])
        context.insert(med)
        let now = at(hour: 21, minute: 30)
        HealthLogStore.logIntake(context: context, profileId: pid, medication: med, minuteOfDay: 480, now: now)
        HealthLogStore.logIntake(context: context, profileId: pid, medication: med, minuteOfDay: 1260, now: now)

        var logs = HealthLogStore.fetchTodayLogs(context: context, profileId: pid, now: now)
        HealthLogStore.undoIntake(context: context, todayLogs: logs, medication: med, minuteOfDay: 1260, now: now)

        logs = HealthLogStore.fetchTodayLogs(context: context, profileId: pid, now: now)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(HealthLogStore.medState(medication: med, minuteOfDay: 480, todayLogs: logs, now: now), .taken(now))
        XCTAssertEqual(HealthLogStore.medState(medication: med, minuteOfDay: 1260, todayLogs: logs, now: now), .pending)
    }

    // MARK: 注入摘要纯函数

    func testWeightSummaryTodayAndDelta() {
        let today = WeightEntry(profileId: pid, date: Date(), weightKg: 52.3)
        let old = WeightEntry(profileId: pid, date: at(hour: 8, dayOffset: -20), weightKg: 53.1)
        let line = HealthLogStore.weightSummary(weights: [today, old])
        XCTAssertEqual(line, "今天体重 52.3 公斤（30 天 -0.8）。")
    }

    func testWeightSummarySingleEntryNoDelta() {
        let e = WeightEntry(profileId: pid, date: at(hour: 8, dayOffset: -2), weightKg: 52.3)
        let line = HealthLogStore.weightSummary(weights: [e])
        XCTAssertTrue(line.hasPrefix("最近一次体重 52.3 公斤（"), line)
        XCTAssertFalse(line.contains("30 天"), "单条不报变化")
    }

    func testWeightSummaryEmpty() {
        XCTAssertEqual(HealthLogStore.weightSummary(weights: []), "")
    }

    func testMedsSummaryStates() {
        let med = Medication(profileId: pid, name: "维生素 D", dosage: "1 片", timesOfDay: [480, 1260])
        context.insert(med)
        let now = at(hour: 12)
        // 8:00 漏服 + 21:00 未到点
        var line = HealthLogStore.medsSummary(meds: [med], todayLogs: [], now: now)
        XCTAssertEqual(line, "今天的药：维生素 D 8:00 那次还没打卡；维生素 D 21:00 未到点。")

        // 打卡后
        HealthLogStore.logIntake(context: context, profileId: pid, medication: med, minuteOfDay: 480, now: at(hour: 8, minute: 10))
        let logs = HealthLogStore.fetchTodayLogs(context: context, profileId: pid, now: now)
        line = HealthLogStore.medsSummary(meds: [med], todayLogs: logs, now: now)
        XCTAssertEqual(line, "今天的药：维生素 D 8:10 已服；维生素 D 21:00 未到点。")
    }

    func testMedsSummaryDueUnlogged() {
        let med = Medication(profileId: pid, name: "维生素 D", dosage: "1 片", timesOfDay: [480])
        let now = at(hour: 9) // 过点 1h，缓冲内
        let line = HealthLogStore.medsSummary(meds: [med], todayLogs: [], now: now)
        XCTAssertEqual(line, "今天的药：维生素 D 8:00 该吃了还没打卡。")
    }

    func testMedsSummaryArchivedExcluded() {
        let med = Medication(profileId: pid, name: "旧药", dosage: "", timesOfDay: [480])
        med.isArchived = true
        XCTAssertEqual(HealthLogStore.medsSummary(meds: [med], todayLogs: [], now: at(hour: 9)), "")
    }

    // MARK: 闸门默认值（权限 P1 §4 收紧：新装默认全关；老装机由迁移写显式值保行为）

    func testGatesDefaultTightenedOff() {
        for d in [PermissionDomain.healthWeight, .healthMeds] {
            UserDefaults.standard.removeObject(forKey: d.storageKey)
            UserDefaults.standard.removeObject(forKey: d.legacy.key)
        }
        XCTAssertFalse(HealthLogStore.weightGateEnabled)
        XCTAssertFalse(HealthLogStore.medsGateEnabled)
        HealthLogStore.medsGateEnabled = true
        XCTAssertTrue(HealthLogStore.medsGateEnabled)
        XCTAssertEqual(PermissionCenter.level(.healthMeds), .bypass, "setter 委托必须写穿档位")
        HealthLogStore.medsGateEnabled = false
        UserDefaults.standard.removeObject(forKey: PermissionDomain.healthMeds.storageKey)
    }

    // MARK: 亲密（plan-health-intimacy：一天一条 / toggle / note upsert / 隔离 / 双默认关）

    func testIntimacyToggleRecordsAndCancels() {
        let noon = at(hour: 12)
        XCTAssertTrue(HealthLogStore.toggleIntimacyToday(context: context, profileId: pid, now: noon))
        let entry = HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: noon)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.date, Calendar.current.startOfDay(for: noon), "date 应归一 startOfDay")
        XCTAssertFalse(HealthLogStore.toggleIntimacyToday(context: context, profileId: pid, now: noon), "再点=取消")
        XCTAssertNil(HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: noon))
    }

    func testIntimacyUpsertSameDayOneEntryNoteUpdates() {
        let noon = at(hour: 12)
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: noon, note: "第一版")
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: at(hour: 20), note: "改了")
        let entry = HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: noon)
        XCTAssertEqual(entry?.note, "改了", "同日 upsert = 改 note 不新增")
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: noon)
        XCTAssertEqual(HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: noon)?.note, "改了",
                       "note 传 nil 不动已有备注")
    }

    func testIntimacyProfileIsolation() {
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: Date())
        XCTAssertNil(HealthLogStore.fetchIntimacy(context: context, profileId: "other", date: Date()))
    }

    func testIntimacyBothKeysDefaultOff() {
        UserDefaults.standard.removeObject(forKey: HealthLogStore.intimacyGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.intimacyShowKey)
        XCTAssertFalse(HealthLogStore.intimacyGateEnabled, "AI 闸默认关")
        XCTAssertFalse(HealthLogStore.showIntimacyCard, "卡可见默认关")
    }
}
