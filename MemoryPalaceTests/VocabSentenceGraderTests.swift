import XCTest
@testable import 记忆花园

/// 造句判分响应解析：严格 JSON / markdown 围栏包裹 / 垃圾输入兜底。
final class VocabSentenceGraderTests: XCTestCase {

    func testParseStrictJSON() {
        let r = VocabSentenceGrader.parse(#"{"ok": true, "feedback": "用得很自然"}"#)
        XCTAssertEqual(r?.ok, true)
        XCTAssertEqual(r?.feedback, "用得很自然")
    }

    func testParseFencedJSON() {
        let raw = """
        ```json
        {"ok": false, "feedback": "brazen 是形容词，不能当动词用"}
        ```
        """
        let r = VocabSentenceGrader.parse(raw)
        XCTAssertEqual(r?.ok, false)
        XCTAssertEqual(r?.feedback, "brazen 是形容词，不能当动词用")
    }

    func testParseJSONEmbeddedInProse() {
        let r = VocabSentenceGrader.parse(#"好的，这是判分：{"ok": true, "feedback": "正确"} 以上。"#)
        XCTAssertEqual(r?.ok, true)
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(VocabSentenceGrader.parse("这个句子写得不错哦"))
        XCTAssertNil(VocabSentenceGrader.parse(""))
        XCTAssertNil(VocabSentenceGrader.parse(#"{"missing": "fields"}"#))
    }

    func testBuildRequestContainsWordAndSentence() {
        let req = VocabSentenceGrader.buildRequest(
            word: "ephemeral", definition: "短暂的", sentence: "Fame is ephemeral.")
        XCTAssertTrue(req.messages[0].content.contains("ephemeral"))
        XCTAssertTrue(req.messages[0].content.contains("Fame is ephemeral."))
        XCTAssertTrue(req.systemPrompt.contains("JSON"))
    }
}
