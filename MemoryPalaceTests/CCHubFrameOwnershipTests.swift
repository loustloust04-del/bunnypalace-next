import XCTest
@testable import 记忆花园

/// plan-multi-hub B2.6 / B2.8：入站帧逐个定归属（research-multi-hub-frames 52 帧）+ 按 hub 分开的 store。
/// 全部注入 defaults suite，不碰真钥匙串、不连真 hub；全局 store 只用随机 chat / 会话名（mp-cc 那条是同名互不清除的用例）
final class CCHubFrameOwnershipTests: XCTestCase {
    final class Wire {
        private let lock = NSLock()
        private var items: [[String: Any]] = []

        func install(on client: CCBridgeWebSocketClient) {
            client.setTransmitHookForTesting { [weak self] _, text, completion in
                let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                self?.lock.lock()
                self?.items.append(obj)
                self?.lock.unlock()
                DispatchQueue.global().async { completion(nil) }
            }
        }

        var all: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return items
        }

        func sent(_ type: String) -> [[String: Any]] { all.filter { $0["type"] as? String == type } }
    }

    final class Counter {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
        var list: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// research 表 A 类（20）+ opencli_result
    static let typesA = [
        "cc_memory_manifest", "cc_memory_files", "cc_memory_changed", "vocab_corpus_result", "pocket_cmd", "twitter_cmd",
        "agent_status_result", "status_result", "status_alert", "warroom_board_result", "warroom_request_result", "pm_req_result",
        "agent_book_note", "trading_report_result", "trading_report_progress", "voice_call_state", "voice_call_snapshot",
        "voice_call_error", "la_query_result", "la_token_nak", "opencli_result",
    ]
    /// B-改（11）
    static let typesBChanged = [
        "reply", "edit", "thinking", "ask_user_question", "ask_user_resolved", "ask_user_stale", "hello",
        "transport_policies", "terminal_state", "session_model", "session_phase",
    ]
    /// B-实例（20）
    static let typesBInstance = [
        "ack", "send_status", "send_status_snapshot", "hub_config", "hub_config_error", "dir_list", "error", "spawn_cc_ok",
        "spawn_cc_err", "list_sessions_result", "terminal_init", "terminal_chunk", "list_windows_result", "window_opened",
        "window_restored", "window_closed", "window_ended", "voice_instructions_result", "terminal_paste_result", "terminal_error",
    ]
    /// C（1）
    static let typesC = ["terminal_usage"]

    private var suites: [String] = []
    private var clients: [CCBridgeWebSocketClient] = []
    private var wires: [Wire] = []
    private var made: [String: CCBridgeWebSocketClient] = [:]
    private var madeWires: [String: Wire] = [:]
    private var secrets: CCHubRegistryTests.FakeSecrets!
    private var std: UserDefaults!
    private var prefix: String!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = URLSession(configuration: .ephemeral)
        secrets = CCHubRegistryTests.FakeSecrets()
        std = newSuite()
        prefix = "CCHubFrameOwnershipTests.hub.\(UUID().uuidString)."
    }

    override func tearDown() {
        for c in clients + Array(made.values) {
            c.disconnect()
            c.setTransmitHookForTesting(nil)
        }
        for id in made.keys { UserDefaults(suiteName: prefix + id)?.removePersistentDomain(forName: prefix + id) }
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        clients = []
        wires = []
        made = [:]
        madeWires = [:]
        session.invalidateAndCancel()
        super.tearDown()
    }

    // MARK: - 工具

    private func newSuite() -> UserDefaults {
        let name = "CCHubFrameOwnershipTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func newClient(hubId: String, defaults: UserDefaults? = nil) -> (CCBridgeWebSocketClient, Wire) {
        let c = CCBridgeWebSocketClient(hubId: hubId, defaults: defaults ?? newSuite())
        let w = Wire()
        w.install(on: c)
        c.pocketEnabledForTesting = false
        clients.append(c)
        wires.append(w)
        return (c, w)
    }

    @MainActor
    private func makeRegistry(primary: CCBridgeWebSocketClient) -> CCHubRegistry {
        CCHubRegistry(primary: primary, standard: std, suitePrefix: prefix, secrets: secrets, originDefaults: std) { [unowned self] id, d in
            let c = CCBridgeWebSocketClient(hubId: id, defaults: d)
            let w = Wire()
            w.install(on: c)
            self.made[id] = c
            self.madeWires[id] = w
            return c
        }
    }

    private func text(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
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

    private func settle(_ seconds: TimeInterval = 0.3) { spin(timeout: seconds) { false } }

    @discardableResult
    private func open(_ client: CCBridgeWebSocketClient) -> URLSessionWebSocketTask {
        let u = URL(string: "ws://127.0.0.1:9/cc")!
        let task = session.webSocketTask(with: u)
        client.adoptTaskForTesting(task, url: u)
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        XCTAssertTrue(spin { client.isConnected && client.currentTaskForTesting === task })
        return task
    }

    /// 每个 A 类帧一份「主 hub 收到真会干活」的帧
    private func frameA(_ type: String, tag: String) -> [String: Any] {
        var f: [String: Any] = ["type": type]
        switch type {
        case "cc_memory_manifest": f["files"] = [["path": "x.md", "hash": "h"]]
        case "cc_memory_files": f["files"] = [["path": "x.md", "content": "c"]]
        case "vocab_corpus_result": f["word"] = "w-\(tag)"; f["ok"] = false
        case "pocket_cmd", "twitter_cmd": f["id"] = "\(type)-\(tag)"
        case "status_result": f["sources"] = []
        case "status_alert": f["alert"] = ["id": "al-\(tag)", "source": "s", "kind": "bad", "text": "t"]
        case "warroom_board_result": f["tasks"] = []
        case "pm_req_result": f["req_id"] = "r-\(tag)"
        case "agent_book_note", "trading_report_result": f["uuid"] = "\(type)-\(tag)"
        case "trading_report_progress": f["symbol"] = "SYM"; f["stage"] = "s"; f["label"] = "l"
        case "voice_call_snapshot": f["calls"] = []
        case "voice_call_error": f["call_id"] = "c-\(tag)"
        case "la_query_result": f["alive"] = [:] as [String: Any]
        case "la_token_nak": f["kind"] = "update"
        default: break
        }
        return f
    }

    private static let watchedNotifications = ["vocabCorpusArrived", "CCMemorySyncDidChange", "warroomBoardUpdated",
                                               "warroomRequestResult", "pmBoardFrame", "tradingResearchProgress"]

    private func observeNotifications(_ counter: Counter) -> [NSObjectProtocol] {
        Self.watchedNotifications.map { name in
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in counter.add(name) }
        }
    }

    // MARK: - 分类：53 帧

    func testFrameTableCoversAll52TypesAndGateMatchesIt() {
        let all = Self.typesA + Self.typesBChanged + Self.typesBInstance + Self.typesC
        XCTAssertEqual(all.count, 53)
        XCTAssertEqual(Set(all).count, 53)
        XCTAssertEqual(CCBridgeWebSocketClient.primaryOnlyFrameTypes, Set(Self.typesA))
        for t in Self.typesA {
            let expected: CCBridgeWebSocketClient.SecondaryFrameGate = t == "pocket_cmd" || t == "twitter_cmd" ? .reject : .drop
            XCTAssertEqual(CCBridgeWebSocketClient.secondaryFrameGate(t), expected, t)
        }
        for t in Self.typesBChanged + Self.typesBInstance + Self.typesC {
            XCTAssertEqual(CCBridgeWebSocketClient.secondaryFrameGate(t), .pass, t)
        }
    }

    // MARK: - A 类：附加 hub 收到什么都不动

    @MainActor
    func testEveryPrimaryOnlyFrameOnSecondaryChangesNothing() {
        let (client, wire) = newClient(hubId: "h-a-\(UUID().uuidString.prefix(6))")
        let task = open(client)
        settle()
        let baseline = wire.all.count
        let calls = Counter()
        client.pocketEnabledForTesting = true
        client.pocketRunnerForTesting = { _, _ in calls.add("pocket") }
        client.onTwitterCmd = { _ in calls.add("twitter"); return [:] }
        client.onAgentStatusResult = { _ in calls.add("agent_status") }
        client.onStatusAlert = { _ in calls.add("status_alert"); return true }
        client.onAgentBookNote = { _ in calls.add("book_note"); return true }
        #if PERSONAL_APPS
        client.onTradingReport = { _ in calls.add("trading"); return true }
        #endif
        let usage = Counter()
        client.usageSnapshotWriterForTesting = { usage.add($0) }
        let notes = Counter()
        let observers = observeNotifications(notes)
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        let tag = UUID().uuidString
        let word = "w-\(tag)"
        VocabArcheologyTracker.inFlight.insert(word)
        defer { VocabArcheologyTracker.inFlight.remove(word) }
        let status = String(describing: StatusSnapshot.shared.sources)
        let windowSeq = TerminalWindowStore.shared.syncSeq
        let phaseHubs = CCSessionPhaseStore.shared.byHub.keys.sorted()
        let standardKeys = ["agentBookNoteSeenUUIDs", "tradingReportSeenUUIDs", CCBridgeWebSocketClient.transportPolicyKey]
        let standardBefore = standardKeys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }

        for type in Self.typesA {
            client.handleIncoming(text(frameA(type, tag: tag)), source: task)
        }
        XCTAssertTrue(spin { wire.all.count == baseline + 2 })
        settle()

        // 只回两条拒绝帧，别的一条不发（status_alert_ack / agent_book_note_ack / trading_report_ack 都没有）
        let out = Array(wire.all.dropFirst(baseline))
        XCTAssertEqual(Set(out.compactMap { $0["type"] as? String }), ["pocket_result", "twitter_result"])
        XCTAssertTrue(out.allSatisfy { $0["ok"] as? Bool == false })
        XCTAssertEqual(calls.list, [], "回调 / 执行器一个都没碰")
        XCTAssertEqual(notes.list, [], "全局通知一个都没发")
        XCTAssertEqual(usage.list, [])
        XCTAssertTrue(VocabArcheologyTracker.inFlight.contains(word), "vocab 回投没落到全局")
        XCTAssertEqual(String(describing: StatusSnapshot.shared.sources), status, "状态面板没被顶掉")
        XCTAssertEqual(TerminalWindowStore.shared.syncSeq, windowSeq)
        XCTAssertEqual(CCSessionPhaseStore.shared.byHub.keys.sorted(), phaseHubs)
        XCTAssertEqual(standardKeys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }, standardBefore)
    }

    /// R4：没人注册回调的附加实例，重放多少遍告警 / 研报缓冲都不涨
    @MainActor
    func testSecondaryBuffersNeverGrow() {
        let (client, _) = newClient(hubId: "h-buf")
        let task = open(client)
        for i in 0..<5 {
            client.handleIncoming(text(frameA("status_alert", tag: "\(i)")), source: task)
            client.handleIncoming(text(frameA("trading_report_result", tag: "\(i)")), source: task)
        }
        settle()
        XCTAssertEqual(client.bufferedStatusAlertCountForTesting, 0)
        #if PERSONAL_APPS
        XCTAssertEqual(client.bufferedTradingReportCountForTesting, 0)
        #endif

        // 对照：主 hub 没注册时照旧缓冲（冷启动竞态的修法不变）
        let (primary, _) = newClient(hubId: CCBridgeWebSocketClient.primaryHubId)
        let ptask = open(primary)
        primary.handleIncoming(text(frameA("status_alert", tag: "p")), source: ptask)
        XCTAssertTrue(spin { primary.bufferedStatusAlertCountForTesting == 1 })
    }

    /// 回归：主 hub 收同样的 A 类帧照旧分发
    @MainActor
    func testPrimaryOnlyFramesStillReachPrimary() {
        let (primary, wire) = newClient(hubId: CCBridgeWebSocketClient.primaryHubId)
        let task = open(primary)
        let calls = Counter()
        primary.onTwitterCmd = { frame in calls.add("twitter"); return ["type": "twitter_result", "id": frame["id"] as? String ?? "", "ok": true] }
        primary.onAgentStatusResult = { _ in calls.add("agent_status") }
        primary.onStatusAlert = { _ in calls.add("status_alert"); return true }
        primary.onAgentBookNote = { _ in calls.add("book_note"); return false }   // false = 不落 .standard 去重表
        #if PERSONAL_APPS
        primary.onTradingReport = { _ in calls.add("trading"); return false }
        #endif
        let notes = Counter()
        let observers = observeNotifications(notes)
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        let tag = UUID().uuidString
        let word = "w-\(tag)"
        VocabArcheologyTracker.inFlight.insert(word)

        var types = ["twitter_cmd", "agent_status_result", "status_alert", "agent_book_note", "vocab_corpus_result"]
        var expectedCalls: Set<String> = ["twitter", "agent_status", "status_alert", "book_note"]
        var expectedNotes: Set<String> = ["vocabCorpusArrived"]
        #if PERSONAL_APPS
        types += ["trading_report_result", "trading_report_progress", "warroom_request_result"]
        expectedCalls.insert("trading")
        expectedNotes.formUnion(["tradingResearchProgress", "warroomRequestResult"])
        #if DEBUG
        types.append("pm_req_result")
        expectedNotes.insert("pmBoardFrame")
        #endif
        #endif
        for type in types { primary.handleIncoming(text(frameA(type, tag: tag)), source: task) }
        XCTAssertTrue(spin { Set(calls.list) == expectedCalls && Set(notes.list) == expectedNotes })
        XCTAssertTrue(spin { wire.sent("status_alert_ack").count == 1 && wire.sent("twitter_result").first?["ok"] as? Bool == true })
        XCTAssertFalse(VocabArcheologyTracker.inFlight.contains(word))
    }

    // MARK: - B 类：只改那台的

    @MainActor
    func testTerminalStateGoesToEachHubsOwnStoreAndStoreUsesItsOwnClient() {
        let primarySuite = std!
        let (primary, primaryWire) = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: primarySuite)
        let r = makeRegistry(primary: primary)
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "纽约", pairing: CCHubPairing(primaryURL: "ws://192.168.9.2:7890/cc"), token: "t2") else { return XCTFail() }
        let secondary = made[id]!
        let secondaryWire = madeWires[id]!
        guard let storeS = r.windowStore(for: id), let storeP = r.windowStore(for: CCHubRegistry.primaryId) else { return XCTFail() }
        XCTAssertTrue(secondary.windowStore === storeS)
        XCTAssertTrue(storeS.client === secondary)
        XCTAssertTrue(primary.windowStore === storeP)
        XCTAssertTrue(storeP.client === primary)
        XCTAssertFalse(storeP === TerminalWindowStore.shared, "注入的主 client 另建一份")
        let sharedSeq = TerminalWindowStore.shared.syncSeq

        let taskS = open(secondary)
        let taskP = open(primary)
        // Registry 接线的连接要 hello 核准身份才落业务帧（impl1 #2）
        secondary.handleIncoming(text(["type": "hello", "hub_id": "HUB-S"]), source: taskS)
        primary.handleIncoming(text(["type": "hello", "hub_id": "HUB-P"]), source: taskP)
        XCTAssertTrue(spin { secondary.identityVerifiedForTesting && primary.identityVerifiedForTesting })
        primary.handleIncoming(text(["type": "terminal_state", "windows": [
            ["code": "pppp", "title": "主", "phase": "working"],
            ["code": "mp-cc", "phase": "waiting", "engine": "claude"],
        ]]), source: taskP)
        XCTAssertTrue(spin { storeP.windows.map(\.code) == ["pppp"] })
        secondary.handleIncoming(text(["type": "terminal_state", "windows": [
            ["code": "ssss", "title": "附加", "phase": "idle"],
            ["code": "mp-cc", "phase": "working", "engine": "claude"],
        ]]), source: taskS)
        XCTAssertTrue(spin { storeS.windows.map(\.code) == ["ssss"] })
        settle()
        XCTAssertEqual(storeP.windows.map(\.code), ["pppp"], "附加 hub 一帧不再把主 hub 的窗口列表整个换掉")
        XCTAssertEqual(storeP.sessionStates["mp-cc"]?.phase, "waiting", "同名 mp-cc 各是各的")
        XCTAssertEqual(storeS.sessionStates["mp-cc"]?.phase, "working")
        XCTAssertEqual(TerminalWindowStore.shared.syncSeq, sharedSeq)

        // 命令出口走绑定的那台
        storeS.close("ssss")
        storeS.refresh()
        XCTAssertTrue(spin { secondaryWire.sent("close_window").count == 1 && secondaryWire.sent("list_windows").count == 1 })
        XCTAssertTrue(primaryWire.sent("close_window").isEmpty)
        XCTAssertTrue(primaryWire.sent("list_windows").isEmpty)

        // 60s 对账结果 + 离线缓存进那台自己的 suite
        secondary.handleIncoming(text(["type": "list_windows_result", "windows": [
            ["code": "zzzz", "created_at": "2026-11-03T00:00:00Z", "alive": true],
        ]]), source: taskS)
        let suiteS = r.defaults(for: id)!
        XCTAssertTrue(spin { storeS.windows.map(\.code) == ["zzzz"] && suiteS.data(forKey: "terminalWindowsCache") != nil })
        XCTAssertNil(primarySuite.data(forKey: "terminalWindowsCache"))
        XCTAssertEqual(TerminalWindowStore(client: secondary, defaults: suiteS).windows.map(\.code), ["zzzz"], "重启读回那台自己的缓存")
        XCTAssertEqual(storeP.windows.map(\.code), ["pppp"])

        // 删 hub：store 一起拆，迟到帧落不进来
        r.remove(id)
        XCTAssertNil(r.windowStore(for: id))
        secondary.handleIncoming(text(["type": "terminal_state", "windows": [["code": "late"]]]), source: taskS)
        settle()
        XCTAssertEqual(storeS.windows.map(\.code), ["zzzz"])
    }

    /// 没接 store 的附加 client（不经 Registry 建的）：terminal_state 哪儿都不写，绝不落到主 hub 的 .shared
    @MainActor
    func testUnwiredSecondaryTerminalStateNeverHitsShared() {
        let (client, _) = newClient(hubId: "h-bare")
        let task = open(client)
        let seq = TerminalWindowStore.shared.syncSeq
        client.handleIncoming(text(["type": "terminal_state", "windows": [["code": "xxxx"]]]), source: task)
        settle()
        XCTAssertEqual(TerminalWindowStore.shared.syncSeq, seq)
    }

    @MainActor
    func testSessionModelAndPhaseKeyedByHubSoSameNameDoesNotClobber() {
        let (primary, _) = newClient(hubId: CCBridgeWebSocketClient.primaryHubId)
        let hub = "h-\(UUID().uuidString)"
        let (secondary, _) = newClient(hubId: hub)
        let taskP = open(primary)
        let taskS = open(secondary)
        let models = CCSessionModelStore.shared
        let phases = CCSessionPhaseStore.shared
        let chatP = "C-\(UUID().uuidString)", chatS = "C-\(UUID().uuidString)", chatP2 = "C-\(UUID().uuidString)"

        primary.handleIncoming(text(["type": "session_model", "session_name": "mp-cc", "model": "opus-p"]), source: taskP)
        secondary.handleIncoming(text(["type": "session_model", "session_name": "mp-cc", "model": "opus-s"]), source: taskS)
        XCTAssertTrue(spin { models.entry(for: "mp-cc", hubId: hub).model == "opus-s" })
        XCTAssertEqual(models.entry(for: "mp-cc").model, "opus-p", "主 hub 的胶囊不被附加 hub 顶掉")
        XCTAssertEqual(ModelCapsule.entry(isCCBridge: true, sessionName: "mp-cc")?.model, "opus-p", "读侧不传 = 主 hub")
        XCTAssertEqual(ModelCapsule.entry(isCCBridge: true, sessionName: "mp-cc", hubId: hub)?.model, "opus-s")
        XCTAssertEqual(CCSessionModelStore.key(hubId: CCBridgeWebSocketClient.primaryHubId, sessionName: "mp-cc"), "mp-cc", "主 hub 旧 key 形态")

        func phase(_ chat: String, _ p: String) -> [String: Any] {
            ["type": "session_phase", "session_name": "mp-cc", "chat_id": chat, "phase": p, "tools": 1]
        }
        primary.handleIncoming(text(phase(chatP, "working")), source: taskP)
        secondary.handleIncoming(text(phase(chatS, "waiting")), source: taskS)
        XCTAssertTrue(spin { phases.phase(for: chatS, hubId: hub)?.phase == .waiting && phases.phase(for: chatP)?.phase == .working })
        settle()
        XCTAssertEqual(phases.phase(for: chatP)?.phase, .working, "另一台同名会话换了对话不清这台的")
        XCTAssertNil(phases.phase(for: chatS), "附加 hub 的阶段不冒到主 hub")
        XCTAssertNil(phases.phase(for: chatP, hubId: hub))

        // 同一台里同名会话改从别的对话发：照旧清旧对话，另一台不受影响
        primary.handleIncoming(text(phase(chatP2, "working")), source: taskP)
        XCTAssertTrue(spin { phases.phase(for: chatP2)?.phase == .working })
        XCTAssertNil(phases.phase(for: chatP))
        XCTAssertEqual(phases.phase(for: chatS, hubId: hub)?.phase, .waiting)

        // 删 hub 时一起清
        phases.removeHub(hub)
        models.removeHub(hub)
        XCTAssertNil(phases.phase(for: chatS, hubId: hub))
        XCTAssertNil(models.entry(for: "mp-cc", hubId: hub).model)
        XCTAssertEqual(models.entry(for: "mp-cc").model, "opus-p")
        XCTAssertEqual(phases.phase(for: chatP2)?.phase, .working)
    }

    @MainActor
    func testRegistryRemoveClearsThatHubsPhaseAndModel() {
        let (primary, _) = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: std)
        let r = makeRegistry(primary: primary)
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "B", pairing: CCHubPairing(primaryURL: "ws://192.168.7.7:7890/cc"), token: "tb") else { return XCTFail() }
        let chat = "C-\(UUID().uuidString)"
        let session = "mp-cc-\(UUID().uuidString.prefix(6))"
        made[id]!.handleIncoming(text(["type": "session_phase", "session_name": session, "chat_id": chat, "phase": "working", "tools": 1]))
        made[id]!.handleIncoming(text(["type": "session_model", "session_name": session, "model": "m"]))
        XCTAssertTrue(spin { CCSessionPhaseStore.shared.phase(for: chat, hubId: id) != nil && CCSessionModelStore.shared.entry(for: session, hubId: id).model == "m" })
        r.remove(id)
        XCTAssertNil(CCSessionPhaseStore.shared.phase(for: chat, hubId: id))
        XCTAssertNil(CCSessionModelStore.shared.entry(for: session, hubId: id).model)
    }

    /// transport_policies：只写那台的 suite；旧连接的迟到表不写（R8）
    func testTransportPoliciesWriteOwnSuiteAndOnlyFromLiveConnection() {
        let primarySuite = newSuite(), secondarySuite = newSuite()
        let (primary, _) = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: primarySuite)
        let (secondary, _) = newClient(hubId: "h-pol", defaults: secondarySuite)
        let taskP = open(primary)
        let stale = open(secondary)
        let live = open(secondary)
        XCTAssertFalse(stale === live)

        primary.handleIncoming(text(["type": "transport_policies", "policies": ["mp-cc": "tmux"]]), source: taskP)
        secondary.handleIncoming(text(["type": "transport_policies", "policies": ["mp-cc": "stream"]]), source: stale)
        settle()
        XCTAssertNil(secondarySuite.object(forKey: CCBridgeWebSocketClient.transportPolicyKey), "旧连接的迟到表不写")
        secondary.handleIncoming(text(["type": "transport_policies", "policies": ["mp-cc": "stream"]]), source: live)
        XCTAssertTrue(spin { CCBridgeWebSocketClient.transportPolicy(for: "mp-cc", hub: secondary) == "stream" })
        XCTAssertEqual(CCBridgeWebSocketClient.transportPolicy(for: "mp-cc", hub: primary), "tmux", "主 hub 的表不被顶掉")

        // 失效之后不写
        secondary.invalidate()
        secondary.handleIncoming(text(["type": "transport_policies", "policies": ["mp-cc": "tmux"]]), source: live)
        settle()
        XCTAssertEqual((secondarySuite.dictionary(forKey: CCBridgeWebSocketClient.transportPolicyKey) as? [String: String])?["mp-cc"], "stream")
    }

    /// C 类 terminal_usage：附加 hub 的终端顶卡照样收到用量，小组件（App Group latest.json）只主 hub 写
    func testTerminalUsageCallbackOnBothButWidgetSnapshotPrimaryOnly() {
        for primaryHub in [false, true] {
            let (client, _) = newClient(hubId: primaryHub ? CCBridgeWebSocketClient.primaryHubId : "h-usage")
            let task = open(client)
            let writes = Counter()
            client.usageSnapshotWriterForTesting = { writes.add($0) }
            var got: TerminalUsage?
            client.attachTerminal(session: "mp-cc", cols: 80, rows: 24, onInit: { _, _ in }, onChunk: { _ in }, onError: { _ in },
                                  onUsage: { got = $0 })
            client.drainPipelinesForTesting()
            client.handleIncoming(text(["type": "terminal_usage", "session_name": "mp-cc", "model": "opus", "ctx": 42]), source: task)
            XCTAssertTrue(spin { got != nil }, "primary=\(primaryHub)：顶卡回调照走")
            XCTAssertEqual(got?.ctx, 42)
            settle(0.1)
            XCTAssertEqual(writes.list, primaryHub ? ["mp-cc"] : [], "primary=\(primaryHub)")
        }
    }

    // MARK: - 读侧接口（B1 / B3 接）

    @MainActor
    func testOwnershipHelpersDefaultToPrimary() {
        XCTAssertEqual(TerminalAgentConversation(session: "mp-cc", title: "t", openedAt: Date()).hubId, CCBridgeWebSocketClient.primaryHubId)
        let store = CCSessionPhaseStore()
        store.apply(CCSessionPhase(frame: ["session_name": "mp-cc", "chat_id": "c1", "phase": "working"])!)
        XCTAssertEqual(store.phase(for: "c1")?.phase, .working)
        XCTAssertEqual(store.phase(for: "c1", hubId: CCBridgeWebSocketClient.primaryHubId)?.phase, .working)
        XCTAssertNil(store.phase(for: "c1", hubId: "other"))
    }
}
