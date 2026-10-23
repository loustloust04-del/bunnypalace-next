import XCTest
@testable import 记忆花园

/// 网页卡宿主能力桥（research-chat-cards §13）：请求解析 + 一次运行里的判定
@MainActor
final class HTMLCardBridgeTests: XCTestCase {

    private func body(_ action: String, id: String = "r1", token: String = "tok", _ extra: [String: Any] = [:]) -> [String: Any] {
        var b: [String: Any] = ["type": "cardRequest", "id": id, "token": token, "action": action]
        extra.forEach { b[$0.key] = $0.value }
        return b
    }

    private func parsed(_ b: [String: Any]) -> HTMLCardAction? {
        if case .success(let r) = HTMLCardRequest.parse(b) { return r.action }
        return nil
    }

    private func parseError(_ b: [String: Any]) -> HTMLCardBridgeError? {
        if case .failure(let e) = HTMLCardRequest.parse(b) { return e }
        return nil
    }

    // MARK: - 解析

    func testParsesFourActions() {
        XCTAssertEqual(parsed(body("todo.add", ["text": " 背 30 个词 ", "date": "2026-10-02"])), .addTodo(text: "背 30 个词", date: "2026-10-02"))
        XCTAssertEqual(parsed(body("todo.add", ["text": "喝水"])), .addTodo(text: "喝水", date: nil))
        XCTAssertEqual(parsed(body("vocab.add", ["text": "ephemeral"])), .addVocab(word: "ephemeral"))
        XCTAssertEqual(parsed(body("ask", ["text": "再出一组"])), .ask("再出一组"))
        XCTAssertEqual(parsed(body("report", ["text": "测验 7/10"])), .report("测验 7/10"))
    }

    func testKeepsIdAndToken() throws {
        let r = try HTMLCardRequest.parse(body("ask", id: "q9", token: "abc", ["text": "hi"])).get()
        XCTAssertEqual(r.id, "q9")
        XCTAssertEqual(r.token, "abc")
    }

    func testRejectsMissingOrBlank() {
        XCTAssertEqual(parseError(body("todo.add")), .invalid)
        XCTAssertEqual(parseError(body("todo.add", ["text": "  \n "])), .invalid)
        XCTAssertEqual(parseError(body("todo.add", ["text": 3])), .invalid)
        XCTAssertEqual(parseError(["action": "ask", "text": "hi", "token": "t"]), .invalid, "没有 id")
        XCTAssertEqual(parseError(body("ask", id: String(repeating: "x", count: 65), ["text": "hi"])), .invalid, "id 太长")
    }

    func testRejectsUnknownAction() {
        XCTAssertEqual(parseError(body("memory.add", ["text": "x"])), .unknownAction)
    }

    func testRejectsTooLongInsteadOfTruncating() {
        XCTAssertEqual(parseError(body("todo.add", ["text": String(repeating: "字", count: 201)])), .tooLong)
        XCTAssertNotNil(parsed(body("todo.add", ["text": String(repeating: "字", count: 200)])))
        XCTAssertEqual(parseError(body("vocab.add", ["text": String(repeating: "a", count: 65)])), .tooLong)
        XCTAssertEqual(parseError(body("ask", ["text": String(repeating: "a", count: 501)])), .tooLong)
        XCTAssertEqual(parseError(body("report", ["text": String(repeating: "a", count: 201)])), .tooLong)
    }

    func testRejectsBadDate() {
        XCTAssertEqual(parseError(body("todo.add", ["text": "x", "date": "明天"])), .invalid)
        XCTAssertEqual(parseError(body("todo.add", ["text": "x", "date": "2026-13-01"])), .invalid)
    }

    func testOnlyTodoAndVocabNeedConfirm() {
        XCTAssertTrue(HTMLCardAction.addTodo(text: "x", date: nil).needsConfirm)
        XCTAssertTrue(HTMLCardAction.addVocab(word: "x").needsConfirm)
        XCTAssertFalse(HTMLCardAction.ask("x").needsConfirm)
        XCTAssertFalse(HTMLCardAction.report("x").needsConfirm)
    }

    // MARK: - 一次运行

    func testWrongTokenOrNotRunningIsRejected() {
        let s = HTMLCardBridgeSession(token: "tok")
        XCTAssertEqual(s.receive(body("ask", token: "old", ["text": "hi"]), running: true), .reply(id: "r1", error: .notRunning))
        XCTAssertEqual(s.receive(body("ask", ["text": "hi"]), running: false), .reply(id: "r1", error: .notRunning))
    }

    func testParseErrorRepliesWithId() {
        let s = HTMLCardBridgeSession(token: "tok")
        XCTAssertEqual(s.receive(body("nope", id: "z"), running: true), .reply(id: "z", error: .unknownAction))
    }

    func testConfirmFlowAllowsThenPerforms() throws {
        let s = HTMLCardBridgeSession(token: "tok")
        let step = s.receive(body("todo.add", ["text": "喝水"]), running: true)
        guard case .confirm(let req) = step else { return XCTFail("要先确认：\(step)") }
        XCTAssertEqual(s.pending, req)
        XCTAssertEqual(s.resolve(allowed: true), .perform(req))
        XCTAssertNil(s.pending)
    }

    func testSecondRequestWhileConfirmingIsBusy() {
        let s = HTMLCardBridgeSession(token: "tok")
        _ = s.receive(body("todo.add", id: "a", ["text": "x"]), running: true)
        XCTAssertEqual(s.receive(body("vocab.add", id: "b", ["text": "y"]), running: true), .reply(id: "b", error: .busy))
        XCTAssertEqual(s.receive(body("report", id: "c", ["text": "z"]), running: true), .reply(id: "c", error: .busy),
                       "排着确认时连不用确认的也先挡掉，回复按顺序")
    }

    func testThreeDenialsCloseTheBridge() {
        let s = HTMLCardBridgeSession(token: "tok")
        for i in 0..<3 {
            _ = s.receive(body("todo.add", id: "d\(i)", ["text": "x"]), running: true)
            XCTAssertEqual(s.resolve(allowed: false), .reply(id: "d\(i)", error: .denied))
        }
        XCTAssertTrue(s.isClosed)
        XCTAssertEqual(s.receive(body("report", id: "e", ["text": "z"]), running: true), .reply(id: "e", error: .closed))
    }

    func testAskAndReportAreRateLimited() {
        let s = HTMLCardBridgeSession(token: "tok")
        for i in 0..<5 {
            guard case .perform = s.receive(body("ask", id: "a\(i)", ["text": "x"]), running: true) else { return XCTFail() }
        }
        XCTAssertEqual(s.receive(body("ask", id: "a5", ["text": "x"]), running: true), .reply(id: "a5", error: .limit))
        for i in 0..<20 {
            guard case .perform = s.receive(body("report", id: "r\(i)", ["text": "x"]), running: true) else { return XCTFail() }
        }
        XCTAssertEqual(s.receive(body("report", id: "r20", ["text": "x"]), running: true), .reply(id: "r20", error: .limit))
    }

    func testCancelPendingRepliesClosed() {
        let s = HTMLCardBridgeSession(token: "tok")
        XCTAssertNil(s.cancelPending())
        _ = s.receive(body("vocab.add", id: "v", ["text": "y"]), running: true)
        XCTAssertEqual(s.cancelPending(), .reply(id: "v", error: .closed))
        XCTAssertNil(s.pending)
        XCTAssertNil(s.resolve(allowed: true), "弹窗晚点回来也不执行")
    }

    // MARK: - mp.ask 进输入框

    func testComposerAppending() {
        XCTAssertEqual(ConversationViewModel.appending("再出一组", to: ""), "再出一组")
        XCTAssertEqual(ConversationViewModel.appending("再出一组", to: "我想"), "我想\n再出一组")
    }

    // MARK: - 给模型的说明

    func testGuideTellsModelAboutBridge() {
        let text = ChatCardPromptGuide.text
        for api in ["mp.todo.add", "mp.vocab.add", "mp.ask", "mp.report", "[附带事件]"] {
            XCTAssertTrue(text.contains(api), "说明里要有 \(api)")
        }
    }

    // MARK: - 壳

    private func shellLines(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "Web")
                                ?? Bundle.main.url(forResource: name, withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// 两份壳只差顶部注释和 CSP（前 10 行），桥的代码两边一样
    func testShellsIdenticalBelowCSP() throws {
        let offline = try shellLines("html-preview")
        let online = try shellLines("html-preview-online")
        XCTAssertEqual(Array(offline.dropFirst(10)), Array(online.dropFirst(10)))
        let body = offline.joined(separator: "\n")
        XCTAssertTrue(body.contains("type: \"cardRequest\""), "壳要转发卡片请求")
        XCTAssertTrue(body.contains("token: bridgeToken"), "转发时附上本次运行的令牌")
        XCTAssertFalse(body.contains("allow-same-origin\""), "iframe 永远不给 same-origin")
    }
}
