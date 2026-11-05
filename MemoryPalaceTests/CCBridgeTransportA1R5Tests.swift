import XCTest
@testable import 记忆花园

/// A1 第五轮返工（sol / astra R5）：「本地没有这一次的记录」不等于「旧结果」；重发被拒后跟正在跑的那一次；
/// 旧 hub 无歧义时真结果撤本地回执；连接编号清旧账；新 hub 连接不再走无编号兜底。每条都在 bug 存在时失败（变异验证见实验日志）。
/// 不碰网络：task 从不 resume，connect / startTask 在测试宿主被 TestHostIsolation 挡在发请求前。能两条路跑的都 A1=1 / A1=0 各跑一遍。
final class CCBridgeTransportA1R5Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clients: [CCBridgeWebSocketClient] = []
    private var session: URLSession!
    private let hubURL = URL(string: "ws://127.0.0.1:9/cc")!

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
        suite = "CCBridgeTransportA1R5Tests.\(UUID().uuidString)"
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

    private func makeTask() -> URLSessionWebSocketTask { session.webSocketTask(with: hubURL) }

    private func text(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    @discardableResult
    private func openTask(_ client: CCBridgeWebSocketClient) -> URLSessionWebSocketTask {
        let task = makeTask()
        client.adoptTaskForTesting(task, url: hubURL)
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
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

    /// 不可重发的「没送达」回执的小字
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

    private func status(_ id: String, _ state: String, retryable: Bool? = nil, reason: String? = nil, attempt: String?, active: String? = nil) -> [String: Any] {
        var obj: [String: Any] = ["chat_id": "C1", "message_id": id, "session_name": "mp-cc", "status": state]
        if let retryable { obj["retryable"] = retryable }
        if let reason { obj["reason"] = reason }
        if let attempt { obj["attempt"] = attempt }
        if let active { obj["active_attempt"] = active }
        return obj
    }

    private func statusFrame(_ id: String, _ state: String, retryable: Bool? = nil, reason: String? = nil, attempt: String?, active: String? = nil) -> String {
        var obj = status(id, state, retryable: retryable, reason: reason, attempt: attempt, active: active)
        obj["type"] = "send_status"
        return text(obj)
    }

    private func snapshotFrame(_ items: [[String: Any]]) -> String {
        text(["type": "send_status_snapshot", "statuses": items])
    }

    /// 第 n 次发送（含重发）帧里 app 给的 attempt
    private func attemptOf(_ wire: Wire, _ id: String, _ n: Int) -> String? {
        let all = wire.sends(id)
        return all.count > n ? all[n].attempt : nil
    }

    // MARK: - P1-a 本地没有这一次的记录 ≠ 旧结果

    /// app 重启（tracker 是空的）后连上同一台电脑：快照里带号的失败、之后实时推来的带号状态、结果不明的 error 都要恢复成消息级回执；
    /// 原帧不在 → 不可重发
    func testNumberedResultsWithoutLocalHistoryAreRestored() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            let foreign = UUID().uuidString + ".7"   // 上一个进程给的编号
            client.handleIncoming(snapshotFrame([status("p1", "failed", retryable: true, reason: "可能已经进去了，看一眼终端再决定要不要重发", attempt: foreign)]), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("p1")?.state == .failed }, "快照里的失败不能被吞")
            XCTAssertFalse(client.sendTracker.canRetry("p1"), "原帧不在，不可重发")
            XCTAssertEqual(receipt(client, "p1"), "可能已经进去了，看一眼终端再决定要不要重发。原消息没留住，请重新发一遍")
            client.handleIncoming(statusFrame("p2", "failed", retryable: false, reason: "会话没了，这条没提交上", attempt: foreign), source: a)
            XCTAssertTrue(spin { receipt(client, "p2") == "会话没了，这条没提交上" })
            client.handleIncoming(text(["type": "error", "message_id": "p3", "session_name": "mp-cc", "uncertain": true, "reason": "tmux 卡住了", "attempt": foreign]), source: a)
            XCTAssertTrue(spin { receipt(client, "p3") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    /// 同一进程：M 收到 ack 后、真正注入前，又发了 400 多条，M 的重型账被裁掉；之后 M 的带号失败（实时、快照）照样认得出、出回执
    func testTerminalAfterRecordTrimmingStillClaimed() {
        let t = CCSendTracker()
        t.targetChanged(1)
        let link = NSObject()
        let m = t.didSend("m", frame: ["content": "x"])
        t.didHandOff(m, to: link, epoch: 1)
        t.didHubAnswer("m", .accepted, attempt: m.wire, on: link)
        for i in 0..<(2 * CCSendStatusStore.maxEntries + 20) {
            let n = t.didSend("n\(i)", frame: ["content": "y"])
            t.didHandOff(n, to: link, epoch: 1)
            t.didHubAnswer("n\(i)", .accepted, attempt: n.wire, on: link)
        }
        XCTAssertEqual(t.bookkeepingCount("m"), 0, "前提：M 的重型账已被裁掉")
        XCTAssertLessThanOrEqual(t.recordCount, 2 * CCSendStatusStore.maxEntries)
        t.didReceive(CCSendStatus(chatId: "C1", messageId: "m", sessionName: "mp-cc", state: .failed, reason: "可能已经进去了", retryable: true, attempt: m.wire), on: link)
        XCTAssertEqual(t.store.entry("m")?.state, .failed, "裁掉账之后到的终态不能被吞")
        XCTAssertTrue(t.canRetry("m"), "原帧还在、目标没变：照常可重发")
        // 快照同理
        let k = t.didSend("k", frame: ["content": "z"])
        t.didHandOff(k, to: link, epoch: 1)
        t.didHubAnswer("k", .accepted, attempt: k.wire, on: link)
        for i in 0..<(2 * CCSendStatusStore.maxEntries + 20) {
            let n = t.didSend("q\(i)", frame: ["content": "y"])
            t.didHandOff(n, to: link, epoch: 1)
            t.didHubAnswer("q\(i)", .accepted, attempt: n.wire, on: link)
        }
        XCTAssertEqual(t.bookkeepingCount("k"), 0)
        t.didReceiveSnapshot([CCSendStatus(chatId: "C1", messageId: "k", sessionName: "mp-cc", state: .failed, reason: "x", retryable: false, attempt: k.wire)], on: link)
        XCTAssertEqual(t.store.entry("k")?.state, .failed)
        // 对照：已知被本地更新的一次取代的旧编号照旧不落
        let k2 = t.didSend("k", frame: ["content": "z2"])
        t.didHandOff(k2, to: link, epoch: 1)
        t.didReceive(CCSendStatus(chatId: "C1", messageId: "k", sessionName: "mp-cc", state: .failed, reason: "旧", retryable: false, attempt: k.wire), on: link)
        XCTAssertNil(t.store.entry("k"), "旧尝试的结果不动新的一次")
    }

    // MARK: - P1-b 重发被「上一次还在跑」拒掉后，跟正在跑的那一次

    /// R1 已被 hub 接受、本地写入报错（显示可重发）→ 点 R2 → hub 拒（带 active_attempt=R1）→ R1 真送到：气泡不能停在「确认中」/ 之后被快照改成失败
    func testActiveRejectionFollowsActiveAttempt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            sendUser(client, "q1")
            XCTAssertTrue(spin { wire.sends("q1").count == 1 })
            let original = attemptOf(wire, "q1", 0)
            client.handleIncoming(ack("q1", original), source: a)
            client.handleIncoming(statusFrame("q1", "failed", retryable: true, attempt: original), source: a)
            XCTAssertTrue(spin { client.sendTracker.canRetry("q1") })
            wire.hold = { $0.isRetry }
            client.retrySend(messageId: "q1")
            XCTAssertTrue(spin { wire.heldCount == 1 })
            let r1 = wire.all.filter { $0.isRetry }[0].attempt
            wire.release(0, URLError(.networkConnectionLost))   // 本地写入报错（其实已经到了 hub）
            XCTAssertTrue(spin { client.sendTracker.canRetry("q1") })
            wire.hold = { _ in false }
            client.retrySend(messageId: "q1")
            XCTAssertTrue(spin { wire.all.filter { $0.isRetry }.count == 2 })
            let r2 = wire.all.filter { $0.isRetry }[1].attempt
            XCTAssertNotEqual(r1, r2)
            client.handleIncoming(statusFrame("q1", "uncertain", retryable: false, reason: "这条还在核对 / 重发中", attempt: r2, active: r1), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("q1")?.state == .uncertain })
            client.handleIncoming(statusFrame("q1", "delivered", retryable: false, attempt: r1), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("q1") == nil }, "R1 的送达要认领")
            client.handleIncoming(snapshotFrame([]), source: a)
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("q1"), "已送达的不被快照改成失败")
        }
    }

    // MARK: - P1-c 旧 hub：无歧义时真结果撤本地回执

    /// 旧 hub（回话都不带编号）收下了 c1、ack 因断线丢了 → 本地「不确定」；重连后快照说在核对、随后推来 delivered：回执撤掉。
    /// 对照：同一 id 有两次都可能到过 hub（有歧义）→ 保守，不撤
    func testOldHubRealResultClearsLocalReceiptWhenUnambiguous() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "c1")
            sendUser(client, "c2")
            sendUser(client, "c2")
            XCTAssertTrue(spin { wire.sends("c1").count == 1 && wire.sends("c2").count == 2 })
            drop(client, a)
            XCTAssertTrue(spin { receipt(client, "c1") == CCBridgeWebSocketClient.userFrameUncertainReason && receipt(client, "c2") == CCBridgeWebSocketClient.userFrameUncertainReason })
            let b = openTask(client)
            client.handleIncoming(snapshotFrame([status("c1", "uncertain", retryable: false, attempt: nil)]), source: b)
            XCTAssertTrue(spin { client.sendTracker.store.entry("c1")?.state == .uncertain }, "hub 还在核对：不再显示本地的「不确定」")
            client.handleIncoming(statusFrame("c1", "delivered", attempt: nil), source: b)
            client.handleIncoming(statusFrame("c2", "delivered", attempt: nil), source: b)
            XCTAssertTrue(spin { client.sendTracker.store.entry("c1") == nil }, "真送到了：撤掉本地回执")
            settle(0.1)
            XCTAssertEqual(receipt(client, "c2"), CCBridgeWebSocketClient.userFrameUncertainReason, "两次都可能到过 hub，分不清是哪次的：保守")
        }
    }

    // MARK: - 附：连接级协议模式锁定

    /// 这条连接回过带编号的话（新 hub）：之后不带编号的状态不覆盖已按编号回答的当前记录；带编号的照常
    func testNumberedConnectionIgnoresUnnumberedStatus() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "z1")
            XCTAssertTrue(spin { wire.sends("z1").count == 1 })
            let mine = attemptOf(wire, "z1", 0)
            client.handleIncoming(ack("z1", mine), source: a)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("z1") })
            client.handleIncoming(statusFrame("z1", "failed", retryable: false, reason: "无编号", attempt: nil), source: a)
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("z1"), "新 hub 的连接上不认无编号状态")
            client.handleIncoming(statusFrame("z1", "failed", retryable: false, reason: "有编号", attempt: mine), source: a)
            XCTAssertTrue(spin { receipt(client, "z1") == "有编号" })
        }
    }

    // MARK: - P2 #6 task 释放后旧账照样清

    /// A 上没回话的消息、断线后 A 的 task 真正释放；B 再断时，A 留下的等回话账按连接编号清掉（不依赖弱引用还能解包）
    func testLostLinkCleanupAfterTaskReleased() {
        let t = CCSendTracker()
        weak var released: NSObject?
        autoreleasepool {
            let a = NSObject()
            released = a
            let m = t.didSend("m", frame: ["content": "x"])
            t.didHandOff(m, to: a)
            t.linkLost(a, reason: "断了")
        }
        XCTAssertNil(released, "前提：A 已经释放")
        XCTAssertEqual(t.inFlightCount, 1)
        let b = NSObject()
        let n = t.didSend("n", frame: ["content": "y"])
        t.didHandOff(n, to: b)
        t.linkLost(b, reason: "断了")
        XCTAssertEqual(t.inFlightCount, 1, "A 留下的旧账清掉，只剩 B 上的")
        XCTAssertNotNil(t.store.entry("m"), "回执照旧留着")
    }
}
