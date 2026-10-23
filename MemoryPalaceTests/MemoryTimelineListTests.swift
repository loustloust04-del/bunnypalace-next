import XCTest
@testable import 记忆花园

/// #067 第 2 步：时间轴列表页的纯函数——月份枚举、按天分组（含跨天）、待续「无」不出
final class MemoryTimelineListTests: XCTestCase {

    let pid = "xctest-timeline-list"

    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        super.tearDown()
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func entry(_ start: Date, _ end: Date, _ conv: String, pending: String = "") -> TimelineEntry {
        TimelineEntry(start: start, end: end, conversationId: conv, title: conv, text: "聊了 \(conv)", pending: pending)
    }

    // MARK: - 月份枚举

    func testMonthsNewestFirstFromDisk() throws {
        try TimelineStore.append(entry(date(2026, 8, 3, 10, 0), date(2026, 8, 3, 11, 0), "a"), profileId: pid)
        try TimelineStore.append(entry(date(2026, 10, 15, 10, 0), date(2026, 10, 15, 11, 0), "b"), profileId: pid)
        try TimelineStore.append(entry(date(2025, 12, 15, 10, 0), date(2025, 12, 15, 11, 0), "c"), profileId: pid)
        try TimelineStore.append(entry(date(2026, 9, 9, 10, 0), date(2026, 9, 9, 11, 0), "d"), profileId: pid)
        let dir = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent(TimelineStore.folder)
        try Data("x".utf8).write(to: dir.appendingPathComponent("说明.md"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("2026-07.txt"))

        XCTAssertEqual(TimelineStore.months(profileId: pid), ["2026-10", "2026-09", "2026-08", "2025-12"])
    }

    func testMonthsMissingFolderIsEmpty() {
        XCTAssertEqual(TimelineStore.months(profileId: pid), [])
    }

    func testMonthNamesFiltersAndSorts() {
        let names = ["2026-01.md", "2026-10.md", "2025-11.md", "notes.md", "2026-1.md", "2026-09.md.bak", ".DS_Store"]
        XCTAssertEqual(TimelineStore.monthNames(names), ["2026-10", "2026-01", "2025-11"])
    }

    // MARK: - 按天分组

    func testGroupByDayNewestFirstWithMidnightSpan() {
        let span = entry(date(2026, 10, 9, 23, 40), date(2026, 10, 10, 0, 30), "span")
        let morning = entry(date(2026, 10, 10, 9, 10), date(2026, 10, 10, 9, 40), "morning")
        let afternoon = entry(date(2026, 10, 10, 14, 20), date(2026, 10, 10, 15, 5), "afternoon")
        let older = entry(date(2026, 10, 8, 16, 0), date(2026, 10, 8, 16, 20), "older")

        let days = TimelineListLayout.groupByDay([morning, span, older, afternoon], calendar: cal)

        XCTAssertEqual(days.map(\.day), [date(2026, 10, 10, 0, 0), date(2026, 10, 9, 0, 0), date(2026, 10, 8, 0, 0)])
        XCTAssertEqual(days[0].entries.map(\.conversationId), ["afternoon", "morning"])
        XCTAssertEqual(days[1].entries.map(\.conversationId), ["span"], "跨天的归开始那天")
        XCTAssertEqual(days[2].entries.map(\.conversationId), ["older"])
    }

    /// v4-1：一天从 05:00 算——凌晨 03:00 那条归前一天；「今天」也按 05:00 算
    func testGroupByDayUsesFiveOClockBoundary() {
        let lateNight = entry(date(2026, 10, 11, 3, 0), date(2026, 10, 11, 4, 10), "lateNight")
        let evening = entry(date(2026, 10, 10, 21, 0), date(2026, 10, 10, 22, 0), "evening")
        let morning = entry(date(2026, 10, 11, 9, 0), date(2026, 10, 11, 9, 30), "morning")
        let days = TimelineListLayout.groupByDay([lateNight, evening, morning], calendar: cal)
        XCTAssertEqual(days.map(\.day), [date(2026, 10, 11, 0, 0), date(2026, 10, 10, 0, 0)])
        XCTAssertEqual(days[1].entries.map(\.conversationId), ["lateNight", "evening"], "04:59 以前归前一天")
        XCTAssertEqual(TimelineListLayout.dayTitle(date(2026, 10, 10, 0, 0), now: date(2026, 10, 11, 4, 0), calendar: cal),
                       "今天 · 10月10日", "凌晨 4 点还算前一天")
    }

    func testGroupByDayEmpty() {
        XCTAssertTrue(TimelineListLayout.groupByDay([], calendar: cal).isEmpty)
    }

    func testRangeText() {
        let now = date(2026, 10, 10, 20, 0)
        XCTAssertEqual(TimelineListLayout.rangeText(start: date(2026, 10, 10, 14, 20), end: date(2026, 10, 10, 15, 5), now: now, calendar: cal),
                       "14:20–15:05")
        XCTAssertEqual(TimelineListLayout.rangeText(start: date(2026, 10, 9, 23, 40), end: date(2026, 10, 10, 0, 30), now: now, calendar: cal),
                       "23:40 – 次日 00:30")
        XCTAssertEqual(TimelineListLayout.rangeText(start: date(2026, 10, 7, 23, 40), end: date(2026, 10, 9, 1, 0), now: now, calendar: cal),
                       "23:40 – 10月9日 01:00")
    }

    func testDayTitle() {
        let now = date(2026, 10, 10, 20, 0)
        XCTAssertEqual(TimelineListLayout.dayTitle(date(2026, 10, 10, 0, 0), now: now, calendar: cal), "今天 · 10月10日")
        XCTAssertEqual(TimelineListLayout.dayTitle(date(2026, 10, 9, 0, 0), now: now, calendar: cal), "昨天 · 10月9日")
        XCTAssertEqual(TimelineListLayout.dayTitle(date(2026, 10, 7, 0, 0), now: now, calendar: cal), "10月7日 周三")
        XCTAssertEqual(TimelineListLayout.dayTitle(date(2025, 3, 2, 0, 0), now: now, calendar: cal), "2025年3月2日 周日")
    }

    // MARK: - 待续 / 更早的月份

    func testPendingNoneHidden() {
        XCTAssertNil(TimelineListLayout.pendingText("无"))
        XCTAssertNil(TimelineListLayout.pendingText(" 无\n"))
        XCTAssertNil(TimelineListLayout.pendingText(""))
        XCTAssertNil(TimelineListLayout.pendingText("  \n "))
        XCTAssertEqual(TimelineListLayout.pendingText("周三复诊完要说结果\n"), "周三复诊完要说结果")
        XCTAssertEqual(TimelineListLayout.pendingText("无聊的事再说"), "无聊的事再说")
    }

    func testMonthTitle() {
        let now = date(2026, 10, 10, 20, 0)
        XCTAssertEqual(TimelineListLayout.monthTitle("2026-09", now: now, calendar: cal), "9月")
        XCTAssertEqual(TimelineListLayout.monthTitle("2025-12", now: now, calendar: cal), "2025年12月")
    }

    // MARK: - 返工 1：顶上常驻开关的副文案（照实际行为：关 = 不记新的、新窗口也不带；总开关关着时也停）
    func testSwitchNoteFollowsActualBehavior() {
        XCTAssertTrue(TimelineListLayout.switchNote(on: true, masterOn: true).hasPrefix("在记"))
        let paused = TimelineListLayout.switchNote(on: false, masterOn: true)
        XCTAssertTrue(paused.hasPrefix("暂停了"))
        XCTAssertTrue(paused.contains("已经记下的还在"))
        XCTAssertTrue(paused.contains("不会带上"))
        XCTAssertFalse(TimelineListLayout.switchNote(on: true, masterOn: true).contains("上下文摘要"), "v4-1：时间轴自己能写，不再说上下文摘要关着就记不进")
        XCTAssertTrue(TimelineListLayout.switchNote(on: true, masterOn: false).contains("总开关"))
        XCTAssertEqual(TimelineListLayout.switchNote(on: true, masterOn: false), TimelineListLayout.switchNote(on: false, masterOn: false))
    }

    // MARK: - 返工 1 · 8：「正在记」——收尾队列状态（巡检和界面同一份规则）+ 状态文案

    func testQueueStateNothingNewIsNone() {
        let now = date(2026, 10, 11, 12, 0)
        let upd = date(2026, 10, 11, 10, 0)
        // 最后一段写到更新那会儿（2 分钟余量内）→ 没新消息
        XCTAssertEqual(SessionCloseout.queueState(updateTime: upd, coveredUntil: upd.addingTimeInterval(-60),
                                                  lastMessageDate: upd, hasPending: true, now: now, force: false), .none)
        XCTAssertEqual(SessionCloseout.queueState(updateTime: upd, coveredUntil: nil, lastMessageDate: upd,
                                                  hasPending: false, now: now, force: false), .none)
        XCTAssertEqual(SessionCloseout.queueState(updateTime: upd, coveredUntil: nil, lastMessageDate: nil,
                                                  hasPending: true, now: now, force: false), .none)
    }

    func testQueueStateWaitsThirtyMinutesFromUpdate() {
        let upd = date(2026, 10, 11, 11, 50)
        let now = date(2026, 10, 11, 12, 0)
        XCTAssertEqual(SessionCloseout.queueState(updateTime: upd, coveredUntil: nil, lastMessageDate: upd.addingTimeInterval(-30),
                                                  hasPending: true, now: now, force: false),
                       .waiting(until: date(2026, 10, 11, 12, 20)))
        // 新建对话那次不等静默
        XCTAssertEqual(SessionCloseout.queueState(updateTime: upd, coveredUntil: nil, lastMessageDate: upd,
                                                  hasPending: true, now: now, force: true), .due)
        // 静默够了
        XCTAssertEqual(SessionCloseout.queueState(updateTime: upd, coveredUntil: date(2026, 10, 11, 9, 0), lastMessageDate: upd,
                                                  hasPending: true, now: date(2026, 10, 11, 12, 21), force: false), .due)
    }

    func testQueueStatusText() {
        let now = date(2026, 10, 11, 12, 0)
        XCTAssertEqual(TimelineListLayout.queueStatus(.due, running: true, now: now, calendar: cal), "正在整理…")
        XCTAssertEqual(TimelineListLayout.queueStatus(.waiting(until: date(2026, 10, 11, 12, 20)), running: false, now: now, calendar: cal),
                       "安静到 12:20 后记；开新窗口会马上记")
        // 过点了还没巡检 → 该记了
        XCTAssertTrue(TimelineListLayout.queueStatus(.waiting(until: date(2026, 10, 11, 11, 59)), running: false, now: now, calendar: cal)!
            .hasPrefix("该记了"))
        XCTAssertTrue(TimelineListLayout.queueStatus(.due, running: false, now: now, calendar: cal)!.hasPrefix("该记了"))
        XCTAssertNil(TimelineListLayout.queueStatus(.none, running: false, now: now, calendar: cal))
    }
}
