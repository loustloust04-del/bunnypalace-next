#if PERSONAL_APPS
#if DEBUG
import XCTest
@testable import 记忆花园

/// 话题盒 store：宽松解析 / 序列化往返 / 掉落引擎 / 账本对账 / 归档。
/// 全程临时目录 + 注入日期/种子——零真库零真文件库。
final class TopicBoxStoreTests: XCTestCase {

    var root: URL!
    var ledgerURL: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("topicbox-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: TopicBoxStore.topicsURL(rootURL: root), withIntermediateDirectories: true)
        ledgerURL = root.appendingPathComponent("ledger.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func put(_ relPath: String, _ content: String) {
        try! TopicBoxStore.writeCard(relPath: relPath, markdown: content, rootURL: root)
    }

    /// 固定序列 RNG：依次吐 values（不够就循环）——掉落 count / shuffle 可复现。
    private struct SeededRNG: RandomNumberGenerator {
        var values: [UInt64]
        var i = 0
        mutating func next() -> UInt64 {
            defer { i += 1 }
            return values[i % values.count]
        }
    }

    // MARK: 解析

    func testParseStandardCard() {
        let md = """
        ---
        created: 2026-07-12
        author: 禾禾
        source: book:abc#page=42
        ---
        什么是自我？

        引文：一段说明。

        ## 回应

        ### 2026-07-12 · 禾禾
        第一条想法。
        跨两行。

        ### 2026-07-13 · 助手
        第二条。
        """
        let card = TopicBoxStore.parse(markdown: md, relPath: "topics/什么是自我.md")
        XCTAssertEqual(card.title, "什么是自我？")
        XCTAssertEqual(card.author, "禾禾")
        XCTAssertEqual(card.created, "2026-07-12")
        XCTAssertEqual(card.source, "book:abc#page=42")
        XCTAssertTrue(card.body.contains("引文：一段说明。"))
        XCTAssertEqual(card.responses.count, 2)
        XCTAssertEqual(card.responses[0].author, "禾禾")
        XCTAssertEqual(card.responses[0].text, "第一条想法。\n跨两行。")
        XCTAssertEqual(card.responses[1].date, "2026-07-13")
        XCTAssertFalse(card.isArchived)
    }

    func testParseLenientVariants() {
        // 无 frontmatter
        let a = TopicBoxStore.parse(markdown: "痛苦是必要的吗\n\n补一句。",
                                    relPath: "topics/a.md")
        XCTAssertEqual(a.title, "痛苦是必要的吗")
        XCTAssertNil(a.author)
        XCTAssertTrue(a.responses.isEmpty)

        // 有 frontmatter 无回应节，标题带 # 前缀
        let b = TopicBoxStore.parse(markdown: "---\nauthor: 助手\n---\n# 时间是幻觉吗",
                                    relPath: "topics/b.md")
        XCTAssertEqual(b.title, "时间是幻觉吗")
        XCTAssertEqual(b.author, "助手")

        // 空文件 → 文件名兜底
        let c = TopicBoxStore.parse(markdown: "", relPath: "topics/空空.md")
        XCTAssertEqual(c.title, "空空")

        // archived 路径判定
        let d = TopicBoxStore.parse(markdown: "x", relPath: "topics/archived/老题.md")
        XCTAssertTrue(d.isArchived)
    }

    func testParseWeirdSectionHeaderMergesIntoPrevious() {
        let md = """
        问题

        ## 回应

        ### 2026-07-12 · 禾禾
        正常回应。

        ### 随手写的小标题
        这段不该丢。
        """
        let card = TopicBoxStore.parse(markdown: md, relPath: "topics/q.md")
        XCTAssertEqual(card.responses.count, 1)
        XCTAssertTrue(card.responses[0].text.contains("正常回应。"))
        XCTAssertTrue(card.responses[0].text.contains("### 随手写的小标题"))
        XCTAssertTrue(card.responses[0].text.contains("这段不该丢。"))
    }

    // MARK: 序列化

    func testSerializeParseRoundTrip() {
        let md = TopicBoxStore.newCardMarkdown(
            title: "意识是涌现的吗？", body: "> 引自某书", author: "禾禾",
            source: "chat#node-1", created: "2026-07-12")
        var current = md
        current = TopicBoxStore.appendResponseMarkdown(
            existing: current, date: "2026-07-12", author: "禾禾", text: "我觉得是。")
        current = TopicBoxStore.appendResponseMarkdown(
            existing: current, date: "2026-07-13", author: "助手", text: "补充一个角度。")

        let card = TopicBoxStore.parse(markdown: current, relPath: "topics/x.md")
        XCTAssertEqual(card.title, "意识是涌现的吗？")
        XCTAssertEqual(card.source, "chat#node-1")
        XCTAssertTrue(card.body.contains("> 引自某书"))
        XCTAssertEqual(card.responses.count, 2)
        XCTAssertEqual(card.responses[0].text, "我觉得是。")
        XCTAssertEqual(card.responses[1].author, "助手")
    }

    func testAppendResponseAddsHeaderOnlyOnce() {
        let base = "裸问题，AI 写的没节头"
        let one = TopicBoxStore.appendResponseMarkdown(
            existing: base, date: "2026-07-12", author: "A", text: "一")
        XCTAssertEqual(one.components(separatedBy: TopicBoxStore.responsesHeader).count, 2)
        let two = TopicBoxStore.appendResponseMarkdown(
            existing: one, date: "2026-07-12", author: "B", text: "二")
        XCTAssertEqual(two.components(separatedBy: TopicBoxStore.responsesHeader).count, 2)
        let card = TopicBoxStore.parse(markdown: two, relPath: "topics/x.md")
        XCTAssertEqual(card.responses.count, 2)
    }

    // MARK: 文件名

    func testSanitizeAndUniqueRelPath() {
        XCTAssertEqual(TopicBoxStore.sanitizeFileName("什么是/自我:真的*吗?"), "什么是自我真的吗")
        XCTAssertEqual(TopicBoxStore.sanitizeFileName("  \n "), "未命名话题")
        XCTAssertEqual(TopicBoxStore.sanitizeFileName(String(repeating: "长", count: 60)).count, 40)

        let p1 = try! TopicBoxStore.createCard(title: "同名", body: "", author: "A",
                                               source: nil, rootURL: root)
        let p2 = try! TopicBoxStore.createCard(title: "同名", body: "", author: "A",
                                               source: nil, rootURL: root)
        XCTAssertEqual(p1, "topics/同名.md")
        XCTAssertEqual(p2, "topics/同名-2.md")
    }

    // MARK: 掉落引擎

    func testDropsIdempotentSameDay() {
        put("topics/a.md", "A")
        put("topics/b.md", "B")
        put("topics/c.md", "C")
        var rng = SeededRNG(values: [0, 1, 2, 3])
        let first = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                   today: "2026-07-12", rng: &rng)
        let ledgerAfterFirst = TopicBoxStore.loadLedger(ledgerURL: ledgerURL)
        var rng2 = SeededRNG(values: [7, 8, 9])
        let second = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                    today: "2026-07-12", rng: &rng2)
        XCTAssertEqual(first, second)
        XCTAssertEqual(TopicBoxStore.loadLedger(ledgerURL: ledgerURL), ledgerAfterFirst)
    }

    func testDropsPreferNeverDroppedThenOldest() {
        put("topics/老题.md", "老")
        put("topics/新题.md", "新")
        put("topics/更老.md", "更老")
        var ledger = TopicDropLedger()
        ledger.history = ["topics/老题.md": "2026-07-10", "topics/更老.md": "2026-07-01"]
        TopicBoxStore.saveLedger(ledger, ledgerURL: ledgerURL)

        // count 抽 2（Int.random(in:1...2) 用注入序列控制）：没掉过的「新题」必在，第二个 = 最久没掉的「更老」
        for seed in [UInt64(0), 1, 5, 42] {
            try? FileManager.default.removeItem(at: ledgerURL)
            TopicBoxStore.saveLedger(ledger, ledgerURL: ledgerURL)
            var rng = SeededRNG(values: [seed, seed &+ 1, seed &+ 2, seed &+ 3, seed &+ 4])
            let picks = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                       today: "2026-07-12", rng: &rng)
            XCTAssertEqual(picks.first, "topics/新题.md", "seed \(seed)：没掉过的优先")
            if picks.count == 2 {
                XCTAssertEqual(picks[1], "topics/更老.md", "seed \(seed)：其次最久没掉")
            }
        }
    }

    func testDropsPoolBoundaries() {
        // 空池：不掉、不盖日期戳（当天晚些投题还能掉）
        var rng = SeededRNG(values: [0])
        XCTAssertEqual(TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                      today: "2026-07-12", rng: &rng), [])
        XCTAssertEqual(TopicBoxStore.loadLedger(ledgerURL: ledgerURL).lastDropDate, "")

        // 池 1 个：掉 1
        put("topics/唯一.md", "唯一")
        var rng2 = SeededRNG(values: [9])
        let picks = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                   today: "2026-07-12", rng: &rng2)
        XCTAssertEqual(picks, ["topics/唯一.md"])
        XCTAssertEqual(TopicBoxStore.loadLedger(ledgerURL: ledgerURL).lastDropDate, "2026-07-12")
    }

    func testReconcileRemovesDeletedFiles() {
        put("topics/留.md", "留")
        put("topics/删.md", "删")
        var rng = SeededRNG(values: [UInt64.max, UInt64.max, UInt64.max, UInt64.max])   // next()=max → count=2 全掉
        let picks = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                   today: "2026-07-12", rng: &rng)
        XCTAssertEqual(Set(picks), Set(["topics/留.md", "topics/删.md"]))

        try! FileManager.default.removeItem(at: root.appendingPathComponent("topics/删.md"))
        var rng2 = SeededRNG(values: [0])
        let after = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                   today: "2026-07-12", rng: &rng2)
        XCTAssertEqual(after, ["topics/留.md"])
        let ledger = TopicBoxStore.loadLedger(ledgerURL: ledgerURL)
        XCTAssertNil(ledger.history["topics/删.md"])
    }

    func testArchiveExcludedFromPoolAndList() throws {
        put("topics/留.md", "留")
        put("topics/收.md", "收")
        let newPath = try TopicBoxStore.archive(relPath: "topics/收.md", rootURL: root)
        XCTAssertEqual(newPath, "topics/archived/收.md")

        XCTAssertEqual(TopicBoxStore.listTopLevelRelPaths(rootURL: root), ["topics/留.md"])
        XCTAssertEqual(TopicBoxStore.listArchivedRelPaths(rootURL: root), ["topics/archived/收.md"])

        var rng = SeededRNG(values: [1, 1, 1])
        let picks = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                   today: "2026-07-12", rng: &rng)
        XCTAssertEqual(picks, ["topics/留.md"])

        let cards = TopicBoxStore.listCards(rootURL: root)
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards.first { $0.relPath == newPath }!.isArchived)
    }

    func testNewDayRedrops() {
        put("topics/a.md", "A")
        put("topics/b.md", "B")
        var rng = SeededRNG(values: [0, 0, 0])   // count=1
        let d1 = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                today: "2026-07-12", rng: &rng)
        XCTAssertEqual(d1.count, 1)
        var rng2 = SeededRNG(values: [0, 0, 0])
        let d2 = TopicBoxStore.ensureTodayDrops(rootURL: root, ledgerURL: ledgerURL,
                                                today: "2026-07-13", rng: &rng2)
        XCTAssertEqual(d2.count, 1)
        // 第二天：a 已掉过，没掉过的 b 优先
        XCTAssertNotEqual(d1, d2)
        let ledger = TopicBoxStore.loadLedger(ledgerURL: ledgerURL)
        XCTAssertEqual(ledger.lastDropDate, "2026-07-13")
        XCTAssertEqual(ledger.history.count, 2)
    }
}
#endif
#endif
