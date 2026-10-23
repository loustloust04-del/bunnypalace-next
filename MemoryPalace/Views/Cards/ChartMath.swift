import Foundation
import CoreGraphics

/// 图表卡的数据整理（research-chat-cards §10.1）：纯函数，便于测
enum ChartMath {
    /// x 轴类目：所有系列标签按首次出现顺序并集
    static func categories(_ card: ChartCard) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in card.series { for p in s.points where seen.insert(p.label).inserted { out.append(p.label) } }
        return out
    }

    static func value(_ series: ChartCard.Series, at label: String) -> Double? {
        series.points.first { $0.label == label }?.value
    }

    /// Y 域由最终值定（入场时柱子长出不改坐标轴）：含 0，上下各留 8%；全 0 → 0...1（R5 U7）
    static func yDomain(_ card: ChartCard) -> ClosedRange<Double> {
        let values = card.series.flatMap { $0.points.map(\.value) }
        let lo = min(0, values.min() ?? 0), hi = max(0, values.max() ?? 0)
        guard lo < hi else { return 0...1 }
        return (lo * 1.08)...(hi * 1.08)
    }

    /// 环形命中：点到圆心的角度（12 点起顺时针）换成累计值落在哪个扇区；只在环上才算（0 值扇区跳过）
    static func sliceIndex(at point: CGPoint, center: CGPoint, outerRadius: CGFloat, innerRatio: CGFloat,
                           points: [ChartCard.Point]) -> Int? {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let r = (dx * dx + dy * dy).squareRoot()
        guard outerRadius > 0, r >= Double(outerRadius * innerRatio), r <= Double(outerRadius) * 1.05 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let total = points.map(\.value).reduce(0, +)
        guard total > 0 else { return nil }
        let target = angle / (2 * .pi) * total
        var acc = 0.0
        for (i, p) in points.enumerated() where p.value > 0 {
            acc += p.value
            if target < acc { return i }
        }
        return points.lastIndex { $0.value > 0 }
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f
    }()

    static func format(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func tooltipRows(_ card: ChartCard, label: String) -> [(name: String, text: String)] {
        card.series.enumerated().map { i, s in
            let name = s.name.isEmpty ? (card.series.count > 1 ? "系列 \(i + 1)" : label) : s.name
            let text = value(s, at: label).map { card.unit.isEmpty ? format($0) : "\(format($0)) \(card.unit)" } ?? "—"
            return (name, text)
        }
    }

    /// 轻点：点到另一项 → 选中它；点到已选中的那一项或空白 → 收起（图表只有轻点，不抢聊天滚动）
    static func reduceTap(current: String?, hit: String?) -> String? {
        guard let hit, hit != current else { return nil }
        return hit
    }

    /// 浮标左右边：以 center 为中心、宽 width，整体夹在 bounds 内（比区还宽时贴左）
    static func edges(center: CGFloat, width: CGFloat, bounds: ClosedRange<CGFloat>) -> (left: CGFloat, right: CGFloat) {
        let span = bounds.upperBound - bounds.lowerBound
        guard width < span else { return (bounds.lowerBound, bounds.lowerBound + width) }
        let left = min(max(center - width / 2, bounds.lowerBound), bounds.upperBound - width)
        return (left, left + width)
    }
}
