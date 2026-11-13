import XCTest
import Security
@testable import 记忆花园

/// atrium P3③：声音效果三参数按楼层存，`current(for:)` 读 Profile；老全局键只给一次性迁移读。
final class VoiceTuningTests: XCTestCase {
    private let suite = "xctest-voice-tuning"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func profile(_ id: String = "p1") -> Profile {
        Profile(id: id, name: "楼", emoji: "🌿", description: "", userName: "你", assistantName: "栗子")
    }

    func testDefaultProfileGivesDefaults() {
        XCTAssertEqual(VoiceTuning.current(for: profile()), VoiceTuning.defaults)
        XCTAssertEqual(VoiceTuning.defaults,
                       VoiceTuning.Settings(stability: 0.0, similarityBoost: 0.75, style: 0.88, speed: 1.1))
    }

    func testReadsProfileValues() {
        var p = profile()
        p.voiceStability = 0.5
        p.voiceStyle = 0.3
        p.voiceSpeed = 0.9
        XCTAssertEqual(VoiceTuning.current(for: p),
                       VoiceTuning.Settings(stability: 0.5, similarityBoost: 0.75, style: 0.3, speed: 0.9))
        VoiceTuning.resetToDefaults(&p)
        XCTAssertEqual(VoiceTuning.current(for: p), VoiceTuning.defaults)
    }

    func testIgnoresGlobalKeys() {
        let keys = [VoiceTuning.stabilityKey, VoiceTuning.styleKey, VoiceTuning.speedKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.set(0.42, forKey: key) }
        XCTAssertEqual(VoiceTuning.current(for: profile()), VoiceTuning.defaults)
    }

    func testCodableLegacyAndRoundtrip() throws {
        var p = profile()
        p.voiceStyle = 0.4
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        XCTAssertEqual(dict["storedVoiceStyle"] as? Double, 0.4)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p)).voiceStyle, 0.4)
        dict.removeValue(forKey: "storedVoiceStyle")
        let legacy = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(VoiceTuning.current(for: legacy), VoiceTuning.defaults)
    }

    func testMigrationCopiesGlobalToAllFloorsOnce() {
        let d = UserDefaults(suiteName: suite)!
        d.set(0.5, forKey: VoiceTuning.stabilityKey)
        d.set(1.3, forKey: VoiceTuning.speedKey)
        var persisted: [Profile] = []
        let floors = [profile("a"), profile("b")]
        XCTAssertTrue(VoiceTuning.migrateGlobalToFloors(profiles: floors, defaults: d) { persisted = $0; return true })
        XCTAssertEqual(persisted.map(\.id), ["a", "b"])
        for p in persisted {
            XCTAssertEqual(VoiceTuning.current(for: p),
                           VoiceTuning.Settings(stability: 0.5, similarityBoost: 0.75, style: 0.88, speed: 1.3),
                           "没设过的风格强度用默认值")
        }
        XCTAssertTrue(d.bool(forKey: VoiceTuning.migratedKey))
        XCTAssertFalse(VoiceTuning.migrateGlobalToFloors(profiles: floors, defaults: d) { _ in XCTFail("只跑一次"); return true })
    }

    func testMigrationNothingSetLeavesFloors() {
        let d = UserDefaults(suiteName: suite)!
        XCTAssertTrue(VoiceTuning.migrateGlobalToFloors(profiles: [profile()], defaults: d) { _ in
            XCTFail("全局没设过不写楼层"); return true
        })
        XCTAssertTrue(d.bool(forKey: VoiceTuning.migratedKey))
    }

    func testMigrationPersistFailureRetries() {
        let d = UserDefaults(suiteName: suite)!
        d.set(0.5, forKey: VoiceTuning.styleKey)
        XCTAssertFalse(VoiceTuning.migrateGlobalToFloors(profiles: [profile()], defaults: d) { _ in false })
        XCTAssertFalse(d.bool(forKey: VoiceTuning.migratedKey), "落盘失败不落标记")
    }

    @MainActor
    func testCallRouteCarriesFloorTuning() {
        var p = profile()
        p.voiceSpeed = 0.8
        XCTAssertEqual(CallSpeechPipeline.Route.resolve(profile: p, legacyKey: { nil }, legacyKeyStatus: { errSecItemNotFound }).tuning.speed, 0.8)
        XCTAssertEqual(CallSpeechPipeline.Route.resolve(profile: nil).tuning, VoiceTuning.defaults)
    }
}
