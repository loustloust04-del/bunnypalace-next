import XCTest
@testable import 记忆花园

/// thinking 回传 §3.7：检查器「上一次真实发出」的思考参数行、回传块数、签名缩写（复制保留原文）
final class ThinkingInspectorTests: XCTestCase {

    private func json(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    func testThinkingLineDefaultTier() {
        let body = json(["model": "claude-opus-5-5", "max_tokens": 36864, "thinking": ["type": "adaptive", "display": "summarized"],
                         "messages": [["role": "user", "content": "hi"]]])
        XCTAssertEqual(SentRequestBodyView.thinkingLine(body), "思考：adaptive · 摘要 · effort 默认(medium) · max_tokens 36864")
    }

    func testThinkingLineSecondRequestCountsEchoedBlocks() {
        let body = json(["model": "claude-opus-5-5", "max_tokens": 26000, "thinking": ["type": "adaptive"], "output_config": ["effort": "high"],
                         "messages": [["role": "user", "content": "hi"],
                                      ["role": "assistant", "content": [["type": "thinking", "thinking": "", "signature": "s"],
                                                                        ["type": "redacted_thinking", "data": "E"],
                                                                        ["type": "tool_use", "id": "t", "name": "x", "input": [String: Any]()]]],
                                      ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "r"]]]]])
        XCTAssertEqual(SentRequestBodyView.thinkingLine(body), "思考：adaptive · 不要摘要 · effort high · max_tokens 26000 · 回传思考块 2 个")
    }

    func testThinkingLineAbsentForPlainBodies() {
        XCTAssertNil(SentRequestBodyView.thinkingLine(json(["model": "gpt-4o", "max_tokens": 16384, "messages": [[String: Any]]()])))
        XCTAssertEqual(SentRequestBodyView.thinkingLine(json(["model": "claude-sonnet-4-5", "max_tokens": 26000,
                                                               "thinking": ["type": "enabled", "budget_tokens": 10000], "messages": [[String: Any]]()])),
                       "思考：enabled · budget_tokens 10000 · max_tokens 26000")
    }

    func testDisplayTextShortensSignaturesButBodyKeepsThem() {
        let sig = String(repeating: "S", count: 1832)
        let body = json(["model": "m", "messages": [["role": "assistant", "content": [
            ["type": "thinking", "thinking": "想", "signature": sig],
            ["type": "redacted_thinking", "data": String(repeating: "D", count: 40)],
        ]]]])
        let shown = SentRequestBodyView.displayText(body)
        XCTAssertTrue(shown.contains("<签名 1832 字>"), shown)
        XCTAssertTrue(shown.contains("<redacted 密文 40 字>"), shown)
        XCTAssertFalse(shown.contains(sig))
        XCTAssertTrue(shown.contains("想"), "摘要文字照显示")
        XCTAssertTrue(body.contains(sig), "「复制」用的是原文")
    }
}
