import XCTest
@testable import MemoryCore

/// A2 接进试写台：「现行」配方渲染出来必须和正式写手逐字相同；检查 / 自动判按正式写手的口径。全虚构
final class MemoryBenchA2WriterTests: XCTestCase {
    private let writer = MemoryBenchA2Writer()

    private func input(persona: String = "", tail: Bool = false, previous: Bool = false) -> MemoryBenchA2Writer.Input {
        MemoryBenchA2Writer.Input(
            names: .init(user: "岚舟", char: "星砚"), persona: persona, tail: tail,
            previous: previous ? .init(title: "定灯塔航线三轮规则", story: "定了一局三轮。", quotes: "岚舟：「三轮可以」", keywords: ["灯塔航线"]) : nil,
            messages: [.init(role: "user", content: "模型船的船帆又掉了"), .init(role: "assistant", content: "试试白乳胶，薄涂。")])
    }

    private func prompt(_ input: MemoryBenchA2Writer.Input) throws -> MemoryBenchPrompt {
        let testCase = try MemoryBenchA2Writer.makeCase(id: "t", title: "t", input: input)
        return try writer.prompt(for: testCase, recipe: writer.builtInRecipes(defaults: .standard)[0])
    }

    func testCurrentRecipeRendersProductionPromptForEveryShape() throws {
        for persona in ["", "你是星砚，岚舟的恋人。"] {
            for tail in [false, true] {
                for previous in [false, true] {
                    let input = input(persona: persona, tail: tail, previous: previous)
                    let speakers = SessionSegmentWriter.Speakers(userName: "岚舟", assistantName: "星砚")
                    let kind: SessionSegment.Kind = tail ? .closeout : .rolling
                    let rendered = try prompt(input)
                    XCTAssertEqual(rendered.system, SessionSegmentWriter.systemPrompt(persona: persona, speakers: speakers, kind: kind),
                                   "persona=\(!persona.isEmpty) tail=\(tail)")
                    XCTAssertEqual(rendered.user,
                                   SessionSegmentWriter.userContent(messages: MemoryBenchA2Writer.messages(input, caseId: "t"),
                                                                    speakers: speakers, previous: MemoryBenchA2Writer.previous(input), kind: kind),
                                   "previous=\(previous)")
                }
            }
        }
    }

    func testEmptyNamesFallBackLikeProduction() throws {
        var input = input()
        input.names = .init(user: " ", char: "")
        let speakers = SessionSegmentWriter.Speakers(userName: " ", assistantName: "")
        XCTAssertEqual(try prompt(input).system, SessionSegmentWriter.systemPrompt(persona: "", speakers: speakers, kind: .rolling))
    }

    func testTemplateKeepsOnlyTheThreeCaseDependentPlaceholders() {
        let template = MemoryBenchA2Writer.currentTemplate()
        XCTAssertTrue(template.hasPrefix("{{人设块}}{{任务说明}}"))
        XCTAssertFalse(MemoryBenchA2Writer.taskNote(tail: false).isEmpty)
        XCTAssertNotEqual(MemoryBenchA2Writer.taskNote(tail: false), MemoryBenchA2Writer.taskNote(tail: true))
        let rest = template.replacingOccurrences(of: "{{人设块}}", with: "").replacingOccurrences(of: "{{任务说明}}", with: "")
            .replacingOccurrences(of: "{{称呼}}", with: "")
        XCTAssertFalse(rest.contains("{{"))
    }

    private static let good = """
    标题：模型船定双帆
    【经过】岚舟试了三次粘船帆，第三次粘住，定了双帆。
    【原话】岚舟：「模型船的船帆又掉了」
    我：「试试白乳胶，薄涂。」
    【关键词】模型船，双帆
    【待续】周末上色
    """

    func testGoodOutputParsesIntoOneItemWithFields() throws {
        let testCase = try MemoryBenchA2Writer.makeCase(id: "t", title: "t", input: input())
        let parsed = writer.parse(output: Self.good, testCase: testCase, recipe: writer.builtInRecipes(defaults: .standard)[0])
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.items[0].fields["title"], "模型船定双帆")
        XCTAssertEqual(parsed.items[0].fields["keywords"], "模型船，双帆")
        XCTAssertEqual(parsed.items[0].fields["pending"], "周末上色")
        XCTAssertTrue(parsed.checks.allSatisfy(\.passed), "\(parsed.checks)")
    }

    func testHardCheckFailsOnMissingBlockAndUserAddress() throws {
        let testCase = try MemoryBenchA2Writer.makeCase(id: "t", title: "t", input: input())
        let recipe = writer.builtInRecipes(defaults: .standard)[0]
        let missing = writer.parse(output: "标题：模型船\n【经过】粘了船帆。", testCase: testCase, recipe: recipe)
        XCTAssertEqual(missing.checks.first?.passed, false)
        XCTAssertEqual(missing.checks.first?.hard, true)
        let address = writer.parse(output: Self.good.replacingOccurrences(of: "岚舟试了", with: "用户说试了"), testCase: testCase, recipe: recipe)
        XCTAssertEqual(address.checks.first?.passed, false)
    }

    func testSoftChecksFlagInventedQuoteAndLongTitle() throws {
        let testCase = try MemoryBenchA2Writer.makeCase(id: "t", title: "t", input: input())
        let raw = Self.good.replacingOccurrences(of: "「试试白乳胶，薄涂。」", with: "「我从来没说过这句」")
            .replacingOccurrences(of: "标题：模型船定双帆", with: "标题：我们一起讨论了很久很久的模型船船帆方案")
        let parsed = writer.parse(output: raw, testCase: testCase, recipe: writer.builtInRecipes(defaults: .standard)[0])
        XCTAssertEqual(parsed.checks.first?.passed, true)
        let soft = parsed.checks.filter { !$0.hard }.map(\.name)
        XCTAssertTrue(soft.contains { $0.contains("原话") && $0.contains("1 / 2") }, "\(soft)")
        XCTAssertTrue(soft.contains { $0.contains("标题超过") }, "\(soft)")
        XCTAssertTrue(soft.contains { $0.contains("代词开头") }, "\(soft)")
    }

    func testSoftCheckFlagsThirdPersonSelfButNotInsideQuotes() throws {
        let testCase = try MemoryBenchA2Writer.makeCase(id: "t", title: "t", input: input())
        let recipe = writer.builtInRecipes(defaults: .standard)[0]
        let third = writer.parse(output: Self.good.replacingOccurrences(of: "我：「试试", with: "星砚：「试试"), testCase: testCase, recipe: recipe)
        XCTAssertTrue(third.checks.contains { !$0.passed && $0.name.contains("星砚") }, "\(third.checks)")
        let quoted = writer.parse(output: Self.good.replacingOccurrences(of: "「模型船的船帆又掉了」", with: "「星砚，模型船的船帆又掉了」"),
                                  testCase: testCase, recipe: recipe)
        XCTAssertFalse(quoted.checks.contains { $0.name.contains("没用「我」") }, "\(quoted.checks)")
    }

    func testAutoJudgeGivesEveryLabelAVerdict() throws {
        let labels = [
            MemoryBenchLabel(id: "y1", kind: MemoryBenchLabel.shouldHave, text: "定双帆", keys: ["双帆"], from: "t"),
            MemoryBenchLabel(id: "y2", kind: MemoryBenchLabel.shouldHave, text: "约雾岛", keys: ["雾岛"], from: "t"),
            MemoryBenchLabel(id: "n1", kind: MemoryBenchLabel.shouldNotHave, text: "报错", keys: ["超时"], from: "t"),
            MemoryBenchLabel(id: "n2", kind: MemoryBenchLabel.shouldNotHave, text: "白乳胶", keys: ["白乳胶"], from: "t"),
        ]
        let testCase = try MemoryBenchA2Writer.makeCase(id: "t", title: "t", input: input(), labels: labels)
        let items = writer.parse(output: Self.good, testCase: testCase, recipe: writer.builtInRecipes(defaults: .standard)[0]).items
        let verdicts = Dictionary(uniqueKeysWithValues: writer.autoJudge(items: items, labels: labels).map { ($0.labelId, $0.verdict) })
        XCTAssertEqual(verdicts, ["y1": .right, "y2": .wrong, "n1": .right, "n2": .wrong])
        // 同一格的判断下标互不相同（`effectiveJudgments` 按 cellId#item 去重）
        XCTAssertEqual(Set(writer.autoJudge(items: items, labels: labels).map(\.item)).count, labels.count)
    }
}
