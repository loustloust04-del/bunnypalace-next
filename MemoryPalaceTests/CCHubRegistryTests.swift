import XCTest
@testable import 记忆花园

/// plan-multi-hub B2.1–B2.5 / B2.7：配对快照 + 口令指纹、keepExistingToken 收紧、Registry、client 身份 / 失效、推送 token 分发、
/// 附加 hub 的最小帧闸。全部注入 defaults suite + 口令替身，不碰真钥匙串、不连真 hub（测试宿主把 startTask 挡在发请求前）。
final class CCHubRegistryTests: XCTestCase {
    /// 口令替身：写入同钥匙串语义（先删后写，写失败 = 旧值也没了）。同时当 ProviderManager 的钥匙串（记 sync 属性）
    final class FakeSecrets: HubSecretStore, APIKeyKeychain {
        var values: [String: String] = [:]
        /// account → 最后一次写入时的 sync 属性
        var synced: [String: Bool] = [:]
        var failWrites = false
        var failWritesTo: Set<String> = []
        var failRemoves = false
        var unreadable: Set<String> = []
        private(set) var writeLog: [String] = []

        func read(account: String) -> HubSecretRead {
            if unreadable.contains(account) { return .unreadable }
            return values[account].map(HubSecretRead.value) ?? .absent
        }

        func write(_ token: String, account: String) -> Bool { set(token, account: account, sync: false) }

        func remove(account: String) -> Bool {
            if failRemoves { return false }
            values.removeValue(forKey: account)
            synced.removeValue(forKey: account)
            return true
        }

        func set(_ value: String, account: String, sync: Bool) -> Bool {
            writeLog.append(account)
            values.removeValue(forKey: account)
            if failWrites || failWritesTo.contains(account) { return false }
            if !value.isEmpty {
                values[account] = value
                synced[account] = sync
            }
            return true
        }

        func getAll() -> [String: String] { values }
    }

    static let localPrimary = CCHubRegistry.keychainAccount(for: CCHubRegistry.primaryId)
    /// 握手替身：连上的就是主 hub（hub_id = HUB-P）
    static let sameMachine: CCHubRegistry.PairingProbe = { _, _ in .hello(hubId: "HUB-P") }

    /// 发送替身：记下每一帧发在哪个 task 上，completion 异步回成功
    final class Wire {
        private let lock = NSLock()
        private var items: [(task: URLSessionWebSocketTask, obj: [String: Any])] = []

        func install(on client: CCBridgeWebSocketClient) {
            client.setTransmitHookForTesting { [weak self] task, text, completion in
                let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                self?.lock.lock()
                self?.items.append((task, obj))
                self?.lock.unlock()
                DispatchQueue.global().async { completion(nil) }
            }
        }

        func sent(_ type: String) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return items.map(\.obj).filter { $0["type"] as? String == type }
        }

        func sentTypes() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return items.compactMap { $0.obj["type"] as? String }
        }
    }

    private var stdName: String!
    private var std: UserDefaults!
    private var prefix: String!
    private var secrets: FakeSecrets!
    private var made: [String: CCBridgeWebSocketClient] = [:]
    private var wires: [String: Wire] = [:]
    private var extraClients: [CCBridgeWebSocketClient] = []
    private var extraSuites: [String] = []
    private var keptWires: [Wire] = []
    private var session: URLSession!

    private let a1URL = "ws://10.0.0.1:7890/cc"
    private let b1URL = "ws://100.64.0.1:7890/cc"
    private let r1URL = "wss://relay-one.example.com:8443/cc"

    override func setUp() {
        super.setUp()
        stdName = "CCHubRegistryTests.std.\(UUID().uuidString)"
        std = UserDefaults(suiteName: stdName)!
        prefix = "CCHubRegistryTests.hub.\(UUID().uuidString)."
        secrets = FakeSecrets()
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        for c in Array(made.values) + extraClients {
            c.disconnect()
            c.setTransmitHookForTesting(nil)
        }
        for id in made.keys { UserDefaults(suiteName: prefix + id)?.removePersistentDomain(forName: prefix + id) }
        for name in extraSuites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        made = [:]
        wires = [:]
        extraClients = []
        keptWires = []
        session.invalidateAndCancel()
        std.removePersistentDomain(forName: stdName)
        super.tearDown()
    }

    // MARK: - 工具

    @MainActor
    private func makeRegistry(primary: CCBridgeWebSocketClient? = nil, launchd: String? = nil) -> (CCHubRegistry, CCBridgeWebSocketClient) {
        let p = primary ?? newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: std)
        let r = CCHubRegistry(primary: p, standard: std, suitePrefix: prefix, secrets: secrets, originDefaults: std,
                              launchdToken: { launchd }) { [unowned self] id, d in
            let c = CCBridgeWebSocketClient(hubId: id, defaults: d)
            let w = Wire()
            w.install(on: c)
            self.made[id] = c
            self.wires[id] = w
            return c
        }
        return (r, p)
    }

    private func newClient(hubId: String, defaults: UserDefaults, a1: Bool = CCBridgeWebSocketClient.a1TransportOffMain) -> CCBridgeWebSocketClient {
        let c = CCBridgeWebSocketClient(hubId: hubId, defaults: defaults, transportOffMain: a1)
        extraClients.append(c)
        return c
    }

    @discardableResult
    private func wired(_ client: CCBridgeWebSocketClient) -> Wire {
        let w = Wire()
        w.install(on: client)
        keptWires.append(w)
        return w
    }

    private func newSuite() -> UserDefaults {
        let name = "CCHubRegistryTests.extra.\(UUID().uuidString)"
        extraSuites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func seedPrimary(token: String = "t1") {
        std.set(a1URL, forKey: CCBridgeEndpoints.overrideKey)
        std.set(b1URL, forKey: CCBridgeEndpoints.backupKey)
        std.set(r1URL, forKey: CCBridgeEndpoints.relayKey)
        std.set("pin-one=", forKey: CCBridgeEndpoints.relayPinKey)
        secrets.values[HubTokenStore.keychainAccount] = token
    }

    private var primarySnapshot: [String: String?] {
        var out: [String: String?] = [:]
        for k in [CCBridgeEndpoints.overrideKey, CCBridgeEndpoints.backupKey, CCBridgeEndpoints.relayKey, CCBridgeEndpoints.relayPinKey] {
            out[k] = std.string(forKey: k)
        }
        out["secret"] = secrets.values[HubTokenStore.keychainAccount]
        return out
    }

    private let pairing2 = CCHubPairing(primaryURL: "ws://192.168.9.2:7890/cc", backupURL: "ws://100.64.9.2:7890/cc",
                                        relayURL: "wss://relay-two.example.com/cc", relayPin: "pin-two=")

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

    private func settle(_ seconds: TimeInterval = 0.2) { spin(timeout: seconds) { false } }

    /// 当成「刚连上」：装 task + didOpen（不碰网络）
    @discardableResult
    private func open(_ client: CCBridgeWebSocketClient, url: String = "ws://127.0.0.1:9/cc") -> URLSessionWebSocketTask {
        let u = URL(string: url)!
        let task = session.webSocketTask(with: u)
        client.adoptTaskForTesting(task, url: u)
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        XCTAssertTrue(spin { client.isConnected && client.currentTaskForTesting === task })
        return task
    }

    private func tokens(_ urls: [URL]) -> Set<String?> { Set(urls.map(CCBridgeWebSocketClient.token(in:))) }

    // MARK: - 主 hub 旧槽位不动

    @MainActor
    func testPrimaryLegacyKeysAndSecretUntouchedBySecondaryHubOps() throws {
        seedPrimary()
        let before = primarySnapshot
        let (r, _) = makeRegistry()
        r.start { _ in }
        let primaryGen = std.object(forKey: CCHubPairingStore.genKey) as? Int
        let primaryFP = CCHubPairingStore.storedFingerprint(std)

        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2") else { return XCTFail("没加上") }
        XCTAssertEqual(r.updatePairing(id, CCHubPairing(primaryURL: "ws://192.168.9.3:7890/cc"), token: "t3"), .updated)
        r.rename(id, to: "纽约 VPS")
        r.remove(id)
        XCTAssertTrue(spin { self.secrets.values[CCHubRegistry.keychainAccount(for: id)] == nil })

        XCTAssertEqual(primarySnapshot, before, "主 hub 旧四键 + cc-bridge 一个字节都不动")
        XCTAssertEqual(std.object(forKey: CCHubPairingStore.genKey) as? Int, primaryGen)
        XCTAssertEqual(CCHubPairingStore.storedFingerprint(std), primaryFP)
        XCTAssertEqual(r.hubs.map(\.id), [CCHubRegistry.primaryId])
    }

    @MainActor
    func testLegacyPrimaryBackfillsFingerprintOnceAndConnectsLikeBefore() {
        seedPrimary(token: "t1")
        XCTAssertNil(CCHubPairingStore.storedFingerprint(std))
        let (r, primary) = makeRegistry()
        r.start { _ in }
        XCTAssertEqual(CCHubPairingStore.storedFingerprint(std), CCHubPairingStore.fingerprint("t1"))
        XCTAssertEqual(CCHubPairingStore.gen(std), 0)
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready)
        XCTAssertEqual(Set(primary.candidateHosts), ["10.0.0.1", "100.64.0.1", "relay-one.example.com"])
        XCTAssertEqual(tokens(primary.candidateURLsForTesting), ["t1"])
        // 只补不改：cc-bridge 换了之后再启动，指纹 / 本机副本都不跟着改
        secrets.values[HubTokenStore.keychainAccount] = "other"
        let (r2, p2) = makeRegistry()
        r2.start { _ in }
        XCTAssertEqual(CCHubPairingStore.storedFingerprint(std), CCHubPairingStore.fingerprint("t1"))
        XCTAssertEqual(tokens(p2.candidateURLsForTesting), ["t1"])
    }

    // MARK: - 主 hub 本机副本（impl1 #1）：连接只认 cc-bridge.hub.primary，cc-bridge 被 iCloud 改了不影响

    /// recheck1 #1：Mac 主 hub 配的是远端 A（地址 + A 指纹），本机副本、旧 cc-bridge 都没有，本机 launchd 装着 hub B →
    /// 不拿 B 的口令补副本、不改 A 的指纹、不连 A（待配对）
    @MainActor
    func testLaunchdTokenNeverFillsAPairingWithAnotherMachine() {
        std.set(a1URL, forKey: CCBridgeEndpoints.overrideKey)
        std.set(b1URL, forKey: CCBridgeEndpoints.backupKey)
        std.set(CCHubPairingStore.fingerprint("tA"), forKey: CCHubPairingStore.fingerprintKey)
        let (r, primary) = makeRegistry(launchd: "tB")
        wired(primary)
        r.start { _ in }
        XCTAssertNil(secrets.values[Self.localPrimary], "不写 B")
        XCTAssertNil(secrets.values[HubTokenStore.keychainAccount])
        XCTAssertEqual(CCHubPairingStore.storedFingerprint(std), CCHubPairingStore.fingerprint("tA"), "待核验的依据不被改掉")
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .needsPairing)
        XCTAssertTrue(primary.candidateURLsForTesting.isEmpty, "不连 A")
        XCTAssertNil(r.pairedPrimaryToken)
    }

    /// 老用户还没指纹、配的是远端：同样不补 B（不拿本机 hub 的口令去连别的电脑）
    @MainActor
    func testLaunchdTokenNotUsedForLegacyRemotePairing() {
        std.set(a1URL, forKey: CCBridgeEndpoints.overrideKey)
        let (r, primary) = makeRegistry(launchd: "tB")
        r.start { _ in }
        XCTAssertNil(secrets.values[Self.localPrimary])
        XCTAssertFalse(primary.candidateURLsForTesting.contains { $0.absoluteString.contains("tB") })
    }

    /// 配对目标就是这台 Mac（只有本机回环）：plist 口令补进本机副本（两份都写），照常连
    @MainActor
    func testLaunchdTokenFillsLoopbackPairing() {
        std.set(CCHubPairingStore.fingerprint(nil), forKey: CCHubPairingStore.fingerprintKey)   // 老的无口令 loopback 配对
        let (r, primary) = makeRegistry(launchd: "tB")
        r.start { _ in }
        XCTAssertEqual(secrets.values[Self.localPrimary], "tB")
        XCTAssertEqual(secrets.synced[Self.localPrimary], false)
        XCTAssertEqual(secrets.values[HubTokenStore.keychainAccount], "tB", "旧条目没有就照旧补一份（老版本回滚）")
        XCTAssertEqual(CCHubPairingStore.storedFingerprint(std), CCHubPairingStore.fingerprint("tB"))
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready)
        XCTAssertEqual(tokens(primary.candidateURLsForTesting), ["tB"])
        XCTAssertTrue(primary.candidateHosts.allSatisfy { $0 == "127.0.0.1" })
    }

    @MainActor
    func testFirstLaunchCopiesLegacyTokenIntoLocalCopyAndLeavesLegacyEntryAlone() {
        seedPrimary(token: "t1")
        let (r, primary) = makeRegistry()
        r.start { _ in }
        XCTAssertEqual(secrets.values[Self.localPrimary], "t1", "首次启动拷一份")
        XCTAssertEqual(secrets.synced[Self.localPrimary], false, "本机副本不同步")
        XCTAssertEqual(secrets.values[HubTokenStore.keychainAccount], "t1", "旧条目原样留着")
        XCTAssertFalse(secrets.writeLog.contains(HubTokenStore.keychainAccount), "旧条目不重写（不改同步属性）")
        XCTAssertEqual(tokens(primary.candidateURLsForTesting), ["t1"])
        XCTAssertEqual(r.pairedPrimaryToken, "t1")
    }

    @MainActor
    func testSyncedLegacyTokenIsNeverSentAfterMigration() {
        seedPrimary(token: "t1")
        let (r, _) = makeRegistry()
        r.start { _ in }
        // 另一台设备经 iCloud 钥匙串把 cc-bridge 改成它自己那台 hub 的口令，重启
        secrets.values[HubTokenStore.keychainAccount] = "t-other-device"
        let (r2, primary) = makeRegistry()
        r2.start { _ in }
        XCTAssertEqual(r2.status(for: CCHubRegistry.primaryId), .ready)
        XCTAssertEqual(tokens(primary.candidateURLsForTesting), ["t1"], "只用本机副本连")
        XCTAssertFalse(primary.candidateURLsForTesting.contains { $0.absoluteString.contains("t-other-device") })
        XCTAssertEqual(secrets.values[HubTokenStore.keychainAccount], "t-other-device", "旧条目不删不改")
        XCTAssertEqual(r2.pairedPrimaryToken, "t1")
    }

    /// 返工前的版本已经写过指纹、还没有本机副本：cc-bridge 对得上才拷，对不上（同步来的）不拷、待配对，绝不试连
    @MainActor
    func testLegacyTokenContradictingFingerprintIsNotCopiedAndNotTried() {
        seedPrimary(token: "t-synced")
        std.set(CCHubPairingStore.fingerprint("t1"), forKey: CCHubPairingStore.fingerprintKey)
        let (r, primary) = makeRegistry()
        wired(primary)
        r.start { _ in }
        XCTAssertNil(secrets.values[Self.localPrimary])
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .needsPairing)
        XCTAssertTrue(primary.isPairingHeld)
        XCTAssertTrue(primary.candidateURLsForTesting.isEmpty, "一个候选都不建 = 口令没进任何 URL")
        XCTAssertNil(r.pairedPrimaryToken)
        XCTAssertEqual(secrets.values[HubTokenStore.keychainAccount], "t-synced")

        secrets.values[HubTokenStore.keychainAccount] = "t1"
        let (r2, p2) = makeRegistry()
        r2.start { _ in }
        XCTAssertEqual(secrets.values[Self.localPrimary], "t1", "对得上：补")
        XCTAssertEqual(tokens(p2.candidateURLsForTesting), ["t1"])
    }

    @MainActor
    func testUnreadableLegacyTokenIsNotCopiedUntilReadable() {
        seedPrimary(token: "t1")
        secrets.unreadable = [HubTokenStore.keychainAccount]
        let (r, _) = makeRegistry()
        r.start { _ in }
        XCTAssertNil(secrets.values[Self.localPrimary])
        XCTAssertNil(CCHubPairingStore.storedFingerprint(std), "读不到这次不补")
        secrets.unreadable = []
        let (r2, p2) = makeRegistry()
        r2.start { _ in }
        XCTAssertEqual(secrets.values[Self.localPrimary], "t1")
        XCTAssertEqual(CCHubPairingStore.storedFingerprint(std), CCHubPairingStore.fingerprint("t1"))
        XCTAssertEqual(tokens(p2.candidateURLsForTesting), ["t1"])
    }

    @MainActor
    func testLocalCopyNotMatchingFingerprintHoldsWithoutTrying() {
        seedPrimary(token: "t1")
        let (r, _) = makeRegistry()
        r.start { _ in }
        secrets.values[Self.localPrimary] = "tampered"
        let (r2, primary) = makeRegistry()
        wired(primary)
        r2.start { _ in }
        XCTAssertEqual(r2.status(for: CCHubRegistry.primaryId), .needsPairing, "主 hub 也不按握手试")
        XCTAssertTrue(primary.isPairingHeld)
        XCTAssertTrue(primary.candidateURLsForTesting.isEmpty)
    }

    /// 扫码 / 手填写两份：本机副本（不同步）+ cc-bridge（经 ProviderManager，照旧跟同步开关走，给老版本回滚）
    @MainActor
    func testPairingWritesLocalCopyAndLegacyEntry() async {
        seedPrimary(token: "t1")
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        let (r, primary) = makeRegistry()
        r.start { _ in }
        let pm = ProviderManager(keychain: secrets)
        let p = CCPairPayload.parse(#"{"mpcc":1,"u":"ws://10.0.0.9:7890/cc","t":"t-new"}"#)!
        let applied = await r.pairPrimary(CCHubPairing(payload: p), token: p.t, providerManager: pm, probe: Self.sameMachine)
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(secrets.values[Self.localPrimary], "t-new")
        XCTAssertEqual(secrets.synced[Self.localPrimary], false)
        XCTAssertEqual(secrets.values[HubTokenStore.keychainAccount], "t-new")
        XCTAssertEqual(secrets.synced[HubTokenStore.keychainAccount], pm.cloudSyncEnabled)
        XCTAssertEqual(tokens(primary.candidateURLsForTesting), ["t-new"])

        // 旧条目写失败不影响（连接不读它）；本机副本写失败 = 整个放弃，地址不动
        secrets.failWritesTo = [HubTokenStore.keychainAccount]
        let manual = await r.applyPrimaryManual(primary: "ws://10.0.0.8:7890/cc", backup: "", token: "t-3", providerManager: nil, reconnect: false,
                                                 probe: Self.sameMachine)
        XCTAssertEqual(manual, .applied)
        XCTAssertEqual(secrets.values[Self.localPrimary], "t-3")
        secrets.failWritesTo = [Self.localPrimary]
        let failed = await r.applyPrimaryManual(primary: "ws://10.0.0.7:7890/cc", backup: "", token: "t-4", providerManager: nil, reconnect: false,
                                                probe: Self.sameMachine)
        XCTAssertEqual(failed, .failed(.secretWriteFailed))
        XCTAssertEqual(std.string(forKey: CCBridgeEndpoints.overrideKey), "ws://10.0.0.8:7890/cc", "地址不动")
    }

    /// API 卡「没改动」的判断也要核本机副本里真的是这个口令（不只比指纹）
    @MainActor
    func testManualUnchangedChecksActualLocalCopy() async {
        seedPrimary(token: "t1")
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        let (r, _) = makeRegistry()
        r.start { _ in }
        secrets.values.removeValue(forKey: Self.localPrimary)   // 钥匙串里没了，指纹还在
        let writesBefore = secrets.writeLog.count
        let result = await r.applyPrimaryManual(primary: a1URL, backup: b1URL, token: "t1", providerManager: nil, reconnect: false, probe: Self.sameMachine)
        XCTAssertEqual(result, .applied)
        XCTAssertGreaterThan(secrets.writeLog.count, writesBefore, "口令没在钥匙串里：重写，不跳过")
        XCTAssertEqual(secrets.values[Self.localPrimary], "t1")
    }

    func testLocalOnlyAccountsReadableAfterFirstUnlock() {
        XCTAssertEqual(KeychainStore.accessibleOverride(account: Self.localPrimary), kSecAttrAccessibleAfterFirstUnlock)
        XCTAssertTrue(KeychainStore.isLocalOnly(account: Self.localPrimary))
        XCTAssertTrue(KeychainStore.isLocalOnly(account: CCHubRegistry.keychainAccount(for: "abc")))
        XCTAssertTrue(KeychainStore.isLocalOnly(account: "cc-bridge-hub-token"))
        XCTAssertFalse(KeychainStore.isLocalOnly(account: HubTokenStore.keychainAccount), "旧条目照旧跟同步开关走")
        XCTAssertFalse(KeychainStore.isLocalOnly(account: "openai"))
    }

    // MARK: - 口令被拒（impl1 #14）

    @MainActor
    func testRejectedTokenHoldsAndOnlyANewTokenRetries() {
        seedPrimary(token: "wrong")
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        let (r, primary) = makeRegistry()
        wired(primary)
        r.start { _ in }
        let task = open(primary, url: "ws://127.0.0.1:9/cc?token=wrong")
        primary.urlSession(session, webSocketTask: task, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        XCTAssertTrue(spin { r.status(for: CCHubRegistry.primaryId) == .needsPairing })
        XCTAssertTrue(primary.isPairingHeld)
        XCTAssertEqual(std.string(forKey: CCHubPairingStore.rejectedFingerprintKey), CCHubPairingStore.fingerprint("wrong"))

        // 同一个口令：再启动 / 重启都不再试
        r.start { _ in }
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .needsPairing)
        let (r2, p2) = makeRegistry()
        r2.start { _ in }
        XCTAssertEqual(r2.status(for: CCHubRegistry.primaryId), .needsPairing)
        XCTAssertTrue(p2.candidateURLsForTesting.isEmpty)
        XCTAssertNil(r2.pairedPrimaryToken)

        // 换了口令（重新配对，同进程）：解除 hold，按新口令连
        XCTAssertEqual(r.updatePairing(CCHubRegistry.primaryId, CCHubPairing.read(std).manual(primary: a1URL, backup: b1URL), token: "right",
                                       expectedIdentity: "HUB-P"), .updated)
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready)
        XCTAssertFalse(primary.isPairingHeld)
        XCTAssertEqual(tokens(primary.candidateURLsForTesting), ["right"])
        XCTAssertNil(std.string(forKey: CCHubPairingStore.rejectedFingerprintKey))
    }

    /// 被拒的不是配对口令（Mac 内嵌 hub 那种显式给的口令）：不记、不停
    @MainActor
    func testRejectionOfNonPairedTokenIsNotRecorded() {
        seedPrimary(token: "t1")
        let (r, primary) = makeRegistry()
        wired(primary)
        r.start { _ in }
        let task = open(primary, url: "ws://127.0.0.1:9/cc?token=embedded")
        primary.urlSession(session, webSocketTask: task, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        settle()
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready)
        XCTAssertNil(std.string(forKey: CCHubPairingStore.rejectedFingerprintKey))
    }

    // MARK: - 身份核准闸（impl1 #2）

    @MainActor
    private func gatedSecondary(identity: String? = nil) -> (CCHubRegistry, String, CCBridgeWebSocketClient, Wire) {
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2", identity: identity) else {
            XCTFail("没加上")
            return (r, "", newClient(hubId: "x", defaults: newSuite()), Wire())
        }
        return (r, id, made[id]!, wires[id]!)
    }

    @MainActor
    private func assertBusinessWaitsForHello(identity: String?, hello: [String: Any]) {
        let (r, id, client, wire) = gatedSecondary(identity: identity)
        var delivered: [String] = []
        client.onProactiveMessage = { _, content, _, _, _, _, _, _, _ in delivered.append(content); return true }
        let task = open(client)
        client.sendUserMessage(chatId: "C", messageId: "m1", content: "hi", user: "u", session: nil, replyTo: nil, attachments: [])
        client.handleIncoming(text(["type": "reply", "chat_id": "C", "content": "r1", "reply_id": "rid-1", "ts": 1]), source: task)
        client.handleIncoming(text(["type": "transport_policies", "policies": ["mp-cc": "stream"]]), source: task)
        settle()
        XCTAssertEqual(Set(wire.sentTypes()), ["client_info"], "核准前只发握手帧")
        XCTAssertTrue(delivered.isEmpty, "核准前业务帧不落")
        XCTAssertNil(r.defaults(for: id)?.object(forKey: CCBridgeWebSocketClient.transportPolicyKey))

        client.handleIncoming(text(hello), source: task)
        XCTAssertTrue(spin { wire.sent("send").count == 1 && delivered == ["r1"] })
        XCTAssertTrue(spin { CCBridgeWebSocketClient.transportPolicy(for: "mp-cc", hub: client) == "stream" })
        XCTAssertFalse(wire.sent("set_cc_config").isEmpty, "连上接线排着的帧放出来")
        XCTAssertEqual(r.identity(of: id), hello["hub_id"] as? String ?? identity)
        // 核准后直接走
        client.handleIncoming(text(["type": "reply", "chat_id": "C", "content": "r2", "reply_id": "rid-2", "ts": 2]), source: task)
        XCTAssertTrue(spin { delivered == ["r1", "r2"] })
    }

    @MainActor
    func testBusinessFramesWaitForApprovedHelloThenFlowInOrder() {
        assertBusinessWaitsForHello(identity: "HUB-A", hello: ["type": "hello", "hub_id": "HUB-A"])
    }

    @MainActor
    func testFirstHelloRecordsIdentityAndApproves() {
        assertBusinessWaitsForHello(identity: nil, hello: ["type": "hello", "hub_id": "HUB-N"])
    }

    /// 老 hub 的 hello 不带 hub_id：拿到 hello 即核准
    @MainActor
    func testOldHubHelloWithoutHubIdApproves() {
        assertBusinessWaitsForHello(identity: nil, hello: ["type": "hello", "host_name": "old"])
    }

    /// 核准的 hello 记下机型；换了机器（核不过）不改；冷启动（新 Registry 同一份 defaults）没握手也拿得到 —— 首页 3D 不跳外形
    @MainActor
    func testLastKnownDeviceRemembersApprovedHelloOnly() {
        let (r, id, client, _) = gatedSecondary(identity: "HUB-A")
        XCTAssertNil(r.lastKnownDevice(for: id))
        let task = open(client)
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-A", "host_model_name": "MacBook Air (15-inch, M5)"]), source: task)
        XCTAssertTrue(spin { r.lastKnownDevice(for: id) == .laptop })
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-OTHER", "host_model_name": "iMac (24-inch, M4)"]), source: task)
        XCTAssertTrue(spin { r.status(for: id) == .identityChanged })
        XCTAssertEqual(r.lastKnownDevice(for: id), .laptop, "换了机器：沿用上次核准的")
        let (cold, _) = makeRegistry()
        XCTAssertEqual(cold.lastKnownDevice(for: id), .laptop, "冷启动没握手也认得")
    }

    @MainActor
    func testContradictingHelloDropsEverythingQueuedAndStops() {
        let (r, id, client, wire) = gatedSecondary(identity: "HUB-A")
        var delivered = 0
        client.onProactiveMessage = { _, _, _, _, _, _, _, _, _ in delivered += 1; return true }
        let task = open(client)
        client.sendUserMessage(chatId: "C", messageId: "m1", content: "hi", user: "u", session: nil, replyTo: nil, attachments: [])
        client.handleIncoming(text(["type": "reply", "chat_id": "C", "content": "r1", "reply_id": "rid-1", "ts": 1]), source: task)
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-OTHER"]), source: task)
        XCTAssertTrue(spin { r.status(for: id) == .identityChanged })
        settle()
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(wire.sent("send").isEmpty, "用户消息没发给另一台")
        XCTAssertTrue(wire.sent("set_cc_config").isEmpty)
        XCTAssertTrue(client.isPairingHeld)
        XCTAssertTrue(spin { client.sendTracker.store.entry("m1")?.state == .failed }, "回执没发出去")
    }

    /// 两台记成同一个 hub_id = 矛盾，后一台停住
    @MainActor
    func testFirstHelloClaimingAnotherHubsIdentityIsRejected() {
        let (r, id, client, _) = gatedSecondary()
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        let task = open(client)
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-P"]), source: task)
        XCTAssertTrue(spin { r.status(for: id) == .identityChanged })
        XCTAssertNil(r.identity(of: id))
    }

    @MainActor
    func testNoHelloPrimaryReleasedAfterTimeoutSecondaryStaysGated() {
        seedPrimary(token: "t1")
        let (r, primary) = makeRegistry()
        let pw = wired(primary)
        primary.helloTimeoutForTesting = 0.2
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "x", pairing: pairing2, token: "t2") else { return XCTFail() }
        made[id]!.helloTimeoutForTesting = 0.2
        open(primary)
        open(made[id]!)
        primary.sendCCConfig()
        made[id]!.sendCCConfig()
        XCTAssertTrue(spin { !pw.sent("set_cc_config").isEmpty }, "极老 hub（不发 hello）：主 hub 等一会儿按旧行为放行")
        XCTAssertTrue(primary.identityVerifiedForTesting)
        settle(0.5)
        XCTAssertTrue(wires[id]!.sent("set_cc_config").isEmpty, "附加 hub 不放行")
        XCTAssertFalse(made[id]!.identityVerifiedForTesting)
    }

    /// 不经 Registry 建的 client 闸关着，行为同原来（现有 A1 测试全靠这条）
    func testUngatedClientSendsRightAway() {
        let c = newClient(hubId: "h-ungated", defaults: newSuite())
        let w = wired(c)
        open(c)
        c.sendCCConfig()
        XCTAssertTrue(spin { !w.sent("set_cc_config").isEmpty })
    }

    // MARK: - 配对提交契约（impl1 #6）

    @MainActor
    func testUpdatePairingKeepsIdentityAndRefusesAnotherMachineOrDuplicates() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let a) = r.addHub(name: "A", pairing: pairing2, token: "ta", identity: "HUB-A") else { return XCTFail() }
        guard case .added(let b) = r.addHub(name: "B", pairing: CCHubPairing(primaryURL: "ws://192.168.7.7:7890/cc"), token: "tb") else { return XCTFail() }
        let p = CCHubPairing(primaryURL: "ws://192.168.9.9:7890/cc")
        XCTAssertEqual(r.updatePairing(a, p, token: "ta2", expectedIdentity: "HUB-Z"), .differentMachine, "预期的是另一台：只能新增")
        XCTAssertEqual(r.updatePairing(b, p, token: "tb2", expectedIdentity: "HUB-A"), .duplicateIdentity(a))
        XCTAssertEqual(r.updatePairing(b, p, token: "ta"), .duplicateToken(a))
        XCTAssertEqual(r.defaults(for: a)?.string(forKey: CCBridgeEndpoints.overrideKey), pairing2.primaryURL, "拒了就一个字节不写")

        XCTAssertEqual(r.updatePairing(a, p, token: "ta2", expectedIdentity: "HUB-A"), .updated)
        XCTAssertEqual(r.identity(of: a), "HUB-A", "更新保留记下的 hub_id，下次握手照核")
        XCTAssertEqual(r.updatePairing(b, p, token: "tb2", expectedIdentity: "HUB-B"), .updated)
        XCTAssertEqual(r.identity(of: b), "HUB-B", "没记过的按预期记下，hello 必须对得上")

        XCTAssertEqual(r.addHub(name: "A again", pairing: p, token: "brand-new", identity: "HUB-A"), .duplicateIdentity(a))
    }

    @MainActor
    func testUpdatedPairingStillGatedUntilHelloMatches() {
        let (r, id, client, wire) = gatedSecondary(identity: "HUB-A")
        XCTAssertEqual(r.updatePairing(id, CCHubPairing(primaryURL: "ws://192.168.9.9:7890/cc"), token: "t3"), .updated)
        let task = open(client)
        client.sendCCConfig()
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-B"]), source: task)
        XCTAssertTrue(spin { r.status(for: id) == .identityChanged }, "扫进的是另一台：握手核对停住")
        settle()
        XCTAssertTrue(wire.sent("set_cc_config").isEmpty)
    }

    // MARK: - 在线删除（impl1 #7）：注销帧完成前业务已经全关

    @MainActor
    func testOnlineRemoveClosesBusinessImmediatelyWhileUnregisterIsInFlight() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        r.setPushToken("tok1")
        guard case .added(let id) = r.addHub(name: "B", pairing: pairing2, token: "tb") else { return XCTFail() }
        let client = made[id]!
        let suite = r.defaults(for: id)!
        // 注销帧的 completion 由测试决定什么时候回
        let lock = NSLock()
        var frames: [[String: Any]] = []
        var pendingUnregister: ((Error?) -> Void)?
        client.setTransmitHookForTesting { _, text, completion in
            let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            lock.lock(); frames.append(obj); lock.unlock()
            if obj["type"] as? String == "unregister_push_token" { pendingUnregister = completion } else { completion(nil) }
        }
        var delivered = 0
        client.onProactiveMessage = { _, _, _, _, _, _, _, _, _ in delivered += 1; return true }
        let task = open(client)
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-B"]), source: task)
        XCTAssertTrue(spin { client.identityVerifiedForTesting })
        settle()
        lock.lock(); let sentBeforeRemove = frames.count; lock.unlock()
        // 删之前已经过了入口的帧在排队
        let release = client.holdHandlersForTesting()
        client.handleIncoming(text(["type": "reply", "chat_id": "C", "content": "late", "reply_id": "r-late", "ts": 9_000_000]), source: task)
        client.handleIncoming(text(["type": "session_phase", "session_name": "mp-cc", "chat_id": "C", "phase": "working"]), source: task)
        client.handleIncoming(text(["type": "session_model", "session_name": "mp-cc", "model": "m"]), source: task)
        r.remove(id)
        release()
        XCTAssertTrue(spin { pendingUnregister != nil }, "注销帧在摘下的旧连接上发出去了")
        // completion 还没回：任何业务都不能生效
        client.sendUserMessage(chatId: "C", messageId: "m-after", content: "x", user: "u", session: nil, replyTo: nil, attachments: [])
        client.retrySend(messageId: "m-after")
        CCBridgeWebSocketClient.setKeepalivePolicy("always", for: "mp-cc", hub: client)
        CCBridgeWebSocketClient.setTransportPolicy("stream", for: "mp-cc", hub: client)
        client.handleIncoming(text(["type": "reply", "chat_id": "C", "content": "later", "reply_id": "r-later", "ts": 9_000_001]), source: task)
        client.drainPipelinesForTesting()
        settle()
        XCTAssertEqual(delivered, 0, "迟到 reply 不落")
        XCTAssertNil(CCSessionPhaseStore.shared.phase(for: "C", hubId: id))
        XCTAssertNil(CCSessionModelStore.shared.entry(for: "mp-cc", hubId: id).model)
        lock.lock(); let afterRemove = frames.dropFirst(sentBeforeRemove).compactMap { $0["type"] as? String }; lock.unlock()
        XCTAssertEqual(afterRemove, ["unregister_push_token"], "删除之后只有那一帧注销（发送 / 重发 / 保暖表 / 传输策略都不出门）")
        XCTAssertNil(suite.object(forKey: CCBridgeWebSocketClient.keepalivePolicyKey))
        XCTAssertNil(suite.object(forKey: "ccSeenReplyIds"))
        XCTAssertNotNil(secrets.values[CCHubRegistry.keychainAccount(for: id)], "存储等注销结束再删")

        pendingUnregister?(nil)
        XCTAssertTrue(spin { self.secrets.values[CCHubRegistry.keychainAccount(for: id)] == nil })
        XCTAssertNil(std.array(forKey: CCHubRegistry.pendingCleanupKey))
        XCTAssertEqual((std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]]) ?? [], [], "发出去了不记待注销")
    }

    // MARK: - 删除事务（impl1 #8）：中断后新进程按记录做完

    @MainActor
    private func relaunch() -> CCHubRegistry {
        extraClients.append(contentsOf: made.values)
        made = [:]
        let (r2, _) = makeRegistry()
        r2.start { _ in }
        return r2
    }

    @MainActor
    func testRemovalInterruptedBeforeListChangeIsFinishedOnRelaunch() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        r.setPushToken("tok1")
        guard case .added(let id) = r.addHub(name: "B", pairing: pairing2, token: "tb", identity: "HUB-B") else { return XCTFail() }
        r.removalInterruptForTesting = { $0 == .recordWritten }
        r.remove(id)
        XCTAssertEqual((std.array(forKey: CCHubRegistry.listKey) as? [[String: String]])?.count, 1, "进程死在撤名单之前")
        let r2 = relaunch()
        XCTAssertEqual(r2.hubs.map(\.id), [CCHubRegistry.primaryId], "删除意图照做完")
        XCTAssertNil(secrets.values[CCHubRegistry.keychainAccount(for: id)])
        XCTAssertNil(UserDefaults(suiteName: prefix + id)!.string(forKey: CCBridgeEndpoints.overrideKey))
        XCTAssertNil(std.array(forKey: CCHubRegistry.pendingCleanupKey))
        XCTAssertEqual(std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]], [["hub": "HUB-B", "token": "tok1"]],
                       "没注销成的 token 转待注销")
    }

    @MainActor
    func testRemovalInterruptedWhileUnregisterPendingKeepsTokenForLater() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        r.setPushToken("tok1")
        guard case .added(let id) = r.addHub(name: "B", pairing: pairing2, token: "tb", identity: "HUB-B") else { return XCTFail() }
        r.removalInterruptForTesting = { $0 == .invalidated }
        r.remove(id)
        XCTAssertTrue(spin { self.made[id]!.isInvalidated })
        settle()
        let records = std.array(forKey: CCHubRegistry.pendingCleanupKey) as? [[String: String]]
        XCTAssertEqual(records, [["id": id, "hub": "HUB-B", "token": "tok1"]], "删除记录带着槽位、hub_id、待注销 token")
        let r2 = relaunch()
        XCTAssertEqual(r2.hubs.count, 1)
        XCTAssertEqual(std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]], [["hub": "HUB-B", "token": "tok1"]])
        XCTAssertNil(secrets.values[CCHubRegistry.keychainAccount(for: id)])
        XCTAssertNil(std.array(forKey: CCHubRegistry.pendingCleanupKey))
    }

    @MainActor
    func testKeychainRemoveFailureKeepsCleanupUntilItSucceeds() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "B", pairing: pairing2, token: "tb") else { return XCTFail() }
        secrets.failRemoves = true
        r.remove(id)
        XCTAssertTrue(spin { self.made[id]!.isInvalidated })
        settle()
        XCTAssertEqual((std.array(forKey: CCHubRegistry.pendingCleanupKey) as? [[String: String]])?.compactMap { $0["id"] }, [id])
        XCTAssertNotNil(secrets.values[CCHubRegistry.keychainAccount(for: id)])
        secrets.failRemoves = false
        _ = relaunch()
        XCTAssertNil(secrets.values[CCHubRegistry.keychainAccount(for: id)])
        XCTAssertNil(std.array(forKey: CCHubRegistry.pendingCleanupKey))
    }

    /// 返工前的删除记录只有槽位 id（[String]）：照样认
    @MainActor
    func testLegacyCleanupFormatStillPurged() {
        secrets.values[CCHubRegistry.keychainAccount(for: "old-slot")] = "x"
        std.set(["old-slot"], forKey: CCHubRegistry.pendingCleanupKey)
        let (r, _) = makeRegistry()
        r.start { _ in }
        XCTAssertNil(secrets.values[CCHubRegistry.keychainAccount(for: "old-slot")])
        XCTAssertNil(std.array(forKey: CCHubRegistry.pendingCleanupKey))
    }

    @MainActor
    func testPendingUnregisterKeptWhenSendFails() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        r.setPushToken("tok2")
        std.set([["hub": "HUB-A", "token": "tok-old"]], forKey: CCHubRegistry.pendingUnregisterKey)
        guard case .added(let id) = r.addHub(name: "A", pairing: pairing2, token: "ta") else { return XCTFail() }
        let client = made[id]!
        var fail = true
        client.setTransmitHookForTesting { _, _, completion in DispatchQueue.main.async { completion(fail ? NSError(domain: "t", code: 1) : nil) } }
        let task = open(client)
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-A"]), source: task)
        settle()
        XCTAssertEqual(std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]], [["hub": "HUB-A", "token": "tok-old"]],
                       "发送失败：留着下次")
        fail = false
        let task2 = open(client)
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-A"]), source: task2)
        XCTAssertTrue(spin { ((self.std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]]) ?? []).isEmpty })
    }

    // MARK: - 同步开关（impl1 #9）：先加 hub 再开同步，hub 口令照旧只在本机

    @MainActor
    func testCloudSyncToggleKeepsHubSecretsLocal() {
        seedPrimary(token: "t1")
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2") else { return XCTFail() }
        secrets.values["openai"] = "sk-x"
        secrets.values["cc-bridge-hub-token"] = "embedded"
        let before = UserDefaults.standard.object(forKey: "apiKeyCloudSync")
        defer {
            if let before { UserDefaults.standard.set(before, forKey: "apiKeyCloudSync") }
            else { UserDefaults.standard.removeObject(forKey: "apiKeyCloudSync") }
        }
        let pm = ProviderManager(keychain: secrets)
        XCTAssertEqual(pm.reencryptAllKeys(sync: true), [])
        XCTAssertEqual(secrets.synced["openai"], true)
        XCTAssertEqual(secrets.synced[HubTokenStore.keychainAccount], true, "旧条目照旧跟开关走")
        XCTAssertEqual(secrets.synced[CCHubRegistry.keychainAccount(for: id)], false, "附加 hub 口令不进 iCloud")
        XCTAssertEqual(secrets.synced[Self.localPrimary], false, "主 hub 本机副本不进 iCloud")
        XCTAssertEqual(secrets.synced["cc-bridge-hub-token"], false)
        XCTAssertEqual(secrets.values[CCHubRegistry.keychainAccount(for: id)], "t2")
    }

    // MARK: - API key 写入（impl1 #10）

    func testSetApiKeyUpdatesCacheOnlyAfterKeychainSucceeds() {
        let fake = FakeSecrets()
        fake.values["cred-x"] = "old"
        let pm = ProviderManager(keychain: fake)
        XCTAssertEqual(pm.apiKey(for: "cred-x"), "old")
        fake.failWrites = true
        XCTAssertFalse(pm.setApiKey("new", for: "cred-x"))
        XCTAssertEqual(pm.apiKey(for: "cred-x"), "old", "写失败缓存不改")
        fake.failWrites = false
        fake.failRemoves = true
        XCTAssertFalse(pm.setApiKey("  ", for: "cred-x"), "删失败返回真实结果")
        fake.failRemoves = false
        XCTAssertTrue(pm.setApiKey("", for: "cred-x"))
        XCTAssertNil(pm.apiKey(for: "cred-x"))
    }

    @MainActor
    func testPrimaryHalfWrittenPairingStaysStrict() {
        seedPrimary(token: "t1")
        std.set(CCHubPairingStore.writingMarker, forKey: CCHubPairingStore.fingerprintKey)
        let (r, primary) = makeRegistry()
        r.start { _ in }
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .needsPairing, "本机写到一半：照旧待配对")
        XCTAssertTrue(primary.candidateURLsForTesting.isEmpty)
    }

    func testAuthRejectionDetection() {
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:9/cc")!)
        XCTAssertTrue(CCBridgeWebSocketClient.isAuthRejection(error: "auth", task: task))
        XCTAssertFalse(CCBridgeWebSocketClient.isAuthRejection(error: "closed (1006)", task: task))
        XCTAssertFalse(CCBridgeWebSocketClient.isAuthRejection(error: nil, task: task))
    }

    func testSecondaryHubSecretsReadableAfterFirstUnlockLikePrimary() {
        XCTAssertEqual(KeychainStore.accessibleOverride(account: CCHubRegistry.keychainAccount(for: "abc")), kSecAttrAccessibleAfterFirstUnlock)
        XCTAssertEqual(KeychainStore.accessibleOverride(account: HubTokenStore.keychainAccount), kSecAttrAccessibleAfterFirstUnlock)
        XCTAssertNil(KeychainStore.accessibleOverride(account: "openai"))
    }

    // MARK: - 配对快照：中断只能是旧完整配对或待配对

    func testPairingWriteInterruptedAtEachStepIsOldOrPending() {
        let old = CCHubPairing(primaryURL: "ws://10.1.1.1:7890/cc", backupURL: "ws://100.1.1.1:7890/cc")
        let new = CCHubPairing(primaryURL: "ws://10.2.2.2:7890/cc", relayURL: "wss://r.example.com/cc", relayPin: "p=")
        let account = "acct"
        let steps: [CCHubPairingStore.WriteStep?] = [.secretWritten, .markerWritten, .snapshotWritten, nil]
        for newToken in ["new-token", "old-token"] {
            for step in steps {
                for failSecret in [false, true] where !(failSecret && step != nil) {
                    let d = newSuite()
                    let store = FakeSecrets()
                    XCTAssertTrue(CCHubPairingStore.write(old, token: "old-token", to: d, writeSecret: { store.write($0, account: account) }))
                    store.failWrites = failSecret
                    let finished = CCHubPairingStore.write(new, token: newToken, to: d, writeSecret: { store.write($0, account: account) },
                                                           interrupt: { $0 == step })
                    let now = CCHubPairing.read(d)
                    let verdict = CCHubPairingStore.verify(d, secret: store.read(account: account), allowLegacy: false)
                    let label = "token=\(newToken) step=\(String(describing: step)) failSecret=\(failSecret)"
                    if finished {
                        XCTAssertEqual(now, new, label)
                        XCTAssertEqual(verdict, .ok(newToken), label)
                    } else {
                        let oldComplete = now == old && verdict == .ok("old-token")
                        // 本机写到一半一律是占位（.mismatch）；只有钥匙串写失败（口令没了、快照还原）是 .changed——都待配对
                        let pending = verdict == .mismatch || (failSecret && verdict == .changed(nil))
                        XCTAssertTrue(oldComplete || pending, "只能是旧完整配对或待配对：\(label) now=\(now) verdict=\(verdict)")
                        if !failSecret { XCTAssertEqual(verdict, .mismatch, "中断：\(label)") }
                    }
                    if failSecret { XCTAssertEqual(now, old, "钥匙串写失败：地址不动 \(label)") }
                }
            }
        }
    }

    func testFingerprintIsSha256HexPrefixAndEmptyForNoToken() {
        XCTAssertEqual(CCHubPairingStore.fingerprint("abc"), "ba7816bf8f01cfea")
        XCTAssertEqual(CCHubPairingStore.fingerprint(nil), "")
        XCTAssertEqual(CCHubPairingStore.fingerprint(""), "")
    }

    func testVerifyLockedKeychainDefersToKeepExistingButNotHalfWritten() {
        let d = newSuite()
        let store = FakeSecrets()
        CCHubPairingStore.write(pairing2, token: "t", to: d, writeSecret: { store.write($0, account: "a") })
        XCTAssertEqual(CCHubPairingStore.verify(d, secret: .unreadable, allowLegacy: false), .ok(nil))
        d.set(CCHubPairingStore.writingMarker, forKey: CCHubPairingStore.fingerprintKey)
        XCTAssertEqual(CCHubPairingStore.verify(d, secret: .unreadable, allowLegacy: false), .mismatch)
        // 附加 hub 没有指纹 = 没写完
        d.removeObject(forKey: CCHubPairingStore.fingerprintKey)
        XCTAssertEqual(CCHubPairingStore.verify(d, secret: .value("t"), allowLegacy: false), .mismatch)
        XCTAssertEqual(CCHubPairingStore.verify(d, secret: .value("t"), allowLegacy: true), .ok("t"))
    }

    // MARK: - 指纹不符不连

    @MainActor
    func testFingerprintMismatchOnRelaunchHoldsSecondaryAndDoesNotConnect() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2") else { return XCTFail() }
        XCTAssertFalse(made[id]!.candidateURLsForTesting.isEmpty)

        // 换了口令但快照没跟上（另一个入口直接写了钥匙串）：重启后这台待配对，不连
        secrets.values[CCHubRegistry.keychainAccount(for: id)] = "tampered"
        extraClients.append(contentsOf: made.values)
        made = [:]
        let (r2, _) = makeRegistry()
        r2.start { _ in }
        let client = made[id]!
        XCTAssertEqual(r2.status(for: id), .needsPairing)
        XCTAssertNil(r2.client(for: id))
        XCTAssertTrue(client.isPairingHeld)
        XCTAssertTrue(client.candidateURLsForTesting.isEmpty, "待配对：一个候选都不建")
        client.connect(urls: [URL(string: "ws://192.168.9.2:7890/cc")!], token: nil, keepExistingToken: true)
        XCTAssertTrue(client.candidateURLsForTesting.isEmpty, "钥匙串 / 旧候选自动连的调用点也被挡")

        // 重新配对一次：解除，按新口令连
        XCTAssertEqual(r2.updatePairing(id, pairing2, token: "t9"), .updated)
        XCTAssertEqual(r2.status(for: id), .ready)
        XCTAssertFalse(client.isPairingHeld)
        XCTAssertEqual(tokens(client.candidateURLsForTesting), ["t9"])
    }

    @MainActor
    func testSecretWriteFailureAbortsAddAndLeavesNothing() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        secrets.failWrites = true
        XCTAssertEqual(r.addHub(name: "x", pairing: pairing2, token: "t2"), .secretWriteFailed)
        XCTAssertEqual(r.hubs.map(\.id), [CCHubRegistry.primaryId])
        XCTAssertNil(std.array(forKey: CCHubRegistry.listKey).flatMap { $0.isEmpty ? nil : $0 })
    }

    @MainActor
    func testDuplicateTokenIsRejected() {
        seedPrimary(token: "t1")
        let (r, _) = makeRegistry()
        r.start { _ in }
        XCTAssertEqual(r.addHub(name: "又是主 hub", pairing: pairing2, token: "t1"), .duplicateToken(CCHubRegistry.primaryId))
        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2") else { return XCTFail() }
        XCTAssertEqual(r.addHub(name: "纽约again", pairing: pairing2, token: "t2"), .duplicateToken(id))
    }

    // MARK: - 口令隔离

    @MainActor
    func testSecondaryCandidatesCarryOnlyItsOwnAddressesAndToken() {
        seedPrimary(token: "t1")
        let (r, primary) = makeRegistry()
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2") else { return XCTFail() }
        let secondary = made[id]!
        XCTAssertEqual(Set(secondary.candidateHosts), ["192.168.9.2", "100.64.9.2", "relay-two.example.com"])
        XCTAssertEqual(tokens(secondary.candidateURLsForTesting), ["t2"])
        XCTAssertEqual(tokens(primary.candidateURLsForTesting), ["t1"])
        XCTAssertFalse(secondary.candidateURLsForTesting.contains { $0.absoluteString.contains("t1") })
        XCTAssertEqual(secondary.defaults.string(forKey: CCBridgeEndpoints.overrideKey), "ws://192.168.9.2:7890/cc")

        // 附加 hub 什么地址都没配：不补本机默认地址
        guard case .added(let empty) = r.addHub(name: "空", pairing: CCHubPairing(), token: "t3") else { return XCTFail() }
        XCTAssertTrue(made[empty]!.candidateURLsForTesting.isEmpty)
    }

    func testKeepExistingTokenOnlyOnExactSameCandidatesAndGen() {
        let a = URL(string: "ws://10.0.0.1:7890/cc")!, b = URL(string: "ws://100.64.0.1:7890/cc")!, c = URL(string: "ws://10.9.9.9:7890/cc")!
        let existing = CCBridgeWebSocketClient.candidateURLs([a, b], token: "t1", keepingTokenFrom: [])
        // 部分重合：不沿用
        XCTAssertEqual(tokens(CCBridgeWebSocketClient.candidateURLs([a, c], token: nil, keepingTokenFrom: existing)), [nil])
        // 集合相同（顺序不同）：沿用
        XCTAssertEqual(tokens(CCBridgeWebSocketClient.candidateURLs([b, a], token: nil, keepingTokenFrom: existing)), ["t1"])

        let d = newSuite()
        let client = newClient(hubId: "h-keep", defaults: d)
        client.connect(urls: [a, b], token: "t1")
        // 读不到口令 + 候选部分重合：这次不连，也不把带口令的候选换成不带口令的
        client.connect(urls: [a, c], token: nil, keepExistingToken: true)
        XCTAssertEqual(client.candidateURLsForTesting.map(\.host), ["10.0.0.1", "100.64.0.1"])
        XCTAssertEqual(tokens(client.candidateURLsForTesting), ["t1"])
        // 同一代、同一组候选：沿用（换了顺序可以看出来确实按新列表重建了）
        client.connect(urls: [b, a], token: nil, keepExistingToken: true)
        XCTAssertEqual(client.candidateURLsForTesting.map(\.host), ["100.64.0.1", "10.0.0.1"])
        XCTAssertEqual(tokens(client.candidateURLsForTesting), ["t1"])
        // 换过一代配对：同一组候选也不沿用
        d.set(CCHubPairingStore.gen(d) + 1, forKey: CCHubPairingStore.genKey)
        client.connect(urls: [a, b], token: nil, keepExistingToken: true)
        XCTAssertEqual(client.candidateURLsForTesting.map(\.host), ["100.64.0.1", "10.0.0.1"], "没沿用 = 没重建")
    }

    func testSameAddressNewTokenRetargetsInsteadOfKeepingLiveSocket() {
        // 测试宿主挡住了真正开新 socket，看「有没有换目标」：换目标会把手上那份 hello 降成「上次的」
        let a = URL(string: "ws://127.0.0.1:9/cc")!
        let client = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: newSuite())
        wired(client)
        client.connect(urls: [a], token: "old")
        let task = session.webSocketTask(with: a)
        client.adoptTaskForTesting(task, url: CCBridgeWebSocketClient.candidateURLs([a], token: "old", keepingTokenFrom: [])[0])
        client.handleIncoming(text(["type": "hello", "host_name": "mac"]))
        XCTAssertTrue(spin { client.hubInfoIsCurrent })
        client.connect(urls: [a], token: "old")
        settle()
        XCTAssertTrue(client.hubInfoIsCurrent, "同地址同口令：不掐活连接")
        XCTAssertTrue(client.currentTaskForTesting === task)
        client.connect(urls: [a], token: "new")
        XCTAssertTrue(spin { !client.hubInfoIsCurrent }, "同地址换口令：重新握手，不接着用旧连接")
        XCTAssertEqual(tokens(client.candidateURLsForTesting), ["new"])
    }

    func testRelayJudgeAndPinReadPerInstanceDefaults() {
        let d1 = newSuite(), d2 = newSuite()
        CCBridgeEndpoints.save(CCPairPayload.parse(#"{"mpcc":1,"u":null,"u3":"wss://relay-one.example.com:8443/cc","p3":"pin-one=","t":"t"}"#)!, defaults: d1)
        CCBridgeEndpoints.save(CCPairPayload.parse(#"{"mpcc":1,"u":null,"u3":"wss://relay-two.example.com/cc","p3":"pin-two=","t":"t"}"#)!, defaults: d2)
        let c1 = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: d1)
        let c2 = newClient(hubId: "h2", defaults: d2)
        XCTAssertEqual(CCBridgeEndpoints.relayPin(host: "relay-one.example.com", port: 8443, defaults: c1.defaults), "pin-one=")
        XCTAssertNil(CCBridgeEndpoints.relayPin(host: "relay-one.example.com", port: 8443, defaults: c2.defaults))
        XCTAssertEqual(CCBridgeEndpoints.relayPin(host: "relay-two.example.com", port: 443, defaults: c2.defaults), "pin-two=")
        XCTAssertNil(CCBridgeEndpoints.relayPin(host: "relay-two.example.com", port: 443, defaults: c1.defaults))
        XCTAssertEqual(CCBridgeEndpoints.relayURL(defaults: c2.defaults)?.host, "relay-two.example.com")
    }

    func testPolicyTablesReadAndWritePerHub() {
        let d = newSuite()
        let c = newClient(hubId: "h-pol", defaults: d)
        wired(c)
        CCBridgeWebSocketClient.setKeepalivePolicy("always", for: "mp-cc", hub: c)
        XCTAssertEqual(CCBridgeWebSocketClient.keepalivePolicy(for: "mp-cc", hub: c), "always")
        XCTAssertEqual((d.dictionary(forKey: CCBridgeWebSocketClient.keepalivePolicyKey) as? [String: String])?["mp-cc"], "always")
        CCBridgeWebSocketClient.setTransportPolicy("stream", for: "mp-cc", hub: c)
        XCTAssertEqual(CCBridgeWebSocketClient.transportPolicy(for: "mp-cc", hub: c), "stream")
        // hub 推来的整表只写那台自己的 suite
        c.handleIncoming(text(["type": "transport_policies", "policies": ["x": "tmux"]]))
        XCTAssertTrue(spin { CCBridgeWebSocketClient.transportPolicy(for: "x", hub: c) == "tmux" })
        XCTAssertEqual(CCBridgeWebSocketClient.transportPolicy(for: "mp-cc", hub: c), "")
    }

    // MARK: - invalidate

    func testInvalidateMakesOldReferenceInertAndDropsLateWrites() {
        for a1 in [true, false] {
            let d = newSuite()
            let client = newClient(hubId: "h-inv-\(a1)", defaults: d, a1: a1)
            let wire = Wire()
            wire.install(on: client)
            open(client)
            var delivered = 0
            client.onProactiveMessage = { _, _, _, _, _, _, _, _, _ in delivered += 1; return true }

            // 删的时候有帧在排队
            let release = client.holdHandlersForTesting()
            client.handleIncoming(text(["type": "thinking", "chat_id": "C", "mp_msg_id": "m", "content": "x", "thinking_id": "th1", "ts": 5_000_000]))
            client.handleIncoming(text(["type": "reply", "chat_id": "C", "content": "late", "reply_id": "r1", "ts": 6_000_000]))
            var done = false
            client.invalidate { _ in done = true }
            release()
            XCTAssertTrue(spin { done })
            client.drainPipelinesForTesting()
            settle()

            XCTAssertTrue(client.isInvalidated)
            XCTAssertEqual(delivered, 0, "迟到 reply 不回调")
            XCTAssertNil(d.object(forKey: "ccSeenThinkingIds"), "迟到帧不把去重写回已删 hub 的 suite")
            XCTAssertNil(d.object(forKey: "ccSeenReplyIds"))
            XCTAssertNil(d.object(forKey: "ccReplyCursorTs"))
            XCTAssertNil(client.onProactiveMessage)
            XCTAssertTrue(client.candidateURLsForTesting.isEmpty, "含口令的候选清掉")
            XCTAssertFalse(client.isConnected)

            // 拿着旧引用：重连 / 连接 / 发送 / 重发 / 粘贴全部无效
            client.reconnectNow()
            client.connect(urls: [URL(string: "ws://127.0.0.1:9/cc")!], token: "t")
            XCTAssertTrue(client.candidateURLsForTesting.isEmpty)
            client.sendUserMessage(chatId: "C", messageId: "m1", content: "hi", user: "u", session: nil, replyTo: nil, attachments: [])
            client.retrySend(messageId: "m1")
            var pasteResult: String?
            client.sendTerminalPaste(session: "mp-cc", text: "x") { pasteResult = $0 }
            XCTAssertTrue(spin { pasteResult != nil })
            client.handleIncoming(text(["type": "reply", "chat_id": "C", "content": "after", "reply_id": "r2", "ts": 7_000_000]))
            settle()
            XCTAssertTrue(wire.sent("send").isEmpty)
            XCTAssertTrue(wire.sent("terminal_paste").isEmpty)
            XCTAssertNil(d.object(forKey: "ccSeenReplyIds"))
        }
    }

    // MARK: - 推送 token

    @MainActor
    func testPushTokenSeededBroadcastAndUnregisteredOnRemove() {
        let (r, primary) = makeRegistry()
        r.start { _ in }
        guard case .added(let a) = r.addHub(name: "A", pairing: pairing2, token: "ta") else { return XCTFail() }
        r.setPushToken("tok1")
        XCTAssertEqual(primary.pushTokenForTesting, "tok1")
        XCTAssertEqual(made[a]!.pushTokenForTesting, "tok1")
        guard case .added(let b) = r.addHub(name: "B", pairing: CCHubPairing(primaryURL: "ws://192.168.7.7:7890/cc"), token: "tb") else { return XCTFail() }
        XCTAssertEqual(made[b]!.pushTokenForTesting, "tok1", "新 client 建好就补种")

        // 连着删（身份核准过）：先发注销帧，再删 suite + 钥匙串
        let taskB = open(made[b]!)
        made[b]!.handleIncoming(text(["type": "hello", "hub_id": "HUB-B"]), source: taskB)
        XCTAssertTrue(spin { self.made[b]!.identityVerifiedForTesting })
        r.remove(b)
        XCTAssertNil(r.client(for: b))
        XCTAssertTrue(spin { self.secrets.values[CCHubRegistry.keychainAccount(for: b)] == nil })
        XCTAssertEqual(wires[b]!.sent("unregister_push_token").map { $0["token"] as? String }, ["tok1"])
        XCTAssertTrue(made[b]!.isInvalidated)
        XCTAssertNil(UserDefaults(suiteName: prefix + b)!.string(forKey: CCBridgeEndpoints.overrideKey))
        XCTAssertNil(std.stringArray(forKey: CCHubRegistry.pendingCleanupKey))

        // 没连着删（记下过 hub_id）：记「待注销」；以后同一台连上先注销旧 token
        made[a]!.handleIncoming(text(["type": "hello", "hub_id": "HUB-A"]))
        XCTAssertTrue(spin { r.defaults(for: a)?.string(forKey: CCHubPairingStore.hubIdentityKey) == "HUB-A" })
        r.remove(a)
        XCTAssertTrue(spin { self.secrets.values[CCHubRegistry.keychainAccount(for: a)] == nil })
        XCTAssertTrue(wires[a]!.sent("unregister_push_token").isEmpty)
        XCTAssertEqual(std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]], [["hub": "HUB-A", "token": "tok1"]])

        r.setPushToken("tok2")
        guard case .added(let c) = r.addHub(name: "C", pairing: CCHubPairing(primaryURL: "ws://192.168.8.8:7890/cc"), token: "tc") else { return XCTFail() }
        let task = open(made[c]!)
        made[c]!.handleIncoming(text(["type": "hello", "hub_id": "HUB-A"]), source: task)
        XCTAssertTrue(spin { self.wires[c]!.sent("unregister_push_token").count == 1 })
        XCTAssertEqual(wires[c]!.sent("unregister_push_token").first?["token"] as? String, "tok1")
        XCTAssertTrue(spin { ((self.std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]]) ?? []).isEmpty }, "发成了才销")
    }

    @MainActor
    func testPendingUnregisterOfCurrentTokenIsDroppedNotSent() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        r.setPushToken("tok1")
        guard case .added(let a) = r.addHub(name: "A", pairing: pairing2, token: "ta") else { return XCTFail() }
        made[a]!.handleIncoming(text(["type": "hello", "hub_id": "HUB-A"]))
        XCTAssertTrue(spin { r.defaults(for: a)?.string(forKey: CCHubPairingStore.hubIdentityKey) == "HUB-A" })
        r.remove(a)
        XCTAssertTrue(spin { (self.std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]])?.count == 1 })
        // 同一台又加回来、token 没变：要推送，不注销
        guard case .added(let again) = r.addHub(name: "A again", pairing: pairing2, token: "ta2") else { return XCTFail() }
        let task = open(made[again]!)
        made[again]!.handleIncoming(text(["type": "hello", "hub_id": "HUB-A"]), source: task)
        XCTAssertTrue(spin { ((self.std.array(forKey: CCHubRegistry.pendingUnregisterKey) as? [[String: String]]) ?? []).isEmpty })
        settle()
        XCTAssertTrue(wires[again]!.sent("unregister_push_token").isEmpty)
    }

    // MARK: - hub_id

    @MainActor
    func testHubIdentityChangeStopsThatHub() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2") else { return XCTFail() }
        let client = made[id]!
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-X", "host_name": "ny"]))
        XCTAssertTrue(spin { r.defaults(for: id)?.string(forKey: CCHubPairingStore.hubIdentityKey) == "HUB-X" })
        XCTAssertEqual(r.status(for: id), .ready)
        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-X"]))
        settle()
        XCTAssertEqual(r.status(for: id), .ready, "同一台：照常")

        client.handleIncoming(text(["type": "hello", "hub_id": "HUB-Y"]))
        XCTAssertTrue(spin { r.status(for: id) == .identityChanged })
        XCTAssertNil(r.client(for: id))
        XCTAssertTrue(client.isPairingHeld)
        XCTAssertEqual(r.defaults(for: id)?.string(forKey: CCHubPairingStore.hubIdentityKey), "HUB-X", "记下的不被顶掉")
        XCTAssertNotNil(r.hubs.first { $0.id == id })
    }

    func testHelloParsesOptionalHubId() {
        XCTAssertEqual(HubHello(frame: ["type": "hello", "hub_id": " abc "])?.hubId, "abc")
        XCTAssertNil(HubHello(frame: ["type": "hello"])?.hubId)
    }

    @MainActor
    func testPrimaryNameDefaultsAndRename() {
        let (r, primary) = makeRegistry()
        XCTAssertEqual(r.primaryName, "我的电脑")
        primary.handleIncoming(text(["type": "hello", "host_name": "粟粟的 MacBook", "host_model_name": "MacBook Air"]))
        XCTAssertTrue(spin { r.primaryName == "MacBook Air" })
        r.rename(CCHubRegistry.primaryId, to: "家里")
        XCTAssertEqual(r.primaryName, "家里")
        XCTAssertEqual(std.string(forKey: CCHubRegistry.primaryNameKey), "家里")
    }

    @MainActor
    func testHubListPersistsAcrossRelaunch() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let id) = r.addHub(name: "纽约", pairing: pairing2, token: "t2") else { return XCTFail() }
        r.rename(id, to: "纽约 VPS")
        extraClients.append(contentsOf: made.values)
        made = [:]
        let (r2, _) = makeRegistry()
        var bound: [String] = []
        r2.start { bound.append($0.hubId) }
        XCTAssertEqual(r2.hubs.map(\.name), ["我的电脑", "纽约 VPS"])
        XCTAssertEqual(Set(bound), [CCHubRegistry.primaryId, id], "每台 client 都接对话回调")
        XCTAssertEqual(tokens(made[id]!.candidateURLsForTesting), ["t2"])
    }

    // MARK: - 附加 hub 的最小帧闸 + 连上接线

    func testSecondaryGateClassification() {
        for t in ["pocket_cmd", "twitter_cmd"] { XCTAssertEqual(CCBridgeWebSocketClient.secondaryFrameGate(t), .reject, t) }
        for t in ["voice_call_snapshot", "voice_call_state", "voice_call_error", "cc_memory_manifest", "cc_memory_files", "cc_memory_changed"] {
            XCTAssertEqual(CCBridgeWebSocketClient.secondaryFrameGate(t), .drop, t)
        }
        for t in ["reply", "thinking", "hello", "terminal_state", "ack"] { XCTAssertEqual(CCBridgeWebSocketClient.secondaryFrameGate(t), .pass, t) }
    }

    func testSecondaryRejectsPocketAndTwitterBeforeAnyHandler() {
        let client = newClient(hubId: "h-gate", defaults: newSuite())
        let wire = Wire()
        wire.install(on: client)
        let task = open(client)
        var pocketRan = false, twitterRan = false
        client.pocketEnabledForTesting = true   // 闸在 pocketEnabled 判断之前：开着也拒
        client.pocketRunnerForTesting = { _, _ in pocketRan = true }
        client.onTwitterCmd = { _ in twitterRan = true; return [:] }
        client.handleIncoming(text(["type": "pocket_cmd", "id": "p1", "op": "eval"]), source: task)
        client.handleIncoming(text(["type": "twitter_cmd", "id": "t1"]), source: task)
        XCTAssertTrue(spin { wire.sent("pocket_result").count == 1 && wire.sent("twitter_result").count == 1 })
        settle()
        XCTAssertFalse(pocketRan)
        XCTAssertFalse(twitterRan)
        XCTAssertEqual(wire.sent("pocket_result").first?["ok"] as? Bool, false)
        XCTAssertEqual(wire.sent("pocket_result").first?["id"] as? String, "p1")
        XCTAssertEqual(wire.sent("twitter_result").first?["ok"] as? Bool, false)
        XCTAssertEqual(wire.sent("twitter_result").first?["id"] as? String, "t1")

        // 对照：主 hub 照旧执行
        let primary = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: newSuite())
        wired(primary)
        let ptask = open(primary)
        var primaryPocket = false
        primary.pocketEnabledForTesting = true
        primary.pocketRunnerForTesting = { _, reply in primaryPocket = true; reply(["type": "pocket_result", "id": "p2", "ok": true]) }
        primary.handleIncoming(text(["type": "pocket_cmd", "id": "p2"]), source: ptask)
        XCTAssertTrue(spin { primaryPocket })
    }

    func testSecondaryOpenSkipsPrimaryOnlyHooksOnBothPaths() {
        for a1 in [true, false] {
            let secondary = newClient(hubId: "h-open-\(a1)", defaults: newSuite(), a1: a1)
            let wire = Wire()
            wire.install(on: secondary)
            open(secondary)
            settle()
            XCTAssertEqual(secondary.primaryOnlyOpenHooksForTesting, 0, "A1=\(a1)：附加 hub 不调 LA / 通话 / CC 记忆 / 绑定开关")
            XCTAssertTrue(wire.sent("set_bind").isEmpty)
            XCTAssertEqual(wire.sent("set_cc_config").count, 1, "CC 设置每台都发")

            let primary = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: newSuite(), a1: a1)
            wired(primary)
            open(primary)
            XCTAssertTrue(spin { primary.primaryOnlyOpenHooksForTesting == 2 }, "A1=\(a1)：主 hub 照旧")
        }
    }

    // MARK: - R4 返工

    final class Counter { var n = 0 }

    private func countingProbe(_ outcome: CCHubRegistry.ProbeOutcome, _ counter: Counter) -> CCHubRegistry.PairingProbe {
        { _, _ in
            counter.n += 1
            return outcome
        }
    }

    /// b4 #1：主电脑配过对后，扫码（CCPairingApply，所有扫码入口共用）/ 手填改配对内容一律先认是哪台：
    /// 别的电脑 / 认不出 / 连不上 → 交给落点，原配对一个字节不动；认出就是主电脑才写；不改内容的重连不握手认
    @MainActor
    func testPrimaryEntriesClassifyBeforeWriting() async {
        seedPrimary(token: "t1")
        std.set("HUB-P", forKey: CCHubPairingStore.hubIdentityKey)
        let (r, _) = makeRegistry()
        r.start { _ in }
        let before = primarySnapshot
        let counter = Counter()
        let scan = CCPairPayload.parse(#"{"mpcc":1,"u":"ws://10.0.0.30:7890/cc","t":"t-other"}"#)!
        for outcome in [CCHubRegistry.ProbeOutcome.hello(hubId: "HUB-OTHER"), .hello(hubId: nil), .failed("连不上")] {
            let result = await CCPairingApply.apply(scan, providerManager: nil, registry: r, probe: countingProbe(outcome, counter))
            guard case .confirm(let check) = result else { return XCTFail("\(outcome) 应交给落点：\(result)") }
            XCTAssertEqual(check.pairing, CCHubPairing(payload: scan))
            XCTAssertEqual(primarySnapshot, before, "分类前不写地址")
            XCTAssertEqual(secrets.values[Self.localPrimary], "t1", "分类前不写口令")
            XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready)
        }
        XCTAssertEqual(counter.n, 3)

        let manual = await r.applyPrimaryManual(primary: "ws://10.0.0.30:7890/cc", backup: "", token: "t-other", providerManager: nil,
                                                reconnect: true, probe: countingProbe(.hello(hubId: "HUB-OTHER"), counter))
        guard case .confirm = manual else { return XCTFail("手填改了内容也先认") }
        XCTAssertEqual(primarySnapshot, before)

        let same = await r.applyPrimaryManual(primary: a1URL, backup: b1URL, token: "t1", providerManager: nil, reconnect: true,
                                              probe: countingProbe(.failed("x"), counter))
        XCTAssertEqual(same, .applied)
        XCTAssertEqual(counter.n, 4, "没改内容的重连照旧，不握手认")

        let mine = await CCPairingApply.apply(scan, providerManager: nil, registry: r, probe: countingProbe(.hello(hubId: "HUB-P"), counter))
        guard case .done(let line) = mine else { return XCTFail() }
        XCTAssertTrue(line.hasPrefix("已配对"), line)
        XCTAssertEqual(std.string(forKey: CCBridgeEndpoints.overrideKey), "ws://10.0.0.30:7890/cc")
        XCTAssertEqual(secrets.values[Self.localPrimary], "t-other")
    }

    /// b4 #1：主电脑从没配过对 → 照原样直接写，不多一步
    @MainActor
    func testFirstPrimaryPairingWritesWithoutProbe() async {
        let (r, _) = makeRegistry()
        r.start { _ in }
        XCTAssertTrue(r.primaryNeverPaired)
        let counter = Counter()
        let scan = CCPairPayload.parse(#"{"mpcc":1,"u":"ws://10.0.0.31:7890/cc","t":"t-first"}"#)!
        let result = await CCPairingApply.apply(scan, providerManager: nil, registry: r, probe: countingProbe(.failed("x"), counter))
        guard case .done(let line) = result else { return XCTFail() }
        XCTAssertTrue(line.hasPrefix("已配对"), line)
        XCTAssertEqual(counter.n, 0)
        XCTAssertEqual(std.string(forKey: CCBridgeEndpoints.overrideKey), "ws://10.0.0.31:7890/cc")
        XCTAssertFalse(r.primaryNeverPaired)
    }

    /// B7.2 B4：口令被拒（1008 auth）按 2 秒起翻倍退避，握手成功不清；换了目标才清
    @MainActor
    func testAuthRejectionBacksOffAndHandshakeDoesNotReset() {
        let client = newClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: newSuite())
        let t1 = open(client)
        client.urlSession(session, webSocketTask: t1, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        XCTAssertTrue(spin { client.authRejectDelayForTesting == 2 })
        let t2 = open(client)
        XCTAssertEqual(client.authRejectDelayForTesting, 2, "被拒的连接握手成功不清")
        client.urlSession(session, webSocketTask: t2, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        XCTAssertTrue(spin { client.authRejectDelayForTesting == 4 })
        let t3 = open(client)
        client.urlSession(session, webSocketTask: t3, didCloseWith: .abnormalClosure, reason: nil)
        settle()
        XCTAssertEqual(client.authRejectDelayForTesting, 4, "开了就断（没连满 5 秒）也不清")
        client.connect(urls: [URL(string: "ws://10.0.0.5:7890/cc")!], token: "new")
        XCTAssertEqual(client.authRejectDelayForTesting, 0, "换了目标 / 口令重新来")
    }

    /// B7.2 B4（bug0）：没配过对的主 hub 回落本机、口令空被拒——收帧失败先到、1008 auth 的 didClose 后到，照样认成被拒、停住
    @MainActor
    func testLateAuthCloseAfterDropStillHoldsUnpairedPrimary() {
        let (r, primary) = makeRegistry()
        r.start { _ in }
        let task = open(primary, url: "ws://127.0.0.1:7890/cc")
        primary.urlSession(session, webSocketTask: task, didCloseWith: .abnormalClosure, reason: nil)
        XCTAssertTrue(spin { primary.currentTaskForTesting == nil })
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready)
        primary.urlSession(session, webSocketTask: task, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        XCTAssertTrue(spin { r.status(for: CCHubRegistry.primaryId) == .needsPairing }, "晚到的 1008 也停住，不再 0.25 秒一次")
        XCTAssertTrue(primary.isPairingHeld)
        XCTAssertEqual(primary.authRejectDelayForTesting, 2)
    }

    /// R5.4：迟到的 1008 只算原连接那一代——之后新连接开着了 / 换了目标，旧拒绝不改状态
    @MainActor
    func testLateAuthCloseIgnoredAfterNewConnectionOrRetarget() {
        let (r, primary) = makeRegistry()
        r.start { _ in }
        let first = open(primary, url: "ws://127.0.0.1:7890/cc")
        primary.urlSession(session, webSocketTask: first, didCloseWith: .abnormalClosure, reason: nil)
        XCTAssertTrue(spin { primary.currentTaskForTesting == nil })
        let second = open(primary, url: "ws://127.0.0.1:7890/cc")
        primary.urlSession(session, webSocketTask: first, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        settle()
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready, "新连接开着：旧连接迟到的拒绝不算")
        XCTAssertEqual(primary.authRejectDelayForTesting, 0)

        primary.urlSession(session, webSocketTask: second, didCloseWith: .abnormalClosure, reason: nil)
        XCTAssertTrue(spin { primary.currentTaskForTesting == nil })
        primary.connect(urls: [URL(string: "ws://10.0.0.40:7890/cc")!], token: "new")
        primary.urlSession(session, webSocketTask: second, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        settle()
        XCTAssertEqual(r.status(for: CCHubRegistry.primaryId), .ready, "换了目标：旧拒绝不算")
        XCTAssertEqual(primary.authRejectDelayForTesting, 0)
    }

    /// B7.2 B4：主 hub 本机副本在、指纹没存（老用户）被拒：按本机副本的口令认，停住
    @MainActor
    func testRejectedPrimaryWithoutStoredFingerprintHolds() {
        seedPrimary(token: "t1")
        secrets.values[Self.localPrimary] = "t1"
        let (r, primary) = makeRegistry()
        r.start { _ in }
        XCTAssertNil(std.string(forKey: CCHubPairingStore.fingerprintKey))
        let task = open(primary, url: "ws://127.0.0.1:9/cc?token=t1")
        primary.urlSession(session, webSocketTask: task, didCloseWith: .policyViolation, reason: Data("auth".utf8))
        XCTAssertTrue(spin { r.status(for: CCHubRegistry.primaryId) == .needsPairing })
        XCTAssertEqual(std.string(forKey: CCHubPairingStore.rejectedFingerprintKey), CCHubPairingStore.fingerprint("t1"))
    }

    /// b4 #11：删掉的电脑名字只留还有对话连着的
    @MainActor
    func testRemovedNamesPrunedToReferencedHubs() {
        let (r, _) = makeRegistry()
        r.start { _ in }
        guard case .added(let a) = r.addHub(name: "纽约", pairing: CCHubPairing(primaryURL: "ws://10.0.0.21:7890/cc"), token: "ta"),
              case .added(let b) = r.addHub(name: "东京", pairing: CCHubPairing(primaryURL: "ws://10.0.0.22:7890/cc"), token: "tb") else {
            return XCTFail()
        }
        r.remove(a)
        r.remove(b)
        XCTAssertEqual(r.removedName(of: a), "纽约")
        r.pruneRemovedNames(referenced: [b, CCHubRegistry.primaryId])
        XCTAssertNil(r.removedName(of: a))
        XCTAssertEqual(r.removedName(of: b), "东京")
        let (r2, _) = makeRegistry()
        XCTAssertEqual(r2.removedNames, [b: "东京"], "落盘")
    }
}
