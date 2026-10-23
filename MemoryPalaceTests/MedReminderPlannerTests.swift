import XCTest
import UserNotifications
@testable import 记忆花园

/// 健康模块 P0-2 提醒（plan-health-module §2）：
/// 计划展开 / identifier 幂等 / 归档·关提醒不出计划 / 上限守卫 / resync 清旧加新 / 权限被拒不注册。
@MainActor
final class MedReminderPlannerTests: XCTestCase {

    let pid = "xctest-medreminder"

    private func med(_ name: String, times: [Int], reminder: Bool = true, archived: Bool = false) -> Medication {
        let m = Medication(profileId: pid, name: name, dosage: "1 片", timesOfDay: times, reminderEnabled: reminder)
        m.isArchived = archived
        return m
    }

    // MARK: 计划纯函数

    func testPlanExpandsAndSortsTimes() {
        let (specs, truncated) = MedReminderPlanner.plan(meds: [med("维生素 D", times: [1260, 480])])
        XCTAssertFalse(truncated)
        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs[0].hour, 8); XCTAssertEqual(specs[0].minute, 0)
        XCTAssertEqual(specs[1].hour, 21); XCTAssertEqual(specs[1].minute, 0)
        XCTAssertEqual(specs[0].title, "维生素 D", "通知标题=药名（粟粟拍板）")
        XCTAssertEqual(specs[0].body, "1 片 · 该吃药啦")
    }

    func testPlanIdentifierDeterministic() {
        let m = med("褪黑素", times: [1260])
        let a = MedReminderPlanner.plan(meds: [m]).specs[0].identifier
        let b = MedReminderPlanner.plan(meds: [m]).specs[0].identifier
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("med-"))
        XCTAssertTrue(a.hasSuffix("-1260"))
    }

    func testPlanExcludesArchivedAndReminderOff() {
        let (specs, _) = MedReminderPlanner.plan(meds: [
            med("正常", times: [480]),
            med("归档", times: [480], archived: true),
            med("关提醒", times: [480], reminder: false),
        ])
        XCTAssertEqual(specs.map(\.title), ["正常"])
    }

    func testPlanEmptyDosageBody() {
        let m = Medication(profileId: pid, name: "药", dosage: "", timesOfDay: [480])
        XCTAssertEqual(MedReminderPlanner.plan(meds: [m]).specs[0].body, "该吃药啦")
    }

    func testPlanTruncatesOverLimit() {
        // 11 药 × 4 时刻 = 44 > 40
        let meds = (0..<11).map { med("药\($0)", times: [60, 120, 180, 240]) }
        let (specs, truncated) = MedReminderPlanner.plan(meds: meds)
        XCTAssertTrue(truncated)
        XCTAssertEqual(specs.count, MedReminderPlanner.maxReminders)
    }

    // MARK: resync（spy）

    final class SpyCenter: MedNotificationScheduling {
        var pending: [String] = []
        var removed: [String] = []
        var added: [ReminderSpec] = []
        var status: UNAuthorizationStatus = .authorized
        var authRequested = false

        func pendingMedIdentifiers() async -> [String] { pending }
        func remove(identifiers: [String]) { removed.append(contentsOf: identifiers) }
        func add(_ spec: ReminderSpec) async { added.append(spec) }
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func requestAuthorization() async -> Bool { authRequested = true; status = .authorized; return true }
    }

    func testResyncClearsStaleThenAdds() async {
        let spy = SpyCenter()
        spy.pending = ["med-old-480", "med-old-1260"]
        let scheduler = MedReminderScheduler(center: spy)
        await scheduler.resync(meds: [med("维生素 D", times: [480])])
        XCTAssertEqual(spy.removed, ["med-old-480", "med-old-1260"], "旧 med- 前缀全清")
        XCTAssertEqual(spy.added.count, 1)
        XCTAssertEqual(spy.added[0].title, "维生素 D")
    }

    func testResyncEmptyPlanOnlyClears() async {
        let spy = SpyCenter()
        spy.pending = ["med-old-480"]
        let scheduler = MedReminderScheduler(center: spy)
        await scheduler.resync(meds: [])
        XCTAssertEqual(spy.removed, ["med-old-480"])
        XCTAssertTrue(spy.added.isEmpty)
        XCTAssertFalse(spy.authRequested, "无计划不该请求权限")
    }

    func testResyncRequestsAuthWhenNotDetermined() async {
        let spy = SpyCenter()
        spy.status = .notDetermined
        let scheduler = MedReminderScheduler(center: spy)
        await scheduler.resync(meds: [med("药", times: [480])])
        XCTAssertTrue(spy.authRequested)
        XCTAssertEqual(spy.added.count, 1)
    }

    func testResyncDeniedRegistersNothing() async {
        let spy = SpyCenter()
        spy.status = .denied
        let scheduler = MedReminderScheduler(center: spy)
        await scheduler.resync(meds: [med("药", times: [480])])
        XCTAssertTrue(spy.added.isEmpty)
        XCTAssertTrue(scheduler.authorizationDenied, "降级标记给面板小灰字")
    }
}
