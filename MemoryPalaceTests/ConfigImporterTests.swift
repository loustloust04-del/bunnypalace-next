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
}
