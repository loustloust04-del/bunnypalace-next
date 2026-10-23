import XCTest
@testable import 记忆花园

/// plan-voice-providers V1c：Profile 新字段 Codable 兼容 + 老 ElevenLabs 配置迁移（幂等、无老 key 不生成）。
final class VoiceServiceMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var keychainService = ""

    override func setUp() {
        super.setUp()
        suiteName = "VoiceServiceMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychainService = "com.susu.MemoryPalace.test.voicemig-\(UUID().uuidString)"
    }

    override func tearDown() {
        for account in KeychainStore.allAccounts(service: keychainService) {
            KeychainStore.remove(account: account, service: keychainService)
        }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> VoiceServiceStore {
        VoiceServiceStore(defaults: defaults, keychainService: keychainService)
    }

    private func profile(_ id: String, voice: String? = nil, name: String? = nil) -> Profile {
        var p = Profile(id: id, name: id, emoji: "🏛️", description: "", userName: "你", assistantName: "助手")
        p.elevenVoiceId = voice
        p.elevenVoiceName = name
        return p
    }

    // MARK: - Profile Codable

    func testLegacyProfileDecodesNewVoiceFieldsAsNil() throws {
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile("p"))) as! [String: Any]
        for k in ["voiceServiceId", "voiceId", "voiceName", "messageModel", "callModel", "voiceExtraNote"] {
            dict.removeValue(forKey: k)
        }
        let back = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(back.voiceServiceId)
        XCTAssertNil(back.voiceId)
        XCTAssertNil(back.messageModel)
        XCTAssertNil(back.voiceExtraNote)
    }

    func testNewVoiceFieldsRoundtrip() throws {
        var p = profile("p")
        p.voiceServiceId = "s"
        p.voiceId = "v"
        p.voiceName = "暖暖"
        p.messageModel = "m1"
        p.callModel = "m2"
        p.voiceExtraNote = "气声多一点"
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    // MARK: - 迁移

    /// 跑一次迁移；`saved` 收集落盘的楼层，`persistOK` 控制落盘成败
    @discardableResult
    private func migrate(_ profiles: [Profile], store: VoiceServiceStore? = nil, key: String? = "k-123456",
                         writeKey: ((String, VoiceService) -> Bool)? = nil, persistOK: Bool = true,
                         saved: inout [Profile]) -> VoiceServiceMigration.Outcome {
        var got: [Profile] = []
        let outcome = VoiceServiceMigration.run(profiles: profiles, store: store ?? makeStore(), legacyKey: key,
                                                defaults: defaults, writeKey: writeKey,
                                                persist: { got = $0; return persistOK })
        saved += got
        return outcome
    }

    func testMigratesLegacyKeyAndAttachesVoicedProfiles() throws {
        let store = makeStore()
        var saved: [Profile] = []
        let outcome = migrate([profile("a", voice: "v-a", name: "暖暖"), profile("b")], store: store,
                              key: " el-legacy-key ", saved: &saved)
        XCTAssertEqual(outcome, .done(migrated: ["a"]))

        let svc = try XCTUnwrap(store.service(id: VoiceServiceMigration.legacyServiceId))
        XCTAssertEqual(svc.kind, .elevenLabs)
        XCTAssertEqual(store.services.count, 1)
        XCTAssertEqual(store.key(for: svc.id), "el-legacy-key")
        XCTAssertNil(KeychainStore.get(account: VoiceTuning.keychainAccount, service: keychainService),
                     "迁移不重写老 account")

        XCTAssertEqual(saved.map(\.id), ["a"], "没选过声音的楼层不挂")
        let a = saved[0]
        XCTAssertEqual(a.voiceServiceId, svc.id)
        XCTAssertEqual(a.voiceId, "v-a")
        XCTAssertEqual(a.voiceName, "暖暖")
        XCTAssertEqual(a.messageModel, "eleven_v3")
        XCTAssertEqual(a.callModel, "eleven_v3")
        XCTAssertEqual(a.elevenVoiceId, "v-a", "老字段保留")
        XCTAssertTrue(defaults.bool(forKey: VoiceServiceMigration.doneKey))
    }

    func testRunningTwiceIsNoOp() {
        let store = makeStore()
        var saved: [Profile] = []
        migrate([profile("a", voice: "v-a")], store: store, saved: &saved)
        var second: [Profile] = []
        XCTAssertEqual(migrate(saved, store: store, saved: &second), .skipped)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(store.services.count, 1)
    }

    /// 标记丢了（比如中途崩）再跑：服务不重复、已挂的楼层不动、key 不覆盖
    func testRerunWithoutFlagStillConverges() {
        var saved: [Profile] = []
        migrate([profile("a", voice: "v-a")], key: "k-first-1", saved: &saved)
        defaults.removeObject(forKey: VoiceServiceMigration.doneKey)
        var again: [Profile] = []
        XCTAssertEqual(migrate(saved, key: "k-other-2", saved: &again), .done(migrated: []))
        XCTAssertTrue(again.isEmpty)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.services.count, 1)
        XCTAssertEqual(reloaded.key(for: VoiceServiceMigration.legacyServiceId), "k-first-1")
    }

    func testNoLegacyKeyCreatesNothingAndRetriesLater() {
        let store = makeStore()
        for key in [nil, "", "   "] as [String?] {
            var saved: [Profile] = []
            XCTAssertEqual(migrate([profile("a", voice: "v-a")], store: store, key: key, saved: &saved), .skipped)
            XCTAssertTrue(saved.isEmpty)
        }
        XCTAssertTrue(store.services.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: VoiceServiceMigration.doneKey), "没 key 不落标记，下次启动再看")
    }

    func testProfileWithExistingServiceUntouched() {
        var p = profile("a", voice: "v-a")
        p.voiceServiceId = "mine"
        var saved: [Profile] = []
        XCTAssertEqual(migrate([p], saved: &saved), .done(migrated: []))
        XCTAssertTrue(saved.isEmpty)
    }

    // MARK: - 失败路径（sol P1-3）

    /// key 写失败：楼层不动、不落标记；下次正常写就迁完
    func testKeyWriteFailureLeavesNoFlagAndRetries() {
        let store = makeStore()
        var saved: [Profile] = []
        XCTAssertEqual(migrate([profile("a", voice: "v-a")], store: store, writeKey: { _, _ in false }, saved: &saved),
                       .keyFailed)
        XCTAssertTrue(saved.isEmpty, "key 没写进去就不挂楼层")
        XCTAssertFalse(defaults.bool(forKey: VoiceServiceMigration.doneKey))

        XCTAssertEqual(migrate([profile("a", voice: "v-a")], store: store, saved: &saved), .done(migrated: ["a"]))
        XCTAssertEqual(store.key(for: VoiceServiceMigration.legacyServiceId), "k-123456")
        XCTAssertTrue(defaults.bool(forKey: VoiceServiceMigration.doneKey))
    }

    /// 写入报成功但读不回来（钥匙串静默失败）也算失败
    func testKeyNotReadableBackCountsAsFailure() {
        var saved: [Profile] = []
        XCTAssertEqual(migrate([profile("a", voice: "v-a")], writeKey: { _, _ in true }, saved: &saved), .keyFailed)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: VoiceServiceMigration.doneKey))
    }

    /// 楼层落盘失败：不落标记；重跑只补还没迁上的楼层（已落盘的不重复）
    func testSaveFailureLeavesNoFlagAndRetriesOnlyUnmigrated() {
        let store = makeStore()
        var saved: [Profile] = []
        let profiles = [profile("a", voice: "v-a"), profile("b", voice: "v-b")]
        XCTAssertEqual(migrate(profiles, store: store, persistOK: false, saved: &saved), .saveFailed)
        XCTAssertFalse(defaults.bool(forKey: VoiceServiceMigration.doneKey), "落盘失败不落标记")

        // 假设 a 其实落盘了、b 没有：重跑只补 b
        var onDisk = profiles
        onDisk[0] = saved.first { $0.id == "a" }!
        var retry: [Profile] = []
        XCTAssertEqual(migrate(onDisk, store: store, saved: &retry), .done(migrated: ["b"]))
        XCTAssertEqual(retry.map(\.id), ["b"])
        XCTAssertEqual(store.services.count, 1, "服务 id 固定不重复")
        XCTAssertTrue(defaults.bool(forKey: VoiceServiceMigration.doneKey))
    }
}
