import XCTest
@testable import 记忆花园

/// 时间线卡 card-timeline（粟粟 10-03 选 A 竖排；先只读）
final class TimelineCardTests: XCTestCase {

    private let json = #"""
    {"id":"l-1","title":"这周","items":[
      {"time":"周一 10-01","title":"网页卡","note":"mp.*","at":"2026-10-01"},
      {"time":"今天 09:12","title":"思考强度","at":"2026-10-03T09:12"},
      {"time":"今晚","title":"验审批卡","at":"2026-10-03T21:00","quote":"审批卡"},
      {"time":"周六","title":"时间线卡","at":"2026-10-05"}
    ]}
    """#

    private func card(_ s: String) -> TimelineCard? {
        guard case .timeline(let t)? = ChatCard.parse(language: "card-timeline", code: s) else { return nil }
        return t
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    // MARK: - 解析

    func testParse() throws {
        let t = try XCTUnwrap(card(json))
        XCTAssertEqual(t.title, "这周")
        XCTAssertEqual(t.items.map(\.title), ["网页卡", "思考强度", "验审批卡", "时间线卡"])
        XCTAssertEqual(t.items[2].quote, "审批卡")
        XCTAssertEqual(ChatCard.timeline(t).id, "l-1")
        XCTAssertEqual(ChatCard.timeline(t).kindLabel, "时间线")
        XCTAssertNotNil(ChatCard.parse(language: "timeline", code: json), "简写也认")
    }

    func testRejectsEmptyAndTooMany() {
        XCTAssertNil(card(#"{"title":"x","items":[]}"#))
        let many = (0..<31).map { #"{"time":"t\#($0)","title":"x"}"# }.joined(separator: ",")
        XCTAssertNil(card("{\"title\":\"x\",\"items\":[\(many)]}"))
        XCTAssertNil(card(#"{"items":[{"time":"t"}]}"#), "每项要有标题")
    }

    func testRoundTrip() throws {
        let t = try XCTUnwrap(card(json))
        let block = ChatCard.timeline(t).blockText
        XCTAssertTrue(block.hasPrefix("```card-timeline\n"))
        XCTAssertEqual(ChatCardExtractor.cards(in: block), [.timeline(t)])
    }

    // MARK: - 过去 / 将来 / 现在线

    func testPastFutureAndNowLine() throws {
        let t = try XCTUnwrap(card(json))
        let now = date("2026-10-03 15:00")
        XCTAssertEqual(t.items.map { $0.isPast(now: now, calendar: calendar) }, [true, true, false, false])
        XCTAssertEqual(t.nowLineIndex(now: now, calendar: calendar), 2, "现在线画在第 3 项前面")
    }

    func testDateOnlyIsPastAfterThatDay() throws {
        let t = try XCTUnwrap(card(#"{"items":[{"time":"今天","title":"a","at":"2026-10-03"}]}"#))
        XCTAssertFalse(t.items[0].isPast(now: date("2026-10-03 23:00"), calendar: calendar), "只写日期：当天还不算过去")
        XCTAssertTrue(t.items[0].isPast(now: date("2026-10-04 00:01"), calendar: calendar))
    }

    func testDoneFlagAndNoTimeInfo() throws {
        let t = try XCTUnwrap(card(#"{"items":[{"time":"早上","title":"a","done":true},{"time":"晚上","title":"b"}]}"#))
        let now = date("2026-10-03 15:00")
        XCTAssertEqual(t.items.map { $0.isPast(now: now, calendar: calendar) }, [true, false])
        XCTAssertEqual(t.nowLineIndex(now: now, calendar: calendar), 1)
        let none = try XCTUnwrap(card(#"{"items":[{"time":"1","title":"a"},{"time":"2","title":"b"}]}"#))
        XCTAssertNil(none.nowLineIndex(now: now, calendar: calendar), "都没时间信息：不画现在线")
    }

    // MARK: - 点了跳到哪条消息

    func testJumpTargetFindsLatestMessageContainingQuote() {
        let nodes: [(id: String, text: String)] = [("a", "先说审批卡的事"), ("b", "别的"), ("c", "审批卡装好了")]
        XCTAssertEqual(TimelineCard.jumpTarget(quote: "审批卡", in: nodes), "c", "取最近一条")
        XCTAssertNil(TimelineCard.jumpTarget(quote: "没有这句", in: nodes))
        XCTAssertNil(TimelineCard.jumpTarget(quote: "  ", in: nodes))
    }

    // MARK: - 给模型的说明

    func testGuide() {
        XCTAssertTrue(ChatCardPromptGuide.text.contains("```card-timeline"))
        XCTAssertTrue(ChatCardPromptGuide.text.contains("card-timeline：时间线"))
    }
}
