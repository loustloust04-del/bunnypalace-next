import MemoryCore
import XCTest
@testable import 记忆花园

final class RecallFullTextTests: XCTestCase {
    private let tuning = RecallTestTuning.make()

    private func hit(_ id: String, terms: Set<String>, identities: [String] = [],
                     score: Double = -1, updated: TimeInterval = 1) -> CatalogRecallIndexStore.Hit {
        .init(docId: id, kind: .page, path: "主题/\(id)", version: "v1", cardKey: nil, parents: [],
              terms: terms, identities: identities,
              updatedAt: Date(timeIntervalSince1970: updated), card: nil, bm25: score)
    }

    private func batch(_ query: [String], hits: [CatalogRecallIndexStore.Hit], weights: [String: Double] = [:],
                       state: CatalogRecallIndexStore.State = .ready) -> RecallFullTextCandidates {
        .init(profileId: "fictional-floor", text: query.joined(separator: " "), terms: query, weights: weights,
              status: .init(state: state, epoch: 1), hits: hits)
    }

    private func ranked(_ value: RecallFullTextCandidates, tuning: RecallTuning? = nil) -> [String] {
        RecallFullText.ranked(value, text: value.text, profileId: value.profileId, excluding: [], tuning: tuning ?? self.tuning).map(\.docId)
    }

    func testCardInjectionPreservesDeclaredDomainWithoutInventingLegacyReality() {
        let cases: [(SeedFactDomain?, String?)] = [
            (.realWorld, nil), (.inWorld, "域：设定（非本人现实经历）"),
            (.mixed, "域：待判（未确认为现实）"), (.unspecified, "域：待判（未确认为现实）"), (nil, nil),
        ]
        for (domain, line) in cases {
            let card = RecallFullTextCandidates.Card(title: "云桥城", gist: "夜航概览", mentions: [], factDomain: domain)
            let block = WikiInjection.cardBlock(card, path: "memory/cc/云桥城.md", version: "v1", parents: [])
            XCTAssertEqual(block.components(separatedBy: "\n"),
                [WikiInjection.hitsTitle, "条目：云桥城"] + (line.map { [$0] } ?? [])
                    + ["要点：夜航概览", "下钻：memory/cc/云桥城.md|v1"])
        }
    }

    func testWordBoundariesLengthsExclusionsAndNumericLocators() {
        XCTAssertEqual(RecallFullText.terms("ＣＥＤＡＲ cedar ab xy 73 maple", excluding: ["maple"], tuning: tuning), ["cedar", "73"])
        XCTAssertEqual(RecallFullText.terms("岚舟 星砚 cedar", excluding: ["岚舟", "星砚"], tuning: tuning), ["cedar"])
        XCTAssertEqual(RecallFullText.terms("林", excluding: [], tuning: tuning), [])
        XCTAssertEqual(RecallFullText.terms("17 83", excluding: [], tuning: tuning), [])
        XCTAssertEqual(RecallFullText.terms("#731", excluding: [], tuning: tuning), ["731"])
        XCTAssertEqual(RecallFullText.terms("2026-10-31", excluding: [], tuning: tuning), ["2026", "10", "31"])
        XCTAssertEqual(RecallFullText.terms("2026-02-31", excluding: [], tuning: tuning), [])
    }

    func testIDFRanksDistinctWordsAndRetainsOriginalOrderOnTies() {
        var limited = tuning
        limited.maximumQueryTerms = 2
        let words = RecallFullText.terms("cedar maple orivale cedar", excluding: [], tuning: limited)
        XCTAssertEqual(RecallFullText.query(words, weights: ["cedar": 1, "maple": 3, "orivale": 3], tuning: limited), ["maple", "orivale"])
        limited.maximumQueryTerms = 1
        XCTAssertEqual(RecallFullText.query(words, weights: [:], tuning: limited), ["cedar"])
    }

    func testWeightedCoverageBoundaryAndMinimumDistinctEvidence() {
        let value = batch(["cedar", "maple", "orivale"], hits: [hit("a", terms: ["cedar", "maple"])],
                          weights: ["cedar": 2, "maple": 1, "orivale": 2])
        XCTAssertEqual(ranked(value), ["a"])
        var stricter = tuning
        stricter.fullTextCoverageThreshold = 0.600001
        XCTAssertEqual(ranked(value, tuning: stricter), [])
        stricter = tuning
        stricter.minimumFullTextTerms = 3
        XCTAssertEqual(ranked(value, tuning: stricter), [])
        XCTAssertEqual(ranked(batch(["cedar", "maple"], hits: [hit("weak", terms: ["cedar"], score: -999)])), [])
    }

    func testSingleNonIdentityTermRespectsMinimumAndCoverageWithoutBypassingNameConflicts() {
        let value = batch(["orivale", "cedar", "maple"], hits: [hit("rare", terms: ["orivale"])])
        var permissive = tuning
        permissive.minimumFullTextTerms = 1
        permissive.fullTextCoverageThreshold = 0.3
        XCTAssertEqual(ranked(value, tuning: permissive), ["rare"])
        permissive.minimumFullTextTerms = 2
        XCTAssertEqual(ranked(value, tuning: permissive), [])
        permissive.minimumFullTextTerms = 1
        permissive.fullTextCoverageThreshold = 0.4
        XCTAssertEqual(ranked(value, tuning: permissive), [])
        permissive.fullTextCoverageThreshold = 0.3
        let ambiguous = batch(["orivale"], hits: [
            hit("north", terms: ["orivale"], identities: ["Orivale"]),
            hit("south", terms: ["orivale"], identities: ["Orivale"])
        ])
        XCTAssertEqual(ranked(ambiguous, tuning: permissive), [])
    }

    func testSingleIdentityRequiresExactUniquePublicName() {
        XCTAssertEqual(ranked(batch(["orivale"], hits: [hit("a", terms: ["orivale"], identities: ["Orivale"])])), ["a"])
        XCTAssertEqual(ranked(batch(["orivale"], hits: [hit("a", terms: ["orivale"], identities: ["Orivale North"])])), [])
        let ambiguous = [hit("a", terms: ["orivale"], identities: ["Orivale"]),
                         hit("b", terms: ["orivale"], identities: ["Orivale"])]
        XCTAssertEqual(ranked(batch(["orivale"], hits: ambiguous)), [])
        XCTAssertEqual(ranked(batch(["orivale", "cedar"], hits: [
            hit("a", terms: ["orivale", "cedar"], identities: ["Orivale"]), ambiguous[1]
        ])), ["a"])
        let single = hit("unique", terms: ["orivale"], identities: ["Orivale"])
        XCTAssertEqual(ranked(batch(["orivale", "cedar"], hits: [single], weights: ["orivale": 2, "cedar": 1])), ["unique"])
        XCTAssertEqual(ranked(batch(["orivale", "cedar"], hits: [single], weights: ["orivale": 1, "cedar": 2])), [])
    }

    func testEvidenceThenIdentityThenBM25ApprovedUpdateAndStableID() {
        let value = batch(["cedar", "maple", "orivale"], hits: [
            hit("body", terms: ["cedar", "maple"], score: -99),
            hit("identity", terms: ["cedar", "maple"], identities: ["cedar"], score: -1),
            hit("full", terms: ["cedar", "maple", "orivale"], score: 0)
        ])
        XCTAssertEqual(ranked(value), ["full", "identity", "body"])
        let ties = batch(["cedar", "maple"], hits: [hit("z", terms: ["cedar", "maple"]),
            hit("a", terms: ["cedar", "maple"]), hit("new", terms: ["cedar", "maple"], updated: 2),
            hit("score", terms: ["cedar", "maple"], score: -2)])
        XCTAssertEqual(ranked(ties), ["score", "new", "a", "z"])
    }

    func testBuildingWrongFloorPreviousQuestionAndExcludedNamesCannotPush() {
        let value = batch(["cedar", "maple"], hits: [hit("a", terms: ["cedar", "maple"])])
        XCTAssertEqual(RecallFullText.ranked(value, text: "unrelated question", profileId: value.profileId,
                                            excluding: [], tuning: tuning), [])
        XCTAssertEqual(RecallFullText.ranked(value, text: value.text, profileId: "another-floor",
                                            excluding: [], tuning: tuning), [])
        XCTAssertEqual(ranked(batch(["cedar", "maple"], hits: value.hits, state: .building)), [])
        XCTAssertEqual(RecallFullText.ranked(value, text: value.text, profileId: value.profileId,
                                            excluding: ["cedar", "maple"], tuning: tuning), [])
    }
    func testCandidateDeadlineReturnsWithoutWaitingForBlockedSource() async throws {
        let f = try RecallFullTextFixture()
        let gate = DispatchSemaphore(value: 0)
        let wiki = f.wiki
        let result = await RecallFullTextRetriever.fetch(
            profileId: f.profileId, text: "cedar maple", snapshot: .init(), excluding: { [] }, tuning: tuning,
            source: { gate.wait(); return wiki }, indexer: .shared, timeout: 0.05)
        XCTAssertEqual(result.status.state, .empty, "源尚未返回，索引并未开始构建；超时不能伪报 building")
        XCTAssertEqual(result.hits, [])
        gate.signal()
        await f.clean()
    }

    func testCancellationReturnsWithoutWaitingForBlockedSource() async throws {
        let f = try RecallFullTextFixture()
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "source entered")
        let wiki = f.wiki
        let task = Task {
            await RecallFullTextRetriever.fetch(
                profileId: f.profileId, text: "cedar maple", snapshot: .init(), excluding: { [] }, tuning: tuning,
                source: { entered.fulfill(); gate.wait(); return wiki }, indexer: .shared)
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.hits, [])
        gate.signal()
        await f.clean()
    }

    func testDeadlinePreservesIndependentlyVerifiedKeptCard() async throws {
        let f = try RecallFullTextFixture()
        let card = try f.card()
        try f.page(cards: [card])
        let (snapshot, _) = await f.fetch("cedar maple")
        let ref = RecallSourceRef(profileId: f.profileId, kind: .card, path: card.path, version: card.version)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "kept verified before query work")
        let wiki = f.wiki
        let task = Task {
            await RecallFullTextRetriever.fetch(
                profileId: f.profileId, text: "later question", snapshot: snapshot,
                excluding: { entered.fulfill(); gate.wait(); return [] }, tuning: tuning,
                source: { wiki }, indexer: .shared, timeout: 1, keeping: [ref])
        }
        await fulfillment(of: [entered], timeout: 3)
        let result = await task.value
        gate.signal()
        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.kept.map(\.path), [card.path])
        XCTAssertEqual(result.kept.first?.card?.gist, card.gist)
        await f.clean()
    }

    func testCommonWordQueryHydratesOnlyAvailablePageSlotsAndRefillsStaleRows() async throws {
        try await Task.detached {
            let f = try RecallFullTextFixture()
            for number in 0..<40 {
                let card = try f.card("memory/cc/合成卡\(number).md")
                try f.page("主题/合成页\(number)", title: "cedar", now: "maple", cards: [card])
            }
            let wiki = f.wiki
            let snapshot = WikiInjection.load(wiki)
            CatalogRecallIndexer.shared.ensure(profileId: f.profileId, wiki: wiki)
            try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: f.profileId)
            let store = try XCTUnwrap(CatalogRecallIndexer.shared.store(profileId: f.profileId))
            let tuning = RecallTestTuning.make()
            let parked = f.root.appendingPathComponent("parked-wiki")
            try FileManager.default.moveItem(at: wiki.root, to: parked)
            let indexed = try store.search(terms: ["cedar", "maple"], profileId: f.profileId)
            XCTAssertEqual(indexed.count, 80)
            try FileManager.default.moveItem(at: parked, to: wiki.root)
            let batch = RecallFullTextCandidates(profileId: f.profileId, text: "cedar maple", terms: ["cedar", "maple"],
                                                 weights: [:], status: try store.status(profileId: f.profileId), hits: indexed)
            let ranked = RecallFullText.ranked(batch, text: batch.text, profileId: f.profileId, excluding: [], tuning: tuning)
            var opened: [String] = []
            let verified = store.verified(ranked, snapshot: snapshot, maximumCount: tuning.maximumPages,
                                          onRead: { opened.append($0) })
            XCTAssertEqual(verified.map(\.docId), Array(ranked.prefix(tuning.maximumPages)).map(\.docId))
            XCTAssertEqual(verified.count, tuning.maximumPages)
            XCTAssertLessThanOrEqual(opened.count, tuning.maximumPages)
            let first = try XCTUnwrap(ranked.first)
            try FileManager.default.removeItem(at: wiki.pageURL(first.path))
            let refilled = store.verified(ranked, snapshot: snapshot, maximumCount: tuning.maximumPages)
            XCTAssertEqual(refilled.map(\.docId), Array(ranked.dropFirst().prefix(tuning.maximumPages)).map(\.docId))
            XCTAssertEqual(try store.search(terms: ["cedar"], profileId: f.profileId, isFinished: { true }), [])
            var cancelledReads = 0
            XCTAssertEqual(store.verified(ranked, snapshot: snapshot, maximumCount: tuning.maximumPages,
                                          isFinished: { true }, onRead: { _ in cancelledReads += 1 }), [])
            XCTAssertEqual(cancelledReads, 0)
            await f.clean()
        }.value
    }

}

struct RecallFullTextFixture: Sendable {
    let root: URL
    let wiki: WikiStore
    let profileId: String

    init(profileId: String = "fulltext-fictional-\(UUID().uuidString)") throws {
        self.profileId = profileId
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fulltext-fictional-\(UUID().uuidString)")
        wiki = WikiStore(root: root.appendingPathComponent("memory/wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
    }

    func card(_ path: String = "memory/cc/合成原料.md", version: String = "v1", title: String = "合成航线卡",
              gist: String = "cedar maple", mentions: [SeedNoteCard.Mention] = []) throws -> SeedNoteCard {
        let value = SeedNoteCard(path: path, version: version, name: title, layer: "CC", title: title, gist: gist,
                                 mentions: mentions, aboutUser: false, group: "主题", when: [], model: "fixture",
                                 madeAt: Date(timeIntervalSince1970: 1_000), run: .init(path: "fixture"))
        try SeedNoteStore(wiki: wiki).save(value)
        return value
    }

    func page(_ path: String = "主题/合成父页", title: String = "合成父页", now: String = "父页当前正文",
              validUntil: String? = nil, records: [String] = [], cards: [SeedNoteCard] = []) throws {
        try wiki.saveRaw(WikiPage(path: path, hook: "合成钩子", title: title, now: now, validUntil: validUntil, records: records,
                                 entries: cards.map { $0.path + "|" + $0.version }).markdown, path: path)
    }

    func fetch(_ text: String, tuning: RecallTuning = RecallTestTuning.make(),
               keeping: [RecallSourceRef] = []) async -> (WikiInjectionSnapshot, RecallFullTextCandidates) {
        let wiki = wiki
        let snapshot = await Task.detached { WikiInjection.load(wiki) }.value
        let candidates = await RecallFullTextRetriever.fetch(profileId: profileId, text: text, snapshot: snapshot,
                                                              excluding: { [] }, tuning: tuning, source: { wiki }, indexer: .shared, keeping: keeping)
        return (snapshot, candidates)
    }

    func clean() async {
        CatalogRecallIndexer.shared.deleteProfile(profileId, wiki: wiki)
        try? await CatalogRecallIndexer.shared.waitUntilIdle(profileId: profileId)
        try? FileManager.default.removeItem(at: root)
    }
}
