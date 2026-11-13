import MemoryCore
import XCTest
@testable import 记忆花园

/// C2 接进试写台：「现行」配方渲染和正式 C2 逐字相同；解析 / 检查用正式那套；自动配标签
final class MemoryBenchC2Tests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!
    private let writer = MemoryBenchC2Writer()

    override func setUp() {
        super.setUp()
        suite = "xctest-bench-c2-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var probe: MemoryBenchSet {
        get throws { try XCTUnwrap(MemoryBenchStore.builtInSets().first { $0.id == "c2-probe" }) }
    }

    /// 正式 C2 一次调用送出去的那份（`FragmentPool.run` 的拼法）
    private func production(_ c: MemoryBenchCase, defaults: UserDefaults) throws -> MemoryBenchPrompt {
        let input = try MemoryBenchC2Writer.input(c)
        let messages = try MemoryBenchC2Writer.messages(input, caseId: c.id)
        let names = MemoryBenchC2Writer.names(input)
        return MemoryBenchPrompt(system: FragmentPool.systemPrompt(names: names, defaults: defaults, day: messages.last?.date.map { MemoryDay.key($0) }),
                                 user: FragmentPool.userContent(messages, names: names))
    }

    // MARK: - 「现行」逐字相同

    func testCurrentRecipeRendersExactlyLikeProductionC2() throws {
        let recipes = writer.builtInRecipes(defaults: defaults)
        XCTAssertEqual(recipes.map(\.id), [MemoryBenchC2Writer.currentRecipeId], "没自定义只有「现行」")
        for c in try probe.cases {
            XCTAssertEqual(try writer.prompt(for: c, recipe: recipes[0]), try production(c, defaults: defaults), "用例 \(c.id)")
        }
    }

    func testEmptyNamesFallBackLikeProduction() throws {
        let c = try MemoryBenchC2Writer.makeCase(id: "x", title: "t", messages: [
            .init(id: "1", role: "user", content: "我乳糖不耐", date: nil),
        ], userName: " ", assistantName: "")
        let recipe = writer.builtInRecipes(defaults: defaults)[0]
        XCTAssertEqual(try writer.prompt(for: c, recipe: recipe), try production(c, defaults: defaults), "称呼空 =「用户」，没日期 = 今天")
    }

    /// astra zd2 #3：有自定义时，第一份「现行」就是正式 C2 实际用的那份（模板 + 参数都跟它），默认模板另列一份候选
    func testCurrentRecipeFollowsTheCustomTemplateWhenThereIsOne() throws {
        let custom = "只填表。{{USER_NAME}} 和 {{CHAR_NAME}}，那天 {{DATE}}。"
        defaults.set(custom, forKey: FragmentPool.customPromptKey)
        let recipes = writer.builtInRecipes(defaults: defaults)
        XCTAssertEqual(recipes.map(\.id), [MemoryBenchC2Writer.currentRecipeId, MemoryBenchC2Writer.defaultRecipeId])
        XCTAssertEqual(recipes[0].params[MemoryBenchC2Writer.requireAttributionParam], .bool(false), "旧自定义不要求 subject / speaker，同正式 C2")
        XCTAssertEqual(recipes[1].params[MemoryBenchC2Writer.requireAttributionParam], .bool(true))
        for c in try probe.cases {
            XCTAssertEqual(try writer.prompt(for: c, recipe: recipes[0]), try production(c, defaults: defaults), "用例 \(c.id)：现行 = 实际生效的")
        }
        let empty = try XCTUnwrap(UserDefaults(suiteName: "\(suite)-empty"))
        defer { UserDefaults().removePersistentDomain(forName: "\(suite)-empty") }
        XCTAssertEqual(try writer.prompt(for: try probe.cases[0], recipe: recipes[1]), try production(try probe.cases[0], defaults: empty),
                       "第二份是默认模板")
    }

    /// astra zd2 #10：末条没日期时，「这一截最后一天」在建用例那一刻冻结，以后哪天跑都一样；日期看不懂就报错
    func testDayIsFrozenWhenCaseIsMadeAndBadDatesThrow() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let made = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 21))!
        let c = try MemoryBenchC2Writer.makeCase(id: "nodate", title: "t", messages: [
            .init(id: "1", role: "user", content: "下周三复诊", date: nil),
        ], userName: "岚舟", assistantName: "星砚", now: made)
        XCTAssertEqual(try MemoryBenchC2Writer.input(c).day, "2026-10-12")
        let recipe = writer.builtInRecipes(defaults: defaults)[0]
        XCTAssertTrue(try writer.prompt(for: c, recipe: recipe).system.contains("2026-10-12"), "跑的那天不是建用例那天，日期也不变")

        func withInput(_ edit: (inout MemoryBenchC2Writer.Input) -> Void) throws -> MemoryBenchCase {
            var input = try MemoryBenchC2Writer.input(c)
            edit(&input)
            var out = c
            out.input = try .from(input)
            return out
        }
        XCTAssertThrowsError(try writer.prompt(for: try withInput { $0.day = nil }, recipe: recipe), "没日期也没冻结的 day：报错，不换成今天")
        XCTAssertThrowsError(try writer.prompt(for: try withInput { $0.day = "10/12" }, recipe: recipe))
        XCTAssertThrowsError(try writer.prompt(for: try withInput { $0.messages[0].date = "昨天晚上" }, recipe: recipe)) {
            XCTAssertEqual($0 as? MemoryBenchC2Writer.InputError, .badDate(index: 1, value: "昨天晚上"))
        }
    }

    // MARK: - 用例

    func testMakeCaseFreezesMessages() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let at = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 21, minute: 30))!
        let messages: [FragmentPool.Message] = [
            .init(id: "a", role: "user", content: "我每周六去半盏", date: at),
            .init(id: "b", role: "assistant", content: "好地方", date: nil),
        ]
        let c = try MemoryBenchC2Writer.makeCase(id: "real-1", title: "真对话", messages: messages, userName: "岚舟", assistantName: "星砚")
        let back = try MemoryBenchC2Writer.messages(try MemoryBenchC2Writer.input(c), caseId: c.id)
        XCTAssertEqual(back.map(\.content), messages.map(\.content))
        XCTAssertEqual(back.map(\.role), ["user", "assistant"])
        XCTAssertEqual(back[0].date, at, "按分钟存，本机时区")
        XCTAssertNil(back[1].date)
    }

    // MARK: - 解析 / 检查

    private func card(_ msg: Int, _ content: String, category: String = "fact", subject: String = "岚舟") -> String {
        #"{"msg":\#(msg),"content":"\#(content)","tags":["半盏"],"importance":3,"emotion":0,"resolved":null,"category":"\#(category)","subject":"\#(subject)","speaker":"用户自述"}"#
    }

    func testParseGoodBatch() throws {
        let c = try probe.cases[7]
        let out = #"{"fragments":["# + card(3, "岚舟每周六下午去旧书店半盏看书") + "," + card(3, "岚舟害怕水") + "]}"
        let parsed = writer.parse(output: out, testCase: c, recipe: writer.builtInRecipes(defaults: defaults)[0])
        XCTAssertEqual(parsed.items.map(\.text), ["岚舟每周六下午去旧书店半盏看书", "岚舟害怕水"])
        XCTAssertEqual(parsed.items[0].fields["subject"], "岚舟")
        XCTAssertEqual(parsed.items[0].fields["tags"], "半盏")
        XCTAssertTrue(parsed.checks.allSatisfy(\.passed))
    }

    func testParseRejectedCardsAndBrokenBatch() throws {
        let c = try probe.cases[0]
        let recipe = writer.builtInRecipes(defaults: defaults)[0]
        let out = #"{"fragments":["# + card(3, "岚舟乳糖不耐") + "," + card(3, "坏卡", category: "瞎写") + "]}"
        let parsed = writer.parse(output: out, testCase: c, recipe: recipe)
        XCTAssertEqual(parsed.items.count, 1, "合格的照收")
        let cards = try XCTUnwrap(parsed.checks.first { $0.name == "每张卡都合格" })
        XCTAssertFalse(cards.passed)
        XCTAssertTrue(cards.hard)
        XCTAssertTrue(cards.detail?.contains("category") == true, cards.detail ?? "")

        let broken = writer.parse(output: "好的，这是结果：{}", testCase: c, recipe: recipe)
        XCTAssertTrue(broken.items.isEmpty)
        XCTAssertEqual(broken.checks.count, 1)
        XCTAssertFalse(broken.checks[0].passed)
        XCTAssertNotNil(broken.checks[0].detail, "整包不合格带原因")
    }

    // MARK: - 自动配标签

    func testAutoJudgeAgainstProbeLabels() throws {
        let c = try probe.cases[7]
        let items = [
            MemoryBenchItem(index: 0, text: "岚舟每周六下午去旧书店半盏看书", fields: ["subject": "岚舟"]),
            MemoryBenchItem(index: 1, text: "岚舟害怕水", fields: ["subject": "岚舟"]),
            MemoryBenchItem(index: 2, text: "岚舟喜欢下雨天", fields: [:]),
        ]
        let judged = writer.autoJudge(items: items, labels: c.labels)
        XCTAssertEqual(judged.map(\.item), [0, 1], "没配上的留给她判")
        XCTAssertEqual(judged.map(\.verdict), [.right, .wrong])
        XCTAssertEqual(judged[1].labelId, "08-n1")
    }

    /// 10-23 试写台 Haiku live 的真实输出：按它修过的关键词（05 一次性建议、06 完美那条、09 带引号的半盏）
    func testLabelsFixedAgainstTheHaikuLiveRun() throws {
        let cases = Dictionary(uniqueKeysWithValues: try probe.cases.map { ($0.id, $0) })
        func judge(_ caseId: String, _ text: String) -> (MemoryBenchVerdict, String)? {
            writer.autoJudge(items: [MemoryBenchItem(index: 0, text: text, fields: [:])], labels: cases[caseId]?.labels ?? []).first
                .map { ($0.verdict, $0.labelId) }
        }
        XCTAssertTrue(judge("05", "星砚建议岚舟把《海边的卡夫卡》放到门口，下次出门顺手带上还给林栖。")! == (.wrong, "05-n2"), "一次性建议记成承诺 = 错")
        XCTAssertTrue(judge("05", "岚舟向林栖借的《海边的卡夫卡》已借了一年多还未归还。")! == (.right, "05-y3"))
        XCTAssertTrue(judge("06", "岚舟的导师钟予白曾对岚舟说过「你做东西太求完美，反而做不完」")! == (.right, "06-y2"), "完美那条归 y2")
        XCTAssertTrue(judge("06", "钟予白是岚舟的大学毕设导师，今年刚退休，已搬去山里种茶。")! == (.right, "06-y1"))
        XCTAssertTrue(judge("09", "岚舟新家离「半盏」书店步行十分钟。")! == (.right, "09-y2"), "带引号的半盏也配得上")
        XCTAssertTrue(judge("09", "岚舟的搬家截止日期是10月25日；旧房子10月26日到期。")! == (.right, "09-y1"))
    }

    func testShouldNotHaveWinsWhenBothMatch() throws {
        let c = try probe.cases[10]
        let judged = writer.autoJudge(items: [MemoryBenchItem(index: 0, text: "开放水域潜水证常见价格三四千元", fields: [:])], labels: c.labels)
        XCTAssertEqual(judged.first?.verdict, .wrong, "既像应记（潜水证）又像不该记（价格）按错算——Haiku 那条错")
    }
}
