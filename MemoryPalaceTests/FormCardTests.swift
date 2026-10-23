import XCTest
@testable import 记忆花园

/// 表单卡（card-ask 表单模式加字段类型；粟粟 10-03：提交直接发、ask_user 弹框先不动）
final class FormCardTests: XCTestCase {

    private func card(_ json: String) -> AskCard? {
        guard case .ask(let a)? = ChatCard.parse(language: "card-ask", code: json) else { return nil }
        return a
    }

    private let sample = #"""
    {"id":"q-1","question":"周末出游","fields":[
      {"label":"去哪","type":"single","options":["海边","山里","市区"],"default":"山里"},
      {"label":"带谁","type":"multi","options":["猫","狗","鱼"],"required":false},
      {"label":"哪天","type":"date","default":"2026-10-04"},
      {"label":"预算","type":"number","min":0,"max":2000,"step":50,"unit":"元","default":500},
      {"label":"想走多远","type":"slider","min":1,"max":10,"unit":"公里"},
      {"label":"备注","placeholder":"随便写","required":false}
    ]}
    """#

    // MARK: - 解析

    func testParsesTypedFields() throws {
        let a = try XCTUnwrap(card(sample))
        let f = try XCTUnwrap(a.fields)
        XCTAssertEqual(f.map(\.kind), [.single, .multi, .date, .number, .slider, .text])
        XCTAssertEqual(f[0].options, ["海边", "山里", "市区"])
        XCTAssertEqual(f[3].min, 0); XCTAssertEqual(f[3].max, 2000); XCTAssertEqual(f[3].step, 50); XCTAssertEqual(f[3].unit, "元")
        XCTAssertEqual(f.map(\.required), [true, false, true, true, true, false], "没写就是必填（和以前一样）")
        XCTAssertNil(a.problem)
    }

    func testOldTextFormsUnchanged() throws {
        let old = #"{"id":"q-2","question":"登录","fields":[{"label":"账号"},{"label":"密码","secure":true}]}"#
        let a = try XCTUnwrap(card(old))
        XCTAssertEqual(a.fields?.map(\.kind), [.text, .text])
        XCTAssertEqual(ChatCard.ask(a).blockText, ChatCard.ask(try XCTUnwrap(card(ChatCard.ask(a).blockText.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")))).blockText)
        XCTAssertFalse(ChatCard.ask(a).blockText.contains("type"), "文字项不写 type，老卡编码不变")
        XCTAssertFalse(ChatCard.ask(a).blockText.contains("required"))
    }

    func testUnknownTypeFallsBackToText() throws {
        let a = try XCTUnwrap(card(#"{"question":"x","fields":[{"label":"颜色","type":"color"}]}"#))
        XCTAssertEqual(a.fields?.first?.kind, .text)
    }

    func testProblems() {
        XCTAssertEqual(card(#"{"question":"x","fields":[{"label":"a","type":"single","options":["只有一个"]}]}"#)?.problem,
                       "「a」的选项要 2–12 个")
        XCTAssertEqual(card(#"{"question":"x","fields":[{"label":"a","type":"slider","min":5}]}"#)?.problem,
                       "「a」的滑块要写最小和最大值")
        XCTAssertEqual(card(#"{"question":"x","fields":[{"label":"a","type":"number","min":9,"max":1}]}"#)?.problem,
                       "「a」的最小值要比最大值小")
    }

    // MARK: - 初始值（默认 / 已答）

    func testInitialValuesFromDefaults() throws {
        let f = try XCTUnwrap(card(sample)?.fields)
        let today = "2026-10-03"
        XCTAssertEqual(f[0].initialValue(today: today), .picked([1]), "默认按选项文字对上")
        XCTAssertEqual(f[1].initialValue(today: today), .picked([]))
        XCTAssertEqual(f[2].initialValue(today: today), .text("2026-10-04"))
        XCTAssertEqual(f[3].initialValue(today: today), .text("500"))
        XCTAssertEqual(f[4].initialValue(today: today), .text("1"), "滑块没默认从最小值起")
        XCTAssertEqual(f[5].initialValue(today: today), .text(""))
        let todayField = try XCTUnwrap(card(#"{"question":"x","fields":[{"label":"d","type":"date","default":"today"}]}"#)?.fields?.first)
        XCTAssertEqual(todayField.initialValue(today: today), .text(today))
    }

    // MARK: - 校验

    func testValidation() throws {
        let f = try XCTUnwrap(card(sample)?.fields)
        XCTAssertEqual(f[0].problem(for: .picked([])), "必填")
        XCTAssertNil(f[1].problem(for: .picked([])), "选填的多选可以一个都不选")
        XCTAssertEqual(f[3].problem(for: .text("abc")), "要填数字")
        XCTAssertEqual(f[3].problem(for: .text("3000")), "要在 0–2000 之间")
        XCTAssertNil(f[3].problem(for: .text("1500")))
        XCTAssertEqual(f[2].problem(for: .text("下周")), "日期格式不对")
        XCTAssertNil(f[5].problem(for: .text("")), "选填的文字可以空")
        XCTAssertEqual(f[0].problem(for: .picked([0, 1])), "只能选一个")
    }

    // MARK: - 写回

    func testFillingWritesTypedAnswers() throws {
        let a = try XCTUnwrap(card(sample))
        let filled = a.filling(values: [.picked([2]), .picked([0, 2]), .text("2026-10-05"), .text("800"), .text("3"), .text("")])
        let f = try XCTUnwrap(filled.fields)
        XCTAssertEqual(f[0].picked, [2]); XCTAssertNil(f[0].answer)
        XCTAssertEqual(f[1].picked, [0, 2])
        XCTAssertEqual(f[2].answer, "2026-10-05")
        XCTAssertEqual(f[3].answer, "800")
        XCTAssertNil(f[5].answer, "空的选填项不写")
        let block = ChatCard.ask(filled).blockText
        XCTAssertTrue(block.contains("\"picked\":[2]"))
        XCTAssertEqual(try XCTUnwrap(card(String(block.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")))), filled, "写回的版本能原样读回")
    }

    func testNumberFormatting() {
        XCTAssertEqual(AskCard.Field.format(500), "500")
        XCTAssertEqual(AskCard.Field.format(2.5), "2.5")
    }

    // MARK: - 给模型的说明

    func testGuideMentionsFieldTypes() {
        let text = ChatCardPromptGuide.text
        for word in ["\"type\"", "single", "multi", "date", "number", "slider", "required"] {
            XCTAssertTrue(text.contains(word), "说明里要有 \(word)")
        }
    }
}
