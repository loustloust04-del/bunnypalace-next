import XCTest
@testable import 记忆花园

/// API 卡草稿保活（plan-api-draft-and-fix-jump §5-1）。偏好走独立 suite；钥匙串走测试宿主隔离（TestHostIsolation 给 service 加后缀）
final class APIDraftStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "api-draft-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        APIDraftStore.clear(defaults: defaults)
    }

    private var draftSecrets: [String] { KeychainStore.allAccounts(service: APIDraftStore.keychainService) }

    override func tearDown() {
        APIDraftStore.writeSecret = { KeychainStore.set($0, account: $1, sync: false, service: APIDraftStore.keychainService) }
        APIDraftStore.clear(defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func sample(slot: String = APIDraft.newSlot) -> APIDraft {
        APIDraft(slot: slot, emoji: "🦊", nickname: "中转", presetSelection: "_custom_", customBaseURL: "https://relay.example.com/v1",
                 customType: ProviderType.anthropic.rawValue, toolsSupported: false,
                 models: [.init(modelId: "m-1", name: "M 1")])
    }

    func testRoundTripWithKey() throws {
        let now = Date()
        APIDraftStore.save(sample(), key: "sk-test-roundtrip", defaults: defaults, now: now)
        let loaded = try XCTUnwrap(APIDraftStore.load(slot: APIDraft.newSlot, defaults: defaults, now: now.addingTimeInterval(60)))
        XCTAssertEqual(loaded.key, "sk-test-roundtrip")
        XCTAssertTrue(loaded.draft.keyStored)
        XCTAssertEqual(loaded.draft.nickname, "中转")
        XCTAssertEqual(loaded.draft.customType, ProviderType.anthropic.rawValue)
        XCTAssertEqual(loaded.draft.models, [.init(modelId: "m-1", name: "M 1")])
        XCTAssertFalse(loaded.draft.toolsSupported)
    }

    func testNilKeyMeansUseSavedCardKey() throws {
        APIDraftStore.save(sample(), key: "sk-test-old", defaults: defaults)
        APIDraftStore.save(sample(slot: "cred-1"), key: nil, defaults: defaults)
        let loaded = try XCTUnwrap(APIDraftStore.load(slot: "cred-1", defaults: defaults))
        XCTAssertNil(loaded.key)
        XCTAssertFalse(loaded.draft.keyStored)
        XCTAssertTrue(draftSecrets.isEmpty, "上一份草稿的 key 不留")
    }

    func testClearedKeyRestoresAsEmpty() throws {
        APIDraftStore.save(sample(slot: "cred-1"), key: "", defaults: defaults)
        let loaded = try XCTUnwrap(APIDraftStore.load(slot: "cred-1", defaults: defaults))
        XCTAssertEqual(loaded.key, "", "她把 key 清空了：恢复成空，不回退成卡上的")
    }

    func testSlotMismatchReturnsNilAndKeepsDraft() {
        APIDraftStore.save(sample(slot: "cred-a"), key: "sk-test-a", defaults: defaults)
        XCTAssertNil(APIDraftStore.load(slot: "cred-b", defaults: defaults))
        XCTAssertNil(APIDraftStore.load(slot: APIDraft.newSlot, defaults: defaults))
        APIDraftStore.clear(slot: "cred-b", defaults: defaults)
        XCTAssertNotNil(APIDraftStore.load(slot: "cred-a", defaults: defaults), "别的卡不删不属于它的草稿")
        APIDraftStore.clear(slot: "cred-a", defaults: defaults)
        XCTAssertNil(APIDraftStore.load(slot: "cred-a", defaults: defaults))
    }

    func testExpiredReturnsNilAndClears() {
        let now = Date()
        APIDraftStore.save(sample(), key: "sk-test-old", defaults: defaults, now: now)
        XCTAssertNil(APIDraftStore.load(slot: APIDraft.newSlot, defaults: defaults, now: now.addingTimeInterval(APIDraftStore.ttl + 1)))
        XCTAssertNil(defaults.data(forKey: APIDraftStore.defaultsKey))
        XCTAssertTrue(draftSecrets.isEmpty)
    }

    func testClearEmptiesDefaultsAndKeychain() {
        APIDraftStore.save(sample(), key: "sk-test-clear", defaults: defaults)
        APIDraftStore.clear(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: APIDraftStore.defaultsKey))
        XCTAssertTrue(draftSecrets.isEmpty)
    }

    func testDefaultsJSONHasNoKey() throws {
        APIDraftStore.save(sample(), key: "sk-test-SECRET-9f2c", defaults: defaults)
        let data = try XCTUnwrap(defaults.data(forKey: APIDraftStore.defaultsKey))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("SECRET-9f2c"), json)
    }

    func testDraftKeyNotInCardKeyService() {
        APIDraftStore.save(sample(), key: "sk-test-isolated", defaults: defaults)
        XCTAssertFalse(KeychainStore.getAll().keys.contains { $0.hasPrefix(APIDraftStore.accountPrefix) }, "草稿 key 不能被卡 key 预热当成一张卡")
        XCTAssertFalse(KeychainStore.getAll().values.contains { $0.contains("sk-test-isolated") })
        XCTAssertEqual(KeychainStore.getAll(service: APIDraftStore.keychainService).count, 1)
        XCTAssertTrue(KeychainStore.getAll(service: APIDraftStore.keychainService).values.first?.contains("sk-test-isolated") == true)
    }

    func testPendingResumeOnlyOnceAndSkipsOnboarding() throws {
        APIDraftStore.save(sample(slot: APIDraft.onboardingSlot), key: nil, defaults: defaults)
        XCTAssertNil(APIDraftStore.takePendingResume(defaults: defaults), "引导草稿由引导自己接，不自动开设置")
        APIDraftStore.save(sample(slot: "cred-1"), key: nil, defaults: defaults)
        XCTAssertEqual(APIDraftStore.takePendingResume(defaults: defaults)?.slot, "cred-1")
        XCTAssertNil(APIDraftStore.takePendingResume(defaults: defaults), "只自动弹一次")
        XCTAssertNotNil(APIDraftStore.load(slot: "cred-1", defaults: defaults), "弹过草稿还在，她自己点进来照样带回")
        APIDraftStore.save(sample(slot: "cred-1"), key: nil, defaults: defaults)
        XCTAssertNotNil(APIDraftStore.takePendingResume(defaults: defaults), "再切一次后台 = 新草稿，又能弹一次")
    }

    // MARK: astra #1：元数据和 key 不串版本

    func testFailedKeyWriteKeepsPreviousDraftIntact() throws {
        APIDraftStore.save(sample(slot: "cred-a"), key: "sk-test-A", defaults: defaults)
        APIDraftStore.writeSecret = { _, _ in false }
        XCTAssertFalse(APIDraftStore.save(sample(slot: "cred-b"), key: "sk-test-B", defaults: defaults), "钥匙串写失败 → 不发布元数据")
        let loaded = try XCTUnwrap(APIDraftStore.load(slot: "cred-a", defaults: defaults))
        XCTAssertEqual(loaded.key, "sk-test-A")
        XCTAssertNil(APIDraftStore.load(slot: "cred-b", defaults: defaults))
    }

    func testKilledAfterKeyWriteBeforePublishNeverLeaksIntoOtherCard() throws {
        APIDraftStore.save(sample(slot: "cred-a"), key: "sk-test-A", defaults: defaults)
        // B 的 key 已经写进钥匙串（新 account），元数据还没发布就被杀
        XCTAssertTrue(APIDraftStore.writeSecret(#"{"key":"sk-test-B"}"#, APIDraftStore.accountPrefix + "orphan"))
        XCTAssertEqual(try XCTUnwrap(APIDraftStore.load(slot: "cred-a", defaults: defaults)).key, "sk-test-A", "A 页绝不带出 B 的 key")
        XCTAssertEqual(draftSecrets.count, 2)
        APIDraftStore.save(sample(slot: "cred-c"), key: "sk-test-C", defaults: defaults)
        XCTAssertEqual(draftSecrets.count, 1, "下一次成功保存顺手收掉孤儿")
    }

    func testMissingSecretInvalidatesDraft() {
        APIDraftStore.save(sample(slot: "cred-a"), key: "sk-test-A", defaults: defaults)
        for account in draftSecrets { KeychainStore.remove(account: account, service: APIDraftStore.keychainService) }
        XCTAssertNil(APIDraftStore.load(slot: "cred-a", defaults: defaults), "读不到这一版的 key → 整份作废，不恢复成空 key")
        XCTAssertNil(defaults.data(forKey: APIDraftStore.defaultsKey))
    }

    // MARK: astra #2：带凭据的地址不进偏好

    func testSafeURLDetection() {
        XCTAssertTrue(APIDraftStore.isSafeBaseURL(""))
        XCTAssertTrue(APIDraftStore.isSafeBaseURL("https://relay.example.com/v1"))
        XCTAssertTrue(APIDraftStore.isSafeBaseURL("http://localhost:11434/v1"))
        XCTAssertFalse(APIDraftStore.isSafeBaseURL("https://relay.example.com/v1?key=abc"))
        XCTAssertFalse(APIDraftStore.isSafeBaseURL("https://user:pw@relay.example.com/v1"))
        XCTAssertFalse(APIDraftStore.isSafeBaseURL("https://relay.example.com/v1#tok"))
        XCTAssertFalse(APIDraftStore.isSafeBaseURL("https://relay.example.com/sk-abcdef/v1"))
        XCTAssertFalse(APIDraftStore.isSafeBaseURL("https://relay.example.com/AbCdEf0123456789AbCdEf0123/v1"), "像 key 的长路径段")
        XCTAssertFalse(APIDraftStore.isSafeBaseURL("relay.example.com/v1?token=1"), "解析不了也当敏感")
    }

    func testSensitiveURLStoredInKeychainOnly() throws {
        for slot in ["cred-a", APIDraft.onboardingSlot] {
            var d = sample(slot: slot)
            d.customBaseURL = "https://relay.example.com/v1?key=URLSECRET42"
            APIDraftStore.save(d, key: nil, defaults: defaults)
            let json = try XCTUnwrap(String(data: try XCTUnwrap(defaults.data(forKey: APIDraftStore.defaultsKey)), encoding: .utf8))
            XCTAssertFalse(json.contains("URLSECRET42"), json)
            XCTAssertEqual(APIDraftStore.peek(defaults: defaults)?.customBaseURL, "", "不读钥匙串时拿不到")
            let loaded = try XCTUnwrap(APIDraftStore.load(slot: slot, defaults: defaults))
            XCTAssertEqual(loaded.draft.customBaseURL, "https://relay.example.com/v1?key=URLSECRET42")
            XCTAssertNil(loaded.key, "key 没存 = 用卡上的")
        }
    }

    func testCleanURLStaysInDefaults() throws {
        APIDraftStore.save(sample(), key: nil, defaults: defaults)
        XCTAssertEqual(APIDraftStore.peek(defaults: defaults)?.customBaseURL, "https://relay.example.com/v1")
        XCTAssertTrue(draftSecrets.isEmpty, "没 key、地址干净 → 不碰钥匙串")
    }

    // MARK: astra #6：列表删卡也清草稿

    @MainActor func testRemoveCredentialClearsItsDraft() {
        let id = "cred-del-\(UUID().uuidString)"
        APIDraftStore.save(sample(slot: id), key: "sk-test-del", defaults: .standard)
        ProviderManager().removeCredential(id: id)
        XCTAssertNil(APIDraftStore.peek(defaults: .standard))
        XCTAssertTrue(draftSecrets.isEmpty)
    }

    // MARK: 区域 / 接口格式（plan-provider-presets §4）

    /// 旧版本存下的草稿没有 regionSelection / presetProtocol 两个 key：照样解得出，按默认区域 + 默认格式恢复
    func testOldDraftWithoutRegionFieldsStillLoads() throws {
        let old = """
        {"slot":"cred-1","emoji":"🦊","nickname":"老草稿","presetSelection":"deepseek","customBaseURL":"",
         "customType":"openaiCompatible","toolsSupported":true,"models":[{"modelId":"deepseek-chat","name":"DeepSeek V3"}],
         "keyStored":false,"baseURLInSecret":false,"resumeOffered":false,"savedAt":\(Date().timeIntervalSinceReferenceDate)}
        """
        defaults.set(Data(old.utf8), forKey: APIDraftStore.defaultsKey)
        let loaded = try XCTUnwrap(APIDraftStore.load(slot: "cred-1", defaults: defaults))
        XCTAssertEqual(loaded.draft.nickname, "老草稿")
        XCTAssertNil(loaded.draft.regionSelection)
        XCTAssertNil(loaded.draft.presetProtocol)
    }

    func testRegionFieldsRoundTrip() throws {
        var d = sample(slot: "cred-2")
        d.presetSelection = "deepseek"
        d.regionSelection = CredentialDraft.ownRegion
        d.presetProtocol = ProviderType.anthropic.rawValue
        APIDraftStore.save(d, key: nil, defaults: defaults)
        let loaded = try XCTUnwrap(APIDraftStore.load(slot: "cred-2", defaults: defaults))
        XCTAssertEqual(loaded.draft.regionSelection, CredentialDraft.ownRegion)
        XCTAssertEqual(loaded.draft.presetProtocol, "anthropic")
    }
}
