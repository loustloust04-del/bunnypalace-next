import XCTest
@testable import 记忆花园

/// A1 第三轮返工（sol R3：#1–#6）的回归测试。P1 与 #4 #5 每条都在 bug 存在时失败（变异验证见实验日志）。
/// 不碰网络：task 从不 resume，connect / startTask 在测试宿主被 TestHostIsolation 挡在发请求前。能两条路跑的都 A1=1 / A1=0 各跑一遍。
final class CCBridgeTransportA1R3Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clients: [CCBridgeWebSocketClient] = []
    private var session: URLSession!
    private let hubURL = URL(string: "ws://127.0.0.1:9/cc")!
    private let otherHubURL = URL(string: "ws://127.0.0.3:9/cc")!

    /// 发送替身：记下每一帧发在哪个 task 上；hold 命中的帧扣住 completion（测试 release 时才回），其余异步回 nil
    final class Wire {
        struct Sent {
            let task: URLSessionWebSocketTask
            let obj: [String: Any]
            var type: String { obj["type"] as? String ?? "?" }
            var isRetry: Bool { obj["retry"] as? Bool == true }
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
        func sent(_ type: String) -> [Sent] { all.filter { $0.type == type } }
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
        suite = "CCBridgeTransportA1R3Tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        for c in clients {
            c.disconnect()
            c.setTransmitHookForTesting(nil)
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

    private func ack(_ id: String) -> String { text(["type": "ack", "message_id": id]) }

    private func status(_ id: String, _ state: String, retryable: Bool? = nil) -> [String: Any] {
        var obj: [String: Any] = ["chat_id": "C1", "message_id": id, "session_name": "mp-cc", "status": state]
        if let retryable { obj["retryable"] = retryable }
        return obj
    }

    private func statusFrame(_ id: String, _ state: String, retryable: Bool? = nil) -> String {
        var obj = status(id, state, retryable: retryable)
        obj["type"] = "send_status"
        return text(obj)
    }

    // MARK: - #1 旧 hub 回话不注销新尝试

    /// 同一连接：M 的第一次还没 ack 就重新生成了第二次；先到的 ack 是第一次的，第二次照旧等自己的回话，断线出「不确定」
    func testOldAckOnSameConnectionDoesNotSettleNewAttempt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "r1")
            sendUser(client, "r1")
            XCTAssertTrue(spin { wire.sent("send").count == 2 })
            client.handleIncoming(ack("r1"), source: a)
            settle(0.1)
            XCTAssertTrue(client.sendTracker.isAwaitingHub("r1"), "第一次的 ack 不算第二次的")
            drop(client, a)
            XCTAssertTrue(spin { receipt(client, "r1") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    /// A1，sol 原交错：第一次的 ack 卡在解析队列，第二次已交出；放开后旧 ack 只销旧账，断线照样给第二次回执
    func testOldAckQueuedInParseDoesNotSettleNewAttemptA1() {
        let (client, wire) = makeClient(a1: true)
        let a = openTask(client)
        sendUser(client, "r2")
        XCTAssertTrue(spin { wire.sent("send").count == 1 })
        let release = client.holdParseForTesting()
        client.didReceive(.success(.string(ack("r2"))), on: a)
        sendUser(client, "r2")
        XCTAssertTrue(spin { wire.sent("send").count == 2 })
        settle(0.05)
        release()
        client.drainPipelinesForTesting()
        settle(0.1)
        XCTAssertTrue(client.sendTracker.isAwaitingHub("r2"))
        drop(client, a)
        XCTAssertTrue(spin { receipt(client, "r2") == CCBridgeWebSocketClient.userFrameUncertainReason })
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 不同连接：A 上那次的 delivered 迟到，M 已在 B 上开始新的一次——只当旧尝试的补账，B 上这次照旧等回话
    func testOldStatusFromPreviousConnectionDoesNotTouchNewAttempt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "r3")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.handleIncoming(ack("r3"), source: a)
            let b = openTask(client)
            sendUser(client, "r3")
            XCTAssertTrue(spin { wire.sent("send").count == 2 })
            XCTAssertTrue(wire.sent("send").last?.task === b)
            client.handleIncoming(statusFrame("r3", "delivered"), source: a)
            settle(0.1)
            XCTAssertTrue(client.sendTracker.isAwaitingHub("r3"), "旧状态不删新尝试的待确认记录")
            drop(client, b)
            XCTAssertTrue(spin { receipt(client, "r3") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    /// 送达快照（hub 收到这次之前的样子）不结算还在等直接回话的这一次
    func testSnapshotDoesNotSettleInFlightAttempt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "r4")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.handleIncoming(text(["type": "send_status_snapshot", "statuses": [status("r4", "failed", retryable: true)]]), source: a)
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("r4"))
            XCTAssertTrue(client.sendTracker.isAwaitingHub("r4"))
        }
    }

    /// 对照：ack 之后到的状态照常以 hub 为准
    func testStatusAfterAckApplies() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "r5")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.handleIncoming(ack("r5"), source: a)
            client.handleIncoming(statusFrame("r5", "uncertain"), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("r5")?.state == .uncertain })
        }
    }

    // MARK: - #2 hub 明确拒收 → 消息级回执

    /// 带 message_id 的 error（send 分支写 tmux 抛错）：这一次结算为「电脑没收下」，不可重发，原因括在末尾
    func testHubRejectionGivesMessageReceipt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "x1")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.handleIncoming(text(["type": "error", "message_id": "x1", "reason": "tmux: boom"]), source: a)
            XCTAssertTrue(spin { receipt(client, "x1") == "电脑没收下这条，请重新发一遍（tmux: boom）" }, "\(receipt(client, "x1") ?? "nil")")
            drop(client, a)
            settle()
            XCTAssertEqual(receipt(client, "x1"), "电脑没收下这条，请重新发一遍（tmux: boom）", "断线不改成「不确定」")
            XCTAssertEqual(wire.sent("send").count, 1, "不自动重发")
        }
    }

    /// 核对失败后给旧版 app 的重复 error（带 session_name）不是对 send 的回话；拒收旧尝试的 error 不动新尝试
    func testOnlyDirectRejectionOfCurrentAttemptSettles() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "x2")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.handleIncoming(text(["type": "error", "message_id": "x2", "session_name": "mp-cc", "reason": "这条消息没送进 mp-cc：x"]), source: a)
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("x2"))
            XCTAssertTrue(client.sendTracker.isAwaitingHub("x2"))
            sendUser(client, "x2")
            XCTAssertTrue(spin { wire.sent("send").count == 2 })
            client.handleIncoming(text(["type": "error", "message_id": "x2", "reason": "tmux: old"]), source: a)
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("x2"), "拒收的是第一次")
            XCTAssertTrue(client.sendTracker.isAwaitingHub("x2"))
        }
    }

    func testHubRejectedReasonFormatting() {
        XCTAssertEqual(CCSendTracker.hubRejectedReason(nil), "电脑没收下这条，请重新发一遍")
        XCTAssertEqual(CCSendTracker.hubRejectedReason("  "), "电脑没收下这条，请重新发一遍")
        let long = String(repeating: "长", count: 100)
        XCTAssertEqual(CCSendTracker.hubRejectedReason(long), "电脑没收下这条，请重新发一遍（" + String(repeating: "长", count: 80) + "）")
    }

    // MARK: - #3 重发绑目标

    private func makeRetryable(_ client: CCBridgeWebSocketClient, _ wire: Wire, _ id: String, on task: URLSessionWebSocketTask) {
        sendUser(client, id)
        XCTAssertTrue(spin { wire.sent("send").contains { $0.obj["message_id"] as? String == id } })
        client.handleIncoming(ack(id), source: task)
        client.handleIncoming(statusFrame(id, "failed", retryable: true), source: task)
        XCTAssertTrue(spin { client.sendTracker.canRetry(id) })
    }

    /// 换了电脑（connect 不先 disconnect、换了候选集合）：旧目标上能点重发的改成不可重发，原帧不出门
    func testRetryableEntryDisabledOnRetarget() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            makeRetryable(client, wire, "t1", on: a)
            client.connect(url: otherHubURL)
            XCTAssertTrue(spin { receipt(client, "t1") == CCSendTracker.retargetReason }, "\(receipt(client, "t1") ?? "nil")")
            let b = openTask(client, url: otherHubURL)
            client.retrySend(messageId: "t1")
            settle()
            XCTAssertFalse(wire.all.contains { $0.task === b && $0.isRetry }, "旧目标的原帧不发给新电脑")
        }
    }

    /// 旧目标迟到的「可重发」状态（换目标之后才落地）：也不给重发资格
    func testLateRetryableStatusAfterRetargetNotRetryable() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            sendUser(client, "t2")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.handleIncoming(ack("t2"), source: a)
            client.connect(url: otherHubURL)
            openTask(client, url: otherHubURL)
            client.handleIncoming(statusFrame("t2", "failed", retryable: true), source: a)
            XCTAssertTrue(spin { receipt(client, "t2") == CCSendTracker.retargetReason })
        }
    }

    /// 对照：同一目标重连（换了 task、目标没变）保留重发资格；重发发在新连接上
    func testRetryKeptAcrossSameTargetReconnect() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            makeRetryable(client, wire, "t3", on: a)
            drop(client, a)
            XCTAssertTrue(spin { !client.isConnected })
            let b = openTask(client)
            XCTAssertTrue(client.sendTracker.canRetry("t3"))
            client.retrySend(messageId: "t3")
            XCTAssertTrue(spin { wire.all.contains { $0.task === b && $0.isRetry } })
            XCTAssertEqual(client.sendTracker.store.entry("t3")?.state, .uncertain)
        }
    }

    // MARK: - #6 本地发送失败按请求 / 尝试身份结算

    /// 重发的 completion 迟到报错：hub 已经回过话（收下 + 确认中），不能被改回「没连上、可重发」
    func testLateRetryFailureDoesNotOverrideHubAnswer() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)   // R4 起：原帧要绑上目标代次才能重发
            let a = openTask(client)
            makeRetryable(client, wire, "t4", on: a)
            wire.hold = { $0.isRetry }
            client.retrySend(messageId: "t4")
            XCTAssertTrue(spin { wire.heldCount == 1 })
            client.handleIncoming(ack("t4"), source: a)
            client.handleIncoming(statusFrame("t4", "uncertain"), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("t4")?.state == .uncertain })
            wire.release(0, URLError(.networkConnectionLost))
            settle()
            XCTAssertEqual(client.sendTracker.store.entry("t4")?.state, .uncertain)
        }
    }

    /// 同一连接上两次 list：第一次本地发送失败只结算第一次，第二次接着等自己的回帧
    func testRequestSendFailureOnlySettlesThatRequest() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            wire.hold = { $0.type == "list_sessions" }
            var r1: Result<[String], CCBridgeRemoteError>?
            var r2: Result<[String], CCBridgeRemoteError>?
            client.listSessions { r1 = $0 }
            client.listSessions { r2 = $0 }
            XCTAssertTrue(spin { wire.heldCount == 2 })
            wire.release(0, URLError(.networkConnectionLost))
            XCTAssertTrue(spin { r1 != nil })
            settle(0.1)
            XCTAssertNil(r2, "第二次不被第一次的发送失败连带")
            client.handleIncoming(text(["type": "list_sessions_result", "sessions": ["s"]]), source: a)
            XCTAssertTrue(spin { r2 != nil })
            XCTAssertEqual(try? r2?.get(), ["s"])
        }
    }

    /// A 上同名 spawn 的发送迟到报错，不能摘掉 B 上新登记的同名请求
    func testLateSpawnSendFailureDoesNotTakeNewRequest() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            openTask(client)
            wire.hold = { $0.type == "spawn_cc" }
            var onA: Result<Void, CCBridgeRemoteError>?
            client.spawnSession("s5") { onA = $0 }
            XCTAssertTrue(spin { wire.heldCount == 1 })
            let b = openTask(client)
            XCTAssertTrue(spin { onA != nil }, "A 失效时它上面的请求按失败收掉")
            var onB: Result<Void, CCBridgeRemoteError>?
            client.spawnSession("s5") { onB = $0 }
            XCTAssertTrue(spin { wire.heldCount == 2 })
            wire.release(0, URLError(.networkConnectionLost))
            settle(0.1)
            XCTAssertNil(onB)
            client.handleIncoming(text(["type": "spawn_cc_ok", "session_name": "s5"]), source: b)
            XCTAssertTrue(spin { onB != nil })
            if case .failure? = onB { XCTFail("B 自己的回帧应成功") }
        }
    }

    // MARK: - #4 主线程交付前再核来源

    /// 回帧在 handlersQueue 上认领时来源还活着，主线程轮到之前换了连接：成功结果改回失败，不静默丢
    func testClaimedSuccessRecheckedBeforeDelivery() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var list: Result<[String], CCBridgeRemoteError>?
            var spawn: Result<Void, CCBridgeRemoteError>?
            client.listSessions { list = $0 }
            client.spawnSession("s6") { spawn = $0 }
            XCTAssertTrue(spin { wire.sent("list_sessions").count == 1 && wire.sent("spawn_cc").count == 1 })
            settle(0.05)
            client.handleIncoming(text(["type": "list_sessions_result", "sessions": ["old"]]), source: a)
            client.handleIncoming(text(["type": "spawn_cc_ok", "session_name": "s6"]), source: a)
            client.drainPipelinesForTesting()   // 已认领、交付排进主队列，主线程还没轮到
            XCTAssertNil(list)
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            XCTAssertTrue(spin { list != nil && spawn != nil })
            if case .success? = list { XCTFail("旧连接的列表不交给新连接上下文") }
            if case .success? = spawn { XCTFail("旧连接的 spawn 成功不交给新连接上下文") }
        }
    }

    // MARK: - #5 连接失效主动结算绑定它的请求

    /// spawn / list / 窗口请求发出后没等到任何回帧连接就断了：全部按「连接断了」失败，不挂死
    func testBoundRequestsFailWhenConnectionDropsWithoutReply() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var results: [String: String] = [:]
            func note(_ key: String, _ failed: Bool) { results[key] = failed ? "failed" : "ok" }
            client.spawnSession("s7") { if case .failure = $0 { note("spawn", true) } else { note("spawn", false) } }
            client.listSessions { if case .failure = $0 { note("list", true) } else { note("list", false) } }
            client.listWindows { if case .failure = $0 { note("windows", true) } else { note("windows", false) } }
            client.openWindow { if case .failure = $0 { note("open", true) } else { note("open", false) } }
            client.restoreWindow(code: "w1") { if case .failure = $0 { note("restore", true) } else { note("restore", false) } }
            XCTAssertTrue(spin { ["spawn_cc", "list_sessions", "list_windows", "open_window", "restore_window"].allSatisfy { wire.sent($0).count == 1 } })
            settle(0.05)
            drop(client, a)
            XCTAssertTrue(spin { results.count == 5 }, "\(results)")
            XCTAssertEqual(Set(results.values), ["failed"])
        }
    }
}
