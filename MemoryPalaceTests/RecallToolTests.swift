import MemoryCore
import XCTest
@testable import 记忆花园

/// recall 的检索排序、证据截面与记忆日边界。
final class RecallToolTests: XCTestCase {


    private func ranked(_ importances: [Int?]) -> [Memory] {
        importances.enumerated().map { i, imp in
            let m = Memory(content: "第\(i)名", category: "fact", profileId: "xctest-recall-priority")
            m.importance = imp
            return m
        }
    }

    func testWeightByPriorityKeepsOrderWhenAllUnsetOrThree() {
        let unset = ranked(Array(repeating: nil, count: 8))
        XCTAssertEqual(RecallTool.weightByPriority(unset).map(\.content), unset.map(\.content), "全没定：名次一点不变")
        let three = ranked(Array(repeating: 3, count: 8))
        XCTAssertEqual(RecallTool.weightByPriority(three).map(\.content), three.map(\.content), "全是 3：名次一点不变")
    }

    /// 重要度 5 在第 13 名以内压过 3 的第 1 名、第 31 名以内压过 1 的第 1 名；再往后相关度占上风
    /// 有效重要度（10-17 astra #5）：没定 = 3，越界的夹到 1–5，极值不溢出
    func testEffectiveImportanceClamps() {
        let cases: [(Int?, Int)] = [(nil, 3), (0, 1), (6, 5), (Int.min, 1), (Int.max, 5), (1, 1), (5, 5), (-3, 1)]
        for (raw, want) in cases {
            XCTAssertEqual(Memory.effectiveImportance(raw), want, "\(String(describing: raw))")
            let m = Memory(content: "x", category: "fact", profileId: "xctest-recall-priority")
            m.importance = raw
            XCTAssertEqual(m.recallPriority, want)
        }
        // 越界的按夹过的值加权：Int.max = 5、Int.min = 1，不崩、不压过同档
        let list = ranked([Int.min, 5, Int.max, 0, 6])
        XCTAssertEqual(RecallTool.weightByPriority(list).map(\.content), ["第1名", "第2名", "第4名", "第0名", "第3名"])
    }

    func testWeightByPriorityBoundaries() {
        var list: [Int?] = [3] + Array(repeating: nil, count: 11) + [5]          // 5 在第 13 名（下标 12）
        XCTAssertEqual(RecallTool.weightByPriority(ranked(list)).first?.content, "第12名")
        list = [3] + Array(repeating: nil, count: 12) + [5]                      // 5 在第 14 名
        XCTAssertEqual(RecallTool.weightByPriority(ranked(list)).first?.content, "第0名")
        list = [1] + Array(repeating: 1, count: 29) + [5]                        // 5 在第 31 名，前面全是 1
        XCTAssertEqual(RecallTool.weightByPriority(ranked(list)).first?.content, "第30名")
        list = [1] + Array(repeating: 1, count: 30) + [5]                        // 5 在第 32 名
        XCTAssertEqual(RecallTool.weightByPriority(ranked(list)).first?.content, "第0名")
    }


    func testCenteredSnippetShortTextUnchanged() {
        XCTAssertEqual(RecallTool.centeredSnippet("短文本", keyword: "短", limit: 100), "短文本")
    }

    func testCenteredSnippetKeywordLate() {
        let text = String(repeating: "前", count: 500) + "目标词尾部"
        let snippet = RecallTool.centeredSnippet(text, keyword: "目标词", limit: 100)
        XCTAssertTrue(snippet.contains("目标词"))
        XCTAssertTrue(snippet.count <= 102)   // limit + 前后省略号
        XCTAssertTrue(snippet.hasPrefix("…"))
    }

    func testCenteredSnippetKeywordMissingFallsBackToPrefix() {
        let text = String(repeating: "字", count: 500)
        let snippet = RecallTool.centeredSnippet(text, keyword: "不存在", limit: 100)
        XCTAssertEqual(snippet.count, 101)    // 100 + 截断号
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testCenteredSnippetCaseInsensitive() {
        let text = String(repeating: "x", count: 400) + "HELLO world" + String(repeating: "y", count: 400)
        XCTAssertTrue(RecallTool.centeredSnippet(text, keyword: "hello", limit: 50).contains("HELLO"))
    }

    // MARK: - parseDay / inRange

    func testParseDayValidAndInvalid() {
        XCTAssertNotNil(RecallTool.parseDay("2026-06-12"))
        XCTAssertNil(RecallTool.parseDay("2026/06/12"))
        XCTAssertNil(RecallTool.parseDay("不是日期"))
        XCTAssertNil(RecallTool.parseDay(""))
        XCTAssertNil(RecallTool.parseDay(nil))
    }

    /// 刀6：before 不含当天（说明文字与代码一致）
    func testBeforeExcludesThatDay() throws {
        let r = try RecallTool.resolveRange(date: nil, after: "2026-09-29", before: "2026-09-30").get()
        let day29 = RecallTool.parseDay("2026-09-29")!
        let day30 = RecallTool.parseDay("2026-09-30")!
        XCTAssertTrue(RecallTool.inRange(day29.addingTimeInterval(23 * 3600), after: r.after, beforeExclusive: r.beforeExclusive))
        XCTAssertFalse(RecallTool.inRange(day30, after: r.after, beforeExclusive: r.beforeExclusive))
    }

    func testDateIsSingleDay() throws {
        let r = try RecallTool.resolveRange(date: "2026-09-29", after: nil, before: nil).get()
        let day = RecallTool.parseDay("2026-09-29")!
        XCTAssertEqual(r.after, day)
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        XCTAssertTrue(RecallTool.inRange(next.addingTimeInterval(-1), after: r.after, beforeExclusive: r.beforeExclusive))
        XCTAssertFalse(RecallTool.inRange(next, after: r.after, beforeExclusive: r.beforeExclusive))
    }

    func testRangeRejectsBadFormatAndInvertedBounds() {
        if case .success = RecallTool.resolveRange(date: "2026/09/29", after: nil, before: nil) { XCTFail("格式错要报错") }
        if case .success = RecallTool.resolveRange(date: nil, after: "2026-09-30", before: "2026-09-30") { XCTFail("before ≤ after 要报错") }
        if case .failure = RecallTool.resolveRange(date: nil, after: nil, before: nil) { XCTFail("都不给 = 不限") }
    }

    func testInRangeBoundsAndNilDate() {
        let after = RecallTool.parseDay("2026-06-01")!
        let before = RecallTool.parseDay("2026-06-10", endOfDay: true)!
        XCTAssertTrue(RecallTool.inRange(after, after: after, beforeExclusive: before))    // 下界含
        XCTAssertFalse(RecallTool.inRange(after.addingTimeInterval(-1), after: after, beforeExclusive: before))
        XCTAssertFalse(RecallTool.inRange(nil, after: nil, beforeExclusive: nil))          // 无时间戳的不进时间过滤结果
    }
}

final class RecordingMemoryEmbedder: MemoryEmbedding, @unchecked Sendable {
    let isReady: Bool
    let revision: Int
    private let vector: [Float]?
    private let lock = NSLock()
    private var texts: [String] = []

    init(ready: Bool = true, revision: Int = 7, vector: [Float]? = [1, 0]) {
        isReady = ready
        self.revision = revision
        self.vector = vector
    }

    var embeddedTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }

    func embed(_ text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        texts.append(text)
        return vector
    }
}

final class MemoryRetrievalTests: XCTestCase {
    private func document(_ text: String, id: UUID = UUID(), vector: [Float]? = nil,
                          revision: Int? = nil, keywords: [String] = []) -> MemoryRetrievalDocument {
        MemoryRetrievalDocument(id: id, content: text, keywords: keywords,
                                embeddingData: vector.map { MemoryVector.data(from: $0) }, embeddingRevision: revision)
    }

    func testBM25ScoresEveryPositionAndIgnoresShortLatinQueries() {
        let scores = MemoryBM25.scores(documents: [["orbit"], [], ["marble", "marble"]], query: "ORBIT")
        XCTAssertEqual(scores.count, 3)
        XCTAssertGreaterThan(scores[0], 0)
        XCTAssertEqual(scores[1], 0)
        XCTAssertEqual(scores[2], 0)
        XCTAssertEqual(MemoryBM25.scores(documents: [["orbit"], []], query: "a"), [0, 0])
    }

    func testBM25RetainsPositiveScoresWhenEveryDocumentContainsTheTerm() {
        for corpus in [[["orbit"]], [["orbit"], ["orbit"]]] {
            let scores = MemoryBM25.scores(documents: corpus, query: "orbit")
            XCTAssertEqual(scores.count, corpus.count)
            for score in scores {
                XCTAssertTrue(score.isFinite)
                XCTAssertGreaterThan(score, 0, "单文档和全库共有词也必须有正 IDF")
            }
        }
    }

    func testChineseKeywordBoostRanksMatchedMemoriesWithoutAdmittingSingleCharacters() {
        let plain = Memory(content: "云桥城地图画好了", category: "fact", profileId: "synthetic-keywords")
        let boosted = Memory(content: plain.content, category: "fact", keywords: ["云桥城"], profileId: "synthetic-keywords")
        let unrelated = Memory(content: "云 桥 城", category: "fact", keywords: ["云", "桥", "城"], profileId: "synthetic-keywords")
        let hits = KeywordRetriever(excludePersistent: false).retrieve([plain, unrelated, boosted], recent: ["云桥城"])
        XCTAssertEqual(hits.map { $0.memory.id }, [boosted.id, plain.id])
    }

    func testShortHanSegmentsRequireEveryBigramAndRemainORWithOtherTerms() {
        for query in ["张小明", "云桥城地图册"] {
            let documents = [query + "记录完成", String(query.dropFirst()), String(query.dropLast())]
                .map { MemoryBM25.document(content: $0, keywords: []) }
            let scores = MemoryBM25.scores(documents: documents, query: query)
            XCTAssertGreaterThan(scores[0], 0)
            XCTAssertEqual(Array(scores.dropFirst()), [0, 0])
        }
        let documents = ["小明 orbit", "orbit"].map { MemoryBM25.document(content: $0, keywords: []) }
        XCTAssertEqual(MemoryBM25.scores(documents: documents, query: "张小明 orbit"),
                       MemoryBM25.scores(documents: documents, query: "orbit"), "不完整姓名不能借另一段的命中追加分数")
        let full = Memory(content: "张小明完成了航图", category: "fact", profileId: "synthetic-short")
        let partial = Memory(content: "小明整理了记录", category: "fact", keywords: ["小明"], profileId: "synthetic-short")
        let hits = KeywordRetriever(excludePersistent: false).retrieve([partial, full], recent: ["张小明"])
        XCTAssertEqual(hits.map { $0.memory.id }, [full.id])
    }

    func testLongHanCommonTermCutoffUsesCandidateCountAndStrictDocumentFrequency() {
        let query = "上次说的旅行计划"
        func scores(count: Int, common: Int) -> [Double] {
            let corpus = Array(repeating: "上次", count: common) + Array(repeating: "灯塔", count: count - common)
            return MemoryBM25.scores(documents: corpus.map { MemoryBM25.document(content: $0, keywords: []) }, query: query)
        }
        XCTAssertEqual(scores(count: 19, common: 19).filter { $0 > 0 }.count, 19, "小语料不丢高频双字")
        XCTAssertEqual(scores(count: 20, common: 10).filter { $0 > 0 }.count, 10, "df/n 等于 0.5 仍保留")
        XCTAssertEqual(scores(count: 20, common: 11), Array(repeating: 0, count: 20))
        let corpus = Array(repeating: MemoryBM25.document(content: "上次", keywords: []), count: 20)
        XCTAssertTrue(MemoryBM25.scores(documents: corpus, query: "上次").allSatisfy { $0 > 0 }, "两字查询不套长段高频门槛")
    }

    func testSixAndSevenHanBoundaryAndMixedScriptSegments() {
        let maps = [MemoryBM25.document(content: "地图", keywords: [])]
        XCTAssertEqual(MemoryBM25.scores(documents: maps, query: "云桥城地图画"), [0])
        XCTAssertGreaterThan(MemoryBM25.scores(documents: maps, query: "云桥城地图画好")[0], 0)
        for (query, contents, expected) in [
            ("云桥城v2", ["云桥城新版", "v2 release", "桥城旧版"], Set([0, 1])),
            ("用Swift写", ["Swift 记录", "用Swift写地图", "用纸写记录"], Set([0, 1])),
            ("地图", ["地图画好了", "地理记录", "图册整理"], Set([0])),
        ] {
            let scores = MemoryBM25.scores(documents: contents.map { MemoryBM25.document(content: $0, keywords: []) }, query: query)
            XCTAssertEqual(Set(scores.indices.filter { scores[$0] > 0 }), expected)
        }
    }

    func testCompatibilityNormalizationMatchesWidthInBothDirections() {
        for (wide, normalized) in [("ＡＢＣ", "abc"), ("１２３４", "1234"), ("ｶﾀｶﾅ", "カタカナ")] {
            let wideDoc = document(wide)
            let normalDoc = document(normalized)
            let unrelated = document("orbit meadow")
            for query in [wide, normalized] {
                let result = MemoryRetrieval.search(query: query, documents: [wideDoc, unrelated, normalDoc],
                                                    embedder: RecordingMemoryEmbedder(ready: false))
                XCTAssertEqual(Set(result.ids), Set([wideDoc.id, normalDoc.id]))
            }
            let keywordOnly = document("灯塔", keywords: [wide])
            XCTAssertEqual(MemoryRetrieval.search(query: normalized, documents: [keywordOnly],
                                                  embedder: RecordingMemoryEmbedder(ready: false)).ids, [keywordOnly.id])
        }
    }

    func testKeywordRetrieverKeepsPinnedRecallButExcludesItFromInjectionCandidates() {
        let pinned = Memory(content: "orbit", category: "fact", profileId: "synthetic", isUserExplicit: true)
        let ordinary = Memory(content: "orbit marble", category: "fact", keywords: ["orbit"], profileId: "synthetic")
        let candidates = [pinned, ordinary]
        let recalled = KeywordRetriever(excludePersistent: false).retrieve(candidates, recent: ["orbit"])
        XCTAssertEqual(Set(recalled.map { $0.memory.id }), Set(candidates.map(\.id)))
        XCTAssertEqual(KeywordRetriever().retrieve(candidates, recent: ["orbit"]).map { $0.memory.id }, [ordinary.id])
    }

    func testVectorOnlyRecallDeduplicatesAndEmbedsQueryOnceWithoutBackfill() {
        let embedder = RecordingMemoryEmbedder()
        let hit = document("marble orbit", vector: [1, 0], revision: 7)
        let stale = document("velvet lantern", vector: [1, 0], revision: 6)
        let missing = document("copper meadow")
        let result = MemoryRetrieval.search(query: "midnight compass", documents: [hit, hit, stale, missing], embedder: embedder)
        XCTAssertEqual(result.ids, [hit.id])
        XCTAssertEqual(embedder.embeddedTexts, ["midnight compass"])
        XCTAssertEqual(result.vectorStatus, "向量部分不可用（2 条没算出来），命中 1 条")
        XCTAssertEqual(result.failedCount, 2)
        XCTAssertEqual(result.validVectorCount, 1)
        XCTAssertNil(missing.embeddingData)
        XCTAssertEqual(stale.embeddingRevision, 6)
    }

    func testUnavailableAndReadyZeroRemainDistinctAndEmptyNeverEmbeds() {
        let candidate = document("marble orbit", vector: [0, 1], revision: 7)
        let unavailable = RecordingMemoryEmbedder(ready: false)
        let unavailableResult = MemoryRetrieval.search(query: "midnight", documents: [candidate], embedder: unavailable)
        XCTAssertTrue(unavailableResult.ids.isEmpty)
        XCTAssertTrue(unavailableResult.vectorStatus.contains("不可用"))
        XCTAssertTrue(unavailable.embeddedTexts.isEmpty)
        let ready = RecordingMemoryEmbedder()
        let zero = MemoryRetrieval.search(query: "midnight", documents: [candidate], embedder: ready)
        XCTAssertTrue(zero.ids.isEmpty)
        XCTAssertTrue(zero.vectorStatus.contains("0"))
        XCTAssertFalse(zero.vectorStatus.contains("不可用"))
        _ = MemoryRetrieval.search(query: "midnight", documents: [], embedder: ready)
        XCTAssertEqual(ready.embeddedTexts, ["midnight"])
        XCTAssertTrue(MemoryRetrieval.search(query: "midnight", documents: [], embedder: unavailable).vectorStatus.contains("不可用"))
        let failed = RecordingMemoryEmbedder(vector: nil)
        XCTAssertTrue(MemoryRetrieval.search(query: "midnight", documents: [candidate], embedder: failed).vectorStatus.contains("不可用"))
    }

    func testEncodingFailureIsUnavailableAndNextQueryCanRecoverWithoutInternalRetry() {
        let embedder = CatalogFakeEmbedder()
        let candidate = document("marble orbit", vector: [1, 0], revision: embedder.revision)
        let first = MemoryRetrieval.search(query: "midnight", documents: [candidate], embedder: embedder)
        XCTAssertEqual(first.ids, [])
        XCTAssertTrue(first.vectorStatus.contains("不可用"))
        XCTAssertEqual(embedder.calls, ["midnight"])

        embedder.vectors["midnight"] = [1, 0]
        let next = MemoryRetrieval.search(query: "midnight", documents: [candidate], embedder: embedder)
        XCTAssertEqual(next.ids, [candidate.id])
        XCTAssertFalse(next.vectorStatus.contains("不可用"))
        XCTAssertEqual(embedder.calls, ["midnight", "midnight"])
    }

    func testVectorRankingKeepsThresholdTopKAndStableTies() {
        let documents = (0..<25).map { document("marble \($0)", vector: [1, 0], revision: 7) }
        let result = MemoryRetrieval.search(query: "midnight", documents: documents, embedder: RecordingMemoryEmbedder())
        XCTAssertEqual(result.ids, documents.prefix(VectorRetriever.topK).map(\.id))
        let below = document("velvet", vector: [0.34, 0], revision: 7)
        XCTAssertTrue(MemoryRetrieval.search(query: "midnight", documents: [below], embedder: RecordingMemoryEmbedder()).ids.isEmpty)
    }

    func testBackfillOnlyMissingOrOldSnapshotsAndLeavesInputsUntouched() {
        let fresh = document("fresh orbit", vector: [0, 1], revision: 7)
        let stale = document("stale meadow", vector: [0, 1], revision: 6)
        let missing = document("missing lantern")
        let embedder = RecordingMemoryEmbedder()
        let documents = [fresh, stale, missing, missing]
        let result = MemoryEmbeddingBackfill.fill(documents, embedder: embedder)
        let filled = result.documents
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.validVectorCount, 3)
        XCTAssertEqual(embedder.embeddedTexts, [stale.content, missing.content])
        XCTAssertEqual(filled.map(\.id), documents.map(\.id))
        XCTAssertEqual(filled[0].embeddingData, fresh.embeddingData)
        XCTAssertTrue(filled.allSatisfy { $0.embeddingRevision == 7 && $0.embeddingData != nil })
        XCTAssertEqual(stale.embeddingRevision, 6)
        XCTAssertNil(missing.embeddingData)
        let unavailable = RecordingMemoryEmbedder(ready: false)
        XCTAssertNil(MemoryEmbeddingBackfill.fill([missing], embedder: unavailable).documents[0].embeddingData)
        XCTAssertTrue(unavailable.embeddedTexts.isEmpty)
    }

    func testRRFUsesOrderedIDsAndDoesNotCountDuplicateRouteHits() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        XCTAssertEqual(MemoryRankFusion.fuse([[first, first, second], [second, third]]), [second, first, third])
        XCTAssertEqual(MemoryRankFusion.fuse([[first], [second]]), [first, second])
        XCTAssertEqual(MemoryRankFusion.fuse([["a", "a", "b"], ["b", "c"]]), ["b", "a", "c"])
    }
}
