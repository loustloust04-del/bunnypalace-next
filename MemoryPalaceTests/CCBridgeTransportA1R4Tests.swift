import XCTest
@testable import 记忆花园

/// A1 第四轮返工（sol R4 #1–#4 + reportUncertainSend）：同一个 message_id 的多次发送按协议里的 attempt 精确认领，
/// 不再靠 FIFO 猜；旧 hub（不带 attempt）走兼容兜底。每条都在 bug 存在时失败（变异验证见实验日志）。
/// 不碰网络：task 从不 resume，connect / startTask 在测试宿主被 TestHostIsolation 挡在发请求前。能两条路跑的都 A1=1 / A1=0 各跑一遍。
final class CCBridgeTransportA1R4Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clients: [CCBridgeWebSocketClient] = []
    private var session: URLSession!
    private let hubURL = URL(string: "ws://127.0.0.1:9/cc")!
    private let otherHubURL = URL(string: "ws://127.0.0.3:9/cc")!

    final class Wire {
        struct Sent {
            let task: URLSessionWebSocketTask
            let obj: [String: Any]
            var type: String { obj["type"] as? String ?? "?" }
            var isRetry: Bool { obj["retry"] as? Bool == true }
            var attempt: String? { obj["attempt"] as? String }
            var messageId: String? { obj["message_id"] as? String }
        }
        private let lock = NSLock()
        private var items: [Sent] = []
        private var held: [(Error?) -> Void] = []
        var hold: (Sent) -> Bool = { _ in false }

        func install(on client: CCBridgeWebSocketClient) {
            client.setTransmitHookForTesting { [weak self] task, text, completion in
                guard let self else { completion(nil); return }
                let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                let sent = Sent(task: task, obj: obj)
                self.lock.lock()
                self.items.append(sent)
                let keep = self.hold(sent)
                if keep { self.held.append(completion) }
                self.lock.unlock()
                if !keep { DispatchQueue.global().async { completion(nil) } }
            }
        }

        var all: [Sent] { lock.lock(); defer { lock.unlock() }; return items }
        func sends(_ id: String) -> [Sent] { all.filter { $0.type == "send" && $0.messageId == id } }
        var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

        func release(_ i: Int, _ error: Error?) {
            lock.lock()
            let completion = held[i]
            lock.unlock()
            completion(error)
        }
    }

    override func setUp() {
        super.setUp()
        suite = "CCBridgeTransportA1R4Tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        for c in clients {
            c.disconnect()
            c.setTransmitHookForTesting(nil)
            c.setRequestCapturedHookForTesting(nil)
        }
        clients = []
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func makeClient(a1: Bool) -> (CCBridgeWebSocketClient, Wire) {
        let c = CCBridgeWebSocketClient(dedupDefaults: defaults, transportOffMain: a1)
        clients.append(c)
        let wire = Wire()
        wire.install(on: c)
        return (c, wire)
    }

    private func bothPaths(_ body: (Bool) -> Void) {
        for a1 in [true, false] {
            XCTContext.runActivity(named: a1 ? "A1=1" : "A1=0") { _ in body(a1) }
            for c in clients { c.disconnect() }
            settle(0.05)
        }
    }

    private func makeTask(_ url: URL? = nil) -> URLSessionWebSocketTask { session.webSocketTask(with: url ?? hubURL) }

    private func text(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func didOpen(_ client: CCBridgeWebSocketClient, _ task: URLSessionWebSocketTask) {
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
    }

    @discardableResult
    private func openTask(_ client: CCBridgeWebSocketClient, url: URL? = nil) -> URLSessionWebSocketTask {
        let task = makeTask(url)
        client.adoptTaskForTesting(task, url: url ?? hubURL)
        didOpen(client, task)
        XCTAssertTrue(spin { client.isConnected && client.currentTaskForTesting === task })
        client.drainTransportForTesting()
        settle(0.05)   // isConnected 可能还是上一条留下的 true：让这条的 didOpen 在 transport / 主线程上真正处理完
        return task
    }

    @discardableResult
    private func spin(timeout: TimeInterval = 2, until cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    private func settle(_ seconds: TimeInterval = 0.2) { spin(timeout: seconds) { false } }

    private func sendUser(_ client: CCBridgeWebSocketClient, _ id: String) {
        client.sendUserMessage(chatId: "C1", messageId: id, content: "hi", user: "u", session: nil, replyTo: nil, attachments: [])
    }

    private func receipt(_ client: CCBridgeWebSocketClient, _ id: String) -> String? {
        guard let e = client.sendTracker.store.entry(id), e.state == .failed, !e.canRetry else { return nil }
        return e.visibleReason
    }

    private func drop(_ client: CCBridgeWebSocketClient, _ task: URLSessionWebSocketTask) {
        client.didReceive(.failure(URLError(.networkConnectionLost)), on: task)
    }

    private func ack(_ id: String, _ attempt: String?) -> String {
        var obj: [String: Any] = ["type": "ack", "message_id": id]
        if let attempt { obj["attempt"] = attempt }
        return text(obj)
    }

    private func status(_ id: String, _ state: String, retryable: Bool? = nil, attempt: String?) -> [String: Any] {
        var obj: [String: Any] = ["chat_id": "C1", "message_id": id, "session_name": "mp-cc", "status": state]
        if let retryable { obj["retryable"] = retryable }
        if let attempt { obj["attempt"] = attempt }
        return obj
    }

    private func statusFrame(_ id: String, _ state: String, retryable: Bool? = nil, attempt: String?) -> String {
        var obj = status(id, state, retryable: retryable, attempt: attempt)
        obj["type"] = "send_status"
        return text(obj)
    }

    /// 第 n 次发送（含重发）帧里 app 给的 attempt
    private func attemptOf(_ wire: Wire, _ id: String, _ n: Int) -> String? {
        let all = wire.all.filter { $0.messageId == id && $0.type == "send" }
        return all.count > n ? all[n].attempt : nil
    }

    // MARK: - #1 本地已给回执后，旧尝试的状态不撤回执

    /// 新的一次本地写入失败已出回执，之后旧那次（A 上）的 delivered 才落地：带 attempt 的、不带的都不撤这条回执
    func testStaleStatusAfterLocalSettlementKeepsReceipt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "s1")
            XCTAssertTrue(spin { wire.sends("s1").count == 1 })
            let first = attemptOf(wire, "s1", 0)
            XCTAssertNotNil(first, "send 帧带 attempt")
            client.handleIncoming(ack("s1", first), source: a)
            let b = openTask(client)
            wire.hold = { $0.type == "send" }
            sendUser(client, "s1")
            XCTAssertTrue(spin { wire.heldCount == 1 })
            XCTAssertNotEqual(attemptOf(wire, "s1", 1), first, "每次发送一个新编号")
            wire.release(0, URLError(.networkConnectionLost))
            XCTAssertTrue(spin { receipt(client, "s1") == CCBridgeWebSocketClient.userFrameUncertainReason })
            client.handleIncoming(statusFrame("s1", "delivered", attempt: first), source: a)
            client.handleIncoming(statusFrame("s1", "delivered", attempt: nil), source: a)
            settle()
            XCTAssertEqual(receipt(client, "s1"), CCBridgeWebSocketClient.userFrameUncertainReason, "旧那次的结果不撤新那次的回执")
            drop(client, b)
            settle(0.1)
            XCTAssertEqual(receipt(client, "s1"), CCBridgeWebSocketClient.userFrameUncertainReason)
        }
    }

    // MARK: - #3 回话不按交出顺序也认得对

    /// 同一 id 先后交出两次，hub 先回了第二次的 ack（第一次在等 codex 重启）：按编号认领，第二次已收下，断线不出回执
    func testOutOfOrderAcksMatchedByAttempt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "s2")
            sendUser(client, "s2")
            XCTAssertTrue(spin { wire.sends("s2").count == 2 })
            client.handleIncoming(ack("s2", attemptOf(wire, "s2", 1)), source: a)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("s2") })
            drop(client, a)
            settle()
            XCTAssertNil(client.sendTracker.store.entry("s2"), "第二次自己的 ack 已经收到")
        }
    }

    // MARK: - #4 快照不消费直接回话；abortRetry 两帧之间开始的新尝试不受影响

    private func makeRetryable(_ client: CCBridgeWebSocketClient, _ wire: Wire, _ id: String, on task: URLSessionWebSocketTask) -> String? {
        sendUser(client, id)
        XCTAssertTrue(spin { !wire.sends(id).isEmpty })
        let a = attemptOf(wire, id, 0)
        client.handleIncoming(ack(id, a), source: task)
        client.handleIncoming(statusFrame(id, "failed", retryable: true, attempt: a), source: task)
        XCTAssertTrue(spin { client.sendTracker.canRetry(id) })
        return a
    }

    /// 同目标重连后点重发；hub 在收到重发之前生成的快照（旧那次的 failed）才落地：不当成重发的回话，气泡仍在「确认中」
    func testOldSnapshotDuringRetryDoesNotSettleRetry() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            let original = makeRetryable(client, wire, "s3", on: a)
            drop(client, a)
            XCTAssertTrue(spin { !client.isConnected })
            let b = openTask(client)
            client.retrySend(messageId: "s3")
            XCTAssertTrue(spin { wire.all.contains { $0.task === b && $0.isRetry } })
            let snapshot: [String: Any] = ["type": "send_status_snapshot", "statuses": [status("s3", "failed", retryable: true, attempt: original), status("s3", "failed", retryable: true, attempt: nil)]]
            client.handleIncoming(text(snapshot), source: b)
            settle()
            XCTAssertEqual(client.sendTracker.store.entry("s3")?.state, .uncertain, "重发还在路上")
            XCTAssertTrue(client.sendTracker.isAwaitingHub("s3"))
            let retryAttempt = wire.all.first { $0.task === b && $0.isRetry }?.attempt
            client.handleIncoming(ack("s3", retryAttempt), source: b)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("s3") })
        }
    }

    /// 重发 r1 被接受后失败：hub 先推 r1 的 failed（可重发）、再回 r1 的直接 error；两帧之间她又点了重发 r2——
    /// r1 的 error 不能把 r2 标成「电脑没收下」
    func testAbortRetryErrorDoesNotHitNextRetry() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            _ = makeRetryable(client, wire, "s4", on: a)
            client.retrySend(messageId: "s4")
            XCTAssertTrue(spin { wire.all.filter { $0.isRetry }.count == 1 })
            let r1 = wire.all.filter { $0.isRetry }[0].attempt
            client.handleIncoming(statusFrame("s4", "failed", retryable: true, attempt: r1), source: a)
            XCTAssertTrue(spin { client.sendTracker.canRetry("s4") })
            client.retrySend(messageId: "s4")
            XCTAssertTrue(spin { wire.all.filter { $0.isRetry }.count == 2 })
            client.handleIncoming(text(["type": "error", "message_id": "s4", "reason": "tmux: x", "attempt": r1 ?? "?"]), source: a)
            settle()
            XCTAssertEqual(client.sendTracker.store.entry("s4")?.state, .uncertain, "r2 还在路上，r1 的 error 不算它的")
            XCTAssertTrue(client.sendTracker.isAwaitingHub("s4"))
        }
    }

    // MARK: - #2 原帧目标未知 = 不可重发

    /// sol 原交错：断线期间重新生成（新那次没交出去）、旧那次可重发的 failed 才落地、再换电脑——新缓存不能被旧状态赋予重发资格，原帧不发给新电脑
    func testOldStatusCannotMakeUnsentAttemptRetryable() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            sendUser(client, "s5")
            XCTAssertTrue(spin { wire.sends("s5").count == 1 })
            let first = attemptOf(wire, "s5", 0)
            client.handleIncoming(ack("s5", first), source: a)
            drop(client, a)
            XCTAssertTrue(spin { !client.isConnected })
            sendUser(client, "s5")
            XCTAssertTrue(spin { receipt(client, "s5") == CCBridgeWebSocketClient.userFrameNotSentReason })
            client.handleIncoming(statusFrame("s5", "failed", retryable: true, attempt: nil), source: a)
            client.handleIncoming(statusFrame("s5", "failed", retryable: true, attempt: first), source: a)
            settle()
            XCTAssertFalse(client.sendTracker.canRetry("s5"))
            client.connect(url: otherHubURL)
            let b = openTask(client, url: otherHubURL)
            client.retrySend(messageId: "s5")
            settle()
            XCTAssertFalse(wire.all.contains { $0.task === b && $0.isRetry }, "原帧不发给别的电脑")
        }
    }

    /// 没做过目标绑定（从没 connect 过）的原帧：重发在 transport 上被挡下，不出门
    func testRetryWithUnknownTargetIsBlocked() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            _ = makeRetryable(client, wire, "s6", on: a)
            client.retrySend(messageId: "s6")
            XCTAssertTrue(spin { receipt(client, "s6") == CCSendTracker.unknownTargetReason }, "\(receipt(client, "s6") ?? "nil")")
            XCTAssertFalse(wire.all.contains { $0.isRetry })
        }
    }

    // MARK: - reportUncertainSend

    /// 结果不明的 error（带 session_name + uncertain + 这一次的 attempt）→ 这一次出「不确定」回执；
    /// 核对失败后的旧版重复通知（带 session_name、没有 uncertain）和不带 attempt 的不认领
    func testUncertainSendErrorGivesReceipt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "s7")
            XCTAssertTrue(spin { wire.sends("s7").count == 1 })
            let mine = attemptOf(wire, "s7", 0) ?? "?"
            client.handleIncoming(text(["type": "error", "message_id": "s7", "session_name": "mp-cc", "reason": "这条消息没送进 mp-cc：x", "attempt": mine]), source: a)
            client.handleIncoming(text(["type": "error", "message_id": "s7", "session_name": "mp-cc", "uncertain": true, "reason": "tmux 卡住了"]), source: a)
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("s7"))
            XCTAssertTrue(client.sendTracker.isAwaitingHub("s7"))
            client.handleIncoming(text(["type": "error", "message_id": "s7", "session_name": "mp-cc", "uncertain": true, "reason": "tmux 卡住了", "attempt": mine]), source: a)
            XCTAssertTrue(spin { receipt(client, "s7") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    // MARK: - 旧 hub（回话不带 attempt）兼容兜底

    func testOldHubWithoutAttemptStillWorks() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "s8")
            sendUser(client, "s9")
            XCTAssertTrue(spin { wire.sends("s8").count == 1 && wire.sends("s9").count == 1 })
            client.handleIncoming(ack("s8", nil), source: a)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("s8") })
            client.handleIncoming(statusFrame("s8", "uncertain", attempt: nil), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("s8")?.state == .uncertain }, "ack 之后的状态照常以 hub 为准")
            drop(client, a)
            XCTAssertTrue(spin { receipt(client, "s9") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    // MARK: - 账目清理

    /// 送到 / 没收下之后，这条消息所有尝试的账清干净
    func testTerminalAnswerCleansBookkeeping() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "s10")
            sendUser(client, "s11")
            XCTAssertTrue(spin { wire.sends("s10").count == 1 && wire.sends("s11").count == 1 })
            let t10 = attemptOf(wire, "s10", 0)
            client.handleIncoming(ack("s10", t10), source: a)
            client.handleIncoming(statusFrame("s10", "delivered", attempt: t10), source: a)
            client.handleIncoming(text(["type": "error", "message_id": "s11", "reason": "tmux: x", "attempt": attemptOf(wire, "s11", 0) ?? "?"]), source: a)
            XCTAssertTrue(spin { receipt(client, "s11") != nil })
            settle(0.1)
            XCTAssertEqual(client.sendTracker.bookkeepingCount("s10"), 0)
            XCTAssertEqual(client.sendTracker.bookkeepingCount("s11"), 0)
        }
    }

    // MARK: - #5 清理先、登记后：当场失败，恰好一次

    /// listSessions 记下 A 之后、排登记之前换成了 B（清理先排进 handlersQueue）：登记时发现 A 已失效，当场失败，回调恰好一次
    func testRegistrationAfterCleanupFailsExactlyOnce() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            openTask(client)
            var swapped = false
            client.setRequestCapturedHookForTesting {
                guard !swapped else { return }
                swapped = true
                client.adoptTaskForTesting(self.makeTask(), url: self.hubURL)
            }
            var calls = 0
            var result: Result<[String], CCBridgeRemoteError>?
            client.listSessions { calls += 1; result = $0 }
            client.setRequestCapturedHookForTesting(nil)
            XCTAssertTrue(spin { calls > 0 })
            settle()
            XCTAssertEqual(calls, 1)
            if case .success? = result { XCTFail("死连接上的请求不该成功") }
        }
    }

    /// 连接断了：绑在它上面的每个请求回调恰好一次（不重复、不漏）
    func testBoundRequestsFailExactlyOnceOnDrop() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var calls: [String: Int] = [:]
            client.spawnSession("s12") { _ in calls["spawn", default: 0] += 1 }
            client.listSessions { _ in calls["list", default: 0] += 1 }
            client.listWindows { _ in calls["windows", default: 0] += 1 }
            client.openWindow { _ in calls["open", default: 0] += 1 }
            client.restoreWindow(code: "w") { _ in calls["restore", default: 0] += 1 }
            XCTAssertTrue(spin { ["spawn_cc", "list_sessions", "list_windows", "open_window", "restore_window"].allSatisfy { t in wire.all.contains { $0.type == t } } })
            settle(0.05)
            drop(client, a)
            XCTAssertTrue(spin { calls.count == 5 })
            client.handleIncoming(text(["type": "list_sessions_result", "sessions": []]), source: a)   // 迟到的旧回帧不再回调
            settle()
            XCTAssertEqual(calls, ["spawn": 1, "list": 1, "windows": 1, "open": 1, "restore": 1])
        }
    }
}
