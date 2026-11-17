import XCTest
@testable import MemoryCore

/// X3：记忆条目只在「聊到了」时带。例子全是虚构的（岚舟 / 星砚 / 槐序巷皮影作坊）。
final class RecallFragmentHitsTests: XCTestCase {
    private let tuning = RecallTestTuning.make()
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, _ text: String, who: String? = nil, priority: Int = 3, age: TimeInterval = 0) -> RecallFragmentDocument {
        RecallFragmentDocument(id: id, tokens: RecallFullText.fragmentTokens(text, tuning: tuning),
                               identities: who.map { [$0] } ?? [], priority: priority, createdAt: day.addingTimeInterval(-age))
    }

    private func hits(_ text: String, _ cards: [RecallFragmentDocument], excluding: [String] = ["岚舟", "星砚"],
                      tuning: RecallTuning? = nil) -> [String] {
        let weights = RecallTokenWeights(tokenDocuments: cards.map(\.tokens))
        return RecallFullText.fragmentHits(text: text, documents: cards, weights: weights,
                                           excluding: excluding, tuning: tuning ?? self.tuning).map(\.id)
    }

    func testUnrelatedSentenceBringsNothing() {
        let cards = [card("a", "槐序巷皮影作坊每周三开门"), card("b", "星砚不吃香菜"), card("c", "云桥城冬天会下雪")]
        XCTAssertEqual(hits("今天帮我看一下这段代码为什么编不过", cards), [])
        XCTAssertEqual(hits("", cards), [])
    }

    func testOneSharedWordIsNotEnough() {
        // 只对上一个词：不带（宁缺毋滥；点名另算，见下）
        let cards = [card("a", "槐序巷皮影作坊每周三开门"), card("b", "皮影戏的灯要用暖光")]
        XCTAssertEqual(hits("最近天气怎么样，想去看皮影", cards), [])
    }

    func testEnoughSharedWeightBringsOnlyThatCard() {
        let cards = [card("a", "槐序巷皮影作坊每周三开门"), card("b", "星砚不吃香菜"), card("c", "云桥城冬天会下雪")]
        XCTAssertEqual(hits("皮影作坊开门了吗", cards), ["a"])
    }

    func testNamedSubjectBringsItsCardsButUserAndAssistantNamesNeverDo() {
        let cards = [card("a", "每周三去学雕皮影", who: "槐序"), card("b", "不吃香菜", who: "星砚"), card("c", "住在云桥城", who: "岚舟")]
        XCTAssertEqual(hits("槐序最近怎么样了呀", cards.map { doc in
            // 调用方（RecallSelection）会先把她和助手自己的名字从 identities 里去掉
            ["星砚", "岚舟"].contains(doc.identities.first ?? "") ? RecallFragmentDocument(
                id: doc.id, tokens: doc.tokens, identities: [], priority: doc.priority, createdAt: doc.createdAt) : doc
        }), ["a"])
    }

    func testLexicalBeatsNamedThenImportanceThenRecency() {
        let cards = [
            card("named-old", "喜欢喝桂花茶", who: "槐序", priority: 3, age: 500),
            card("named-important", "对花生过敏", who: "槐序", priority: 5, age: 900),
            card("named-new", "搬去了云桥城", who: "槐序", priority: 3, age: 10),
            card("lexical", "皮影作坊周三开门"),
        ]
        XCTAssertEqual(hits("槐序说皮影作坊开门了", cards), ["lexical", "named-important", "named-new", "named-old"])
    }

    func testThresholdsAreTheFullTextOnesAndAreTunable() {
        let cards = [card("a", "槐序巷皮影作坊每周三开门")]
        var loose = tuning
        loose.minimumFullTextTerms = 1
        loose.fullTextCoverageThreshold = 0.1
        XCTAssertEqual(hits("最近天气怎么样，想去看皮影", cards, tuning: loose), ["a"])
        var strict = tuning
        strict.fullTextCoverageThreshold = 1
        XCTAssertEqual(hits("皮影作坊今天开门了吗", cards, tuning: strict), [], "这句里还有卡上没有的词，覆盖不到 100%")
    }
}
