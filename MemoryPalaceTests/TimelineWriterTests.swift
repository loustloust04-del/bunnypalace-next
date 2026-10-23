import XCTest
@testable import 记忆花园

/// v4-1 §五：W3 拆两次调用——窗口总结整段重写最后那段；时间轴按天切、按键改写；格式检查
final class TimelineWriterTests: XCTestCase {

    let pid = "xctest-timeline-writer"
    private let speakers = SessionSegmentWriter.Speakers(userName: "粟粟", assistantName: "小克")

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private var dir: URL { TimelineStore.dir(profileId: pid) }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    private func msgs(_ dates: [Date]) -> [SessionSegmentWriter.Message] {
        dates.enumerated().map { .init(id: "n\($0.offset)", role: $0.offset % 2 == 0 ? "user" : "assistant", content: "第\($0.offset)条", date: $0.element) }
    }

    // MARK: - 格式检查

    func testParseAcceptsTopicsAndPending() {
        let r = TimelineWriter.parse("【话题】\n- 改了时间轴格式\n- 停在写单测\n【待续】\n- 跑金样")
        XCTAssertEqual(r.draft, .init(topics: ["改了时间轴格式", "停在写单测"], pending: ["跑金样"]))
        XCTAssertEqual(TimelineWriter.parse("【话题】\n- 一件事\n【待续】\n- 无").draft?.pending, [], "「无」= 没有待续")
    }

    func testParseRejectsRoleplayAndMissingParts() {
        XCTAssertNotNil(TimelineWriter.parse("（想了很久）……想到了").problem, "10-11 那条戏文：第一行不是【话题】")
        XCTAssertNotNil(TimelineWriter.parse("好的，我来记一下。\n【话题】\n- 一\n【待续】\n- 无").problem, "前面有开场白")
        XCTAssertNotNil(TimelineWriter.parse("【话题】\n聊了很多\n【待续】\n- 无").problem, "话题下面没有「- 」行")
        XCTAssertNotNil(TimelineWriter.parse("【话题】\n- 一").problem, "缺【待续】")
        XCTAssertNotNil(TimelineWriter.parse("【话题】\n- 用户说要复诊\n【待续】\n- 无").problem, "不能出现「用户」")
        XCTAssertNil(TimelineWriter.parse("【话题】\n- 粟粟说「我不是用户」\n【待续】\n- 无").problem, "引号里的原话不算")
    }

    func testSegmentFormatProblem() {
        XCTAssertNil(SessionSegmentWriter.formatProblem("标题：复诊\n【经过】说好周三去\n【原话】粟粟：「周三」"))
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("（想了很久）……想到了"))
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("这个窗口聊了复诊。\n标题：复诊\n【经过】说好\n【原话】粟粟：「周三」"), "【经过】前面有正文")
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("标题：复诊\n【经过】说好"), "缺【原话】")
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("【经过】说好\n【原话】粟粟：「周三」"), "缺标题")
        XCTAssertNotNil(SessionSegmentWriter.formatProblem("标题：复诊\n【经过】用户说好\n【原话】粟粟：「周三」"))
    }

    // MARK: - 写手：重写一次、还不对就抛

    func testRetriesOnceThenThrows() async throws {
        var calls = 0
        let bad: SessionSegmentWriter.Caller = { _, _ in calls += 1; return "（想了很久）……想到了" }
        let req = TimelineWriter.Request(day: "2026-10-11", windowTitle: "色色", existing: nil, previousPending: nil,
                                         messages: msgs([date(10, 11, 10)]), persona: "", speakers: speakers)
        do {
            _ = try await TimelineWriter.write(req, caller: bad)
            XCTFail("两次都不合格应该抛")
        } catch MemoryWriterError.format {}
        XCTAssertEqual(calls, 2)

        calls = 0
        let fixed: SessionSegmentWriter.Caller = { _, user in
            calls += 1
            return user.contains("提醒") ? "【话题】\n- 好了\n【待续】\n- 无" : "随便写写"
        }
        let draft = try await TimelineWriter.write(req, caller: fixed)
        XCTAssertEqual(draft?.topics, ["好了"])
        XCTAssertEqual(calls, 2)
    }

    // MARK: - 输入：已有那条 / 上一条待续（Q5）

    func testUserContentFeedsExistingOrPreviousPending() {
        let existing = TimelineEntry(start: date(10, 11, 9), end: date(10, 11, 10), conversationId: "c", title: "t",
                                     text: "- 上午的事", pending: "下午问结果", day: "2026-10-11", lastNodeId: "x")
        let withExisting = TimelineWriter.userContent(day: "2026-10-11", windowTitle: "t", existing: existing, previousPending: "旧待续",
                                                      messages: [], speakers: speakers)
        XCTAssertTrue(withExisting.contains("- 上午的事") && withExisting.contains("- 下午问结果"))
        XCTAssertFalse(withExisting.contains("旧待续"), "这一天已经有条目：不再喂上一条的待续")
        let fresh = TimelineWriter.userContent(day: "2026-10-12", windowTitle: "t", existing: nil, previousPending: "旧待续",
                                               messages: [], speakers: speakers)
        XCTAssertTrue(fresh.contains("这一天这个窗口还没记过") && fresh.contains("- 旧待续"))
    }

    func testSegmentUserContentFeedsFullPreviousWithoutPending() {
        let prev = SessionSegment(kind: .rolling, title: "复诊", start: date(10, 11, 9), end: date(10, 11, 10), from: 0, to: 2,
                                  lastNodeId: "n1", story: "说好周三去", quotes: "粟粟：「周三」", pending: "老待续")
        let text = SessionSegmentWriter.userContent(messages: [], speakers: speakers, previous: prev, kind: .rolling)
        XCTAssertTrue(text.contains("说好周三去") && text.contains("粟粟：「周三」"), "上一段全文进了输入")
        XCTAssertFalse(text.contains("老待续"), "待续没进")
        let sys = SessionSegmentWriter.systemPrompt(persona: "", speakers: speakers, kind: .rolling)
        XCTAssertTrue(sys.contains("不要用「这个窗口」开头"))
        XCTAssertFalse(sys.contains("【待续】"))
        let o = SessionSegmentWriter.parse("标题：复诊\n【经过】说好\n【原话】粟粟：「周三」\n【待续】周三问结果")
        XCTAssertEqual(o.quotes, "粟粟：「周三」", "输出里的【待续】被丢掉")
    }

    // MARK: - 时间轴按天切、按键改写

    func testWriteTimelineSplitsByDayAndRewritesSameKey() async throws {
        // 10-09 晚上两条 + 10-10 凌晨两条（归 10-09）+ 10-10 上午两条
        let m = msgs([date(10, 9, 22), date(10, 9, 23), date(10, 10, 1), date(10, 10, 2), date(10, 10, 9), date(10, 10, 10)])
        var seen: [String] = []
        let caller: SessionSegmentWriter.Caller = { _, user in
            seen.append(user)
            return "【话题】\n- 第\(seen.count)份\n【待续】\n- 待续\(seen.count)"
        }
        let n = try await SessionCloseout.writeTimeline(0..<4, messages: m, conversationId: "conv-k", title: "K",
                                                        persona: "", speakers: speakers, caller: caller, dir: dir)
        XCTAssertEqual(n, 1, "前四条都归 10-09，一份")
        let n2 = try await SessionCloseout.writeTimeline(4..<6, messages: m, conversationId: "conv-k", title: "K",
                                                         persona: "", speakers: speakers, caller: caller, dir: dir)
        XCTAssertEqual(n2, 1)
        XCTAssertTrue(seen[1].contains("这一天这个窗口还没记过") && seen[1].contains("- 待续1"), "新的一天喂上一条的待续")
        let entries = TimelineStore.entries(month: "2026-10", in: dir)
        XCTAssertEqual(entries.map(\.day), ["2026-10-09", "2026-10-10"])
        XCTAssertEqual(entries[0].start, date(10, 9, 22))
        XCTAssertEqual(entries[0].end, date(10, 10, 2), "日期、起止时间都来自那一天自己的消息")
        XCTAssertEqual(entries[0].lastNodeId, "n3")

        // 同一天再收尾一次：改写同一条，喂已有那条
        let more = m + msgs([date(10, 10, 11), date(10, 10, 12)]).map { .init(id: "x" + $0.id, role: $0.role, content: $0.content, date: $0.date) }
        _ = try await SessionCloseout.writeTimeline(6..<8, messages: more, conversationId: "conv-k", title: "K",
                                                    persona: "", speakers: speakers, caller: caller, dir: dir)
        XCTAssertTrue(seen[2].contains("这一天这个窗口已经记下的") && seen[2].contains("- 第2份"))
        let after = TimelineStore.entries(month: "2026-10", in: dir)
        XCTAssertEqual(after.count, 2, "同一天同一窗口只有一条")
        XCTAssertEqual(after[1].start, date(10, 10, 9), "开始时间留着那天最早的")
        XCTAssertEqual(after[1].lastNodeId, "xn1")
    }

    func testTimelineStartWatermarks() {
        let ids = (0..<10).map { "n\($0)" }
        let dates: [Date?] = (0..<10).map { date(10, 10, 8 + $0) }
        let v2 = TimelineEntry(start: dates[0]!, end: dates[4]!, conversationId: "c", title: "", text: "", pending: "", day: "2026-10-10", lastNodeId: "n4")
        XCTAssertEqual(SessionCloseout.timelineStart(pathIds: ids, dates: dates, latest: v2, legacyLast: "n7", notBefore: 0), 5, "v2 的 last 优先")
        var lost = v2; lost.lastNodeId = "gone"
        XCTAssertEqual(SessionCloseout.timelineStart(pathIds: ids, dates: dates, latest: lost, legacyLast: nil, notBefore: 0), 5, "找不到 id 按结束时间认")
        XCTAssertEqual(SessionCloseout.timelineStart(pathIds: ids, dates: dates, latest: nil, legacyLast: "n7", notBefore: 0), 8, "退回旧收尾段")
        XCTAssertEqual(SessionCloseout.timelineStart(pathIds: ids, dates: dates, latest: nil, legacyLast: nil, notBefore: 3), 3, "第一次补写，不早于起点")
        XCTAssertEqual(SessionCloseout.timelineStart(pathIds: ids, dates: dates, latest: v2, legacyLast: nil, notBefore: 7), 7)
    }

    // MARK: - 窗口总结：上下文摘要抄一份 + 最后那段

    func testComposeWindowSummaryCopiesContextAndRewritesTail() async throws {
        let m = msgs((0..<6).map { date(10, 11, 8 + $0) })
        let ctx = SessionSegment(kind: .rolling, title: "前面", start: date(10, 11, 8), end: date(10, 11, 9), from: 0, to: 2,
                                 lastNodeId: "n1", story: "前面的经过", quotes: "", pending: "")
        let oldTail = SessionSegment(kind: .closeout, title: "老收尾", start: date(10, 11, 10), end: date(10, 11, 11), from: 2, to: 4,
                                     lastNodeId: "n3", story: "老", quotes: "", pending: "仍未")
        let s = SessionSummary(conversationId: "c", title: "t", compressedCount: 2, segments: [ctx, oldTail], updatedAt: .distantPast)
        var asked = ""
        let w = try await SessionCloseout.composeWindowSummary(context: s, messages: m, title: "t", notBefore: 0, persona: "",
                                                               speakers: speakers) { _, user in
            asked = user
            return "标题：最后那截\n【经过】接着聊\n【原话】粟粟：「嗯」"
        }
        XCTAssertEqual(w?.segments.map(\.title), ["前面", "最后那截"], "老收尾段不抄，最后那段整段重写")
        XCTAssertEqual(w?.segments.last?.from, 2, "从上下文摘要水位线之后写")
        XCTAssertEqual(w?.closedThrough, "n5")
        XCTAssertTrue(asked.contains("前面的经过"), "喂上下文摘要最后一段全文")
        XCTAssertEqual(SessionCloseout.windowTailStart(context: [], pathIds: (0..<200).map { "n\($0)" }, notBefore: 0), 50, "最多 150 条")
    }
}
