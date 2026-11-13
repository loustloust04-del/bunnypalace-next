import XCTest
@testable import MemoryCore

/// 整理 agent：结论本的校验和核对、六个工具、循环的封顶和收尾。模型是脚本化的假模型，全虚构
final class OrganizeAgentTests: XCTestCase {
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")

    private struct FakeSource: OrganizeSource {
        var all: [OrganizeCard]
        func cards() throws -> [OrganizeCard] { all }
        func source(of card: String, before: Int, after: Int) throws -> [OrganizeSourceLine] {
            card == "9" ? [] : [OrganizeSourceLine(marker: "窗口 1 · #\(card)", who: "岚舟", when: "2026-10-12", text: "原文 \(card)，前 \(before) 后 \(after)", isOrigin: true)]
        }
        func search(_ terms: String, limit: Int) throws -> [OrganizeSourceLine] {
            terms == "没有" ? [] : [OrganizeSourceLine(marker: "窗口 2 · #5", who: "星砚", text: "搜到「\(terms)」")]
        }
    }

    private var cards: [OrganizeCard] {
        [OrganizeCard(id: "1", content: "岚舟的模型船做成双帆。", day: "2026-10-12"),
         OrganizeCard(id: "2", content: "岚舟只用水性颜料。"),
         OrganizeCard(id: "3", content: "岚舟当时有点困。"),
         OrganizeCard(id: "4", content: "岚舟住在云桥城。", zone: .archive),
         OrganizeCard(id: "5", content: "岚舟亲手写的一句。", zone: .locked)]
    }

    // MARK: - 结论本

    func testRecordValidatesEachItemSeparately() {
        var ledger = OrganizeLedger()
        let receipt = ledger.record([
            .init(action: "merge", cards: ["1", "2"], content: "岚舟的模型船做成双帆，只用水性颜料上色。", confidence: 0.8),
            .init(action: "drop", cards: ["3"], why: "只是那一刻"),
            .init(action: "archive", cards: ["1"]),
            .init(action: "keep", cards: ["99"]),
            .init(action: "merge", cards: ["1"], content: "一张不能并"),
            .init(action: "rewrite", cards: ["2"]),
            .init(action: "keep", cards: ["1", "2"]),
            .init(action: "rewrite", cards: ["5"], content: "想动锁住的"),
            .init(action: "keep", cards: ["1"], confidence: 1.5),
            .init(action: "keep", cards: []),
        ], cards: cards)
        XCTAssertEqual(receipt.accepted, 2)
        XCTAssertEqual(receipt.rejected.count, 8)
        XCTAssertEqual(ledger.entries.map(\.action), [.merge, .drop])
        XCTAssertEqual(ledger.decided, ["1", "2", "3"])
        XCTAssertTrue(ledger.problems(cards: cards).isEmpty, "Archive / Lock 的卡不要求有结论")
    }

    func testLaterRecordReplacesEarlierAndFlagsBrokenMerge() {
        var ledger = OrganizeLedger()
        _ = ledger.record([.init(action: "merge", cards: ["1", "2"], content: "并。", confidence: 0.7)], cards: cards)
        _ = ledger.record([.init(action: "drop", cards: ["2"])], cards: cards)
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertEqual(ledger.entries[0].cards, ["1"])
        let problems = ledger.problems(cards: cards)
        XCTAssertTrue(problems.contains { $0.contains("merge 现在只剩卡 1") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("还有 1 张 Draft 卡没有结论") }, "\(problems)")
        _ = ledger.record([.init(action: "keep", cards: ["1"], confidence: 0.9), .init(action: "unsure", cards: ["3"])], cards: cards)
        XCTAssertTrue(ledger.problems(cards: cards).isEmpty)
        XCTAssertEqual(ledger.entries.map(\.cards), [["2"], ["1"], ["3"]])
    }

    func testTouchingArchivedCardBecomesSuggestion() {
        var ledger = OrganizeLedger()
        _ = ledger.record([.init(action: "merge", cards: ["1", "4"], content: "岚舟住在云桥城，模型船做成双帆。", confidence: 0.6),
                           .init(action: "keep", cards: ["4"])], cards: cards)
        XCTAssertEqual(ledger.entries.last?.suggestion, false, "keep 一张已在档案的卡不是建议")
        _ = ledger.record([.init(action: "rewrite", cards: ["4"], content: "岚舟搬到了云桥城。")], cards: cards)
        XCTAssertEqual(ledger.entries.last?.suggestion, true)
    }

    func testCloseUndecidedHandsTheRestToHer() {
        var ledger = OrganizeLedger()
        _ = ledger.record([.init(action: "drop", cards: ["3"])], cards: cards)
        ledger.closeUndecided(cards: cards, why: "没跑完")
        XCTAssertEqual(ledger.entries.filter { $0.action == .unsure }.map(\.cards), [["1"], ["2"]])
    }

    // MARK: - 工具

    private func call(_ name: String, _ arguments: String) -> AgentToolCall {
        AgentToolCall(id: "c", name: name, arguments: arguments)
    }

    func testListCardsPagesAndMarksArchived() {
        var ledger = OrganizeLedger()
        let source = FakeSource(all: cards)
        let first = OrganizeAgent.execute(call("list_cards", #"{"limit":2}"#), cards: cards, source: source, ledger: &ledger)
        XCTAssertTrue(first.content.contains("[1] 2026-10-12 岚舟的模型船做成双帆。"))
        XCTAssertTrue(first.content.contains("第 1–2 张，共 5 张，下一页 offset=2；全部卡里还有 3 张没结论。"))
        let rest = OrganizeAgent.execute(call("list_cards", #"{"offset":2}"#), cards: cards, source: source, ledger: &ledger)
        XCTAssertTrue(rest.content.contains("[4]（已在档案） 岚舟住在云桥城。"))
        XCTAssertTrue(rest.content.contains("已经到底"))
        XCTAssertTrue(OrganizeAgent.execute(call("list_cards", #"{"offset":50}"#), cards: cards, source: source, ledger: &ledger).content.contains("没有更多卡了"))
    }

    func testReadAndSearchSource() {
        var ledger = OrganizeLedger()
        let source = FakeSource(all: cards)
        let read = OrganizeAgent.execute(call("read_source", #"{"card":1,"before":99}"#), cards: cards, source: source, ledger: &ledger)
        XCTAssertEqual(read.content, "→ 窗口 1 · #1 2026-10-12 · 岚舟：原文 1，前 10 后 3")
        XCTAssertTrue(OrganizeAgent.execute(call("read_source", #"{"card":"77"}"#), cards: cards, source: source, ledger: &ledger).isError)
        XCTAssertEqual(OrganizeAgent.execute(call("search_source", #"{"terms":"双帆"}"#), cards: cards, source: source, ledger: &ledger).content,
                       "  窗口 2 · #5 · 星砚：搜到「双帆」")
        XCTAssertEqual(OrganizeAgent.execute(call("search_source", #"{"terms":"没有"}"#), cards: cards, source: source, ledger: &ledger).content, "没搜到。")
        XCTAssertTrue(OrganizeAgent.execute(call("shell", "{}"), cards: cards, source: source, ledger: &ledger).isError)
    }

    func testRecordCheckFinish() {
        var ledger = OrganizeLedger()
        let source = FakeSource(all: cards)
        let early = OrganizeAgent.execute(call("finish", "{}"), cards: cards, source: source, ledger: &ledger)
        XCTAssertTrue(early.isError)
        XCTAssertNil(early.finished)
        let recorded = OrganizeAgent.execute(call("record", #"{"items":[{"action":"merge","cards":[1,"2"],"content":"并好的一句。","confidence":0.8},{"action":"drop","cards":["3"]},{"action":"keep","cards":["88"]}]}"#),
                                             cards: cards, source: source, ledger: &ledger)
        XCTAssertTrue(recorded.content.hasPrefix("收下 2 条；退回 1 条"), recorded.content)
        XCTAssertTrue(recorded.content.hasSuffix("还有 0 张没结论。"))
        XCTAssertEqual(OrganizeAgent.execute(call("check", ""), cards: cards, source: source, ledger: &ledger).content, "都对上了：每张卡都有结论。")
        XCTAssertEqual(OrganizeAgent.execute(call("finish", #"{"summary":"理完了"}"#), cards: cards, source: source, ledger: &ledger).finished, "理完了")
        XCTAssertTrue(OrganizeAgent.execute(call("record", "不是 JSON"), cards: cards, source: source, ledger: &ledger).isError)
    }

    // MARK: - 循环

    /// 按脚本一轮一轮回：每轮给若干工具调用
    private func scripted(_ rounds: [[AgentToolCall]], seen: @escaping ([AgentToolSpec], [AgentTurn]) -> Void = { _, _ in }) -> ClosureToolModelCaller {
        var index = 0
        return ClosureToolModelCaller { _, turns, tools in
            seen(tools, turns)
            defer { index += 1 }
            let calls = index < rounds.count ? rounds[index] : []
            return AgentStep(text: calls.isEmpty ? "我想想" : "", calls: calls, usage: AgentUsage(input: 100, output: 10, cacheRead: 40))
        }
    }

    func testRunFinishesWhenAgentFinishes() async {
        let caller = scripted([
            [call("list_cards", "{}")],
            [call("read_source", #"{"card":"1"}"#), call("record", #"{"items":[{"action":"merge","cards":["1","2"],"content":"并好的一句。","confidence":0.8},{"action":"drop","cards":["3"]}]}"#)],
            [call("check", "{}"), call("finish", #"{"summary":"三张理完"}"#)],
        ])
        let outcome = await OrganizeAgent.run(source: FakeSource(all: cards), caller: caller, names: names)
        XCTAssertEqual(outcome.stop, .finished)
        XCTAssertEqual(outcome.summary, "三张理完")
        XCTAssertEqual(outcome.rounds.map(\.tools), [["list_cards"], ["read_source", "record"], ["check", "finish"]])
        XCTAssertEqual(outcome.inputTokens, 300)
        XCTAssertEqual(outcome.cacheReadTokens, 120)
        XCTAssertEqual(outcome.ledger.entries.map(\.action), [.merge, .drop])
    }

    func testRunHitsRoundLimitClosesToolsAndHandsRestToHer() async {
        var offered: [[String]] = []
        let caller = scripted(Array(repeating: [call("list_cards", "{}")], count: 10)) { tools, _ in offered.append(tools.map(\.name)) }
        let outcome = await OrganizeAgent.run(source: FakeSource(all: cards), caller: caller, names: names,
                                              limits: .init(rounds: 5))
        XCTAssertEqual(outcome.stop, .rounds)
        XCTAssertEqual(outcome.rounds.count, 5)
        XCTAssertEqual(offered[1].count, 9, "六个基本工具 + similar_cards + 分堆两个")
        XCTAssertEqual(offered[2], ["record", "check", "finish"], "最后三轮只剩交和结束")
        XCTAssertEqual(outcome.ledger.entries.filter { $0.action == .unsure }.count, 3)
    }

    func testRunStopsOnBudgetCancelNoToolsAndFailure() async {
        let source = FakeSource(all: cards)
        let budget = await OrganizeAgent.run(source: source, caller: scripted([]), names: names, allow: { false })
        XCTAssertEqual(budget.stop, .budget)
        XCTAssertTrue(budget.rounds.isEmpty)
        XCTAssertEqual(budget.ledger.entries.count, 3)

        let silent = await OrganizeAgent.run(source: source, caller: scripted([]), names: names)
        XCTAssertEqual(silent.rounds.count, 2, "光说话：提醒一次，再来一次就停")
        XCTAssertNotEqual(silent.stop, .finished)

        let failing = ClosureToolModelCaller { _, _, _ in throw MemoryWriterError.format("接口炸了") }
        let failed = await OrganizeAgent.run(source: source, caller: failing, names: names)
        XCTAssertEqual(failed.stop, .failed)
        XCTAssertNotNil(failed.error)
    }

    func testTruncatedRoundIsToldToBatchAndDoesNotCountAsSilence() async {
        var round = 0
        var sawReminder = false
        let caller = ClosureToolModelCaller { _, turns, _ in
            defer { round += 1 }
            if round < 3 { return AgentStep(stop: "max_tokens") }
            if case .user(let text)? = turns.last, text.contains("分几次交") { sawReminder = true }
            if round == 3 {
                return AgentStep(calls: [AgentToolCall(id: "a", name: "record", arguments: #"{"items":[{"action":"drop","cards":["1"]},{"action":"drop","cards":["2"]},{"action":"drop","cards":["3"]}]}"#)])
            }
            return AgentStep(calls: [AgentToolCall(id: "b", name: "finish", arguments: "{}")])
        }
        let outcome = await OrganizeAgent.run(source: FakeSource(all: cards), caller: caller, names: names)
        XCTAssertEqual(outcome.stop, .finished, "连着截断三轮也不该当成它不干了")
        XCTAssertTrue(sawReminder)
        XCTAssertEqual(outcome.rounds.count, 5)
    }

    func testRunWithNoDraftCardsMakesNoCalls() async {
        let caller = ClosureToolModelCaller { _, _, _ in XCTFail("没有新卡不该调模型"); return AgentStep() }
        let outcome = await OrganizeAgent.run(source: FakeSource(all: [OrganizeCard(id: "4", content: "已在档案。", zone: .archive)]),
                                              caller: caller, names: names)
        XCTAssertEqual(outcome.stop, .finished)
    }

    func testTrimmedElidesOldToolResultsButKeepsRecentAndStructure() {
        let big = String(repeating: "字", count: 1000)
        var turns: [AgentTurn] = [.user("开始")]
        for index in 0..<6 {
            turns.append(.assistant(text: "", calls: [call("list_cards", "{}")], reasoning: nil))
            turns.append(.toolResults([AgentToolResult(callId: "c\(index)", content: big)]))
        }
        let out = OrganizeAgent.trimmed(turns, limit: 2500)
        XCTAssertEqual(out.count, turns.count)
        func size(_ turn: AgentTurn) -> Int { if case .toolResults(let r) = turn { return r[0].content.count }; return 0 }
        XCTAssertLessThan(size(out[2]), 100)
        XCTAssertEqual(size(out[12]), 1000, "最近的不动")
        XCTAssertEqual(OrganizeAgent.trimmed(turns, limit: 100_000), turns)
    }

    // MARK: - 第二轮：相近的卡、没有 keep

    private var mixed: [OrganizeCard] {
        [OrganizeCard(id: "1", content: "岚舟的模型船做成双帆。"),
         OrganizeCard(id: "2", content: "星砚答应陪岚舟画云桥城地图。"),
         OrganizeCard(id: "3", content: "岚舟给模型船上色只用水性颜料。"),
         OrganizeCard(id: "4", content: "云桥城地图定在周末开始画。"),
         OrganizeCard(id: "5", content: "岚舟的模型船船帆粘了三次才牢。")]
    }

    func testNeighborsFindLexicallyCloseCardsAndOrderThemTogether() {
        let neighbors = OrganizeNeighbors(cards: mixed)
        let close = neighbors.similar(to: "1", limit: 2).map(\.id)
        XCTAssertEqual(Set(close), ["3", "5"], "模型船的三张互相最近")
        XCTAssertEqual(neighbors.similar(to: "2", limit: 1).first?.id, "4")
        XCTAssertTrue(neighbors.similar(to: "99", limit: 5).isEmpty)
        let order = neighbors.ordered()
        XCTAssertEqual(Set(order), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(order.first, "1")
        let ships = ["1", "3", "5"].compactMap { order.firstIndex(of: $0) }.sorted()
        XCTAssertEqual(ships.last! - ships.first!, 2, "三张模型船挨在一起：\(order)")
    }

    func testSimilarCardsToolAndKeepRefusedWhenNotAllowed() {
        var ledger = OrganizeLedger()
        let source = FakeSource(all: mixed)
        let neighbors = OrganizeNeighbors(cards: mixed)
        let options = OrganizeAgent.Options()
        let similar = OrganizeAgent.execute(call("similar_cards", #"{"card":"2","limit":1}"#), cards: mixed, source: source,
                                            ledger: &ledger, neighbors: neighbors, options: options)
        XCTAssertEqual(similar.content, "[4] 云桥城地图定在周末开始画。")
        XCTAssertTrue(OrganizeAgent.execute(call("similar_cards", #"{"card":"2"}"#), cards: mixed, source: source, ledger: &ledger).isError,
                      "没开这个帮手时没有这个工具")
        let recorded = OrganizeAgent.execute(call("record", #"{"items":[{"action":"keep","cards":["1"]},{"action":"rewrite","cards":["2"],"content":"星砚答应陪岚舟画云桥城地图。","confidence":0.7}]}"#),
                                             cards: mixed, source: source, ledger: &ledger, neighbors: neighbors, options: options)
        XCTAssertTrue(recorded.content.hasPrefix("收下 1 条；退回 1 条"), recorded.content)
        XCTAssertTrue(recorded.content.contains("没有 keep"))
        XCTAssertEqual(ledger.entries.map(\.action), [.rewrite])
        XCTAssertTrue(OrganizeAgent.tools(options).contains { $0.name == "similar_cards" })
        XCTAssertFalse(OrganizeAgent.tools(options).first { $0.name == "record" }!.schema.contains("\"keep\""))
        XCTAssertFalse(OrganizeAgent.systemPrompt(names: names, options: options).contains("keep"))
        XCTAssertTrue(OrganizeAgent.systemPrompt(names: names, options: .init(neighbors: false, allowKeep: true)).contains("keep（原样留一张）"))
    }

    func testPilesWorkspaceSortsListsAndShowsProgress() {
        var ledger = OrganizeLedger()
        var desk = OrganizeAgent.Desk()
        let source = FakeSource(all: mixed)
        let options = OrganizeAgent.Options(neighbors: false)
        func run(_ name: String, _ arguments: String) -> (content: String, isError: Bool, finished: String?) {
            OrganizeAgent.execute(call(name, arguments), cards: mixed, source: source, ledger: &ledger, desk: &desk, neighbors: nil, options: options)
        }
        let sorted = run("sort_cards", #"{"piles":[{"name":"模型船","cards":["1",3,"5","77"]},{"name":"云桥城地图","cards":["2"]}]}"#)
        XCTAssertTrue(sorted.content.hasPrefix("分了 4 张；现在一共 2 堆，还有 1 张没分堆。"), sorted.content)
        XCTAssertTrue(sorted.content.contains("没有这些编号的卡：77"))
        _ = run("sort_cards", #"{"piles":[{"name":"云桥城地图","cards":["4"]}]}"#)
        _ = run("record", #"{"items":[{"action":"merge","cards":["1","3"],"content":"岚舟的模型船做成双帆，只用水性颜料上色。","confidence":0.8}]}"#)
        XCTAssertEqual(run("list_piles", "{}").content, "「模型船」3 张，1 张没结论\n「云桥城地图」2 张，2 张没结论")
        let pile = run("list_cards", #"{"pile":"模型船"}"#)
        XCTAssertTrue(pile.content.contains("[1]（已有结论） 岚舟的模型船做成双帆。"), pile.content)
        XCTAssertTrue(pile.content.contains("[5] 岚舟的模型船船帆粘了三次才牢。"))
        XCTAssertFalse(pile.content.contains("云桥城"))
        XCTAssertTrue(pile.content.contains("「模型船」这一堆第 1–3 张，共 3 张，已经到底；全部卡里还有 3 张没结论。"))
        XCTAssertTrue(run("list_cards", #"{"pile":"没这堆"}"#).isError)
        XCTAssertTrue(OrganizeAgent.execute(call("sort_cards", #"{"piles":[]}"#), cards: mixed, source: source, ledger: &ledger).isError,
                      "没开分堆时没有这个工具")
        XCTAssertTrue(OrganizeAgent.systemPrompt(names: names, options: options).contains("sort_cards"))
        XCTAssertFalse(OrganizeAgent.systemPrompt(names: names, options: .init(piles: false)).contains("sort_cards"))
    }

    func testTrimmedCutsToHalfSoThePrefixStaysStable() {
        let big = String(repeating: "字", count: 1000)
        var turns: [AgentTurn] = [.user("开始")]
        for index in 0..<8 {
            turns.append(.assistant(text: "", calls: [call("list_cards", "{}")], reasoning: nil))
            turns.append(.toolResults([AgentToolResult(callId: "c\(index)", content: big)]))
        }
        let once = OrganizeAgent.trimmed(turns, limit: 6000)
        func kept(_ turns: [AgentTurn]) -> Int {
            turns.reduce(0) { sum, turn in
                if case .toolResults(let r) = turn, r[0].content.count == 1000 { return sum + 1 }
                return sum
            }
        }
        XCTAssertEqual(kept(once), 2, "超了 6000 就裁到 3000 以内（省略提示自己也占字数）")
        XCTAssertEqual(OrganizeAgent.trimmed(once, limit: 6000), once, "裁过之后没再超就不动，前面的内容稳定")
    }

    func testSystemPromptCarriesOwnerWordsAndNoRuleList() {
        let prompt = OrganizeAgent.systemPrompt(names: names, ownerWords: "- 「只要精准的事实。」")
        XCTAssertTrue(prompt.contains("- 「只要精准的事实。」"))
        XCTAssertTrue(prompt.contains("岚舟"))
        for tool in OrganizeAgent.tools { XCTAssertTrue(prompt.contains(tool.name), tool.name) }
        XCTAssertFalse(prompt.contains("不记"), "不列「不记 X」清单")
    }
}
