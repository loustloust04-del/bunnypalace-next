import XCTest
@testable import MemoryCore

/// 时间轴月文件：c2c3-v2 第 7 段的一天一条和留下来的老条目（v2 一天 × 一窗口 / 更老的格式）同住一份文件、按 05:00 归月；
/// 老条目只读，新旧读得出、写回不丢
final class TimelineStoreV2Tests: XCTestCase {

    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-v2-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var dir: URL { TimelineStore.dir(root: root) }

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

    /// ⑤-1 P2-b（R-1）：来源窗已删 / 关参与 → 那窗的项和老条目不注；一天一条的主调行照带（整天聚合，不归属单个窗）
    /// 老条目放在**没有 record 的日子**（有主调的日子本来就不出老条目，放那儿是白绿）
    func testInjectionDropsHiddenConversationRowsButKeepsHeadline() throws {
        let day = "2026-10-11"
        let kept = item("conv-kept-0001", "开着的窗", date(10, 11, 14, 20), date(10, 11, 15, 5))
        let hidden = item("conv-off-0001", "关参与窗", date(10, 11, 16, 0), date(10, 11, 16, 30))
        let hiddenOldDay = "2026-10-09"
        let hiddenOld = v2(hiddenOldDay, "conv-off-0002", start: date(10, 9, 17), end: date(10, 9, 18),
                           topics: ["隐藏窗的话题"], pending: "隐藏待续")
        let keptOldDay = "2026-10-08"
        let keptOld = v2(keptOldDay, "conv-kept-0002", start: date(10, 8, 9), end: date(10, 8, 10),
                         topics: ["开窗老条目"], pending: "开窗待续")
        let injection = TimelineStore.injection(
            records: [day: record(day, headline: "今天的主调", items: [kept, hidden])],
            entries: [hiddenOldDay: [hiddenOld], keptOldDay: [keptOld]], today: day, currentConversationId: "",
            windowIds: [], openPending: [:], hiddenConversations: ["conv-off-0001", "conv-off-0002"])
        let text = try XCTUnwrap(injection.text)
        XCTAssertTrue(text.contains("今天的主调"), "主调行是整天聚合，不按窗挡")
        XCTAssertTrue(text.contains("开着的窗"))
        XCTAssertFalse(text.contains("关参与窗"), "关参与窗的项不带")
        XCTAssertTrue(text.contains("开窗老条目"), "没有 record 的日子：开窗老条目照带")
        XCTAssertFalse(text.contains("隐藏窗的话题"), "关参与窗的老条目不带")
        XCTAssertEqual(injection.units.filter { $0.key.contains("conv-off") }, [])

        // openPending = nil 那条老路径：待续从注进去的老条目里取，隐藏窗的也不带
        let legacyPending = TimelineStore.injection(
            records: [:], entries: [hiddenOldDay: [hiddenOld], keptOldDay: [keptOld]], today: day,
            currentConversationId: "", windowIds: [], openPending: nil,
            hiddenConversations: ["conv-off-0002"])
        let pendingText = try XCTUnwrap(legacyPending.text)
        XCTAssertTrue(pendingText.contains("开窗待续"))
        XCTAssertFalse(pendingText.contains("隐藏待续"), "关参与窗的老待续不带")
        XCTAssertEqual(legacyPending.hiddenCount, 2, "隐藏老条目 1 + 它的待续窗 1（nil 分支也要数）")
        XCTAssertTrue(pendingText.contains("开窗老条目"))
        XCTAssertFalse(pendingText.contains("隐藏窗的话题"))
    }

    /// ⑤-1 P2-b r2（Opus 必修 3）：当天条目全来自隐藏窗 → 主调也是那扇窗的摘要，一起不带；
    /// 只隐藏一部分、以及条目本来就空的日子照带主调
    func testInjectionDropsHeadlineWhenAllItemsAreHidden() throws {
        let today = "2026-10-11"
        let hiddenDay = "2026-10-10"
        let emptyDay = "2026-10-09"
        let earlierHiddenDay = "2026-10-07"   // 非 full 日：只有主调那条分支，全隐藏 = 整天不出现
        let kept = item("conv-kept-0001", "开着的窗", date(10, 11, 14, 20), date(10, 11, 15, 5))
        let hidden = item("conv-off-0001", "关参与窗", date(10, 10, 16, 0), date(10, 10, 16, 30))
        let earlierHidden = item("conv-off-0001", "关参与窗", date(10, 7, 16, 0), date(10, 7, 16, 30))
        let hiddenOld = v2(hiddenDay, "conv-kept-0002", start: date(10, 10, 9), end: date(10, 10, 10), topics: ["开窗老条目"])
        let injection = TimelineStore.injection(
            records: [today: record(today, headline: "今天的主调", items: [kept]),
                      hiddenDay: record(hiddenDay, headline: "全隐藏的主调", items: [hidden]),
                      emptyDay: record(emptyDay, headline: "没条目的主调", items: []),
                      earlierHiddenDay: record(earlierHiddenDay, headline: "早先全隐藏的主调", items: [earlierHidden])],
            entries: [hiddenDay: [hiddenOld]], today: today, currentConversationId: "", windowIds: [],
            openPending: [:], hiddenConversations: ["conv-off-0001"])
        let text = try XCTUnwrap(injection.text)
        XCTAssertTrue(text.contains("今天的主调"))
        XCTAssertTrue(text.contains("开着的窗"), "只隐藏一部分：主调照带")
        XCTAssertFalse(text.contains("全隐藏的主调"), "当天条目全来自隐藏窗：主调不带")
        XCTAssertFalse(text.contains("关参与窗"))
        XCTAssertTrue(text.contains("（旧格式，没有主调）"), "退回老条目那一行")
        XCTAssertTrue(text.contains("开窗老条目"))
        XCTAssertTrue(text.contains("没条目的主调"), "条目本来就空的日子主调照带")
        XCTAssertFalse(text.contains("早先全隐藏的主调"), "更早的日子同样不带全隐藏的主调")
        XCTAssertFalse(injection.units.contains { $0.key == earlierHiddenDay }, "整天不出现")
    }

    /// ⑤-1 P2-b r2（kimi 建议 2）：空串 conversationId + 非空隐藏集照带（空串不会命中任何窗）
    func testInjectionKeepsEmptyConversationIdRows() throws {
        let day = "2026-10-11"
        let emptyId = item("", "空编号窗", date(10, 11, 14, 20), date(10, 11, 15, 5))
        let injection = TimelineStore.injection(
            records: [day: record(day, headline: "今天的主调", items: [emptyId])],
            entries: [:], today: day, currentConversationId: "", windowIds: [], openPending: nil,
            hiddenConversations: ["conv-off-0001"])
        let text = try XCTUnwrap(injection.text)
        XCTAssertTrue(text.contains("空编号窗"), "空串 conversationId 不在隐藏集里，照带")
    }

    /// ⑤-2 P1-b：待续记账每窗一行，与注入文本里那行一字不差
    func testPendingUnitsMatchInjectedLines() throws {
        let day = "2026-10-11"
        let kept = item("conv-kept-0001", "开着的窗", date(10, 11, 14, 20), date(10, 11, 15, 5))
        let other = item("conv-kept-0002", "另一扇窗", date(10, 11, 16, 0), date(10, 11, 16, 30))
        let injection = TimelineStore.injection(
            records: [day: record(day, headline: "今天的主调", items: [kept, other])],
            entries: [:], today: day, currentConversationId: "", windowIds: [],
            openPending: ["conv-kept-0001": ["跑金样", "写复盘"], "conv-kept-0002": ["等批注"]])
        let text = try XCTUnwrap(injection.text)
        XCTAssertEqual(injection.pendingUnits.map(\.conversationId), ["conv-kept-0001", "conv-kept-0002"])
        let injected = try XCTUnwrap(text.components(separatedBy: "[待续]").last)
            .components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(injection.pendingUnits.map(\.line), injected, "逐字一致")
        XCTAssertEqual(injection.hiddenCount, 0)

        let onlyPending = TimelineStore.injection(
            records: [day: record(day, headline: "今天的主调", items: [kept])],
            entries: [:], today: day, currentConversationId: "", windowIds: [],
            openPending: ["conv-kept-0001": ["跑金样"]], timelineLines: false)
        XCTAssertEqual(onlyPending.units, [], "只要待续：时间轴那几行不出")
        let injectedLine: String? = onlyPending.text?.components(separatedBy: "\n").last { $0.hasPrefix("- ") }
        XCTAssertEqual(onlyPending.pendingUnits.first?.line, injectedLine)
    }

    /// ⑤-2 P1-b：来源窗挡掉的项 / 老条目 / 待续窗各算一条（三处加法缺一即红）
    func testHiddenCountCountsItemsOldEntriesPending() throws {
        let day = "2026-10-11"
        let kept = item("conv-kept-0001", "开着的窗", date(10, 11, 14, 20), date(10, 11, 15, 5))
        let hiddenItem = item("conv-off-0001", "关参与窗", date(10, 11, 16, 0), date(10, 11, 16, 30))
        let hiddenOldDay = "2026-10-09"
        let hiddenOld = v2(hiddenOldDay, "conv-off-0001", start: date(10, 9, 17), end: date(10, 9, 18),
                           topics: ["隐藏窗的话题"], pending: "隐藏待续")
        let injection = TimelineStore.injection(
            records: [day: record(day, headline: "今天的主调", items: [kept, hiddenItem])],
            entries: [hiddenOldDay: [hiddenOld]], today: day, currentConversationId: "", windowIds: [],
            openPending: ["conv-off-0001": ["隐藏待续"], "conv-kept-0001": ["开窗待续"]],
            hiddenConversations: ["conv-off-0001"])
        let text = try XCTUnwrap(injection.text)
        XCTAssertEqual(injection.hiddenCount, 3, "项 1 + 老条目 1 + 待续窗 1")
        XCTAssertEqual(injection.pendingUnits.map(\.conversationId), ["conv-kept-0001"])
        XCTAssertFalse(text.contains("关参与窗"))
        XCTAssertFalse(text.contains("隐藏窗的话题"))
        XCTAssertFalse(text.contains("隐藏待续"))

        let nothingVisible = TimelineStore.injection(
            records: [day: record(day, headline: nil, items: [hiddenItem])],
            entries: [:], today: day, currentConversationId: "", windowIds: [],
            openPending: [:], hiddenConversations: ["conv-off-0001"])
        XCTAssertNil(nothingVisible.text, "全挡掉")
        XCTAssertEqual(nothingVisible.hiddenCount, 1, "挡掉的条数照样记")
    }

    /// ⑤-2 P1 r2（Opus 必修 2）：本窗只要待续不要时间轴 → 项 / 老条目本来就不上 wire，不算候选；
    /// 待续窗照数
    func testHiddenCountSkipsTimelineItemsWhenTimelineLinesOff() throws {
        let day = "2026-10-11"
        let hiddenItem = item("conv-off-0001", "关参与窗", date(10, 11, 16, 0), date(10, 11, 16, 30))
        let hiddenOldDay = "2026-10-09"
        let hiddenOld = v2(hiddenOldDay, "conv-off-0001", start: date(10, 9, 17), end: date(10, 9, 18),
                           topics: ["隐藏窗的话题"], pending: "隐藏待续")
        let injection = TimelineStore.injection(
            records: [day: record(day, headline: "今天的主调", items: [hiddenItem])],
            entries: [hiddenOldDay: [hiddenOld]], today: day, currentConversationId: "", windowIds: [],
            openPending: ["conv-off-0001": ["隐藏待续"]], timelineLines: false,
            hiddenConversations: ["conv-off-0001"])
        XCTAssertEqual(injection.hiddenCount, 1, "只要待续：项 / 老条目不算，只数待续窗")
        XCTAssertNil(injection.text, "隐藏窗的项 / 老条目 / 待续都不上 wire")

        let withLines = TimelineStore.injection(
            records: [day: record(day, headline: "今天的主调", items: [hiddenItem])],
            entries: [hiddenOldDay: [hiddenOld]], today: day, currentConversationId: "", windowIds: [],
            openPending: ["conv-off-0001": ["隐藏待续"]],
            hiddenConversations: ["conv-off-0001"])
        XCTAssertEqual(withLines.hiddenCount, 3, "勾着时间轴：项 + 老条目 + 待续窗")
    }
}
