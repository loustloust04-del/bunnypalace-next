import XCTest
@testable import 记忆花园

/// 气泡模式时间分隔：英文 iMessage 格式（T3）。日子加粗、时间常规由 View 负责，这里只测文案。
final class ChatTimeDividerBubbleTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testBubbleGapIsOneHour() {
        XCTAssertEqual(ChatTimeDivider.bubbleGap, 3600)
        XCTAssertEqual(ChatTimeDivider.articleGap, 3 * 3600, "文章模式保持 3 小时")
    }

    func testBubbleLabelFormats() {
        let now = date("2026-10-02 10:00")      // 周五
        let cases = [
            ("2026-10-02 09:23", "Today", "9:23 AM"),
            ("2026-10-01 21:05", "Yesterday", "9:05 PM"),
            ("2026-09-30 14:10", "Wednesday", "2:10 PM"),
            ("2026-09-26 14:20", "Saturday", "2:20 PM"),
            ("2026-09-25 08:00", "Sep 25", "8:00 AM"),
            ("2025-12-31 08:05", "Dec 31", "8:05 AM")
        ]
        for (input, day, time) in cases {
            let actual = ChatTimeDivider.bubbleLabel(date(input), now: now, calendar: calendar)
            XCTAssertEqual(actual.day, day, input)
            XCTAssertEqual(actual.time, time, input)
        }
    }

    func testBubbleClockTwelveHour() {
        func clock(_ s: String) -> String { ChatTimeDivider.bubbleClock(date(s), calendar: calendar) }
        XCTAssertEqual(clock("2026-10-02 00:00"), "12:00 AM", "午夜是 12 AM")
        XCTAssertEqual(clock("2026-10-02 12:00"), "12:00 PM", "正午是 12 PM")
        XCTAssertEqual(clock("2026-10-02 09:05"), "9:05 AM", "小时不补零、分钟补零")
        XCTAssertEqual(clock("2026-10-02 23:59"), "11:59 PM")
    }

    func testBubbleDividersUseOneHourGap() {
        let nodes: [(id: String, time: Date?)] = [
            ("a", date("2026-10-01 10:00")),
            ("b", date("2026-10-01 10:30")),   // 隔 30 分钟：不出
            ("c", date("2026-10-01 11:30")),   // 隔 1 小时：出
            ("d", date("2026-10-01 11:45")),
        ]
        let map = ChatTimeDivider.dividers(for: nodes, gap: ChatTimeDivider.bubbleGap)
        XCTAssertEqual(Set(map.keys), ["a", "c"])
    }
}
