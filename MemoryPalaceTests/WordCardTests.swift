import XCTest
import SwiftData
@testable import 记忆花园

/// 生词卡 card-word（research-chat-cards §14）
@MainActor
final class WordCardTests: XCTestCase {

    // MARK: - 解析

    func testParse() {
        guard case .word(let w)? = ChatCard.parse(language: "card-word", code: #"{"word":" ephemeral ","note":"短暂的那个"}"#)
        else { return XCTFail() }
        XCTAssertEqual(w.word, "ephemeral")
        XCTAssertEqual(w.note, "短暂的那个")
        XCTAssertNil(ChatCard.word(w).id, "生词卡不需要 id，不参与版本判定")
        XCTAssertEqual(ChatCard.word(w).kindLabel, "生词")
    }

    func testShortAliasAndRequiredWord() {
        XCTAssertNotNil(ChatCard.parse(language: "word", code: #"{"word":"run"}"#))
        XCTAssertNil(ChatCard.parse(language: "card-word", code: #"{"note":"x"}"#))
        XCTAssertNil(ChatCard.parse(language: "card-word", code: #"{"word":"  "}"#))
        XCTAssertNil(ChatCard.parse(language: "card-word", code: "{\"word\":\"\(String(repeating: "a", count: 65))\"}"))
    }

    func testBlockTextRoundTrips() {
        let card = ChatCard.word(WordCard(word: "ephemeral", note: nil))
        XCTAssertTrue(card.blockText.hasPrefix("```card-word\n"))
        XCTAssertEqual(ChatCardExtractor.cards(in: card.blockText), [card])
    }

    // MARK: - 文字

    func testSummary() {
        XCTAssertEqual(WordCardText.summary(status: nil, inNotebook: false), "还没收进词库")
        XCTAssertEqual(WordCardText.summary(status: .unknown, inNotebook: true), "在词库 · 不认识")
        XCTAssertEqual(WordCardText.summary(status: .slow, inNotebook: true), "在词库 · 不熟")
        XCTAssertEqual(WordCardText.summary(status: .known, inNotebook: false), "没收进词库 · 认识")
    }

    func testEventText() {
        XCTAssertEqual(WordCardText.added("ephemeral"), "把 ephemeral 加进了词库")
        XCTAssertEqual(WordCardText.markedKnown("ephemeral"), "把 ephemeral 标成了认识")
    }

    func testGuideTellsModel() {
        let text = ChatCardPromptGuide.text
        XCTAssertTrue(text.contains("```card-word"), "语言名列表里有 card-word")
        XCTAssertTrue(text.contains("card-word：生词卡"))
        XCTAssertTrue(text.contains("date（可选"), "待办卡的 date")
    }

    // MARK: - 标记（从 markCurrent 抽出来的静态 upsert）

    private func context() throws -> ModelContext {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func progress(_ word: String, _ ctx: ModelContext) -> [VocabProgress] {
        (try? ctx.fetch(FetchDescriptor<VocabProgress>(predicate: #Predicate { $0.word == word }))) ?? []
    }

    func testMarkInsertsThenUpdatesInPlace() throws {
        let ctx = try context()
        VocabSessionStore.mark(word: "ephemeral", status: .unknown, seconds: 3, note: "旧笔记", source: "test", context: ctx)
        VocabSessionStore.mark(word: "ephemeral", status: .known, seconds: nil, note: nil, source: "test", context: ctx)
        let rows = progress("ephemeral", ctx)
        XCTAssertEqual(rows.count, 1, "同一个词只一条")
        XCTAssertEqual(rows.first?.status, .known)
        XCTAssertEqual(rows.first?.note, "旧笔记", "note 不传不动")
        XCTAssertEqual(rows.first?.seconds, 3, "seconds 不传不动")
    }
}
