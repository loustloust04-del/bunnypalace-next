import XCTest
@testable import 记忆花园

/// 日历按天统计的口径与汇总（plan-calendar §2.1–2.3，astra #2 #4）。
final class DailyActivityTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func t(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func s(_ role: String, _ date: Date?, chars: Int = 10, deleted: Bool = false) -> ActivityNodeSample {
        ActivityNodeSample(role: role, createTime: date, charCount: chars, isDeleted: deleted)
    }

    func testCountsOnlyUserAndAssistantWithTime() {
        let c = DailyActivity.contribution(convId: "a", nodeCount: 6, samples: [
            s("user", t(2026, 9, 25, 10)),
            s("assistant", t(2026, 9, 25, 10, 1), chars: 30),
            s("system", t(2026, 9, 25, 10)),
            s("tool", t(2026, 9, 25, 10)),
            s("user", nil),
            s("user", t(2026, 9, 25, 11), deleted: true),
        ], calendar: cal)
        let d = c.days["2026-09-25"]
        XCTAssertEqual(d?.user, 1)
        XCTAssertEqual(d?.assistant, 1)
        XCTAssertEqual(d?.userChars, 10)
        XCTAssertEqual(d?.assistantChars, 30)
        XCTAssertEqual(d?.hours[10], 2)
    }

    func testMidnightMessageCountsOnCalendarDayButLateGoesToPreviousNight() {
        // 26 日 02:47：条数算 26 日；「最晚」算 25 日的 26:47
        let c = DailyActivity.contribution(convId: "a", nodeCount: 1, samples: [s("user", t(2026, 9, 26, 2, 47))], calendar: cal)
        XCTAssertEqual(c.days["2026-09-26"]?.user, 1)
        XCTAssertNil(c.days["2026-09-26"]?.lateMinute)
        XCTAssertEqual(c.days["2026-09-25"]?.messages, 0)
        XCTAssertEqual(c.days["2026-09-25"]?.lateMinute, 26 * 60 + 47)
    }

    func testFourAmIsSameDay() {
        let c = DailyActivity.contribution(convId: "a", nodeCount: 1, samples: [s("user", t(2026, 9, 26, 4, 0))], calendar: cal)
        XCTAssertEqual(c.days["2026-09-26"]?.lateMinute, 4 * 60)
    }

    func testRemovingConversationRollsBackHoursAndLatest() {
        // A：周一凌晨 3 点；B：凌晨 2 点。删 A 后最晚回到 2 点，小时分布减掉 A
        let a = DailyActivity.contribution(convId: "A", nodeCount: 1, samples: [s("user", t(2026, 9, 28, 3))], calendar: cal)
        let b = DailyActivity.contribution(convId: "B", nodeCount: 1, samples: [s("user", t(2026, 9, 28, 2))], calendar: cal)
        let both = DailyActivity.aggregate([a, b])
        XCTAssertEqual(both.days["2026-09-27"]?.lateMinute, 27 * 60)
        XCTAssertEqual(both.days["2026-09-28"]?.hours[3], 1)
        let onlyB = DailyActivity.aggregate([b])
        XCTAssertEqual(onlyB.days["2026-09-27"]?.lateMinute, 26 * 60)
        XCTAssertEqual(onlyB.days["2026-09-28"]?.hours[3], 0)
        XCTAssertEqual(onlyB.days["2026-09-28"]?.hours[2], 1)
    }

    func testConversationsByDayReverseLookup() {
        let a = DailyActivity.contribution(convId: "A", nodeCount: 2, samples: [s("user", t(2026, 9, 25, 9)), s("assistant", t(2026, 9, 25, 9))], calendar: cal)
        let b = DailyActivity.contribution(convId: "B", nodeCount: 1, samples: [s("user", t(2026, 9, 26, 9))], calendar: cal)
        let sum = DailyActivity.aggregate([a, b])
        XCTAssertEqual(sum.conversationsByDay["2026-09-25"], ["A": 2])
        XCTAssertEqual(sum.conversationsByDay["2026-09-26"], ["B": 1])
        // 熬夜记到前一天的「空贡献」不算「这天聊了」
        let late = DailyActivity.contribution(convId: "C", nodeCount: 1, samples: [s("user", t(2026, 9, 27, 1))], calendar: cal)
        XCTAssertNil(DailyActivity.aggregate([late]).conversationsByDay["2026-09-26"])
    }

    func testValueByMetricAndWho() {
        var d = DayContribution()
        d.user = 3; d.assistant = 5; d.userChars = 30; d.assistantChars = 500
        XCTAssertEqual(DailyActivity.value(d, metric: .messages, who: .all), 8)
        XCTAssertEqual(DailyActivity.value(d, metric: .messages, who: .me), 3)
        XCTAssertEqual(DailyActivity.value(d, metric: .chars, who: .ai), 500)
        XCTAssertEqual(DailyActivity.value(nil, metric: .chars, who: .all), 0)
    }

    func testThresholdsFallbackWhenFewDays() {
        XCTAssertEqual(DailyActivity.thresholds(recentValues: [5, 10, 0, 0], metric: .messages), [40, 100, 180])
    }

    func testThresholdsFromQuantilesAreStrictlyIncreasing() {
        let values = Array(repeating: 50, count: 30)
        let t = DailyActivity.thresholds(recentValues: values, metric: .messages)
        XCTAssertEqual(t.count, 3)
        XCTAssertLessThan(t[0], t[1])
        XCTAssertLessThan(t[1], t[2])
    }

    func testLevels() {
        let t = [10, 20, 30]
        XCTAssertEqual(DailyActivity.level(0, thresholds: t), 0)
        XCTAssertEqual(DailyActivity.level(9, thresholds: t), 1)
        XCTAssertEqual(DailyActivity.level(10, thresholds: t), 2)
        XCTAssertEqual(DailyActivity.level(29, thresholds: t), 3)
        XCTAssertEqual(DailyActivity.level(30, thresholds: t), 4)
    }

    func testDayKeyRoundTrip() {
        let key = DailyActivity.dayKey(t(2026, 2, 28, 23, 59), calendar: cal)
        XCTAssertEqual(key, "2026-02-28")
        let back = DailyActivity.date(fromKey: key, calendar: cal)!
        XCTAssertEqual(DailyActivity.dayKey(back, calendar: cal), key)
    }

    // MARK: 落盘

    func testCacheStoreRoundTripAndWipe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cal-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityCacheStore(root: root)
        XCTAssertNil(store.loadManifest())
        var m = ActivityManifest()
        m.dirty = ["x"]
        store.saveManifest(m)
        XCTAssertEqual(store.loadManifest()?.dirty, ["x"])
        let c = DailyActivity.contribution(convId: "conv/1", nodeCount: 1, samples: [s("user", t(2026, 9, 25, 9))], calendar: cal)
        store.save(c)
        XCTAssertEqual(store.loadAll()["conv/1"], c)
        store.remove(convId: "conv/1")
        XCTAssertTrue(store.loadAll().isEmpty)
        store.wipe()
        XCTAssertNil(store.loadManifest())
    }
}
