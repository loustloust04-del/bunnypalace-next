import XCTest
@testable import 记忆花园

/// M2「背景到 100%」的两把锁（plan-theme-decouple M2.1 / M2.4）。
///
/// 1. `opacityRange` 从 0.08...0.92 放开到 0...1——`normalized` 和 `resolvedOpacity` 都会 clamp，
///    以前用户拉满也只存 0.92，现在 1.0 要能原样进出。
/// 2. 新字段 `veil`（遮罩强度）是 optional，老 JSON 没有它，解出来必须是 nil 且 `resolvedVeil` == 1
///    ——1 就是改动前的遮罩强度，老主题观感零变化。
final class ThemeBackgroundStyleTests: XCTestCase {

    /// 老 JSON：只有透明度和位置，没有 veil
    private let legacyJSON = """
    {"opacity": 0.8, "offsetX": 10, "offsetY": -20}
    """

    func testLegacyJSONDecodesWithNilVeilAndFullStrength() throws {
        let style = try JSONDecoder().decode(ThemeBackgroundStyle.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(style.veil, "老主题解出来必须是 nil，否则升级后遮罩会跳变")
        XCTAssertEqual(style.resolvedVeil, 1.0, "nil = 改动前的强度")
        XCTAssertEqual(style.opacity, 0.8)
    }

    /// 透明度 1.0 / 0.0 现在要能原样存下来（以前会被 clamp 到 0.92 / 0.08）
    func testFullOpacitySurvivesNormalize() {
        XCTAssertEqual(ThemeBackgroundStyle(opacity: 1.0).normalized.opacity, 1.0)
        XCTAssertEqual(ThemeBackgroundStyle(opacity: 0.0).normalized.opacity, 0.0)
        XCTAssertEqual(ThemeBackgroundStyle(opacity: 1.0).resolvedOpacity(for: .light), 1.0)
        XCTAssertEqual(ThemeBackgroundStyle(opacity: 1.0).resolvedOpacity(for: .dark), 1.0)
    }

    /// 没设透明度时的 fallback 不受范围放开影响
    func testOpacityFallbackUnchanged() {
        XCTAssertEqual(ThemeBackgroundStyle().resolvedOpacity(for: .light), 0.36)
        XCTAssertEqual(ThemeBackgroundStyle().resolvedOpacity(for: .dark), 0.52)
    }

    /// veil = 0（要原图）是个真值，编解码后不能变回 nil；越界要 clamp
    func testVeilZeroRoundTripsAndOutOfRangeClamps() throws {
        let zero = ThemeBackgroundStyle(veil: 0)
        let restored = try JSONDecoder().decode(
            ThemeBackgroundStyle.self,
            from: try JSONEncoder().encode(zero)
        )
        XCTAssertEqual(restored.veil, 0)
        XCTAssertEqual(restored.resolvedVeil, 0)

        XCTAssertEqual(ThemeBackgroundStyle(veil: 1.5).normalized.veil, 1.0)
        XCTAssertEqual(ThemeBackgroundStyle(veil: -0.2).normalized.veil, 0.0)
    }
}
