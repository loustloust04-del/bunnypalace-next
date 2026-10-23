import XCTest
@testable import 记忆花园

/// v4-1 §六：当前窗口不注入和原文重复的东西；同一个窗口待续只带一次；发送时记账
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

    func testPendingOnlyOnLatestPerWindow() throws {
        let text = try XCTUnwrap(TimelineStore.injectionText([entry(8, "a", last: nil, pending: "旧的"), entry(9, "b", last: nil, pending: "乙"),
                                                              entry(10, "a", last: nil, pending: "新的")]))
        XCTAssertFalse(text.contains("旧的"), "同一个窗口只在最新那条后面带待续")
        XCTAssertTrue(text.contains("（待续：新的）") && text.contains("（待续：乙）"))
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

    /// 记账记下的条目 = 插槽文字里实际出现的那几条
    func testSlotEntriesMatchText() throws {
        let tl = TimelineStore.dir(profileId: pid)
        try TimelineStore.write([entry(8, "other-0001", last: "o1", pending: "甲"), entry(9, "cur-00001", last: "h1"),
                                 entry(10, "cur-00001", last: "gone")], month: "2026-10", in: tl)
        let slot = CalendarInjection.timelineSlot(profileId: pid, currentConversationId: "cur-00001", windowIds: ["h1"], now: date(11, 12))
        let text = try XCTUnwrap(slot.timeline)
        XCTAssertEqual(slot.entries.map(\.dayKey), ["2026-10-08", "2026-10-10"])
        for e in slot.entries { XCTAssertTrue(text.contains(TimelineStore.line(e, withPending: true).components(separatedBy: "（待续").first!)) }
        XCTAssertFalse(text.contains("第9天"))
        MemoryInjectionMeter.record(profileId: pid, hits: [], memories: [], timelineKeys: slot.entries.map(MemoryInjectionMeter.key),
                                    contextKeys: ["cur-0000|n1"])
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid)?.timelineKeys, ["2026-10-08|other-0001", "2026-10-10|cur-00001"])
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid)?.contextKeys, ["cur-0000|n1"])
    }
}
