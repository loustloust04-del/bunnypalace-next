import XCTest
@testable import 记忆花园

/// 进度卡 B（粟粟 10-03「都按推荐」）：CC 对话的三个点换成状态卡
@MainActor
final class CCSessionPhaseTests: XCTestCase {
    private func frame(_ extra: [String: Any]) -> [String: Any] {
        ["type": "session_phase", "session_name": "mp-cc", "chat_id": "conv-1", "updated_unix": 1_000, "can_stop": true].merging(extra) { $1 }
    }

    func testParseFrame() {
        let p = CCSessionPhase(frame: frame(["phase": "waiting", "detail": "选哪个？", "since_unix": 900]))
        XCTAssertEqual(p?.chatId, "conv-1")
        XCTAssertEqual(p?.sessionName, "mp-cc")
        XCTAssertEqual(p?.phase, .waiting)
        XCTAssertEqual(p?.detail, "选哪个？")
        XCTAssertEqual(p?.since, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(p?.canStop, true)
        XCTAssertNil(CCSessionPhase(frame: frame(["phase": "working", "chat_id": NSNull()])), "没有 chat_id 不知道该放哪个对话")
        XCTAssertNil(CCSessionPhase(frame: frame(["phase": "dancing"])))
    }

    func testHeadlines() {
        let now = Date(timeIntervalSince1970: 1_200)
        let working = CCSessionPhase(frame: frame(["phase": "working", "since_unix": 1_020]))!
        XCTAssertEqual(working.headline(now: now), "干活中 · 3 分钟")
        let fresh = CCSessionPhase(frame: frame(["phase": "working", "since_unix": 1_188]))!
        XCTAssertEqual(fresh.headline(now: now), "干活中 · 12 秒")
        XCTAssertEqual(CCSessionPhase(frame: frame(["phase": "working"]))!.headline(now: now), "干活中")
        XCTAssertEqual(CCSessionPhase(frame: frame(["phase": "waiting", "detail": "选哪个？"]))!.headline(now: now), "在等你回答：选哪个？")
        XCTAssertEqual(CCSessionPhase(frame: frame(["phase": "waiting"]))!.headline(now: now), "在等你")
        XCTAssertEqual(CCSessionPhase(frame: frame(["phase": "done", "since_unix": 880]))!.headline(now: now), "做完了 · 用时 2 分钟")
    }

    func testVisibility() {
        let now = Date(timeIntervalSince1970: 1_005)
        XCTAssertTrue(CCSessionPhase(frame: frame(["phase": "working", "tools": 2]))!.isVisible(now: now))
        XCTAssertTrue(CCSessionPhase(frame: frame(["phase": "waiting"]))!.isVisible(now: now), "等你回答：不管动没动工具都出")
        XCTAssertTrue(CCSessionPhase(frame: frame(["phase": "done", "tools": 1]))!.isVisible(now: now), "刚做完亮一下")
        XCTAssertFalse(CCSessionPhase(frame: frame(["phase": "done", "tools": 1]))!.isVisible(now: now.addingTimeInterval(30)), "做完一会儿就收")
        XCTAssertFalse(CCSessionPhase(frame: frame(["phase": "idle"]))!.isVisible(now: now))
    }

    /// 粟粟 10-04：普通聊天（没调用工具）不出状态卡，照旧三个点
    func testPlainChatHasNoCard() {
        let now = Date(timeIntervalSince1970: 1_005)
        XCTAssertFalse(CCSessionPhase(frame: frame(["phase": "working"]))!.isVisible(now: now))
        XCTAssertFalse(CCSessionPhase(frame: frame(["phase": "done"]))!.isVisible(now: now))
    }

    func testToolInHeadline() {
        let now = Date(timeIntervalSince1970: 1_200)
        let p = CCSessionPhase(frame: frame(["phase": "working", "since_unix": 1_020, "tools": 4, "tool": "Bash"]))!
        XCTAssertEqual(p.tools, 4)
        XCTAssertEqual(p.headline(now: now), "干活中 · 3 分钟 · 跑命令")
        XCTAssertEqual(CCSessionPhase(frame: frame(["phase": "working", "tools": 1, "tool": "mcp__github__create_issue"]))!.headline(now: now), "干活中 · create_issue")
        XCTAssertEqual(CCSessionPhase(frame: frame(["phase": "done", "since_unix": 880, "tools": 5]))!.headline(now: now), "做完了 · 用时 2 分钟 · 用了 5 次工具")
        XCTAssertEqual(CCSessionPhase.toolName("Read"), "读文件")
        XCTAssertEqual(CCSessionPhase.toolName("SomethingNew"), "SomethingNew")
    }

    func testStoreKeysByConversationAndReplaces() {
        let store = CCSessionPhaseStore()
        store.apply(CCSessionPhase(frame: frame(["phase": "working"]))!)
        store.apply(CCSessionPhase(frame: frame(["phase": "done", "chat_id": "conv-2", "session_name": "mp-cc-2"]))!)
        XCTAssertEqual(store.phase(for: "conv-1")?.phase, .working)
        store.apply(CCSessionPhase(frame: frame(["phase": "waiting"]))!)
        XCTAssertEqual(store.phase(for: "conv-1")?.phase, .waiting)
        XCTAssertEqual(store.phase(for: "conv-2")?.sessionName, "mp-cc-2")
        XCTAssertNil(store.phase(for: "conv-3"))
    }

    func testSameSessionMovedToAnotherChatClearsOldOne() {
        let store = CCSessionPhaseStore()
        store.apply(CCSessionPhase(frame: frame(["phase": "working"]))!)
        store.apply(CCSessionPhase(frame: frame(["phase": "working", "chat_id": "conv-2"]))!)
        XCTAssertNil(store.phase(for: "conv-1"), "mp-cc 改从别的对话发了：旧对话不再挂它的状态")
        XCTAssertEqual(store.phase(for: "conv-2")?.phase, .working)
    }
}
