import XCTest
@testable import 记忆花园

/// 铲屎二期刀 5：CC 设置以 hub 为准（D-B1）+ 楼层称呼镜像空名不写空串（L-B11）
final class CCConfigSyncTests: XCTestCase {
    private var suite = ""
    private var d: UserDefaults!

    override func setUp() {
        suite = "cc-config-sync-\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        d.removePersistentDomain(forName: suite)
    }

    func testPayloadCarriesEditedAtAndEmptyTemplate() {
        d.set(false, forKey: "ccNudgeEnabled")
        d.set(true, forKey: "ccNewSessionStream")
        d.set(20, forKey: "ccNudgeIdleMin")
        CCConfigSync.markEdited(["nudgeEnabled"], defaults: d, now: Date(timeIntervalSince1970: 5))
        let p = CCConfigSync.payload(d)
        XCTAssertEqual(p["nudgeEnabled"] as? Bool, false)
        XCTAssertEqual(p["newSessionTransport"] as? String, "stream")
        XCTAssertEqual(p["idleMinMin"] as? Int, 20)
        XCTAssertNil(p["idleMaxMin"], "没设过的不发，hub 用自己的")
        XCTAssertEqual(p["nudgeTemplate"] as? String, "", "空模板也发：手改清空要能回到默认")
        XCTAssertEqual((p["editedAt"] as? [String: Double])?["nudgeEnabled"], 5000)
    }

    func testApplyWritesHubValuesButKeepsNewerLocalEdits() {
        d.set(true, forKey: "ccNudgeEnabled")
        d.set("我的模板", forKey: "ccNudgeTemplate")
        CCConfigSync.markEdited(["cooldownMin"], defaults: d, now: Date(timeIntervalSince1970: 10))
        d.set(5, forKey: "ccNudgeCooldown")
        CCConfigSync.apply([
            "type": "cc_config", "nudgeEnabled": false, "newSessionTransport": "stream",
            "idleMinMin": 25, "idleMaxMin": 50, "quietStartMin": 60, "quietEndMin": 420, "cooldownMin": 90,
            "updatedAt": ["cooldownMin": 2000, "nudgeEnabled": 9000],
        ], to: d)
        XCTAssertEqual(d.object(forKey: "ccNudgeEnabled") as? Bool, false)
        XCTAssertTrue(d.bool(forKey: "ccNewSessionStream"))
        XCTAssertEqual(d.integer(forKey: "ccNudgeIdleMin"), 25)
        XCTAssertEqual(d.integer(forKey: "ccNudgeIdleMax"), 50)
        XCTAssertEqual(d.integer(forKey: "ccNudgeQuietStartMin"), 60)
        XCTAssertEqual(d.integer(forKey: "ccNudgeCooldown"), 5, "本机 10s 改的比 hub 记的 2s 新：不覆盖，等下次 set 带过去")
        XCTAssertNil(d.object(forKey: "ccNudgeTemplate"), "hub 没带模板 = 默认：本机回到灰字占位")
    }

    @MainActor
    func testMirrorNamesRemovesEmptyNames() {
        d.set("旧名", forKey: "assistantName")
        let profile = Profile(name: "楼", emoji: "🏠", description: "", userName: "粟粟", assistantName: "  ")
        ProfileManager.mirrorNames(profile, into: d)
        XCTAssertEqual(d.string(forKey: "userName"), "粟粟")
        XCTAssertNil(d.object(forKey: "assistantName"), "空 AI 名删 key，让 @AppStorage 默认「助手」生效")
    }
}
