@testable import MemoryCore
import XCTest

/// 试写台模板（plan-memory-audit-home-trial 3.3）：只有变量 / 如果 / 每三种写法，其余一字不动；写错带行号
final class PromptTemplateTests: XCTestCase {

    private func render(_ source: String, _ vars: [String: MemoryBenchValue] = [:]) throws -> String {
        try PromptTemplate(source).render(vars)
    }

    private func problems(_ source: String, _ vars: [String: MemoryBenchValue] = [:]) -> [PromptTemplate.Problem] {
        do {
            _ = try render(source, vars)
            return []
        } catch let f as PromptTemplate.Failure {
            return f.problems
        } catch {
            XCTFail("不是 Failure：\(error)")
            return []
        }
    }

    func testPlainTextIsUntouched() throws {
        let text = "只输出一个 JSON：{\"fragments\":[{\"msg\":3}]}\n嵌套 {\"a\":{\"b\":1}}\n\n  末尾空格  \n"
        XCTAssertEqual(try render(text), text, "没有 {{ 的地方逐字不变（JSON 的单花括号、}}、换行、空格）")
    }

    func testVariables() throws {
        let vars: [String: MemoryBenchValue] = ["称呼": .text("岚舟"), "条数": .number(6), "是尾段": .flag(true), "上一段.标题": .text("搬家")]
        XCTAssertEqual(try render("{{称呼}}说了 {{条数}} 条，尾段：{{是尾段}}，上一段《{{ 上一段.标题 }}》", vars),
                       "岚舟说了 6 条，尾段：是，上一段《搬家》")
    }

    func testConditionals() throws {
        let tpl = "{{#如果 段数 <= 8}}全文{{否则}}只给标题{{/如果}}"
        XCTAssertEqual(try render(tpl, ["段数": .number(8)]), "全文")
        XCTAssertEqual(try render(tpl, ["段数": .number(9)]), "只给标题")
        let list: MemoryBenchValue = .list(Array(repeating: [:], count: 9))
        XCTAssertEqual(try render(tpl, ["段数": list]), "只给标题", "一组按份数比")
        XCTAssertEqual(try render("{{#如果 有上一段}}有{{/如果}}", ["有上一段": .flag(false)]), "", "没有否则：假就什么都不出")
        XCTAssertEqual(try render("{{#如果 不 有上一段}}第一段{{/如果}}", ["有上一段": .flag(false)]), "第一段")
        XCTAssertEqual(try render("{{#如果 上一段.标题}}有标题{{否则}}空{{/如果}}", ["上一段.标题": .text("")]), "空", "空字 = 假")
        XCTAssertEqual(try render("{{#如果 x != 0}}非零{{/如果}}{{#如果 x = 0}}零{{/如果}}", ["x": .number(0)]), "零")
    }

    func testEachWithIndexAndOuterScope() throws {
        let segs: MemoryBenchValue = .list([["标题": .text("搬家")], ["标题": .text("看病")]])
        let tpl = "窗口「{{窗口}}」{{#每 段}}\n〔{{序号}}〕{{标题}}·{{窗口}}{{#如果 是最后一个}}。{{否则}}；{{/如果}}{{/每}}"
        XCTAssertEqual(try render(tpl, ["窗口": .text("周末"), "段": segs]), "窗口「周末」\n〔1〕搬家·周末；\n〔2〕看病·周末。")
        XCTAssertEqual(try render("[{{#每 段}}x{{/每}}]", ["段": .list([])]), "[]", "空组什么都不出")
        XCTAssertEqual(try render("{{#每 段}}{{#如果 是第一个}}首{{/如果}}{{标题}}{{/每}}", ["段": segs]), "首搬家看病")
    }

    func testProblemsCarryLineNumbers() {
        XCTAssertEqual(problems("第一行\n第二行\n{{不存在}}"), [.init(line: 3, message: "不认识变量「不存在」")])
        XCTAssertEqual(problems("{{a}}\n{{b}}").map(\.line), [1, 2], "所有不认识的都列出来，不只第一个")
        XCTAssertEqual(problems("\n{{#如果 a}}没收尾").first?.line, 2)
        XCTAssertEqual(problems("{{/如果}}").count, 1)
        XCTAssertEqual(problems("{{否则}}").count, 1, "否则在如果外面")
        XCTAssertEqual(problems("{{#如果 a}}1{{否则}}2{{否则}}3{{/如果}}", ["a": .flag(true)]).count, 1, "否则只能一个")
        XCTAssertEqual(problems("{{#如果 a <= x}}{{/如果}}", ["a": .number(1)]).count, 1, "右边要是整数")
        XCTAssertEqual(problems("{{#每}}{{/每}}").count, 1, "每要写组名")
        XCTAssertEqual(problems("{{#每 段}}没收尾", ["段": .list([])]).count, 1)
        XCTAssertEqual(problems("{{#循环 段}}{{/循环}}").count, 1, "块只有如果 / 每")
        XCTAssertEqual(problems("{{两个 词}}").count, 1, "变量名里不能有空格")
        XCTAssertEqual(problems("开头 {{没收"), [.init(line: 1, message: "「{{」没有配上「}}」")])
        XCTAssertEqual(problems("{{段}}", ["段": .list([])]).first?.message, "「段」是一组，要用「{{#每 段}}…{{/每}}」")
        XCTAssertEqual(problems("{{#每 段}}{{/每}}", ["段": .text("x")]).count, 1, "不是一组不能每")
        XCTAssertEqual(problems("{{#如果 不存在}}{{/如果}}").count, 1, "条件里的变量也要认识")
    }

    func testFailureMessageIsReadable() {
        XCTAssertEqual(PromptTemplate.Failure(problems: [.init(line: 2, message: "不认识变量「x」")]).localizedDescription,
                       "第 2 行：不认识变量「x」")
    }
}
