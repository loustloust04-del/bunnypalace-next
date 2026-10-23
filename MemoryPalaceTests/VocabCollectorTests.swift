import XCTest
import SwiftData
@testable import 记忆花园

/// CR-3 书词打通写入口 + aiNote 回填的纯逻辑测试（内存库）。
final class VocabCollectorTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    var deckDir: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: VocabProgress.self, MessageNode.self, configurations: config)
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: "pendingVocabAsk")
        // collect() 的进复习 hook 重定向到 tmp——测试永不写真 cards.json（07-08 污染教训）
        deckDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-vocab-collector-\(UUID().uuidString)")
        VocabCollector.reviewDeckDir = deckDir
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "pendingVocabAsk")
        VocabCollector.reviewDeckDir = VocabCardStore.defaultDir
        try? FileManager.default.removeItem(at: deckDir)
        container = nil
        super.tearDown()
    }

    // MARK: - normalize

    func testNormalizeStripsPunctuationAndLowercases() {
        XCTAssertEqual(VocabCollector.normalize("  Serendipity, "), "serendipity")
        XCTAssertEqual(VocabCollector.normalize("\u{201C}Abandon!\u{201D}"), "abandon")
        // 短语保留内部空格
        XCTAssertEqual(VocabCollector.normalize("Give Up."), "give up")
    }

    // MARK: - collect

    func testCollectNewWordStartsUnknownWithSource() {
        let word = VocabCollector.collect(
            rawText: "Serendipity,", bookSafeName: "mybook", chapter: 3, anchorStart: 120, context: context
        )
        XCTAssertEqual(word, "serendipity")
        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .unknown)
        XCTAssertEqual(all[0].sourceBookRef, "mybook#chapter3#120")
    }

    func testCollectExistingWordKeepsStatusUpdatesSource() {
        let existing = VocabProgress(word: "abandon", status: .known, seconds: 5)
        context.insert(existing)
        try! context.save()

        _ = VocabCollector.collect(
            rawText: "abandon", bookSafeName: "mybook", chapter: 7, anchorStart: 42, context: context
        )
        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertEqual(all.count, 1, "已有词补出处不建新条")
        XCTAssertEqual(all[0].status, .known, "不动学习状态")
        XCTAssertEqual(all[0].sourceBookRef, "mybook#chapter7#42")
    }

    // MARK: - collectManually（学习卡 ✨ / 生词本搜索收词）

    func testCollectManuallyNewWordGetsManualSource() {
        let word = VocabCollector.collectManually(rawText: "Serendipity ", context: context)
        XCTAssertEqual(word, "serendipity")
        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertEqual(all.first?.sourceBookRef, VocabCollector.manualSource)
        XCTAssertEqual(all.first?.status, .unknown)
    }

    func testCollectManuallyKeepsBookSourceAndStatus() {
        let existing = VocabProgress(word: "abandon", status: .known, seconds: 5)
        existing.sourceBookRef = "mybook#chapter3#10"
        context.insert(existing)
        try! context.save()

        _ = VocabCollector.collectManually(rawText: "abandon", context: context)
        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.sourceBookRef, "mybook#chapter3#10", "书出处不被 manual 覆盖")
        XCTAssertEqual(all.first?.status, .known)
    }

    // MARK: - fillAINote

    private func makeAssistantNode(id: String, conversationId: String, content: String) {
        let node = MessageNode(
            id: id, role: "assistant", content: content, contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: conversationId
        )
        context.insert(node)
        try! context.save()
    }

    func testFillAINoteWritesAnswerAndClearsPending() {
        makeAssistantNode(id: "n1", conversationId: "c1", content: "abandon 的词源是……")
        VocabCollector.recordPendingAsk(word: "abandon", conversationId: "c1")

        VocabCollector.fillAINote(nodeId: "n1", conversationId: "c1", context: context)

        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertEqual(all.first?.aiNote, "abandon 的词源是……")
        XCTAssertNotNil(all.first?.aiNoteAt)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "pendingVocabAsk"), "回填后清 pending")
    }

    func testFillAINoteIgnoresOtherConversation() {
        makeAssistantNode(id: "n1", conversationId: "c-other", content: "无关回答")
        VocabCollector.recordPendingAsk(word: "abandon", conversationId: "c1")

        VocabCollector.fillAINote(nodeId: "n1", conversationId: "c-other", context: context)

        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertTrue(all.isEmpty, "对话不匹配不回填")
        XCTAssertNotNil(UserDefaults.standard.dictionary(forKey: "pendingVocabAsk"), "pending 保留等真回复")
    }

    // MARK: - R2-4 聊天划词

    func testSentenceContaining() {
        let text = "第一句话。The plane will take off soon! 最后一句"
        let range = text.range(of: "take off")!
        XCTAssertEqual(VocabCollector.sentence(containing: range, in: text),
                       "The plane will take off soon!")
        let r2 = text.range(of: "第一句")!
        XCTAssertEqual(VocabCollector.sentence(containing: r2, in: text), "第一句话。")
        let r3 = text.range(of: "最后")!
        XCTAssertEqual(VocabCollector.sentence(containing: r3, in: text), "最后一句")
    }

    func testCollectManuallyWithAnchor() {
        let word = VocabCollector.collectManually(rawText: "Brazen", anchor: "A brazen attempt.", context: context)
        XCTAssertEqual(word, "brazen")
        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertEqual(all.first?.anchorText, "A brazen attempt.")
    }

    func testCollectHookWritesToInjectedDeckDirOnly() {
        VocabCollector.collect(rawText: "serendipity", bookSafeName: "b", chapter: 1, anchorStart: 0, context: context)
        XCTAssertEqual(VocabCardStore.load(dir: deckDir).map(\.word), ["serendipity"], "hook 落注入目录")
    }

    func testFillAINoteAppendsNotOverwrites() {
        let existing = VocabProgress(word: "abandon", status: .slow, seconds: 3)
        existing.aiNote = "第一次注解"
        context.insert(existing)
        try! context.save()

        makeAssistantNode(id: "n2", conversationId: "c1", content: "第二次注解")
        VocabCollector.recordPendingAsk(word: "abandon", conversationId: "c1")
        VocabCollector.fillAINote(nodeId: "n2", conversationId: "c1", context: context)

        let all = try! context.fetch(FetchDescriptor<VocabProgress>())
        XCTAssertEqual(all.first?.aiNote, "第一次注解\n\n---\n\n第二次注解", "追加分隔，不可删对方笔迹")
    }
}
