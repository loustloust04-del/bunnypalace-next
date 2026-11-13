import XCTest
import SwiftData
@testable import 记忆花园

/// plan-multi-hub B1 / B3.1–B3.5：对话归属、按对话的 hub 发送 / 拒发、来源 hub（AskUser / 迟到帧 / 阶段）、focus 分发、
/// 终端显式 client、改绑、扫码落点。注入 defaults suite + 口令替身 + 假 task，不碰真库 / 真钥匙串 / 真 hub。
@MainActor
final class CCHubRoutingTests: XCTestCase {
    /// 记下每台 client 发出的每一帧（completion 回主线程成功）
    final class Wire {
        private(set) var frames: [[String: Any]] = []

        func install(on client: CCBridgeWebSocketClient) {
            client.setTransmitHookForTesting { [weak self] _, text, completion in
                DispatchQueue.main.async {
                    let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                    self?.frames.append(obj)
                    completion(nil)
                }
            }
        }

        func sent(_ type: String) -> [[String: Any]] { frames.filter { $0["type"] as? String == type } }
        func types() -> Set<String> { Set(frames.compactMap { $0["type"] as? String }) }
    }

    private var stdName: String!
    private var std: UserDefaults!
    private var prefix: String!
    private var secrets: CCHubRegistryTests.FakeSecrets!
    private var session: URLSession!
    private var made: [String: CCBridgeWebSocketClient] = [:]
    private var wires: [String: Wire] = [:]
    private var extraClients: [CCBridgeWebSocketClient] = []
    private var primaryWire: Wire!
    private var harness: PromptRealPathHarness?

    private let pairingA = CCHubPairing(primaryURL: "ws://192.168.9.2:7890/cc")
    private let pairingB = CCHubPairing(primaryURL: "ws://192.168.9.3:7890/cc")

    override func setUp() async throws {
        try await super.setUp()
        stdName = "CCHubRoutingTests.std.\(UUID().uuidString)"
        std = UserDefaults(suiteName: stdName)!
        prefix = "CCHubRoutingTests.hub.\(UUID().uuidString)."
        secrets = CCHubRegistryTests.FakeSecrets()
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        for c in Array(made.values) + extraClients {
            c.disconnect()
            c.setTransmitHookForTesting(nil)
        }
        for id in made.keys { UserDefaults(suiteName: prefix + id)?.removePersistentDomain(forName: prefix + id) }
        made = [:]
        wires = [:]
        extraClients = []
        session.invalidateAndCancel()
        std.removePersistentDomain(forName: stdName)
        try await super.tearDown()
    }

    // MARK: - 工具

    private func makeRegistry() -> (CCHubRegistry, CCBridgeWebSocketClient) {
        let p = CCBridgeWebSocketClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: std, transportOffMain: false)
        extraClients.append(p)
        primaryWire = Wire()
        primaryWire.install(on: p)
        let r = CCHubRegistry(primary: p, standard: std, suitePrefix: prefix, secrets: secrets, originDefaults: std) { [unowned self] id, d in
            let c = CCBridgeWebSocketClient(hubId: id, defaults: d, transportOffMain: false)
            let w = Wire()
            w.install(on: c)
            self.made[id] = c
            self.wires[id] = w
            return c
        }
        return (r, p)
    }

    private func add(_ r: CCHubRegistry, _ name: String, pairing: CCHubPairing, token: String) -> String {
        guard case .added(let id) = r.addHub(name: name, pairing: pairing, token: token) else {
            XCTFail("加不上 \(name)")
            return ""
        }
        return id
    }

    /// 测试跑在主队列上，不能 RunLoop.run 等主队列：让出去等
    @discardableResult
    private func waitFor(timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return cond()
    }

    private func expect(_ cond: () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await waitFor(cond)
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    private func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }

    /// 当成「刚连上」并收到 hello（Registry 接线的 client 要 hello 核准身份后才收发业务帧，impl1 #2）。hubId nil = 老 hub 不报
    private func openAsync(_ client: CCBridgeWebSocketClient, hello hubId: String? = nil) async {
        let u = URL(string: "ws://127.0.0.1:9/cc")!
        let task = session.webSocketTask(with: u)
        client.adoptTaskForTesting(task, url: u)
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        let connected = await waitFor { client.isConnected && client.currentTaskForTesting === task }
        XCTAssertTrue(connected)
        var hello: [String: Any] = ["type": "hello"]
        hello["hub_id"] = hubId
        client.handleIncoming(String(data: try! JSONSerialization.data(withJSONObject: hello), encoding: .utf8)!, source: task)
        let verified = await waitFor { client.identityVerifiedForTesting }
        XCTAssertTrue(verified)
    }

    private func makeHarness() async throws -> (PromptRealPathHarness, ProviderModel, Conversation) {
        let h = try await PromptRealPathHarness.make(PromptScenario(name: "multi-hub-route", profileId: "xctest-multihub-\(UUID().uuidString)",
                                                                    voiceHint: false, memoryFixtures: false))
        harness = h
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-multihub")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        h.viewModel.ccSentLedger = CCSentHubLedger(defaults: std)
        h.viewModel.ccOriginLedger = CCChatOriginLedger(defaults: std)
        return (h, cc, conversation)
    }

    private func send(_ h: PromptRealPathHarness, _ model: ProviderModel, _ text: String) -> Bool {
        h.viewModel.sendMessage(text, model: model, profile: h.profile, preset: h.preset,
                                providerManager: h.providerManager, context: h.context)
    }

    private let questions: [[String: Any]] = [["question": "选哪个？", "options": [["label": "甲"], ["label": "乙"]]]]

    // MARK: - 归属

    func testHubIdOfConversationNilIsPrimary() {
        let c = Conversation(id: "c1", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        XCTAssertEqual(CCHubRegistry.hubId(of: c), CCHubRegistry.primaryId)
        c.ccHubId = "hub-x"
        XCTAssertEqual(CCHubRegistry.hubId(of: c), "hub-x")
    }

    func testNewCCConversationGetsExplicitHubAndIdentityOldOnesStayNil() {
        let (r, _) = makeRegistry()
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        let fresh = Conversation(id: "n1", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        r.bindNewCCConversation(fresh)
        XCTAssertEqual(fresh.ccHubId, "primary", "主 hub 也写明确值")
        XCTAssertEqual(fresh.ccHubIdentity, "HUB-P")

        let old = Conversation(id: "o1", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        old.ccBridgeSessionName = "mp-cc"
        r.bindNewCCConversation(old)
        XCTAssertNil(old.ccHubId, "已有会话名的老对话 = 主 hub，保持 nil")

        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        r.lastHubId = a
        let second = Conversation(id: "n2", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        r.bindNewCCConversation(second)
        XCTAssertEqual(second.ccHubId, a, "默认用上次选的那台")
        r.remove(a)
        XCTAssertEqual(r.lastHubId, CCHubRegistry.primaryId, "那台不在了 → 主 hub")
    }

    /// impl1 #3：主 hub 的 hub_id 还不知道 → 新对话留 nil（老语义），明确的 "primary" 一定带 hub_id
    func testNewConversationStaysNilWhilePrimaryIdentityUnknown() {
        let (r, _) = makeRegistry()
        let fresh = Conversation(id: "n0", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        r.bindNewCCConversation(fresh)
        XCTAssertNil(fresh.ccHubId)
        XCTAssertNil(fresh.ccHubIdentity)
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        r.bindNewCCConversation(fresh)
        XCTAssertEqual(fresh.ccHubId, CCHubRegistry.primaryId, "知道了（还没起会话）再写明确值")
        XCTAssertEqual(fresh.ccHubIdentity, "HUB-P")
    }

    // MARK: - 路由（B3.1）

    func testRouteRefusesUnboundRemovedAndNeverFallsBackToPrimary() {
        let (r, p) = makeRegistry()
        if case .success(let c) = r.route(CCHubRegistry.primaryId) { XCTAssertTrue(c === p) } else { XCTFail() }
        XCTAssertEqual(r.route(CCHubRegistry.unboundHubId).failure, .unbound)
        XCTAssertEqual(r.route("never-existed").failure, .removed)
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        if case .success(let c) = r.route(a) { XCTAssertTrue(c === made[a]) } else { XCTFail() }
        r.remove(a)
        XCTAssertEqual(r.route(a).failure, .removed)
    }

    func testRouteRefusesPendingPairingAndIdentityChanged() async {
        let (r, _) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        secrets.values[CCHubRegistry.keychainAccount(for: a)] = "changed-elsewhere"
        r.start { _ in }
        await expect({ r.status(for: a) == .needsPairing })
        XCTAssertEqual(r.route(a).failure, .needsPairing)
        made[b]!.handleIncoming(#"{"type":"hello","hub_id":"HUB-B"}"#)
        await expect({ r.identity(of: b) == "HUB-B" })
        made[b]!.handleIncoming(#"{"type":"hello","hub_id":"HUB-OTHER"}"#)
        await expect({ r.status(for: b) == .identityChanged })
        XCTAssertEqual(r.route(b).failure, .identityChanged)
    }

    func testConversationOnSecondaryHubSendsThroughThatHubOnly() async throws {
        let (h, cc, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(p)
        await openAsync(made[a]!)
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        XCTAssertTrue(send(h, cc, "发到纽约"))
        await expect({ self.wires[a]!.sent("send").count == 1 }, "走绑的那台")
        XCTAssertEqual(wires[a]!.sent("send").first?["chat_id"] as? String, conversation.id)
        await pause()
        XCTAssertTrue(primaryWire.sent("send").isEmpty, "不发主 hub")
    }

    func testLegacyNilConversationSendsThroughPrimary() async throws {
        let (h, cc, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(p)
        await openAsync(made[a]!)
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccBridgeSessionName = "mp-cc-legacy"
        XCTAssertNil(conversation.ccHubId)
        XCTAssertTrue(send(h, cc, "老对话"))
        await expect({ self.primaryWire.sent("send").count == 1 })
        XCTAssertNil(conversation.ccHubId, "老对话不补写")
        await pause()
        XCTAssertTrue(wires[a]!.sent("send").isEmpty)
    }

    func testUnavailableHubRefusesWithoutFallback() async throws {
        let (h, cc, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(p)
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        let pathCount = h.viewModel.currentPath.count

        conversation.ccHubId = CCHubRegistry.unboundHubId
        XCTAssertEqual(h.viewModel.ccSendBlocker(for: conversation), .unbound)
        XCTAssertFalse(send(h, cc, "待绑定"))
        XCTAssertEqual(h.viewModel.transientNotice?.text, CCHubRegistry.Unavailable.unbound.message)

        r.remove(a)
        conversation.ccHubId = a
        XCTAssertFalse(send(h, cc, "删掉的"))
        XCTAssertEqual(h.viewModel.transientNotice?.text, CCHubRegistry.Unavailable.removed.message)
        XCTAssertFalse(send(h, cc, "/compact"), "斜杠命令同样拒")

        await pause()
        XCTAssertEqual(h.viewModel.currentPath.count, pathCount, "没建 user 节点，输入框留着")
        XCTAssertTrue(primaryWire.sent("send").isEmpty && primaryWire.sent("command").isEmpty, "不回落主 hub")
    }

    func testPendingPairingHubRefusesSend() async throws {
        let (h, cc, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        secrets.values[CCHubRegistry.keychainAccount(for: a)] = "changed-elsewhere"
        r.start { _ in }
        await expect({ r.status(for: a) == .needsPairing })
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        XCTAssertFalse(send(h, cc, "待配对"))
        XCTAssertEqual(h.viewModel.transientNotice?.text, CCHubRegistry.Unavailable.needsPairing.message)
        await pause()
        XCTAssertTrue(primaryWire.sent("send").isEmpty && wires[a]!.sent("send").isEmpty)
    }

    func testSendStatusIsFoundOnTheHubThatHoldsItAndRetriesThere() {
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        var announced: [String] = []
        let sub = r.sendMembership.sink { announced.append($0) }
        made[a]!.sendTracker.store.set("m1", state: .failed, reason: "x", retryable: true, hasFrame: false)
        let status = r.sendStatus(for: "m1")
        XCTAssertTrue(status?.client === made[a])
        XCTAssertFalse(status?.client === p)
        XCTAssertEqual(announced, ["m1"])
        XCTAssertNil(r.sendStatus(for: "m2"))
        sub.cancel()
    }

    // MARK: - 来源 hub（B3.2）

    func testAskUserAnswerAndSkipGoBackToAskingHubEvenAfterRebind() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(p)
        await openAsync(made[a]!)
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()

        h.viewModel.presentCCAskUser(chatId: conversation.id, toolUseId: "tu1", questions: questions, fromHub: a, context: h.context)
        XCTAssertEqual(h.viewModel.pendingCCQuestion?.origin.hubId, a)
        XCTAssertTrue(r.rebind(conversation, to: CCHubRegistry.primaryId))
        h.viewModel.recordUserAnswer(.options([1]), at: 0)
        h.viewModel.completeActiveAskCard()
        await expect({ self.wires[a]!.sent("ask_user_answer").count == 1 }, "回答回原来那台")
        XCTAssertEqual(wires[a]!.sent("ask_user_answer").first?["tool_use_id"] as? String, "tu1")

        h.viewModel.presentCCAskUser(chatId: conversation.id, toolUseId: "tu2", questions: questions, fromHub: a, context: h.context)
        h.viewModel.handleCCAskUserStale(toolUseId: "tu2", fromHub: CCHubRegistry.primaryId)
        XCTAssertNotNil(h.viewModel.pendingCCQuestion, "别的台的失效帧收不走这张卡")
        h.viewModel.dismissActiveAskCard()
        await expect({ self.wires[a]!.sent("ask_user_answer").count == 2 }, "跳过也回原来那台")
        await pause()
        XCTAssertTrue(primaryWire.sent("ask_user_answer").isEmpty)
    }

    func testAskUserAnswerRefusedWhenThatSlotNowIsAnotherMachine() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(made[a]!)
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        let d = try XCTUnwrap(r.defaults(for: a))
        d.set("HUB-A", forKey: CCHubPairingStore.hubIdentityKey)
        h.viewModel.presentCCAskUser(chatId: conversation.id, toolUseId: "tu1", questions: questions, fromHub: a, context: h.context)
        d.set(CCHubPairingStore.gen(d) + 1, forKey: CCHubPairingStore.genKey)
        d.set("HUB-Z", forKey: CCHubPairingStore.hubIdentityKey)
        h.viewModel.recordUserAnswer(.options([0]), at: 0)
        h.viewModel.completeActiveAskCard()
        await pause()
        XCTAssertTrue(wires[a]!.sent("ask_user_answer").isEmpty)
        XCTAssertNotNil(h.viewModel.transientNotice)
    }

    /// 真实 Mac 路径（impl1 #4）：外部 hub 问的题没答，Mac 切到内嵌 hub（配对代次不变、只换了 hub_id）→ 答案不发给新那台
    func testMacLocalSwitchRefusesOldAskUserAnswer() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        r.start { _ in }
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = CCHubRegistry.primaryId
        try h.context.save()
        r.switchPrimaryLocally(urls: [URL(string: "ws://127.0.0.1:7890/cc")!], token: "t-ext")
        await openAsync(p, hello: "HUB-EXT")
        XCTAssertEqual(r.identity(of: CCHubRegistry.primaryId), "HUB-EXT")
        let gen = CCHubPairingStore.gen(std)
        h.viewModel.presentCCAskUser(chatId: conversation.id, toolUseId: "tu1", questions: questions, fromHub: CCHubRegistry.primaryId, context: h.context)
        XCTAssertEqual(h.viewModel.pendingCCQuestion?.origin.identity, "HUB-EXT")

        r.switchPrimaryLocally(urls: [URL(string: "ws://127.0.0.1:61234/cc")!], token: "t-emb")
        await openAsync(p, hello: "HUB-EMB")
        XCTAssertEqual(r.identity(of: CCHubRegistry.primaryId), "HUB-EMB", "本机切换：新 hub_id 直接核准")
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready, "不停住")
        XCTAssertEqual(CCHubPairingStore.gen(std), gen, "配对代次没变（真实路径就是只换身份）")

        h.viewModel.recordUserAnswer(.options([0]), at: 0)
        h.viewModel.completeActiveAskCard()
        await pause()
        XCTAssertTrue(primaryWire.sent("ask_user_answer").isEmpty, "答案不发给内嵌 hub")
        XCTAssertNotNil(h.viewModel.transientNotice)
    }

    /// R5.3：主电脑口令被拒待配对后，本机切换（Mac 内嵌 hub）用对的口令连上、这一代核准 → 待配对解开，route 放行
    func testLocalSwitchApprovalClearsNeedsPairing() async throws {
        let (r, p) = makeRegistry()
        std.set("ws://10.0.0.1:7890/cc", forKey: CCBridgeEndpoints.overrideKey)
        std.set(CCHubPairingStore.fingerprint("t1"), forKey: CCHubPairingStore.fingerprintKey)
        secrets.values[CCHubRegistry.keychainAccount(for: CCHubRegistry.primaryId)] = "tampered"
        r.start { _ in }
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .needsPairing)
        if case .success = r.route(CCHubRegistry.primaryId) { XCTFail("待配对时 route 报出来") }

        r.switchPrimaryLocally(urls: [URL(string: "ws://127.0.0.1:61234/cc")!], token: "t-emb")
        await openAsync(p, hello: "HUB-EMB")
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready)
        XCTAssertFalse(p.isPairingHeld)
        if case .failure(let why) = r.route(CCHubRegistry.primaryId) { XCTFail("核准过的本机连接不再拦：\(why)") }
    }

    /// recheck1 #4：Mac 切到内嵌 hub B、B 的 hello 还没到（defaults 里还是 A 的身份）时回答 A 的旧卡 → 拒绝，B 一帧答案都不收；
    /// hello 到了也不补发
    func testMacLocalSwitchBeforeHelloRefusesOldAnswerAndNeverFlushesIt() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        r.start { _ in }
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = CCHubRegistry.primaryId
        try h.context.save()
        r.switchPrimaryLocally(urls: [URL(string: "ws://127.0.0.1:7890/cc")!], token: "t-ext")
        await openAsync(p, hello: "HUB-A")
        h.viewModel.presentCCAskUser(chatId: conversation.id, toolUseId: "tu1", questions: questions, fromHub: CCHubRegistry.primaryId, context: h.context)
        XCTAssertNotNil(h.viewModel.pendingCCQuestion)

        r.switchPrimaryLocally(urls: [URL(string: "ws://127.0.0.1:61234/cc")!], token: "t-emb")
        let u = URL(string: "ws://127.0.0.1:61234/cc")!
        let taskB = session.webSocketTask(with: u)
        p.adoptTaskForTesting(taskB, url: u)
        p.urlSession(session, webSocketTask: taskB, didOpenWithProtocol: nil)
        await expect({ p.isConnected && p.currentTaskForTesting === taskB })
        XCTAssertEqual(r.identity(of: CCHubRegistry.primaryId), "HUB-A", "B 的 hello 还没到：defaults 还是 A")
        XCTAssertFalse(p.isIdentityVerified)

        h.viewModel.recordUserAnswer(.options([0]), at: 0)
        h.viewModel.completeActiveAskCard()
        XCTAssertNotNil(h.viewModel.transientNotice, "拒绝并提示")
        p.handleIncoming(#"{"type":"hello","hub_id":"HUB-B"}"#, source: taskB)
        await expect({ p.isIdentityVerified })
        await pause()
        XCTAssertTrue(primaryWire.sent("ask_user_answer").isEmpty, "B 收到 0 帧答案（hello 到了也不补发）")
    }

    /// 同一台换了目标（附加 hub 改配对 → 交互代次推进），重新握手核准的 hub_id 就是问题来源那台：照发
    func testAskUserAnswerAllowedAfterRetargetWhenVerifiedIdentityMatches() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(made[a]!, hello: "HUB-A")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        h.viewModel.presentCCAskUser(chatId: conversation.id, toolUseId: "tu1", questions: questions, fromHub: a, context: h.context)
        let epoch = made[a]!.interactionEpoch
        XCTAssertEqual(r.updatePairing(a, CCHubPairing(primaryURL: "ws://192.168.9.20:7890/cc"), token: "ta2"), .updated)
        XCTAssertNotEqual(made[a]!.interactionEpoch, epoch, "换了目标")
        await openAsync(made[a]!, hello: "HUB-A")
        h.viewModel.recordUserAnswer(.options([1]), at: 0)
        h.viewModel.completeActiveAskCard()
        await expect({ self.wires[a]!.sent("ask_user_answer").count == 1 }, "当前连接核准的就是那台")
    }

    /// 身份已知且矛盾优先拒绝：配对代次、交互代次都没变也不放行
    func testAskUserAnswerRefusedWhenOnlyIdentityChanged() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(made[a]!, hello: "HUB-A")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        h.viewModel.presentCCAskUser(chatId: conversation.id, toolUseId: "tu1", questions: questions, fromHub: a, context: h.context)
        let origin = try XCTUnwrap(h.viewModel.pendingCCQuestion?.origin)
        r.defaults(for: a)?.set("HUB-Z", forKey: CCHubPairingStore.hubIdentityKey)
        let now = ConversationViewModel.CCHubOrigin(made[a]!)
        XCTAssertEqual(now.gen, origin.gen)
        XCTAssertEqual(now.epoch, origin.epoch)
        XCTAssertFalse(origin.isSameMachine(as: now))
        h.viewModel.recordUserAnswer(.options([0]), at: 0)
        h.viewModel.completeActiveAskCard()
        await pause()
        XCTAssertTrue(wires[a]!.sent("ask_user_answer").isEmpty)
    }

    /// hub_id 有一边不知道：配对代次和交互代次（换目标就推进）都得没变
    func testOriginWithoutIdentityNeedsSameGenAndEpoch() {
        let d = UserDefaults(suiteName: "CCHubRoutingTests.origin.\(UUID().uuidString)")!
        let c = CCBridgeWebSocketClient(hubId: "h-origin", defaults: d)
        extraClients.append(c)
        c.connect(urls: [URL(string: "ws://10.0.0.1:7890/cc")!], token: "a")
        XCTAssertFalse(ConversationViewModel.CCHubOrigin(c).verified, "没有连接 = 没核准")
        let u = URL(string: "ws://10.0.0.1:7890/cc")!
        c.adoptTaskForTesting(session.webSocketTask(with: u), url: u)
        let origin = ConversationViewModel.CCHubOrigin(c)
        XCTAssertTrue(origin.isSameMachine(as: ConversationViewModel.CCHubOrigin(c)))
        c.connect(urls: [URL(string: "ws://10.0.0.2:7890/cc")!], token: "a")
        XCTAssertFalse(origin.isSameMachine(as: ConversationViewModel.CCHubOrigin(c)), "换了目标")
        let before = ConversationViewModel.CCHubOrigin(c)
        c.advanceInteractionEpoch()
        XCTAssertFalse(before.isSameMachine(as: ConversationViewModel.CCHubOrigin(c)), "显式切换推进交互代次")
        d.set("HUB-1", forKey: CCHubPairingStore.hubIdentityKey)
        let known = ConversationViewModel.CCHubOrigin(c)
        c.advanceInteractionEpoch()
        XCTAssertFalse(known.isSameMachine(as: ConversationViewModel.CCHubOrigin(c)),
                       "代次变了、当前连接核准时没报 hub_id：defaults 里同一个历史身份不算（recheck1 #4）")
    }

    // MARK: - 临时握手（impl1 #5）：真实 handshakeProbe 接线

    func testClassifyPairingProbeOnlyHandshakesAndWritesNothing() async {
        let (r, _) = makeRegistry()
        let wire = Wire()
        let chat = "C-probe-\(UUID().uuidString)"
        final class Seen { var probe: CCBridgeWebSocketClient?; var delivered = 0; var leakedKeys: [String]?; var address: String? }
        let seen = Seen()
        let watchedKeys = [CCBridgeWebSocketClient.transportPolicyKey, CCBridgeWebSocketClient.keepalivePolicyKey,
                           "ccSeenReplyIds", "ccSeenThinkingIds", "ccReplyCursorTs", "terminalWindowsCache", CCHubPairingStore.hubIdentityKey]
        CCHubRegistry.probeClientHookForTesting = { [session] client in
            seen.probe = client
            wire.install(on: client)
            client.onProactiveMessage = { _, _, _, _, _, _, _, _, _ in seen.delivered += 1; return true }
            let u = URL(string: "ws://192.168.9.2:7890/cc?token=tp")!
            let task = session!.webSocketTask(with: u)
            client.adoptTaskForTesting(task, url: u)
            client.urlSession(session!, webSocketTask: task, didOpenWithProtocol: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for f: [String: Any] in [
                    ["type": "reply", "chat_id": chat, "content": "replayed", "reply_id": "rid-p", "ts": 5],
                    ["type": "thinking", "chat_id": chat, "mp_msg_id": "m", "content": "t", "thinking_id": "th-p", "ts": 6],
                    ["type": "transport_policies", "policies": ["mp-cc": "stream"]],
                    ["type": "session_phase", "session_name": "mp-cc", "chat_id": chat, "phase": "working"],
                    ["type": "terminal_state", "windows": [["code": "pppp"]]],
                ] {
                    client.handleIncoming(String(data: try! JSONSerialization.data(withJSONObject: f), encoding: .utf8)!, source: task)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    seen.leakedKeys = watchedKeys.filter { client.defaults.object(forKey: $0) != nil }
                    seen.address = UserDefaults(suiteName: CCHubRegistry.probeSuiteName)?.string(forKey: CCBridgeEndpoints.overrideKey)
                    client.handleIncoming(#"{"type":"hello","hub_id":"HUB-PROBE"}"#, source: task)
                }
            }
        }
        defer { CCHubRegistry.probeClientHookForTesting = nil }
        let match = await r.classifyPairing(pairingA, token: "tp")
        XCTAssertEqual(match, .addNew(reportedIdentity: "HUB-PROBE"))
        await pause()
        XCTAssertTrue(wire.frames.isEmpty, "一帧不发（含 set_cc_config / focus / client_info）：\(wire.types())")
        XCTAssertEqual(seen.delivered, 0, "回放的 reply 不落")
        XCTAssertEqual(seen.leakedKeys, [], "临时 suite 里除了地址什么都没写")
        XCTAssertEqual(seen.address, pairingA.primaryURL, "认哪台用的是固定那一个 suite，不按次起新名字（B7.2 B6）")
        XCTAssertNil(UserDefaults(suiteName: CCHubRegistry.probeSuiteName)?.string(forKey: CCBridgeEndpoints.overrideKey), "用完清掉")
        XCTAssertNil(CCSessionPhaseStore.shared.phase(for: chat, hubId: seen.probe?.hubId ?? ""))
        XCTAssertTrue(seen.probe?.isInvalidated == true, "用完就失效")
        XCTAssertEqual(r.hubs.count, 1, "Registry 一个字节不写")
    }

    func testLateFramesFromAnotherHubAreDropped() async throws {
        let (h, cc, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        await openAsync(p)
        await openAsync(made[a]!)
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        let vm = h.viewModel
        XCTAssertTrue(vm.acceptsCCFrame(chatId: conversation.id, fromHub: a, context: h.context))
        XCTAssertFalse(vm.acceptsCCFrame(chatId: conversation.id, fromHub: b, context: h.context), "没绑、没在那台发过")
        XCTAssertFalse(vm.acceptsCCFrame(chatId: conversation.id, fromHub: CCHubRegistry.primaryId, context: h.context))
        XCTAssertTrue(vm.acceptsCCFrame(chatId: "not-on-this-device", fromHub: b, context: h.context), "本机没有的照旧交给落库路径丢")

        XCTAssertTrue(send(h, cc, "在纽约发过"))
        await expect({ self.wires[a]!.sent("send").count == 1 })
        r.rebind(conversation, to: b)
        XCTAssertTrue(vm.acceptsCCFrame(chatId: conversation.id, fromHub: a, context: h.context), "改绑后原来那台迟到的回包照收")
        XCTAssertTrue(vm.acceptsCCFrame(chatId: conversation.id, fromHub: b, context: h.context))
        XCTAssertFalse(vm.acceptsCCFrame(chatId: conversation.id, fromHub: CCHubRegistry.primaryId, context: h.context))

        // 阶段 store 写入同样核来源（R7）
        let store = CCSessionPhaseStore()
        store.accepts = { vm.acceptsCCFrame(chatId: $0, fromHub: $1, context: h.context) }
        let frame: [String: Any] = ["session_name": "mp-cc", "chat_id": conversation.id, "phase": "working"]
        store.apply(try XCTUnwrap(CCSessionPhase(frame: frame)), hubId: CCHubRegistry.primaryId)
        XCTAssertNil(store.phase(for: conversation.id, hubId: CCHubRegistry.primaryId), "不归这台的阶段不写")
        store.apply(try XCTUnwrap(CCSessionPhase(frame: frame)), hubId: b)
        XCTAssertNotNil(store.phase(for: conversation.id, hubId: b))
    }

    // MARK: - 备份恢复（impl1 #3）

    /// A 设备的备份在主 hub 是 B 的设备上恢复：走真实恢复映射 → 待绑定，发送不落到 B
    func testRestoredBackupFromAnotherDeviceIsUnboundAndNeverSentToLocalPrimary() async throws {
        let (h, cc, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        r.reconnectPrimary(fallbackToLocal: false)
        await openAsync(p, hello: "HUB-B")
        XCTAssertEqual(r.identity(of: CCHubRegistry.primaryId), "HUB-B")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        let resolver: (String?, String?) -> String? = { [std, prefix] in
            CCHubRegistry.resolveSynced(hubId: $0, identity: $1, standard: std!, suitePrefix: prefix!)
        }
        func restore(_ hub: String?, _ identity: String?) throws -> Conversation {
            let src = Conversation(id: "r-\(UUID().uuidString)", title: "", createTime: Date(), updateTime: Date(),
                                   currentNodeId: "", provider: "cc-bridge", profileId: "xctest-restore")
            src.ccHubId = hub
            src.ccHubIdentity = identity
            let data = try JSONEncoder().encode(FullConversationDocument(model: src, nodes: [], hubIdentity: { $0.ccHubIdentity }))
            return GlobalImporter.restoredConversation(try JSONDecoder().decode(FullConversationDocument.self, from: data), hubResolver: resolver)
        }
        let fromA = try restore("primary", "HUB-A")
        XCTAssertEqual(fromA.ccHubId, CCHubRegistry.unboundHubId, "A 的主 hub ≠ 本机主 hub")
        XCTAssertEqual(fromA.ccHubIdentity, "HUB-A", "hub_id 留着，以后认得出再绑回")
        XCTAssertEqual(try restore("primary", "HUB-B").ccHubId, CCHubRegistry.primaryId, "自己的备份")
        XCTAssertEqual(try restore("primary", nil).ccHubId, CCHubRegistry.unboundHubId, "明确的 primary 不带 hub_id 不冒充本机主 hub")
        XCTAssertNil(try restore(nil, nil).ccHubId, "真正的旧数据保持 nil")

        conversation.ccHubId = fromA.ccHubId
        conversation.ccHubIdentity = fromA.ccHubIdentity
        XCTAssertFalse(send(h, cc, "恢复后发一条"))
        XCTAssertEqual(h.viewModel.transientNotice?.text, CCHubRegistry.Unavailable.unbound.message)
        await pause()
        XCTAssertTrue(primaryWire.sent("send").isEmpty, "不发给 B")
    }

    // MARK: - 先同步后识别（impl1 #12）

    /// 同步来的时候本机还不知道 hub_id → 待绑定；那台第一次报 hub_id / 加上那台 → 自动绑回。手动选过的不动
    func testSyncedBeforeIdentityKnownRebindsWhenHubIsIdentified() async throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        func synced(_ id: String, hub: String, identity: String) -> Conversation {
            let c = Conversation(id: id, title: id, createTime: Date(), updateTime: Date(), currentNodeId: "", provider: "cc-bridge")
            c.ccHubId = CCHubRegistry.resolveSynced(hubId: hub, identity: identity, standard: std, suitePrefix: prefix)
            c.ccHubIdentity = identity
            ctx.insert(c)
            return c
        }
        let onPrimary = synced("s-p", hub: "primary", identity: "HUB-P")
        let onA = synced("s-a", hub: "remote-uuid", identity: "HUB-A")
        let onX = synced("s-x", hub: "remote-uuid-2", identity: "HUB-X")
        let manual = Conversation(id: "s-m", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        manual.ccHubId = a
        manual.ccHubIdentity = "HUB-P"
        ctx.insert(manual)
        try ctx.save()
        XCTAssertEqual([onPrimary, onA, onX].map(\.ccHubId), Array(repeating: CCHubRegistry.unboundHubId, count: 3))

        r.reconnectPrimary(fallbackToLocal: false)
        await openAsync(p, hello: "HUB-P")
        r.onIdentityConfirmed = { CCHubRegistry.rebindAutoUnbound(identity: $1, to: $0, context: ctx) }
        XCTAssertEqual(onPrimary.ccHubId, CCHubRegistry.primaryId, "hook 接上前确认的补做")

        r.updateFocus(onA)
        await openAsync(made[a]!, hello: "HUB-A")
        XCTAssertEqual(onA.ccHubId, a)
        XCTAssertEqual(r.focus?.hubId, a, "正看着的对话 focus 跟着绑回那台")
        XCTAssertEqual(manual.ccHubId, a, "手动选的（不是待绑定）不动")
        XCTAssertEqual(onX.ccHubId, CCHubRegistry.unboundHubId)

        guard case .added(let x) = r.addHub(name: "东京", pairing: pairingB, token: "tx", identity: "HUB-X") else { return XCTFail() }
        XCTAssertEqual(onX.ccHubId, x, "加 hub 带 hub_id 也绑回")
        let persisted = try ctx.fetch(FetchDescriptor<Conversation>()).filter { $0.ccHubId == CCHubRegistry.unboundHubId }
        XCTAssertTrue(persisted.isEmpty)
    }

    // MARK: - 发过的 hub 持久表 + 拒收不记账（impl1 #13）

    /// 改绑后重启（新 ViewModel 只读持久表）：原来那台合法的迟到回包照收；同槽位换了 hub_id / 过期就不放行
    func testSentLedgerSurvivesRestartAndRequiresSameHubIdentity() async throws {
        let (h, cc, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        await openAsync(made[a]!, hello: "HUB-A")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        XCTAssertTrue(send(h, cc, "在纽约发过"))
        await expect({ self.wires[a]!.sent("send").count == 1 })
        XCTAssertTrue(r.rebind(conversation, to: b))
        try h.context.save()

        let restarted = ConversationViewModel()
        restarted.ccBridgeClient = p
        restarted.ccHubRegistry = r
        restarted.ccSentLedger = CCSentHubLedger(defaults: std)
        XCTAssertTrue(restarted.acceptsCCFrame(chatId: conversation.id, fromHub: a, context: h.context), "重启后改绑前那台的迟到回包照收")
        XCTAssertTrue(restarted.acceptsCCFrame(chatId: conversation.id, fromHub: b, context: h.context))
        XCTAssertFalse(restarted.acceptsCCFrame(chatId: conversation.id, fromHub: CCHubRegistry.primaryId, context: h.context))
        r.defaults(for: a)?.set("HUB-Z", forKey: CCHubPairingStore.hubIdentityKey)
        XCTAssertFalse(restarted.acceptsCCFrame(chatId: conversation.id, fromHub: a, context: h.context), "同槽位换了机器：发过一次不等于永久放行")

        let ledger = CCSentHubLedger(defaults: std)
        ledger.record(chatId: "old", hubId: a, identity: "HUB-Z", now: Date(timeIntervalSinceNow: -8 * 24 * 3600))
        XCTAssertFalse(ledger.sent(chatId: "old", hubId: a, identity: "HUB-Z"), "7 天过期")
        for i in 0..<(CCSentHubLedger.limit + 5) { ledger.record(chatId: "c\(i)", hubId: a, identity: nil) }
        XCTAssertEqual(std.array(forKey: CCSentHubLedger.key)?.count, CCSentHubLedger.limit, "有上限")
        XCTAssertTrue(ledger.sent(chatId: "c\(CCSentHubLedger.limit + 4)", hubId: a, identity: "HUB-A"), "留新的")
        XCTAssertFalse(ledger.sent(chatId: "c0", hubId: a, identity: nil))
    }

    /// 接线同 ContentView.bindChatCallbacks：reply / thinking 走 deliverCCFrame（返回值 = client 记不记已收）
    private func wireDelivery(_ client: CCBridgeWebSocketClient, hub: String, vm: ConversationViewModel, context: ModelContext,
                              into box: DeliveredBox) {
        client.onProactiveMessage = { chatId, content, _, _, _, _, _, _, _ in
            vm.deliverCCFrame(chatId: chatId, fromHub: hub, context: context) { box.delivered.append(content) }
        }
        client.onThinking = { chatId, _, content in
            vm.deliverCCFrame(chatId: chatId, fromHub: hub, context: context) { box.delivered.append("think:" + content) }
        }
    }

    final class DeliveredBox { var delivered: [String] = [] }

    private func feed(_ client: CCBridgeWebSocketClient, chat: String, suffix: String, ts: Int) {
        let task = client.currentTaskForTesting
        for f: [String: Any] in [
            ["type": "reply", "chat_id": chat, "content": "r" + suffix, "reply_id": "rid-" + suffix, "ts": ts],
            ["type": "thinking", "chat_id": chat, "mp_msg_id": "m" + suffix, "content": "t" + suffix, "thinking_id": "th-" + suffix, "ts": ts + 10],
        ] {
            client.handleIncoming(String(data: try! JSONSerialization.data(withJSONObject: f), encoding: .utf8)!, source: task)
        }
    }

    /// B7.2 B1：对话绑着别的那台时拒收的 reply / thinking 记成已收；改绑到这台后回放不再收（改绑前它发的不算这条对话的），之后的新回复照收
    func testFramesRefusedWhileBoundElsewhereStayRefusedAfterRebind() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        let client = try XCTUnwrap(made[b])
        let box = DeliveredBox()
        wireDelivery(client, hub: b, vm: h.viewModel, context: h.context, into: box)
        await openAsync(client, hello: "HUB-B")
        let d = client.defaults
        let chat = conversation.id

        feed(client, chat: chat, suffix: "b1", ts: 50)
        await expect({ (d.dictionary(forKey: "ccSeenReplyIds") as? [String: Double])?["rid-b1"] != nil }, "拒收的 reply 记成已收")
        await expect({ (d.dictionary(forKey: "ccSeenThinkingIds") as? [String: Double])?["th-b1"] != nil }, "拒收的 thinking 记成已收")
        XCTAssertEqual(box.delivered, [], "对话绑纽约、没在东京发过 → 拒收")

        XCTAssertTrue(r.rebind(conversation, to: b))
        try h.context.save()
        feed(client, chat: chat, suffix: "b1", ts: 50)
        await pause()
        XCTAssertEqual(box.delivered, [], "改绑后回放：改绑前东京发的还是不收")
        feed(client, chat: chat, suffix: "b2", ts: 70)
        await expect({ box.delivered == ["rb2", "think:tb2"] }, "改绑后东京的新回复照收：\(box.delivered)")
    }

    /// 待绑定（同步来、认不出那台）拒收的不记已收、不推游标：认出那台自动绑回后回放补到（impl1 #13 保留）
    func testFramesRefusedWhileUnboundLandAfterAutoRebind() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = CCHubRegistry.unboundHubId
        conversation.ccHubIdentity = "HUB-B"
        try h.context.save()
        let client = try XCTUnwrap(made[b])
        let box = DeliveredBox()
        wireDelivery(client, hub: b, vm: h.viewModel, context: h.context, into: box)
        await openAsync(client, hello: "HUB-B")
        let d = client.defaults
        let chat = conversation.id

        feed(client, chat: chat, suffix: "u1", ts: 50)
        await pause()
        XCTAssertEqual(box.delivered, [])
        XCTAssertNil((d.dictionary(forKey: "ccSeenReplyIds") as? [String: Double])?["rid-u1"], "待绑定拒收的不记已收")
        XCTAssertEqual(d.double(forKey: "ccReplyCursorTs"), 0, "不推游标")

        XCTAssertEqual(CCHubRegistry.rebindAutoUnbound(identity: "HUB-B", to: b, context: h.context), [chat])
        feed(client, chat: chat, suffix: "u1", ts: 50)
        await expect({ box.delivered == ["ru1", "think:tu1"] }, "绑回后回放补到：\(box.delivered)")
        XCTAssertEqual(d.double(forKey: "ccReplyCursorTs"), 60)
    }

    /// B7.2 B1 / R5.2：edit 只认被改那条自己的来源（持久，重启照认）；查不到来源只在从没改绑过的对话里放行
    func testEditOnlyFromTheHubThatSentTheMessage() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        await openAsync(made[a]!, hello: "HUB-A")
        await openAsync(made[b]!, hello: "HUB-B")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        let vm = h.viewModel
        let chat = conversation.id
        vm.insertProactiveAssistantMessage(chatId: chat, content: "纽约说", ccMessageId: "mA", fromHub: a, context: h.context)
        XCTAssertTrue(vm.acceptsCCEdit(chatId: chat, ccMessageId: "old", fromHub: a, context: h.context), "没改绑过：查不到来源的（账本之前的老消息）照收")

        XCTAssertTrue(r.rebind(conversation, to: b))
        XCTAssertFalse(vm.acceptsCCEdit(chatId: chat, ccMessageId: "mA", fromHub: b, context: h.context), "东京不能改纽约发的那条")
        vm.insertProactiveAssistantMessage(chatId: chat, content: "东京说", ccMessageId: "mB", fromHub: b, context: h.context)
        XCTAssertTrue(vm.acceptsCCEdit(chatId: chat, ccMessageId: "mB", fromHub: b, context: h.context))
        XCTAssertFalse(vm.acceptsCCEdit(chatId: chat, ccMessageId: "old", fromHub: b, context: h.context), "改绑过：查不到来源的不收")

        // 重启：来源持久，东京改自己的照收、改纽约的照拒（不再看「这条对话最近在哪台发过」）
        let restarted = ConversationViewModel()
        restarted.ccBridgeClient = p
        restarted.ccHubRegistry = r
        restarted.ccSentLedger = CCSentHubLedger(defaults: std)
        restarted.ccOriginLedger = CCChatOriginLedger(defaults: std)
        XCTAssertTrue(restarted.acceptsCCEdit(chatId: chat, ccMessageId: "mB", fromHub: b, context: h.context))
        XCTAssertFalse(restarted.acceptsCCEdit(chatId: chat, ccMessageId: "mA", fromHub: b, context: h.context))
        XCTAssertFalse(restarted.acceptsCCEdit(chatId: chat, ccMessageId: "old", fromHub: b, context: h.context))
        r.defaults(for: b)?.set("HUB-Z", forKey: CCHubPairingStore.hubIdentityKey)
        XCTAssertFalse(restarted.acceptsCCEdit(chatId: chat, ccMessageId: "mB", fromHub: b, context: h.context), "同槽位换了机器不算")
    }

    /// R5.2：账本有上限、会过期
    func testOriginLedgerLimitsAndExpiry() {
        let ledger = CCChatOriginLedger(defaults: std)
        ledger.recordMessage(chatId: "c", messageId: "old", hubId: "h", identity: nil, now: Date(timeIntervalSinceNow: -31 * 24 * 3600))
        XCTAssertNil(ledger.messageOrigin(chatId: "c", messageId: "old"), "30 天过期")
        for i in 0..<(CCChatOriginLedger.messageLimit + 5) { ledger.recordMessage(chatId: "c", messageId: "m\(i)", hubId: "h", identity: nil) }
        XCTAssertEqual(std.array(forKey: CCChatOriginLedger.messagesKey)?.count, CCChatOriginLedger.messageLimit)
        XCTAssertNil(ledger.messageOrigin(chatId: "c", messageId: "m0"))
        XCTAssertEqual(ledger.messageOrigin(chatId: "c", messageId: "m\(CCChatOriginLedger.messageLimit + 4)"), .init(hub: "h", identity: nil))
        ledger.recordRefusedAsk(chatId: "c", toolUseId: "t", hubId: "h", identity: "HUB-H", now: Date(timeIntervalSinceNow: -8 * 24 * 3600))
        XCTAssertFalse(ledger.refusedAsk(chatId: "c", toolUseId: "t", hubId: "h", identity: "HUB-H"), "7 天过期")
        for i in 0..<(CCChatOriginLedger.reboundLimit + 5) {
            CCChatOriginLedger.recordRebind(chatId: "r\(i)", defaults: std, now: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        XCTAssertEqual(std.dictionary(forKey: CCChatOriginLedger.reboundKey)?.count, CCChatOriginLedger.reboundLimit)
        XCTAssertFalse(CCChatOriginLedger.wasRebound(chatId: "r0", defaults: std), "留新的")
        XCTAssertTrue(CCChatOriginLedger.wasRebound(chatId: "r\(CCChatOriginLedger.reboundLimit + 4)", defaults: std))
    }

    /// B7.2 B1：绑着别的那台时拒过的问题卡 / 收账，改绑到那台后再来也不收（不落「已跳过」泡）；新题照收
    func testAskRefusedWhileBoundElsewhereStaysRefusedAfterRebind() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = a
        try h.context.save()
        let vm = h.viewModel
        let chat = conversation.id
        XCTAssertFalse(vm.acceptsCCAskFrame(chatId: chat, toolUseId: "tu-b", fromHub: b, context: h.context))
        XCTAssertTrue(vm.acceptsCCAskFrame(chatId: chat, toolUseId: "tu-a", fromHub: a, context: h.context))
        XCTAssertTrue(r.rebind(conversation, to: b))
        XCTAssertFalse(vm.acceptsCCAskFrame(chatId: chat, toolUseId: "tu-b", fromHub: b, context: h.context), "改绑前拒过的那题")
        XCTAssertTrue(vm.acceptsCCAskFrame(chatId: chat, toolUseId: "tu-b2", fromHub: b, context: h.context), "改绑后的新题照收")
        let restarted = ConversationViewModel()
        restarted.ccBridgeClient = p
        restarted.ccHubRegistry = r
        restarted.ccSentLedger = CCSentHubLedger(defaults: std)
        restarted.ccOriginLedger = CCChatOriginLedger(defaults: std)
        XCTAssertFalse(restarted.acceptsCCAskFrame(chatId: chat, toolUseId: "tu-b", fromHub: b, context: h.context), "重启后重放也不收（R5.2）")
        XCTAssertFalse(restarted.acceptsCCAskFrame(chatId: chat, toolUseId: "tu-a", fromHub: a, context: h.context),
                       "纽约那题：改绑后纽约没在这条对话发过，照旧不收")
    }

    // MARK: - AskUser resolved 来源（impl1 #15）

    /// 两台同 toolUseId：A 的 resolved 不收 B 的卡；Q/A 去重键带 hub_id，两台各落一条；旧键照认
    func testAskUserResolvedMatchesChatHubAndToolUseId() async throws {
        let (h, _, conversation) = try await makeHarness()
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let b = add(r, "东京", pairing: pairingB, token: "tb")
        await openAsync(made[a]!, hello: "HUB-A")
        await openAsync(made[b]!, hello: "HUB-B")
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        conversation.ccHubId = b
        try h.context.save()
        let vm = h.viewModel
        let answers = ["选哪个？": "甲"]

        vm.presentCCAskUser(chatId: conversation.id, toolUseId: "tu1", questions: questions, fromHub: b, context: h.context)
        XCTAssertEqual(vm.pendingCCQuestion?.origin.hubId, b)
        vm.handleCCAskUserResolved(chatId: conversation.id, toolUseId: "tu1", questions: questions, answers: answers, fromHub: a, context: h.context)
        XCTAssertNotNil(vm.pendingCCQuestion, "A 的 resolved 不收 B 的卡")
        vm.handleCCAskUserResolved(chatId: "another-chat", toolUseId: "tu1", questions: questions, answers: answers, fromHub: b, context: h.context)
        XCTAssertNotNil(vm.pendingCCQuestion, "chat 不对也不收")
        vm.handleCCAskUserResolved(chatId: conversation.id, toolUseId: "tu1", questions: questions, answers: answers, fromHub: b, context: h.context)
        XCTAssertNil(vm.pendingCCQuestion)

        let cid = conversation.id
        func qaKeys() throws -> [String] {
            try h.context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == cid }))
                .compactMap(\.ccMessageId).filter { $0.hasPrefix("askuser") }.sorted()
        }
        XCTAssertEqual(try qaKeys(), ["askuser:HUB-A:tu1", "askuser:HUB-B:tu1"], "两台各落一条，不互相去重")
        vm.handleCCAskUserResolved(chatId: conversation.id, toolUseId: "tu1", questions: questions, answers: answers, fromHub: b, context: h.context)
        XCTAssertEqual(try qaKeys().count, 2, "同一台重复的 resolved 去重")

        // 旧键：升级前（主 hub 还不报 hub_id）落的 Q/A，升级后回放不再落一条
        vm.handleCCAskUserResolved(chatId: conversation.id, toolUseId: "tu9", questions: questions, answers: answers,
                                   fromHub: CCHubRegistry.primaryId, context: h.context)
        XCTAssertTrue(try qaKeys().contains("askuser:tu9"))
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        vm.handleCCAskUserResolved(chatId: conversation.id, toolUseId: "tu9", questions: questions, answers: answers,
                                   fromHub: CCHubRegistry.primaryId, context: h.context)
        XCTAssertEqual(try qaKeys().count, 3, "旧键照认")
    }

    // MARK: - focus（B3.3）

    func testFocusGoesToBoundHubAndFollowsRebindWithSameChatId() async {
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(p)
        await openAsync(made[a]!)
        let c = Conversation(id: "chat-1", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        c.ccHubId = a
        r.updateFocus(c)
        await expect({ self.wires[a]!.sent("focus").last?["chat_id"] as? String == "chat-1" })
        await expect({ self.primaryWire.sent("focus").last?["chat_id"] as? String == "" }, "其他台 focus:null")

        r.rebind(c, to: CCHubRegistry.primaryId)
        await expect({ self.primaryWire.sent("focus").last?["chat_id"] as? String == "chat-1" }, "只改 hub 也重发")
        await expect({ self.wires[a]!.sent("focus").last?["chat_id"] as? String == "" }, "旧台收 null")

        r.updateFocus(nil)
        await expect({ self.primaryWire.sent("focus").last?["chat_id"] as? String == "" })
    }

    func testNewClientGetsCachedFocusBeforeConnecting() async {
        let (r, _) = makeRegistry()
        r.updateFocus(chatId: "chat-9", hubId: "will-not-match")
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        let c = Conversation(id: "chat-9", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        r.rebind(c, to: a)
        r.updateFocus(c)
        await openAsync(made[a]!)
        await expect({ self.wires[a]!.sent("focus").last?["chat_id"] as? String == "chat-9" }, "连上就报缓存的 focus")
    }

    // MARK: - 终端（B3.4）

    func testSameSessionNameOnTwoHubsOnlyHitsSelectedHub() async {
        let (r, p) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        await openAsync(p)
        await openAsync(made[a]!)
        let backend = HubTerminalBackend(sessionName: "mp-cc", client: made[a]!)
        let events = TerminalBackendEvents(onInit: { _, _ in }, onChunk: { _ in }, onError: { _ in }, onUsage: { _ in })
        backend.attach(cols: 80, rows: 24, openedAt: nil, events: events) { _ in }
        backend.send(Data("ls\r".utf8)) { _ in }
        backend.paste("echo hi", bracketed: true) { _ in }
        if case .success(let c) = r.route(a) { c.sendTerminalInput(session: "mp-cc", bytes: Data([0x1b])) }   // 阶段卡 Esc 的路径
        r.windowStore(for: a)?.end("w1")
        backend.detach()
        for type in ["terminal_attach", "terminal_input", "terminal_paste", "end_window", "terminal_detach"] {
            await expect({ !self.wires[a]!.sent(type).isEmpty }, "\(type) 落到所选那台")
        }
        XCTAssertTrue(wires[a]!.sent("terminal_input").allSatisfy { $0["session_name"] as? String == "mp-cc" })
        await pause()
        let primaryTypes = primaryWire.types()
        for type in ["terminal_attach", "terminal_input", "terminal_paste", "end_window", "terminal_detach"] {
            XCTAssertFalse(primaryTypes.contains(type), "主 hub 上同名 mp-cc 不受影响：\(type)")
        }
    }

    // MARK: - 改绑 + 扫码落点（B3.5）

    func testRebindKeepsSessionNameAndRejectsUnknownHub() {
        let (r, _) = makeRegistry()
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        r.defaults(for: a)?.set("HUB-A", forKey: CCHubPairingStore.hubIdentityKey)
        let c = Conversation(id: "c", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        c.ccBridgeSessionName = "mp-cc-1"
        XCTAssertTrue(r.rebind(c, to: a))
        XCTAssertEqual(c.ccHubId, a)
        XCTAssertEqual(c.ccHubIdentity, "HUB-A")
        XCTAssertEqual(c.ccBridgeSessionName, "mp-cc-1")
        XCTAssertFalse(r.rebind(c, to: "gone"))
        XCTAssertEqual(c.ccHubId, a)
    }

    func testClassifyPairingByHubIdentity() async {
        let (r, _) = makeRegistry()
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        let a = add(r, "纽约", pairing: pairingA, token: "ta")
        r.defaults(for: a)?.set("HUB-A", forKey: CCHubPairingStore.hubIdentityKey)
        let legacy = add(r, "老 hub", pairing: pairingB, token: "tl")
        func probe(_ outcome: CCHubRegistry.ProbeOutcome) -> CCHubRegistry.PairingProbe { { _, _ in outcome } }
        let p = CCHubPairing(primaryURL: "ws://10.9.9.9:7890/cc")

        let same = await r.classifyPairing(p, token: "new", probe: probe(.hello(hubId: "HUB-A")))
        XCTAssertEqual(same, .update(a), "同 hub_id = 同一台换了地址 / 口令")
        let fresh = await r.classifyPairing(p, token: "new", probe: probe(.hello(hubId: "HUB-NEW")))
        XCTAssertEqual(fresh, .addNew(reportedIdentity: "HUB-NEW"))
        let intoPrimary = await r.classifyPairing(p, token: "new", target: CCHubRegistry.primaryId, probe: probe(.hello(hubId: "HUB-NEW")))
        XCTAssertEqual(intoPrimary, .differentMachine(target: CCHubRegistry.primaryId, matching: nil), "主 hub 扫进另一台：不覆盖")
        let primaryToA = await r.classifyPairing(p, token: "new", target: CCHubRegistry.primaryId, probe: probe(.hello(hubId: "HUB-A")))
        XCTAssertEqual(primaryToA, .differentMachine(target: CCHubRegistry.primaryId, matching: a))
        let oldHubSameToken = await r.classifyPairing(p, token: "tl", probe: probe(.hello(hubId: nil)))
        XCTAssertEqual(oldHubSameToken, .update(legacy), "老 hub 不报 hub_id：口令对上就是那台")
        let oldHubUnknown = await r.classifyPairing(p, token: "zz", probe: probe(.hello(hubId: nil)))
        XCTAssertEqual(oldHubUnknown, .needsChoice)
        let down = await r.classifyPairing(p, token: "zz", probe: probe(.failed("连不上")))
        XCTAssertEqual(down, .unreachable("连不上"))
        XCTAssertEqual(r.hubs.count, 3, "只判断，不写")
    }
}

/// B1：两个新字段进备份 / 同步，对端按 hub_id 认机器
@MainActor
final class CCHubConversationSyncTests: XCTestCase {
    private let pid = "xctest-multihub-sync"
    private var stdName: String!
    private var std: UserDefaults!
    private var prefix: String!
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        stdName = "CCHubConversationSyncTests.std.\(UUID().uuidString)"
        std = UserDefaults(suiteName: stdName)!
        prefix = "CCHubConversationSyncTests.hub.\(UUID().uuidString)."
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("multihub-sync-\(UUID().uuidString)")
        SyncStore.overrideRoot = tempRoot
        SyncStoreTests.wipeLocalSyncState(pid: pid)
    }

    override func tearDown() {
        SyncStore.overrideRoot = nil
        try? FileManager.default.removeItem(at: tempRoot)
        SyncStoreTests.wipeLocalSyncState(pid: pid)
        std.removePersistentDomain(forName: stdName)
        super.tearDown()
    }

    /// 本机名单：一台附加 hub（id → hub_id）
    private func seedLocalHub(id: String, identity: String?) {
        var list = std.array(forKey: CCHubRegistry.listKey) as? [[String: String]] ?? []
        list.append(["id": id, "name": id])
        std.set(list, forKey: CCHubRegistry.listKey)
        let suite = UserDefaults(suiteName: prefix + id)!
        if let identity { suite.set(identity, forKey: CCHubPairingStore.hubIdentityKey) }
        addTeardownBlock { [prefix] in UserDefaults(suiteName: prefix! + id)?.removePersistentDomain(forName: prefix! + id) }
    }

    private func resolve(_ hubId: String?, _ identity: String?) -> String? {
        CCHubRegistry.resolveSynced(hubId: hubId, identity: identity, standard: std, suitePrefix: prefix)
    }

    func testBackupRoundTripsBothFieldsAndOldBackupsDecodeAsNil() throws {
        let c = Conversation(id: "b1", title: "t", createTime: Date(timeIntervalSince1970: 1), updateTime: Date(timeIntervalSince1970: 2),
                             currentNodeId: "", provider: "cc-bridge", profileId: pid)
        c.ccHubId = "hub-uuid"
        c.ccHubIdentity = "HUB-X"
        let data = try JSONEncoder().encode(FullConversationDocument(model: c, nodes: []))
        let back = try JSONDecoder().decode(FullConversationDocument.self, from: data).toConversationModel()
        XCTAssertEqual(back.ccHubId, "hub-uuid")
        XCTAssertEqual(back.ccHubIdentity, "HUB-X")

        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "ccHubId")
        obj.removeValue(forKey: "ccHubIdentity")
        let old = try JSONDecoder().decode(FullConversationDocument.self, from: JSONSerialization.data(withJSONObject: obj)).toConversationModel()
        XCTAssertNil(old.ccHubId, "旧包 = 主 hub")
        XCTAssertNil(old.ccHubIdentity)
        // 字段覆盖（只比 Conversation：别的 model 的覆盖不归这单）
        XCTAssertNoThrow(try SchemaCoverageCheck.compareFields(
            modelName: "Conversation", modelFields: SchemaCoverageCheck.modelFieldNames(c),
            docFields: SchemaCoverageCheck.documentFieldNames(sample: FullConversationDocument(model: c, nodes: [])),
            allowedExtraInDoc: ["schemaVersion", "nodes"]))
    }

    func testResolveSyncedRules() {
        seedLocalHub(id: "local-ny", identity: "HUB-NY")
        std.set("HUB-MAC-B", forKey: CCHubPairingStore.hubIdentityKey)
        XCTAssertNil(resolve(nil, nil), "老对话保持 nil")
        XCTAssertEqual(resolve("remote-uuid", "HUB-NY"), "local-ny", "对端那台本机也有 → 绑那台")
        XCTAssertEqual(resolve("remote-uuid", "HUB-UNKNOWN"), CCHubRegistry.unboundHubId, "本机没有 → 待绑定")
        XCTAssertEqual(resolve("primary", "HUB-MAC-A"), CCHubRegistry.unboundHubId, "别的设备的 primary 不冒充本机主 hub")
        XCTAssertEqual(resolve("primary", "HUB-MAC-B"), CCHubRegistry.primaryId, "hub_id 对得上本机主 hub 才算")
        XCTAssertEqual(resolve("remote-uuid", "HUB-MAC-B"), CCHubRegistry.primaryId, "对端的附加 hub 正是本机主 hub")
        XCTAssertEqual(resolve("remote-uuid", nil), CCHubRegistry.unboundHubId, "认不出的附加 hub 绝不落到主 hub")
        XCTAssertEqual(resolve("primary", nil), CCHubRegistry.unboundHubId,
                       "明确的 primary 不带 hub_id 也不冒充本机主 hub（impl1 #3：新对话主 hub 身份不知道时写 nil）")
        XCTAssertEqual(resolve("local-ny", nil), "local-ny", "本机名单里的槽位（这台自己的备份）")
        XCTAssertEqual(resolve(nil, "HUB-NY"), "local-ny", "只有 hub_id 也按它认")
    }

    /// impl1 #3：备份导出像同步导出一样补取已知身份
    func testBackupExportFillsKnownIdentity() {
        std.set("HUB-MAC-B", forKey: CCHubPairingStore.hubIdentityKey)
        let c = Conversation(id: "bk", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "", provider: "cc-bridge", profileId: pid)
        c.ccHubId = CCHubRegistry.primaryId
        let doc = FullConversationDocument(model: c, nodes: []) { CCHubRegistry.exportedIdentity(of: $0, standard: self.std, suitePrefix: self.prefix) }
        XCTAssertEqual(doc.ccHubIdentity, "HUB-MAC-B")
    }

    /// impl1 #11：身份补齐 / 改绑（不推进 updateTime）也重新导出；内容去重比较两个归属字段；列表排序不动
    func testOwnershipChangesReexportWithoutTouchingUpdateTime() throws {
        seedLocalHub(id: "slot-a", identity: nil)
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let first = Conversation(id: "o-1", title: "o-1", createTime: Date(timeIntervalSinceNow: -100), updateTime: Date(timeIntervalSinceNow: -50),
                                 currentNodeId: "", provider: "cc-bridge", profileId: pid)
        first.ccHubId = "slot-a"
        let second = Conversation(id: "o-2", title: "o-2", createTime: Date(timeIntervalSinceNow: -100), updateTime: Date(timeIntervalSinceNow: -50),
                                  currentNodeId: "", provider: "cc-bridge", profileId: pid)
        second.ccHubId = CCHubRegistry.primaryId
        second.ccHubIdentity = "HUB-P"
        ctx.insert(first)
        ctx.insert(second)
        try ctx.save()
        let identity: (Conversation) -> String? = { CCHubRegistry.exportedIdentity(of: $0, standard: self.std, suitePrefix: self.prefix) }
        func export() -> Int { SyncStore.exportChanged(profileId: pid, context: ctx, hubIdentity: identity).exported }
        func doc(_ id: String) throws -> [String: Any] {
            let url = try XCTUnwrap(SyncStore.syncRoot(profileId: pid)).appendingPathComponent("\(id).json")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }

        XCTAssertEqual(export(), 2)
        XCTAssertNil(try doc("o-1")["ccHubIdentity"], "那台还没报 hub_id")
        XCTAssertEqual(export(), 0, "没变不导")

        UserDefaults(suiteName: prefix + "slot-a")!.set("HUB-A", forKey: CCHubPairingStore.hubIdentityKey)
        XCTAssertEqual(export(), 1, "身份补齐 → 重新导出")
        XCTAssertEqual(try doc("o-1")["ccHubIdentity"] as? String, "HUB-A")

        let stamp = second.updateTime
        second.ccHubId = "slot-a"   // 改绑（同 rebind：只改两个字段）
        second.ccHubIdentity = "HUB-A"
        try ctx.save()
        XCTAssertEqual(export(), 1, "已导出的对话改绑、没新消息也重新导出")
        XCTAssertEqual(try doc("o-2")["ccHubId"] as? String, "slot-a")
        XCTAssertEqual(try doc("o-2")["ccHubIdentity"] as? String, "HUB-A")
        XCTAssertEqual(second.updateTime, stamp, "不动列表排序")
        XCTAssertEqual(export(), 0)
    }

    /// 导入后本机把对端的归属换成自己的说法（待绑定），不算本机改了归属：不回写对端的文档
    func testImportedOwnershipIsNotEchoedBack() throws {
        let a = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let b = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctxA = ModelContext(a)
        let ctxB = ModelContext(b)
        let c = Conversation(id: "e-1", title: "e-1", createTime: Date(timeIntervalSinceNow: -100), updateTime: Date(timeIntervalSinceNow: -50),
                             currentNodeId: "", provider: "cc-bridge", profileId: pid)
        c.ccHubId = CCHubRegistry.primaryId
        c.ccHubIdentity = "HUB-MAC-A"
        ctxA.insert(c)
        try ctxA.save()
        XCTAssertEqual(SyncStore.exportChanged(profileId: pid, context: ctxA).exported, 1)
        _ = SyncStore.importAll(profileId: pid, context: ctxB) { self.resolve($0, $1) }
        XCTAssertEqual(try ctxB.fetch(FetchDescriptor<Conversation>()).first?.ccHubId, CCHubRegistry.unboundHubId)
        XCTAssertEqual(SyncStore.exportChanged(profileId: pid, context: ctxB).exported, 0, "不把 unbound 写回云端")
    }

    func testSyncCarriesIdentityAndPeerResolvesLocally() throws {
        let a = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let b = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctxA = ModelContext(a)
        let ctxB = ModelContext(b)
        for (id, hub, identity) in [("s-unknown", "a-uuid-1", "HUB-ELSEWHERE"), ("s-known", "a-uuid-2", "HUB-NY"),
                                    ("s-primary", "primary", "HUB-MAC-A"), ("s-legacy", nil, nil)] as [(String, String?, String?)] {
            let c = Conversation(id: id, title: id, createTime: Date(timeIntervalSinceNow: -100), updateTime: Date(timeIntervalSinceNow: -50),
                                 currentNodeId: "", provider: "cc-bridge", profileId: pid)
            c.ccHubId = hub
            c.ccHubIdentity = identity
            ctxA.insert(c)
        }
        try ctxA.save()
        _ = SyncStore.exportChanged(profileId: pid, context: ctxA)

        seedLocalHub(id: "b-ny", identity: "HUB-NY")
        std.set("HUB-MAC-B", forKey: CCHubPairingStore.hubIdentityKey)
        // B 本机已经有的、绑过的不被对端覆盖
        let local = Conversation(id: "s-known", title: "s-known", createTime: Date(timeIntervalSinceNow: -100),
                                 updateTime: Date(timeIntervalSinceNow: -80), currentNodeId: "", provider: "cc-bridge", profileId: pid)
        ctxB.insert(local)
        try ctxB.save()
        _ = SyncStore.importAll(profileId: pid, context: ctxB) { self.resolve($0, $1) }

        func conv(_ id: String) throws -> Conversation {
            try XCTUnwrap(ctxB.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first)
        }
        XCTAssertEqual(try conv("s-unknown").ccHubId, CCHubRegistry.unboundHubId)
        XCTAssertEqual(try conv("s-unknown").ccHubIdentity, "HUB-ELSEWHERE", "hub_id 留着，以后加上那台能认")
        XCTAssertEqual(try conv("s-known").ccHubId, "b-ny", "本机还没归属的按对端补一次")
        XCTAssertEqual(try conv("s-primary").ccHubId, CCHubRegistry.unboundHubId, "A 的主 hub ≠ B 的主 hub")
        XCTAssertNil(try conv("s-legacy").ccHubId)

        try conv("s-known").ccHubId = CCHubRegistry.primaryId
        try ctxB.save()
        SyncStoreTests.wipeLocalSyncState(pid: pid)
        _ = SyncStore.importAll(profileId: pid, context: ctxB) { self.resolve($0, $1) }
        XCTAssertEqual(try conv("s-known").ccHubId, CCHubRegistry.primaryId, "本机改绑过的不被对端覆盖")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
