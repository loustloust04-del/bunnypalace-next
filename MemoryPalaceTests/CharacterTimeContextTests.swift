import XCTest
@testable import 记忆花园

/// atrium P3②：「作息感知」按楼层存，promptText 只看 Profile，不读全局 UserDefaults。
final class CharacterTimeContextTests: XCTestCase {
    private let suite = "xctest-time-awareness"
    private var savedGlobal: Any?

    override func setUp() {
        super.setUp()
        savedGlobal = UserDefaults.standard.object(forKey: CharacterTimeContext.legacyGlobalKey)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        if let savedGlobal { UserDefaults.standard.set(savedGlobal, forKey: CharacterTimeContext.legacyGlobalKey) }
        else { UserDefaults.standard.removeObject(forKey: CharacterTimeContext.legacyGlobalKey) }
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func profile(id: String = "p1", on: Bool, tz: String? = "Asia/Tokyo") -> Profile {
        var p = Profile(id: id, name: "楼", emoji: "🌿", description: "", userName: "你", assistantName: "栗子")
        p.characterTimeZone = tz
        p.timeAwarenessEnabled = on
        return p
    }

    func testOffGivesNil() {
        XCTAssertNil(CharacterTimeContext.promptText(profile: profile(on: false)))
    }

    func testOnWithValidZoneGivesText() throws {
        let text = try XCTUnwrap(CharacterTimeContext.promptText(profile: profile(on: true)))
        XCTAssertTrue(text.hasPrefix("〔时间〕"))
        XCTAssertTrue(text.contains("栗子"))
    }

    func testOnWithoutValidZoneGivesNil() {
        XCTAssertNil(CharacterTimeContext.promptText(profile: profile(on: true, tz: nil)))
        XCTAssertNil(CharacterTimeContext.promptText(profile: profile(on: true, tz: "Mars/Base")))
    }

    func testIgnoresGlobalKey() {
        UserDefaults.standard.set(true, forKey: CharacterTimeContext.legacyGlobalKey)
        XCTAssertNil(CharacterTimeContext.promptText(profile: profile(on: false)), "全局开着、这层关 → 不注入")
        UserDefaults.standard.set(false, forKey: CharacterTimeContext.legacyGlobalKey)
        XCTAssertNotNil(CharacterTimeContext.promptText(profile: profile(on: true)), "全局关着、这层开 → 注入")
    }

    func testLegacyProfileDecodesOff() throws {
        let p = profile(on: true)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        XCTAssertEqual(dict["storedTimeAwareness"] as? Bool, true)
        dict.removeValue(forKey: "storedTimeAwareness")
        let legacy = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertFalse(legacy.timeAwarenessEnabled)
        XCTAssertTrue(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p)).timeAwarenessEnabled)
    }

    func testMigrationTurnsAllFloorsOnOnce() {
        let d = UserDefaults(suiteName: suite)!
        d.set(true, forKey: CharacterTimeContext.legacyGlobalKey)
        var persisted: [Profile] = []
        let floors = [profile(id: "a", on: false), profile(id: "b", on: true)]
        XCTAssertTrue(CharacterTimeContext.migrateGlobalSwitch(profiles: floors, defaults: d) { persisted = $0; return true })
        XCTAssertEqual(persisted.map(\.id), ["a"], "已经开着的不重写")
        XCTAssertTrue(persisted.allSatisfy(\.timeAwarenessEnabled))
        XCTAssertTrue(d.bool(forKey: CharacterTimeContext.migratedKey))
        XCTAssertFalse(CharacterTimeContext.migrateGlobalSwitch(profiles: floors, defaults: d) { _ in XCTFail("只跑一次"); return true })
    }

    func testMigrationGlobalOffLeavesFloors() {
        let d = UserDefaults(suiteName: suite)!
        XCTAssertTrue(CharacterTimeContext.migrateGlobalSwitch(profiles: [profile(on: false)], defaults: d) { _ in
            XCTFail("全局没开不写楼层"); return true
        })
        XCTAssertTrue(d.bool(forKey: CharacterTimeContext.migratedKey))
    }

    func testMigrationPersistFailureRetries() {
        let d = UserDefaults(suiteName: suite)!
        d.set(true, forKey: CharacterTimeContext.legacyGlobalKey)
        XCTAssertFalse(CharacterTimeContext.migrateGlobalSwitch(profiles: [profile(on: false)], defaults: d) { _ in false })
        XCTAssertFalse(d.bool(forKey: CharacterTimeContext.migratedKey), "落盘失败不落标记")
    }
}
