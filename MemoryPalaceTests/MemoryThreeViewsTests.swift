import XCTest
@testable import 记忆花园

/// 记忆 app 三样分格（plan-memory-app-three-views）：窗口总结段排序、窗口列表、记忆起点
final class MemoryThreeViewsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func seg(_ title: String, _ kind: SessionSegment.Kind, at offset: TimeInterval) -> SessionSegment {
        let start = t0.addingTimeInterval(offset)
        return SessionSegment(kind: kind, title: title, start: start, end: start.addingTimeInterval(600), from: 0, to: 0,
                              lastNodeId: nil, story: "经过\(title)", quotes: "", pending: "待续\(title)")
    }

    // MARK: - 窗口总结段排序

    func testOrderedPutsLegacyFirstThenByStart() {
        let segs = [seg("收尾 B", .closeout, at: 3600), seg("老", .legacy, at: 9000), seg("压缩 A", .rolling, at: 0)]
        XCTAssertEqual(WindowSummaryReader.ordered(segs).map(\.title), ["老", "压缩 A", "收尾 B"])
    }

    func testOrderedKeepsFileOrderOnTie() {
        let segs = [seg("一", .rolling, at: 60), seg("二", .closeout, at: 60), seg("零", .rolling, at: 0)]
        XCTAssertEqual(WindowSummaryReader.ordered(segs).map(\.title), ["零", "一", "二"])
    }

    func testContextSegmentsDropCloseout() {
        let segs = [seg("老", .legacy, at: 0), seg("压缩", .rolling, at: 60), seg("收尾", .closeout, at: 120)]
        XCTAssertEqual(WindowSummaryReader.contextSegments(segs).map(\.title), ["老", "压缩"])
    }

    // MARK: - 窗口总结格列表

    private func summary(_ cid: String, title: String, segs: [SessionSegment], updated: TimeInterval) -> SessionSummary {
        SessionSummary(conversationId: cid, title: title, compressedCount: 0, segments: segs,
                       updatedAt: t0.addingTimeInterval(updated))
    }

    func testRowsSkipEmptyMarkGoneAndSortByRecent() {
        let a = summary("conv-a", title: "旧名 A", segs: [seg("1", .rolling, at: 0), seg("2", .closeout, at: 86_400)], updated: 100)
        let b = summary("conv-b", title: "B", segs: [seg("1", .closeout, at: 0)], updated: 500)
        let empty = summary("conv-c", title: "空", segs: [], updated: 900)
        let rows = WindowSummaryListLayout.rows([a, b, empty], aliveTitles: ["conv-a": "新名 A"])
        XCTAssertEqual(rows.map(\.conversationId), ["conv-b", "conv-a"], "一段都没有的不出；最近写过的在上")
        XCTAssertEqual(rows[1].title, "新名 A", "窗口还在：用现在的标题")
        XCTAssertFalse(rows[1].isGone)
        XCTAssertEqual(rows[0].title, "B", "窗口删了：用文件里的标题")
        XCTAssertTrue(rows[0].isGone)
        XCTAssertEqual(rows[1].segmentCount, 2)
        XCTAssertEqual(rows[1].first, t0)
        XCTAssertEqual(rows[1].last, t0.addingTimeInterval(86_400 + 600))
    }

    func testDateRangeText() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
        let d1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        let d1b = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 22))!
        let d9 = cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9))!
        XCTAssertEqual(WindowSummaryListLayout.dateRange(first: d1, last: d9, now: now, calendar: cal), "10月1日 – 10月9日")
        XCTAssertEqual(WindowSummaryListLayout.dateRange(first: d1, last: d1b, now: now, calendar: cal), "10月1日")
        XCTAssertNil(WindowSummaryListLayout.dateRange(first: nil, last: nil, now: now, calendar: cal))
    }

    // MARK: - 记忆从哪天开始

    private var shanghai: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    func testStartDayParseFormatRoundTrip() {
        let cal = shanghai
        let d = try! XCTUnwrap(MemoryStartDay.parse("2026-10-01", calendar: cal))
        XCTAssertEqual(d, cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 5)), "v4-1：起点那天也从 05:00 算")
        XCTAssertEqual(MemoryStartDay.format(d, calendar: cal), "2026-10-01")
        XCTAssertNil(MemoryStartDay.parse("", calendar: cal), "空 = 不限")
        XCTAssertNil(MemoryStartDay.parse("十月一日", calendar: cal), "写坏了 = 不限")
    }

    func testFirstAllowedIndex() {
        let start = t0
        let before = t0.addingTimeInterval(-3600), after = t0.addingTimeInterval(3600)
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([before, after], startDay: nil), 0, "不限")
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([after, after], startDay: start), 0, "全在起点以后")
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([before, before, after, after], startDay: start), 2)
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([before, after, before, after], startDay: start), 3, "时间不单调：取起点以前最后一条之后")
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([before, before], startDay: start), 2, "全在起点以前 = 一条都不给")
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([nil, after], startDay: start), 0, "没时间的不算以前")
        XCTAssertEqual(MemoryStartDay.firstAllowedIndex([start], startDay: start), 0, "起点当天 00:00 那条算进去")
    }

    // MARK: - 起点接进写手

    /// 路径：n 条消息，第 i 条在 t0 + i 小时
    private func ids(_ n: Int) -> [String] { (0..<n).map { "n\($0)" } }
    private func dates(_ n: Int) -> [Date?] { (0..<n).map { t0.addingTimeInterval(TimeInterval($0) * 3600) } }
    private func hour(_ i: Int) -> Date { t0.addingTimeInterval(TimeInterval(i) * 3600) }
    /// 起点设在第 i 条消息那一刻 → 第 i 条起能写
    private func notBefore(_ n: Int, startAt i: Int) -> Int {
        MemoryStartDay.firstAllowedIndex(dates(n), startDay: hour(i))
    }

    private func written(_ kind: SessionSegment.Kind, _ range: Range<Int>) -> SessionSegment {
        SessionSegment(kind: kind, title: "\(range)", start: hour(range.lowerBound), end: hour(range.upperBound - 1),
                       from: range.lowerBound, to: range.upperBound, lastNodeId: "n\(range.upperBound - 1)",
                       story: "", quotes: "", pending: "")
    }

    private func summary(_ segs: [SessionSegment], compressed: Int = 0) -> SessionSummary {
        SessionSummary(conversationId: "conv-start", title: "t", compressedCount: compressed, segments: segs, updatedAt: t0)
    }

    /// 收尾 + 首次补写：起点以前的消息不进任何一段
    func testPendingRangesRespectStartDay() {
        let s = summary([])
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(200), dates: dates(200)), [50..<200], "不限：首次补写照旧倒回 150 条")
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(200), dates: dates(200), notBefore: notBefore(200, startAt: 120)),
                       [120..<200], "首次补写截在起点")
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(200), dates: dates(200), notBefore: notBefore(200, startAt: 10)),
                       [50..<200], "起点更早：150 条上限照旧")
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(200), dates: dates(200), notBefore: 200), [], "全在起点以前：不收尾")
        let done = summary([written(.rolling, 0..<100)])
        XCTAssertEqual(SessionCloseout.pendingRanges(done, pathIds: ids(200), dates: dates(200), notBefore: 150), [150..<200],
                       "接着写也不早于起点")
    }

    /// 设 10-01 收尾 → 改成 09-01：跳过的那截又能补（不超首次补写上限），已经写下的不重写
    func testMovingStartEarlierReopensSkippedStretchForCloseout() {
        let first = SessionCloseout.pendingRanges(summary([]), pathIds: ids(300), dates: dates(300), notBefore: notBefore(300, startAt: 200))
        XCTAssertEqual(first, [200..<300], "起点在第 200 条：前面不写")

        let s = summary([written(.rolling, 200..<300)])
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(310), dates: dates(310), notBefore: notBefore(310, startAt: 200)),
                       [300..<310], "起点不动：只接着写新的")
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(310), dates: dates(310), notBefore: notBefore(310, startAt: 0)),
                       [160..<200, 300..<310], "起点往前挪：跳过的那截补回来，最多倒回到整条路径倒数 150 条；200..<300 不重写")

        XCTAssertEqual(SessionCloseout.insertionIndex(s, chunkStart: hour(160)), 0, "补写的插在最早那段前面")
        XCTAssertEqual(SessionCloseout.insertionIndex(s, chunkStart: hour(300)), 1, "接着写的照旧追加")
    }

    /// 首次补写被 150 条上限截掉的老消息，不会因为这次改动被翻出来
    func testNaturalFirstCloseoutCapIsNotBackfilled() {
        let s = summary([written(.rolling, 50..<200)])
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(210), dates: dates(210)), [200..<210])
        XCTAssertEqual(SessionCloseout.pendingRanges(s, pathIds: ids(200), dates: dates(200)), [], "写到头了")
        let legacy = summary([SessionSegment(kind: .legacy, title: "老", start: hour(250), end: hour(250), from: 0, to: 40,
                                             lastNodeId: nil, story: "老", quotes: "", pending: ""), written(.rolling, 120..<200)])
        XCTAssertEqual(SessionCloseout.pendingRanges(legacy, pathIds: ids(210), dates: dates(210)), [200..<210],
                       "有改版前累计摘要（从第 0 条盖起）：不补前面")
    }

    /// 压缩：锚点只算真写进段的
    func testCompressPlanAnchorCountsOnlyWrittenMessages() {
        let s = summary([])
        XCTAssertEqual(SessionCloseout.compressPlan(s, pathIds: ids(300), dates: dates(300), oldCount: 260),
                       SessionCloseout.CompressPlan(ranges: [110..<260], anchor: 260), "不限：照旧倒回 150 条")
        XCTAssertEqual(SessionCloseout.compressPlan(s, pathIds: ids(300), dates: dates(300), oldCount: 260, notBefore: 200),
                       SessionCloseout.CompressPlan(ranges: [200..<260], anchor: 260))
        XCTAssertNil(SessionCloseout.compressPlan(s, pathIds: ids(300), dates: dates(300), oldCount: 260, notBefore: 280),
                     "窗外全在起点以前、一段都没有：不写，锚点不动")

        let has = summary([written(.rolling, 0..<100)], compressed: 100)
        XCTAssertNil(SessionCloseout.compressPlan(has, pathIds: ids(300), dates: dates(300), oldCount: 160, notBefore: 280),
                     "窗外新的那截全在起点以前：锚点不推过去")
        XCTAssertEqual(SessionCloseout.compressPlan(has, pathIds: ids(300), dates: dates(300), oldCount: 160),
                       SessionCloseout.CompressPlan(ranges: [100..<160], anchor: 160), "起点挪回去：那截照常压")
        XCTAssertNil(SessionCloseout.compressPlan(has, pathIds: ids(300), dates: dates(300), oldCount: 100), "锚点已经到了")

        let closed = summary([written(.rolling, 0..<100), written(.closeout, 100..<200)], compressed: 100)
        XCTAssertEqual(SessionCloseout.compressPlan(closed, pathIds: ids(300), dates: dates(300), oldCount: 160),
                       SessionCloseout.CompressPlan(ranges: [100..<160], anchor: 160),
                       "v4-1 astra #7：老收尾段不注入，不算覆盖——它盖的那截照样压成压缩段")
    }

    /// astra #7：存量 rolling [0,20) + closeout [20,40)，窗外到 40 → [20,40) 重新写成压缩段（不重生成也要成立）
    func testOldCloseoutRangeGetsCompressedAgain() async throws {
        let s = summary([written(.rolling, 0..<20), written(.closeout, 20..<40)], compressed: 20)
        XCTAssertEqual(SessionCloseout.compressPlan(s, pathIds: ids(60), dates: dates(60), oldCount: 40),
                       SessionCloseout.CompressPlan(ranges: [20..<40], anchor: 40))
        let msgs = (0..<60).map { SessionSegmentWriter.Message(id: "n\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "x", date: hour($0)) }
        var out = s
        var fed = ""
        _ = try await SessionCloseout.writeContextParts([20..<40], messages: msgs, into: &out, title: "t", persona: "",
                                                        speakers: .init(userName: "粟粟", assistantName: "小克"), caller: { _, user in
            fed = user
            return "标题：补压\n【经过】接着聊\n【原话】粟粟：「嗯」"
        }, save: { _ in })
        XCTAssertEqual(out.segments.map(\.kind), [.rolling, .closeout, .rolling], "收尾段留在文件里（窗口总结退回读它），新压缩段插在后面")
        XCTAssertTrue(fed.contains("上一段「0..<20」"), "喂的上一段是压缩段，不是老收尾段")
        XCTAssertEqual(SessionSummaryStore.resumeIndex(SessionCloseout.coverage(out), pathIds: ids(60)), 40)
    }

    /// 设 10-01 压缩 → 改成 09-01：跳过的那截又能压，已经写下的不重写
    func testMovingStartEarlierReopensSkippedStretchForCompress() {
        let first = SessionCloseout.compressPlan(summary([]), pathIds: ids(300), dates: dates(300), oldCount: 260,
                                                 notBefore: notBefore(300, startAt: 200))
        XCTAssertEqual(first, SessionCloseout.CompressPlan(ranges: [200..<260], anchor: 260))

        let s = summary([written(.rolling, 200..<260)], compressed: 260)
        XCTAssertEqual(SessionCloseout.compressPlan(s, pathIds: ids(300), dates: dates(300), oldCount: 270,
                                                    notBefore: notBefore(300, startAt: 0)),
                       SessionCloseout.CompressPlan(ranges: [150..<200, 260..<270], anchor: 270),
                       "跳过的那截补回来（最多倒回整条路径 150 条）；200..<260 不重写")
    }


    /// v4-1 Q3：两个开关任一个开着就收尾
    func testQueueNoteFollowsBothSwitches() {
        XCTAssertEqual(WindowSummaryListLayout.queueNote(masterOn: false, summaryOn: true, timelineOn: true, queueEmpty: false), "记忆总开关关着，现在不记")
        XCTAssertTrue(WindowSummaryListLayout.queueNote(masterOn: true, summaryOn: false, timelineOn: false, queueEmpty: false)?.contains("都关着") == true)
        XCTAssertNil(WindowSummaryListLayout.queueNote(masterOn: true, summaryOn: false, timelineOn: true, queueEmpty: false), "只开时间轴也收尾")
        XCTAssertNil(WindowSummaryListLayout.queueNote(masterOn: true, summaryOn: true, timelineOn: false, queueEmpty: false))
        XCTAssertEqual(WindowSummaryListLayout.queueNote(masterOn: true, summaryOn: true, timelineOn: true, queueEmpty: true), "现在没有等着记的窗口")
    }
}
