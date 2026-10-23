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

    func testWindowSummaryPrefersWindowsThenFallsBackToSessions() throws {
        try SessionSummaryStore.save(summary("conv-a-0001", [seg("压缩一", .rolling, at: 0), seg("老收尾", .closeout, at: 600)]), profileId: pid)
        // 还没有 windows/：退回把 sessions/ 整份当窗口总结
        XCTAssertEqual(WindowSummaryReader.load(conversationId: "conv-a-0001", profileId: pid)?.segments.map(\.title), ["压缩一", "老收尾"])
        try WindowSummaryStore.save(summary("conv-a-0001", [seg("压缩一", .rolling, at: 0), seg("新最后一段", .closeout, at: 900)], closed: "x"),
                                    in: root)
        XCTAssertEqual(WindowSummaryReader.load(conversationId: "conv-a-0001", profileId: pid)?.segments.map(\.title), ["压缩一", "新最后一段"])
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-a-0001", profileId: pid)?.closedThrough, "x")
    }

    func testContextSheetReadsSessionsWithoutCloseout() throws {
        try SessionSummaryStore.save(summary("conv-b-0001", [seg("老", .legacy, at: 0), seg("压缩", .rolling, at: 600), seg("老收尾", .closeout, at: 1200)]),
                                     profileId: pid)
        try WindowSummaryStore.save(summary("conv-b-0001", [seg("窗口总结那份", .closeout, at: 0)]), in: root)
        XCTAssertEqual(WindowSummaryReader.loadContext(conversationId: "conv-b-0001", profileId: pid)?.segments.map(\.title), ["老", "压缩"],
                       "上下文摘要弹层只读 sessions/，不看 windows/，老收尾段不算")
    }

    func testListMergesWindowsFirstThenSessionsOnly() throws {
        try SessionSummaryStore.save(summary("conv-c-0001", [seg("c 压缩", .rolling, at: 0)]), profileId: pid)
        try SessionSummaryStore.save(summary("conv-d-0001", [seg("d 压缩", .rolling, at: 0)]), profileId: pid)
        try WindowSummaryStore.save(summary("conv-c-0001", [seg("c 压缩", .rolling, at: 0), seg("c 最后", .closeout, at: 60)]), in: root)
        let list = WindowSummaryReader.listAll(profileId: pid)
        XCTAssertEqual(Set(list.map(\.conversationId)), ["conv-c-0001", "conv-d-0001"])
        XCTAssertEqual(list.first { $0.conversationId == "conv-c-0001" }?.segments.count, 2, "同一个窗口 windows/ 优先")
    }

    func testFileLibraryNames() {
        XCTAssertEqual(MemoryTreeGroup.titles["sessions"], "上下文摘要")
        XCTAssertEqual(MemoryTreeGroup.titles["windows"], "窗口总结")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/windows", assistantName: "x"), "窗口总结")
    }
}
