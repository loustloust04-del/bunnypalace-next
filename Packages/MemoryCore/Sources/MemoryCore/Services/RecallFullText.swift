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
        // 很长的一句（整段贴进来的日志）不同的词上千个：用集合判重，别在数组里线性找
        var emitted = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if allowed.contains(word), emitted.insert(word).inserted { ordered.append(word) }
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

/// X3 的一张候选卡：词面只算一次（调用方按卡的版本缓存），不带正文。
public struct RecallFragmentDocument: Equatable, Sendable {
    public let id: String
    /// 正文 + 标签的有效词（`RecallFullText.fragmentTokens`）
    public let tokens: Set<String>
    /// 卡上记的「说的是谁」；她和助手自己的名字、「不触发的词」调用方先去掉
    public let identities: [String]
    /// 重要度（没定 = 3）
    public let priority: Int
    public let createdAt: Date

    public init(id: String, tokens: Set<String>, identities: [String], priority: Int, createdAt: Date) {
        self.id = id
        self.tokens = tokens
        self.identities = identities
        self.priority = priority
        self.createdAt = createdAt
    }
}

public extension RecallFullText {
    enum FragmentMatch: String, Equatable, Sendable { case lexical, named }

    /// 这句话里哪些词参加比对：false = 所有的词都算（卡 / 页里没出现过的词分量最重，卡得盖住这句话的大半才算，同全文兜底）；
    /// true = 只算卡 / 页里出现过的词（宽）。
    /// 定 false 的来由（11-14，一份真实楼层快照，304 张卡 × 1.58 万句过了「太短的不找」的话，只数数量）：
    /// false 有 1.1% 的句子至少对上一张卡，true 是 4.8%、对上的张数是 4 倍。多出来的那些是对是错没有人工标注能说明，
    /// 读侧规格「错注比漏注更严重」→ 先取严的。要放宽只改这一个值，改完用 `RecallRealFloorMeasureTests` 再量一遍。
    static let fragmentQueryUsesCorpusTermsOnly = false

    static func fragmentTokens(_ text: String, tuning: RecallTuning) -> Set<String> {
        RecallLexical.tokens(SearchTextSegmenter.normalized(text), tuning: tuning)
    }

    /// X3：一张记忆条目算「聊到了」只有两种（都只看当前这一句，不调模型）——
    /// - lexical：这句话里分量最重的几个词，卡上对上的够多、分量够重。门槛就是全文兜底那一组
    ///   （`maximumQueryTerms` / `minimumFullTextTerms` / `fullTextCoverageThreshold`），不另设数；
    /// - named：这句话点了卡上记的那个人 / 物的名字（同页名触发，按词边界认）。
    /// 排序：lexical 在前（覆盖高的先、对上的词多的先），named 在后；同档重要度高的先、新的先。
    /// 这里不截数量：一轮最多几张由 `RecallTurnState` 按 `maximumFragments` 收，冷却的不占名额。
    static func fragmentHits(text: String, documents: [RecallFragmentDocument], weights: RecallTokenWeights,
                             excluding: [String], tuning: RecallTuning,
                             corpusTermsOnly: Bool = fragmentQueryUsesCorpusTermsOnly) -> [(id: String, match: FragmentMatch)] {
        guard !documents.isEmpty else { return [] }
        let words = terms(text, excluding: excluding, tuning: tuning).filter {
            !corpusTermsOnly || (weights.frequencies[$0] ?? 0) > 0
        }
        let weight = Dictionary(words.map { ($0, weights.weight($0)) }, uniquingKeysWith: { first, _ in first })
        let asked = Set(query(words, weights: weight, tuning: tuning))
        let total = asked.reduce(0) { $0 + (weight[$1] ?? 1) }
        // 点名按名字只判一次（很多卡记的是同一个人），先用子串挡掉绝大多数再走分词边界
        let folded = RecallLexical.normalized(text)
        var namedCache: [String: Bool] = [:]
        func named(_ identities: [String]) -> Bool {
            identities.contains { identity in
                if let known = namedCache[identity] { return known }
                let key = RecallLexical.normalized(identity).trimmingCharacters(in: .whitespacesAndNewlines)
                let result = !key.isEmpty && folded.contains(key) && RecallLexical.names([identity], in: text, tuning: tuning)
                namedCache[identity] = result
                return result
            }
        }
        var scored: [(document: RecallFragmentDocument, match: FragmentMatch, coverage: Double, count: Int)] = []
        for document in documents {
            let matched = document.tokens.intersection(asked)
            let coverage = total > 0 ? matched.reduce(0) { $0 + (weight[$1] ?? 1) } / total : 0
            if !matched.isEmpty, matched.count >= tuning.minimumFullTextTerms, coverage >= tuning.fullTextCoverageThreshold {
                scored.append((document, .lexical, coverage, matched.count))
            } else if named(document.identities) {
                scored.append((document, .named, 0, 0))
            }
        }
        scored.sort { a, b in
            if a.match != b.match { return a.match == .lexical }
            if a.coverage != b.coverage { return a.coverage > b.coverage }
            if a.count != b.count { return a.count > b.count }
            if a.document.priority != b.document.priority { return a.document.priority > b.document.priority }
            if a.document.createdAt != b.document.createdAt { return a.document.createdAt > b.document.createdAt }
            return a.document.id < b.document.id
        }
        return scored.map { ($0.document.id, $0.match) }
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
