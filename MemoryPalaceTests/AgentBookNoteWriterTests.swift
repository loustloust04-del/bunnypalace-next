import XCTest
import SwiftData
@testable import 记忆花园

/// CR-4 P3：AI 读书产物落地——anchor 唯一命中/幂等/回批注挂串。
final class AgentBookNoteWriterTests: XCTestCase {
    static let pid = "xctest-cr4-writer"
    static let book = "tbook"

    var container: ModelContainer!
    var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Conversation.self, MessageNode.self, configurations: config)
        context = ModelContext(container)

        // 书：index + 第 1 章文本
        let idx = BookStore.BookIndex(
            name: "测试书", author: "", format: "txt",
            createdAt: Date(), updatedAt: Date(),
            currentChapter: 1, scrollRatio: 0, totalChapters: 1,
            chapters: [.init(no: 1, title: "第一章", chars: 20)]
        )
        try! BookStore.saveIndex(idx, safeName: Self.book, profileId: Self.pid)
        try! BookStore.saveChapterText("她走进花园，看见薄荷色的光。", safeName: Self.book, chapterNo: 1, profileId: Self.pid)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: BookStore.booksRoot(profileId: Self.pid).deletingLastPathComponent())
        container = nil
        super.tearDown()
    }

    private func payload(notes: [[String: Any]], message: String = "") -> [String: Any] {
        [
            "uuid": UUID().uuidString, "floorId": Self.pid, "safeName": Self.book,
            "bookName": "测试书", "chapter": 1, "notes": notes, "message": message,
        ]
    }

    func testUniqueRangeSemantics() {
        XCTAssertEqual(AgentBookNoteWriter.uniqueRange(of: "薄荷色", in: "第一章她看见薄荷色的光"), 6..<9)
        XCTAssertNil(AgentBookNoteWriter.uniqueRange(of: "aa", in: "aaa"), "多命中 → nil")
        XCTAssertNil(AgentBookNoteWriter.uniqueRange(of: "不存在", in: "abc"), "零命中 → nil")
    }

    func testHandleWritesLocatedNoteAndDropsHallucinated() {
        let ok = AgentBookNoteWriter.handle(payload(notes: [
            ["anchorText": "看见薄荷色的光", "comment": "这句像你"],
            ["anchorText": "原文里根本没有这句", "comment": "幻觉引用"],
        ]), context: context)
        XCTAssertTrue(ok)
        let notes = BookStore.loadNotes(safeName: Self.book, profileId: Self.pid)
        XCTAssertEqual(notes.count, 1, "幻觉引用被丢弃")
        XCTAssertEqual(notes[0].role, "ai")
        XCTAssertEqual(notes[0].content, "这句像你")
        XCTAssertGreaterThan(notes[0].anchorStart, 0, "offset 含 title 域")
    }

    func testHandleIsIdempotent() {
        let p = payload(notes: [["anchorText": "看见薄荷色的光", "comment": "重复投递"]])
        _ = AgentBookNoteWriter.handle(p, context: context)
        _ = AgentBookNoteWriter.handle(p, context: context)
        XCTAssertEqual(BookStore.loadNotes(safeName: Self.book, profileId: Self.pid).count, 1)
    }

    func testReplyToAnchorThreadsOntoHerNote() {
        // 她先有一条批注
        var all = BookStore.loadNotes(safeName: Self.book, profileId: Self.pid)
        all.append(BookStore.Note(
            id: "hers", chapter: 1, anchorText: "她走进花园", anchorStart: 3, anchorEnd: 8,
            kind: "note", content: "想进这个花园", role: "user", messageId: nil, createdAt: Date()
        ))
        try! BookStore.saveNotes(all, safeName: Self.book, profileId: Self.pid)

        _ = AgentBookNoteWriter.handle(payload(notes: [
            ["anchorText": "看见薄荷色的光", "comment": "陪你进", "replyToAnchor": "她走进花园"],
        ]), context: context)

        let notes = BookStore.loadNotes(safeName: Self.book, profileId: Self.pid)
        let aiNote = notes.first { $0.role == "ai" }
        XCTAssertEqual(aiNote?.replyTo, "hers", "回批注挂到她的卡下")
    }

    func testMissingBookReturnsFalseForRetry() {
        var p = payload(notes: [["anchorText": "看见薄荷色的光", "comment": "c"]])
        p["safeName"] = "no-such-book"
        XCTAssertFalse(AgentBookNoteWriter.handle(p, context: context), "书不存在不 ack，等补投")
    }

    // MARK: - R2 聊天内批注意向

    private func makeAssistantNode(content: String) -> String {
        let node = MessageNode(
            id: UUID().uuidString, role: "assistant", content: content, contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: "c1",
            profileId: Self.pid
        )
        context.insert(node)
        try! context.save()
        return node.id
    }

    func testChatIntentLandsNoteAndReplacesBlock() throws {
        let content = """
        这一段真好。
        ```book-note
        {"book": "\(Self.book)", "chapter": 1, "anchorText": "看见薄荷色的光", "comment": "聊天里留的"}
        ```
        我们聊聊？
        """
        let nodeId = makeAssistantNode(content: content)
        AgentBookNoteWriter.processChatIntents(nodeId: nodeId, context: context)

        let notes = BookStore.loadNotes(safeName: Self.book, profileId: Self.pid)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].content, "聊天里留的")

        let desc = FetchDescriptor<MessageNode>()
        let node = (try! context.fetch(desc)).first!
        XCTAssertFalse(node.content.contains("```book-note"), "块被替换")
        XCTAssertTrue(node.content.contains("已在《测试书》第 1 章留下批注"))
        XCTAssertTrue(node.content.contains("我们聊聊？"), "其余内容保留")

        // 幂等：再跑一次无操作
        AgentBookNoteWriter.processChatIntents(nodeId: nodeId, context: context)
        XCTAssertEqual(BookStore.loadNotes(safeName: Self.book, profileId: Self.pid).count, 1)
    }

    func testChatIntentHallucinatedAnchorReportsFailure() {
        let content = """
        ```book-note
        {"book": "\(Self.book)", "chapter": 1, "anchorText": "原文里没有这句引用", "comment": "c"}
        ```
        """
        let nodeId = makeAssistantNode(content: content)
        AgentBookNoteWriter.processChatIntents(nodeId: nodeId, context: context)

        XCTAssertTrue(BookStore.loadNotes(safeName: Self.book, profileId: Self.pid).isEmpty)
        let node = (try! context.fetch(FetchDescriptor<MessageNode>())).first!
        XCTAssertTrue(node.content.contains("批注未落地"), "定位失败可见反馈")
    }
}
