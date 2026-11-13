import MemoryCore
import XCTest
@testable import 记忆花园

/// v5 §3-2：{助手}的 pending_notes 工具（list / done / faded）；门 = 总开关 && A4 开
final class PendingToolTests: XCTestCase {

    let pid = "xctest-pending-tool"
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in ["mem_master", "mem_content_timeline"] { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        PendingStore.forget(profileId: pid)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    @MainActor
    func testGate() {
        XCTAssertTrue(PendingNotesTool.enabled)
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        XCTAssertFalse(PendingNotesTool.enabled, "A4 关了不给")
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        UserDefaults.standard.set(false, forKey: "mem_master")
        XCTAssertFalse(PendingNotesTool.enabled, "总开关关了不给")
        XCTAssertNotNil(ToolRegistry.all.first { $0.definition.name == PendingNotesTool.toolName }, "进了注册表")
        XCTAssertEqual(ToolDrawerCatalog.item(named: PendingNotesTool.toolName)?.gate, .memoryWriter(.a4))
    }

    func testListDoneFaded() throws {
        try PendingStore.add(["问结果"], conversationId: "conv-here", day: "2026-10-14", anchor: nil, profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        try PendingStore.add(["列清单"], conversationId: "conv-else", day: "2026-10-13", anchor: nil, profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        let list = PendingNotesTool.execute(inputJSON: #"{"action":"list"}"#, profileId: pid, conversationId: "conv-here")
        XCTAssertFalse(list.isError)
        XCTAssertTrue(list.text.hasPrefix("这个窗口：\n- p0001 · 问结果"), list.text)
        XCTAssertTrue(list.text.contains("别的窗口：\n- p0002 · 列清单"))

        let done = PendingNotesTool.execute(inputJSON: #"{"action":"done","id":"p0001"}"#, profileId: pid, conversationId: "conv-here")
        XCTAssertEqual(done.text, "标好了：「问结果」→ 做完了")
        let faded = PendingNotesTool.execute(inputJSON: #"{"action":"faded","id":"p0002"}"#, profileId: pid, conversationId: "conv-here")
        XCTAssertFalse(faded.isError)
        XCTAssertEqual(PendingNotesTool.execute(inputJSON: #"{"action":"list"}"#, profileId: pid, conversationId: "conv-here").text,
                       "现在没有没做完的待续")
    }

    func testErrors() {
        XCTAssertTrue(PendingNotesTool.execute(inputJSON: #"{"action":"done"}"#, profileId: pid, conversationId: nil).isError)
        XCTAssertTrue(PendingNotesTool.execute(inputJSON: #"{"action":"done","id":"p9999"}"#, profileId: pid, conversationId: nil).isError)
        XCTAssertTrue(PendingNotesTool.execute(inputJSON: #"{"action":"delete"}"#, profileId: pid, conversationId: nil).isError)
    }

    func testAddPersistsOnlyCurrentSourceEvenWithForeignArgument() throws {
        let added = PendingNotesTool.execute(inputJSON: #"{"action":"add","text":"取云桥城地图"}"#, profileId: pid, conversationId: "conv-here")
        XCTAssertFalse(added.isError, added.text)
        let explicit = PendingNotesTool.execute(inputJSON: #"{"action":"add","text":"找星砚","conversation_id":"conv-else"}"#, profileId: pid, conversationId: "conv-here")
        XCTAssertFalse(explicit.isError, explicit.text)
        let stored = try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertEqual(stored.map(\.text), ["取云桥城地图", "找星砚"])
        XCTAssertEqual(stored.map(\.conversationId), ["conv-here", "conv-here"])
        XCTAssertTrue(stored.allSatisfy { $0.state == .open && $0.day == MemoryDay.key(Date()) })
        let listed = PendingNotesTool.execute(inputJSON: #"{"action":"list"}"#, profileId: pid, conversationId: "conv-here")
        XCTAssertTrue(listed.text.contains("这个窗口：\n- p0001 · 取云桥城地图"))
        XCTAssertTrue(listed.text.contains("- p0002 · 找星砚"))
        XCTAssertFalse(listed.text.contains("别的窗口："))
    }

    func testAddTextBoundariesAndParticipationGate() throws {
        for text in ["", " \n ", String(repeating: "城", count: 201)] {
            let input = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "add", "text": text]), as: UTF8.self)
            XCTAssertTrue(PendingNotesTool.execute(inputJSON: input, profileId: pid, conversationId: "conv-here").isError)
        }
        let blocked = PendingNotesTool.execute(inputJSON: #"{"action":"add","text":"取地图"}"#, profileId: pid,
                                                conversationId: "conv-here", memoryEnabled: false)
        XCTAssertEqual(blocked, .init(text: "这场对话关了记忆参与，不能改待续", isError: true))
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) ?? [], [])
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "add", "text": String(repeating: "城", count: 200)]), as: UTF8.self)
        XCTAssertFalse(PendingNotesTool.execute(inputJSON: input, profileId: pid, conversationId: "conv-here").isError)
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.first?.text, String(repeating: "城", count: 200))
    }

    func testAddRejectsMultilineAndMarkupWithoutCorruptingNotebook() throws {
        let seed = PendingNotesTool.execute(inputJSON: #"{"action":"add","text":"取地图"}"#, profileId: pid, conversationId: "conv-here")
        XCTAssertFalse(seed.isError)
        let before = try Data(contentsOf: PendingStore.fileURL(root: FileLibraryStore.memoryRoot(profileId: pid)))
        for text in ["取地图\n走北门", "取地图\r走北门", "取地图\u{2028}走北门", "取<地图>", "取<!--地图-->"] {
            let input = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "add", "text": text]), as: UTF8.self)
            XCTAssertTrue(PendingNotesTool.execute(inputJSON: input, profileId: pid, conversationId: "conv-here").isError, text)
            XCTAssertEqual(try Data(contentsOf: PendingStore.fileURL(root: FileLibraryStore.memoryRoot(profileId: pid))), before)
            try PendingStore.checkReadable(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        }
        PendingStore.forget(profileId: pid)
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.map(\.text), ["取地图"])
        let rendered = PendingStore.render(try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))))
        XCTAssertEqual(PendingStore.parse(rendered).map(\.text), ["取地图"])
        XCTAssertTrue(PendingNotesTool.execute(inputJSON: #"{"action":"add","text":"找星砚","conversation_id":"conv-else"}"#,
                                               profileId: pid, conversationId: nil).isError)
    }
}
