import XCTest
@testable import 记忆花园

/// 气泡渐变第二色 `ThemeTokenSet.userBubbleGradient`（plan-bubble-gradient）：
/// 老 JSON 缺 key → nil（单色照旧）；设值往返不丢；三处派生（纯净背景 / 壁纸 alpha / 深色草稿）跟着 userBubble 走。
final class ThemeBubbleGradientTests: XCTestCase {

    private var withGradient: ThemeTokenSet {
        var tokens = ThemeTokenSet.palaceLightDefault
        tokens.userBubbleGradient = ThemeColorValue(hex: 0xE8B4A8)
        return tokens
    }

    func testDefaultsHaveNoGradient() {
        XCTAssertNil(ThemeTokenSet.palaceLightDefault.userBubbleGradient)
        XCTAssertNil(ThemeTokenSet.palaceDarkDefault.userBubbleGradient)
    }

    /// 用户机器上的老主题 JSON 没有这格：解出来必须是 nil，升级后气泡不能变样
    func testLegacyJSONWithoutKeyDecodesToNil() throws {
        let data = try JSONEncoder().encode(withGradient)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["userBubbleGradient"], "设了值编码里得有这个 key，否则下面的删 key 不成立")
        json.removeValue(forKey: "userBubbleGradient")

        let legacy = try JSONDecoder().decode(ThemeTokenSet.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.userBubbleGradient)
        XCTAssertEqual(legacy.userBubble, ThemeTokenSet.palaceLightDefault.userBubble)
    }

    func testGradientSurvivesRoundTrip() throws {
        let restored = try JSONDecoder().decode(ThemeTokenSet.self, from: try JSONEncoder().encode(withGradient))
        XCTAssertEqual(restored.userBubbleGradient?.hexString, "#E8B4A8")
    }

    /// 纯净背景覆盖 userBubble 时第二色一起清掉，不然覆盖后的灰底还带一截渐变
    func testPureBackgroundDropsGradient() {
        XCTAssertNil(withGradient.applyingPureBackground(for: .light).userBubbleGradient)
        XCTAssertNil(withGradient.applyingPureBackground(for: .dark).userBubbleGradient)
    }

    /// 壁纸下自动半透明：两端色乘同一个 alpha
    func testWallpaperAlphaAppliesToBothStops() throws {
        let light = withGradient.applyingBackgroundImageSurfaceStyle(for: .light)
        XCTAssertEqual(try XCTUnwrap(light.userBubbleGradient).alpha, 0.90, accuracy: 0.001)
        XCTAssertEqual(light.userBubble.alpha, 0.90, accuracy: 0.001)

        let dark = withGradient.applyingBackgroundImageSurfaceStyle(for: .dark)
        XCTAssertEqual(try XCTUnwrap(dark.userBubbleGradient).alpha, 0.84, accuracy: 0.001)

        XCTAssertNil(ThemeTokenSet.palaceLightDefault.applyingBackgroundImageSurfaceStyle(for: .light).userBubbleGradient)
    }

    /// 浅色生成深色草稿：设过第二色就带过去（压暗），没设保持 nil
    func testDarkDraftCarriesGradient() {
        XCTAssertNotNil(withGradient.generatingDarkDraftFromLight().userBubbleGradient)
        XCTAssertNil(ThemeTokenSet.palaceLightDefault.generatingDarkDraftFromLight().userBubbleGradient)
    }
}
