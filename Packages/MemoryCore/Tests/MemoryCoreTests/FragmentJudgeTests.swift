import XCTest
@testable import MemoryCore

/// C2 碎片裁判：提示词带齐材料、解析只认「这一批每张正好一条」、统计。全虚构
final class FragmentJudgeTests: XCTestCase {
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")

    private func card(_ id: String, _ content: String, source: String = "岚舟：模型船的船帆又掉了") -> FragmentJudge.Card {
        FragmentJudge.Card(id: id, content: content, subject: "岚舟", speaker: "用户自述", category: "fact", source: source)
    }

    func testPromptCarriesPriorCardsAndSourceExcerpts() {
        let user = FragmentJudge.userContent(batch: [card("3", "岚舟的模型船做成双帆。")],
                                             prior: [.init(id: "1", content: "岚舟制作模型船时只用水性颜料。")])
        XCTAssertTrue(user.contains("[1] 岚舟制作模型船时只用水性颜料。"))
        XCTAssertTrue(user.contains("[3] 岚舟的模型船做成双帆。"))
        XCTAssertTrue(user.contains("主题：岚舟 · 来源：用户自述 · 类别：fact"))
        XCTAssertTrue(user.contains("出处原文：\n岚舟：模型船的船帆又掉了"))
        XCTAssertTrue(FragmentJudge.userContent(batch: [card("1", "x", source: "")], prior: []).contains("（找不到出处）"))
        let system = FragmentJudge.systemPrompt(names: names)
        XCTAssertTrue(system.contains("岚舟"))
        for verdict in FragmentJudge.Verdict.allCases { XCTAssertTrue(system.contains("- \(verdict.rawValue)："), verdict.rawValue) }
    }

    func testParseAcceptsExactlyOneJudgmentPerCard() throws {
        let raw = #"{"judgments":[{"id":"2","verdict":"momentary","why":"只是那一刻"},{"id":1,"verdict":"ok","relation":"duplicate","of":7}]}"#
        let parsed = try XCTUnwrap(FragmentJudge.parse(raw, expecting: ["1", "2"]))
        XCTAssertEqual(parsed.map(\.id), ["1", "2"])
        XCTAssertEqual(parsed[0], .init(id: "1", verdict: .ok, relation: .duplicate, of: "7"))
        XCTAssertEqual(parsed[1].verdict, .momentary)
        XCTAssertEqual(parsed[1].why, "只是那一刻")
    }

    func testParseRejectsMissingExtraDuplicatedOrUnknown() {
        XCTAssertNil(FragmentJudge.parse(#"{"judgments":[{"id":"1","verdict":"ok"}]}"#, expecting: ["1", "2"]))
        XCTAssertNil(FragmentJudge.parse(#"{"judgments":[{"id":"1","verdict":"ok"},{"id":"9","verdict":"ok"}]}"#, expecting: ["1", "2"]))
        XCTAssertNil(FragmentJudge.parse(#"{"judgments":[{"id":"1","verdict":"ok"},{"id":"1","verdict":"ok"}]}"#, expecting: ["1", "2"]))
        XCTAssertNil(FragmentJudge.parse(#"{"judgments":[{"id":"1","verdict":"好"}]}"#, expecting: ["1"]))
        XCTAssertNil(FragmentJudge.parse("我觉得都不错", expecting: ["1"]))
    }

    func testUnknownRelationOrMissingTargetIsDropped() throws {
        let raw = #"{"judgments":[{"id":"1","verdict":"ok","relation":"similar","of":"3"},{"id":"2","verdict":"ok","relation":"same_topic"}]}"#
        let parsed = try XCTUnwrap(FragmentJudge.parse(raw, expecting: ["1", "2"]))
        XCTAssertNil(parsed[0].relation)
        XCTAssertNil(parsed[0].of)
        XCTAssertNil(parsed[1].relation)
    }

    func testFencedJSONIsAccepted() {
        XCTAssertNotNil(FragmentJudge.parse("```json\n{\"judgments\":[{\"id\":\"1\",\"verdict\":\"ok\"}]}\n```", expecting: ["1"]))
    }

    func testJudgeRetriesOnceThenThrows() async throws {
        var calls = 0
        let good = #"{"judgments":[{"id":"1","verdict":"comfort"}]}"#
        let fixed = try await FragmentJudge.judge(batch: [card("1", "星砚承诺不会离开。")], prior: [], names: names) { _, user in
            calls += 1
            if calls == 2 { XCTAssertTrue(user.contains("重交")) }
            return calls == 1 ? "不是 JSON" : good
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(fixed.first?.verdict, .comfort)
        do {
            _ = try await FragmentJudge.judge(batch: [card("1", "x")], prior: [], names: names) { _, _ in "还是不对" }
            XCTFail("两次都不合格应该抛错")
        } catch {}
        let empty = try await FragmentJudge.judge(batch: [], prior: [], names: names) { _, _ in XCTFail("空批不该调模型"); return nil }
        XCTAssertTrue(empty.isEmpty)
    }

    func testTallyRates() {
        let tally = FragmentJudge.tally([
            .init(id: "1", verdict: .ok),
            .init(id: "2", verdict: .ok, relation: .duplicate, of: "1"),
            .init(id: "3", verdict: .momentary),
            .init(id: "4", verdict: .engineering, relation: .sameTopic, of: "3"),
        ])
        XCTAssertEqual(tally.total, 4)
        XCTAssertEqual(tally.unsatisfied, 2)
        XCTAssertEqual(tally.unsatisfiedRate, 0.5)
        XCTAssertEqual(tally.duplicateRate, 0.25)
        XCTAssertEqual(tally.sameTopicRate, 0.25)
        XCTAssertNil(FragmentJudge.tally([]).unsatisfiedRate)
    }
}
