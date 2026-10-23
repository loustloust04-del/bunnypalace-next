#if PERSONAL_APPS
import XCTest
@testable import 记忆花园

@MainActor
final class DeathScaleSlashFilterTests: XCTestCase {
    private let pool: [CCSlashCommand] = [
        .init(name: "/clear", placeholder: "", description: "", needsTmux: false),
        .init(name: "/susuos", placeholder: "", description: "", needsTmux: false),
        .init(name: "/SusuOS Mort sans sépulture", placeholder: "", description: "", needsTmux: false),
        .init(name: "susuos-x", placeholder: "", description: "", needsTmux: false),
        .init(name: "/susu", placeholder: "", description: "", needsTmux: false),
    ]

    func testSusuosNeverListed() {
        for prefix in ["", "/", "/s", "/su", "/susu", "/susuos", "/SUSUOS", "/susuos Mort sans sépulture"] {
            let names = CCSlashCommandSuggestions.candidates(for: prefix, in: pool).map(\.name)
            XCTAssertFalse(names.contains { $0.lowercased().contains("susuos") }, "prefix=\(prefix) → \(names)")
        }
    }

    func testOtherCommandsUnaffected() {
        XCTAssertEqual(CCSlashCommandSuggestions.candidates(for: "/", in: pool).map(\.name), ["/clear", "/susu"])
        XCTAssertEqual(CCSlashCommandSuggestions.candidates(for: "/cl", in: pool).map(\.name), ["/clear"])
        XCTAssertEqual(CCSlashCommandSuggestions.candidates(for: "/susu", in: pool).map(\.name), ["/susu"])
    }

    func testTypingUnlockPhraseShowsNothing() {
        XCTAssertTrue(CCSlashCommandSuggestions.candidates(for: "/susuos Mort sans sépulture").isEmpty)
        XCTAssertTrue(CCSlashCommandSuggestions.candidates(for: "/susuos").isEmpty)
        XCTAssertEqual(CCSlashCommandSuggestions.candidates(for: "/").count, CCSlashCommand.all.count, "内置清单里本来就没有 susuos")
    }
}
#endif
