import XCTest
@testable import 记忆花园

/// 聊天划线存储：叠划、时间线、老文件迁移、落盘 roundtrip、坏 JSON 兜底。
@MainActor
final class ChatHighlightStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-chat-highlights-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - 09-26 和读书划线同步

    func testLegacyFileMigratesNoteAndColor() throws {
        let legacy = """
        [{"colorId":"amber","createdAt":"2026-09-01T10:00:00Z","nodeId":"n1","note":"老批注","profileId":"p","quote":"abc"},
         {"colorId":"rose","createdAt":"2026-09-02T10:00:00Z","nodeId":"n1","profileId":"p","quote":"def"}]
        """
        try legacy.data(using: .utf8)!.write(to: dir.appendingPathComponent("chat-highlights.json"))
        let store = ChatHighlightStore(dir: dir)
        let hs = store.strokes(nodeId: "n1", profileId: "p")
        XCTAssertEqual(hs.count, 2)
        XCTAssertEqual(hs[0].content, "老批注", "老批注 = 时间线第一条")
        XCTAssertNil(hs[0].note)
        XCTAssertEqual(hs[0].strokeColorHex, "#E89B47", "暖橙保持原色")
        XCTAssertEqual(hs[1].strokeColorHex, "#C98A8A")
        XCTAssertEqual(hs[1].strokeStyle, .fill)
        XCTAssertFalse(hs[0].id.isEmpty)
        // 迁移已落盘：重读 id 不变
        XCTAssertEqual(ChatHighlightStore(dir: dir).strokes(nodeId: "n1", profileId: "p").map(\.id), hs.map(\.id))
    }

    func testAddStacksSameQuote() {
        let store = ChatHighlightStore(dir: dir)
        store.add(nodeId: "n1", profileId: "p", quote: "abc", color: "#BDA8D8", style: .underline)
        store.add(nodeId: "n1", profileId: "p", quote: "abc", color: "#8EBD9F", style: .fill)
        let hs = ChatHighlightStore(dir: dir).strokes(nodeId: "n1", profileId: "p")
        XCTAssertEqual(hs.count, 2, "同一段再划 = 叠一道")
        XCTAssertEqual(hs[0].strokeStyle, .underline)
        XCTAssertEqual(NoteThreads.place(of: hs[1].id, in: store.highlights)?.strokes.count, 2, "两道同一处")
    }

    func testTimelineOnChatHighlights() {
        let store = ChatHighlightStore(dir: dir)
        let h = store.add(nodeId: "n1", profileId: "p", quote: "abc", color: "#8EBD9F", style: .fill)!
        let place = NoteThreads.place(of: h.id, in: store.highlights)!
        store.mutate { NoteThreads.addEntry("第一条", to: place, in: &$0) }
        store.mutate { NoteThreads.addEntry("第二条", to: NoteThreads.place(of: h.id, in: $0)!, in: &$0) }
        let reloaded = ChatHighlightStore(dir: dir)
        let p2 = NoteThreads.place(of: h.id, in: reloaded.highlights)!
        XCTAssertEqual(NoteThreads.entries(of: p2, in: reloaded.highlights).map(\.content), ["第一条", "第二条"])
        XCTAssertEqual(reloaded.strokes(nodeId: "n1", profileId: "p").count, 1, "回复不算笔画")
        reloaded.mutate { NoteThreads.deleteEntry(h.id, in: &$0) }
        XCTAssertEqual(reloaded.highlights.count, 2, "删根那条只清内容，不级联")
    }

    func testNearestLegacyId() {
        XCTAssertEqual(ChatHighlight.nearestLegacyId("#D99A9A"), "rose")
        XCTAssertEqual(ChatHighlight.nearestLegacyId("#AFC08A"), "mint")
        XCTAssertEqual(ChatHighlight.nearestLegacyId("#E0A050"), "amber")
    }

    func testUnreadableFileIsKeptAside() {
        try? "not json".data(using: .utf8)?.write(to: dir.appendingPathComponent("chat-highlights.json"))
        let store = ChatHighlightStore(dir: dir)
        store.add(nodeId: "n", profileId: "p", quote: "x", color: "#8EBD9F", style: .fill)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("chat-highlights.unreadable-") }, "读不懂的原文件留了一份")
    }

    func testPersistRoundtripKeepsColorAndStyle() {
        let store = ChatHighlightStore(dir: dir)
        let h = store.add(nodeId: "n1", profileId: "p", quote: "abc", color: "#C98A8A", style: .pen)!
        let reloaded = ChatHighlightStore(dir: dir).strokes(nodeId: "n1", profileId: "p").first
        XCTAssertEqual(reloaded?.strokeColorHex, "#C98A8A")
        XCTAssertEqual(reloaded?.strokeStyle, .pen)
        XCTAssertEqual(reloaded?.colorId, "rose", "旧版本读得出来的颜色名")
        store.mutate { notes in
            guard let i = notes.firstIndex(where: { $0.id == h.id }) else { return }
            notes[i].color = "#8EBD9F"
            notes[i].style = HighlightStyle.underline.rawValue
        }
        let again = ChatHighlightStore(dir: dir).strokes(nodeId: "n1", profileId: "p").first
        XCTAssertEqual(again?.strokeStyle, .underline)
        XCTAssertEqual(again?.colorId, "mint", "改色后颜色名跟着变")
    }

    func testSyntheticAnchorIsPerFloor() {
        let store = ChatHighlightStore(dir: dir)
        let a = store.add(nodeId: "ticker:NVDA", profileId: "p1", quote: "abc", color: "#8EBD9F", style: .fill)!
        store.add(nodeId: "ticker:NVDA", profileId: "p2", quote: "abc", color: "#C98A8A", style: .fill)
        XCTAssertEqual(store.strokes(nodeId: "ticker:NVDA", profileId: "p1").count, 1, "别的楼层的同名锚不算")
        XCTAssertEqual(NoteThreads.place(of: a.id, in: store.highlights)?.strokes.count, 1)
        store.mutate { NoteThreads.removePlace(NoteThreads.place(of: a.id, in: $0)!, in: &$0) }
        XCTAssertEqual(store.strokes(nodeId: "ticker:NVDA", profileId: "p2").count, 1, "删这处不碰别的楼层")
    }

    func testUnreadableFileIsNeverOverwritten() throws {
        let url = dir.appendingPathComponent("chat-highlights.json")
        try "{ not json".data(using: .utf8)!.write(to: url)
        let store = ChatHighlightStore(dir: dir)
        XCTAssertTrue(store.writesBlocked)
        store.add(nodeId: "n", profileId: "p", quote: "x", color: "#8EBD9F", style: .fill)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json", "读不懂的原文件不被空数据覆盖")
    }

    func testMissingIdsArePersistedOnLoad() throws {
        let legacy = """
        [{"colorId":"mint","createdAt":"2026-09-01T10:00:00Z","nodeId":"n1","profileId":"p","quote":"abc"}]
        """
        try legacy.data(using: .utf8)!.write(to: dir.appendingPathComponent("chat-highlights.json"))
        let first = ChatHighlightStore(dir: dir).highlights.first?.id
        XCTAssertEqual(ChatHighlightStore(dir: dir).highlights.first?.id, first, "补的 id 落盘，重开不变")
    }

    func testCorruptJSONReturnsEmpty() {
        try? "not json".data(using: .utf8)?.write(to: dir.appendingPathComponent("chat-highlights.json"))
        XCTAssertEqual(ChatHighlightStore(dir: dir).highlights.count, 0)
    }
}
