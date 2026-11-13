import SwiftUI

/// 珠串配色（docs/design-status-widget.html :root）：墨绿珠、玫瑰坏珠、点点金星、纸色卡底；没有蓝、没有黄
struct StatusPalette {
    static let rose = Color(hex: 0xC98F9E)
    static let gold = Color(hex: 0xB8954C)
    static let hollow = Color(hex: 0xB4BAB3)

    let night: Bool
    init(_ scheme: ColorScheme) { night = scheme == .dark }

    var bead: Color { night ? Color(hex: 0xDDE5DF) : Color(hex: 0x3A4A41) }
    var thread: Color { night ? Color(hex: 0x55605A) : Color(hex: 0xB9BFB6) }
    var card: Color { night ? Color(red: 40 / 255, green: 48 / 255, blue: 45 / 255).opacity(0.78) : Color(hex: 0xFBF9F4).opacity(0.86) }
    var page: Color { night ? Color(hex: 0x1E2623) : Color(hex: 0xFBF9F4) }
    var banner: Color { night ? Color(hex: 0x28302D).opacity(0.96) : Color(hex: 0xFBF9F4).opacity(0.94) }
    var ink: Color { night ? Color(hex: 0xE4EAE5) : Color(hex: 0x34403A) }
    var sub: Color { night ? Color(hex: 0xAEB8B2) : Color(hex: 0x5D6A62) }
    var faint: Color { Color(hex: 0x9AA39C) }
    var badText: Color { night ? Color(hex: 0xE3A9B6) : Color(hex: 0xA65E70) }
    var line: Color { night ? Color.white.opacity(0.08) : Color(hex: 0xE6E2D7) }
    var chip: Color { night ? Color.white.opacity(0.08) : Color(hex: 0xEFEDE6) }
    var stem: Color { Color(hex: 0x6F9A80) }
}

/// 一串珠子的画法（照设计稿 JS 版 strand()）：悬链线垂着，大小珠交替，坏的那颗掉在下方地面
enum StatusStrandDrawing {
    enum Look: Equatable { case ok, bad, stale, empty }

    struct Bead: Equatable {
        let name: String
        let state: StatusBead
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, beads: [Bead], look: Look, beadR: CGFloat,
                     star: Bool, palette: StatusPalette, falling: Set<String>, fallProgress: Double) {
        let pad: CGFloat = 10, x0 = pad, x1 = size.width - pad
        let top = size.height * 0.22, sag = size.height * 0.42, ground = size.height - 6
        func y(_ x: CGFloat) -> CGFloat {
            let t = (x - x0) / max(1, x1 - x0)
            return top + sag * 4 * t * (1 - t)
        }
        var thread = Path()
        thread.move(to: CGPoint(x: x0, y: y(x0)))
        var x = x0
        while x <= x1 { thread.addLine(to: CGPoint(x: x, y: y(x))); x += 2 }
        let dashed = look == .stale || look == .empty
        context.stroke(thread, with: .color(palette.thread), style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 3] : []))
        for end in [x0, x1] { context.fill(circle(end, y(end), 1.6), with: .color(palette.thread)) }
        if look == .empty { return }

        let step = (x1 - x0) / CGFloat(beads.count + 1)
        var falls: [(cx: CGFloat, cy: CGFloat, name: String)] = []
        for (i, bead) in beads.enumerated() {
            let cx = x0 + step * CGFloat(i + 1), cy = y(cx)
            if i > 0 {
                let mx = cx - step / 2
                let spacer = circle(mx, y(mx), beadR * 0.42)
                if look == .stale {
                    context.stroke(spacer, with: .color(StatusPalette.hollow.opacity(0.7)), lineWidth: 0.8)
                } else {
                    context.fill(spacer, with: .color(palette.bead.opacity(0.55)))
                }
            }
            let main = circle(cx, cy, beadR)
            if look == .stale || bead.state == .off {
                context.stroke(main, with: .color(StatusPalette.hollow), lineWidth: 1)
            } else if bead.state == .ok {
                context.fill(main, with: .color(palette.bead))
                context.fill(circle(cx - beadR * 0.35, cy - beadR * 0.35, beadR * 0.28), with: .color(.white.opacity(palette.night ? 0.18 : 0.35)))
            } else {
                context.stroke(main, with: .color(StatusPalette.rose), style: StrokeStyle(lineWidth: 0.9, dash: [1.5, 2]))
                falls.append((cx: cx, cy: cy, name: bead.name))
            }
        }
        for (k, fall) in falls.enumerated() {
            let fx = fall.cx + (k % 2 == 1 ? 3 : -3), fy = ground - beadR
            context.fill(Path(ellipseIn: CGRect(x: fx - beadR * 1.3, y: ground - 1.2, width: beadR * 2.6, height: 2.4)),
                         with: .color(StatusPalette.rose.opacity(0.25)))
            let lift = falling.contains(fall.name) ? fallOffset(progress: fallProgress, from: fall.cy - fy) : 0
            context.fill(circle(fx, fy + lift, beadR), with: .color(StatusPalette.rose))
            context.fill(circle(fx - beadR * 0.35, fy + lift - beadR * 0.35, beadR * 0.28), with: .color(.white.opacity(0.45)))
        }
        if look == .ok && star {
            let cx = (x0 + x1) / 2, cy = y(cx) + beadR + 12
            var stem = Path()
            stem.move(to: CGPoint(x: cx, y: y(cx) + beadR))
            stem.addLine(to: CGPoint(x: cx, y: cy - 5))
            context.stroke(stem, with: .color(StatusPalette.gold), style: StrokeStyle(lineWidth: 0.8, dash: [1, 1.6]))
            dotStar(in: &context, center: CGPoint(x: cx, y: cy), radius: 7.5, color: StatusPalette.gold)
        }
    }

    /// 点点四角金星：沿四条凹边排小点
    static func dotStar(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        let points = (0..<4).map { k -> CGPoint in
            let a = CGFloat(k) * .pi / 2 - .pi / 2
            return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        }
        for k in 0..<4 {
            let a = points[k], b = points[(k + 1) % 4]
            for t in stride(from: CGFloat(0), to: 1, by: 0.25) {
                let u = 1 - t
                let px = u * u * a.x + 2 * u * t * center.x + t * t * b.x
                let py = u * u * a.y + 2 * u * t * center.y + t * t * b.y
                context.fill(circle(px, py, 0.75), with: .color(color))
            }
        }
        context.fill(circle(center.x, center.y, 1.1), with: .color(color))
    }

    /// CSS fall 关键帧：0% 在线上 → 62% 落地 → 78% 弹起 4pt → 100% 停住（progress 0…1，前 0.4s 延迟由调用方算进去）
    static func fallOffset(progress: Double, from: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        if p < 0.62 {
            let t = p / 0.62
            return from * CGFloat(1 - t * t)
        }
        if p < 0.78 {
            let t = (p - 0.62) / 0.16
            return -4 * CGFloat(1 - (1 - t) * (1 - t))
        }
        let t = (p - 0.78) / 0.22
        return -4 * CGFloat(1 - t * t * (3 - 2 * t))
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}

/// 珠串（SwiftUI Canvas）。唯一动效：某颗刚变坏时从线上掉下来弹一下（≈0.9s）；减弱动态效果时直接落地。
/// 「刚变坏」按 fallKey 记住上次看到的坏珠名字，不是每次打开都掉
struct StatusStrandView: View {
    let beads: [StatusStrandDrawing.Bead]
    let look: StatusStrandDrawing.Look
    var beadR: CGFloat = 5
    var star = true
    var fallKey: String?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var falling: Set<String> = []
    @State private var fallStart: Date?

    private static let delay = 0.4
    private static let duration = 0.9

    var body: some View {
        TimelineView(.animation(paused: fallStart == nil)) { timeline in
            Canvas { context, size in
                let progress = fallStart.map { (timeline.date.timeIntervalSince($0) - Self.delay) / Self.duration } ?? 1
                StatusStrandDrawing.draw(in: &context, size: size, beads: beads, look: look, beadR: beadR, star: star,
                                         palette: StatusPalette(scheme), falling: falling, fallProgress: progress)
            }
        }
        .accessibilityHidden(true)
        .onAppear(perform: noteBad)
        .onChange(of: beads) { _, _ in noteBad() }
    }

    private var badNames: Set<String> {
        look == .stale ? [] : Set(beads.filter { $0.state == .bad }.map(\.name))
    }

    private func noteBad() {
        guard let fallKey else { return }
        let key = "statusStrandSeenBad.\(fallKey)"
        let seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let now = badNames
        if now != seen { UserDefaults.standard.set(Array(now).sorted(), forKey: key) }
        let fresh = now.subtracting(seen)
        guard !fresh.isEmpty, !reduceMotion else { return }
        falling = fresh
        let start = Date()
        fallStart = start
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.delay + Self.duration + 0.05))
            if fallStart == start { fallStart = nil; falling = [] }
        }
    }
}

extension StatusStrand {
    var beads: [StatusStrandDrawing.Bead] { lines.map { .init(name: $0.name, state: $0.bead) } }

    var look: StatusStrandDrawing.Look {
        switch verdict {
        case .ok: return .ok
        case .bad: return .bad
        case .stale: return .stale
        }
    }
}
