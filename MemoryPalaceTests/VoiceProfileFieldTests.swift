import XCTest
@testable import 记忆花园

/// 发语音条 M3：Profile 新增 voice 字段的 Codable 兼容。
final class VoiceProfileFieldTests: XCTestCase {

    func testLegacyProfileDecodesWithNilVoice() throws {
        // 老 profile JSON（无 elevenVoiceId/Name）decode 两字段自动 nil
        let p = Profile(id: "p1", name: "测试楼", emoji: "🏛️", description: "",
                        userName: "你", assistantName: "助手")
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        dict.removeValue(forKey: "elevenVoiceId")
        dict.removeValue(forKey: "elevenVoiceName")
        let legacy = try JSONSerialization.data(withJSONObject: dict)

        let back = try JSONDecoder().decode(Profile.self, from: legacy)
        XCTAssertNil(back.elevenVoiceId)
        XCTAssertNil(back.elevenVoiceName)
        XCTAssertEqual(back.name, "测试楼")
    }

    func testVoiceFieldsRoundtrip() throws {
        var p = Profile(id: "p2", name: "楼", emoji: "🌿", description: "",
                        userName: "你", assistantName: "助手")
        p.elevenVoiceId = "v-abc"
        p.elevenVoiceName = "暖暖"
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.elevenVoiceId, "v-abc")
        XCTAssertEqual(back.elevenVoiceName, "暖暖")
    }
}
