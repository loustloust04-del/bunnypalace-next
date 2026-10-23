import XCTest
import SwiftData
@testable import 记忆花园

/// v4-1 §七 / Q12：recall 只给 conversation_id → 窗口总结（读 windows/，没有退回 sessions/）+ 时间轴这个窗口最新一条的待续
final class RecallWindowSummaryTests: XCTestCase {

    let pid = "xctest-recall-window"
    var container: ModelContainer!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        context.insert(MessageNode(id: "w-n0", role: "user", content: "随便聊聊", contentType: "text", createTime: t, parentId: nil,
                                   childrenIds: [], conversationId: "conv-wwww-0001", profileId: pid))
        context.insert(Conversation(id: "conv-wwww-0001", title: "色色", createTime: t, updateTime: t, currentNodeId: "w-n0", profileId: pid))
        try! context.save()
    }

    override func tearDown() {
        container = nil
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func run() async -> RecallTool.ExecResult {
        await RecallTool.execute(inputJSON: #"{"conversation_id":"conv-wwww-0001"}"#, profileId: pid, currentConversationId: nil,
                                 userName: "粟粟", assistantName: "小克", container: container)
    }

    private func seg(_ kind: SessionSegment.Kind, _ title: String) -> SessionSegment {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        return SessionSegment(kind: kind, title: title, start: d, end: d.addingTimeInterval(60), from: 0, to: 1, lastNodeId: "w-n0",
                              story: "\(title)的经过", quotes: "", pending: "")
    }

    func testReturnsWindowSummaryWithLatestTimelinePending() async throws {
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        try SessionSummaryStore.save(SessionSummary(conversationId: "conv-wwww-0001", title: "色色", compressedCount: 0,
                                                    segments: [seg(.rolling, "上下文摘要那段")], updatedAt: Date()), profileId: pid)
        var r = await run()
        XCTAssertTrue(r.text.contains("上下文摘要那段的经过"), "没有 windows/ 退回 sessions/：\(r.text)")

        try WindowSummaryStore.save(SessionSummary(conversationId: "conv-wwww-0001", title: "色色", compressedCount: 0,
                                                   segments: [seg(.rolling, "上下文摘要那段"), seg(.closeout, "最后那截")], updatedAt: Date(),
                                                   closedThrough: "w-n0"), in: root)
        try TimelineStore.upsert(TimelineEntry(start: Date(), end: Date(), conversationId: "conv-wwww-0001", title: "色色", text: "- 一件事",
                                               pending: "周末问猫粮\n下次接着写", day: "2026-10-11", lastNodeId: "w-n0"),
                                 in: TimelineStore.dir(root: root))
        r = await run()
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("最后那截的经过"), r.text)
        XCTAssertTrue(r.text.contains("- 周末问猫粮") && r.text.contains("- 下次接着写"), "带上时间轴最新一条的待续：\(r.text)")
    }

    func testNothingYetSaysSo() async {
        let r = await run()
        XCTAssertTrue(r.text.contains("还没有窗口总结"), r.text)
    }
}
