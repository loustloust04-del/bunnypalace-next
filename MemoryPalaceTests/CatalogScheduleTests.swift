import XCTest
import SwiftData
@testable import 记忆花园

/// C3 调度（plan-memory-c3-catalog 4.2、todo 8）：05:00 分界、一天只管一次、开关 / 每天自动 / 写入预算不跑、同楼层互斥排队
final class CatalogScheduleTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""
    private let pid = "xctest-catalog-schedule"

    override func setUp() {
        super.setUp()
        suite = "xctest-catalog-schedule-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func date(_ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: mi))!
    }

    private func decide(_ now: Date, exceeded: Bool = false) -> CatalogSchedule.Decision? {
        CatalogSchedule.decide(profileId: pid, now: now, defaults: defaults, budgetExceeded: { exceeded })
    }

    func testOncePerMemoryDayAt0500() {
        XCTAssertEqual(decide(date(16, 4, 30)), .run, "04:30 算 10-15")
        XCTAssertNil(decide(date(16, 4, 55)), "同一记忆日回前台不再跑")
        XCTAssertEqual(defaults.string(forKey: CatalogSchedule.ranKey(pid)), "2026-10-15")
        XCTAssertEqual(decide(date(16, 5, 1)), .run, "过了 05:00 是新的一天")
        XCTAssertNil(decide(date(16, 23, 59)))
        XCTAssertNil(CatalogSchedule.decide(profileId: pid, now: date(17, 4, 59), defaults: defaults, budgetExceeded: { XCTFail("今天管过了不该再查预算"); return false }))
        XCTAssertEqual(CatalogSchedule.decide(profileId: "xctest-other", now: date(17, 4, 59), defaults: defaults, budgetExceeded: { false }), .run,
                       "按楼层记")
    }

    func testSkipsAreRecordedOncePerDay() {
        defaults.set(false, forKey: "mem_write_c3")
        XCTAssertEqual(decide(date(16, 9)), .skip("C3 关着，今天不自动整理"))
        XCTAssertNil(decide(date(16, 10)), "原因一天只记一行")

        defaults.set(true, forKey: "mem_write_c3")
        defaults.set(false, forKey: "mem_master")
        XCTAssertEqual(decide(date(17, 9)), .skip("C3 关着，今天不自动整理"), "总开关关 = 不写")

        defaults.set(true, forKey: "mem_master")
        defaults.set(false, forKey: CatalogSettings.dailyKey)
        XCTAssertEqual(decide(date(18, 9)), .skip("「每天自动整理」关着，今天不自动整理"))

        defaults.set(true, forKey: CatalogSettings.dailyKey)
        XCTAssertEqual(decide(date(19, 9), exceeded: true), .skip("写入预算用完，今天不自动整理"))
        XCTAssertEqual(decide(date(20, 9)), .run)
    }

    func testNextBoundary() {
        XCTAssertEqual(CatalogSchedule.nextBoundary(after: date(16, 4, 30)), date(16, 5))
        XCTAssertEqual(CatalogSchedule.nextBoundary(after: date(16, 5)), date(17, 5))
        XCTAssertEqual(CatalogSchedule.nextBoundary(after: date(16, 23)), date(17, 5))
    }

    func testRanKeyIsNotExported() {
        XCTAssertFalse(ConfigSchema.allScalarEntries.contains { $0.key.hasPrefix("mem_c3_ran") }, "运行记录不进配置导出")
    }

    // MARK: - 同楼层只跑一个，后来的排队

    private actor Trace {
        var events: [String] = []
        func add(_ e: String) { events.append(e) }
    }

    func testLockSerializesSameFloorOnly() async throws {
        let lock = CatalogLock()
        let trace = Trace()
        await lock.acquire("a")
        let waiting = Task {
            await lock.acquire("a")
            await trace.add("第二个拿到 a")
            await lock.release("a")
        }
        await lock.acquire("b")
        await trace.add("b 不用等")
        await lock.release("b")
        try await Task.sleep(for: .milliseconds(50))
        await trace.add("第一个放 a")
        await lock.release("a")
        await waiting.value

        let events = await trace.events
        XCTAssertEqual(events, ["b 不用等", "第一个放 a", "第二个拿到 a"])
        await lock.acquire("a")
        await lock.release("a")
    }
}
