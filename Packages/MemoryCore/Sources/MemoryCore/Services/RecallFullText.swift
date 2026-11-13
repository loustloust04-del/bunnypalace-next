import Foundation
import NaturalLanguage

public struct RecallFullTextCandidates: Equatable, Sendable {
    public struct Card: Equatable, Sendable {
        public let title: String
        public let gist: String
        public let mentions: [String]
        public var factDomain: SeedFactDomain? = nil

        public init(title: String, gist: String, mentions: [String], factDomain: SeedFactDomain? = nil) {
            self.title = title
            self.gist = gist
            self.mentions = mentions
            self.factDomain = factDomain
        }
    }

    public let profileId: String
    public let text: String
    public let terms: [String]
    public let weights: [String: Double]
    public let status: CatalogRecallIndexStore.Status
    public let hits: [CatalogRecallIndexStore.Hit]
    public var kept: [CatalogRecallIndexStore.Hit] = []

    public init(profileId: String, text: String, terms: [String], weights: [String: Double], status: CatalogRecallIndexStore.Status, hits: [CatalogRecallIndexStore.Hit], kept: [CatalogRecallIndexStore.Hit] = []) {
        self.profileId = profileId
        self.text = text
        self.terms = terms
        self.weights = weights
        self.status = status
        self.hits = hits
        self.kept = kept
    }
}

public enum RecallFullText {
    public static func terms(_ text: String, excluding: [String], tuning: RecallTuning) -> [String] {
        let text = SearchTextSegmenter.normalized(text)
        let blocked = Set(excluding.flatMap { [$0] + Array(RecallLexical.tokens($0, tuning: tuning)) }
            .map { SearchTextSegmenter.normalized($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        let valid = RecallLexical.tokens(text, tuning: tuning)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        var numbers: [String] = []
        var seen = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            guard !blocked.contains(word), seen.insert(word).inserted else { return true }
            if valid.contains(word) { words.append(word) }
            else if word.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }) { numbers.append(word) }
            return true
        }
        let numericLocator = RecallLexical.retrospective(text) && text.range(of: #"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}"#, options: .regularExpression) != nil
            || text.range(of: #"(?:#|编号\s*[:：]?\s*|\b(?:id|no)\s*[.:#]?\s*)\d+"#, options: .regularExpression) != nil
        guard !words.isEmpty || numericLocator else { return [] }
        let allowed = Set(words + numbers)
        var ordered: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if allowed.contains(word), !ordered.contains(word) { ordered.append(word) }
            return true
        }
        return ordered
    }

    public static func query(_ terms: [String], weights: [String: Double], tuning: RecallTuning) -> [String] {
        terms.enumerated().sorted {
            let a = weights[$0.element] ?? 1, b = weights[$1.element] ?? 1
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(max(0, tuning.maximumQueryTerms)).map(\.element)
    }

    public static func ranked(_ batch: RecallFullTextCandidates, text: String, profileId: String,
                       excluding: [String], tuning: RecallTuning,
                       isFinished: @Sendable () -> Bool = { false }) -> [CatalogRecallIndexStore.Hit] {
        guard batch.profileId == profileId, batch.text == text, batch.status.state == .ready else { return [] }
        let allowed = Set(terms(text, excluding: excluding, tuning: tuning))
        let query = batch.terms.filter(allowed.contains)
        guard !query.isEmpty else { return [] }
        let querySet = Set(query)
        let total = query.reduce(0) { $0 + (batch.weights[$1] ?? 1) }
        var owners: [String: Set<String>] = [:]
        for hit in batch.hits {
            guard !isFinished() else { return [] }
            for identity in hit.identities {
                owners[SearchTextSegmenter.normalized(identity), default: []].insert(hit.docId)
            }
        }
        var scored: [(hit: CatalogRecallIndexStore.Hit, count: Int, coverage: Double, exact: Bool)] = []
        for hit in batch.hits {
            guard !isFinished() else { return [] }
            let matched = hit.terms.intersection(querySet)
            let coverage = matched.reduce(0) { $0 + (batch.weights[$1] ?? 1) } / total
            var exact = false
            var unique = false
            for identity in hit.identities {
                let name = SearchTextSegmenter.normalized(identity)
                if matched.contains(name) {
                    exact = true
                    if owners[name]?.count == 1 { unique = true }
                }
            }
            let qualifies = coverage >= tuning.fullTextCoverageThreshold
                && (matched.count == 1
                    ? (exact ? unique : tuning.minimumFullTextTerms <= 1)
                    : matched.count >= tuning.minimumFullTextTerms)
            if qualifies { scored.append((hit, matched.count, coverage, exact)) }
        }
        scored.sort { a, b in
            if a.coverage != b.coverage { return a.coverage > b.coverage }
            if a.count != b.count { return a.count > b.count }
            if a.exact != b.exact { return a.exact }
            if a.hit.bm25 != b.hit.bm25 { return a.hit.bm25 < b.hit.bm25 }
            if a.hit.updatedAt != b.hit.updatedAt { return a.hit.updatedAt > b.hit.updatedAt }
            return a.hit.docId < b.hit.docId
        }
        return scored.map(\.hit)
    }
}

public enum RecallFullTextRetriever {
    public static func fetch(profileId: String, text: String, snapshot: WikiInjectionSnapshot,
                      excluding: @escaping @Sendable () async -> [String], tuning: RecallTuning,
                      source: @escaping @Sendable () -> WikiStore,
                      indexer: CatalogRecallIndexer, timeout: TimeInterval = 5,
                      keeping: [RecallSourceRef] = []) async -> RecallFullTextCandidates {
        let delivery = Delivery()
        let empty: @Sendable () -> RecallFullTextCandidates = {
            .init(profileId: profileId, text: text, terms: [], weights: [:],
                  status: indexer.status(profileId: profileId), hits: [], kept: delivery.kept)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delivery.install(continuation, fallback: empty, timeout: timeout)
                Task.detached(priority: .utility) {
                    MainThreadIO.assertOffMain(.read, "RecallFullTextRetriever.fetch")
                    guard !delivery.finished else { return }
                    var excluded: [String] = []
                    var words: [String] = []
                    if keeping.isEmpty {
                        excluded = await excluding()
                        guard !delivery.finished else { return }
                        words = RecallFullText.terms(text, excluding: excluded + snapshot.stopWords, tuning: tuning)
                        guard !words.isEmpty else { delivery.finish(empty()); return }
                    }
                    do {
                        let wiki = source()
                        guard !delivery.finished else { return }
                        indexer.ensure(profileId: profileId, wiki: wiki)
                        let readyStore = indexer.store(profileId: profileId)
                        if readyStore == nil { try await indexer.waitUntilIdle(profileId: profileId) }
                        guard !delivery.finished, let store = readyStore ?? indexer.store(profileId: profileId) else { delivery.finish(empty()); return }
                        if !keeping.isEmpty {
                            let kept = try store.retained(keeping, snapshot: snapshot, isFinished: { delivery.finished })
                            delivery.keep(kept)
                            guard !delivery.finished else { return }
                        }
                        if readyStore != nil { try await indexer.waitUntilIdle(profileId: profileId) }
                        guard !delivery.finished else { return }
                        if !keeping.isEmpty {
                            excluded = await excluding()
                            guard !delivery.finished else { return }
                            words = RecallFullText.terms(text, excluding: excluded + snapshot.stopWords, tuning: tuning)
                        }
                        guard !delivery.finished else { return }
                        guard !words.isEmpty else { delivery.finish(empty()); return }
                        try await indexer.reconcile(profileId: profileId)
                        guard !delivery.finished else { return }
                        let status = try store.status(profileId: profileId)
                        guard status.state == .ready else { delivery.finish(empty()); return }
                        let weights = try store.queryWeights(terms: words, profileId: profileId, isFinished: { delivery.finished })
                        let query = RecallFullText.query(words, weights: weights, tuning: tuning)
                        let indexed = try store.search(terms: query, profileId: profileId, isFinished: { delivery.finished })
                        let batch = RecallFullTextCandidates(profileId: profileId, text: text, terms: query,
                                                             weights: weights, status: status, hits: indexed)
                        let ranked = RecallFullText.ranked(batch, text: text, profileId: profileId,
                                                           excluding: excluded + snapshot.stopWords, tuning: tuning,
                                                           isFinished: { delivery.finished })
                        let hits = store.verified(ranked, snapshot: snapshot, maximumCount: tuning.maximumPages,
                                                  isFinished: { delivery.finished })
                        guard !delivery.finished else { return }
                        let after = try store.status(profileId: profileId)
                        delivery.finish(.init(profileId: profileId, text: text, terms: query, weights: weights,
                                              status: after, hits: after == status ? hits : [], kept: delivery.kept))
                    } catch {
                        delivery.finish(empty())
                    }
                }
            }
        } onCancel: { delivery.finish(empty()) }
    }

    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RecallFullTextCandidates, Never>?
        private var result: RecallFullTextCandidates?
        private var timer: DispatchWorkItem?
        private var retained: [CatalogRecallIndexStore.Hit] = []
        var kept: [CatalogRecallIndexStore.Hit] { lock.withLock { retained } }

        func keep(_ hits: [CatalogRecallIndexStore.Hit]) {
            lock.withLock { if result == nil { retained = hits } }
        }
        var finished: Bool { lock.withLock { result != nil } }

        func install(_ continuation: CheckedContinuation<RecallFullTextCandidates, Never>,
                     fallback: @escaping @Sendable () -> RecallFullTextCandidates, timeout: TimeInterval) {
            let timer = DispatchWorkItem { self.finish(fallback()) }
            let result: RecallFullTextCandidates? = lock.withLock {
                if let result = self.result { return result }
                self.continuation = continuation
                self.timer = timer
                return nil
            }
            if let result { continuation.resume(returning: result) }
            else { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer) }
        }

        func finish(_ value: RecallFullTextCandidates) {
            let continuation = lock.withLock {
                guard result == nil else { return nil as CheckedContinuation<RecallFullTextCandidates, Never>? }
                result = value
                timer?.cancel()
                timer = nil
                let pending = self.continuation
                self.continuation = nil
                return pending
            }
            continuation?.resume(returning: value)
        }
    }
}
