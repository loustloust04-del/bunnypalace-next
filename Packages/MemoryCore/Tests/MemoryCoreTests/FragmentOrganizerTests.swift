import XCTest
@testable import MemoryCore

/// C2 整理：提示词带齐材料；单条不合规矩降成「拿不准」不连累整批；整包两次不合格全部交给她。全虚构
final class FragmentOrganizerTests: XCTestCase {
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")

    private func card(_ id: String, _ content: String) -> FragmentOrganizer.Card {
        FragmentOrganizer.Card(id: id, content: content, subject: "岚舟", source: "岚舟：模型船的船帆又掉了")
    }

    func testPromptCarriesKnownCardsAndSource() {
        let user = FragmentOrganizer.userContent(batch: [card("3", "岚舟的模型船做成双帆。")],
                                                 known: [.init(id: "1", content: "岚舟制作模型船时只用水性颜料。")])
        XCTAssertTrue(user.contains("档案里已经有的卡：\n[1] 岚舟制作模型船时只用水性颜料。"))
        XCTAssertTrue(user.contains("[3] 岚舟的模型船做成双帆。\n（主题：岚舟）\n出处原文：\n岚舟：模型船的船帆又掉了"))
        XCTAssertTrue(FragmentOrganizer.userContent(batch: [card("1", "x")], known: []).contains("（还没有）"))
        let system = FragmentOrganizer.systemPrompt(names: names)
        for action in FragmentOrganizer.Action.allCases { XCTAssertTrue(system.contains("- \(action.rawValue)："), action.rawValue) }
        XCTAssertTrue(system.contains("原文是事实"))
    }

    func testParseKeepsValidDecisionsInBatchOrder() throws {
        let raw = #"{"decisions":[{"id":"3","action":"merge","into":1,"content":"岚舟的模型船做成双帆，只用水性颜料。"},{"id":"2","action":"drop","why":"只是那一刻"},{"id":4,"action":"fix","content":"岚舟把模型船改成了双帆。"},{"id":"5","action":"keep"}]}"#
        let parsed = try XCTUnwrap(FragmentOrganizer.parse(raw, expecting: ["2", "3", "4", "5"], known: ["1"]))
        XCTAssertEqual(parsed.map(\.id), ["2", "3", "4", "5"])
        XCTAssertEqual(parsed.map(\.action), [.drop, .merge, .fix, .keep])
        XCTAssertEqual(parsed[1].into, "1")
        XCTAssertEqual(parsed[2].content, "岚舟把模型船改成了双帆。")
    }

    func testBadSingleDecisionsBecomeUnsureWithReason() throws {
        let long = String(repeating: "长", count: FragmentOrganizer.maxContentChars + 1)
        let raw = """
        {"decisions":[{"id":"2","action":"archive"},{"id":"3","action":"merge","into":"99","content":"并"},{"id":"4","action":"merge","into":"4","content":"并自己"},{"id":"5","action":"fix"},{"id":"6","action":"fix","content":"\(long)"},{"id":"7","action":"merge","into":"1"}]}
        """
        let parsed = try XCTUnwrap(FragmentOrganizer.parse(raw, expecting: ["2", "3", "4", "5", "6", "7"], known: ["1"]))
        XCTAssertEqual(parsed.map(\.action), Array(repeating: .unsure, count: 6))
        XCTAssertTrue(parsed.allSatisfy { $0.why?.isEmpty == false })
    }

    func testMergeIntoEarlierCardOfSameBatchIsAllowed() throws {
        let raw = #"{"decisions":[{"id":"2","action":"keep"},{"id":"3","action":"merge","into":"2","content":"并好的一句。"}]}"#
        XCTAssertEqual(try XCTUnwrap(FragmentOrganizer.parse(raw, expecting: ["2", "3"], known: []))[1].action, .merge)
    }

    func testWholeBatchRejectedWhenCardsMissingOrExtra() {
        XCTAssertNil(FragmentOrganizer.parse(#"{"decisions":[{"id":"2","action":"keep"}]}"#, expecting: ["2", "3"], known: []))
        XCTAssertNil(FragmentOrganizer.parse(#"{"decisions":[{"id":"2","action":"keep"},{"id":"8","action":"keep"}]}"#, expecting: ["2", "3"], known: []))
        XCTAssertNil(FragmentOrganizer.parse("都留着吧", expecting: ["2"], known: []))
    }

    func testOrganizeRetriesOnceThenHandsEverythingToHer() async throws {
        var calls = 0
        let fixed = try await FragmentOrganizer.organize(batch: [card("2", "x")], known: [], names: names) { _, user in
            calls += 1
            if calls == 2 { XCTAssertTrue(user.contains("重交")) }
            return calls == 1 ? "不是 JSON" : #"{"decisions":[{"id":"2","action":"drop"}]}"#
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(fixed.map(\.action), [.drop])
        let gaveUp = try await FragmentOrganizer.organize(batch: [card("2", "x"), card("3", "y")], known: [], names: names) { _, _ in "还是不对" }
        XCTAssertEqual(gaveUp.map(\.action), [.unsure, .unsure])
        let skipped = try await FragmentOrganizer.organize(batch: [card("2", "x")], known: [], names: names) { _, _ in nil }
        XCTAssertEqual(skipped.map(\.action), [.unsure])
    }

    func testTallyCountsNetAddedAndUnsureRate() {
        let tally = FragmentOrganizer.tally([
            .init(id: "1", action: .keep), .init(id: "2", action: .fix, content: "改"),
            .init(id: "3", action: .merge, into: "1", content: "并"), .init(id: "4", action: .drop),
            .init(id: "5", action: .unsure),
        ])
        XCTAssertEqual(tally.total, 5)
        XCTAssertEqual(tally.added, 2)
        XCTAssertEqual(tally.unsureRate, 0.2)
        XCTAssertNil(FragmentOrganizer.tally([]).unsureRate)
    }
}
