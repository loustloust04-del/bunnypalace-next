import XCTest
@testable import 记忆花园

/// B-7：进 page2 只在跨天时写桌面日期（plan-paging-decouple §3.4）
final class Page2DateRuleTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    func testSameDayDoesNotWrite() {
        XCTAssertFalse(Page2DateRule.shouldWrite(old: date(4, 8, 0), now: date(4, 23, 59, 59), calendar: calendar))
    }

    func testAcrossMidnightWrites() {
        XCTAssertTrue(Page2DateRule.shouldWrite(old: date(4, 23, 59, 59), now: date(5, 0, 0, 1), calendar: calendar))
    }

    func testClockGoingBackAcrossDayWrites() {
        XCTAssertTrue(Page2DateRule.shouldWrite(old: date(5, 0, 10), now: date(4, 23, 50), calendar: calendar))
    }
}
