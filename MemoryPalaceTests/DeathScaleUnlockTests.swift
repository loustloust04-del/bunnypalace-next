#if PERSONAL_APPS
import XCTest
@testable import 记忆花园

final class DeathScaleUnlockTests: XCTestCase {
    func testExactPhrase() {
        XCTAssertTrue(DeathScaleUnlock.matches("/susuos Mort sans sépulture"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(DeathScaleUnlock.matches("/Susuos mort SANS Sépulture"))
        XCTAssertTrue(DeathScaleUnlock.matches("/SUSUOS MORT SANS SÉPULTURE"))
    }

    func testAccentInsensitive() {
        XCTAssertTrue(DeathScaleUnlock.matches("/susuos Mort sans sepulture"))
        XCTAssertTrue(DeathScaleUnlock.matches("/susuos Mort sans se\u{301}pulture"), "组合重音也认")
    }

    func testWhitespaceCollapsed() {
        XCTAssertTrue(DeathScaleUnlock.matches("/susuos   Mort  sans\tsépulture"))
        XCTAssertTrue(DeathScaleUnlock.matches("/susuos Mort\nsans sépulture"))
    }

    func testLeadingTrailingWhitespace() {
        XCTAssertTrue(DeathScaleUnlock.matches("  /susuos Mort sans sépulture \n"))
    }

    func testPartialDoesNotMatch() {
        XCTAssertFalse(DeathScaleUnlock.matches("/susuos"))
        XCTAssertFalse(DeathScaleUnlock.matches("/susuos Mort sans"))
        XCTAssertFalse(DeathScaleUnlock.matches("susuos Mort sans sépulture"), "少了斜杠不算")
        XCTAssertFalse(DeathScaleUnlock.matches("Mort sans sépulture"))
        XCTAssertFalse(DeathScaleUnlock.matches(""))
    }

    func testExtraWordDoesNotMatch() {
        XCTAssertFalse(DeathScaleUnlock.matches("/susuos Mort sans sépulture encore"))
        XCTAssertFalse(DeathScaleUnlock.matches("hi /susuos Mort sans sépulture"))
        XCTAssertFalse(DeathScaleUnlock.matches("/susuos Mort sans sépultures"))
    }
}
#endif
