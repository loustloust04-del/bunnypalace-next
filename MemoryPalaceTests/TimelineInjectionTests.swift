import MemoryCore
import XCTest
@testable import 记忆花园

/// v4-1 §六：当前窗口不注入和原文重复的东西；待续单独一段、同一个窗口只带一次；发送时记账（c2c3-v2 第 7 段：一天一条 + 老条目）
final class TimelineInjectionTests: XCTestCase {

    let pid = "xctest-timeline-inject"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        MemoryInjectionMeter.clear(profileId: pid)
        super.tearDown()
    }

    private func date(_ d: Int, _ h: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!
    }

    private func entry(_ day: Int, _ conv: String, last: String?, pending: String = "") -> TimelineEntry {
        TimelineEntry(start: date(day, 10), end: date(day, 11), conversationId: conv, title: conv, text: "- \(conv) 第\(day)天",
                      pending: pending, day: "2026-10-\(String(format: "%02d", day))", lastNodeId: last)
    }

    func testCurrentWindowEntryStillInHistoryIsSkipped() {
        let window: Set<String> = ["h1", "h2"]
        XCTAssertFalse(TimelineStore.injectable(entry(10, "cur", last: "h2"), currentConversationId: "cur", windowIds: window))
        XCTAssertTrue(TimelineStore.injectable(entry(9, "cur", last: "old"), currentConversationId: "cur", windowIds: window))
        XCTAssertTrue(TimelineStore.injectable(entry(10, "other", last: "h2"), currentConversationId: "cur", windowIds: window), "别的窗口的条目全注")
        var v1 = entry(10, "cur", last: nil); v1.day = nil
        XCTAssertTrue(TimelineStore.injectable(v1, currentConversationId: "cur", windowIds: window), "老条目没有 id，照注")
    }

    /// 待续还没迁移的楼层：照读老条目里的老字段，同一个窗口只取最新那条；单独一段，不跟在条目后面
    func testUnmigratedPendingFromLatestLegacyEntry() throws {
        let entries = ["2026-10-08": [entry(8, "a", last: nil, pending: "旧的")], "2026-10-09": [entry(9, "b", last: nil, pending: "乙")],
                       "2026-10-10": [entry(10, "a", last: nil, pending: "新的")]]
        let text = try XCTUnwrap(TimelineStore.injection(records: [:], entries: entries, today: "2026-10-10", currentConversationId: "",
                                                         windowIds: [], openPending: nil).text)
        XCTAssertFalse(text.contains("旧的"), "同一个窗口只取最新那条的待续")
        XCTAssertTrue(text.contains("[待续]") && text.contains("《a》conv a：新的") && text.contains("《b》conv b：乙"))
        XCTAssertTrue(text.hasPrefix("[时间轴]"), "给小克看的名字和记忆 app 一致")
    }

    func testContextSegmentsOverlappingWindowAreSkipped() {
        func seg(_ kind: SessionSegment.Kind, last: String?, to: Int) -> SessionSegment {
            SessionSegment(kind: kind, title: "\(kind)", start: .distantPast, end: .distantPast, from: 0, to: to, lastNodeId: last,
                           story: "", quotes: "", pending: "")
        }
        let segs = [seg(.legacy, last: nil, to: 10), seg(.rolling, last: "out", to: 20), seg(.closeout, last: "out2", to: 30), seg(.rolling, last: "h1", to: 40)]
        XCTAssertEqual(SessionSummaryStore.injectableSegments(segs, windowIds: ["h1"], windowStart: 30).map(\.kind), [.legacy, .rolling],
                       "收尾段不注；最后一条还在窗口里的不注")
        XCTAssertEqual(SessionSummaryStore.injectableSegments(segs, windowIds: ["h1"], windowStart: 5).map(\.kind), [.rolling],
                       "老段没有 id 看下标：它盖到的最后一条在窗口里就不注")
    }

    func testWindowSegmentInSessionsNeverEntersZ2OrA2Readers() async throws {
        let cid = "window-kind-guard"
        let formal = SessionSegment(kind: .rolling, title: "北门", start: date(10, 10), end: date(10, 11),
                                    from: 0, to: 6, lastNodeId: "out", story: "走北门", quotes: "", pending: "", format: 2)
        var window = formal
        window.kind = .window
        window.title = "不该注入"
        window.story = "窗口总结不能冒充上下文"
        let s = SessionSummary(conversationId: cid, title: "云桥城", compressedCount: 6, segments: [formal, window], updatedAt: date(10, 12))
        try SessionSummaryStore.save(s, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        var loaded = try XCTUnwrap(SessionSummaryStore.load(conversationId: cid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        loaded.segments = SessionSummaryStore.injectableSegments(loaded.segments, windowIds: [], windowStart: 100)
        XCTAssertEqual(loaded.segments, [formal])
        let z2 = try XCTUnwrap(SessionSummaryStore.injectionText(loaded, fullCount: 2))
        XCTAssertTrue(z2.contains("走北门"))
        XCTAssertFalse(z2.contains("不该注入") || z2.contains(window.story))
        let catalog = await CatalogALineReader.readWindow(cid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        XCTAssertEqual(catalog?.segments.map(\.segment), [formal])
        XCTAssertEqual(WindowSummaryReader.loadContext(conversationId: cid, profileId: pid)?.a2, [formal])
    }

    /// 记账记下的单位 = 插槽文字里实际出现的那几行（今天算第 1 天：11 号、10 号带各项，9 号往前只带主调）
    func testSlotUnitsMatchText() throws {
        let tl = TimelineStore.dir(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        func item(_ conv: String, _ d: Int, to: String) -> TimelineDayRecord.Item {
            .init(kind: .segment, conversationId: conv, window: conv, title: "\(conv) 第\(d)天", start: date(d, 10), end: date(d, 11), from: "f", to: to)
        }
        try TimelineStore.save(.init(days: [
            TimelineDayRecord(date: "2026-10-09", headline: "九号的主调", items: [item("other-0001", 9, to: "o9")]),
            TimelineDayRecord(date: "2026-10-10", headline: "十号的主调", items: [item("other-0001", 10, to: "o1"), item("cur-00001", 10, to: "gone")]),
            TimelineDayRecord(date: "2026-10-11", headline: "十一号的主调", items: [item("cur-00001", 11, to: "h1")]),
        ], entries: [entry(8, "old-00001", last: "x")]), month: "2026-10", in: tl)
        let slot = CalendarInjection.timelineSlot(profileId: pid, currentConversationId: "cur-00001", windowIds: ["h1"], now: date(11, 12),
                                                          participation: .testValue(profileId: pid))
        let text = try XCTUnwrap(slot.timeline)
        for u in slot.units { XCTAssertTrue(text.contains(u.line)) }
        XCTAssertFalse(text.contains("cur-00001 第11天"), "原文还在窗口里的不注")
        XCTAssertFalse(text.contains("other-0001 第9天"), "第 3 天往前只带主调")
        XCTAssertTrue(text.contains("10-08 周四：（旧格式）《old-00001》old-00001 第8天 conv old-0000"), "8 号只有老条目、没有主调：带一行老条目的话题，标旧格式")
        MemoryInjectionMeter.record(profileId: pid, record: MemoryInjectionRecord(
            tokens: 0, stableCount: 0, hitCount: 0, at: Date(), timelineKeys: slot.units.map(\.key), contextKeys: ["cur-0000|n1"]))
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid)?.timelineKeys,
                       ["2026-10-08", "2026-10-09", "2026-10-10", "2026-10-10|other-0001|o1", "2026-10-10|cur-00001|gone", "2026-10-11"])
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid)?.contextKeys, ["cur-0000|n1"])
    }
}
