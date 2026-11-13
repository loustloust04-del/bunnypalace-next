import Foundation
import MemoryCore

extension MemoryWriteLog {
    /// `MemoryHealthStore` 成败出口顺手调（A2 / A3 / A4 / C2 唯一出口）
    static func record(_ kind: MemoryHealthStore.Kind, profileId: String, ok: Bool, note: String, model: String,
                       rejected: Int? = nil, now: Date = Date(), memoryRoot: @autoclosure () -> URL) {
        guard let writer = MemoryWriterID(health: kind) else { return }
        record(writer: writer, profileId: profileId, ok: ok, note: note, model: model, rejected: rejected, now: now, memoryRoot: memoryRoot())
    }
    /// C2「本周拒收 N 次」：这周一 0 点起拒收张数相加
    static func rejectedThisWeek(_ list: [Entry], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let since = WriteBudgetStore.since(period: .week, resetAt: nil, now: now, calendar: calendar) ?? now
        return list.filter { $0.writer == MemoryWriterID.c2.code && $0.time >= since }.reduce(0) { $0 + ($1.rejected ?? 0) }
    }
}

extension MemoryWriterID {
    /// 状态卡 / 日志里用的健康种类（后台写手才有）
    var health: MemoryHealthStore.Kind? {
        switch self {
        case .a2: return .context
        case .a3: return .summary
        case .a4: return .timeline
        case .c2: return .extract
        default: return nil
        }
    }

    init?(health: MemoryHealthStore.Kind) {
        switch health {
        case .context: self = .a2
        case .summary: self = .a3
        case .timeline: self = .a4
        case .extract: self = .c2
        case .dream: return nil
        }
    }
}
