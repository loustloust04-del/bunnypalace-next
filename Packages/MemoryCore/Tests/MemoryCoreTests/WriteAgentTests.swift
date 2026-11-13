import XCTest
@testable import MemoryCore

/// 写入 agent：账本的校验、工具、循环。模型是脚本化的假模型，全虚构
final class WriteAgentTests: XCTestCase {
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")

    private struct FakeSource: WriteSource {
        var windowTitle = "模型船"
        var lines: [WriteLine] = (1...5).map { WriteLine(number: $0, who: $0 % 2 == 1 ? "岚舟" : "星砚", when: "2026-10-1\($0) 09:00", text: "第 \($0) 句") }
        var cards: [WriteKnownCard] = [
            WriteKnownCard(id: "7", content: "住在云桥城，租的房子朝南。", subject: "岚舟", since: "2026-09", archived: true),
            WriteKnownCard(id: "8", content: "模型船做成双帆。", subject: "岚舟"),
        ]
        var wiki: [WritePage] = []
        func span() throws -> [WriteLine] { lines }
        func before(count: Int, skip: Int) throws -> [WriteLine] { skip > 0 ? [] : [WriteLine(number: 0, who: "岚舟", text: "更早的一句")] }
        func search(_ terms: String, limit: Int) throws -> [OrganizeSourceLine] {
            terms == "没有" ? [] : [OrganizeSourceLine(marker: "窗口 2 · #5", who: "星砚", text: "搜到「\(terms)」")]
        }
        func known() throws -> [WriteKnownCard] { cards }
        func pages() throws -> [WritePage] { wiki }
    }

    private func desk(_ source: FakeSource = FakeSource()) -> WriteAgent.Desk {
        WriteAgent.Desk(span: source.lines, known: source.cards, pages: source.wiki, windowTitle: source.windowTitle)
    }

    private func card(_ content: String, subject: String? = "岚舟", type: String? = "fact", origin: String? = "said",
                      msgs: [Int] = [1], target: String? = nil, key: String? = nil) -> WriteLedger.CardInput {
        .init(key: key, target: target, subject: subject, type: type, origin: origin, volatile: nil, content: content, msgs: msgs, since: nil, confidence: nil)
    }

    // MARK: - 账本

    func testSubmitValidatesEachCardSeparately() {
        var ledger = WriteLedger()
        let known = FakeSource().cards
        let receipt = ledger.submit(cards: [
            card("只用水性颜料上色。"),
            card(""),
            card("没主语", subject: " "),
            card("类型不对", type: "note"),
            card("来源不对", origin: "heard"),
            card("出处不在这段里", msgs: [99]),
            card("改不存在的卡", target: "99"),
            card("搬到了雾岛，房子朝东。", target: "7"),
            card("模型船改成三帆。", msgs: [2, 99], target: "8"),
        ], span: 1...5, known: known)
        XCTAssertEqual(receipt.rejected.count, 6)
        XCTAssertEqual(ledger.cards.map(\.key), ["n1", "n2", "n3"])
        XCTAssertEqual(ledger.cards.map(\.suggestion), [false, true, false], "改她认可过的卡只是建议")
        XCTAssertEqual(ledger.cards[2].msgs, [2], "不在这段里的出处编号丢掉")
    }

    func testKeyReplacesAndRemoveDropsNoteLinks() {
        var ledger = WriteLedger()
        _ = ledger.submit(cards: [card("只用水性颜料上色。"), card("想把船送给林栖。", msgs: [3])], span: 1...5, known: [])
        _ = ledger.submit(cards: [card("只用水性颜料，因为油性的味道受不了。", key: "n1")], span: 1...5, known: [])
        XCTAssertEqual(ledger.cards.count, 2)
        XCTAssertTrue(ledger.cards[0].content.contains("味道"))
        XCTAssertEqual(ledger.submit(cards: [card("顶一张没交过的", key: "n9")], span: 1...5, known: []).rejected.count, 1)

    }

    func testMatterOwnsItsCardsAndResubmitReplacesThem() {
        var ledger = WriteLedger()
        let first = ledger.submit(matter: .init(key: nil, title: "模型船", page: nil, summary: "截至 2026-10-15 做到上色这一步。",
                                                 facts: [card("只用水性颜料上色。"), card("坏的", type: "x"), card("想把船送给林栖。", msgs: [3])]),
                                  label: "第 1 件事", span: 1...5, known: [])
        XCTAssertEqual(first.accepted, ["p1", "n1", "n2"])
        XCTAssertEqual(first.rejected.count, 1)
        XCTAssertEqual(ledger.notes.first?.cards, ["n1", "n2"])

        XCTAssertEqual(ledger.submit(matter: .init(key: nil, title: "", page: nil, summary: "没标题", facts: [card("甲")]), label: "x", span: 1...5, known: []).rejected.count, 1)
        XCTAssertEqual(ledger.submit(matter: .init(key: nil, title: "没卡", page: nil, summary: "一段", facts: []), label: "x", span: 1...5, known: []).rejected.count, 1)
        let hollow = ledger.submit(matter: .init(key: "p1", title: "模型船", page: nil, summary: "重交但卡全坏", facts: [card("", msgs: [1])]), label: "x", span: 1...5, known: [])
        XCTAssertTrue(hollow.accepted.isEmpty)
        XCTAssertEqual(ledger.notes.first?.cards, ["n1", "n2"], "整件没记上时原来的不动")

        let again = ledger.submit(matter: .init(key: "p1", title: "模型船", page: "物件/模型船", summary: "2026-10-16 上色做完了。",
                                                 facts: [card("只用水性颜料，因为油性的味道受不了。")]), label: "x", span: 1...5, known: [])
        XCTAssertEqual(again.accepted.first, "p1")
        XCTAssertEqual(ledger.notes.count, 1)
        XCTAssertEqual(ledger.cards.count, 1, "重交时原来底下的卡一起换掉")
        XCTAssertEqual(ledger.notes[0].page, "物件/模型船")

        XCTAssertEqual(ledger.remove([ledger.cards[0].key]), 1)
        XCTAssertEqual(ledger.problems(windowTitle: "模型船").blocking.count, 1, "底下的卡都撤了要拦")
        XCTAssertEqual(ledger.remove(["p1"]), 1)
        XCTAssertTrue(ledger.problems(windowTitle: "模型船").blocking.isEmpty)
    }

    func testRemovingMatterTakesItsCards() {
        var ledger = WriteLedger()
        _ = ledger.submit(matter: .init(key: nil, title: "模型船", page: nil, summary: "一段", facts: [card("甲事实一句。"), card("乙事实一句。", msgs: [2])]),
                          label: "x", span: 1...5, known: [])
        _ = ledger.submit(cards: [card("零散的一句。", msgs: [4])], span: 1...5, known: [])
        XCTAssertEqual(ledger.remove(["p1"]), 3)
        XCTAssertEqual(ledger.cards.map(\.key), ["n3"])
    }

    func testProblemsHintDanglingWordsAndLookAlikesWithoutBlocking() {
        var ledger = WriteLedger()
        _ = ledger.submit(cards: [card("这个窗口的星砚答应今天陪她上色。"), card("2026-10-12 在「模型船」窗口定了用双帆。", msgs: [2]),
                                  card("2026-10-12 在「模型船」窗口定了用双帆，不用单帆。", msgs: [3])], span: 1...5, known: [])
        let found = ledger.problems(windowTitle: "模型船")
        XCTAssertTrue(found.blocking.isEmpty)
        XCTAssertEqual(found.hints.count, 2)
        XCTAssertTrue(found.hints[0].contains("n1") && found.hints[0].contains("模型船"))
        XCTAssertTrue(found.hints[1].contains("n2 和 n3"))
    }

    // MARK: - 工具

    private func run(_ name: String, _ arguments: String, ledger: inout WriteLedger, source: FakeSource = FakeSource()) -> (content: String, isError: Bool, finished: String?) {
        WriteAgent.execute(AgentToolCall(id: "c", name: name, arguments: arguments), desk: desk(source), source: source, ledger: &ledger)
    }

    func testReadTools() {
        var ledger = WriteLedger()
        let first = run("read_span", #"{"count":2}"#, ledger: &ledger)
        XCTAssertTrue(first.content.contains("#1 2026-10-11 09:00 · 岚舟：第 1 句"))
        XCTAssertTrue(first.content.contains("下一页 from=3"))
        XCTAssertTrue(run("read_span", #"{"from":3}"#, ledger: &ledger).content.contains("已经到底"))
        XCTAssertTrue(run("read_span", #"{"from":9}"#, ledger: &ledger).content.contains("没有更多了"))
        XCTAssertTrue(run("read_before", "{}", ledger: &ledger).content.contains("#0 · 岚舟：更早的一句"))
        XCTAssertTrue(run("read_before", #"{"skip":1}"#, ledger: &ledger).content.contains("没有更早"))
        XCTAssertTrue(run("search_source", #"{"terms":"双帆"}"#, ledger: &ledger).content.contains("窗口 2 · #5"))
        XCTAssertTrue(run("list_pages", "{}", ledger: &ledger).content.contains("还没有页"))
        XCTAssertTrue(run("nope", "{}", ledger: &ledger).isError)
    }

    func testSearchMemoryCoversKnownAndSubmitted() {
        var ledger = WriteLedger()
        XCTAssertTrue(run("search_memory", #"{"terms":"双帆"}"#, ledger: &ledger).content.hasPrefix("[8]"))
        XCTAssertTrue(run("search_memory", #"{"terms":"云桥城"}"#, ledger: &ledger).content.contains("（她认可过）"))
        XCTAssertTrue(run("search_memory", #"{"terms":"颜料"}"#, ledger: &ledger).content.contains("没有字面相近"))
        _ = run("submit", #"{"cards":[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料上色。","msgs":[1]}]}"#, ledger: &ledger)
        XCTAssertTrue(run("search_memory", #"{"terms":"颜料"}"#, ledger: &ledger).content.contains("[n1]（你这次交的）"))
        var empty = WriteLedger()
        XCTAssertTrue(run("search_memory", #"{"terms":"颜料"}"#, ledger: &empty, source: FakeSource(cards: [])).content.contains("档案现在是空的"))
    }

    func testSubmitListCheckFinish() {
        var ledger = WriteLedger()
        XCTAssertTrue(run("list_submitted", "{}", ledger: &ledger).content.contains("还没交过"))
        let done = run("submit", #"{"matters":[{"title":"模型船","summary":"截至 2026-10-15 做到上色。","facts":[{"subject":"岚舟","type":"fact","origin":"said","content":"想把船送给林栖。","msgs":[3],"since":"2026-10-13"},{"subject":"岚舟","type":"x","origin":"said","content":"坏的","msgs":[1]}]}],"cards":[{"subject":"岚舟","type":"fact","origin":"said","content":"搬到了雾岛。","msgs":[2],"target":7}]}"#, ledger: &ledger)
        XCTAssertTrue(done.content.contains("p1（卡 n1）") && done.content.contains("n2") && done.content.contains("退回 1 条"))
        XCTAssertTrue(done.content.contains("n2 改的是她认可过的卡"))
        XCTAssertTrue(done.content.contains("现在一共 1 件事、2 张卡"))
        let listing = run("list_submitted", "{}", ledger: &ledger).content
        XCTAssertTrue(listing.contains("[p1]「模型船」") && listing.contains("[n1] fact · said · 岚舟：想把船送给林栖。"))
        XCTAssertTrue(listing.contains("零散的卡：") && listing.contains("改 7"))
        XCTAssertTrue(run("check", "{}", ledger: &ledger).content.contains("没看出问题"))
        XCTAssertTrue(run("submit", #"{"remove":["n1"]}"#, ledger: &ledger).content.contains("撤回 1 条"))
        XCTAssertTrue(run("finish", "{}", ledger: &ledger).isError, "一件事底下的卡没了不能结束")
        _ = run("submit", #"{"remove":["p1"]}"#, ledger: &ledger)
        XCTAssertEqual(run("finish", #"{"summary":"没什么可记"}"#, ledger: &ledger).finished, "没什么可记")
    }

    // MARK: - 循环

    func testRunTellsWindowNameAndStopsOnFinish() async {
        let script: [[AgentToolCall]] = [
            [AgentToolCall(id: "1", name: "read_span", arguments: "{}")],
            [AgentToolCall(id: "2", name: "submit", arguments: #"{"cards":[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料上色。","msgs":[1]}]}"#)],
            [AgentToolCall(id: "3", name: "finish", arguments: #"{"summary":"记了颜料"}"#)],
        ]
        let seen = Box()
        let caller = ClosureToolModelCaller { system, turns, _ in
            let round = await seen.next(system: system, first: turns.first)
            return AgentStep(calls: script[round], usage: AgentUsage(input: 10, output: 2))
        }
        let outcome = await WriteAgent.run(source: FakeSource(), caller: caller, names: names)
        XCTAssertEqual(outcome.stop, .finished)
        XCTAssertEqual(outcome.summary, "记了颜料")
        XCTAssertEqual(outcome.ledger.cards.count, 1)
        XCTAssertEqual(outcome.inputTokens, 30)
        let system = await seen.system
        XCTAssertTrue(system.contains("这个窗口的名字是「模型船」") && system.contains("2026-10-11 到 2026-10-15"))
        let first = await seen.first
        XCTAssertEqual(first, .user("这段新对话一共 5 条；档案里现在有 2 张卡。开始吧。"))
    }

    func testRunStopsAtRoundLimitAndWhenModelOnlyTalks() async {
        let looping = ClosureToolModelCaller { _, _, _ in AgentStep(calls: [AgentToolCall(id: "x", name: "check", arguments: "{}")]) }
        let capped = await WriteAgent.run(source: FakeSource(), caller: looping, names: names, limits: .init(rounds: 5))
        XCTAssertEqual(capped.stop, .rounds)
        XCTAssertEqual(capped.rounds.count, 5)
        let talking = ClosureToolModelCaller { _, _, _ in AgentStep(text: "我想想") }
        let idle = await WriteAgent.run(source: FakeSource(), caller: talking, names: names)
        XCTAssertEqual(idle.rounds.count, 2, "提醒一次，再不调工具就停")
        let empty = await WriteAgent.run(source: FakeSource(lines: []), caller: talking, names: names)
        XCTAssertEqual(empty.summary, "没有新对话")
    }

    private actor Box {
        var round = 0
        var system = ""
        var first: AgentTurn?
        func next(system: String, first: AgentTurn?) -> Int {
            self.system = system
            if self.first == nil { self.first = first }
            round += 1
            return round - 1
        }
    }
}
