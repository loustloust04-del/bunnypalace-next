import Foundation
import MemoryCore

extension MemoryInjectionMeter {
    static func record(profileId: String, receipt: RecallTurnReceipt) {
        guard let record = receipt.injectionRecord else { return }
        Self.record(profileId: profileId, record: record)
    }
    /// 纯函数（astra #11）：组装后真留下来的时间轴单位的键——插槽关了 / 预设里没有插槽时组装不出时间轴段，一个都不算；
    /// 有时间轴段时只算段里真出现的那几行
    static func keptTimelineKeys(_ units: [TimelineStore.Unit], in segments: [TaggedSegment]) -> [String] {
        let text = segments.filter { $0.source == .timeline }.map(\.content).joined(separator: "\n")
        guard !text.isEmpty else { return [] }
        return units.filter { text.contains($0.line) }.map(\.key)
    }
}
