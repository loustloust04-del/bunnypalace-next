import XCTest
@testable import 记忆花园

/// A1（plan-app-instant-connect §3）：连接状态机挪到 transport 串行队列后的契约——
/// 状态只在 transport 上动、旧 task 的回调作废、「已连上」快照先于首批业务帧到主线程、MP_APP_CONNECT_A1=0 回到主线程原路径。
/// 不碰网络：task 从不 resume（127.0.0.1:9 discard 端口兜底），connect 在测试宿主被 TestHostIsolation 挡在发请求之前。
final class CCBridgeTransportA1Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clients: [CCBridgeWebSocketClient] = []
    private var session: URLSession!
    private let hubURL = URL(string: "ws://127.0.0.1:9/cc")!

    override func setUp() {
        super.setUp()
        suite = "CCBridgeTransportA1Tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        for c in clients { c.disconnect() }
        clients = []
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func makeClient(a1: Bool) -> CCBridgeWebSocketClient {
        let c = CCBridgeWebSocketClient(dedupDefaults: defaults, transportOffMain: a1)
        clients.append(c)
        return c
    }

    private func makeTask() -> URLSessionWebSocketTask {
        session.webSocketTask(with: hubURL)
    }

    private func frame(_ obj: [String: Any]) -> URLSessionWebSocketTask.Message {
        .string(String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
    }

    private func editFrame(_ id: String) -> URLSessionWebSocketTask.Message {
        frame(["type": "edit", "chat_id": "C1", "mp_msg_id": id, "content": "x"])
    }

    private func replyFrame(_ id: String) -> URLSessionWebSocketTask.Message {
        frame(["type": "reply", "chat_id": "C1", "content": "hi", "reply_id": id, "mp_msg_id": "s_" + id])
    }

    private func didOpen(_ client: CCBridgeWebSocketClient, _ task: URLSessionWebSocketTask) {
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
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

    // MARK: - A1

    /// 帧比 didOpen 先到 transport（显式门）：压着，didOpen 处理完、快照排进主队列后才放——
    /// 主线程上业务处理时 isConnected 一定已是 true（直接 main.async 的 edit 和走 handlersQueue 的 reply 都一样）
    func testEarlyFramesReachMainAfterConnectedSnapshot() {
        let client = makeClient(a1: true)
        let task = makeTask()
        client.adoptTaskForTesting(task, url: hubURL)
        var seen: [String] = []
        client.onEditMessage = { _, id, _, _ in seen.append("edit:\(id):\(client.isConnected)") }
        client.onProactiveMessage = { _, _, _, _, _, _, ccId, _, _ in seen.append("reply:\(ccId ?? "-"):\(client.isConnected)") }
        let rid = "a1-early-\(UUID().uuidString.prefix(8))"
        client.didReceive(.success(editFrame("m1")), on: task)
        client.didReceive(.success(replyFrame(rid)), on: task)
        didOpen(client, task)
        client.didReceive(.success(editFrame("m2")), on: task)
        XCTAssertTrue(spin { seen.count == 3 }, "\(seen)")
        // 有序比较（A1 R1 #11）：压着的帧按到达顺序放出，reply / edit 走同一条有序通道（R1 #6），落地顺序 = 到达顺序
        XCTAssertEqual(seen, ["edit:m1:true", "reply:s_\(rid):true", "edit:m2:true"])
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 被换掉的旧 task：didOpen 不认、帧不收不压；当前 task 照常连上
    func testStaleTaskCallbacksAreDropped() {
        let client = makeClient(a1: true)
        let old = makeTask(), current = makeTask()
        client.adoptTaskForTesting(old, url: hubURL)
        client.adoptTaskForTesting(current, url: hubURL)
        var edits: [String] = []
        client.onEditMessage = { _, id, _, _ in edits.append(id) }
        didOpen(client, old)
        client.didReceive(.success(editFrame("old")), on: old)
        spin(timeout: 0.3) { false }
        XCTAssertFalse(client.isConnected)
        didOpen(client, current)
        client.didReceive(.success(editFrame("cur")), on: current)
        XCTAssertTrue(spin { client.isConnected && edits == ["cur"] }, "\(edits)")
        spin(timeout: 0.2) { false }
        XCTAssertEqual(edits, ["cur"], "旧 task 的帧既不投递也不压着等放出")
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 快照排在主队列里还没轮到时手动断开：disconnect 同步在 transport 上摘掉 task，快照到了按 task 对不上作废
    func testDisconnectBeforeSnapshotAppliedDropsIt() {
        let client = makeClient(a1: true)
        let task = makeTask()
        client.adoptTaskForTesting(task, url: hubURL)
        didOpen(client, task)
        client.disconnect()   // 主线程同步排进 transport：didOpen 先处理完（快照已排主队列），再拆
        spin(timeout: 0.3) { false }
        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(client.isConnecting)
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 断线 → 「断了」快照落主线程 → 退避定时器在 transport 上到点再起探测（测试宿主在发请求前挡下、计数）
    func testDropSchedulesReconnectOnTransport() {
        let client = makeClient(a1: true)
        let task = makeTask()
        client.adoptTaskForTesting(task, url: hubURL)
        didOpen(client, task)
        XCTAssertTrue(spin { client.isConnected })
        let blockedBefore = TestHostIsolation.blockedCount(.hub)
        client.didReceive(.failure(URLError(.networkConnectionLost)), on: task)
        XCTAssertTrue(spin { !client.isConnected })
        XCTAssertNotNil(client.lastError)
        XCTAssertTrue(spin(timeout: 3) { TestHostIsolation.blockedCount(.hub) > blockedBefore }, "退避到点后 startTask 应在 transport 上跑到")
        client.didReceive(.failure(URLError(.networkConnectionLost)), on: task)   // 同一次断连的第二个回调：task 已摘，不再排退避
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 各入口从主线程 / 后台线程乱序打进来，状态机只在 transport 上动；connect 同步定下目标（随后的请求不会被它作废）
    func testEntryPointsFromAnyThreadStayOnTransport() {
        let client = makeClient(a1: true)
        client.connect(url: hubURL)
        XCTAssertEqual(client.currentHost, "127.0.0.1", "connect 返回时目标已定")
        XCTAssertTrue(client.hasCandidates)
        let group = DispatchGroup()
        for i in 0..<8 {
            DispatchQueue.global().async(group: group) {
                let task = self.session.webSocketTask(with: self.hubURL)
                client.adoptTaskForTesting(task, url: self.hubURL)
                client.urlSession(self.session, webSocketTask: task, didOpenWithProtocol: nil)
                client.didReceive(.success(self.editFrame("bg\(i)")), on: task)
                if i % 4 == 0 { client.connect(url: self.hubURL) }
            }
        }
        for _ in 0..<4 {   // 断桥卡的「重新连接」只从主线程按
            client.reconnectNow()
            spin(timeout: 0.05) { false }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        spin(timeout: 0.5) { false }
        client.disconnect()
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    /// 尺子：A1 下 client_info 在 transport 上发（早于主线程进入），报告仍带 ui_ms（主线程进入）和 transport 标记
    func testConnectReportInA1() {
        let client = makeClient(a1: true)
        var report: [String: Any]?
        client.onConnectReportForTesting = { report = $0 }
        client.connect(url: hubURL)   // 开一段（测试宿主挡在发请求前）
        let task = makeTask()
        client.adoptTaskForTesting(task, url: hubURL)
        didOpen(client, task)
        XCTAssertTrue(spin { report != nil })
        guard let r = report, ConnectRuler.enabled else { return }
        XCTAssertEqual(r["transport"] as? String, "a1")
        XCTAssertNotNil((r["sw"] as? [String: String])?["A1"])
        let open = r["ws_open_ms"] as? Int, info = r["client_info_ms"] as? Int, ui = r["ui_ms"] as? Int
        XCTAssertNotNil(open)
        XCTAssertNotNil(info)
        XCTAssertNotNil(ui)
        if let open, let info, let ui {
            XCTAssertLessThanOrEqual(open, info)
            XCTAssertLessThanOrEqual(info, ui, "A1：client_info 不等主线程")
        }
        XCTAssertNil(r["ws_invalid"])
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }

    // MARK: - 开关回退

    /// MP_APP_CONNECT_A1=0：transport 就是主线程，原路径——didOpen 排主线程处理、帧不压（早到的帧照旧直接投递）
    func testSwitchOffUsesMainThreadPath() {
        let client = makeClient(a1: false)
        XCTAssertFalse(client.transportOffMain)
        var report: [String: Any]?
        client.onConnectReportForTesting = { report = $0 }
        client.connect(url: hubURL)
        let task = makeTask()
        client.adoptTaskForTesting(task, url: hubURL)
        var seen: [String] = []
        client.onEditMessage = { _, id, _, _ in seen.append("\(id):\(client.isConnected)") }
        client.didReceive(.success(editFrame("early")), on: task)   // 原路径没有门：比 didOpen 早投进主队列
        client.drainPipelinesForTesting()   // edit 走 handlersQueue → main 的有序通道（A1 R1 #6），等它排进主队列
        let opened = expectation(description: "didOpen from delegate queue")
        DispatchQueue.global().async {   // 原路径的 didOpen 来自 Foundation 委托队列
            self.didOpen(client, task)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 2)
        XCTAssertTrue(spin { client.isConnected && seen.count == 1 })
        XCTAssertEqual(seen, ["early:false"])
        XCTAssertTrue(spin { report != nil })
        if ConnectRuler.enabled { XCTAssertEqual(report?["transport"] as? String, "main") }
        client.disconnect()
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.transportOwnershipBreaks, 0)
    }
}
