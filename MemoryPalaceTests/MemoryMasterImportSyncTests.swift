import XCTest
@testable import 记忆花园

/// v5 · 0.2：设置导入后记忆总开关两份（perm.memory / mem_master）对齐——以 perm.memory 为准，只有 mem_master 时按它
final class MemoryMasterImportSyncTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "xctest-mem-master-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func importJSON(_ root: [String: Any], into d: UserDefaults) throws {
        var r = root
        r["schema_version"] = ConfigSchema.currentVersion
        try ConfigImporter.importAll(try JSONSerialization.data(withJSONObject: r), defaults: d, secrets: NoSecrets())
    }

    private final class NoSecrets: ConfigSecretStore {
        func allAccounts() -> [String] { [] }
        func get(account: String) -> String? { nil }
        func set(_ value: String, account: String) {}
    }

    func testPermWinsOverMasterKey() throws {
        let d = makeDefaults()
        try importJSON(["memory": ["mem_master": true], "permissions": ["perm.memory": PermissionLevel.notAllowed.rawValue]], into: d)
        XCTAssertEqual(d.integer(forKey: "perm.memory"), PermissionLevel.notAllowed.rawValue)
        XCTAssertEqual(d.object(forKey: "mem_master") as? Bool, false, "显示关 = 实际关")
    }

    func testPermBypassTurnsMasterOn() throws {
        let d = makeDefaults()
        d.set(false, forKey: "mem_master")
        try importJSON(["memory": ["mem_master": false], "permissions": ["perm.memory": PermissionLevel.bypass.rawValue]], into: d)
        XCTAssertEqual(d.object(forKey: "mem_master") as? Bool, true)
    }

    func testOnlyMasterKeyFillsPerm() throws {
        let d = makeDefaults()
        d.set(PermissionLevel.bypass.rawValue, forKey: "perm.memory")
        try importJSON(["memory": ["mem_master": false]], into: d)
        XCTAssertEqual(d.integer(forKey: "perm.memory"), PermissionLevel.notAllowed.rawValue)
        XCTAssertEqual(d.object(forKey: "mem_master") as? Bool, false)
    }

    func testNeitherKeyLeavesLocalAlone() throws {
        let d = makeDefaults()
        d.set(PermissionLevel.bypass.rawValue, forKey: "perm.memory")
        d.set(true, forKey: "mem_master")
        try importJSON(["memory": [FragmentWatch.everyKey: 24]], into: d)
        XCTAssertEqual(d.integer(forKey: "perm.memory"), PermissionLevel.bypass.rawValue)
        XCTAssertEqual(d.object(forKey: "mem_master") as? Bool, true)
    }
}
