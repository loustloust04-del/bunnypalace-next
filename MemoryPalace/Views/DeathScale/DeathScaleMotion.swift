#if PERSONAL_APPS
import Foundation

/// 砝码堆（小样 `layoutHeap`）：按分量排金字塔，多了整体缩小，永远落在盘里。
/// 跟小样的差别：缩到三成以下（砝码上百枚）就不限五排、每排收窄不超过一枚砝码宽，堆成高塔，不至于缩成一层灰
enum DeathScaleHeap {
    struct Item: Equatable {
        var id: UUID
        var weight: Int
        var createdAt: Date
    }

    struct Placement: Equatable {
        var id: UUID
        var weight: Int
        var x: Double
        var y: Double
        var size: Double
    }

    struct Layout: Equatable {
        var scale: Double
        var placements: [Placement]
    }

    static let maxRows = 5
    static let maxHeight = 92.0
    static let relaxBelow = 0.3

    static func size(_ weight: Int) -> Double { 24 + Double(weight) * 2.7 }

    static func layout(_ items: [Item]) -> Layout {
        let sorted = items.sorted {
            $0.weight != $1.weight ? $0.weight > $1.weight : $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
        var scale = 1.0
        var rows: [[Item]] = []
        for _ in 0..<80 {
            let relaxed = scale < relaxBelow
            rows = rowsFor(sorted, scale: scale, relaxed: relaxed)
            let height = rows.reduce(0) { $0 + ($1.map { size($0.weight) }.max() ?? 0) * scale * 0.74 }
            if height <= maxHeight, relaxed || rows.count <= maxRows { break }
            scale *= 0.9
        }
        var out: [Placement] = []
        var base = DeathScaleScene.rim + 2.5
        for (ri, row) in rows.enumerated() {
            let widths = row.map { size($0.weight) * scale * 0.98 }
            let total = widths.reduce(0, +)
            var x = -total / 2
            for (i, item) in row.enumerated() {
                out.append(Placement(id: item.id, weight: item.weight,
                                     x: x + widths[i] / 2 + (DeathScaleEngraver.hash(Double(i), Double(ri)) - 0.5) * 2 * scale,
                                     y: base + (DeathScaleEngraver.hash(Double(ri), Double(i)) - 0.5) * 1.2,
                                     size: size(item.weight) * scale))
                x += widths[i]
            }
            base -= (row.map { size($0.weight) }.max() ?? 0) * scale * 0.74
        }
        return Layout(scale: scale, placements: out)
    }

    private static func rowsFor(_ sorted: [Item], scale: Double, relaxed: Bool) -> [[Item]] {
        var rows: [[Item]] = []
        var cap = DeathScaleScene.panRadius * 1.78
        var row: [Item] = []
        var width = 0.0
        for item in sorted {
            let w = size(item.weight) * scale * 0.98
            if width + w > cap, !row.isEmpty {
                let rowMax = row.map { size($0.weight) }.max() ?? 0
                rows.append(row)
                row = []
                width = 0
                cap = relaxed ? max(cap * 0.8, cap - rowMax * scale) : cap * 0.8
            }
            row.append(item)
            width += w
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

/// 横梁：弹簧阻尼（k = 34, c = 2.6），用解析解，任意时刻的角度直接算，不靠逐帧积分
struct DeathScaleSpring: Equatable {
    static let stiffness = 34.0
    static let damping = 2.6
    private static let gamma = damping / 2
    private static let omega = (stiffness - gamma * gamma).squareRoot()
    /// 摆幅包络小于这个角度（度）就算停稳
    static let restThreshold = 0.02

    var start: Date
    var offset: Double
    var velocity: Double
    var target: Double

    static func target(die: Int, live: Int) -> Double {
        -21 * tanh(Double(die - live) / (0.28 * Double(die + live) + 3))
    }

    static func resting(at target: Double, date: Date = .distantPast) -> DeathScaleSpring {
        DeathScaleSpring(start: date, offset: 0, velocity: 0, target: target)
    }

    private var coefficients: (Double, Double) {
        (offset, (velocity + Self.gamma * offset) / Self.omega)
    }

    func angle(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(start))
        let (a, b) = coefficients
        return target + exp(-Self.gamma * t) * (a * cos(Self.omega * t) + b * sin(Self.omega * t))
    }

    func angularVelocity(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(start))
        let (a, b) = coefficients
        let w = Self.omega, g = Self.gamma
        return exp(-g * t) * ((b * w - g * a) * cos(w * t) - (a * w + g * b) * sin(w * t))
    }

    func retargeted(_ newTarget: Double, at date: Date) -> DeathScaleSpring {
        DeathScaleSpring(start: date, offset: angle(at: date) - newTarget, velocity: angularVelocity(at: date), target: newTarget)
    }

    var settleDate: Date {
        let (a, b) = coefficients
        let amplitude = (a * a + b * b).squareRoot() * (1 + Self.gamma / Self.omega)
        guard amplitude > Self.restThreshold else { return start }
        return start.addingTimeInterval(log(amplitude / Self.restThreshold) / Self.gamma)
    }
}

/// 新砝码从上方落进盘里，弹两下（小样 `@keyframes drop`）
struct DeathScaleDrop: Equatable {
    static let duration = 0.9
    private static let stops: [(Double, Double, Double)] = [(0, -90, 0), (0.55, 0, 1), (0.72, -7, 1), (0.86, 0, 1), (0.93, -2, 1), (1, 0, 1)]

    var id: UUID
    var start: Date

    var end: Date { start.addingTimeInterval(Self.duration) }

    /// (向上的位移, 不透明度)；落完了返回 nil
    func pose(at date: Date) -> (dy: Double, opacity: Double)? {
        guard date < end else { return nil }
        let t = date.timeIntervalSince(start) / Self.duration
        guard t > 0 else { return (Self.stops[0].1, 0) }
        let i = Self.stops.lastIndex { $0.0 <= t } ?? 0
        let a = Self.stops[i], b = Self.stops[min(i + 1, Self.stops.count - 1)]
        let f = b.0 > a.0 ? Self.ease((t - a.0) / (b.0 - a.0)) : 1
        return (a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }

    /// cubic-bezier(.3, .1, .4, 1)
    static func ease(_ x: Double) -> Double {
        let x1 = 0.3, y1 = 0.1, x2 = 0.4, y2 = 1.0
        func bez(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if bez(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, y1, y2)
    }
}
#endif
