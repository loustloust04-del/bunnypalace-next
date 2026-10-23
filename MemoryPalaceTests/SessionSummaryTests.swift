import XCTest
@testable import 记忆花园

/// 第三刀：窗口摘要分段追加 / 三层 / 水位线 / 收尾切段 / 跨窗口时间轴（plan-memory-fix-3）
final class SessionSummaryTests: XCTestCase {

    let pid = "xctest-session-summary"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func seg(_ title: String, kind: SessionSegment.Kind = .rolling, from: Int, to: Int, last: String? = nil,
                     start: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> SessionSegment {
        SessionSegment(kind: kind, title: title, start: start, end: start.addingTimeInterval(600), from: from, to: to,
                       lastNodeId: last, story: "经过\(title)", quotes: "粟粟：「原话\(title)」", pending: "待续\(title)")
    }

    // MARK: - 存储

    func testRenderParseRoundTripKeepsSegmentsInOrder() {
        let s = SessionSummary(conversationId: "conv-abcdef123", title: "复诊那件事", compressedCount: 40,
                               segments: [seg("一", from: 0, to: 20, last: "n20"), seg("二", kind: .closeout, from: 20, to: 40, last: "n40")],
                               updatedAt: Date(timeIntervalSince1970: 1_790_001_000))
        let back = SessionSummaryStore.parse(SessionSummaryStore.render(s))
        XCTAssertEqual(back, s)
    }

    func testSaveAppendDoesNotTouchOldSegments() throws {
        var s = SessionSummaryStore.loadOrSeed(conversationId: "conv-append-1", profileId: pid, title: "标题")
        s.segments.append(seg("一", from: 0, to: 10, last: "n10"))
        try SessionSummaryStore.save(s, profileId: pid)
        var again = try XCTUnwrap(SessionSummaryStore.load(conversationId: "conv-append-1", profileId: pid))
        again.segments.append(seg("二", from: 10, to: 20, last: "n20"))
        try SessionSummaryStore.save(again, profileId: pid)
        let final = try XCTUnwrap(SessionSummaryStore.load(conversationId: "conv-append-1", profileId: pid))
        XCTAssertEqual(final.segments.map(\.title), ["一", "二"])
        XCTAssertEqual(final.segments[0], s.segments[0])
    }

    func testLegacySummaryBecomesSegmentZero() {
        SummaryFileStore.save(ContextSummary(summary: "老的累计摘要", coveredCount: 30, updatedAt: Date()),
                              conversationId: "conv-legacy-1", profileId: pid, conversationTitle: "老对话")
        let s = SessionSummaryStore.loadOrSeed(conversationId: "conv-legacy-1", profileId: pid, title: "老对话")
        XCTAssertEqual(s.compressedCount, 30)
        XCTAssertEqual(s.segments.count, 1)
        XCTAssertEqual(s.segments[0].kind, .legacy)
        XCTAssertEqual(s.segments[0].story, "老的累计摘要")
        XCTAssertNotNil(SummaryFileStore.load(conversationId: "conv-legacy-1", profileId: pid), "老文件不动")
    }

    // MARK: - 水位线

    func testResumeIndexPrefersNodeIdThenFallsBackToCount() {
        let s = SessionSummary(conversationId: "c", title: "", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 3, last: "b")], updatedAt: Date())
        XCTAssertEqual(SessionSummaryStore.resumeIndex(s, pathIds: ["a", "b", "c", "d"]), 2, "按 id 找到 b，从它后面接")
        XCTAssertEqual(SessionSummaryStore.resumeIndex(s, pathIds: ["x", "y", "z", "w"]), 3, "id 找不到（切过分支）退回下标")
        XCTAssertEqual(SessionSummaryStore.resumeIndex(s, pathIds: ["x"]), 1, "夹在路径长度内")
    }

    func testPendingRangeNoDuplicateNoGapAndFirstCloseoutCap() {
        let ids = (0..<200).map { "n\($0)" }
        let empty = SessionSummary(conversationId: "c", title: "", compressedCount: 0, segments: [], updatedAt: Date())
        XCTAssertEqual(SessionCloseout.pendingRanges(empty, pathIds: ids, dates: []), [50..<200], "一段都没有：最多从倒数 150 条开始")
        let done = SessionSummary(conversationId: "c", title: "", compressedCount: 0,
                                  segments: [seg("一", from: 50, to: 200, last: "n199")], updatedAt: Date())
        XCTAssertEqual(SessionCloseout.pendingRanges(done, pathIds: ids, dates: []), [], "总结到最后一条了，不重复写")
        XCTAssertEqual(SessionCloseout.pendingRanges(done, pathIds: ids + ["n200", "n201"], dates: []), [200..<202], "接着聊了：只写新的")
    }

    func testChunksSplitLongTail() {
        XCTAssertEqual(SessionCloseout.chunks(0..<130, size: 60), [0..<60, 60..<120, 120..<130])
        XCTAssertEqual(SessionCloseout.chunks(5..<9, size: 60), [5..<9])
    }

    // MARK: - 注入

    func testInjectionFullRecentSegmentsAndTitlesForOlder() throws {
        let s = SessionSummary(conversationId: "conv-abcdef123", title: "t", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 1), seg("二", from: 1, to: 2), seg("三", from: 2, to: 3)],
                               updatedAt: Date())
        let text = try XCTUnwrap(SessionSummaryStore.injectionText(s, fullCount: 2))
        XCTAssertTrue(text.contains("· 一"))
        XCTAssertFalse(text.contains("经过一"), "更早的只放标题")
        XCTAssertTrue(text.contains("经过二") && text.contains("经过三"))
        XCTAssertTrue(text.contains("【待续】待续三"))
        XCTAssertTrue(text.contains("conversation_id=conv-abc"))
    }

    // MARK: - 写手

    func testTranscriptUsesFloorNamesNotUserAI() {
        let msgs = [SessionSegmentWriter.Message(id: "1", role: "user", content: "下周三复诊", date: nil),
                    SessionSegmentWriter.Message(id: "2", role: "assistant", content: "记住了", date: nil)]
        let t = SessionSegmentWriter.transcript(msgs, speakers: .init(userName: "粟粟", assistantName: "小克"))
        XCTAssertEqual(t, "粟粟：下周三复诊\n\n小克：记住了")
        let sys = SessionSegmentWriter.systemPrompt(persona: "你是小克。", speakers: .init(userName: "粟粟", assistantName: "小克"), kind: .rolling)
        XCTAssertTrue(sys.hasPrefix("你是小克。"))
        XCTAssertTrue(sys.contains("【经过】") && sys.contains("【原话】"))
        XCTAssertFalse(sys.contains("【待续】") || sys.contains("【时间轴】"), "v4-1：上下文摘要不写待续")
        XCTAssertTrue(sys.contains("接着上一段写") && sys.contains("不要用「这个窗口」开头"))
        XCTAssertTrue(SessionSegmentWriter.systemPrompt(persona: "", speakers: .init(userName: "", assistantName: ""), kind: .closeout).contains("窗口总结"))
    }

    /// v4-1 §四：上一段全文进输入、待续不进
    func testUserContentFeedsPreviousFullTextWithoutPending() {
        let prev = seg("一", from: 0, to: 10, last: "n9")
        let text = SessionSegmentWriter.userContent(messages: [], speakers: .init(userName: "粟粟", assistantName: "小克"), previous: prev, kind: .rolling)
        XCTAssertTrue(text.contains("经过一") && text.contains("粟粟：「原话一」"))
        XCTAssertFalse(text.contains("待续一"))
    }

    /// 格式两次都不合格：不存、抛格式错；第一次不合格带提醒重写
    func testWriterRetriesOnceThenThrowsFormat() async throws {
        let req = SessionSegmentWriter.Request(
            messages: [.init(id: "1", role: "user", content: "嗯", date: Date())], kind: .rolling, from: 0, persona: "",
            speakers: .init(userName: "粟粟", assistantName: "小克"), previous: nil)
        var calls = 0
        do {
            _ = try await SessionSegmentWriter.write(req) { _, _ in calls += 1; return "（想了很久）……想到了" }
            XCTFail("应该抛")
        } catch MemoryWriterError.format {}
        XCTAssertEqual(calls, 2)
        let ok = try await SessionSegmentWriter.write(req) { _, user in
            user.contains("提醒") ? "标题：好了\n【经过】接着聊\n【原话】粟粟：「嗯」\n【待续】不该留下" : "这个窗口聊了很多"
        }
        XCTAssertEqual(ok?.title, "好了")
        XCTAssertEqual(ok?.pending, "", "输出里的【待续】被丢掉")
    }

    func testParseOutputAndForbiddenAddress() {
        let raw = """
        标题：复诊安排
        【经过】粟粟说下周三复诊，我记下了。
        【原话】粟粟：「记住我下周三要去复诊」
        我：「记住了」
        【待续】周三问结果
        【时间轴】聊了复诊安排，约好周三问结果。
        """
        let o = SessionSegmentWriter.parse(raw)
        XCTAssertEqual(o.title, "复诊安排")
        XCTAssertEqual(o.story, "粟粟说下周三复诊，我记下了。")
        XCTAssertEqual(o.quotes, "粟粟：「记住我下周三要去复诊」\n我：「记住了」")
        XCTAssertFalse(o.quotes.contains("周三问结果") || o.quotes.contains("时间轴"), "多写的【待续】【时间轴】丢掉")
        XCTAssertFalse(SessionSegmentWriter.hasForbiddenAddress(o))
        XCTAssertNil(SessionSegmentWriter.formatProblem(raw))

        var bad = o
        bad.story = "用户说要复诊"
        XCTAssertTrue(SessionSegmentWriter.hasForbiddenAddress(bad))
        var quoted = o
        quoted.story = "她说「我不是用户」"
        XCTAssertFalse(SessionSegmentWriter.hasForbiddenAddress(quoted), "引号里的原话不算")
    }

    // MARK: - 时间轴

    func testTimelineAppendSortsByTimeAcrossConversations() throws {
        let base = Date()
        try TimelineStore.append(TimelineEntry(start: base.addingTimeInterval(-3600), end: base.addingTimeInterval(-3000),
                                               conversationId: "conv-b-000000", title: "B", text: "聊了 B", pending: "无"), profileId: pid)
        try TimelineStore.append(TimelineEntry(start: base.addingTimeInterval(-7200), end: base.addingTimeInterval(-6600),
                                               conversationId: "conv-a-000000", title: "A", text: "聊了 A", pending: "周三问结果"), profileId: pid)
        let recent = TimelineStore.recent(profileId: pid, now: base, count: 8, days: 7)
        XCTAssertEqual(recent.map(\.title), ["A", "B"], "按时间排，不按写入顺序")
        XCTAssertEqual(recent.first?.pending, "周三问结果")
        let text = try XCTUnwrap(TimelineStore.injectionText(recent))
        XCTAssertTrue(text.contains("conv conv-a-0") && text.contains("待续：周三问结果"))
    }

    func testTimelineSelectHonorsCountAndDays() {
        let now = Date()
        let entries = (0..<12).map { i in
            TimelineEntry(start: now.addingTimeInterval(Double(-i) * 86400), end: now.addingTimeInterval(Double(-i) * 86400 + 60),
                          conversationId: "c\(i)", title: "\(i)", text: "", pending: "")
        }
        XCTAssertEqual(TimelineStore.select(entries, now: now, count: 8, days: 7).map(\.title), ["7", "6", "5", "4", "3", "2", "1", "0"],
                       "7 天前那条还在窗口里（按结束时间算），8 天前的不要")
        XCTAssertEqual(TimelineStore.select(entries, now: now, count: 8, days: 3).map(\.title), ["3", "2", "1", "0"])
        XCTAssertEqual(TimelineStore.select(entries, now: now, count: 3, days: 30).map(\.title), ["2", "1", "0"])
    }
}
