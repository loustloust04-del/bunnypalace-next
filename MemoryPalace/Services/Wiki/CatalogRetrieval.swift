import Foundation

/// C3 两种写手共用的检索；只带值快照，f 编号始终来自原快照。
struct CatalogRetrieval: Sendable {
    typealias OriginalSearch = @Sendable ([String], DateInterval?, CatalogCancel) async -> [SearchService.CatalogNode]

    let memoryRoot: URL
    let fragments: [CatalogFragment]
    var conversationIds: Set<String>? = nil
    var embedder: any MemoryEmbedding = AppleMemoryEmbedder.shared
    var originalSearch: OriginalSearch? = nil

    enum Limits {
        static let hits = 10
        static let chars = 6000
    }

    private enum Candidate {
        case original(SearchService.CatalogNode)
        case aline(CatalogALineReader.Hit)
        case fragment(CatalogFragment)

        var key: Key {
            switch self {
            case .original(let node): return .original(node.profileId, node.nodeId)
            case .aline(let hit):
                return .aline(hit.layer.rawValue, hit.conversationId ?? "", hit.day, hit.segment, hit.start, hit.end, hit.bodyText)
            case .fragment(let fragment): return .fragment(fragment.id)
            }
        }

        var body: String {
            switch self {
            case .original(let node): node.body
            case .aline(let hit): hit.bodyText
            case .fragment(let fragment): fragment.content
            }
        }

        var weight: Double {
            switch self {
            case .original: 1.2
            case .aline: 1.1
            case .fragment: 1.0
            }
        }
    }

    private enum Key: Hashable {
        case original(String, String)
        case aline(String, String, String, Int?, Date, Date, String)
        case fragment(UUID)
    }

    struct Result: Sendable {
        let originals: [SearchService.CatalogNode]
        let aline: CatalogALineReader.Result
        let fragments: [CatalogFragment]
        let labels: [UUID: String]
        let vectorStatus: String
        let receipt: CatalogSearchReceipt

        init(aline: CatalogALineReader.Result, fragments: [CatalogFragment], labels: [UUID: String], vectorStatus: String,
             originals: [SearchService.CatalogNode] = [], cancel: CatalogCancel? = nil) {
            self.labels = labels
            self.vectorStatus = vectorStatus
            var seen = Set<Key>()
            var candidates: [Candidate] = []
            for candidate in originals.map(Candidate.original) + aline.hits.map(Candidate.aline) + fragments.map(Candidate.fragment) {
                if cancel?.isCancelled == true { break }
                if seen.insert(candidate.key).inserted { candidates.append(candidate) }
            }
            var documents: [[String]] = []
            for candidate in candidates {
                if cancel?.isCancelled == true { break }
                documents.append(MemoryBM25.document(content: candidate.body, keywords: []))
            }
            let scores = MemoryBM25.scores(documents: documents, query: aline.terms.joined(separator: "\n"), cancel: cancel)
            let order = (cancel?.isCancelled == true ? [] : Array(candidates.indices)).sorted {
                let lhs = scores[$0] * candidates[$0].weight
                let rhs = scores[$1] * candidates[$1].weight
                return lhs != rhs ? lhs > rhs : $0 < $1
            }
            var receipt = CatalogSearchReceipt(vectorStatus: vectorStatus)
            receipt.append("搜「\(aline.terms.joined(separator: " / "))」：原文、A 线、已留碎片三路召回，统一相关度排序。\n")
            receipt.append("向量：\(vectorStatus)\n助手发言只作上下文，不是用户事实；写作时跳过不相关原料。\n")
            var hits: [CatalogALineReader.Hit] = []
            var selected: [CatalogFragment] = []
            var nodes: [SearchService.CatalogNode] = []
            var remaining = Limits.chars
            var truncated = false
            for index in order {
                if cancel?.isCancelled == true { break }
                guard hits.count + selected.count + nodes.count < Limits.hits, remaining > 0 else {
                    truncated = true
                    break
                }
                var entry = CatalogSearchReceipt(vectorStatus: vectorStatus)
                switch candidates[index] {
                case .original(let node):
                    entry.append("\n\n【原文】profileId=\(node.profileId) · conversationId=\(node.conversationId) · nodeId=\(node.nodeId) · \(node.created.map { ISO8601DateFormatter().string(from: $0) } ?? "时间未知") · \(node.role == "assistant" ? "助手发言（非用户事实）" : "用户发言") · \(node.onMain ? "主线" : "支线")\n")
                    entry.appendBody(node.body, kind: .original, source: .original(node))
                case .aline(let hit):
                    entry.append("\n\n【\(hit.layer.rawValue)】\n")
                    entry.appendALine(hit)
                case .fragment(let fragment):
                    let label = labels[fragment.id] ?? ""
                    // 归因不进正文区间；放在正文前，正文截断后仍保留归因。
                    entry.append("\n\n- \(label) · \(fragment.day) · \(fragment.status) · \(fragment.attributionText) · ")
                    entry.appendBody(fragment.content, kind: .fragment, source: .fragment(label, fragment))
                }
                if entry.bodyChars > remaining {
                    entry = entry.bodyPrefix(remaining)
                    entry.append(CatalogAgentTools.clipNote)
                    truncated = true
                }
                guard entry.bodyChars > 0 else { continue }
                remaining -= entry.bodyChars
                receipt.appendReceipt(entry)
                switch candidates[index] {
                case .original(let node): nodes.append(node)
                case .aline(let hit): hits.append(hit)
                case .fragment(let fragment): selected.append(fragment)
                }
            }
            self.originals = nodes
            self.aline = .init(terms: aline.terms, hits: hits, found: aline.found, truncated: truncated)
            self.fragments = selected
            self.receipt = receipt
        }
    }

    func search(_ terms: [String], in range: DateInterval? = nil, fragmentsOnly: Bool = false,
                excludingFragmentIds: Set<UUID> = [], cancel: CatalogCancel = CatalogCancel()) async -> Result {
        await cancel.withTaskCancellation {
            let words = WikiStore.normalizedWords(terms)
            let empty = CatalogALineReader.Result(terms: words, hits: [], found: [:])
            func cancelled() -> Result {
                Result(aline: empty, fragments: [], labels: [:], vectorStatus: "已取消", cancel: cancel)
            }
            guard !cancel.isCancelled else { return cancelled() }
            async let originals = fragmentsOnly || cancel.isCancelled ? [] : originalSearch?(words, range, cancel) ?? []
            async let aline = Task.detached(priority: .utility) {
                fragmentsOnly || cancel.isCancelled ? empty
                    : RecallTool.searchALine(terms: words, in: range, memoryRoot: memoryRoot,
                                             conversationIds: conversationIds, cancel: cancel)
            }.value
            async let fragmentResult = Task.detached(priority: .utility) {
                var byId: [UUID: CatalogFragment] = [:]
                var labels: [UUID: String] = [:]
                var candidates: [MemoryRetrievalDocument] = []
                for (index, fragment) in fragments.enumerated() where byId[fragment.id] == nil {
                    guard !cancel.isCancelled else { break }
                    byId[fragment.id] = fragment
                    labels[fragment.id] = CatalogSorter.label(index)
                    if let range, let day = MemoryDay.date(ofKey: fragment.day) {
                        let start = MemoryDay.boundary(of: day)
                        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
                        guard start < range.end && end > range.start else { continue }
                    }
                    candidates.append(fragment.retrievalDocument)
                }
                let found = MemoryRetrieval.search(query: words.joined(separator: "\n"), documents: candidates,
                                                   embedder: embedder, cancel: cancel)
                return (found.ids.filter { !excludingFragmentIds.contains($0) }.compactMap { byId[$0] }, labels, found.vectorStatus)
            }.value
            let (nodes, a, f) = await (originals, aline, fragmentResult)
            guard !cancel.isCancelled else { return cancelled() }
            return Result(aline: a, fragments: f.0, labels: f.1, vectorStatus: f.2, originals: nodes, cancel: cancel)
        }
    }
}
