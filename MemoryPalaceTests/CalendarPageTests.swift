import XCTest
import SwiftUI
@testable import 记忆花园

/// 日历整页重排（plan-calendar-page）的纯函数：留白几何、未来月、文案、日记子集。
@MainActor
final class CalendarPageTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: 留白（独立期望：左右各 0.57 格、上 0.82、下 0.55）

    func testAspectForFourFiveSixRows() {
        XCTAssertEqual(PencilMonthView.Layout.aspect(rows: 4), 8.14 / 5.37, accuracy: 1e-9)
        XCTAssertEqual(PencilMonthView.Layout.aspect(rows: 5), 8.14 / 6.37, accuracy: 1e-9)
        XCTAssertEqual(PencilMonthView.Layout.aspect(rows: 6), 8.14 / 7.37, accuracy: 1e-9)
    }

    func testMetricsMargins() {
        let lay = PencilMonthView.Layout(month: date(2026, 9, 15), calendar: calendar)
        let m = lay.metrics(width: 407)   // 8.14 格 → 一格 50
        XCTAssertEqual(m.cell, 50, accuracy: 1e-9)
        XCTAssertEqual(m.x0, 28.5, accuracy: 1e-9)
        XCTAssertEqual(m.y0, 41, accuracy: 1e-9)
    }

    func testDayAtGridEdges() {
        // 2026-09：前空 2 格，5 行
        let lay = PencilMonthView.Layout(month: date(2026, 9, 15), calendar: calendar)
        let w: CGFloat = 407
        XCTAssertEqual(lay.day(at: CGPoint(x: 28.5 + 100 + 1, y: 41 + 1), width: w), 1)
        XCTAssertNil(lay.day(at: CGPoint(x: 28, y: 41 + 1), width: w))            // 格子左边的留白
        XCTAssertNil(lay.day(at: CGPoint(x: 28.5 + 100 + 1, y: 40), width: w))    // 星期那一行
        XCTAssertNil(lay.day(at: CGPoint(x: 28.5 + 1, y: 41 + 250 + 1), width: w)) // 最后一行下面
        XCTAssertEqual(lay.day(at: CGPoint(x: 28.5 + 150 + 1, y: 41 + 250 - 1), width: w), 30)
    }

    // MARK: 未来月份（画法和能不能点同一个判定）

    func testIsFutureComparesYearAndMonth() {
        let today = date(2026, 9, 27)
        XCTAssertFalse(PencilYearView.isFuture(month: 9, year: 2026, today: today, calendar: calendar))
        XCTAssertFalse(PencilYearView.isFuture(month: 1, year: 2026, today: today, calendar: calendar))
        XCTAssertTrue(PencilYearView.isFuture(month: 10, year: 2026, today: today, calendar: calendar))
        XCTAssertTrue(PencilYearView.isFuture(month: 1, year: 2027, today: today, calendar: calendar))
        XCTAssertFalse(PencilYearView.isFuture(month: 12, year: 2025, today: today, calendar: calendar))
    }

    // MARK: 文案

    func testYearsAgoUsesRealYear() {
        XCTAssertEqual(CalendarText.yearsAgo(1), "一年前")
        XCTAssertEqual(CalendarText.yearsAgo(2), "两年前")
        XCTAssertEqual(CalendarText.yearsAgo(3), "三年前")
    }

    func testRecapButtonsUseEnglishAbbrev() {
        XCTAssertEqual(StarCardCover.monthAbbrev(8), "aug")
        XCTAssertEqual(StarCardCover.monthAbbrev(1), "jan")
        XCTAssertEqual(StarCardCover.monthAbbrev(13), "")
    }

    func testEnglishLabelsOnGateTabs() {
        XCTAssertEqual(CalendarTab.allCases.map(\.englishLabel), ["month", "year", "days"])
    }

    // MARK: 日记点阵纸只认的子集

    func testJournalLinesSubset() {
        let md = "# 2026-09-27 星期日\n\n## 今天\n去花市买了一盆银叶菊。\n- [ ] 给妈妈打电话\n- [x] 买花\n  缩进的一行"
        XCTAssertEqual(JournalDotPaper.lines(md), [
            .heading("2026-09-27 星期日"), .blank, .heading("今天"), .text("去花市买了一盆银叶菊。"),
            .todo("给妈妈打电话", done: false), .todo("买花", done: true), .text("  缩进的一行"),
        ])
    }
}
