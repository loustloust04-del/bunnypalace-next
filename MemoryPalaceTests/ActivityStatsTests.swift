import XCTest
@testable import 记忆花园

/// 年视图统计（plan-calendar §九 P3）。
final class ActivityStatsTests: XCTestCase {

    private var g: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { g.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }

    private func summary(_ keys: [String: Int]) -> DailyActivity.Summary {
        var s = DailyActivity.Summary()
        for (k, n) in keys { var d = DayContribution(); d.user = n; s.days[k] = d }
        return s
    }

    func testCurrentStreakCountsFromYesterdayWhenTodayEmpty() {
        let s = summary(["2026-09-24": 1, "2026-09-25": 3, "2026-09-26": 2])
        XCTAssertEqual(ActivityStats.currentStreak(s, today: day(2026, 9, 27), calendar: g), 3)
        XCTAssertEqual(ActivityStats.currentStreak(s, today: day(2026, 9, 26), calendar: g), 3)
        XCTAssertEqual(ActivityStats.currentStreak(s, today: day(2026, 9, 29), calendar: g), 0)
    }

    func testCurrentStreakCrossesNewYear() {
        let s = summary(["2025-12-30": 1, "2025-12-31": 1, "2026-01-01": 1])
        XCTAssertEqual(ActivityStats.currentStreak(s, today: day(2026, 1, 1), calendar: g), 3)
    }

    func testLongestStreakWithinYear() {
        let s = summary(["2026-03-01": 1, "2026-03-02": 1, "2026-03-03": 1, "2026-05-01": 1, "2026-05-02": 1, "2025-12-31": 5, "2026-01-01": 1])
        let l = ActivityStats.longestStreak(s, year: 2026, calendar: g)
        XCTAssertEqual(l, ActivityStats.Streak(length: 3, start: "2026-03-01", end: "2026-03-03"))
    }

    func testBusiestPrefersEarlierOnTie() {
        let s = summary(["2026-06-03": 412, "2026-07-01": 412, "2026-02-01": 10])
        XCTAssertEqual(ActivityStats.busiestDay(s, year: 2026)?.key, "2026-06-03")
        XCTAssertNil(ActivityStats.busiestDay(s, year: 2024))
    }

    func testLatestUsesNightAttribution() {
        let c = DailyActivity.contribution(convId: "a", nodeCount: 2, samples: [
            ActivityNodeSample(role: "user", createTime: day(2026, 9, 26, 3), charCount: 1, isDeleted: false),
            ActivityNodeSample(role: "user", createTime: day(2026, 9, 20, 23), charCount: 1, isDeleted: false),
        ], calendar: g)
        let s = DailyActivity.aggregate([c])
        let l = ActivityStats.latest(s, year: 2026)
        XCTAssertEqual(l?.key, "2026-09-25")
        XCTAssertEqual(l?.time, "03:00")
    }

    func testPunchCardMondayFirst() {
        // 2026-09-28 是周一
        let c = DailyActivity.contribution(convId: "a", nodeCount: 1, samples: [
            ActivityNodeSample(role: "user", createTime: day(2026, 9, 28, 22), charCount: 1, isDeleted: false),
        ], calendar: g)
        let grid = ActivityStats.punchCard(DailyActivity.aggregate([c]), year: 2026, calendar: g)
        XCTAssertEqual(grid[0][22], 1)
        XCTAssertEqual(grid.flatMap { $0 }.reduce(0, +), 1)
    }

    func testActiveDaysAndTotal() {
        let s = summary(["2026-01-01": 3, "2026-01-02": 0, "2025-01-01": 9])
        XCTAssertEqual(ActivityStats.activeDays(s, year: 2026), 1)
        XCTAssertEqual(ActivityStats.totalMessages(s, year: 2026), 3)
    }
}
