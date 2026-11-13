import XCTest
@testable import 记忆花园

/// API 卡唯一落盘入口（plan-onboarding-xiaoya-impl P1a）：期望值照抽取前 APICredentialEditor.persist 的行为固化。
/// 跑在 mac 测试宿主里，照 ProviderManagerDefaultsTests 的隔离写法：相关 UserDefaults 键快照 / 还原，
/// 测试期新出现的钥匙串 account 删掉。不碰已有的 cc-bridge 等钥匙串条目（单例只测不写 key 的 ChatGPT 账号卡）。
@MainActor
final class CredentialCommitterTests: XCTestCase {
    private let keys = [
        "credentials", "favoriteModels", "localEngineAutoFavoritedIds", "exampleCardSeededV1",
        "credentialMigrationV1Done", "ccBridgeIdFixupV2Done", "selectedChatModel",
        "memoryExtractModelId", "customProviders", "customModels", "ccBridgeBaseURLOverride",
        "chatgptOAuthCardSeededV1", "credentialURLNormalizeV1Done",
    ]
    private var snapshot: [String: Any] = [:]
    private var keychainAccountsBefore: Set<String> = []

    override func setUp() async throws {
        snapshot = [:]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { snapshot[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
        keychainAccountsBefore = Set(KeychainStore.getAll().keys)
        // 老装机：一次性迁移都跑过，示例卡 / ChatGPT 卡不再播
        for k in ["credentialMigrationV1Done", "ccBridgeIdFixupV2Done", "exampleCardSeededV1",
                  "chatgptOAuthCardSeededV1", "credentialURLNormalizeV1Done"] {
            UserDefaults.standard.set(true, forKey: k)
        }
    }

    override func tearDown() async throws {
        for k in keys {
            if let v = snapshot[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        for account in Set(KeychainStore.getAll().keys).subtracting(keychainAccountsBefore) {
            KeychainStore.remove(account: account)
        }
    }

    // MARK: helpers

    private func write(_ cards: [APICredential]) {
        UserDefaults.standard.set(try! JSONEncoder().encode(cards), forKey: "credentials")
    }

    private func models(_ ids: [String], cid: String = "draft") -> [ProviderModel] {
        ids.map { ProviderModel(credentialId: cid, modelId: $0, name: $0) }
    }

    private var selected: String { UserDefaults.standard.string(forKey: "selectedChatModel") ?? "" }

    // MARK: 卡 id

    func testNewHTTPCardGetsCredIdAndKey() {
        let pm = ProviderManager()
        let d = CredentialDraft(presetSelection: "openai", nickname: "新卡", emoji: "🍐", models: models(["gpt-x"]))
        let id = CredentialCommitter.commit(d, key: "  sk-test-commit-new  ", existing: nil, adopt: .none, providerManager: pm)
        XCTAssertTrue(id.hasPrefix("cred-"))
        let card = pm.credentials.first { $0.id == id }
        XCTAssertEqual(card?.name, "新卡")
        XCTAssertEqual(card?.models.map(\.id), ["\(id)/gpt-x"])
        XCTAssertEqual(pm.apiKey(for: id), "sk-test-commit-new", "key 去首尾空白后进钥匙串")
        XCTAssertEqual(selected, "", ".none 不碰主模型")
        XCTAssertFalse(pm.isFavoriteModel(id: "\(id)/gpt-x"))
    }

    func testEmptyNameAndEmojiFallback() {
        let pm = ProviderManager()
        let d = CredentialDraft(presetSelection: "openai", nickname: "  ", emoji: " ")
        let id = CredentialCommitter.commit(d, key: "sk-test-commit-empty", existing: nil, adopt: .none, providerManager: pm)
        let card = pm.credentials.first { $0.id == id }
        XCTAssertEqual(card?.name, "未命名")
        XCTAssertEqual(card?.emoji, "🔑")
    }

    /// 主 hub 口令只由 CCHubRegistry 的配对入口写一次（plan-multi-hub impl1 #10）：卡提交不再写 cc-bridge 第二遍，
    /// 第二遍写失败（钥匙串先删后写）就删不掉第一遍刚存好的口令；Codex 本地卡的 key 照旧写
    func testCCBridgeCardCommitDoesNotRewriteHubSecret() {
        let fake = CCHubRegistryTests.FakeSecrets()
        fake.values[HubTokenStore.keychainAccount] = "paired"
        let pm = ProviderManager(keychain: fake)
        fake.failWrites = true
        let id = CredentialCommitter.commit(CredentialDraft(presetSelection: HubTokenStore.keychainAccount), key: "paired",
                                            existing: nil, adopt: .none, providerManager: pm)
        XCTAssertEqual(id, HubTokenStore.keychainAccount)
        XCTAssertFalse(fake.writeLog.contains(HubTokenStore.keychainAccount))
        XCTAssertEqual(fake.values[HubTokenStore.keychainAccount], "paired")
        XCTAssertEqual(pm.apiKey(for: HubTokenStore.keychainAccount), "paired")
    }

    /// 单例卡 id = 预设 id；ChatGPT 账号卡不动钥匙串；非 HTTP 卡新建时模型用预设自带的
    func testSingletonPresetIdAndNoKeychainWrite() {
        let pm = ProviderManager()
        let keyBefore = pm.apiKey(for: "chatgpt-oauth")
        let d = CredentialDraft(presetSelection: "chatgpt-oauth", nickname: "GPT", emoji: "🟢", models: models(["ignored"]))
        let id = CredentialCommitter.commit(d, key: "should-not-be-written", existing: nil, adopt: .none, providerManager: pm)
        XCTAssertEqual(id, "chatgpt-oauth")
        XCTAssertEqual(pm.apiKey(for: "chatgpt-oauth"), keyBefore)
        let card = pm.credentials.first { $0.id == id }
        XCTAssertEqual(card?.models.map(\.modelId), APIProvider.chatgptOAuth.models.map(\.modelId), "草稿里的模型不进非 HTTP 卡")
    }

    /// 已存的非 HTTP 卡：模型沿用已存的
    func testExistingNonHTTPCardKeepsStoredModels() {
        let existing = APICredential(id: "chatgpt-oauth", name: "GPT", emoji: "🟢", presetId: "chatgpt-oauth", type: .chatgptOAuth,
                                     baseURL: APIProvider.chatgptOAuth.baseURL, models: models(["stored-1"], cid: "chatgpt-oauth"))
        write([existing])
        let pm = ProviderManager()
        let d = CredentialDraft(presetSelection: "chatgpt-oauth", nickname: "改名", emoji: "🟢")
        let id = CredentialCommitter.commit(d, key: "", existing: existing, adopt: .none, providerManager: pm)
        XCTAssertEqual(id, "chatgpt-oauth")
        XCTAssertEqual(pm.credentials.first { $0.id == id }?.models.map(\.modelId), ["stored-1"])
        XCTAssertEqual(pm.credentials.first { $0.id == id }?.name, "改名")
    }

    /// 编辑已有卡：id 不变、原地替换；删掉的模型从收藏 / 主模型里清掉（forgetModels）
    func testEditKeepsIdAndForgetsDroppedModels() {
        let cid = "cred-test-edit-\(UUID().uuidString)"
        let existing = APICredential(id: cid, name: "旧", emoji: "🍋", presetId: "openai", type: .openaiCompatible,
                                     baseURL: "https://api.openai.com/v1", models: models(["a", "b"], cid: cid))
        write([existing])
        UserDefaults.standard.set(try! JSONEncoder().encode(["\(cid)/a", "\(cid)/b"]), forKey: "favoriteModels")
        UserDefaults.standard.set("\(cid)/b", forKey: "selectedChatModel")
        let pm = ProviderManager()
        let d = CredentialDraft(presetSelection: "openai", nickname: "旧", emoji: "🍋", models: models(["a"], cid: cid))
        let id = CredentialCommitter.commit(d, key: "sk-test-commit-edit", existing: existing, adopt: .none, providerManager: pm)
        XCTAssertEqual(id, cid)
        XCTAssertEqual(pm.credentials.filter { $0.id == cid }.count, 1)
        XCTAssertTrue(pm.isFavoriteModel(id: "\(cid)/a"))
        XCTAssertFalse(pm.isFavoriteModel(id: "\(cid)/b"))
        XCTAssertEqual(selected, "", "主模型指向被删的模型 → 清空")
    }

    // MARK: Adopt

    /// autoPick：预设推荐的第一个（清单里有）优先；主模型空着 → 接管
    func testAutoPickPrefersPresetFirstAndTakesEmptySelection() {
        let pm = ProviderManager()
        let presetFirst = APIProvider.openai.models.first!.modelId
        let d = CredentialDraft(presetSelection: "openai", nickname: "n", emoji: "🍑", models: models(["zz-other", presetFirst]))
        let id = CredentialCommitter.commit(d, key: "sk-test-commit-auto", existing: nil, adopt: .autoPick, providerManager: pm)
        XCTAssertTrue(pm.isFavoriteModel(id: "\(id)/\(presetFirst)"))
        XCTAssertEqual(selected, "\(id)/\(presetFirst)")
    }

    /// K3：当前主模型能用 → 只收藏不抢
    func testAutoPickDoesNotStealUsableSelection() {
        let pm = ProviderManager()
        let first = CredentialCommitter.commit(CredentialDraft(presetSelection: "openai", nickname: "1", emoji: "1️⃣", models: models(["m1"])),
                                               key: "sk-test-commit-k3a", existing: nil, adopt: .autoPick, providerManager: pm)
        XCTAssertEqual(selected, "\(first)/m1")
        let second = CredentialCommitter.commit(CredentialDraft(presetSelection: "openai", nickname: "2", emoji: "2️⃣", models: models(["m2"])),
                                                key: "sk-test-commit-k3b", existing: nil, adopt: .autoPick, providerManager: pm)
        XCTAssertEqual(selected, "\(first)/m1")
        XCTAssertTrue(pm.isFavoriteModel(id: "\(second)/m2"))
    }

    /// .model：按用户挑的那个收藏 + 接管（不是 autoPick 的那个）
    func testAdoptSpecificModel() {
        let pm = ProviderManager()
        let d = CredentialDraft(presetSelection: "openai", nickname: "n", emoji: "🍒", models: models(["m1", "m2"]))
        let id = CredentialCommitter.commit(d, key: "sk-test-commit-pick", existing: nil, adopt: .model("m2"), providerManager: pm)
        XCTAssertTrue(pm.isFavoriteModel(id: "\(id)/m2"))
        XCTAssertFalse(pm.isFavoriteModel(id: "\(id)/m1"))
        XCTAssertEqual(selected, "\(id)/m2")
    }

    /// .model 手填的 id 不在清单上：补进卡的清单再接管
    func testAdoptModelNotInListIsAppended() {
        let pm = ProviderManager()
        let d = CredentialDraft(presetSelection: "openai", nickname: "n", emoji: "🍓", models: models(["m1"]))
        let id = CredentialCommitter.commit(d, key: "sk-test-commit-manual", existing: nil, adopt: .model("typed-by-hand"), providerManager: pm)
        XCTAssertEqual(pm.credentials.first { $0.id == id }?.models.map(\.modelId), ["m1", "typed-by-hand"])
        XCTAssertEqual(selected, "\(id)/typed-by-hand")
    }

    // MARK: 模型元数据旁表（阶段 2–4 审查 #1）

    private func tempHints() -> ModelHints {
        ModelHints(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("hints-commit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model-hints.json"))
    }

    /// 新卡页面拉到的元数据：保存时按真实卡 id 写，不留在临时的 "draft" 槽
    func testNewCardHintsLandUnderRealCardId() {
        let pm = ProviderManager()
        let store = tempHints()
        let hint = ModelHint(contextTokens: 128000, inputModalities: ["text", "image"])
        let d = CredentialDraft(presetSelection: "openai", nickname: "n", emoji: "🫐", models: models(["gpt-x"]))
        let id = CredentialCommitter.commit(d, key: "sk-test-commit-hints", existing: nil, adopt: .none,
                                            modelHints: ["gpt-x": hint], hintStore: store, providerManager: pm)
        XCTAssertEqual(store.hint(credentialId: id, modelId: "gpt-x"), hint)
        XCTAssertNil(store.hint(credentialId: "draft", modelId: "gpt-x"))
        XCTAssertEqual(ModelHints(fileURL: store.fileURL).hint(credentialId: id, modelId: "gpt-x"), hint, "落盘后能读回")
    }

    /// 编辑已有卡：没拉过（nil）不动原来的；换家后没拉到（空表）清掉旧家的
    func testExistingCardHintsUntouchedWithoutFetchClearedOnEmpty() {
        let cid = "cred-test-hints-\(UUID().uuidString)"
        let existing = APICredential(id: cid, name: "旧", emoji: "🍈", presetId: "openai", type: .openaiCompatible,
                                     baseURL: "https://api.openai.com/v1", models: models(["a"], cid: cid))
        write([existing])
        let pm = ProviderManager()
        let store = tempHints()
        let old = ModelHint(contextTokens: 8000, inputModalities: nil)
        store.replace(credentialId: cid, with: ["a": old])
        let d = CredentialDraft(presetSelection: "openai", nickname: "改名", emoji: "🍈", models: models(["a"], cid: cid))
        CredentialCommitter.commit(d, key: "sk-test-commit-hints2", existing: existing, adopt: .none, hintStore: store, providerManager: pm)
        XCTAssertEqual(store.hint(credentialId: cid, modelId: "a"), old)
        CredentialCommitter.commit(d, key: "sk-test-commit-hints2", existing: existing, adopt: .none,
                                   modelHints: [:], hintStore: store, providerManager: pm)
        XCTAssertNil(store.hint(credentialId: cid, modelId: "a"))
    }

    /// 删卡（唯一入口 removeCredential）：旁表里这张卡的元数据一起删
    func testRemoveCredentialDropsHints() {
        let cid = "cred-test-hints-rm-\(UUID().uuidString)"
        write([APICredential(id: cid, name: "删", emoji: "🍐", presetId: "openai", type: .openaiCompatible,
                             baseURL: "https://api.openai.com/v1", models: models(["a"], cid: cid))])
        let pm = ProviderManager()
        ModelHints.shared.replace(credentialId: cid, with: ["a": ModelHint(contextTokens: 1, inputModalities: nil)])
        XCTAssertNotNil(ModelHints.shared.hint(credentialId: cid, modelId: "a"))
        pm.removeCredential(id: cid)
        XCTAssertNil(ModelHints.shared.hint(credentialId: cid, modelId: "a"))
    }

    // MARK: 本机模型

    /// 本机模型卡：只收藏已经装好的
    func testLocalModelCardFavoritesOnlyInstalled() throws {
        guard APIProvider.presets.contains(where: { $0.id == APICredential.localId }) else {
            throw XCTSkip("这台机器不支持本机模型，预设里没有")
        }
        let pm = ProviderManager()
        let d = CredentialDraft(presetSelection: APICredential.localId, nickname: "本机", emoji: "🌱")
        let id = CredentialCommitter.commit(d, key: "", existing: nil, adopt: .none, providerManager: pm)
        XCTAssertEqual(id, APICredential.localId)
        let card = try XCTUnwrap(pm.credentials.first { $0.id == id })
        XCTAssertEqual(card.models.map(\.modelId), APIProvider.localMLX.models.map(\.modelId))
        for m in card.models {
            let installed = AssistantModelStore.installedDirectory(modelId: m.modelId) != nil
            XCTAssertEqual(pm.isFavoriteModel(id: m.id), installed, m.modelId)
        }
        XCTAssertNil(pm.apiKey(for: id))
    }
}
