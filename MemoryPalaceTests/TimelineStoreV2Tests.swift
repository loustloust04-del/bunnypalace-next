import XCTest
@testable import 记忆花园

/// 时间轴月文件：c2c3-v2 第 7 段的一天一条和留下来的老条目（v2 一天 × 一窗口 / 更老的格式）同住一份文件、按 05:00 归月；
/// 老条目只读，新旧读得出、写回不丢
final class TimelineStoreV2Tests: XCTestCase {

    let pid = "xctest-timeline-v2"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private var dir: URL { TimelineStore.dir(profileId: pid) }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    private func v2(_ day: String, _ conv: String, start: Date, end: Date, topics: [String], pending: String = "", last: String? = nil) -> TimelineEntry {
        TimelineEntry(start: start, end: end, conversationId: conv, title: "窗口\(conv)",
                      text: topics.map { "- \($0)" }.joined(separator: "\n"), pending: pending, day: day, lastNodeId: last)
    }

    private func record(_ day: String, headline: String?, items: [TimelineDayRecord.Item]) -> TimelineDayRecord {
        TimelineDayRecord(date: day, headline: headline, topics: headline == nil ? [] : ["话题"], items: items, source: "abc")
    }

    private func item(_ conv: String, _ title: String, _ start: Date, _ end: Date, from: String? = "a", to: String? = "b",
                      kind: TimelineDayRecord.Item.Kind = .segment, continued: Bool = false) -> TimelineDayRecord.Item {
        .init(kind: kind, conversationId: conv, window: "窗口 \(conv)", title: title, start: start, end: end, from: from, to: to, continued: continued)
    }

    func testRenderParseRoundTripV2AndOld() {
        let new = v2("2026-10-11", "conv-new-0001", start: date(10, 11, 14, 20), end: date(10, 11, 15, 5),
                     topics: ["改了时间轴格式", "停在写单测"], pending: "跑金样\n写复盘", last: "node-9")
        let old = TimelineEntry(start: date(10, 10, 9, 0), end: date(10, 10, 9, 30), conversationId: "conv-old-0001",
                                title: "老", text: "两三句老格式", pending: "周三问结果")
        let raw = TimelineStore.render([old, new], month: "2026-10")
        XCTAssertTrue(raw.contains("<!-- entry v=2 day=2026-10-11 conv=conv-new-0001 "))
        XCTAssertTrue(raw.contains("- 改了时间轴格式\n- 停在写单测\n待续：\n- 跑金样\n- 写复盘"))
        XCTAssertEqual(TimelineStore.parse(raw), [old, new])
        XCTAssertNil(TimelineStore.parse(raw)[0].day, "老格式没有 day")
    }

    /// 一天一条和老条目同一份月文件：读写来回不丢；老条目正文不会把后面那天的块吞进去
    func testMixedMonthRoundTrip() throws {
        let day = record("2026-10-12", headline: "上午修报错，深夜翻旧照片", items: [
            item("conv-a", "修设置页报错；补单测", date(10, 12, 9), date(10, 12, 11)),
            item("conv-b", "（3 条，没压缩）", date(10, 13, 1), date(10, 13, 1, 20), kind: .short),
        ])
        let pending = record("2026-10-13", headline: nil, items: [item("conv-a", "翻 --> 旧照片", date(10, 13, 20), date(10, 13, 21), continued: true)])
        let old = v2("2026-10-11", "conv-old", start: date(10, 11, 9), end: date(10, 11, 10), topics: ["老话题"], pending: "老待续")
        let m = TimelineStore.Month(days: [pending, day], entries: [old])
        try TimelineStore.save(m, month: "2026-10", in: dir)
        let back = try TimelineStore.monthStrict("2026-10", in: dir)
        XCTAssertEqual(back.entries, [old])
        XCTAssertEqual(back.days.map(\.date), ["2026-10-12", "2026-10-13"], "按日期排")
        XCTAssertEqual(back.days.first, day)
        XCTAssertEqual(back.days.last?.headline, nil)
        XCTAssertEqual(back.days.last?.items.first?.title, "翻 -> 旧照片", "注释里放不下的「-->」换掉")
        let raw = try String(contentsOf: dir.appendingPathComponent("2026-10.md"), encoding: .utf8)
        XCTAssertTrue(raw.contains("### 深夜\n- 01:00–01:20 《窗口 conv-b》（3 条，没压缩）"), "深夜归前一个记忆日，人也看得懂")
        XCTAssertTrue(raw.contains("## 2026-10-13 · （还没有主调）"))
    }

    /// 读坏的月文件不能当空的写回去：机读注释的块数和读出来的对不上就抛
    func testStrictReadRejectsBrokenItem() throws {
        try TimelineStore.save(.init(days: [record("2026-10-12", headline: "一句", items: [item("c", "t", date(10, 12, 9), date(10, 12, 10))])]),
                               month: "2026-10", in: dir)
        let url = dir.appendingPathComponent("2026-10.md")
        let raw = try String(contentsOf: url, encoding: .utf8)
        try Data(raw.replacingOccurrences(of: "\"kind\":\"segment\"", with: "\"kind\":\"???\"").utf8).write(to: url)
        XCTAssertThrowsError(try TimelineStore.monthStrict("2026-10", in: dir))
        XCTAssertThrowsError(try TimelineStore.mutateMonth("2026-10", in: dir) { _ in })
        XCTAssertNotEqual(try String(contentsOf: url, encoding: .utf8), raw, "没被写回")
    }

    /// astra #6：同时往同一个月文件写，各自的都留着
    func testConcurrentWritersSameMonthKeepBoth() {
        let d = dir
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            let day = String(format: "2026-10-%02d", i / 2 + 1)
            do {
                if i % 2 == 0 {
                    try TimelineStore.seedLegacy(TimelineEntry(start: date(10, i / 2 + 1, 10), end: date(10, i / 2 + 1, 11), conversationId: "conv-a",
                                                               title: "a", text: "- \(i)", pending: "", day: day, lastNodeId: "n\(i)"), in: d)
                } else {
                    try TimelineStore.mutateMonth("2026-10", in: d) { $0.days.append(self.record(day, headline: "第\(i)", items: [])) }
                }
            } catch { XCTFail("\(error)") }
        }
        let m = TimelineStore.month("2026-10", in: d)
        XCTAssertEqual(m.entries.count, 20, "没有谁覆盖掉别人刚写的")
        XCTAssertEqual(m.days.count, 20)
    }

    func testLatestLegacyEntry() throws {
        try TimelineStore.seedLegacy(v2("2026-09-30", "conv-x", start: date(9, 30, 10), end: date(9, 30, 11), topics: ["九月底"], pending: "甲"), in: dir)
        try TimelineStore.seedLegacy(v2("2026-10-02", "conv-x", start: date(10, 2, 10), end: date(10, 2, 11), topics: ["十月"], pending: "乙"), in: dir)
        XCTAssertEqual(TimelineStore.latest(conversationId: "conv-x", in: dir)?.pending, "乙")
        XCTAssertNil(TimelineStore.latest(conversationId: "conv-z", in: dir))
    }
}
