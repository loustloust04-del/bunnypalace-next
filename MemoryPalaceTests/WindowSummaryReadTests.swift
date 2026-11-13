import MemoryCore
import XCTest
@testable import 记忆花园

/// v4-1 §三：上下文摘要（sessions/）和窗口总结（windows/）拆开存；读侧三处改读法 + 退回规则
final class WindowSummaryReadTests: XCTestCase {

    let pid = "xctest-window-read"
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private var root: URL { FileLibraryStore.memoryRoot(profileId: pid) }

    private func seg(_ title: String, _ kind: SessionSegment.Kind, at offset: TimeInterval) -> SessionSegment {
        let start = t0.addingTimeInterval(offset)
        return SessionSegment(kind: kind, title: title, start: start, end: start.addingTimeInterval(600), from: 0, to: 0,
                              lastNodeId: "n\(Int(offset))", story: "经过\(title)", quotes: "", pending: "")
    }

    private func summary(_ cid: String, _ segs: [SessionSegment], closed: String? = nil) -> SessionSummary {
        SessionSummary(conversationId: cid, title: "窗\(cid)", compressedCount: 0, segments: segs, updatedAt: t0, closedThrough: closed)
    }

    func testClosedThroughRoundTripAndOnlyInWindowsFile() throws {
        let w = summary("conv-w-0001", [seg("压缩", .rolling, at: 0), seg("最后", .closeout, at: 600)], closed: "n-last")
        XCTAssertEqual(SessionSummaryStore.parse(SessionSummaryStore.render(w)), w)
        XCTAssertFalse(SessionSummaryStore.render(summary("c", [])).contains("closedThrough"), "sessions/ 文件格式不变")
    }

    private func tail(_ title: String, at offset: TimeInterval) -> SessionSegment {
        var t = seg(title, .closeout, at: offset)
        t.isTail = true
        return t
    }

    private func oneSeg(_ title: String, from: Int) -> SessionSegment {
        var s = seg(title, .closeout, at: 0)
        s.from = from
        return s
    }

    /// 三代搬迁 W1：一个窗口 = A3（windows/ 一段从头压的才算）+ A2（第 0 段 / 正式段 / 尾段）+ 老收尾段（灰字一组）
    func testDocSplitsA3AndA2AcrossThreeGenerations() throws {
        // 第三代：A3 一段 from=0；A2 正式段 + 尾段
        try SessionSummaryStore.save(summary("conv-v5-0001", [seg("压缩", .rolling, at: 0), tail("尾", at: 600)]), memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        try WindowSummaryStore.save(summary("conv-v5-0001", [oneSeg("整窗", from: 0)], closed: "x"), in: root)
        let v5 = try XCTUnwrap(WindowSummaryReader.load(conversationId: "conv-v5-0001", profileId: pid))
        XCTAssertEqual(v5.a3?.title, "整窗")
        XCTAssertEqual(v5.a2.map(\.title), ["压缩", "尾"])
        XCTAssertEqual(v5.oldCloseouts, [])
        // 第二代：v4-1 抄本（多段）当「还没压」；A2 里起点以前的老收尾段单独一组
        try SessionSummaryStore.save(summary("conv-v41-001", [seg("老收尾", .closeout, at: 0), seg("压缩", .rolling, at: 600)]), memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        try WindowSummaryStore.save(summary("conv-v41-001", [seg("压缩", .rolling, at: 600), seg("最后那截", .closeout, at: 1200)], closed: "y"),
                                    in: root)
        let v41 = try XCTUnwrap(WindowSummaryReader.load(conversationId: "conv-v41-001", profileId: pid))
        XCTAssertNil(v41.a3, "v4-1 抄本 = 还没压成窗口总结")
        XCTAssertEqual(v41.a2.map(\.title), ["压缩"])
        XCTAssertEqual(v41.oldCloseouts.map(\.title), ["老收尾"])
        XCTAssertNil(WindowSummaryReader.a3(summary("c", [oneSeg("只有最后那截", from: 40)])), "一段但 from > 0 也是抄本")
        // 第一代：只有 summaries/ → 第 0 段，还没有 A3
        SummaryFileStore.save(ContextSummary(summary: "第一代老摘要", coveredCount: 12, updatedAt: t0), conversationId: "conv-g1-0001",
                              memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "老")
        let g1 = try XCTUnwrap(WindowSummaryReader.load(conversationId: "conv-g1-0001", profileId: pid))
        XCTAssertNil(g1.a3)
        XCTAssertEqual(g1.a2.map(\.kind), [.legacy])
        XCTAssertEqual(g1.a2.first?.story, "第一代老摘要")
    }

    /// astra #13：只有 windows/ 旧抄本（认不成 A3）、没有 sessions/ 的窗口 → 详情页灰字一组「旧窗口总结」，不当空的
    func testOldWindowsCopyWithoutSessionsStillShows() throws {
        try WindowSummaryStore.save(summary("conv-w41-only", [seg("压缩", .rolling, at: 0), seg("最后那截", .closeout, at: 600)], closed: "z"),
                                    in: root)
        let doc = try XCTUnwrap(WindowSummaryReader.load(conversationId: "conv-w41-only", profileId: pid))
        XCTAssertFalse(doc.isEmpty)
        XCTAssertNil(doc.a3)
        XCTAssertEqual(doc.a2, [])
        XCTAssertEqual(doc.oldWindow.map(\.title), ["压缩", "最后那截"])
        // 认得成 A3 的不放进旧的那组
        try WindowSummaryStore.save(summary("conv-v5-only", [oneSeg("整窗", from: 0)], closed: "z"), in: root)
        XCTAssertEqual(WindowSummaryReader.load(conversationId: "conv-v5-only", profileId: pid)?.oldWindow, [])
    }

    /// W4：对话 ⋯「上下文摘要」显示尾段，老收尾段仍不显示，不看 windows/
    func testContextSheetShowsTailButNotOldCloseout() throws {
        try SessionSummaryStore.save(summary("conv-b-0001", [seg("老", .legacy, at: 0), seg("压缩", .rolling, at: 600), seg("老收尾", .closeout, at: 1200),
                                                             tail("尾", at: 1800)]), memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        try WindowSummaryStore.save(summary("conv-b-0001", [seg("窗口总结那份", .closeout, at: 0)]), in: root)
        let doc = WindowSummaryReader.loadContext(conversationId: "conv-b-0001", profileId: pid)
        XCTAssertEqual(doc?.a2.map(\.title), ["老", "压缩", "尾"])
        XCTAssertEqual(doc?.a2.last?.isTail, true)
    }

    /// W2：列表合 windows/ + sessions/，一个窗口一行；「记了 N 段」= A2 段数（第 0 段 + 正式段 + 尾段，老收尾段不算）
    func testListRowsCountA2Segments() {
        let windows = [summary("conv-c-0001", [oneSeg("c 整窗", from: 0)]), summary("conv-e-0001", [oneSeg("只有 A3", from: 0)])]
        let sessions = [summary("conv-c-0001", [seg("老", .legacy, at: 0), seg("c 压缩", .rolling, at: 60), seg("老收尾", .closeout, at: 120),
                                                tail("尾", at: 180)]),
                        summary("conv-d-0001", [seg("d 压缩", .rolling, at: 0)]),
                        summary("conv-f-0001", [])]
        let rows = WindowSummaryListLayout.rows(windows: windows, sessions: sessions, aliveTitles: [:])
        XCTAssertEqual(Set(rows.map(\.conversationId)), ["conv-c-0001", "conv-d-0001", "conv-e-0001"], "一段都没有的不出")
        let count = Dictionary(uniqueKeysWithValues: rows.map { ($0.conversationId, $0.segmentCount) })
        XCTAssertEqual(count, ["conv-c-0001": 3, "conv-d-0001": 1, "conv-e-0001": 0])
    }

    func testFileLibraryNames() {
        XCTAssertEqual(MemoryTreeGroup.titles["sessions"], "上下文摘要")
        XCTAssertEqual(MemoryTreeGroup.titles["windows"], "窗口总结")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/windows", assistantName: "x"), "窗口总结")
    }
}
