import XCTest
@testable import 记忆花园

/// v4-1 §三：时间轴 v2——一天 × 一窗口一条、按（日期, 窗口编号）改写、按 05:00 归月；老格式照读
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

    func testRenderParseRoundTripV2AndOld() {
        let new = v2("2026-10-11", "conv-new-0001", start: date(10, 11, 14, 20), end: date(10, 11, 15, 5),
                     topics: ["改了时间轴格式", "停在写单测"], pending: "跑金样\n写复盘", last: "node-9")
        let old = TimelineEntry(start: date(10, 10, 9, 0), end: date(10, 10, 9, 30), conversationId: "conv-old-0001",
                                title: "老", text: "两三句老格式", pending: "周三问结果")
        let raw = TimelineStore.render([old, new], month: "2026-10")
        XCTAssertTrue(raw.contains("<!-- entry v=2 day=2026-10-11 conv=conv-new-0001 "))
        XCTAssertTrue(raw.contains("last=node-9 -->"))
        XCTAssertTrue(raw.contains("- 改了时间轴格式\n- 停在写单测\n待续：\n- 跑金样\n- 写复盘"))
        XCTAssertEqual(TimelineStore.parse(raw), [old, new])
        XCTAssertEqual(new.topics, ["改了时间轴格式", "停在写单测"])
        XCTAssertNil(TimelineStore.parse(raw)[0].day, "老格式没有 day")
    }

    /// 新文件给老代码读：老解析器只认 conv / start / end，待续那几行原样收进待续
    func testOldParserSemanticsOnNewFile() {
        let new = v2("2026-10-11", "conv-new-0002", start: date(10, 11, 14, 0), end: date(10, 11, 15, 0), topics: ["一"], pending: "甲")
        let raw = TimelineStore.render([new], month: "2026-10")
        XCTAssertTrue(raw.contains("conv=conv-new-0002 start="), "老代码按 key=value 拆，多出来的 v / day / last 它不认也不碍事")
    }

    func testUpsertRewritesSameDaySameWindow() throws {
        let a1 = v2("2026-10-11", "conv-a", start: date(10, 11, 10), end: date(10, 11, 11), topics: ["上午"])
        let b = v2("2026-10-11", "conv-b", start: date(10, 11, 12), end: date(10, 11, 13), topics: ["别的窗口"])
        let a2 = v2("2026-10-11", "conv-a", start: date(10, 11, 10), end: date(10, 11, 18), topics: ["上午", "晚上"])
        let aNext = v2("2026-10-12", "conv-a", start: date(10, 12, 9), end: date(10, 12, 10), topics: ["第二天"])
        var list = TimelineStore.upserting(a1, into: [])
        list = TimelineStore.upserting(b, into: list)
        list = TimelineStore.upserting(a2, into: list)
        list = TimelineStore.upserting(aNext, into: list)
        XCTAssertEqual(list.count, 3, "同一天同一窗口只有一条")
        XCTAssertEqual(list.first { $0.conversationId == "conv-a" && $0.day == "2026-10-11" }?.topics, ["上午", "晚上"])

        let old = TimelineEntry(start: date(10, 11, 8), end: date(10, 11, 9), conversationId: "conv-a", title: "老", text: "老", pending: "")
        XCTAssertEqual(TimelineStore.upserting(a2, into: [old]).count, 2, "老格式条目不参与按键改写")
    }

    func testUpsertFilesByMemoryDayMonth() throws {
        // 11-01 04:30 的事归 10-31，进 10 月文件
        let late = v2(MemoryDay.key(date(11, 1, 4, 30)), "conv-late", start: date(10, 31, 23), end: date(11, 1, 4, 30), topics: ["熬夜"])
        try TimelineStore.upsert(late, in: dir)
        XCTAssertEqual(TimelineStore.months(profileId: pid), ["2026-10"])
        XCTAssertEqual(TimelineStore.entry(day: "2026-10-31", conversationId: "conv-late", in: dir)?.topics, ["熬夜"])

        try TimelineStore.append(TimelineEntry(start: date(11, 1, 3), end: date(11, 1, 4), conversationId: "conv-old",
                                               title: "老", text: "老", pending: ""), profileId: pid)
        XCTAssertEqual(TimelineStore.months(profileId: pid), ["2026-10"], "老写法也按 05:00 归月")
    }

    /// astra #6：两个窗口同时往同一个月文件写，两边的条目都留着
    func testConcurrentWritersSameMonthKeepBoth() {
        let d = dir
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            let conv = i % 2 == 0 ? "conv-a" : "conv-b"
            let day = String(format: "2026-10-%02d", i / 2 + 1)
            let e = TimelineEntry(start: date(10, i / 2 + 1, 10), end: date(10, i / 2 + 1, 11), conversationId: conv, title: conv,
                                  text: "- \(i)", pending: "", day: day, lastNodeId: "n\(i)")
            do { try TimelineStore.upsert(e, in: d) } catch { XCTFail("\(error)") }
        }
        let all = TimelineStore.entries(month: "2026-10", in: d)
        XCTAssertEqual(all.count, 40, "没有谁覆盖掉别人刚写的")
        XCTAssertEqual(all.filter { $0.conversationId == "conv-a" }.count, 20)
    }

    func testLatestAndPrevious() throws {
        try TimelineStore.upsert(v2("2026-09-30", "conv-x", start: date(9, 30, 10), end: date(9, 30, 11), topics: ["九月底"], pending: "甲"), in: dir)
        try TimelineStore.upsert(v2("2026-10-02", "conv-x", start: date(10, 2, 10), end: date(10, 2, 11), topics: ["十月"], pending: "乙"), in: dir)
        try TimelineStore.upsert(v2("2026-10-03", "conv-y", start: date(10, 3, 10), end: date(10, 3, 11), topics: ["别的"]), in: dir)
        XCTAssertEqual(TimelineStore.latest(conversationId: "conv-x", in: dir)?.day, "2026-10-02")
        XCTAssertEqual(TimelineStore.latest(conversationId: "conv-x", before: "2026-10-02", in: dir)?.pending, "甲", "跨月往回找")
        XCTAssertNil(TimelineStore.latest(conversationId: "conv-x", before: "2026-09-30", in: dir))
        XCTAssertNil(TimelineStore.latest(conversationId: "conv-z", in: dir))
    }
}
