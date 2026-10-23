import XCTest
import SwiftData
@testable import 记忆花园

/// 健康模块 P0-5 注入（plan-health-module §5）：
/// composedHealthSummary 段落拼装 × 闸门矩阵 + 逐字锚（缓存安全：同数据同时刻注入串逐字稳定）。
/// 苹果健康段在测试机 = HealthService stub/无授权 → 恒空串，矩阵只锚体重/吃药段。
@MainActor
final class HealthInjectionTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-health-inject"

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: WeightEntry.self, Medication.self, MedicationLog.self, CycleDay.self, IntimacyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.weightGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.medsGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.cycleGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.intimacyGateKey)
        for d in [PermissionDomain.healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy] {
            UserDefaults.standard.removeObject(forKey: d.storageKey)
        }
        // §4 收紧后默认全关；本套用例的"体重/吃药可见"前提改由显式声明
        HealthLogStore.weightGateEnabled = true
        HealthLogStore.medsGateEnabled = true

    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HealthLogStore.weightGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.medsGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.cycleGateKey)
        UserDefaults.standard.removeObject(forKey: HealthLogStore.intimacyGateKey)
        for d in [PermissionDomain.healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy] {
            UserDefaults.standard.removeObject(forKey: d.storageKey)
        }

        container = nil
        super.tearDown()
    }

    private func seedWeightToday(_ kg: Double) {
        HealthLogStore.upsertWeight(context: context, profileId: pid, date: Date(), weightKg: kg)
    }

    private func seedMed() -> Medication {
        let med = Medication(profileId: pid, name: "维生素 D", dosage: "1 片", timesOfDay: [480])
        context.insert(med)
        try? context.save()
        return med
    }

    func testEmptyDataEmptySummary() {
        XCTAssertEqual(HealthLogStore.composedHealthSummary(context: context, profileId: pid), "",
                       "无数据 = 空串 = 插槽自动跳过")
    }

    func testGatesAllOffEmptySummary() {
        seedWeightToday(52.3)
        _ = seedMed()
        HealthLogStore.weightGateEnabled = false
        HealthLogStore.medsGateEnabled = false
        XCTAssertEqual(HealthLogStore.composedHealthSummary(context: context, profileId: pid), "")
    }

    func testWeightOnlyVerbatim() {
        seedWeightToday(52.3)
        HealthLogStore.medsGateEnabled = false
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "今天体重 52.3 公斤。",
            "逐字锚：注入串漂移会毁 prompt 缓存前缀"
        )
    }

    func testWeightAndMedsComposedVerbatim() {
        seedWeightToday(52.3)
        _ = seedMed()
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(7 * 3600) // 7:00，8:00 未到点
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "今天体重 52.3 公斤。今天的药：维生素 D 8:00 未到点。"
        )
    }

    func testMedsGateOffDropsSection() {
        seedWeightToday(52.3)
        _ = seedMed()
        HealthLogStore.medsGateEnabled = false
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(7 * 3600)
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "今天体重 52.3 公斤。"
        )
    }

    func testProfileIsolation() {
        seedWeightToday(52.3)
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        XCTAssertEqual(HealthLogStore.composedHealthSummary(context: context, profileId: "other", now: now), "",
                       "别的楼层看不到本楼层数据")
    }

    // MARK: cycle 闸（默认关！）

    func testCycleGateDefaultOffAnchor() {
        seedWeightToday(52.3)
        // 种经期数据但不开闸 → 注入串与无 cycle 时代逐字一致（缓存安全锚）
        HealthCycleStore.upsertDay(context: context, profileId: pid, date: Date(), flow: .medium)
        HealthLogStore.medsGateEnabled = false
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "今天体重 52.3 公斤。",
            "cycle 闸默认关 = 现有输出零字节变化"
        )
    }

    func testCycleGateOnInPeriodVerbatim() {
        HealthLogStore.weightGateEnabled = false
        HealthLogStore.medsGateEnabled = false
        HealthLogStore.cycleGateEnabled = true
        let cal = Calendar.current
        HealthCycleStore.upsertDay(context: context, profileId: pid,
                                   date: cal.date(byAdding: .day, value: -1, to: Date())!, flow: .medium)
        HealthCycleStore.upsertDay(context: context, profileId: pid, date: Date(), flow: .medium)
        let now = cal.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "月经周期第 2 天（经量中）。"
        )
    }

    // MARK: intimacy 闸（默认关！口径只报当天）

    func testIntimacyGateDefaultOffAnchor() {
        seedWeightToday(52.3)
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: Date(), note: "私密备注")
        HealthLogStore.medsGateEnabled = false
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "今天体重 52.3 公斤。",
            "intimacy 闸默认关 = 现有输出零字节变化"
        )
    }

    func testIntimacyGateOnTodayVerbatim() {
        HealthLogStore.weightGateEnabled = false
        HealthLogStore.medsGateEnabled = false
        HealthLogStore.intimacyGateEnabled = true
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: Date(), note: "私密备注")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "今天有亲密记录。",
            "口径只报当天一句，note 不注入"
        )
    }

    func testIntimacyGateOnYesterdayOnlyEmpty() {
        HealthLogStore.weightGateEnabled = false
        HealthLogStore.medsGateEnabled = false
        HealthLogStore.intimacyGateEnabled = true
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        HealthLogStore.upsertIntimacy(context: context, profileId: pid, date: yesterday)
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        XCTAssertEqual(
            HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now),
            "",
            "开闸但今天没有 = 空（不带历史/距离感）"
        )
    }

    func testDeterministicAcrossCalls() {
        seedWeightToday(52.3)
        _ = seedMed()
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(7 * 3600)
        let a = HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now)
        let b = HealthLogStore.composedHealthSummary(context: context, profileId: pid, now: now)
        XCTAssertEqual(a, b, "同数据同时刻逐字稳定（缓存安全）")
    }
}
