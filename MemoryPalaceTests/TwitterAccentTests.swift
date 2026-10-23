import XCTest
import SwiftUI
@testable import 记忆花园

/// 强调色的十六进制解析。用户能自己填色，非法输入必须稳稳兜住而不是画出黑块。
final class TwitterAccentTests: XCTestCase {

    func testParsesSixDigitWithHash() {
        let rgb = TwitterAccent.rgb(fromHex: "#1D9BF0")
        XCTAssertEqual(rgb?.r ?? -1, 29.0 / 255, accuracy: 0.001)
        XCTAssertEqual(rgb?.g ?? -1, 155.0 / 255, accuracy: 0.001)
        XCTAssertEqual(rgb?.b ?? -1, 240.0 / 255, accuracy: 0.001)
    }

    func testParsesWithoutHash() {
        XCTAssertNotNil(TwitterAccent.rgb(fromHex: "1D9BF0"))
    }

    func testIsCaseInsensitive() {
        let upper = TwitterAccent.rgb(fromHex: "#1D9BF0")
        let lower = TwitterAccent.rgb(fromHex: "#1d9bf0")
        XCTAssertEqual(upper?.r ?? -1, lower?.r ?? -2, accuracy: 0.0001)
    }

    func testToleratesSurroundingWhitespace() {
        XCTAssertNotNil(TwitterAccent.rgb(fromHex: "  #1D9BF0 "))
    }

    func testRejectsWrongLength() {
        XCTAssertNil(TwitterAccent.rgb(fromHex: "#1D9BF"))
        XCTAssertNil(TwitterAccent.rgb(fromHex: "#1D9BF012"))
        XCTAssertNil(TwitterAccent.rgb(fromHex: ""))
    }

    func testRejectsNonHexCharacters() {
        XCTAssertNil(TwitterAccent.rgb(fromHex: "#ZZZZZZ"))
        XCTAssertNil(TwitterAccent.rgb(fromHex: "#1D9BG0"))
    }

    func testNormalizeUppercasesAndAddsHash() {
        XCTAssertEqual(TwitterAccent.normalized("1d9bf0"), "#1D9BF0")
        XCTAssertEqual(TwitterAccent.normalized("  #1D9BF0  "), "#1D9BF0")
    }

    func testNormalizeReturnsNilForJunk() {
        XCTAssertNil(TwitterAccent.normalized("不是颜色"))
    }

    func testDefaultIsTwitterBlueAndParses() {
        // 粟粟 2026-09-21 拍板：这个子应用用推特蓝
        XCTAssertEqual(TwitterAccent.defaultHex, "#1D9BF0")
        XCTAssertNotNil(TwitterAccent.rgb(fromHex: TwitterAccent.defaultHex))
    }

    func testEveryPresetParses() {
        XCTAssertFalse(TwitterAccent.presets.isEmpty)
        for preset in TwitterAccent.presets {
            XCTAssertNotNil(TwitterAccent.rgb(fromHex: preset.hex), "预设色 \(preset.name) 解析不了")
            XCTAssertEqual(TwitterAccent.normalized(preset.hex), preset.hex, "预设色要写成规范形态")
        }
    }

    func testColorFallsBackInsteadOfGoingBlack() {
        // 用户手填了一串垃圾，不能把界面画成黑块
        XCTAssertEqual(TwitterAccent.hexOrFallback("垃圾"), TwitterAccent.defaultHex)
        XCTAssertEqual(TwitterAccent.hexOrFallback("#8ebd9f"), "#8EBD9F")
    }
}
