import XCTest
@testable import 记忆花园

/// A1 返工（sol R1 十二条）：发送替身 + 队列屏障把交错情形固定下来，断言实际用的是哪条连接、事件顺序、cursor、ACK、消息结果。
/// 不碰网络：task 从不 resume（127.0.0.1:9 discard 端口兜底），所有帧被替身拦下；connect / startTask 在测试宿主被 TestHostIsolation 挡在发请求前。
/// 能两条路都跑的用 `bothPaths`（A1=1 transport 串行队列 / A1=0 主线程原路径）；要卡 transport 的只跑 A1（A1=0 的 transport 是主线程）。
final class CCBridgeTransportA1R1Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clients: [CCBridgeWebSocketClient] = []
    private var session: URLSession!
    private let hubURL = URL(string: "ws://127.0.0.1:9/cc")!

    /// 发送替身：记下每一帧发在哪个 task 上；`result` 决定回什么，completion 异步回（同真 URLSession）
    final class Wire {
        struct Sent {
            let task: URLSessionWebSocketTask
            let obj: [String: Any]
            var type: String { obj["type"] as? String ?? "?" }
        }
        private let lock = NSLock()
        private var items: [Sent] = []
        var result: (Sent) -> Error? = { _ in nil }
        /// 帧记下之后、completion 之前同步调（造「发到一半换连接」）
        var onSend: ((Sent) -> Void)?

        func install(on client: CCBridgeWebSocketClient) {
            client.setTransmitHookForTesting { [weak self] task, text, completion in
                guard let self else { completion(nil); return }
                let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                let sent = Sent(task: task, obj: obj)
                self.lock.lock()
                self.items.append(sent)
                let result = self.result
                let onSend = self.onSend
                self.lock.unlock()
                onSend?(sent)
                let err = result(sent)
                DispatchQueue.global().async { completion(err) }
            }
        }

        var all: [Sent] { lock.lock(); defer { lock.unlock() }; return items }
        func sent(_ type: String) -> [Sent] { all.filter { $0.type == type } }
        func types(on task: URLSessionWebSocketTask) -> [String] { all.filter { $0.task === task }.map(\.type) }
    }

    override func setUp() {
        super.setUp()
        suite = "CCBridgeTransportA1R1Tests.\(UUID().uuidString)"
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
            for c in clients { c.disconnect() }   // 上一条路的退避定时器别漏到下一条路的计数里
            settle(0.05)
        }
    }

    private func makeTask() -> URLSessionWebSocketTask { session.webSocketTask(with: hubURL) }

    private func text(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func frame(_ obj: [String: Any]) -> URLSessionWebSocketTask.Message { .string(text(obj)) }

    private func didOpen(_ client: CCBridgeWebSocketClient, _ task: URLSessionWebSocketTask) {
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
    }

    /// 装上并打开一个 task，等主线程应用完「已连上」
    @discardableResult
    private func openTask(_ client: CCBridgeWebSocketClient) -> URLSessionWebSocketTask {
        let task = makeTask()
        client.adoptTaskForTesting(task, url: hubURL)
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

    // MARK: - #4 终端输入 / 补订阅绑一个 task

    /// 一次输入的四片：发完第一片就换了连接，剩下三片仍在原 task 上，新连接上一片都没有
    func testTerminalInputChunksStayOnOneTaskAcrossSwap() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            let b = makeTask()
            var swapped = false
            wire.onSend = { sent in
                guard sent.type == "terminal_input", !swapped else { return }
                swapped = true
                client.adoptTaskForTesting(b, url: self.hubURL)
            }
            let bytes = Data(repeating: 0x61, count: CCBridgeWebSocketClient.terminalInputChunkLimit * 3 + 10)
            var result: Error?? = .none
            client.sendTerminalInput(session: "s1", bytes: bytes) { result = .some($0) }
            XCTAssertTrue(spin { result != nil })
            XCTAssertNil(result ?? nil)
            let inputs = wire.sent("terminal_input")
            XCTAssertEqual(inputs.count, 4)
            XCTAssertTrue(inputs.allSatisfy { $0.task === a }, "分片全在原连接上")
            XCTAssertFalse(wire.types(on: b).contains("terminal_input"))
            XCTAssertTrue(client.currentTaskForTesting === b)
        }
    }

    /// 那条连接中途失效：completion 报错，不自动重发（总片数不变、新连接上没有补发）
    func testTerminalInputFailureReportsWithoutResend() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            var n = 0
            wire.result = { sent in
                guard sent.type == "terminal_input" else { return nil }
                n += 1
                return n == 2 ? URLError(.networkConnectionLost) : nil
            }
            let bytes = Data(repeating: 0x62, count: CCBridgeWebSocketClient.terminalInputChunkLimit * 2 + 1)
            var result: Error?? = .none
            client.sendTerminalInput(session: "s1", bytes: bytes) { result = .some($0) }
            XCTAssertTrue(spin { result != nil })
            XCTAssertNotNil(result ?? nil, "任一片失败要报出来")
            settle()
            let inputs = wire.sent("terminal_input")
            XCTAssertEqual(inputs.count, 3, "不自动重发")
            XCTAssertTrue(inputs.allSatisfy { $0.task === a })
        }
    }

    // MARK: - #1 用户消息永远不静默丢

    private func sendUser(_ client: CCBridgeWebSocketClient, _ id: String) {
        client.sendUserMessage(chatId: "C1", messageId: id, content: "hi", user: "u", session: nil, replyTo: nil, attachments: [])
    }

    private func receipt(_ client: CCBridgeWebSocketClient, _ id: String) -> String? {
        guard let e = client.sendTracker.store.entry(id), e.state == .failed, !e.canRetry else { return nil }
        return e.visibleReason
    }

    /// 断桥卡 / 发消息前的 reconnectNow 同步建立尝试：返回时这一轮已经起了（测试宿主挡在发请求前）；
    /// 紧跟着的消息既没有 task 也没有在跑的探测 → 当场给「没发出去」回执，不静默丢
    func testReconnectNowIsSyncAndFollowingMessageGetsReceipt() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let before = TestHostIsolation.blockedCount(.hub)
            client.reconnectNow()
            XCTAssertEqual(TestHostIsolation.blockedCount(.hub), before + 1, "reconnectNow 返回时这次尝试已经建立")
            sendUser(client, "m-none")
            XCTAssertTrue(spin { receipt(client, "m-none") == CCBridgeWebSocketClient.userFrameNotSentReason })
            XCTAssertTrue(wire.sent("send").isEmpty)
        }
    }

    /// 多候选探测期间发的消息排着，赢家的 task 一建好就发在它上面；没有失败回执
    func testMessageDuringProbeWaitsForWinnerTask() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.beginProbeRoundForTesting()
            sendUser(client, "m-wait1")
            sendUser(client, "m-wait2")
            settle(0.1)
            XCTAssertTrue(wire.sent("send").isEmpty, "还没有 task，不能发也不能丢")
            let a = makeTask()
            client.adoptTaskForTesting(a, url: hubURL)
            XCTAssertTrue(spin { wire.sent("send").count == 2 })
            let sends = wire.sent("send")
            XCTAssertEqual(sends.map { $0.obj["message_id"] as? String }, ["m-wait1", "m-wait2"], "按先后")
            XCTAssertTrue(sends.allSatisfy { $0.task === a })
            settle()
            XCTAssertNil(client.sendTracker.store.entry("m-wait1"))
        }
    }

    /// 这一轮探测全败 / 手动断开：排着的消息回执失败
    func testPendingMessagesFailWhenAttemptEnds() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.beginProbeRoundForTesting()
            sendUser(client, "m-allfail")
            client.failProbeRoundForTesting()
            XCTAssertTrue(spin { receipt(client, "m-allfail") == CCBridgeWebSocketClient.userFrameNotSentReason })
            client.beginProbeRoundForTesting()
            sendUser(client, "m-manual")
            client.disconnect()
            XCTAssertTrue(spin { receipt(client, "m-manual") == CCBridgeWebSocketClient.userFrameNotSentReason })
            XCTAssertTrue(wire.sent("send").isEmpty)
        }
    }

    /// 交给 task 之后发送报错：没打开过的 task = 肯定没到；打开过的 = 不确定。两种话分开
    func testSendErrorReceiptDependsOnWhetherTaskOpened() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            wire.result = { $0.type == "send" ? URLError(.networkConnectionLost) : nil }
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            sendUser(client, "m-unopened")
            XCTAssertTrue(spin { receipt(client, "m-unopened") == CCBridgeWebSocketClient.userFrameNotSentReason })
            openTask(client)
            sendUser(client, "m-opened")
            XCTAssertTrue(spin { receipt(client, "m-opened") == CCBridgeWebSocketClient.userFrameUncertainReason })
        }
    }

    // MARK: - #2 断线只拆造成断线的那个 task

    /// A1：A 的收帧失败和「换上 B」先后排进 transport（屏障卡着），放开后 A 的断线不能把 B 摘掉
    func testDisconnectOfOldTaskKeepsSwappedInTaskA1() {
        let (client, _) = makeClient(a1: true)
        let a = openTask(client)
        let b = makeTask()
        let release = client.holdTransportForTesting()
        client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)   // 排在屏障后
        client.adoptTaskForTesting(b, url: hubURL, async: true)               // 再排一个换 task
        release()
        client.drainTransportForTesting()
        XCTAssertTrue(client.currentTaskForTesting === b, "A 的断线处理只拆 A")
        XCTAssertTrue(spin { !client.isConnected }, "A 的「断了」快照照样落到主线程")
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// A1=0：A 的收帧失败从委托队列来、排进主线程；排队期间主线程换上 B——轮到时身份对不上，B 留着
    func testDisconnectOfOldTaskKeepsSwappedInTaskMainPath() {
        let (client, _) = makeClient(a1: false)
        let a = openTask(client)
        let b = makeTask()
        let queued = DispatchSemaphore(value: 0)   // 不用 expectation：XCTWaiter 会转主 RunLoop，把排着的断线处理提前跑掉
        DispatchQueue.global().async {
            client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)
            queued.signal()
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 2), .success)   // 断线处理已 main.async 排着，主线程还没轮到
        client.adoptTaskForTesting(b, url: hubURL)
        settle()
        XCTAssertTrue(client.currentTaskForTesting === b)
        XCTAssertNil(client.lastError, "A 的断线作废，没走断线处理")
    }

    /// 同一次断连两个回调（收帧失败 + didClose）：只处理一次
    func testDuplicateDisconnectCallbacksHandledOnce() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            let a = openTask(client)
            client.didReceive(.failure(URLError(.networkConnectionLost)), on: a)
            client.urlSession(session, webSocketTask: a, didCloseWith: .goingAway, reason: nil)
            XCTAssertTrue(spin { !client.isConnected })
            settle()
            XCTAssertNil(client.currentTaskForTesting)
            XCTAssertEqual(client.lastError, URLError(.networkConnectionLost).localizedDescription, "第二个回调没再覆盖")
        }
    }

    // MARK: - #3「已打开」绑 task

    /// A 打开过、换上 B 正在握手：B 的看门狗照样到点掐掉 B（原来被 A 留下的 socketOpen 挡住）
    func testWatchdogFiresForNewHandshakeAfterSwap() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            client.connectTimeoutForTesting = 0.15
            openTask(client)
            let b = makeTask()
            client.adoptTaskForTesting(b, url: hubURL, watchdog: true)
            XCTAssertTrue(spin { client.currentTaskForTesting == nil }, "B 没打开，看门狗应掐掉")
            XCTAssertTrue(spin { client.lastError == "connect timeout" })
        }
    }

    /// B 打开了：看门狗不掐
    func testWatchdogSparesOpenedTask() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            client.connectTimeoutForTesting = 0.15
            let b = makeTask()
            client.adoptTaskForTesting(b, url: hubURL, watchdog: true)
            didOpen(client, b)
            XCTAssertTrue(spin { client.isConnected })
            settle(0.4)
            XCTAssertTrue(client.currentTaskForTesting === b)
        }
    }

    /// A 打开过、换上 B 还在握手（主线程 isConnected 还停在 A 的 true）：手动重连照样能起（原来被 socketOpen 挡掉）
    func testManualReconnectNotBlockedBySwappedTask() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            client.connect(url: hubURL)   // 有候选地址（测试宿主挡在发请求前）
            openTask(client)
            client.adoptTaskForTesting(makeTask(), url: hubURL)
            XCTAssertTrue(client.isConnected, "前提：换 task 不清 isConnected（原有行为）")
            let before = TestHostIsolation.blockedCount(.hub)
            client.reconnectNow()
            XCTAssertTrue(spin { TestHostIsolation.blockedCount(.hub) > before }, "重连起了一轮（测试宿主在发请求前挡下）")
            XCTAssertNil(client.currentTaskForTesting, "半死的 B 已摘掉")
        }
    }

    /// 当前 task 真打开着：手动重连什么都不做
    func testManualReconnectNoopWhenCurrentTaskOpen() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            let before = TestHostIsolation.blockedCount(.hub)
            client.reconnectNow()
            settle()
            XCTAssertEqual(TestHostIsolation.blockedCount(.hub), before)
            XCTAssertTrue(client.currentTaskForTesting === a)
        }
    }

    // MARK: - #5 帧带着来源连接走到最终应用；ACK 绑来源 · #10 connect_report 绑这次连上的 task

    /// 测试方法都跑在主线程
    private func phase(_ chat: String) -> CCSessionPhase? {
        MainActor.assumeIsolated { CCSessionPhaseStore.shared.phase(for: chat) }
    }

    /// 连接现状类帧（hello / 送达快照 / 会话阶段）已经排到主线程、还没应用时连接换了：丢掉，不改现状
    func testStaleConnectionStateFramesAreDropped() {
        bothPaths { a1 in
            defaults.removeObject(forKey: "ccReplyCursorTs")   // 每条路从没收过开始（client 建时读 cursor）
            let (client, _) = makeClient(a1: a1)
            let a = openTask(client)
            client.sendTracker.didReceive(CCSendStatus(chatId: "C1", messageId: "m-pending", sessionName: "s", state: .uncertain, reason: nil))
            let chat = "stale-\(UUID().uuidString.prefix(8))"
            var replies: [String] = []
            client.onProactiveMessage = { _, _, _, _, _, _, ccId, _, _ in replies.append(ccId ?? "-") }
            let rid = "r5-\(UUID().uuidString.prefix(8))"
            client.didReceive(.success(frame(["type": "hello"])), on: a)
            client.didReceive(.success(frame(["type": "send_status_snapshot", "statuses": []])), on: a)
            client.didReceive(.success(frame(["type": "session_phase", "session_name": "mp-cc", "chat_id": chat, "phase": "working"])), on: a)
            client.didReceive(.success(replyFrame(rid)), on: a)
            client.drainPipelinesForTesting()            // 都已排到主线程，主线程还没轮到
            client.adoptTaskForTesting(makeTask(), url: hubURL)   // 连接换了
            settle()
            XCTAssertNil(client.hubInfo, "旧连接的 hello 不应用")
            XCTAssertFalse(client.hubInfoIsCurrent)
            XCTAssertEqual(client.sendTracker.store.entry("m-pending")?.state, .uncertain, "旧连接的快照不拿来对账")
            XCTAssertNil(phase(chat))
            // 持久的 reply 不按连接作废：照常落地、推进 cursor（重放 + 去重兜不重）
            XCTAssertEqual(replies, ["s_\(rid)"])
            XCTAssertEqual(defaults.double(forKey: "ccReplyCursorTs"), 1_700_000_000_000)
        }
    }

    /// 对照：来源连接还是当前连接时照常应用
    func testLiveConnectionStateFramesApply() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            let a = openTask(client)
            client.sendTracker.didReceive(CCSendStatus(chatId: "C1", messageId: "m-pending", sessionName: "s", state: .uncertain, reason: nil))
            let chat = "live-\(UUID().uuidString.prefix(8))"
            client.didReceive(.success(frame(["type": "hello"])), on: a)
            client.didReceive(.success(frame(["type": "send_status_snapshot", "statuses": []])), on: a)
            client.didReceive(.success(frame(["type": "session_phase", "session_name": "mp-cc", "chat_id": chat, "phase": "working"])), on: a)
            XCTAssertTrue(spin { client.currentHubInfo != nil })
            XCTAssertTrue(spin { client.sendTracker.store.entry("m-pending")?.state == .failed }, "hub 那边没记录 → 没送达")
            XCTAssertTrue(spin { phase(chat) != nil })
        }
    }

    /// 命令结果（ACK 类）只发回帧的来源连接：处理期间换了连接，也不借新连接发
    func testAckGoesBackOnSourceConnection() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            client.onTwitterCmd = { frame in ["type": TwitterCCBridge.resultType, "id": frame["id"] as? String ?? "", "ok": true] }
            client.didReceive(.success(frame(["type": TwitterCCBridge.commandType, "id": "cmd-1"])), on: a)
            client.drainPipelinesForTesting()
            let b = makeTask()
            client.adoptTaskForTesting(b, url: hubURL)
            XCTAssertTrue(spin { !wire.sent(TwitterCCBridge.resultType).isEmpty })
            let results = wire.sent(TwitterCCBridge.resultType)
            XCTAssertEqual(results.count, 1)
            XCTAssertTrue(results.first?.task === a, "回到来源连接")
            XCTAssertFalse(wire.types(on: b).contains(TwitterCCBridge.resultType))
        }
    }

    /// A1：快照排在主队列里时连接换了——connect_report 不借新连接发，只记本地诊断
    func testStaleConnectReportIsNotSentOnNewConnection() {
        let (client, wire) = makeClient(a1: true)
        var dropped: [String: Any]?
        var sent: [String: Any]?
        client.onConnectReportDroppedForTesting = { dropped = $0 }
        client.onConnectReportForTesting = { sent = $0 }
        client.connect(url: hubURL)   // 开一段（测试宿主挡在发请求前）
        let a = makeTask()
        client.adoptTaskForTesting(a, url: hubURL)
        didOpen(client, a)                       // transport 上：client_info 发出、快照（带报告）排进主队列
        let b = makeTask()
        client.adoptTaskForTesting(b, url: hubURL)   // 主线程还没轮到快照，连接已换
        XCTAssertTrue(spin { dropped != nil })
        XCTAssertNil(sent)
        XCTAssertTrue(wire.sent("connect_report").isEmpty, "旧尝试的报告哪条连接都不发")
        XCTAssertEqual(wire.sent("client_info").map { $0.task === a }, [true], "client_info 在 transport 上发在 A 上")
        XCTAssertFalse(client.isConnected)
    }

    /// 对照：连接没换，connect_report 发在这次连上的 task 上
    func testConnectReportSentOnOpenedTask() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            client.connect(url: hubURL)
            let a = openTask(client)
            XCTAssertTrue(spin { !wire.sent("connect_report").isEmpty })
            XCTAssertTrue(wire.sent("connect_report").allSatisfy { $0.task === a })
        }
    }

    // MARK: - #6 reply → edit 有序 · #11 早到帧有序

    private func replyFrame(_ rid: String) -> URLSessionWebSocketTask.Message {
        frame(["type": "reply", "chat_id": "C1", "content": "hi", "reply_id": rid, "mp_msg_id": "s_" + rid, "ts": 1_700_000_000_000])
    }

    /// 改某条 reply 的 edit 紧跟着它到：落地顺序 = 到达顺序（原来 edit 直接 main.async，会抢在多绕一跳 handlersQueue 的 reply 前面）。
    /// 卡住 handlersQueue 把交错固定下来（A1 R2 N5）：reply 卡在那一跳时，edit / 流式 thinking 若不走同一条通道就会先落地
    func testEditLandsAfterTheReplyItEdits() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            let a = openTask(client)
            var seen: [String] = []
            client.onProactiveMessage = { _, _, _, _, _, _, ccId, _, _ in seen.append("reply:\(ccId ?? "-")") }
            client.onEditMessage = { _, id, _, _ in seen.append("edit:\(id)") }
            client.onThinking = { _, id, _ in seen.append("think:\(id)") }
            let rid = "r6-\(UUID().uuidString.prefix(8))"
            let release = client.holdHandlersForTesting()
            client.didReceive(.success(replyFrame(rid)), on: a)
            client.didReceive(.success(frame(["type": "edit", "chat_id": "C1", "mp_msg_id": "s_" + rid, "content": "改"])), on: a)
            client.didReceive(.success(frame(["type": "thinking", "chat_id": "C1", "mp_msg_id": "s_" + rid, "content": "想", "thinking_id": "t-" + rid, "streaming": true])), on: a)
            client.drainPipelinesForTesting(handlers: false)   // 三帧都已解析、排到 handlersQueue（卡着）
            settle(0.1)
            XCTAssertTrue(seen.isEmpty, "reply 卡在 handlersQueue 时谁都不能先落地：\(seen)")
            release()
            XCTAssertTrue(spin { seen.count == 3 }, "\(seen)")
            XCTAssertEqual(seen, ["reply:s_\(rid)", "edit:s_\(rid)", "think:s_\(rid)"])
        }
    }

    /// A1 早到帧（didOpen 前到）：hello、送达快照、reply → 它的 edit，放出后严格按到达顺序、且都排在「已连上」快照之后——
    /// reply 落地时 isConnected 已 true、hello 已应用（hubInfoIsCurrent 没被快照翻回 false）、快照已对过账
    func testEarlyFramesOrderedWithHelloSnapshotAndEdit() {
        let (client, _) = makeClient(a1: true)
        let a = makeTask()
        client.adoptTaskForTesting(a, url: hubURL)
        client.sendTracker.didReceive(CCSendStatus(chatId: "C1", messageId: "m-pending", sessionName: "s", state: .uncertain, reason: nil))
        var seen: [String] = []
        client.onProactiveMessage = { _, _, _, _, _, _, ccId, _, _ in
            let snap = client.sendTracker.store.entry("m-pending")?.state == .failed
            seen.append("reply:\(ccId ?? "-"):conn=\(client.isConnected):hello=\(client.hubInfoIsCurrent):snap=\(snap)")
        }
        client.onEditMessage = { _, id, _, _ in seen.append("edit:\(id):conn=\(client.isConnected)") }
        let rid = "r11-\(UUID().uuidString.prefix(8))"
        client.didReceive(.success(frame(["type": "hello"])), on: a)
        client.didReceive(.success(frame(["type": "send_status_snapshot", "statuses": []])), on: a)
        client.didReceive(.success(replyFrame(rid)), on: a)
        client.didReceive(.success(frame(["type": "edit", "chat_id": "C1", "mp_msg_id": "s_" + rid, "content": "改"])), on: a)
        didOpen(client, a)
        client.didReceive(.success(frame(["type": "edit", "chat_id": "C1", "mp_msg_id": "m2", "content": "x"])), on: a)
        XCTAssertTrue(spin { seen.count == 3 }, "\(seen)")
        XCTAssertEqual(seen, [
            "reply:s_\(rid):conn=true:hello=true:snap=true",
            "edit:s_\(rid):conn=true",
            "edit:m2:conn=true",
        ])
        XCTAssertNotNil(client.currentHubInfo)
        XCTAssertEqual(defaults.double(forKey: "ccReplyCursorTs"), 1_700_000_000_000, "reply 落地后推进 cursor")
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    // MARK: - #7 terminal_active 与前后台同序 · #8 focus 在 client_info 之前

    private func activeFlags(_ wire: Wire) -> [Bool] { wire.sent("terminal_active").compactMap { $0.obj["active"] as? Bool } }

    /// A1：didOpen 和「进后台」先后排进 transport：active 帧顺序 = 状态变化顺序，最后一帧是最新状态
    func testTerminalActiveFollowsForegroundOrder() {
        let (client, wire) = makeClient(a1: true)
        let a = makeTask()
        client.adoptTaskForTesting(a, url: hubURL)
        var release = client.holdTransportForTesting()
        didOpen(client, a)          // 排着：按当时的前后台报 active
        client.noteBackground()     // 排着：前后台 → 后台，focus(null) + active(false)
        release()
        client.drainTransportForTesting()
        XCTAssertEqual(activeFlags(wire), [true, false])
        XCTAssertTrue(wire.sent("terminal_active").allSatisfy { $0.task === a })

        let (client2, wire2) = makeClient(a1: true)
        let b = makeTask()
        client2.adoptTaskForTesting(b, url: hubURL)
        release = client2.holdTransportForTesting()
        client2.noteBackground()    // 反过来：先进后台再 didOpen
        didOpen(client2, b)
        release()
        client2.drainTransportForTesting()
        XCTAssertEqual(activeFlags(wire2), [false, false], "didOpen 读到的是已发布的后台状态")
        XCTAssertEqual(client.transportOwnershipBreaks + client2.transportOwnershipBreaks, 0)
    }

    /// 两条路：进后台 → 回前台，active 帧依次 false / true
    func testBackgroundForegroundActiveFrames() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            openTask(client)
            client.noteBackground()
            client.noteForeground()
            XCTAssertTrue(spin { activeFlags(wire).suffix(2) == [false, true] }, "\(activeFlags(wire))")
        }
    }

    /// A1：focus 拿锁保护的最新一份，在 transport 的 didOpen 里、client_info 之前发；主线程应用快照时不再补发一次；之后变了照常更新
    func testFocusSentBeforeClientInfo() {
        let (client, wire) = makeClient(a1: true)
        client.updateFocus("C9")    // 还没连上：记下
        let a = makeTask()
        client.adoptTaskForTesting(a, url: hubURL)
        didOpen(client, a)
        XCTAssertTrue(spin { client.isConnected })
        settle()
        let types = wire.types(on: a)
        let focusAt = types.firstIndex(of: "focus"), infoAt = types.firstIndex(of: "client_info")
        XCTAssertNotNil(focusAt)
        XCTAssertNotNil(infoAt)
        if let focusAt, let infoAt { XCTAssertLessThan(focusAt, infoAt, "\(types)") }
        XCTAssertEqual(wire.sent("focus").map { $0.obj["chat_id"] as? String }, ["C9"], "只发一次")
        client.updateFocus("C10")
        XCTAssertTrue(spin { wire.sent("focus").count == 2 })
        XCTAssertEqual(wire.sent("focus").last?.obj["chat_id"] as? String, "C10")
        XCTAssertTrue(wire.sent("focus").allSatisfy { $0.task === a })
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    // MARK: - #12 探针计数跨队列

    /// reply 计数在 handlersQueue 上自增、didOpen 时在 transport（A1=0 主线程）上清零：多线程同时喂帧不丢计数，新连接从 0 起
    func testProbeReplyCountIsConsistentAcrossQueues() {
        bothPaths { a1 in
            let (client, _) = makeClient(a1: a1)
            let a = openTask(client)
            XCTAssertEqual(client.probeReplyCountForTesting, 0)
            let group = DispatchGroup()
            for t in 0..<4 {
                DispatchQueue.global().async(group: group) {
                    for i in 0..<25 {
                        client.handleIncoming(self.text(["type": "reply", "chat_id": "C1", "content": "x", "reply_id": "pc-\(a1)-\(t)-\(i)-\(UUID().uuidString.prefix(6))"]), source: a)
                    }
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            client.drainPipelinesForTesting()
            XCTAssertEqual(client.probeReplyCountForTesting, 100)
            let b = makeTask()
            client.adoptTaskForTesting(b, url: hubURL)
            didOpen(client, b)
            XCTAssertTrue(spin { client.probeReplyCountForTesting == 0 }, "新连接重新计")
        }
    }

    // MARK: - #9 解析离开 transport、帧门有上限

    private func editFrame(_ id: String, content: String = "x") -> URLSessionWebSocketTask.Message {
        frame(["type": "edit", "chat_id": "C1", "mp_msg_id": id, "content": content])
    }

    /// 解析队列卡住时 transport 照样空闲（connect / disconnect / 换 task 不被大帧拖住）；放开后按到达顺序落地
    func testParseQueueKeepsOrderAndDoesNotHoldTransport() {
        let (client, _) = makeClient(a1: true)
        let a = openTask(client)
        var seen: [String] = []
        client.onEditMessage = { _, id, content, _ in seen.append("\(id):\(content.count)") }
        let release = client.holdParseForTesting()
        let big = String(repeating: "z", count: 2 << 20)
        client.didReceive(.success(editFrame("e1")), on: a)
        client.didReceive(.success(editFrame("big", content: big)), on: a)
        client.didReceive(.success(editFrame("e3")), on: a)
        let t0 = Date()
        client.drainTransportForTesting()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "解析卡着，transport 不等它")
        XCTAssertGreaterThan(client.parseBacklogBytesForTesting, 2 << 20)
        XCTAssertTrue(client.currentTaskForTesting === a)
        settle(0.1)
        XCTAssertTrue(seen.isEmpty)
        release()
        XCTAssertTrue(spin { seen.count == 3 })
        XCTAssertEqual(seen, ["e1:1", "big:\(2 << 20)", "e3:1"])
        client.drainPipelinesForTesting()
        XCTAssertEqual(client.parseBacklogBytesForTesting, 0)
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// didOpen 前压着的帧超上限：断开这次连接走重连（丢的帧靠重放补）
    func testPreOpenOverflowDropsConnection() {
        let (client, _) = makeClient(a1: true)
        var limits = CCBridgeWebSocketClient.FrameLimits()
        limits.preOpenFrames = 2
        client.setFrameLimitsForTesting(limits)
        client.connect(url: hubURL)   // 有候选地址，断线后才会排重连
        let a = makeTask()
        client.adoptTaskForTesting(a, url: hubURL)
        let before = TestHostIsolation.blockedCount(.hub)
        for i in 0..<3 { client.didReceive(.success(editFrame("p\(i)")), on: a) }
        client.drainTransportForTesting()
        XCTAssertNil(client.currentTaskForTesting, "超限断开")
        XCTAssertTrue(spin { client.lastError?.contains("超限") == true })
        XCTAssertTrue(spin(timeout: 3) { TestHostIsolation.blockedCount(.hub) > before }, "退避后重连")
        didOpen(client, a)   // 迟到的 didOpen 不认
        settle()
        XCTAssertFalse(client.isConnected)
    }

    /// 可控 receive（A1 R2 N5）：每次 receiveLoop 挂的 receive 回调都记下，测试决定喂哪一帧；记同时挂着的最大数
    final class Receiver {
        private let lock = NSLock()
        private var pending: [(Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
        private var maxPending = 0

        func install(on client: CCBridgeWebSocketClient) {
            client.setReceiveHookForTesting { [weak self] _, callback in
                guard let self else { return }
                self.lock.lock()
                self.pending.append(callback)
                self.maxPending = max(self.maxPending, self.pending.count)
                self.lock.unlock()
            }
        }

        var outstanding: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
        var maxOutstanding: Int { lock.lock(); defer { lock.unlock() }; return maxPending }

        /// 把一帧交给最早挂着的 receive；没有挂着的 receive = 收不到（返回 false）
        func deliver(_ message: URLSessionWebSocketTask.Message) -> Bool {
            lock.lock()
            guard !pending.isEmpty else { lock.unlock(); return false }
            let callback = pending.removeFirst()
            lock.unlock()
            callback(.success(message))
            return true
        }
    }

    /// 解析积压超上限：先不再 receive；解析追上来恢复，恢复后下一帧确实收得到，且任何时候只挂一个 receive
    /// （删掉恢复时的 receiveLoop()，第二帧就没有 receive 可交、这条失败）
    func testParseBacklogPausesReceiving() {
        let (client, _) = makeClient(a1: true)
        let rx = Receiver()
        rx.install(on: client)
        var limits = CCBridgeWebSocketClient.FrameLimits()
        limits.parseBacklogBytes = 10
        client.setFrameLimitsForTesting(limits)
        var seen: [String] = []
        client.onEditMessage = { _, id, _, _ in seen.append(id) }
        let a = makeTask()
        client.adoptTaskForTesting(a, url: hubURL, receiving: true)
        didOpen(client, a)
        XCTAssertTrue(spin { client.isConnected })
        XCTAssertEqual(rx.outstanding, 1)
        let release = client.holdParseForTesting()
        XCTAssertTrue(rx.deliver(editFrame("bp1")))
        client.drainTransportForTesting()
        XCTAssertTrue(client.receivePausedForTesting)
        XCTAssertEqual(rx.outstanding, 0, "积压超上限：先不再 receive")
        release()
        client.drainPipelinesForTesting()
        XCTAssertFalse(client.receivePausedForTesting)
        XCTAssertEqual(rx.outstanding, 1, "解析追上来：恢复收帧")
        XCTAssertTrue(rx.deliver(editFrame("bp2")), "恢复后下一帧有 receive 接")
        XCTAssertTrue(spin { seen == ["bp1", "bp2"] }, "\(seen)")
        client.drainPipelinesForTesting()
        XCTAssertEqual(rx.outstanding, 1)
        XCTAssertEqual(rx.maxOutstanding, 1, "同时只挂一个 receive")
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 补订阅：attach 记下的 task 就是实际发出去的那个——在「记下 task」与「真正发送」之间换成 B（A1 R2 N5），这一发仍在 A 上；
    /// B 打开后在 B 上补一次
    func testAttachRecordsTheTaskItWasSentOn() {
        bothPaths { a1 in
            let (client, wire) = makeClient(a1: a1)
            let a = openTask(client)
            let b = makeTask()
            var swapped = false   // 只在 handlersQueue 上读写
            client.setAttachRecordedHookForTesting { _ in
                guard !swapped else { return }
                swapped = true
                client.adoptTaskForTesting(b, url: self.hubURL)
            }
            client.attachTerminal(session: "s1", cols: 80, rows: 24, onInit: { _, _ in }, onChunk: { _ in }, onError: { _ in })
            XCTAssertTrue(spin { wire.sent("terminal_attach").count == 1 })
            XCTAssertTrue(wire.sent("terminal_attach").first?.task === a, "发在记下的那个 task 上，不是中途换上的 B")
            XCTAssertTrue(client.currentTaskForTesting === b)
            client.setAttachRecordedHookForTesting(nil)
            didOpen(client, b)
            XCTAssertTrue(spin { wire.sent("terminal_attach").count == 2 })
            settle()
            let attaches = wire.sent("terminal_attach")
            XCTAssertEqual(attaches.count, 2, "已交给 B 的不重发")
            XCTAssertTrue(attaches.last?.task === b)
        }
    }
}
