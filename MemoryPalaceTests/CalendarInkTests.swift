import XCTest
import SwiftUI
@testable import 记忆花园

/// 日历画笔 / 版式 / 星孔（plan-calendar P0 §2.3、P1、P2）的纯函数。
@MainActor
final class CalendarInkTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func month(_ y: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: 15))!
    }

    // MARK: 种子随机

    func testRandIsReproducible() {
        var a = CalendarInk.Rand(seed: CalendarInk.seed("floor-1", "2026-9"))
        var b = CalendarInk.Rand(seed: CalendarInk.seed("floor-1", "2026-9"))
        for _ in 0..<50 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testSeedDiffersByFloorAndMonth() {
        XCTAssertNotEqual(CalendarInk.seed("floor-1", "2026-9"), CalendarInk.seed("floor-2", "2026-9"))
        XCTAssertNotEqual(CalendarInk.seed("floor-1", "2026-9"), CalendarInk.seed("floor-1", "2026-10"))
        // 拼接不含糊：("ab","c") ≠ ("a","bc")
        XCTAssertNotEqual(CalendarInk.seed("ab", "c"), CalendarInk.seed("a", "bc"))
    }

    func testRandStaysInUnitInterval() {
        var r = CalendarInk.Rand(seed: 42)
        for _ in 0..<1000 {
            let v = r.next()
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }

    // MARK: 版式

    func testLayoutSeptember2026() {
        // 2026-09-01 是周二（周日起 → 前空 2 格），30 天 → 5 行
        let lay = PencilMonthView.Layout(month: month(2026, 9), calendar: calendar)
        XCTAssertEqual(lay.leading, 2)
        XCTAssertEqual(lay.daysInMonth, 30)
        XCTAssertEqual(lay.rows, 5)
    }

    func testLayoutFebruaryStartingSundayIsFourRows() {
        // 2026-02-01 是周日，28 天 → 正好 4 行
        let lay = PencilMonthView.Layout(month: month(2026, 2), calendar: calendar)
        XCTAssertEqual(lay.leading, 0)
        XCTAssertEqual(lay.rows, 4)
    }

    func testLayoutSixRowMonth() {
        // 2026-05-01 是周五（前空 5 格）+ 31 天 = 36 → 6 行
        let lay = PencilMonthView.Layout(month: month(2026, 5), calendar: calendar)
        XCTAssertEqual(lay.leading, 5)
        XCTAssertEqual(lay.rows, 6)
    }

    func testTapMapsCellCenterToDay() {
        let lay = PencilMonthView.Layout(month: month(2026, 9), calendar: calendar)
        let width: CGFloat = 365
        let m = lay.metrics(width: width)
        for d in [1, 7, 15, 30] {
            let r = m.cellRect(lay.index(ofDay: d))
            XCTAssertEqual(lay.day(at: CGPoint(x: r.midX, y: r.midY), width: width), d)
        }
    }

    func testTapOutsideDaysIsNil() {
        let lay = PencilMonthView.Layout(month: month(2026, 9), calendar: calendar)
        let width: CGFloat = 365
        let m = lay.metrics(width: width)
        // 1 号前的空格
        let blank = m.cellRect(0)
        XCTAssertNil(lay.day(at: CGPoint(x: blank.midX, y: blank.midY), width: width))
        // 30 号后的空格
        let after = m.cellRect(lay.index(ofDay: 30) + 1)
        XCTAssertNil(lay.day(at: CGPoint(x: after.midX, y: after.midY), width: width))
        // 网格外
        XCTAssertNil(lay.day(at: CGPoint(x: -5, y: -5), width: width))
        XCTAssertNil(lay.day(at: CGPoint(x: width + 5, y: m.y0 + 10), width: width))
    }

    // MARK: 星孔

    func testNoLevelsNoHoles() {
        let lay = PencilMonthView.Layout(month: month(2026, 9), calendar: calendar)
        let holes = StarCardCover.holes(lay: lay, metrics: lay.metrics(width: 365), levels: [:], seed: 1)
        XCTAssertTrue(holes.isEmpty)
    }

    func testStarHoleStaysInsideItsCell() {
        // 孤星：被格点圆削过之后，应该完全落在自己那一格里（不会挖到邻居）
        let lay = PencilMonthView.Layout(month: month(2026, 9), calendar: calendar)
        let m = lay.metrics(width: 365)
        let holes = StarCardCover.holes(lay: lay, metrics: m, levels: [10: 4], seed: 1)
        XCTAssertFalse(holes.isEmpty)
        let cell = m.cellRect(lay.index(ofDay: 10))
        XCTAssertTrue(cell.insetBy(dx: -1, dy: -1).contains(holes.boundingRect))
    }

    func testAdjacentStarsConnect() {
        // 相邻两个星孔之间有桥：孔的外框横跨两格
        let lay = PencilMonthView.Layout(month: month(2026, 9), calendar: calendar)
        let m = lay.metrics(width: 365)
        let holes = StarCardCover.holes(lay: lay, metrics: m, levels: [14: 4, 15: 4], seed: 1)
        let a = m.cellRect(lay.index(ofDay: 14)), b = m.cellRect(lay.index(ofDay: 15))
        XCTAssertLessThan(holes.boundingRect.minX, a.midX)
        XCTAssertGreaterThan(holes.boundingRect.maxX, b.midX)
        // 桥中点（两格交界处）是孔
        XCTAssertTrue(holes.contains(CGPoint(x: a.maxX, y: a.midY)))
    }

    func testStarsAcrossWeekBoundaryDoNotConnect() {
        // 19 号（周六）和 20 号（周日）在不同行：不能横着连
        let lay = PencilMonthView.Layout(month: month(2026, 9), calendar: calendar)
        let m = lay.metrics(width: 365)
        let holes = StarCardCover.holes(lay: lay, metrics: m, levels: [19: 4, 20: 4], seed: 1)
        let sat = m.cellRect(lay.index(ofDay: 19))
        XCTAssertFalse(holes.contains(CGPoint(x: sat.maxX + 1, y: sat.midY)))
    }

    func testMonthNameIsLowercaseEnglish() {
        XCTAssertEqual(StarCardCover.monthName(month(2026, 9)), "september")
    }
}
