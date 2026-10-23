import XCTest
@testable import 记忆花园

final class AskUserToolTests: XCTestCase {

    private func json(_ obj: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    // MARK: - parse

    func testParseSingleQuestion() {
        let input = json(["questions": [
            ["question": "超能力选哪个?", "options": ["读心", "暂停时间", "永无 bug"]]
        ]])
        let parsed = AskUserTool.parse(inputJSON: input)
        XCTAssertEqual(parsed, [.init(question: "超能力选哪个?", options: ["读心", "暂停时间", "永无 bug"], multiSelect: false)])
    }

    func testParseMultiQuestionAndMultiSelect() {
        let input = json(["questions": [
            ["question": "Q1", "options": ["a", "b"], "multiSelect": true],
            ["question": "Q2", "options": ["c", "d", "e"]],
        ]])
        let parsed = AskUserTool.parse(inputJSON: input)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0].multiSelect, true)
        XCTAssertEqual(parsed?[1].multiSelect, false)
    }

    func testParseRejectsInvalid() {
        // 非 JSON
        XCTAssertNil(AskUserTool.parse(inputJSON: "not json"))
        // 空 questions
        XCTAssertNil(AskUserTool.parse(inputJSON: json(["questions": [] as [Any]])))
        // 5 题超上限
        let five = (1...5).map { ["question": "Q\($0)", "options": ["a", "b"]] }
        XCTAssertNil(AskUserTool.parse(inputJSON: json(["questions": five])))
        // 缺 question
        XCTAssertNil(AskUserTool.parse(inputJSON: json(["questions": [["options": ["a", "b"]]]])))
        // 选项只有 1 个
        XCTAssertNil(AskUserTool.parse(inputJSON: json(["questions": [["question": "Q", "options": ["a"]]]])))
        // 选项 7 个超上限
        XCTAssertNil(AskUserTool.parse(inputJSON: json(["questions": [["question": "Q", "options": ["1","2","3","4","5","6","7"]]]])))
        // 空白选项
        XCTAssertNil(AskUserTool.parse(inputJSON: json(["questions": [["question": "Q", "options": ["a", "  "]]]])))
    }

    // MARK: - resultText

    func testResultTextSingle() {
        let qs = [AskUserTool.ParsedQuestion(question: "超能力?", options: ["读心", "暂停"], multiSelect: false)]
        XCTAssertEqual(AskUserTool.resultText(questions: qs, answers: ["暂停"]),
                       "Q: 超能力?\nA: 暂停")
    }

    func testResultTextMultiWithSkipAndFreeText() {
        let qs = [
            AskUserTool.ParsedQuestion(question: "Q1", options: ["a", "b"], multiSelect: false),
            AskUserTool.ParsedQuestion(question: "Q2", options: ["c", "d"], multiSelect: false),
        ]
        let text = AskUserTool.resultText(questions: qs, answers: ["自由输入的答案", nil])
        XCTAssertEqual(text, "Q: Q1\nA: 自由输入的答案\n\nQ: Q2\nA: \(AskUserTool.skippedAnswer)")
    }

    // MARK: - 双家 schema 渲染

    func testSchemaRendersBothFamilies() {
        let d = AskUserTool.definition
        let openAI = ToolSchemaRenderer.openAI(d)
        XCTAssertEqual(openAI["type"] as? String, "function")
        let fn = openAI["function"] as! [String: Any]
        XCTAssertEqual(fn["name"] as? String, "ask_user")
        let params = fn["parameters"] as! [String: Any]
        XCTAssertNotNil((params["properties"] as! [String: Any])["questions"])
        XCTAssertEqual(params["required"] as? [String], ["questions"])

        let anthropic = ToolSchemaRenderer.anthropic(d)
        XCTAssertEqual(anthropic["name"] as? String, "ask_user")
        let schema = anthropic["input_schema"] as! [String: Any]
        XCTAssertNotNil((schema["properties"] as! [String: Any])["questions"])
    }
}
