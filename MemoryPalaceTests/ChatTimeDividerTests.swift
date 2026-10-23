import XCTest
@testable import 记忆花园

/// 聊天时间分割线 + 长按角标（TASK page1-消息-20，粟粟 10-02：A 两侧线改波浪线、角标放菜单底部）
final class ChatTimeDividerTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "zh_CN")
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

    // MARK: - 什么时候出现

    func testFirstMessageAndLongGapsGetDividers() {
        let nodes: [(id: String, time: Date?)] = [
            ("a", date("2026-10-01 23:41")),
            ("b", date("2026-10-01 23:42")),
            ("c", date("2026-10-02 02:41")),     // 隔 2 小时 59 分：不出
            ("d", date("2026-10-02 05:41")),     // 隔正好 3 小时：出
            ("e", date("2026-10-02 05:50")),
        ]
        let map = ChatTimeDivider.dividers(for: nodes)
        XCTAssertEqual(Set(map.keys), ["a", "d"])
        XCTAssertEqual(map["d"], date("2026-10-02 05:41"))
    }

    func testNodesWithoutTimeAreSkipped() {
        let nodes: [(id: String, time: Date?)] = [
            ("root", nil),
            ("a", date("2026-10-01 10:00")),
            ("x", nil),                          // 没时间的不出、也不打断比较
            ("b", date("2026-10-01 14:00")),
        ]
        XCTAssertEqual(Set(ChatTimeDivider.dividers(for: nodes).keys), ["a", "b"])
    }

    // MARK: - 时间怎么写

    func testLabels() {
        let now = date("2026-10-02 10:00")      // 周五
        func label(_ s: String) -> String { ChatTimeDivider.label(date(s), now: now, calendar: calendar) }
        XCTAssertEqual(label("2026-10-02 09:12"), "09:12")
        XCTAssertEqual(label("2026-10-01 23:41"), "昨天 23:41")
        XCTAssertEqual(label("2026-09-30 14:20"), "周三 14:20")
        XCTAssertEqual(label("2026-09-26 14:20"), "周六 14:20", "6 天内写星期")
        XCTAssertEqual(label("2026-09-25 14:20"), "9月25日 14:20", "一周及以上写日期")
        XCTAssertEqual(label("2025-12-31 08:05"), "2025年12月31日 08:05")
    }

    // MARK: - 长按角标

    func testInfoLineForAssistantWithUsage() {
        let now = date("2026-10-02 10:00")
        let line = ChatBubbleInfo.line(time: date("2026-10-02 09:13"), isUser: false,
                                       prompt: 12_400, completion: 86, cacheRead: 11_904, now: now, calendar: calendar)
        XCTAssertEqual(line, "10月2日 09:13\n输入 12.4k · 输出 86 · 缓存命中 11.9k（96%）")
    }

    func testInfoLineWithoutCacheOrUsage() {
        let now = date("2026-10-02 10:00")
        XCTAssertEqual(ChatBubbleInfo.line(time: date("2026-10-02 09:13"), isUser: false,
                                           prompt: 2_000, completion: 1_200_000, cacheRead: nil, now: now, calendar: calendar),
                       "10月2日 09:13\n输入 2k · 输出 1.2M")
        XCTAssertEqual(ChatBubbleInfo.line(time: date("2026-10-02 09:13"), isUser: true,
                                           prompt: nil, completion: nil, cacheRead: nil, now: now, calendar: calendar),
                       "10月2日 09:13", "你的消息只有时间")
        XCTAssertEqual(ChatBubbleInfo.line(time: date("2025-01-05 09:13"), isUser: true,
                                           prompt: nil, completion: nil, cacheRead: nil, now: now, calendar: calendar),
                       "2025年1月5日 09:13")
        XCTAssertNil(ChatBubbleInfo.line(time: nil, isUser: true, prompt: nil, completion: nil, cacheRead: nil,
                                         now: now, calendar: calendar))
    }

    func testTokenFormat() {
        XCTAssertEqual(ChatBubbleInfo.tokens(86), "86")
        XCTAssertEqual(ChatBubbleInfo.tokens(1_000), "1k")
        XCTAssertEqual(ChatBubbleInfo.tokens(12_449), "12.4k")
        XCTAssertEqual(ChatBubbleInfo.tokens(1_260_000), "1.3M")
    }
}
