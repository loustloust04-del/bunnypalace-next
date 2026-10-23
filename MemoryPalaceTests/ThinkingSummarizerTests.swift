import XCTest
@testable import 记忆花园

/// 思考一句话总结的纯函数（plan-thinking-branch §4）
final class ThinkingSummarizerTests: XCTestCase {

    func testCleanStripsPrefixQuotesAndPunctuation() {
        XCTAssertEqual(ThinkingSummarizer.clean("总结：「先列提纲再举例。」\n多余的第二行"), "先列提纲再举例")
        XCTAssertEqual(ThinkingSummarizer.clean("Summary: 确认格式"), "确认格式")
        XCTAssertEqual(ThinkingSummarizer.clean(String(repeating: "长", count: 60)).count, 40)
        XCTAssertEqual(ThinkingSummarizer.clean("   "), "")
    }

    func testFirstSentenceTakesUpToTerminator() {
        XCTAssertEqual(ThinkingSummarizer.firstSentence("用户想测 **markdown** 渲染。我应该先列提纲"), "用户想测 markdown 渲染")
        XCTAssertNil(ThinkingSummarizer.firstSentence("   "))
    }

    func testFirstSentenceTruncatesByDisplayWidth() {
        let long = String(repeating: "想", count: 30)
        let s = try! XCTUnwrap(ThinkingSummarizer.firstSentence(long))
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertEqual(s.count, 21, "20 个汉字 + 省略号")
    }

    func testAPIOnlyForFreshMessages() {
        let now = Date()
        XCTAssertTrue(ThinkingSummarizer.allowsAPI(createTime: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(ThinkingSummarizer.allowsAPI(createTime: now.addingTimeInterval(-31 * 60), now: now))
        XCTAssertFalse(ThinkingSummarizer.allowsAPI(createTime: nil, now: now))
    }
}
