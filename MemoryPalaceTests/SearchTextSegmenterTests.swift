import XCTest
@testable import 记忆花园

final class SearchTextSegmenterTests: XCTestCase {

    func testCJKAndKanaSplitPerCharacter() {
        let out = SearchTextSegmenter.segment("小岚说カタカナ")
        XCTAssertEqual(out.split(separator: " ").map(String.init), ["小", "岚", "说", "カ", "タ", "カ", "ナ"])
    }

    func testLatinWordsStayWholeAndFolded() {
        XCTAssertEqual(SearchTextSegmenter.segment("SwiftUI 键盘"), "swiftui  键  盘 ")
    }

    func testFullwidthNormalizedByNFKC() {
        XCTAssertEqual(SearchTextSegmenter.segment("ＡＢＣ１２３"), "abc123")
        XCTAssertEqual(SearchTextSegmenter.segment("ｶﾞ"), " ガ ")
    }

    func testNormalizedSharesCompatibilityAndCaseFolding() {
        XCTAssertEqual(SearchTextSegmenter.normalized("Swift V2"), "swift v2")
        XCTAssertEqual(SearchTextSegmenter.normalized("ＡＢＣ１２３ｶﾞ"), "abc123ガ")
        XCTAssertEqual(SearchTextSegmenter.normalized("㍿"), "株式会社")
    }

    func testCatalogTermsPreserveHanRunsAndStableDeduplication() {
        XCTAssertEqual(SearchTextSegmenter.catalogTerms([" 云桥城，张小明 ", "云桥城", "云", "🍎", "  "]),
                       ["云桥城", "张小明", "云", "🍎"])
        XCTAssertEqual(SearchTextSegmenter.catalogTerms(["ＡＢＣ", "abc"]), ["abc"])
    }

    func testQueryPhraseAndPrefix() {
        XCTAssertEqual(SearchTextSegmenter.ftsQuery(for: "小岚"), "\"小 岚\"*")
        XCTAssertEqual(SearchTextSegmenter.ftsQuery(for: "Swift"), "\"swift\"*")
        XCTAssertEqual(SearchTextSegmenter.ftsQuery(for: "gpt-4o"), "\"gpt-4o\"*")
    }

    func testQueryEscapesQuotesAndSyntax() {
        XCTAssertEqual(SearchTextSegmenter.ftsQuery(for: "a\"b"), "\"a b\"*")
        XCTAssertEqual(SearchTextSegmenter.ftsQuery(for: "NOT"), "\"not\"*")
        XCTAssertEqual(SearchTextSegmenter.ftsQuery(for: "x AND (y)"), "\"x and (y)\"*")
    }

    func testUnindexableQueryIsNil() {
        XCTAssertNil(SearchTextSegmenter.ftsQuery(for: "😀"))
        XCTAssertNil(SearchTextSegmenter.ftsQuery(for: "，。!?"))
        XCTAssertNil(SearchTextSegmenter.ftsQuery(for: "  "))
    }

    func testVisibleTextMatchesInConvFindRule() {
        let raw = "[thinking]内心戏[/thinking]正文"
        XCTAssertEqual(ContentCleaner.visibleText(raw, isUser: false, cached: false), "正文")
        XCTAssertEqual(ContentCleaner.visibleText(raw, isUser: true, cached: false), raw)
    }
}
