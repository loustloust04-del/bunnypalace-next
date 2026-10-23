import XCTest
import SwiftData
@testable import 记忆花园

/// CR-1 T1：aiBubble 回填。notes.json 用 xctest 专用 profileId 落真实目录，tearDown 清理。
final class BookNoteBackfillTests: XCTestCase {
    static let pid = "xctest-cr1-backfill"
    static let book = "testbook"

    var container: ModelContainer!
    var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: MessageNode.self, configurations: config)
        context = ModelContext(container)
    }

    override func tearDown() {
        let root = BookStore.booksRoot(profileId: Self.pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
        container = nil
        super.tearDown()
    }

    private func makeTurn(userBookRef: String?, assistantContent: String) -> (userId: String, assistantId: String) {
        let user = MessageNode(
            id: "u1", role: "user", content: "（在书里读到）你怎么看？", contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: ["a1"], conversationId: "c1",
            profileId: Self.pid
        )
        user.bookRef = userBookRef
        let assistant = MessageNode(
            id: "a1", role: "assistant", content: assistantContent, contentType: "text",
            createTime: Date(), parentId: "u1", childrenIds: [], conversationId: "c1",
            profileId: Self.pid
        )
        context.insert(user)
        context.insert(assistant)
        try! context.save()
        return ("u1", "a1")
    }

    private func seedPlaceholderNote(messageId: String) {
        let note = BookStore.Note(
            id: "n1", chapter: 3, anchorText: "选段", anchorStart: 10, anchorEnd: 12,
            kind: "aiBubble", content: "（助手正在回答…）", role: "ai",
            messageId: messageId, createdAt: Date()
        )
        try! BookStore.saveNotes([note], safeName: Self.book, profileId: Self.pid)
    }

    func testFillWritesAnswerIntoPlaceholder() {
        let ids = makeTurn(userBookRef: "\(Self.book)#chapter3", assistantContent: "这段写的是孤独。")
        seedPlaceholderNote(messageId: ids.userId)

        BookNoteBackfill.fill(nodeId: ids.assistantId, conversationId: "c1", context: context)

        let notes = BookStore.loadNotes(safeName: Self.book, profileId: Self.pid)
        XCTAssertEqual(notes.first?.content, "这段写的是孤独。")
    }

    func testFillIgnoresNonBookTurn() {
        let ids = makeTurn(userBookRef: nil, assistantContent: "普通聊天回答")
        seedPlaceholderNote(messageId: ids.userId)

        BookNoteBackfill.fill(nodeId: ids.assistantId, conversationId: "c1", context: context)

        let notes = BookStore.loadNotes(safeName: Self.book, profileId: Self.pid)
        XCTAssertEqual(notes.first?.content, "（助手正在回答…）", "无 bookRef 不回填")
    }

    func testFillSameContentDoesNotRewrite() {
        let ids = makeTurn(userBookRef: "\(Self.book)#chapter3", assistantContent: "答案")
        seedPlaceholderNote(messageId: ids.userId)
        BookNoteBackfill.fill(nodeId: ids.assistantId, conversationId: "c1", context: context)
        let mtime1 = notesMTime()

        // 同内容再收口一次（不应重写文件）
        BookNoteBackfill.fill(nodeId: ids.assistantId, conversationId: "c1", context: context)
        XCTAssertEqual(notesMTime(), mtime1, "内容未变不落盘")
    }

    private func notesMTime() -> Date? {
        let url = BookStore.bookDir(safeName: Self.book, profileId: Self.pid)
            .appendingPathComponent("notes.json")
        return try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    // MARK: - CR-1 replyTo 向后兼容

    func testNoteDecodingWithoutReplyToDefaultsNil() throws {
        // 老 notes.json（无 replyTo 字段）必须能解出 nil，不炸
        let legacy = """
        [{"id":"n1","chapter":1,"anchorText":"a","anchorStart":0,"anchorEnd":1,
          "kind":"note","content":"c","role":"user","createdAt":"2026-01-01T00:00:00Z"}]
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let notes = try d.decode([BookStore.Note].self, from: Data(legacy.utf8))
        XCTAssertNil(notes[0].replyTo)
    }
}
