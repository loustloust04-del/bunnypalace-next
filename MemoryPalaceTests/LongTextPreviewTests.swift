import XCTest
@testable import 记忆花园

/// A2：长文本行内预览——跳空行取前几行、字数、空白算空
final class LongTextPreviewTests: XCTestCase {

    func testExcerptSkipsBlankLinesAndTakesFirstLines() {
        let text = "\n\n  第一行  \n\n第二行\r\n第三行\n\n第四行\n第五行\n"
        XCTAssertEqual(LongTextPreview.excerpt(text), "第一行\n第二行\n第三行\n第四行")
        XCTAssertEqual(LongTextPreview.excerpt(text, maxLines: 2), "第一行\n第二行")
    }

    func testExcerptOfWhitespaceIsEmpty() {
        XCTAssertEqual(LongTextPreview.excerpt(""), "")
        XCTAssertEqual(LongTextPreview.excerpt(" \n\t\n "), "")
    }

    func testExcerptOnlyScansHead() {
        let text = String(repeating: "长", count: 5000) + "\n尾巴"
        let excerpt = LongTextPreview.excerpt(text)
        XCTAssertFalse(excerpt.contains("尾巴"))
        XCTAssertEqual(excerpt.count, 2000)
    }

    func testCountLabel() {
        XCTAssertEqual(LongTextPreview.countLabel(""), "")
        XCTAssertEqual(LongTextPreview.countLabel("  \n "), "")
        XCTAssertEqual(LongTextPreview.countLabel("你好，世界"), "5 字")
        XCTAssertEqual(LongTextPreview.countLabel("👩‍👩‍👧 a\n"), "4 字")
    }
}
