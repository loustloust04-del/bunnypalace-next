import Foundation

/// 卡和卡之间「字面上有多像」（plan-organize-agent §3.10）：给整理 agent 当帮手——列卡时把相近的排在一起、
/// 让它能问「和这张相近的还有哪些」。纯代码，不调模型；只是提示，怎么并还是它自己定。
/// 像不像按「共有的词有多稀罕」算（常见词几乎不计分），词的切法沿用 `MemoryBM25.tokens`（汉字相邻双字）
public struct OrganizeNeighbors: Sendable {
    private let ids: [String]
    private let index: [String: Int]
    /// 每张卡的词 → 权重（越稀罕越重），已经归一成单位长度
    private let vectors: [[String: Double]]

    public init(cards: [OrganizeCard]) {
        ids = cards.map(\.id)
        index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let sets = cards.map { Set(MemoryBM25.tokens($0.content)) }
        var df: [String: Int] = [:]
        for set in sets { for term in set { df[term, default: 0] += 1 } }
        let n = Double(max(cards.count, 1))
        vectors = sets.map { set in
            var weights: [String: Double] = [:]
            for term in set { weights[term] = log(1 + n / Double(df[term] ?? 1)) }
            let length = sqrt(weights.values.reduce(0) { $0 + $1 * $1 })
            return length > 0 ? weights.mapValues { $0 / length } : weights
        }
    }

    private func similarity(_ a: Int, _ b: Int) -> Double {
        let (small, large) = vectors[a].count <= vectors[b].count ? (vectors[a], vectors[b]) : (vectors[b], vectors[a])
        var sum = 0.0
        for (term, weight) in small { if let other = large[term] { sum += weight * other } }
        return sum
    }

    /// 和这张最像的几张，像的在前。先找直接像的；再从最像的几张出发多走一步（借 SAG2 的「捞到了再接着捞」：
    /// 同一件事换了说法时，往往隔着一张中间的卡才连得上），走远一步的打个折
    public func similar(to id: String, limit: Int) -> [(id: String, score: Double)] {
        guard let origin = index[id], limit > 0 else { return [] }
        var best: [Int: Double] = [:]
        for other in ids.indices where other != origin {
            let score = similarity(origin, other)
            if score > 0 { best[other] = score }
        }
        let direct = best.sorted { $0.value > $1.value }.prefix(3)
        for (via, viaScore) in direct {
            for other in ids.indices where other != origin && other != via {
                let score = viaScore * similarity(via, other) * 0.6
                if score > (best[other] ?? 0) { best[other] = score }
            }
        }
        return best.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { (ids[$0.key], $0.value) }
    }

    /// 把相近的卡排到一起：从第一张开始，每次接上还没排的里面和当前这张最像的；一点都不像了就回到原顺序里下一张没排的
    public func ordered() -> [String] {
        var left = Set(ids.indices)
        var out: [Int] = []
        var next = ids.indices.first
        while let current = next {
            out.append(current)
            left.remove(current)
            var bestScore = 0.0
            var bestIndex: Int?
            for other in left {
                let score = similarity(current, other)
                if score > bestScore || (score == bestScore && score > 0 && other < (bestIndex ?? Int.max)) {
                    bestScore = score
                    bestIndex = other
                }
            }
            next = bestIndex ?? left.min()
        }
        return out.map { ids[$0] }
    }
}
