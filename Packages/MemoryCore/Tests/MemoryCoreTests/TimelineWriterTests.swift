@testable import MemoryCore
import XCTest

/// c2c3-v2 第 7 段 + rev5 §3：A4 主调写手只喂一天的 A2 标题 + 日期、不带人设，只交 {"headline","topics"}；
/// 主调 ≤40 字（超了截、记日志），topics 坏了只丢 topics。顺带两条 A2 写手的格式 / 输入检查
final class TimelineWriterTests: XCTestCase {

    private let speakers = SessionSegmentWriter.Speakers(userName: "粟粟", assistantName: "小克")

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - A4 主调

    func testHeadlineAndTopicsFromJSON() {
        let d = TimelineWriter.parse(#"{"headline":"白天修报错，晚上翻旧照片","topics":["报错","旧照片"]}"#)
        XCTAssertEqual(d, .init(headline: "白天修报错，晚上翻旧照片", topics: ["报错", "旧照片"]))
        XCTAssertEqual(TimelineWriter.parse("```json\n{\"headline\":\"一句\",\"topics\":[\"甲\"]}\n```")?.headline, "一句", "代码围栏也认")
        XCTAssertEqual(TimelineWriter.parse("<think>想想</think>{\"headline\":\"一句\"}")?.topics, [], "没给 topics = 空")
    }

    /// topics 坏了只丢 topics，主调照收
    func testBrokenTopicsOnlyDropTopics() {
        XCTAssertEqual(TimelineWriter.parse(#"{"headline":"一句","topics":"报错"}"#), .init(headline: "一句", topics: []))
        XCTAssertEqual(TimelineWriter.parse(#"{"headline":"一句","topics":[1,"",null,"甲","甲","一个非常非常非常非常非常长的话题词超过了"]}"#)?.topics, ["甲"])
        XCTAssertEqual(TimelineWriter.parse(#"{"headline":"一句","topics":["a","b","c","d"]}"#)?.topics, ["a", "b", "c"], "最多三个")
        XCTAssertEqual(TimelineWriter.parse(#"{"headline":"一句，带「引号」","topics":["甲" "乙"]}"#), .init(headline: "一句，带「引号」", topics: []),
                       "JSON 整个坏了：字面捞主调，topics 丢掉")
    }

    func testHeadlineLimitAndFallbacks() {
        let long = String(repeating: "很", count: 55)
        XCTAssertEqual(TimelineWriter.parse(#"{"headline":"\#(long)"}"#)?.headline.count, TimelineStore.headlineLimit, "超了截到 40 字")
        XCTAssertEqual(TimelineWriter.parse("「白天修报错」\n多说的一行")?.headline, "白天修报错", "小模型没给 JSON：第一行当主调")
        XCTAssertNil(TimelineWriter.parse(#"{"topics":["甲"]}"#), "没有主调 = 拿不到")
        XCTAssertNil(TimelineWriter.parse(#"{"headline":"   "}"#))
        XCTAssertNil(TimelineWriter.parse("<think>没想完"))
    }

    /// 只喂标题 + 日期，不带人设、不带原文；一天调一次，主调拿不到就抛、不重写
    func testWriteFeedsOnlyTitlesAndDate() async throws {
        var seen: [(String, String)] = []
        let caller: SessionSegmentWriter.Caller = { system, user in
            seen.append((system, user))
            return "说了点别的"
        }
        let d = try await TimelineWriter.write(date: "2026-10-12", titles: ["修设置页报错", "翻旧照片"], caller: caller)
        XCTAssertEqual(d?.headline, "说了点别的")
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].0, TimelineWriter.systemPrompt, "system 是固定那段，不拼人设")
        XCTAssertEqual(seen[0].1, "2026-10-12\n修设置页报错\n翻旧照片")
        XCTAssertTrue(TimelineWriter.systemPrompt.contains("不超过 40 字"))

        var calls = 0
        do {
            _ = try await TimelineWriter.write(date: "2026-10-12", titles: ["t"], caller: { _, _ in calls += 1; return #"{"topics":[]}"# })
            XCTFail("没有主调应该抛")
        } catch MemoryWriterError.format {}
        XCTAssertEqual(calls, 1, "不重写")
        let skipped = try await TimelineWriter.write(date: "2026-10-12", titles: ["t"], caller: { _, _ in nil })
        XCTAssertNil(skipped, "预算闸 / 空输出 = 跳过")
    }

    // MARK: - A2 写手（顺带）

    func testSegmentFormatProblem() {
        XCTAssertNil(SessionSegmentWriter.formatProblem("标题：复诊\n【经过】说好周三去\n【原话】粟粟：「周三」"))
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("（想了很久）……想到了"))
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("这个窗口聊了复诊。\n标题：复诊\n【经过】说好\n【原话】粟粟：「周三」"), "【经过】前面有正文")
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("标题：复诊\n【经过】说好"), "缺【原话】")
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("【经过】说好\n【原话】粟粟：「周三」"), "缺标题")
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("标题：复诊\n【经过】用户说好\n【原话】粟粟：「周三」"))
    }

    func testSegmentUserContentFeedsFullPreviousWithoutPending() {
        let prev = SessionSegment(kind: .rolling, title: "复诊", start: date(10, 11, 9), end: date(10, 11, 10), from: 0, to: 2,
                                  lastNodeId: "n1", story: "说好周三去", quotes: "粟粟：「周三」", pending: "老待续")
        let text = SessionSegmentWriter.userContent(messages: [], speakers: speakers, previous: prev, kind: .rolling)
        XCTAssertTrue(text.contains("说好周三去") && text.contains("粟粟：「周三」"), "上一段全文进了输入")
        XCTAssertFalse(text.contains("老待续"), "待续没进")
        let o = SessionSegmentWriter.parse("标题：复诊\n【经过】说好\n【原话】粟粟：「周三」\n【待续】周三问结果")
        XCTAssertEqual(o.quotes, "粟粟：「周三」", "【待续】不进原话")
        XCTAssertEqual(o.pending, "周三问结果")
    }
}
