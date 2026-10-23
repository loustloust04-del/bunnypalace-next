import XCTest
@testable import 记忆花园

/// ProviderManager 启动期的默认卡 / 默认收藏（粟粟 09-05：「收藏的模型下次 build 就消失」+ 新装机默认收藏三条）。
/// 跑在 mac 测试宿主里，UserDefaults.standard 就是 app 自己的——每个 key 快照 / 还原，别把粟粟的卡弄丢。
final class ProviderManagerDefaultsTests: XCTestCase {
    private let keys = [
        "credentials", "favoriteModels", "localEngineAutoFavoritedIds", "exampleCardSeededV1",
        "credentialMigrationV1Done", "ccBridgeIdFixupV2Done", "selectedChatModel",
        "memoryExtractModelId", "customProviders", "customModels", "ccBridgeBaseURLOverride",
    ]
    private var snapshot: [String: Any] = [:]
    private var keychainAccountsBefore: Set<String> = []

    override func setUp() {
        super.setUp()
        snapshot = [:]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { snapshot[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
        keychainAccountsBefore = Set(KeychainStore.getAll().keys)
    }

    override func tearDown() {
        for k in keys {
            if let v = snapshot[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        // V1 迁移可能给测试期的卡写 cred-UUID account，别留在钥匙串里
        for account in Set(KeychainStore.getAll().keys).subtracting(keychainAccountsBefore) {
            KeychainStore.remove(account: account)
        }
        super.tearDown()
    }

    // MARK: - helpers

    private func write(_ cards: [APICredential]) {
        UserDefaults.standard.set(try! JSONEncoder().encode(cards), forKey: "credentials")
    }

    private func writeFavorites(_ ids: [String]) {
        UserDefaults.standard.set(try! JSONEncoder().encode(ids), forKey: "favoriteModels")
    }

    private func card(id: String, presetId: String?, type: ProviderType, models: [String]) -> APICredential {
        APICredential(id: id, name: id, emoji: "🧪", presetId: presetId, type: type, baseURL: "http://127.0.0.1:1",
                      models: models.map { ProviderModel(credentialId: id, modelId: $0, name: $0) })
    }

    /// 老装机：三个一次性迁移都已跑过
    private func markMigrated() {
        UserDefaults.standard.set(true, forKey: "credentialMigrationV1Done")
        UserDefaults.standard.set(true, forKey: "ccBridgeIdFixupV2Done")
        UserDefaults.standard.set(true, forKey: "exampleCardSeededV1")
    }

    // MARK: - tests

    /// 根因：init 里默认收藏本地引擎跑在读收藏存档之前，追加后整表存回，把用户收藏覆盖掉。
    func testInitKeepsUserFavoritesWhileSeedingLocalEngines() {
        markMigrated()
        write([card(id: "cc-bridge", presetId: "cc-bridge", type: .ccBridge, models: ["cc-local"]),
               card(id: "cred-x", presetId: "openai", type: .openaiCompatible, models: ["m1"])])
        writeFavorites(["cred-x/m1"])
        // localEngineAutoFavoritedIds 不存在 = 第一次见到本地引擎，会走「追加 + 整表存回」那条路
        let pm = ProviderManager()
        XCTAssertTrue(pm.favoriteModelIds.contains("cred-x/m1"), "用户自己的收藏被启动期默认收藏覆盖掉了")
        XCTAssertTrue(pm.favoriteModelIds.contains("cc-bridge/cc-local"))
        XCTAssertTrue(pm.favoriteModelIds.contains("codex-bridge/codex-local"))
        XCTAssertTrue(pm.credentials.contains { $0.id == "codex-bridge" }, "配了 CC 桥就该自动配平 Codex 卡")
        // 下次 build 重启：还在
        XCTAssertTrue(ProviderManager().favoriteModelIds.contains("cred-x/m1"))
    }

    /// V1 迁移曾把 Codex 预设也建成 id "cc-bridge"——老装机启动时把撞 id 的那张删掉。
    func testDuplicateCodexCardFromV1IsRemoved() {
        markMigrated()
        write([card(id: "cc-bridge", presetId: "cc-bridge", type: .ccBridge, models: ["cc-local"]),
               card(id: "cc-bridge", presetId: "codex-bridge", type: .ccBridge, models: ["codex-local"]),
               card(id: "codex-bridge", presetId: "codex-bridge", type: .ccBridge, models: ["codex-local"])])
        let pm = ProviderManager()
        XCTAssertEqual(pm.credentials.filter { $0.id == "cc-bridge" }.count, 1)
        XCTAssertEqual(pm.credentials.first { $0.id == "cc-bridge" }?.presetId, "cc-bridge")
        XCTAssertEqual(pm.credentials.filter { $0.presetId == "codex-bridge" }.count, 1)
    }

    /// 新装机：V1 迁移 + ensure* 走完——Claude Code / Codex 各一张、示例卡一张，默认收藏恰好三条，别的都不收藏。
    func testFreshInstallSeedsExactlyThreeDefaultFavorites() {
        // setUp 已把所有 key 清掉 = 新装机
        let pm = ProviderManager()
        let ids = pm.credentials.map(\.id)
        XCTAssertEqual(ids.filter { $0 == "cc-bridge" }.count, 1)
        XCTAssertEqual(ids.filter { $0 == "codex-bridge" }.count, 1)
        XCTAssertTrue(ids.contains(APICredential.exampleId))
        XCTAssertEqual(Set(pm.favoriteModelIds),
                       ["cc-bridge/cc-local", "codex-bridge/codex-local", "example-api/example-model"])
        // 示例卡没 key 也要在选择器里露面
        XCTAssertTrue(pm.favoritesByCredential.contains { $0.0.id == APICredential.exampleId })
        // 删了示例卡、再启动（已不是新装机）：不冒回来
        pm.removeCredential(id: APICredential.exampleId)
        UserDefaults.standard.removeObject(forKey: "exampleCardSeededV1")
        XCTAssertFalse(ProviderManager().credentials.contains { $0.id == APICredential.exampleId })
    }
}
