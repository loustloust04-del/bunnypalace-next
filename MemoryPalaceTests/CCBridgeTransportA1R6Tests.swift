import XCTest
@testable import 记忆花园

/// A1 第六轮返工（sol / astra R6）：只有本机创建 / 明确跟随的尝试身份能证明「已被本地更新取代」，仅从 hub 观察 / 恢复的编号不挡同一条之后的结果；
/// 连接级带号锁定用别的消息独立证明；新连接首个带号帧之前走兜底的现状固定下来。每条都在 bug 存在时失败（变异验证见实验日志）。
/// 不碰网络：task 从不 resume，connect / startTask 在测试宿主被 TestHostIsolation 挡在发请求前。两条路（A1=1 / A1=0）各跑一遍。
final class CCBridgeTransportA1R6Tests: XCTestCase {
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
        suite = "CCBridgeTransportA1R6Tests.\(UUID().uuidString)"
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

    // MARK: - P1 仅观察到的编号不挡后续结果

    /// 同一条消息的两个外部 attempt 先后推进（本机没发过这条）：(a) 恢复 X 失败 → 外部 Y 送到 → 回执消失；
    /// (b) X 送到 → 外部 Y 失败 → 建回执。对照 (c)：本机确实发了新的一次，旧 X 的结果照旧不覆盖
    func testObservedAttemptsKeepAdvancing() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            let x = UUID().uuidString + ".3"
            let y = UUID().uuidString + ".9"
            // (a)
            client.handleIncoming(snapshotFrame([status("x1", "failed", retryable: true, reason: "可能已经进去了，看一眼终端再决定要不要重发", attempt: x)]), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("x1")?.state == .failed })
            client.handleIncoming(statusFrame("x1", "delivered", attempt: y), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("x1") == nil }, "别的设备重发送到了：回执要撤掉")
            // (b)
            client.handleIncoming(statusFrame("x2", "delivered", attempt: x), source: a)
            client.handleIncoming(statusFrame("x2", "failed", retryable: false, reason: "会话没了，这条没提交上", attempt: y), source: a)
            XCTAssertTrue(spin { receipt(client, "x2") == "会话没了，这条没提交上" }, "别的设备重新发的那次失败了：要建回执")
            // (c) 对照
            client.handleIncoming(snapshotFrame([status("x3", "failed", retryable: true, reason: "旧的", attempt: x)]), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("x3")?.state == .failed })
            sendUser(client, "x3")   // 本机重新生成：有了本地更新的一次
            XCTAssertTrue(spin { wire.sends("x3").count == 1 })
            XCTAssertTrue(spin { client.sendTracker.store.entry("x3") == nil })
            client.handleIncoming(statusFrame("x3", "failed", retryable: false, reason: "旧的", attempt: x), source: a)
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("x3"), "旧 X 的结果不覆盖本机新的一次")
            XCTAssertTrue(client.sendTracker.isAwaitingHub("x3"))
        }
    }

    // MARK: - 连接级带号锁定

    /// 用另一条消息的带号回话证明这条连接是新 hub；本消息（没被编号回答过、本地已给回执、按兜底本来会落）的无号状态不落
    func testNumberedLinkLockProvenByOtherMessage() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "b1")
            XCTAssertTrue(spin { wire.sends("b1").count == 1 })
            drop(client, a)
            XCTAssertTrue(spin { receipt(client, "b1") == CCBridgeWebSocketClient.userFrameUncertainReason })
            let b = openTask(client)
            sendUser(client, "bx")
            XCTAssertTrue(spin { wire.sends("bx").count == 1 })
            client.handleIncoming(ack("bx", attemptOf(wire, "bx", 0)), source: b)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("bx") })
            client.handleIncoming(statusFrame("b1", "delivered", attempt: nil), source: b)
            settle(0.1)
            XCTAssertEqual(receipt(client, "b1"), CCBridgeWebSocketClient.userFrameUncertainReason, "新 hub 的连接上不认无编号状态")
        }
    }

    /// 现状固定：新连接收到第一帧带号回话之前，无号状态按旧 hub 兜底落（w1 撤回执）；之后这条连接锁成新 hub，w2 的无号状态不落
    func testFallbackBeforeFirstNumberedFrame() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "w1")
            sendUser(client, "w2")
            XCTAssertTrue(spin { wire.sends("w1").count == 1 && wire.sends("w2").count == 1 })
            drop(client, a)
            XCTAssertTrue(spin { receipt(client, "w1") != nil && receipt(client, "w2") != nil })
            let b = openTask(client)
            client.handleIncoming(statusFrame("w1", "delivered", attempt: nil), source: b)
            XCTAssertTrue(spin { client.sendTracker.store.entry("w1") == nil }, "首个带号帧之前：走兜底")
            sendUser(client, "wx")
            XCTAssertTrue(spin { wire.sends("wx").count == 1 })
            client.handleIncoming(ack("wx", attemptOf(wire, "wx", 0)), source: b)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("wx") })
            client.handleIncoming(statusFrame("w2", "delivered", attempt: nil), source: b)
            settle(0.1)
            XCTAssertEqual(receipt(client, "w2"), CCBridgeWebSocketClient.userFrameUncertainReason, "锁定之后不再兜底")
        }
    }
}
