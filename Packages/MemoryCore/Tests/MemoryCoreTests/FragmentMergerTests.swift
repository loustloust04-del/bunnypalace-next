import XCTest
@testable import MemoryCore

/// C2 整理的「并」：分组解析、合并解析、跑一遍。全虚构
final class FragmentMergerTests: XCTestCase {
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")

    private func card(_ id: String, _ content: String) -> FragmentMerger.Card {
        FragmentMerger.Card(id: id, content: content, source: "岚舟：\(content)")
    }

    func testParseGroupsDropsUnknownIdsOverlapsAndThinGroups() throws {
        let raw = #"{"groups":[["1","2","99"],[2,3],["4"],["5","6"]]}"#
        let groups = try XCTUnwrap(FragmentMerger.parseGroups(raw, ids: ["1", "2", "3", "4", "5", "6"]))
        XCTAssertEqual(groups, [["1", "2"], ["5", "6"]])
        XCTAssertEqual(FragmentMerger.parseGroups(#"{"groups":[]}"#, ids: ["1"]), [])
        XCTAssertNil(FragmentMerger.parseGroups("没什么可并的", ids: ["1"]))
    }

    func testParseGroupsRejectsOversizedGroup() throws {
        let ids = (1...(FragmentMerger.maxGroupSize + 1)).map(String.init)
        let raw = "{\"groups\":[[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]]}"
        XCTAssertEqual(FragmentMerger.parseGroups(raw, ids: Set(ids)), [])
    }

    func testParseMergedNeedsEveryIdExactlyOnce() throws {
        let good = #"{"cards":[{"content":"岚舟的模型船做成双帆，只用水性颜料上色。","from":["1",2]}]}"#
        XCTAssertEqual(try XCTUnwrap(FragmentMerger.parseMerged(good, group: ["1", "2"])),
                       [.init(content: "岚舟的模型船做成双帆，只用水性颜料上色。", from: ["1", "2"])])
        let split = #"{"cards":[{"content":"甲。","from":["1"]},{"content":"乙。","from":["2"]}]}"#
        XCTAssertEqual(FragmentMerger.parseMerged(split, group: ["1", "2"])?.count, 2)
        XCTAssertNil(FragmentMerger.parseMerged(#"{"cards":[{"content":"只并了一张。","from":["1"]}]}"#, group: ["1", "2"]))
        XCTAssertNil(FragmentMerger.parseMerged(#"{"cards":[{"content":"重复吸收。","from":["1","1"]}]}"#, group: ["1", "2"]))
        XCTAssertNil(FragmentMerger.parseMerged(#"{"cards":[{"content":"","from":["1","2"]}]}"#, group: ["1", "2"]))
        let long = String(repeating: "长", count: FragmentMerger.maxContentChars + 1)
        XCTAssertNil(FragmentMerger.parseMerged("{\"cards\":[{\"content\":\"\(long)\",\"from\":[\"1\",\"2\"]}]}", group: ["1", "2"]))
    }

    func testPromptsCarryCardsAndSources() {
        let cards = [card("1", "岚舟的模型船做成双帆。"), card("2", "岚舟只用水性颜料。")]
        XCTAssertEqual(FragmentMerger.groupUserContent(cards), "[1] 岚舟的模型船做成双帆。\n[2] 岚舟只用水性颜料。")
        XCTAssertTrue(FragmentMerger.mergeUserContent(cards).contains("[2] 岚舟只用水性颜料。\n出处原文：\n岚舟：岚舟只用水性颜料。"))
        XCTAssertTrue(FragmentMerger.mergeSystemPrompt(names: names).contains("原文是事实"))
    }

    func testRunGroupsThenMergesAndKeepsFailedGroupsUntouched() async throws {
        let cards = (1...5).map { card(String($0), "第 \($0) 张。") }
        let outcome = try await FragmentMerger.run(cards, names: names, caller: { system, user in
            if system.contains("圈成一组") { return #"{"groups":[["1","2","3"],["4","5"]]}"# }
            if user.contains("[1]") { return #"{"cards":[{"content":"前三张并成的一句。","from":["1","2","3"]}]}"# }
            return "并不出来"
        }, concurrent: 1)
        XCTAssertEqual(outcome.groups, [["1", "2", "3"], ["4", "5"]])
        XCTAssertEqual(outcome.merged, [.init(content: "前三张并成的一句。", from: ["1", "2", "3"])])
        XCTAssertEqual(outcome.failedGroups, [["4", "5"]])
        XCTAssertEqual(outcome.removed, 2)
    }

    func testRunWithNothingToMergeMakesNoMergeCalls() async throws {
        var calls = 0
        let outcome = try await FragmentMerger.run([card("1", "甲。"), card("2", "乙。")], names: names, caller: { _, _ in
            calls += 1
            return #"{"groups":[]}"#
        })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome, FragmentMerger.Outcome())
        let single = try await FragmentMerger.run([card("1", "甲。")], names: names, caller: { _, _ in XCTFail("一张卡不该调模型"); return nil })
        XCTAssertEqual(single, FragmentMerger.Outcome())
    }
}
