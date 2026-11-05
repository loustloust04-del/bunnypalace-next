import Combine
import XCTest
@testable import 记忆花园

/// A1 第二轮返工（sol R2：N1–N4、R1-1 残留、R1-5 残留）的回归测试。每条 P1 都在 bug 存在时失败：
/// 发送替身记下每帧实际发在哪个 task 上，completion 可以扣住、由测试决定什么时候以什么结果放；队列屏障固定交错。
/// 不碰网络：task 从不 resume，connect / startTask 在测试宿主被 TestHostIsolation 挡在发请求前。能两条路跑的都 A1=1 / A1=0 各跑一遍。
final class CCBridgeTransportA1R2Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clients: [CCBridgeWebSocketClient] = []
    private var session: URLSession!
    private let hubURL = URL(string: "ws://127.0.0.1:9/cc")!
    private let altURL = URL(string: "ws://127.0.0.2:9/cc")!
    private let otherHubURL = URL(string: "ws://127.0.0.3:9/cc")!

    /// 发送替身：记下每一帧发在哪个 task 上；hold 命中的帧扣住 completion（测试 release 时才回），其余异步回 nil
    final class Wire {
        struct Sent {
            let task: URLSessionWebSocketTask
            let obj: [String: Any]
            var type: String { obj["type"] as? String ?? "?" }
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

        /// 放出第 i 个扣住的 completion
        func release(_ i: Int, _ error: Error?) {
            lock.lock()
            let completion = held[i]
            lock.unlock()
            completion(error)
        }
    }

    override func setUp() {
        super.setUp()
        suite = "CCBridgeTransportA1R2Tests.\(UUID().uuidString)"
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

    private func frame(_ obj: [String: Any]) -> URLSessionWebSocketTask.Message { .string(text(obj)) }

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

    /// 不可点重发的「没送达」回执原因
    private func receipt(_ client: CCBridgeWebSocketClient, _ id: String) -> String? {
        guard let e = client.sendTracker.store.entry(id), e.state == .failed, !e.canRetry else { return nil }
        return e.visibleReason
    }

    private func sentIds(_ wire: Wire) -> [String?] { wire.sent("send").map { $0.obj["message_id"] as? String } }

    private func ack(_ id: String) -> String { text(["type": "ack", "message_id": id]) }

    private func status(_ id: String, _ state: String, retryable: Bool? = nil) -> String {
        var obj: [String: Any] = ["type": "send_status", "chat_id": "C1", "message_id": id, "session_name": "mp-cc", "status": state]
        if let retryable { obj["retryable"] = retryable }
        return text(obj)
    }

    // MARK: - N1 pending 绑目标 + 鉴权代次

    /// 探测期间排着的消息，connect 不先 disconnect 直接换了目标（同内嵌 hub 端口跟随）：回执失败，不迁移到新 hub
    func testPendingMessageFailsOnRetarget() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(urls: [hubURL, altURL])
            client.beginProbeRoundForTesting()
            sendUser(client, "n1-old")
            client.drainTransportForTesting()
            client.connect(urls: [otherHubURL], token: "tk")
            client.beginProbeRoundForTesting()
            client.adoptTaskForTesting(makeTask(otherHubURL), url: otherHubURL)
            XCTAssertTrue(spin { receipt(client, "n1-old") == CCBridgeWebSocketClient.userFrameNotSentReason })
            settle()
            XCTAssertTrue(wire.sent("send").isEmpty, "旧目标的消息不发给新 hub")
        }
    }

    /// 只换了口令（同一组地址）也算换了鉴权代次：排着的回执失败
    func testPendingMessageFailsOnTokenChange() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(urls: [hubURL, altURL], token: "t1")
            client.beginProbeRoundForTesting()
            sendUser(client, "n1-token")
            client.drainTransportForTesting()
            client.connect(urls: [hubURL, altURL], token: "t2")
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            XCTAssertTrue(spin { receipt(client, "n1-token") == CCBridgeWebSocketClient.userFrameNotSentReason })
            settle()
            XCTAssertTrue(wire.sent("send").isEmpty)
        }
    }

    /// 对照：同一目标重探（同一组候选、顺序不同也算）：排着的照旧等赢家，发在赢家上
    func testPendingMessageSurvivesSameTargetReprobe() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(urls: [hubURL, altURL], token: "t1")
            client.beginProbeRoundForTesting()
            sendUser(client, "n1-same")
            client.drainTransportForTesting()
            client.connect(urls: [altURL, hubURL], token: "t1")
            let a = makeTask()
            client.adoptTaskForTesting(a, url: hubURL)
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            XCTAssertTrue(wire.sent("send").first?.task === a)
            settle()
            XCTAssertNil(client.sendTracker.store.entry("n1-same"))
        }
    }

    // MARK: - N4 用户消息在 transport 上排序

    /// task 已对外可见、排着的消息还没 flush 时又发一条：先发的先到，同在这个 task 上（原来主线程看到 task 就直发，后发的抢到前面）
    func testNewMessageCannotOvertakePendingOnes() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.beginProbeRoundForTesting()
            sendUser(client, "q1")
            client.drainTransportForTesting()
            let a = makeTask()
            client.adoptTaskForTesting(a, url: hubURL, flushPending: false)
            sendUser(client, "q2")
            XCTAssertTrue(spin { wire.sent("send").count == 2 }, "\(sentIds(wire))")
            XCTAssertEqual(sentIds(wire), ["q1", "q2"])
            XCTAssertTrue(wire.sent("send").allSatisfy { $0.task === a })
        }
    }

    // MARK: - R1-1 残留：WS 写成功只算「已交出」，hub ack 才算收下

    /// 交出去、没等到 ack 连接就断了：「不确定」回执，不自动重发；ack 到之前气泡没有新徽章
    func testUnackedMessageGetsUncertainReceiptOnDisconnect() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "k1")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            settle(0.1)
            XCTAssertNil(client.sendTracker.store.entry("k1"), "已交出未 ack：气泡外观不变")
            client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)
            XCTAssertTrue(spin { receipt(client, "k1") == CCBridgeWebSocketClient.userFrameUncertainReason })
            settle()
            XCTAssertEqual(wire.sent("send").count, 1, "不自动重发")
        }
    }

    /// 来源连接上收到 ack 之后断线：不出回执
    func testAckedMessageNotMarkedOnDisconnect() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "k2")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.didReceive(.success(.string(ack("k2"))), on: a)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("k2") })
            client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)
            XCTAssertTrue(spin { !client.isConnected })
            settle()
            XCTAssertNil(client.sendTracker.store.entry("k2"))
        }
    }

    /// ack 只认来源连接：交给 A 的消息，别的连接上来的同 id ack 不算；A 断了照样「不确定」
    func testAckFromOtherConnectionIgnored() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "k3")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.handleIncoming(ack("k3"), source: makeTask())
            settle(0.1)
            XCTAssertTrue(client.sendTracker.isAwaitingHub("k3"))
            client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)
            XCTAssertTrue(spin { receipt(client, "k3") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    /// 换了 task 没有断线回调（手动重连 / 换网 / 不先 disconnect 的 connect）：被换下的连接上没 ack 的照样结算
    func testUnackedMessageSettledWhenTaskReplaced() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            openTask(client)
            sendUser(client, "k4")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            XCTAssertTrue(spin { receipt(client, "k4") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    /// 从没打开过的连接被换掉：交给它的消息「没发出去」
    func testUnopenedTaskReplacedGivesNotSentReceipt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            sendUser(client, "k5")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            XCTAssertTrue(spin { receipt(client, "k5") == CCBridgeWebSocketClient.userFrameNotSentReason })
        }
    }

    /// 换 task 后，A 上迟到的 ack 照样认：「不确定」回执撤掉
    func testLateAckFromReplacedConnectionClearsReceipt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "k6")
            XCTAssertTrue(spin { wire.sent("send").count == 1 })
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            XCTAssertTrue(spin { receipt(client, "k6") != nil })
            client.handleIncoming(ack("k6"), source: a)
            XCTAssertTrue(spin { client.sendTracker.store.entry("k6") == nil })
        }
    }

    /// A1：ack 已在解析队列里、随后连接断了——结算排在已收到的帧后面，ack 先认，不出回执
    func testAckQueuedBeforeDisconnectWinsA1() {
        let (client, wire) = makeClient(a1: true)
        let a = openTask(client)
        sendUser(client, "k7")
        XCTAssertTrue(spin { wire.sent("send").count == 1 })
        settle(0.05)
        var flips = 0   // 「不确定」回执哪怕一闪而过也算错（迟到的 ack 会撤回执，只看最终状态看不出顺序）
        let watch = client.sendTracker.store.membership.sink { if $0 == "k7" { flips += 1 } }
        defer { watch.cancel() }
        let release = client.holdParseForTesting()
        client.didReceive(.success(.string(ack("k7"))), on: a)
        client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)
        client.drainTransportForTesting()
        XCTAssertNil(client.currentTaskForTesting, "断线已处理（ack 还卡在解析）")
        release()
        client.drainPipelinesForTesting()
        XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("k7") })
        settle()
        XCTAssertNil(client.sendTracker.store.entry("k7"))
        XCTAssertEqual(flips, 0, "ack 先认，从没出过回执")
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 断线结算后重连：hub 的空快照不改「不确定」回执、已 ack 的也不凭空出条目；快照里列了就以 hub 为准
    func testReconnectSnapshotAfterSettlement() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            sendUser(client, "k8")
            sendUser(client, "k9")
            XCTAssertTrue(spin { wire.sent("send").count == 2 })
            client.didReceive(.success(.string(ack("k9"))), on: a)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("k9") })
            client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)
            XCTAssertTrue(spin { receipt(client, "k8") == CCBridgeWebSocketClient.userFrameUncertainReason })
            let b = openTask(client)
            client.didReceive(.success(frame(["type": "send_status_snapshot", "statuses": []])), on: b)
            settle()
            XCTAssertEqual(receipt(client, "k8"), CCBridgeWebSocketClient.userFrameUncertainReason)
            XCTAssertNil(client.sendTracker.store.entry("k9"))
            // R4 起：本地已给过回执的这一次，只认带它自己 attempt 的状态（新 hub 原样带回；不带的旧 hub 状态归属不明，不撤回执）
            let k8Attempt = wire.sent("send").first { $0.obj["message_id"] as? String == "k8" }?.obj["attempt"] as? String ?? "?"
            let listed: [String: Any] = ["type": "send_status_snapshot", "statuses": [["chat_id": "C1", "message_id": "k8", "session_name": "mp-cc", "status": "uncertain", "attempt": k8Attempt]]]
            client.didReceive(.success(frame(listed)), on: b)
            XCTAssertTrue(spin { client.sendTracker.store.entry("k8")?.state == .uncertain }, "hub 列了就以 hub 为准")
        }
    }

    // MARK: - N3 本地 completion 绑发送尝试

    /// hub 已经收下（ack）并 delivered：同一次尝试迟到的本地写入失败不再把它标成失败
    /// （R3 起：交出后、ack 之前到的状态算旧尝试的补账，所以先 ack）
    func testLateLocalFailureDoesNotOverrideHubDelivered() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            wire.hold = { $0.type == "send" }
            sendUser(client, "f1")
            XCTAssertTrue(spin { wire.heldCount == 1 })
            client.handleIncoming(ack("f1"), source: a)
            client.handleIncoming(status("f1", "delivered"), source: a)
            XCTAssertTrue(spin { !client.sendTracker.isAwaitingHub("f1") })
            wire.release(0, URLError(.networkConnectionLost))
            settle()
            XCTAssertNil(client.sendTracker.store.entry("f1"))
        }
    }

    /// hub 收下后给了 failed + 可重发：迟到的本地错误不能把重发按钮禁掉
    func testLateLocalFailureKeepsHubRetryable() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            wire.hold = { $0.type == "send" }
            sendUser(client, "f2")
            XCTAssertTrue(spin { wire.heldCount == 1 })
            client.handleIncoming(ack("f2"), source: a)
            client.handleIncoming(status("f2", "failed", retryable: true), source: a)
            XCTAssertTrue(spin { client.sendTracker.canRetry("f2") })
            wire.release(0, URLError(.networkConnectionLost))
            settle()
            XCTAssertTrue(client.sendTracker.canRetry("f2"))
        }
    }

    /// 同一个 id 已经开始新一次发送（重新生成复用节点 id）：上一次迟到的失败不污染新一次；新一次自己的失败照常结算
    func testLateFailureOfPreviousAttemptIgnored() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            openTask(client)
            wire.hold = { $0.type == "send" }
            sendUser(client, "f3")
            sendUser(client, "f3")
            XCTAssertTrue(spin { wire.heldCount == 2 })
            wire.release(0, URLError(.networkConnectionLost))
            settle()
            XCTAssertNil(client.sendTracker.store.entry("f3"), "上一次的失败不认")
            wire.release(1, URLError(.networkConnectionLost))
            XCTAssertTrue(spin { receipt(client, "f3") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    // MARK: - N2 source 带到 terminal_error / spawn / 无 request_id 的回帧

    private func terminalError(_ session: String) -> String {
        text(["type": "terminal_error", "session_name": session, "reason": "session_not_found"])
    }

    private func attach(_ client: CCBridgeWebSocketClient, _ session: String, onError: @escaping (String) -> Void = { _ in }) {
        client.attachTerminal(session: session, cols: 80, rows: 24, onInit: { _, _ in }, onChunk: { _ in }, onError: onError)
    }

    /// A1：A 的 terminal_error(session_not_found) 卡在解析队列；换上 B、B 打开、补订阅交给 B——放开后 A 的错误作废：
    /// 不在 B 上 spawn，也不报给界面（原来只核「当前 task + 最新 attach 记录」，两者都是 B，放行后在 B 上 spawn）
    func testStaleTerminalErrorDoesNotSpawnOnNewConnectionA1() {
        let (client, wire) = makeClient(a1: true)
        let a = openTask(client)
        var errors: [String] = []
        attach(client, "s1") { errors.append($0) }
        XCTAssertTrue(spin { wire.sent("terminal_attach").count == 1 })
        let release = client.holdParseForTesting()
        client.didReceive(.success(.string(terminalError("s1"))), on: a)
        client.drainTransportForTesting()
        let b = makeTask()
        client.adoptTaskForTesting(b, url: hubURL)
        didOpen(client, b)
        XCTAssertTrue(spin { wire.sent("terminal_attach").count == 2 }, "B 的补订阅已交给 B")
        XCTAssertTrue(wire.sent("terminal_attach").last?.task === b)
        release()
        client.drainPipelinesForTesting()
        settle()
        XCTAssertTrue(wire.sent("spawn_cc").isEmpty, "旧连接的错误不触发新连接上的 spawn")
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 同一契约两条路都核：来源 A 已被 B 取代（B 已补订阅）时才处理到的 A 的错误，作废
    func testStaleTerminalErrorIgnoredBothPaths() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var errors: [String] = []
            attach(client, "s2") { errors.append($0) }
            XCTAssertTrue(spin { wire.sent("terminal_attach").count == 1 })
            let b = makeTask()
            client.adoptTaskForTesting(b, url: hubURL)
            didOpen(client, b)
            XCTAssertTrue(spin { wire.sent("terminal_attach").count == 2 })
            client.handleIncoming(terminalError("s2"), source: a)
            client.handleIncoming(text(["type": "terminal_error", "session_name": "s2", "reason": "attach failed"]), source: a)
            client.drainPipelinesForTesting()
            settle()
            XCTAssertTrue(wire.sent("spawn_cc").isEmpty)
            XCTAssertTrue(errors.isEmpty)
        }
    }

    /// 对照：来源还是当前连接，session_not_found 自动 spawn 一次，发在这条连接上；spawn 成功后在它上面重新 attach
    func testLiveTerminalErrorSpawnsOnItsOwnConnection() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            attach(client, "s3")
            XCTAssertTrue(spin { wire.sent("terminal_attach").count == 1 })
            client.didReceive(.success(.string(terminalError("s3"))), on: a)
            XCTAssertTrue(spin { wire.sent("spawn_cc").count == 1 })
            XCTAssertTrue(wire.sent("spawn_cc").first?.task === a)
            client.didReceive(.success(frame(["type": "spawn_cc_ok", "session_name": "s3"])), on: a)
            XCTAssertTrue(spin { wire.sent("terminal_attach").count == 2 })
            XCTAssertTrue(wire.sent("terminal_attach").allSatisfy { $0.task === a })
        }
    }

    /// spawn 发在 A 上，回音到之前换成 B：A 迟到的 spawn_cc_ok 不当成功（不驱动新连接上的操作），按「连接断了」失败
    func testStaleSpawnReplyFailsInsteadOfApplying() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var result: Result<Void, CCBridgeRemoteError>?
            client.spawnSession("s9") { result = $0 }
            XCTAssertTrue(spin { wire.sent("spawn_cc").count == 1 })
            XCTAssertTrue(wire.sent("spawn_cc").first?.task === a)
            openTask(client)
            client.handleIncoming(text(["type": "spawn_cc_ok", "session_name": "s9"]), source: a)
            XCTAssertTrue(spin { result != nil })
            guard case .failure(let err)? = result else { return XCTFail("旧连接的成功不该被采用") }
            XCTAssertEqual(err.reason, CCBridgeWebSocketClient.staleReplyReason)
        }
    }

    /// list 回帧按来源认领：A 上发的请求，A 失效后才到的结果按失败回；B 上发的请求不会被 A 的结果吃掉，等 B 自己的
    func testListResultClaimedBySourceConnection() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var onA: Result<[String], CCBridgeRemoteError>?
            client.listSessions { onA = $0 }
            XCTAssertTrue(spin { wire.sent("list_sessions").count == 1 })
            let b = openTask(client)
            var onB: Result<[String], CCBridgeRemoteError>?
            client.listSessions { onB = $0 }
            XCTAssertTrue(spin { wire.sent("list_sessions").count == 2 })
            XCTAssertTrue(wire.sent("list_sessions").last?.task === b)
            client.handleIncoming(text(["type": "list_sessions_result", "sessions": ["old"]]), source: a)
            XCTAssertTrue(spin { onA != nil })
            if case .success? = onA { XCTFail("旧连接的结果不该被采用") }
            settle(0.1)
            XCTAssertNil(onB, "B 上的请求接着等自己的回帧")
            client.handleIncoming(text(["type": "list_sessions_result", "sessions": ["new"]]), source: b)
            XCTAssertTrue(spin { onB != nil })
            XCTAssertEqual(try? onB?.get(), ["new"])
        }
    }

    /// 窗口回帧同理：A 上发的 open_window，A 失效后才到的 window_opened 不当成功
    func testStaleWindowOpenedNotApplied() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var result: Result<String, CCBridgeRemoteError>?
            client.openWindow { result = $0 }
            XCTAssertTrue(spin { wire.sent("open_window").count == 1 })
            openTask(client)
            client.handleIncoming(text(["type": "window_opened", "code": "w1"]), source: a)
            XCTAssertTrue(spin { result != nil })
            if case .success? = result { XCTFail("旧连接的结果不该被采用") }
        }
    }

    // MARK: - R1-5 残留：Pocket 结果绑来源连接

    /// pocket 开着：执行器的结果（含异步回调）只经绑定来源的口发回来源连接；结果回来时来源已换 → 不发
    func testPocketResultOnlyGoesBackOnSourceConnection() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.pocketEnabledForTesting = true
            var replies: [([String: Any]) -> Void] = []
            client.pocketRunnerForTesting = { _, reply in replies.append(reply) }
            let a = openTask(client)
            client.didReceive(.success(frame(["type": "pocket_cmd", "id": "p1", "action": "js"])), on: a)
            client.didReceive(.success(frame(["type": "pocket_cmd", "id": "p2", "action": "js"])), on: a)
            XCTAssertTrue(spin { replies.count == 2 })
            replies[0](["type": "pocket_result", "id": "p1", "ok": true])
            XCTAssertTrue(spin { wire.sent("pocket_result").count == 1 })
            let b = makeTask()
            client.adoptTaskForTesting(b, url: hubURL)
            replies[1](["type": "pocket_result", "id": "p2", "ok": true])
            settle()
            XCTAssertEqual(wire.sent("pocket_result").map { $0.obj["id"] as? String }, ["p1"])
            XCTAssertTrue(wire.sent("pocket_result").allSatisfy { $0.task === a })
        }
    }
}
