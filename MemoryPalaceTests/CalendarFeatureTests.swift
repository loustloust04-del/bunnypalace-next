import XCTest
@testable import 记忆花园

/// 月历记号 / 纪念日落点 / 注入文字 / 聊天意向（plan-calendar §六 §八，astra #11 #13 #19）。
final class CalendarFeatureTests: XCTestCase {

    private var g: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { g.date(from: DateComponents(year: y, month: m, day: d))! }

    // MARK: 记号优先级

    func testDoodlePriority() {
        var inputs = CalendarMarks.Inputs(summary: DailyActivity.Summary())
        inputs.summary.conversationsByDay["2026-09-10"] = ["a": 150]
        inputs.moods["2026-09-10"] = .happy
        inputs.journalDates = ["2026-09-10"]
        inputs.anniversaryDays["2026-09-10"] = false
        XCTAssertEqual(CalendarMarks.doodle(key: "2026-09-10", inputs: inputs), .star)
        inputs.anniversaryDays["2026-09-10"] = true
        XCTAssertEqual(CalendarMarks.doodle(key: "2026-09-10", inputs: inputs), .bow)
        inputs.anniversaryDays = [:]
        XCTAssertEqual(CalendarMarks.doodle(key: "2026-09-10", inputs: inputs), .heartBox)
        inputs.journalDates = []
        XCTAssertEqual(CalendarMarks.doodle(key: "2026-09-10", inputs: inputs), .flower)
        inputs.moods = [:]
        XCTAssertEqual(CalendarMarks.doodle(key: "2026-09-10", inputs: inputs), .spiral)
        inputs.summary.conversationsByDay["2026-09-10"] = ["a": 99]
        XCTAssertNil(CalendarMarks.doodle(key: "2026-09-10", inputs: inputs))
    }

    func testMonthMarksLevels() {
        var summary = DailyActivity.Summary()
        var d = DayContribution(); d.user = 50; d.assistant = 50
        summary.days["2026-09-25"] = d
        let first = day(2026, 9, 1)
        let marks = CalendarMarks.month(first, daysInMonth: 30, inputs: CalendarMarks.Inputs(summary: summary),
                                        thresholds: [10, 50, 90], calendar: g)
        XCTAssertEqual(marks[25]?.level, 4)
        XCTAssertEqual(marks[24]?.level, 0)
    }

    // MARK: 纪念日落在这个月的哪天

    func testOccurrenceKeys() {
        let chinese = AnniversaryMath.chineseCalendar(timeZone: g.timeZone)
        let sep = day(2026, 9, 1), oct = day(2026, 10, 1)
        let trip = Anniversary(title: "旅行", kind: .countdown, date: "2026-09-20")
        XCTAssertEqual(AnniversaryMath.occurrenceKeys(of: trip, inMonth: sep, gregorian: g, chinese: chinese), ["2026-09-20"])
        XCTAssertEqual(AnniversaryMath.occurrenceKeys(of: trip, inMonth: oct, gregorian: g, chinese: chinese), [])
        let bday = Anniversary(title: "生日", kind: .yearly, isBirthday: true, date: "2000-10-01")
        XCTAssertEqual(AnniversaryMath.occurrenceKeys(of: bday, inMonth: oct, gregorian: g, chinese: chinese), ["2026-10-01"])
        // 出生之前的年份不标
        XCTAssertEqual(AnniversaryMath.occurrenceKeys(of: bday, inMonth: day(1999, 10, 1), gregorian: g, chinese: chinese), [])
        let mom = Anniversary(title: "妈妈", kind: .yearly, date: "1970-10-01", lunar: LunarMonthDay(month: 9, day: 9, leap: false))
        XCTAssertEqual(AnniversaryMath.occurrenceKeys(of: mom, inMonth: oct, gregorian: g, chinese: chinese), ["2026-10-18"])
    }

    // MARK: 注入

    func testAnniversaryTextRespectsRemindWindowAndSwitch() {
        let today = day(2026, 9, 27)
        let soon = Anniversary(title: "去京都", kind: .countdown, date: "2026-09-29", remindDays: 3)
        let far = Anniversary(title: "元旦", kind: .countdown, date: "2027-01-01", remindDays: 3)
        let silent = Anniversary(title: "秘密", kind: .countdown, date: "2026-09-28", remindDays: nil)
        let text = CalendarInjection.anniversaryText(anniversaries: [soon, far, silent], today: today, calendar: g, enabled: true)
        XCTAssertEqual(text, "[日历·快到的日子]\n· 后天（9/29）是「去京都」")
        XCTAssertNil(CalendarInjection.anniversaryText(anniversaries: [soon], today: today, calendar: g, enabled: false))
        XCTAssertNil(CalendarInjection.anniversaryText(anniversaries: [far, silent], today: today, calendar: g, enabled: true))
    }

    func testTodayJournalTextNeedsBothSwitches() {
        let doc = JournalDocument(frontmatter: [], body: "  今天买了月饼  ", diskHash: nil)
        XCTAssertNil(CalendarInjection.todayJournalText(document: doc, visible: false, inject: true))
        XCTAssertNil(CalendarInjection.todayJournalText(document: doc, visible: true, inject: false))
        XCTAssertEqual(CalendarInjection.todayJournalText(document: doc, visible: true, inject: true),
                       "[今天的日记｜用户自己写的，别逐字复述]\n今天买了月饼")
        let long = JournalDocument(frontmatter: [], body: String(repeating: "字", count: 900), diskHash: nil)
        XCTAssertEqual(CalendarInjection.todayJournalText(document: long, visible: true, inject: true)?.count,
                       "[今天的日记｜用户自己写的，别逐字复述]\n".count + CalendarInjection.journalLimit + 2)
    }
}
