import XCTest
@testable import 记忆花园

/// VocabReviewStore：今日队列构建 / 配额供卡 / 加卡去重 / 评分落库推进。
/// 注入 tmp 目录，不碰真存储。
@MainActor
final class VocabReviewQueueTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-vocab-review-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func fakeWord(_ w: String, priority: Int) -> VocabWord {
        VocabWord(word: w, definition: "def-\(w)", categories: [], forms: [],
                  ranks: nil, priority: priority, notes: "", band: "", scanOrder: priority)
    }

    // MARK: - quotaWords 纯函数

    func testQuotaWordsTakesInOrderSkippingKnownAndExisting() {
        let lib = [fakeWord("a", priority: 1), fakeWord("b", priority: 2),
                   fakeWord("c", priority: 3), fakeWord("d", priority: 4)]
        let picked = VocabReviewStore.quotaWords(
            library: lib, existing: ["b"], known: ["a"], quota: 2)
        XCTAssertEqual(picked, ["c", "d"], "跳过已知 a、已有卡 b，按序取 2")
    }

    func testQuotaZeroReturnsEmpty() {
        XCTAssertEqual(VocabReviewStore.quotaWords(
            library: [fakeWord("a", priority: 1)], existing: [], known: [], quota: 0), [])
    }

    // MARK: - addCard

    func testAddCardNormalizesAndDedups() {
        let store = VocabReviewStore(dir: dir)
        XCTAssertTrue(store.addCard(rawWord: " Ephemeral. ", source: "manual"))
        XCTAssertEqual(store.cards.first?.word, "ephemeral")
        XCTAssertFalse(store.addCard(rawWord: "ephemeral", source: "manual"), "重复不加")
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(VocabCardStore.load(dir: dir).count, 1, "落盘")
    }

    // MARK: - 队列

    func testQueueOnlyDueSortedByDueAt() {
        let now = Date()
        var early = VocabCard(word: "early", source: "manual", now: now)
        early.dueAt = now.addingTimeInterval(-86_400)
        var late = VocabCard(word: "late", source: "manual", now: now)
        late.dueAt = now.addingTimeInterval(-3_600)
        var future = VocabCard(word: "future", source: "manual", now: now)
        future.dueAt = now.addingTimeInterval(2 * 86_400)
        VocabCardStore.save([late, future, early], dir: dir)

        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: [], quota: 0, now: now)
        XCTAssertEqual(store.queue, ["early", "late"], "明天到期的不进，due 升序")
    }

    // MARK: - submitRating

    func testSubmitRatingUpdatesCardLogsAndAdvances() throws {
        let now = Date()
        let store = VocabReviewStore(dir: dir)
        store.addCard(rawWord: "alpha", source: "manual", now: now)
        store.addCard(rawWord: "beta", source: "manual", now: now)
        store.bootstrap(knownWords: [], quota: 0, now: now)
        XCTAssertEqual(store.queue.count, 2)
        XCTAssertEqual(store.currentCard?.word, "alpha")

        store.submitRating(.good, exercise: .read, now: now)

        let saved = VocabCardStore.load(dir: dir).first { $0.word == "alpha" }!
        XCTAssertEqual(saved.reps, 1)
        XCTAssertEqual(saved.intervalDays, 1)
        // 落盘走 ISO8601 秒级精度，按 1s 容差比
        XCTAssertEqual(saved.dueAt.timeIntervalSince1970,
                       now.addingTimeInterval(86_400).timeIntervalSince1970, accuracy: 1.0)
        XCTAssertNotNil(saved.lastReviewedAt)
        XCTAssertEqual(store.currentCard?.word, "beta", "游标前进")

        let log = try String(contentsOf: dir.appendingPathComponent("review-log.jsonl"), encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 1)
        XCTAssertTrue(log.contains("\"alpha\""))
    }

    func testSubmitAgainResetsReps() {
        let now = Date()
        var card = VocabCard(word: "gamma", source: "manual", now: now)
        card.reps = 4
        card.intervalDays = 10
        card.dueAt = now
        VocabCardStore.save([card], dir: dir)

        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: [], quota: 0, now: now)
        store.submitRating(.again, exercise: .spell, now: now)
        let saved = VocabCardStore.load(dir: dir)[0]
        XCTAssertEqual(saved.reps, 0)
        XCTAssertEqual(saved.lapses, 1)
    }

    // MARK: - 词书四源（R2-1）

    func testQuotaLibraryNGSLPassthrough() {
        let lib = [fakeWord("a", priority: 1), fakeWord("b", priority: 2)]
        XCTAssertEqual(VocabReviewStore.quotaLibrary(
            source: .ngsl, ngsl: lib, ielts: [], gapWords: [], notebookWords: []).map(\.word),
            ["a", "b"])
    }

    func testQuotaLibraryIELTSJoinsNGSLDefinition() {
        let lib = [fakeWord("abandon", priority: 1)]
        let out = VocabReviewStore.quotaLibrary(
            source: .ielts, ngsl: lib, ielts: ["abandon", "abate"], gapWords: [], notebookWords: [])
        XCTAssertEqual(out.map(\.word), ["abandon", "abate"], "保持表内顺序")
        XCTAssertEqual(out[0].definition, "def-abandon", "NGSL 有的词借释义")
        XCTAssertEqual(out[1].definition, "", "表外词 minimal 条目")
    }

    func testQuotaLibraryGapFiltersNGSL() {
        let lib = [fakeWord("a", priority: 1), fakeWord("b", priority: 2), fakeWord("c", priority: 3)]
        XCTAssertEqual(VocabReviewStore.quotaLibrary(
            source: .gap, ngsl: lib, ielts: [], gapWords: ["c", "a"], notebookWords: []).map(\.word),
            ["a", "c"], "priority 序")
    }

    func testQuotaLibraryNotebookKeepsCallerOrder() {
        let lib = [fakeWord("a", priority: 1)]
        XCTAssertEqual(VocabReviewStore.quotaLibrary(
            source: .notebook, ngsl: lib, ielts: [], gapWords: [], notebookWords: ["z", "a"]).map(\.word),
            ["z", "a"], "收词时间倒序由调用方保证")
    }

    // MARK: - 换词书立即生效（R3.1：今天没碰过的配额卡回收重供）

    func testSwitchingQuotaSourcePurgesUntouchedAndResupplies() {
        let now = Date()
        let ngsl = [fakeWord("be", priority: 1), fakeWord("of", priority: 2)]
        let ielts = [fakeWord("abandon", priority: 1), fakeWord("abate", priority: 2)]

        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: [], quota: 2, now: now, library: ngsl, quotaSourceId: "ngsl")
        XCTAssertEqual(Set(store.cards.map(\.word)), ["be", "of"])

        // 复习掉一张（劳动不回收）
        store.submitRating(.good, exercise: .read, now: now)
        let reviewed = store.cards.first { $0.lastReviewedAt != nil }!.word

        // 切雅思：没碰过的 ngsl 配额卡回收，从雅思补到今日额度
        store.bootstrap(knownWords: [], quota: 2, now: now, library: ielts, quotaSourceId: "ielts")
        let words = Set(store.cards.map(\.word))
        XCTAssertTrue(words.contains(reviewed), "复习过的保留")
        XCTAssertFalse(words.contains(reviewed == "be" ? "of" : "be"), "没碰过的回收")
        XCTAssertEqual(store.cards.filter { $0.quotaSourceId == "ielts" }.count, 1, "补到额度 2（已复习 1 + 新供 1）")
        XCTAssertEqual(words.count, 2)
    }

    func testSwitchingSourcePurgesYesterdaysUntouchedQuotaCards() {
        let now = Date()
        // 昨天供的 NGSL 配额卡（quotaSourceId nil = R3.1 之前的老数据），一次没碰
        var stale = VocabCard(word: "be", source: "quota", now: now.addingTimeInterval(-86_400))
        stale.dueAt = now.addingTimeInterval(-86_400)
        VocabCardStore.save([stale], dir: dir)

        let ielts = [fakeWord("abandon", priority: 1)]
        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: [], quota: 1, now: now, library: ielts, quotaSourceId: "ielts")
        XCTAssertEqual(store.cards.map(\.word), ["abandon"], "昨天的没碰旧供卡也回收")
    }

    func testRemoveCurrentCardDropsFromDeckAndQueue() {
        let now = Date()
        let store = VocabReviewStore(dir: dir)
        store.addCard(rawWord: "alpha", source: "manual", now: now)
        store.addCard(rawWord: "beta", source: "manual", now: now)
        store.bootstrap(knownWords: [], quota: 0, now: now)
        XCTAssertEqual(store.currentCard?.word, "alpha")
        store.removeCurrentCard()
        XCTAssertEqual(store.currentCard?.word, "beta", "游标指向下一张")
        XCTAssertEqual(VocabCardStore.load(dir: dir).map(\.word), ["beta"], "落盘删除")
    }

    func testSameSourceRebootstrapKeepsQuotaCards() {
        let now = Date()
        let lib = [fakeWord("w1", priority: 1), fakeWord("w2", priority: 2)]
        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: [], quota: 2, now: now, library: lib, quotaSourceId: "ngsl")
        store.bootstrap(knownWords: [], quota: 2, now: now, library: lib, quotaSourceId: "ngsl")
        XCTAssertEqual(store.cards.count, 2, "同词书重进不重供不回收")
    }

    // MARK: - 拼写题材料链

    func testSpellMaterialPrefersDefinition() {
        let m = VocabReviewStore.spellMaterial(
            word: "ephemeral", definition: "短暂的", anchorText: "Ephemeral beauty fades.", note: nil)
        XCTAssertEqual(m.prompt, "短暂的")
        XCTAssertFalse(m.degraded)
    }

    func testSpellMaterialClozesAnchorCaseInsensitive() {
        let m = VocabReviewStore.spellMaterial(
            word: "ephemeral", definition: nil, anchorText: "Ephemeral beauty is ephemeral.", note: nil)
        XCTAssertEqual(m.prompt, "“____ beauty is ____.”")
        XCTAssertFalse(m.degraded)
    }

    func testSpellMaterialClozesPhrase() {
        let m = VocabReviewStore.spellMaterial(
            word: "take off", definition: "", anchorText: "The plane will take off soon.", note: nil)
        XCTAssertEqual(m.prompt, "“The plane will ____ soon.”")
    }

    func testSpellMaterialSkipsAnchorWithoutWordFallsToNote() {
        let m = VocabReviewStore.spellMaterial(
            word: "ephemeral", definition: nil, anchorText: "无关句子。", note: "转瞬即逝，蜉蝣朝生暮死")
        XCTAssertEqual(m.prompt, "转瞬即逝，蜉蝣朝生暮死")
        XCTAssertFalse(m.degraded)
    }

    func testSpellMaterialAllMissingDegrades() {
        let m = VocabReviewStore.spellMaterial(word: "x", definition: nil, anchorText: nil, note: nil)
        XCTAssertTrue(m.degraded)
    }

    // MARK: - 配额供卡进队列

    func testBootstrapSuppliesQuotaCards() {
        let now = Date()
        let lib = [fakeWord("w1", priority: 1), fakeWord("w2", priority: 2),
                   fakeWord("w3", priority: 3)]
        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: ["w1"], quota: 2, now: now, library: lib)
        XCTAssertEqual(Set(store.cards.map(\.word)), ["w2", "w3"])
        XCTAssertTrue(store.cards.allSatisfy { $0.source == "quota" })
        XCTAssertEqual(store.queue.count, 2, "新卡当天到期进队列")

        // 同日重复 bootstrap 不重复供卡
        store.bootstrap(knownWords: ["w1"], quota: 2, now: now, library: lib)
        XCTAssertEqual(store.cards.count, 2, "今天已供满，不再补")
    }

    // MARK: - 每日复习上限

    func testCapRemaining() {
        XCTAssertEqual(VocabReviewStore.capRemaining(cap: 50, reviewedToday: 0), 50)
        XCTAssertEqual(VocabReviewStore.capRemaining(cap: 50, reviewedToday: 30), 20)
        XCTAssertEqual(VocabReviewStore.capRemaining(cap: 50, reviewedToday: 80), 0, "超量不出负数")
    }

    func testBootstrapDailyCapTruncatesQueue() {
        let now = Date()
        let lib = (1...8).map { fakeWord("w\($0)", priority: $0) }
        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: [], quota: 8, now: now, library: lib, dailyCap: 3)
        XCTAssertEqual(store.cards.count, 8, "供卡不受 cap 影响（cap 只截队列）")
        XCTAssertEqual(store.queue.count, 3, "今日队列被日上限截断")

        // cap 0 = 不限
        let store2 = VocabReviewStore(dir: FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-cap-tests-\(UUID().uuidString)", isDirectory: true))
        store2.bootstrap(knownWords: [], quota: 8, now: now, library: lib, dailyCap: 0)
        XCTAssertEqual(store2.queue.count, 8)
    }

    func testDailyCapCountsReviewedToday() {
        let now = Date()
        let lib = (1...5).map { fakeWord("w\($0)", priority: $0) }
        let store = VocabReviewStore(dir: dir)
        store.bootstrap(knownWords: [], quota: 5, now: now, library: lib, dailyCap: 3)
        // 复习掉 2 张
        store.submitRating(.good, exercise: .read, now: now)
        store.submitRating(.good, exercise: .read, now: now)
        // 重新 bootstrap（模拟切 tab 回来）：今日已复习 2，只剩 1 个名额
        store.bootstrap(knownWords: [], quota: 5, now: now, library: lib, dailyCap: 3)
        XCTAssertEqual(store.queue.count, 1, "cap 扣掉今日已复习数")
    }
}
