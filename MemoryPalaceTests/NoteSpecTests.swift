import XCTest
@testable import 记忆花园

/// 便利贴样式编进 noteStyle 字符串（不改表）：新格式往返、旧四种值照认、坏值兜底。
final class NoteSpecTests: XCTestCase {
    func testRoundTrip() {
        for kind in NoteKind.allCases {
            for font in NoteFont.allCases {
                let spec = NoteSpec(kind: kind, color: kind.colors.last, font: font)
                XCTAssertEqual(NoteSpec(raw: spec.raw), spec, spec.raw)
            }
        }
    }

    func testLegacyValues() {
        XCTAssertEqual(NoteSpec(raw: "yellow_square"), NoteSpec(kind: .sticky, color: "#fff1a8", font: .system))
        XCTAssertEqual(NoteSpec(raw: "pink_rounded"), NoteSpec(kind: .sticky, color: "#ffd6dc", font: .system))
        XCTAssertEqual(NoteSpec(raw: "glass").kind, .vellum)
        XCTAssertEqual(NoteSpec(raw: "torn_paper").kind, .torn)
        XCTAssertEqual(NoteSpec(raw: nil).kind, .sticky)
    }

    func testGarbageFallsBack() {
        let s = NoteSpec(raw: "nope|zz|??")
        XCTAssertEqual(s.kind, .sticky)
        XCTAssertEqual(s.font, .system)
        XCTAssertEqual(s.color, NoteKind.sticky.colors.first)
        // 没有配色的纸不带颜色
        XCTAssertNil(NoteSpec(raw: "kraft|#ffffff|hand").color)
    }
}
