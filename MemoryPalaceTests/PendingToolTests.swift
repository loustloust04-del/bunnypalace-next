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
        try PendingStore.add(["问结果"], conversationId: "conv-here", day: "2026-10-14", anchor: nil, profileId: pid)
        try PendingStore.add(["列清单"], conversationId: "conv-else", day: "2026-10-13", anchor: nil, profileId: pid)
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
}
