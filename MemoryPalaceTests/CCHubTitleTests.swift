import XCTest
@testable import 记忆花园

/// plan-multi-hub B4.4：对话标题下的电脑名、输入框上方的提示、新建对话默认哪台、改连提示。注入 defaults suite + 口令替身，不碰真库 / 真 hub
@MainActor
final class CCHubTitleTests: XCTestCase {
    private var stdName: String!
    private var std: UserDefaults!
    private var prefix: String!
    private var clients: [CCBridgeWebSocketClient] = []
    private var hubIds: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        stdName = "CCHubTitleTests.std.\(UUID().uuidString)"
        std = UserDefaults(suiteName: stdName)!
        prefix = "CCHubTitleTests.hub.\(UUID().uuidString)."
    }

    override func tearDown() async throws {
        for c in clients { c.disconnect() }
        clients = []
        for id in hubIds { UserDefaults(suiteName: prefix + id)?.removePersistentDomain(forName: prefix + id) }
        hubIds = []
        std.removePersistentDomain(forName: stdName)
        try await super.tearDown()
    }

    private func makeRegistry() -> CCHubRegistry {
        let p = CCBridgeWebSocketClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: std, transportOffMain: false)
        clients.append(p)
        return CCHubRegistry(primary: p, standard: std, suitePrefix: prefix, secrets: CCHubRegistryTests.FakeSecrets(), originDefaults: std) { [unowned self] id, d in
            let c = CCBridgeWebSocketClient(hubId: id, defaults: d, transportOffMain: false)
            self.clients.append(c)
            self.hubIds.append(id)
            return c
        }
    }

    private func add(_ r: CCHubRegistry, _ name: String, token: String) -> String {
        guard case .added(let id) = r.addHub(name: name, pairing: CCHubPairing(primaryURL: "ws://192.168.9.\(clients.count):7890/cc"), token: token) else {
            XCTFail("加不上 \(name)")
            return ""
        }
        return id
    }

    private func conversation(_ id: String = UUID().uuidString) -> Conversation {
        Conversation(id: id, title: "助手·部署", createTime: Date(), updateTime: Date(), currentNodeId: "")
    }

    // MARK: - 标题下那行

    func testSubtitleOnlyWithTwoOrMoreHubs() {
        XCTAssertNil(CCHubTitle.subtitle(hubCount: 1, name: "MacBook", blocker: nil), "1 台：标题跟现在一样")
        XCTAssertEqual(CCHubTitle.subtitle(hubCount: 2, name: "MacBook", blocker: nil), "MacBook", "连主电脑的也写")
        XCTAssertEqual(CCHubTitle.subtitle(hubCount: 3, name: "纽约", blocker: nil), "纽约")
    }

    func testSubtitleForEachUnavailableEvenWithOneHub() {
        XCTAssertEqual(CCHubTitle.subtitle(hubCount: 1, name: "纽约", blocker: .removed), "纽约 · 已删除")
        XCTAssertEqual(CCHubTitle.subtitle(hubCount: 2, name: "纽约", blocker: .needsPairing), "纽约 · 要重新配对")
        XCTAssertEqual(CCHubTitle.subtitle(hubCount: 2, name: "纽约", blocker: .identityChanged), "纽约 · 换了机器")
        XCTAssertEqual(CCHubTitle.subtitle(hubCount: 1, name: nil, blocker: .unbound), "电脑不在这台设备上")
        XCTAssertEqual(CCHubTitle.subtitle(hubCount: 1, name: nil, blocker: .removed), "那台电脑 · 已删除", "名字不知道也给一行")
    }

    func testNoticeUsesMockWordingForRemovedAndRouteMessageOtherwise() {
        XCTAssertEqual(CCHubTitle.notice(.removed, name: "纽约"), "这个对话连的是「纽约」，那台电脑已经删掉了，消息发不出去。")
        XCTAssertEqual(CCHubTitle.notice(.removed, name: nil), CCHubRegistry.Unavailable.removed.message)
        for why in [CCHubRegistry.Unavailable.unbound, .needsPairing, .identityChanged] {
            XCTAssertEqual(CCHubTitle.notice(why, name: "纽约"), why.message)
        }
    }

    func testSubtitleFromRegistryRoute() {
        let r = makeRegistry()
        let c = conversation()
        XCTAssertNil(CCHubTitle.subtitle(for: c, registry: r), "只有主电脑：不写")

        let nyc = add(r, "纽约", token: "t-nyc")
        XCTAssertEqual(CCHubTitle.subtitle(for: c, registry: r), r.primaryName, "≥2 台：连主电脑的写主电脑名")
        c.ccHubId = nyc
        XCTAssertEqual(CCHubTitle.subtitle(for: c, registry: r), "纽约")
        XCTAssertNil(CCHubTitle.blocker(for: c, registry: r), "只是连不上不算用不了")

        r.remove(nyc)
        XCTAssertEqual(r.hubs.count, 1)
        XCTAssertEqual(r.removedName(of: nyc), "纽约", "删的时候记下名字")
        XCTAssertEqual(CCHubTitle.blocker(for: c, registry: r), .removed)
        XCTAssertEqual(CCHubTitle.subtitle(for: c, registry: r), "纽约 · 已删除", "剩 1 台也要写")

        c.ccHubId = CCHubRegistry.unboundHubId
        XCTAssertEqual(CCHubTitle.subtitle(for: c, registry: r), "电脑不在这台设备上")
    }

    func testHubChoiceOnlyWithTwoOrMoreHubs() {
        XCTAssertFalse(CCHubTitle.showsHubChoice(hubCount: 1))
        XCTAssertTrue(CCHubTitle.showsHubChoice(hubCount: 2))
    }

    // MARK: - 新建对话选电脑

    func testNewConversationDefaultsToLastPickedAndPickIsRemembered() {
        let r = makeRegistry()
        let nyc = add(r, "纽约", token: "t-nyc")
        XCTAssertEqual(r.lastHubId, CCHubRegistry.primaryId, "没选过 = 主电脑")

        let first = conversation()
        CCHubTitle.pickForNewConversation(first, hubId: nyc, registry: r)
        XCTAssertEqual(first.ccHubId, nyc)
        XCTAssertEqual(r.lastHubId, nyc, "记成上次选的")

        let second = conversation()
        r.bindNewCCConversation(second)
        XCTAssertEqual(second.ccHubId, nyc, "下一个新对话默认上次选的")

        // 选回主电脑：主电脑 hub_id 还不知道 → 留 nil（同 bindNewCCConversation，不写没 hub_id 的 "primary"）
        CCHubTitle.pickForNewConversation(second, hubId: CCHubRegistry.primaryId, registry: r)
        XCTAssertNil(second.ccHubId)
        XCTAssertEqual(CCHubRegistry.hubId(of: second), CCHubRegistry.primaryId)
        XCTAssertEqual(r.lastHubId, CCHubRegistry.primaryId)

        // 已经挑过会话名的走改绑
        let named = conversation()
        named.ccBridgeSessionName = "mp-cc-3"
        CCHubTitle.pickForNewConversation(named, hubId: nyc, registry: r)
        XCTAssertEqual(named.ccHubId, nyc)
        XCTAssertEqual(named.ccBridgeSessionName, "mp-cc-3", "会话名不动")
    }

    func testUnreachableHubCanStillBePicked() {
        let r = makeRegistry()
        let nyc = add(r, "纽约", token: "t-nyc")
        let hub = r.hubs.first { $0.id == nyc }!
        XCTAssertEqual(CCHubTitle.status(of: hub, registry: r).text, "连不上")
        let c = conversation()
        CCHubTitle.pickForNewConversation(c, hubId: nyc, registry: r)
        XCTAssertEqual(c.ccHubId, nyc, "连不上的那台也能选，等它接上再发")
    }

    // MARK: - 改连提示

    func testRebindNoticeOnlyWhenUnfinished() {
        XCTAssertNil(CCHubTitle.rebindNotice(unfinished: false, from: "纽约"))
        XCTAssertEqual(CCHubTitle.rebindNotice(unfinished: true, from: "纽约"), "还有没回完的在纽约上，回复会回到纽约", "不报条数（b4 #9）")
    }

    func testRebindReportsUnfinishedOnOldHubButNotWhenItWasRemoved() {
        let r = makeRegistry()
        let nyc = add(r, "纽约", token: "t-nyc")
        let c = conversation()
        c.ccHubId = nyc

        XCTAssertEqual(CCHubTitle.rebind(c, to: CCHubRegistry.primaryId, unfinished: true, registry: r), "还有没回完的在纽约上，回复会回到纽约")
        XCTAssertNil(c.ccHubId, "改连到 hub_id 还不知道的主电脑：留 nil（b4 #3）")
        XCTAssertNil(c.ccHubIdentity)
        XCTAssertEqual(CCHubRegistry.hubId(of: c), CCHubRegistry.primaryId)
        XCTAssertNil(CCHubTitle.rebind(c, to: nyc, unfinished: false, registry: r), "都回完了不提示")
        XCTAssertEqual(c.ccHubId, nyc)
        XCTAssertNil(CCHubTitle.rebind(c, to: nyc, unfinished: true, registry: r), "选的就是现在这台：不动不提示")

        r.remove(nyc)
        XCTAssertNil(CCHubTitle.rebind(c, to: CCHubRegistry.primaryId, unfinished: true, registry: r), "那台删了，回复回不来，不说「会回到」")
        XCTAssertEqual(CCHubRegistry.hubId(of: c), CCHubRegistry.primaryId, "照样改连")
        XCTAssertNil(CCHubTitle.blocker(for: c, registry: r))
    }

    /// b4 #3：有会话名的对话 / 「换一台」改连主电脑，主电脑 hub_id 不知道 → 两字段 nil，同步 / 恢复后照旧落本机主电脑，不判待绑定；知道了才写 primary + hub_id
    func testRebindToPrimaryWithUnknownIdentityStaysLegacyThroughSyncResolve() {
        let r = makeRegistry()
        let nyc = add(r, "纽约", token: "t-nyc")
        let named = conversation()
        named.ccBridgeSessionName = "mp-cc-3"
        named.ccHubId = nyc
        CCHubTitle.pickForNewConversation(named, hubId: CCHubRegistry.primaryId, registry: r)
        XCTAssertNil(named.ccHubId)
        XCTAssertNil(named.ccHubIdentity)
        XCTAssertEqual(named.ccBridgeSessionName, "mp-cc-3", "会话名不动")
        let exported = CCHubRegistry.exportedIdentity(of: named, standard: std, suitePrefix: prefix)
        XCTAssertNil(CCHubRegistry.resolveSynced(hubId: named.ccHubId, identity: exported, standard: std, suitePrefix: prefix),
                     "导出 / 恢复：老语义 = 本机主电脑，不是待绑定")

        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        XCTAssertTrue(r.rebind(named, to: nyc))
        XCTAssertTrue(r.rebind(named, to: CCHubRegistry.primaryId))
        XCTAssertEqual(named.ccHubId, CCHubRegistry.primaryId, "知道了 hub_id：写明确的 primary + hub_id")
        XCTAssertEqual(named.ccHubIdentity, "HUB-P")
    }

    /// b4 #4：主电脑待配对 / 换了机器，标题 / 输入框 / 发送拦截都报出来；正常时什么都不多
    func testPrimaryNeedsPairingIsReportedByRouteAndViewModel() {
        let secrets = CCHubRegistryTests.FakeSecrets()
        secrets.values[CCHubRegistry.keychainAccount(for: CCHubRegistry.primaryId)] = "tampered"
        std.set("ws://10.0.0.1:7890/cc", forKey: CCBridgeEndpoints.overrideKey)
        std.set(CCHubPairingStore.fingerprint("t1"), forKey: CCHubPairingStore.fingerprintKey)
        let p = CCBridgeWebSocketClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: std, transportOffMain: false)
        clients.append(p)
        let r = CCHubRegistry(primary: p, standard: std, suitePrefix: prefix, secrets: secrets, originDefaults: std)
        let c = conversation()
        let vm = ConversationViewModel()
        vm.ccHubRegistry = r
        vm.ccBridgeClient = p
        XCTAssertNil(CCHubTitle.blocker(for: c, registry: r), "启动前：正常")
        XCTAssertNil(vm.ccSendBlocker(for: c))
        XCTAssertNil(CCHubTitle.subtitle(for: c, registry: r), "1 台正常：标题不变")

        r.start { _ in }
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .needsPairing)
        XCTAssertEqual(CCHubTitle.blocker(for: c, registry: r), .needsPairing)
        XCTAssertEqual(vm.ccSendBlocker(for: c), .needsPairing, "发送拦截跟标题同一份")
        XCTAssertEqual(CCHubTitle.subtitle(for: c, registry: r), "\(r.primaryName) · 要重新配对", "1 台也写")
    }

    /// b4 #9：等待项按来源判，连改两次不把 A 上的算到 B 头上
    func testUnfinishedIsJudgedBySourceHub() {
        let vm = ConversationViewModel()
        let c = conversation("chat-1")
        c.ccHubId = "hub-a"
        XCTAssertFalse(vm.ccHasUnfinished(for: c))
        vm.ccWaitingSince["chat-1"] = Date()
        vm.ccWaitingHub["chat-1"] = "hub-a"
        XCTAssertTrue(vm.ccHasUnfinished(for: c))
        c.ccHubId = "hub-b"
        XCTAssertFalse(vm.ccHasUnfinished(for: c), "A 上等的回复不算 B 的（改连到 B 后再改连到 C）")
        vm.ccWaitingSince["chat-1"] = nil
        c.ccHubId = "hub-a"
        XCTAssertFalse(vm.ccHasUnfinished(for: c), "回完了")
        let client = CCBridgeWebSocketClient(hubId: "hub-a", defaults: std, transportOffMain: false)
        clients.append(client)
        vm.pendingCCQuestion = .init(chatId: "chat-1", toolUseId: "tu", questions: [], collectedAnswers: [],
                                     origin: .init(client))
        XCTAssertTrue(vm.ccHasUnfinished(for: c))
        c.ccHubId = "hub-b"
        XCTAssertFalse(vm.ccHasUnfinished(for: c), "别的那台问的题不算这台的")
    }

    /// b4 #2：选台期间旧那台迟到的 list / spawn 回包不认（对话 / 那台 / 代次三样都对得上才认）
    func testSessionPickerIgnoresLateResponsesFromPreviousHub() {
        var requests = CCSessionPickerRequests()
        let listA = requests.begin(conversationId: "c1", hubId: "hub-a")
        let spawnA = requests.begin(conversationId: "c1", hubId: "hub-a")
        XCTAssertTrue(requests.isCurrent(listA, conversationId: "c1", hubId: "hub-a"))

        // 选 B：旧代次作废
        requests.invalidate()
        let listB = requests.begin(conversationId: "c1", hubId: "hub-b")
        XCTAssertTrue(requests.isCurrent(listB, conversationId: "c1", hubId: "hub-b"), "B 的列表先到：认")
        XCTAssertFalse(requests.isCurrent(listA, conversationId: "c1", hubId: "hub-b"), "A 的列表后到：不覆盖")
        XCTAssertFalse(requests.isCurrent(spawnA, conversationId: "c1", hubId: "hub-b"), "A 上新建成功：不把会话名写进绑 B 的对话")
        XCTAssertFalse(requests.isCurrent(listB, conversationId: "c2", hubId: "hub-b"), "换了对话也不认")
        XCTAssertFalse(requests.isCurrent(listB, conversationId: "c1", hubId: "hub-a"), "对话又被改回 A（同代次没作废）也不认 B 的")

        // 关掉选择器：全作废
        requests.invalidate()
        XCTAssertFalse(requests.isCurrent(listB, conversationId: "c1", hubId: "hub-b"))
    }
}
