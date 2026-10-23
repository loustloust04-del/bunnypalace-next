import XCTest
@testable import 记忆花园

/// 修复第一刀·刀3：画像注入与做梦解绑——迁移抄值 + 开关独立 + 受总开关连坐。
final class ProfileInjectionFlagTests: XCTestCase {

    private let keys = ["mem_inject_profile", "mem_content_profile", "mem_profile_inject_split_v1", "mem_master"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        for k in keys { if let v = d.object(forKey: k) { saved[k] = v }; d.removeObject(forKey: k) }
    }

    override func tearDown() {
        let d = UserDefaults.standard
        for k in keys { d.removeObject(forKey: k) }
        for (k, v) in saved { d.set(v, forKey: k) }
        super.tearDown()
    }

    func testMigrationCopiesDreamOn() {
        UserDefaults.standard.set(true, forKey: "mem_content_profile")
        MemoryFlags.migrateProfileInjectionSplitIfNeeded()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "mem_inject_profile"))
        XCTAssertTrue(MemoryFlags.profileInjectionEnabled)
    }

    func testMigrationCopiesDreamOff() {
        UserDefaults.standard.set(false, forKey: "mem_content_profile")
        MemoryFlags.migrateProfileInjectionSplitIfNeeded()
        XCTAssertEqual(UserDefaults.standard.object(forKey: "mem_inject_profile") as? Bool, false)
    }

    func testMigrationKeepsExplicitValue() {
        UserDefaults.standard.set(true, forKey: "mem_content_profile")
        UserDefaults.standard.set(false, forKey: "mem_inject_profile")
        MemoryFlags.migrateProfileInjectionSplitIfNeeded()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "mem_inject_profile"), "已写过就不覆盖")
    }

    func testMigrationRunsOnce() {
        MemoryFlags.migrateProfileInjectionSplitIfNeeded()
        UserDefaults.standard.removeObject(forKey: "mem_inject_profile")
        UserDefaults.standard.set(true, forKey: "mem_content_profile")
        MemoryFlags.migrateProfileInjectionSplitIfNeeded()
        XCTAssertNil(UserDefaults.standard.object(forKey: "mem_inject_profile"), "sentinel 守卫只跑一次")
    }

    func testInjectionIndependentOfDream() {
        UserDefaults.standard.set(false, forKey: "mem_content_profile")
        UserDefaults.standard.set(true, forKey: "mem_inject_profile")
        XCTAssertFalse(DreamConsolidator.enabled)
        XCTAssertTrue(MemoryFlags.profileInjectionEnabled)
    }

    func testMasterOffGatesInjection() {
        UserDefaults.standard.set(true, forKey: "mem_inject_profile")
        UserDefaults.standard.set(false, forKey: "mem_master")
        XCTAssertFalse(MemoryFlags.profileInjectionEnabled)
    }
}
