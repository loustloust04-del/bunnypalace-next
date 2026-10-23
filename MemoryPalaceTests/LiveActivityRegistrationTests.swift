import Foundation
import XCTest
@testable import 记忆花园

// D6 注册协议的 wire 契约（docs/prompts/2026-08-29-live-activity/README.md「冻结合同」）：
// key 逐字对，nil 不落键（不写 null）。hub 侧 live-activity-tokens.ts 按这些 key 解。
final class LiveActivityRegistrationTests: XCTestCase {
    private let updateReg = CCLiveActivityRegistration(
        kind: .update,
        token: "aabbcc",
        previousToken: "001122",
        activityId: "ACT-1",
        sessionName: "mp-cc",
        installId: "INSTALL-1",
        env: "sandbox",
        preview: "hidden"
    )

    private let startReg = CCLiveActivityRegistration(
        kind: .start,
        token: "ddeeff",
        previousToken: nil,
        activityId: nil,
        sessionName: nil,
        installId: "INSTALL-1",
        env: "production",
        preview: "full"
    )

    private func json(_ reg: CCLiveActivityRegistration) throws -> [String: Any] {
        let data = try JSONEncoder().encode(reg)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testUpdateWireKeysMatchContract() throws {
        let obj = try json(updateReg)
        XCTAssertEqual(Set(obj.keys), [
            "kind", "token", "previous_token", "activity_id",
            "session_name", "install_id", "env", "preview",
        ])
        XCTAssertEqual(obj["kind"] as? String, "update")
        XCTAssertEqual(obj["token"] as? String, "aabbcc")
        XCTAssertEqual(obj["previous_token"] as? String, "001122")
        XCTAssertEqual(obj["activity_id"] as? String, "ACT-1")
        XCTAssertEqual(obj["session_name"] as? String, "mp-cc")
        XCTAssertEqual(obj["install_id"] as? String, "INSTALL-1")
        XCTAssertEqual(obj["env"] as? String, "sandbox")
        XCTAssertEqual(obj["preview"] as? String, "hidden")
    }

    func testStartOmitsNilKeys() throws {
        let obj = try json(startReg)
        XCTAssertEqual(Set(obj.keys), ["kind", "token", "install_id", "env", "preview"])
        XCTAssertNil(obj["previous_token"])
        XCTAssertNil(obj["activity_id"])
        XCTAssertNil(obj["session_name"])
        XCTAssertEqual(obj["kind"] as? String, "start")
        XCTAssertEqual(obj["env"] as? String, "production")
    }

    func testWireFieldsEqualsEncodedJSON() throws {
        XCTAssertEqual(
            Set(updateReg.wireFields().keys),
            Set(try json(updateReg).keys)
        )
        XCTAssertEqual(updateReg.wireFields()["activity_id"] as? String, "ACT-1")
        XCTAssertTrue(startReg.wireFields()["activity_id"] == nil)
    }

    func testRoundTripDecode() throws {
        let data = try JSONEncoder().encode(updateReg)
        XCTAssertEqual(try JSONDecoder().decode(CCLiveActivityRegistration.self, from: data), updateReg)
    }

    func testTopicGoesOnWireWhenSet() throws {
        var reg = startReg
        reg.topic = "com.susu.MemoryPalace.susu"
        let obj = try json(reg)
        XCTAssertEqual(Set(obj.keys), ["kind", "token", "install_id", "env", "preview", "topic"])
        XCTAssertEqual(obj["topic"] as? String, "com.susu.MemoryPalace.susu")
    }

    /// UserDefaults 里没有 topic 的老注册照常解出来。
    func testDecodesLegacyRecordWithoutTopic() throws {
        let legacy = #"{"kind":"start","token":"ddeeff","install_id":"INSTALL-1","env":"production","preview":"full"}"#
        let reg = try JSONDecoder().decode(CCLiveActivityRegistration.self, from: Data(legacy.utf8))
        XCTAssertEqual(reg, startReg)
        XCTAssertNil(reg.topic)
    }

    func testIdentityKeys() {
        XCTAssertEqual(updateReg.identity, "update:ACT-1")
        XCTAssertEqual(startReg.identity, "start:INSTALL-1")
    }

    /// token 轮换是**替换**，不追加。
    func testUpsertReplacesSameIdentity() {
        var rotated = updateReg
        rotated.token = "999999"
        rotated.previousToken = updateReg.token

        var regs = CCLiveActivityRegistrationStore.upsert(updateReg, into: [])
        regs = CCLiveActivityRegistrationStore.upsert(startReg, into: regs)
        regs = CCLiveActivityRegistrationStore.upsert(rotated, into: regs)

        XCTAssertEqual(regs.count, 2)
        XCTAssertEqual(regs.first { $0.kind == .update }?.token, "999999")
        XCTAssertEqual(regs.first { $0.kind == .update }?.previousToken, "aabbcc")
        XCTAssertEqual(regs.first { $0.kind == .start }?.token, "ddeeff")
    }

    func testInstallIdIsStableAndRegistrationsPersist() throws {
        let suite = "LiveActivityRegistrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let first = CCLiveActivityRegistrationStore.installId(defaults)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(CCLiveActivityRegistrationStore.installId(defaults), first)

        XCTAssertEqual(CCLiveActivityRegistrationStore.load(defaults), [])
        CCLiveActivityRegistrationStore.save([updateReg, startReg], defaults)
        XCTAssertEqual(CCLiveActivityRegistrationStore.load(defaults), [updateReg, startReg])
    }
}
