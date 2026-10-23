import XCTest
@testable import 记忆花园

/// v4-1 §二：记忆的一天从 05:00 算起
final class MemoryDayTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    func testBoundaryAtFive() {
        XCTAssertEqual(MemoryDay.key(date(10, 11, 4, 59), calendar: cal), "2026-10-10", "04:59 归前一天")
        XCTAssertEqual(MemoryDay.key(date(10, 11, 5, 0), calendar: cal), "2026-10-11", "05:00 归当天")
        XCTAssertEqual(MemoryDay.key(date(10, 11, 23, 59), calendar: cal), "2026-10-11")
        XCTAssertEqual(MemoryDay.dayStart(date(10, 11, 3, 0), calendar: cal), date(10, 10, 0))
    }

    func testMonthFollowsDay() {
        XCTAssertEqual(MemoryDay.key(date(11, 1, 4, 30), calendar: cal), "2026-10-31", "11-01 04:30 归 10-31")
        XCTAssertEqual(MemoryDay.month(date(11, 1, 4, 30), calendar: cal), "2026-10", "进 10 月文件")
        XCTAssertEqual(MemoryDay.month(date(11, 1, 5, 0), calendar: cal), "2026-11")
    }

    /// 夏令时切换那天（美西 2026-11-01 02:00 回拨）：按钟面算，04:30 仍归前一天
    func testDaylightSavingFallBack() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let d = la.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 4, minute: 30))!
        XCTAssertEqual(MemoryDay.key(d, calendar: la), "2026-10-31")
        XCTAssertEqual(MemoryDay.month(d, calendar: la), "2026-10")
    }

    /// 美西 2026-03-08（拨快）/ 2026-11-01（回拨）：起点仍是钟面 05:00，和 key 的归日一致
    func testStartDayClockFaceFiveOnDSTDays() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for raw in ["2026-03-08", "2026-11-01"] {
            let d = try! XCTUnwrap(MemoryStartDay.parse(raw, calendar: la))
            XCTAssertEqual(la.component(.hour, from: d), 5, raw)
            XCTAssertEqual(la.component(.minute, from: d), 0, raw)
            XCTAssertEqual(MemoryDay.key(d, calendar: la), raw, "05:00 归当天")
            XCTAssertEqual(MemoryDay.key(d.addingTimeInterval(-60), calendar: la), MemoryDay.key(la.date(byAdding: .day, value: -1, to: d)!, calendar: la),
                           "04:59 归前一天")
        }
    }

    func testKeyRoundTripAndBoundary() {
        XCTAssertEqual(MemoryDay.date(ofKey: "2026-10-01", calendar: cal), date(10, 1, 0))
        XCTAssertNil(MemoryDay.date(ofKey: "十月", calendar: cal))
        XCTAssertEqual(MemoryDay.boundary(of: date(10, 1, 13), calendar: cal), date(10, 1, 5))
    }

    func testSplitByDay() {
        // 10-09 15:44 到 10-11 04:42：10-11 凌晨那几条归 10-10
        let dates: [Date?] = [date(10, 9, 15, 44), date(10, 9, 23, 10), date(10, 10, 1, 0), date(10, 10, 9, 0),
                              nil, date(10, 10, 22, 0), date(10, 11, 4, 42)]
        let parts = MemoryDay.split(dates, calendar: cal)
        XCTAssertEqual(parts, [0..<3, 3..<7], "切成 10-09、10-10 两组（10-10 01:00 归 10-09）；没时间的跟着前一条")
        XCTAssertEqual(parts.map { MemoryDay.key(dates[$0.lowerBound]!, calendar: cal) }, ["2026-10-09", "2026-10-10"])
        XCTAssertEqual(MemoryDay.split([], calendar: cal), [])
        XCTAssertEqual(MemoryDay.split([nil, nil], calendar: cal), [0..<2])
    }

    func testStartDayCountsFromFive() {
        let d = try! XCTUnwrap(MemoryStartDay.parse("2026-10-01", calendar: cal))
        XCTAssertEqual(d, date(10, 1, 5), "起点那天也从 05:00 算")
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([date(10, 1, 4, 59), date(10, 1, 5)], startDay: d), 1,
                       "10-01 04:59 算 09-30，不进")
    }
}
