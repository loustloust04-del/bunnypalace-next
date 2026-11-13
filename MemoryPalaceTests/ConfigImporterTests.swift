import XCTest
@testable import 记忆花园

/// 导入设置时给剥了模型的卡补种子（plan-provider-presets §4）：有 regionId 用那个区域的，没有用默认区域的
final class ConfigImporterTests: XCTestCase {

    private final class NoSecrets: ConfigSecretStore {
        func allAccounts() -> [String] { [] }
        func get(account: String) -> String? { nil }
        func set(_ value: String, account: String) {}
    }

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "xctest-config-import-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func importCredentials(_ creds: [[String: Any]]) throws -> [APICredential] {
        let root: [String: Any] = ["schema_version": 1, ConfigSchema.Section.api.rawValue: ["credentials": creds]]
        try ConfigImporter.importAll(JSONSerialization.data(withJSONObject: root), defaults: defaults, secrets: NoSecrets())
        let data = try XCTUnwrap(defaults.data(forKey: "credentials"))
        return try JSONDecoder().decode([APICredential].self, from: data)
    }

    private func cred(_ id: String, preset: String?, regionId: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["id": id, "name": id, "emoji": "🍐", "type": "openaiCompatible",
                                "baseURL": "https://api.openai.com/v1", "extraHeaders": [String: String](), "createdAt": 0]
        if let preset { d["presetId"] = preset }
        if let regionId { d["regionId"] = regionId }
        return d
    }

    func testSeedsFromRegionOrDefault() throws {
        let cards = try importCredentials([
            cred("cred-a", preset: "openai"),
            cred("cred-b", preset: "openai", regionId: "default"),
            cred("cred-c", preset: "openai", regionId: "no-such-region"),
            cred("cred-d", preset: nil),
        ])
        let seeds = APIProvider.openai.models.map(\.modelId)
        XCTAssertEqual(cards[0].models.map(\.modelId), seeds)
        XCTAssertEqual(cards[1].models.map(\.modelId), seeds)
        XCTAssertEqual(cards[1].regionId, "default", "regionId 原样导入")
        XCTAssertEqual(cards[2].models.map(\.modelId), seeds, "认不出的区域退回默认区域")
        XCTAssertTrue(cards[0].models.allSatisfy { $0.credentialId == "cred-a" })
        XCTAssertEqual(cards[3].models, [], "自定义卡没有种子")
    }

    func testExistingModelsUntouched() throws {
        var c = cred("cred-e", preset: "openai")
        c["models"] = [["credentialId": "cred-e", "modelId": "mine", "name": "Mine"]]
        let cards = try importCredentials([c])
        XCTAssertEqual(cards[0].models.map(\.modelId), ["mine"])
    }

    func testImportPreservesProfileNameMirrorsWhileApplyingOrdinarySettings() throws {
        for version in [0, ConfigSchema.currentVersion] {
            for transport in 0...2 {
                defaults.set("当前用户", forKey: "userName")
                defaults.set("当前助手", forKey: "assistantName")
                defaults.set("原导出方式", forKey: "exportMode")
                let root: [String: Any] = [
                    "schema_version": version,
                    "general": [
                        "userName": "备份旧用户",
                        "assistantName": "备份旧助手",
                        "exportMode": "导入导出方式"
                    ]
                ]

                let result = try importNameConfig(root, transport: transport)
                XCTAssertTrue(result.ignoredNameMirrors)

                XCTAssertEqual(defaults.string(forKey: "userName"), "当前用户")
                XCTAssertEqual(defaults.string(forKey: "assistantName"), "当前助手")
                XCTAssertEqual(defaults.string(forKey: "exportMode"), "导入导出方式")
            }
        }
    }

    func testImportOfOnlyNamesDoesNotCreateIndependentMirrors() throws {
        for version in [0, ConfigSchema.currentVersion] {
            for transport in 0...2 {
                let root: [String: Any] = [
                    "schema_version": version,
                    "general": ["userName": "备份用户", "assistantName": "备份助手"]
                ]

                let result = try importNameConfig(root, transport: transport)
                XCTAssertTrue(result.ignoredNameMirrors)

                let stored = defaults.persistentDomain(forName: suite) ?? [:]
                XCTAssertNil(stored["userName"])
                XCTAssertNil(stored["assistantName"])
            }
        }
    }

    func testImportReportsIgnoredNamesOnlyWhenGeneralContainsThoseKeys() throws {
        let cases: [([String: Any], Bool)] = [
            (["general": ["userName": ""]], true),
            (["general": ["assistantName": NSNull()]], true),
            (["general": ["exportMode": "测试导出方式"]], false),
            (["appearance": ["userName": "不属于通用"]], false),
            ([:], false)
        ]
        for (sections, expected) in cases {
            var root = sections
            root["schema_version"] = ConfigSchema.currentVersion
            for transport in 0...2 {
                let result = try importNameConfig(root, transport: transport)
                XCTAssertEqual(result.ignoredNameMirrors, expected)
            }
        }
    }

    /// atrium P3④b：字体字号 / 气泡几何 / 行距段距按人存，9 个老键只是当前层的镜像，不进导出表、老备份里有也不导
    func testPerFloorAppearanceKeysAreOutOfConfig() throws {
        XCTAssertTrue(Set(ConfigSchema.appStorageKeys.map(\.key)).isDisjoint(with: ChatAppearance.legacyKeys))
        let root: [String: Any] = [
            "schema_version": ConfigSchema.currentVersion,
            "general": ["selectedFont": "老备份字体", "fontScale": 1.8, "lineSpacingScale": 1.0],
            "appearance": ["bubbleCornerRadius": 4.0, "bubbleSpacing": 10.0]
        ]
        _ = try importNameConfig(root, transport: 0)
        for key in ChatAppearance.legacyKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    /// 同一 apply 入口的三种消费者路径：明文、带口令文件、预先解锁的文件。
    private func importNameConfig(_ root: [String: Any], transport: Int) throws -> ConfigImporter.Result {
        let plain = try JSONSerialization.data(withJSONObject: root)
        if transport == 0 {
            return try ConfigImporter.importAll(plain, defaults: defaults, secrets: NoSecrets())
        } else {
            let passphrase = "isolated-config-import-test"
            let encrypted = try ConfigCrypto.seal(plain, passphrase: passphrase)
            if transport == 1 {
                return try ConfigImporter.importAll(
                    encrypted, passphrase: passphrase, defaults: defaults, secrets: NoSecrets()
                )
            } else {
                let unlocked = try ConfigImporter.unlock(encrypted, passphrase: passphrase)
                return try ConfigImporter.importAll(unlocked, defaults: defaults, secrets: NoSecrets())
            }
        }
    }
}
