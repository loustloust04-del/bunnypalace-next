import Foundation

/// 找回失效记忆（修复第一刀·刀2）：库里只记了失效时间没记原因，
/// 按失效时间聚批——同一分钟内一起失效 ≥3 条的算一批（做梦毕业 / 整理记忆是成批标的），其余算零散。
enum MemoryRevival {
    static let minBatchSize = 3
    static let window: TimeInterval = 60

    struct Batch: Identifiable {
        let start: Date
        let memories: [Memory]
        var id: Date { start }
    }

    /// 只看已失效的；批按时间新→旧，批内与零散按失效时间新→旧
    static func group(_ memories: [Memory]) -> (batches: [Batch], scattered: [Memory]) {
        let dead = memories
            .compactMap { m in m.supersededAt.map { (m, $0) } }
            .sorted { $0.1 < $1.1 }
        var clusters: [[(Memory, Date)]] = []
        for item in dead {
            if let anchor = clusters.last?.first?.1, item.1.timeIntervalSince(anchor) <= window {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }
        var batches: [Batch] = []
        var scattered: [Memory] = []
        for c in clusters {
            if c.count >= minBatchSize {
                batches.append(Batch(start: c[0].1, memories: c.reversed().map(\.0)))
            } else {
                scattered += c.map(\.0)
            }
        }
        let newestFirst: (Memory, Memory) -> Bool = { ($0.supersededAt ?? .distantPast) > ($1.supersededAt ?? .distantPast) }
        return (batches.reversed(), scattered.sorted(by: newestFirst))
    }

    /// 「已删除」弹层：档案成批的 = 整理时合并掉的；零散的档案和{{char}}自己记下的删掉的并一组
    /// （库里只记了删的时间没记是谁删的，「你删的」「{{char}}划掉的」分不开），按删的时间新→旧
    static func trash(archive: [Memory], assistant: [SelfMemory]) -> (batches: [Batch], scattered: [MemoryRowItem]) {
        let (batches, loose) = group(archive)
        let items = loose.map { MemoryRowItem($0) } + assistant.filter { !$0.isActive }.map { MemoryRowItem($0) }
        return (batches, items.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) })
    }

    static func revive(_ memories: [Memory]) {
        let now = Date()
        for m in memories {
            m.supersededAt = nil
            m.updatedAt = now
        }
    }
}
