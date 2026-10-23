#if os(macOS)
import Foundation

/// 监听增量的解析限流（plan-mac-hang-probe 阶段 3，docs/research-mac-watcher-incremental-parse.md）：
/// 正在跑的 CC 会话每几秒追加一次，解析器每次都整份重读（这条对话 32MB / 3000 行），后台一核被占满。
/// 同一个文件两次解析之间至少隔 `max(minInterval, 上次耗时 × costFactor)`；隔不够的推迟，只留最新那份 ref，
/// 到点补一次——文件停写后一定有一次最终解析，标题 / 条数 / tokens / 更新时间最终一致，只是最多晚这么一个间隔。
/// 只在监听的串行队列上用，不加锁（所以 @unchecked Sendable）
final class CodingParseThrottle: @unchecked Sendable {
    /// 推迟项的补解析已经排上了（避免重复排）
    var retryScheduled = false
    let minInterval: TimeInterval
    let costFactor: Double
    private let now: () -> Date
    private var lastParsed: [String: (at: Date, cost: TimeInterval)] = [:]
    private var deferred: [String: CodingSessionFileRef] = [:]

    init(minInterval: TimeInterval = 3, costFactor: Double = 10, now: @escaping () -> Date = Date.init) {
        self.minInterval = minInterval
        self.costFactor = costFactor
        self.now = now
    }

    /// 这批里现在就该解析的（含到点的推迟项）；隔不够的收进推迟表。第二个值 = 最早什么时候再来取（nil = 没有推迟的）
    func admit(_ refs: [CodingSessionFileRef]) -> (due: [CodingSessionFileRef], retryAfter: TimeInterval?) {
        for ref in refs { deferred[ref.filePath] = ref }
        return takeDue()
    }

    /// 推迟表里到点的拿出来
    func takeDue() -> (due: [CodingSessionFileRef], retryAfter: TimeInterval?) {
        let t = now()
        var due: [CodingSessionFileRef] = []
        var soonest: TimeInterval?
        for (path, ref) in deferred {
            let wait = remaining(path, at: t)
            if wait <= 0 {
                due.append(ref)
            } else {
                soonest = min(soonest ?? wait, wait)
            }
        }
        for ref in due { deferred[ref.filePath] = nil }
        return (due, soonest)
    }

    /// 解析完记一笔：这批的总耗时算到每个文件头上（保守，批里通常就一两个文件）
    func record(_ refs: [CodingSessionFileRef], cost: TimeInterval) {
        let t = now()
        for ref in refs { lastParsed[ref.filePath] = (t, cost) }
    }

    var pendingCount: Int { deferred.count }

    private func remaining(_ path: String, at t: Date) -> TimeInterval {
        guard let last = lastParsed[path] else { return 0 }
        let interval = max(minInterval, last.cost * costFactor)
        return interval - t.timeIntervalSince(last.at)
    }
}
#endif
