import XCTest
@testable import 记忆花园

/// plan-calendar-v5：iOS 风年页的纯计算 + 格子小点
final class CalendarIOSMathTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testThisYearListsUpToCurrentMonthNewestFirst() {
        let r = CalendarIOSMath.monthRows(activeByMonth: [9: 25, 8: 31, 1: 3], year: 2026, today: date(2026, 9, 28), calendar: calendar)
        XCTAssertEqual(r.rows.map(\.month), [9, 8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(r.rows.first?.kind, .current)
        XCTAssertEqual(r.rows.dropFirst().map(\.kind), Array(repeating: .recap, count: 8))
        XCTAssertEqual(r.futureFrom, 10)
        XCTAssertEqual(r.rows[1].fraction, 1, accuracy: 0.0001)          // 8 月 31 / 31
        XCTAssertEqual(r.rows[0].fraction, 25.0 / 30, accuracy: 0.0001)  // 9 月 30 天
        XCTAssertEqual(r.rows.last?.activeDays, 3)
    }

    func testPastYearAllTwelveRecapNoFuture() {
        let r = CalendarIOSMath.monthRows(activeByMonth: [:], year: 2025, today: date(2026, 9, 28), calendar: calendar)
        XCTAssertEqual(r.rows.count, 12)
        XCTAssertTrue(r.rows.allSatisfy { $0.kind == .recap })
        XCTAssertNil(r.futureFrom)
        XCTAssertEqual(r.rows.first(where: { $0.month == 2 })?.daysInMonth, 28)
    }

    func testFutureYearIsAllFuture() {
        let r = CalendarIOSMath.monthRows(activeByMonth: [:], year: 2027, today: date(2026, 9, 28), calendar: calendar)
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertEqual(r.futureFrom, 1)
    }

    func testDecemberHasNoFutureTail() {
        let r = CalendarIOSMath.monthRows(activeByMonth: [:], year: 2026, today: date(2026, 12, 3), calendar: calendar)
        XCTAssertEqual(r.rows.count, 12)
        XCTAssertNil(r.futureFrom)
    }

    func testHourTotalsSumAcrossWeekdays() {
        var punch = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        punch[0][23] = 4
        punch[6][23] = 5
        punch[3][0] = 1
        let h = CalendarIOSMath.hourTotals(punch)
        XCTAssertEqual(h.count, 24)
        XCTAssertEqual(h[23], 9)
        XCTAssertEqual(h[0], 1)
        XCTAssertEqual(h.reduce(0, +), 10)
        XCTAssertEqual(CalendarIOSMath.hourTotals([]), Array(repeating: 0, count: 24))
    }

    func testWeeklyMoodsModeAndTieOrder() {
        // 第一周（1/1–1/7）：累 ×2、开心 ×1 → 累；第二周（1/8–1/14）：平静 ×1、难过 ×1 → 一样多取靠前的平静；第三周空
        let moods: [String: JournalMood] = [
            "2025-01-01": .tired, "2025-01-03": .tired, "2025-01-05": .happy,
            "2025-01-09": .sad, "2025-01-10": .calm,
        ]
        let w = CalendarIOSMath.weeklyMoods(year: 2025, moods: moods, today: date(2026, 9, 28), calendar: calendar)
        XCTAssertEqual(w.count, 53)          // 365 天 = 52 周 + 1 天
        XCTAssertEqual(w[0], .tired)
        XCTAssertEqual(w[1], .calm)
        XCTAssertNil(w[2])
    }

    func testWeeklyMoodsThisYearStopsAtToday() {
        let w = CalendarIOSMath.weeklyMoods(year: 2026, moods: ["2026-01-15": .happy], today: date(2026, 1, 15), calendar: calendar)
        XCTAssertEqual(w.count, 3)           // 1/1–1/7, 1/8–1/14, 1/15
        XCTAssertEqual(w[2], .happy)
        XCTAssertTrue(CalendarIOSMath.weeklyMoods(year: 2027, moods: [:], today: date(2026, 1, 15), calendar: calendar).isEmpty)
    }

    func testGridDotsChatThenAnniversaryPeriodYields() {
        var m = PencilMonthDay()
        XCTAssertTrue(IOSMonthGrid.dots(chat: false, m).isEmpty)
        // 涂深档位不算：没有消息就没有聊天点
        m.level = 3
        XCTAssertTrue(IOSMonthGrid.dots(chat: false, m).isEmpty)
        XCTAssertEqual(IOSMonthGrid.dots(chat: true, m).count, 1)
        m.periodMark = true
        XCTAssertEqual(IOSMonthGrid.dots(chat: true, m), [Theme.branchIndicator, IOSMonthGrid.rose])
        m.doodle = .bow
        XCTAssertEqual(IOSMonthGrid.dots(chat: true, m), [Theme.branchIndicator, IOSMonthGrid.anniversaryPink])
        m.doodle = .heartBox   // 日记不是纪念日
        XCTAssertFalse(IOSMonthGrid.isAnniversary(m))
    }
}
