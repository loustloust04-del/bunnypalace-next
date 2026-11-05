import XCTest
@testable import 记忆花园

/// 小芽名字和人设收口（plan-onboarding-xiaoya-impl §2.5）：名字恒为小芽，覆写只在 pro 下生效且钉名字。内存偏好
final class AssistantPromptsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "AssistantPromptsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNameIsAlwaysXiaoya() {
        XCTAssertEqual(AssistantPrompts.assistantName, "小芽")
        XCTAssertEqual(AssistantPrompts.englishName, "Lily")
    }

    func testLiteWithoutOverrideUsesBuiltIn() {
        XCTAssertEqual(AssistantPrompts.personaLayer(defaults), AssistantPrompts.defaultPersona(name: "小芽"))
    }

    func testLiteIgnoresOverride() {
        defaults.set("你是一只猫", forKey: AssistantPrompts.personaOverrideKey)
        XCTAssertEqual(AssistantPrompts.personaLayer(defaults), AssistantPrompts.defaultPersona(name: "小芽"))
        XCTAssertEqual(defaults.string(forKey: AssistantPrompts.personaOverrideKey), "你是一只猫", "键保留")
    }

    func testProWithoutOverrideUsesBuiltInXiaoya() {
        defaults.set(true, forKey: "settings.proMode")
        let layer = AssistantPrompts.personaLayer(defaults)
        XCTAssertEqual(layer, AssistantPrompts.defaultPersona(name: "小芽"))
        XCTAssertFalse(layer.contains("Rosemary"))
    }

    func testProOverrideKeepsName() {
        defaults.set(true, forKey: "settings.proMode")
        defaults.set("  说话更冷淡一点  ", forKey: AssistantPrompts.personaOverrideKey)
        XCTAssertEqual(AssistantPrompts.personaLayer(defaults), "你叫「小芽」（英文名 Lily），名字不能改。\n\(AssistantPrompts.gardenNaming)\n说话更冷淡一点")
    }

    /// 旧名字键不再读（键不删）
    func testOldNameKeyIsIgnored() {
        defaults.set(true, forKey: "settings.proMode")
        defaults.set(" 豆豆 ", forKey: AssistantPrompts.nameKey)
        XCTAssertEqual(AssistantPrompts.assistantName, "小芽")
        XCTAssertEqual(AssistantPrompts.personaLayer(defaults), AssistantPrompts.defaultPersona(name: "小芽"))
    }
}
