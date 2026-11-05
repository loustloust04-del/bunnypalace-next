import SwiftUI

// MARK: - 程序化剪纸贴纸（plan-onboarding-xiaoya-impl §12-A；小样 design-onboarding-xiaoya-v3.html sticker() / SHAPES / LAY）
// 不规则多边形（种子抖一点角）→ 每层描粗边当白纸边 → 上一层错开 1–2pt（叠层）→ 撒深浅纸纤维 → 薄边影 + 整张落影。
// 坐标照小样：形状画在 0…100，画布 -14…114（128 格）。纸是纸，颜色固定，不跟亮暗主题。
// 哪里贴什么在 XiaoyaStickerRule（Services/Assistant/XiaoyaStickers.swift）。

/// 小样 rng()（mulberry32）：同一个种子画出同一张
private struct XiaoyaStickerRandom {
    private var a: UInt32

    init(_ seed: UInt32) { a = seed }

    mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// 一块形状：填色多边形，或描边折线（sw = 线宽）。back = false 只画在最上一层（不描纸边）
private struct XiaoyaStickerPiece {
    var path: Path
    var stroke: CGFloat?
    var fill: Color?
    var back = true
}

private enum XiaoyaStickerShapes {
    static func pieces(_ kind: XiaoyaStickerKind, seed: UInt32) -> [XiaoyaStickerPiece] {
        var r = XiaoyaStickerRandom(seed)
        switch kind {
        case .burst:
            return [.init(path: polygon(burst(9, 48, 22, &r)))]
        case .heart:
            return [.init(path: polygon(jitter(heart, &r, 5)))]
        case .ques:
            return [.init(path: polyline([(27, 36), (33, 17), (55, 9), (74, 19), (75, 38), (56, 51), (53, 64)]), stroke: 15),
                    .init(path: polygon(ngon(53, 85, 9.5, 9, 6, &r)))]
        case .excl:
            return [.init(path: polygon(jitter([(37, 6), (67, 5), (58, 63), (44, 64)], &r, 4))),
                    .init(path: polygon(ngon(51, 83, 10.5, 10, 6, &r)))]
        case .bubble:
            let dot = gardenColor("#46443F")
            return [.init(path: polygon(bubble(&r))),
                    .init(path: polygon(ngon(32, 44, 6, 6, 6, &r, j: 0.25)), fill: dot, back: false),
                    .init(path: polygon(ngon(52, 42, 6, 6, 6, &r, j: 0.25)), fill: dot, back: false),
                    .init(path: polygon(ngon(72, 40, 6, 6, 6, &r, j: 0.25)), fill: dot, back: false)]
        case .bolt:
            return [.init(path: polygon(jitter([(60, 3), (18, 56), (46, 53), (30, 97), (82, 38), (54, 41), (74, 3)], &r, 4)))]
        case .bulb:
            var filament = Path()
            filament.move(to: CGPoint(x: 44, y: 66))
            filament.addLine(to: CGPoint(x: 45, y: 52))
            filament.addCurve(to: CGPoint(x: 50, y: 46), control1: CGPoint(x: 42, y: 46), control2: CGPoint(x: 47, y: 42))
            filament.addCurve(to: CGPoint(x: 55, y: 52), control1: CGPoint(x: 53, y: 42), control2: CGPoint(x: 58, y: 46))
            filament.addLine(to: CGPoint(x: 56, y: 66))
            var threads = polyline([(38, 82), (62, 82)])
            threads.addPath(polyline([(39, 87.5), (61, 87.5)]))
            let glass = bulbGlass(&r)
            let base = jitter([(37, 76), (63, 76), (60, 93), (40, 93)], &r, 2)
            return [.init(path: polygon(glass)),
                    .init(path: polygon(base), fill: gardenColor("#A29D93")),
                    .init(path: filament, stroke: 2.6, fill: gardenColor("#C9612F"), back: false),
                    .init(path: threads, stroke: 1.8, fill: gardenColor("#6f6a62"), back: false),
                    .init(path: polyline([(30, 30), (36, 20), (45, 15)]), stroke: 4, fill: .white.opacity(0.75), back: false)]
        }
    }

    static let heart: [(Double, Double)] = [(50, 30), (60, 15), (77, 10), (92, 20), (95, 39), (85, 57), (50, 90),
                                            (15, 57), (5, 39), (8, 20), (23, 10), (40, 15)]

    static func polygon(_ pts: [(Double, Double)]) -> Path {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }

    static func polyline(_ pts: [(Double, Double)]) -> Path {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
        return p
    }

    static func jitter(_ pts: [(Double, Double)], _ r: inout XiaoyaStickerRandom, _ a: Double) -> [(Double, Double)] {
        pts.map { p in
            let x = p.0 + (r.next() - 0.5) * a
            let y = p.1 + (r.next() - 0.5) * a
            return (x, y)
        }
    }

    static func ngon(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ n: Int,
                     _ r: inout XiaoyaStickerRandom, j: Double = 0.14) -> [(Double, Double)] {
        (0..<n).map { i in
            let a = Double(i) / Double(n) * .pi * 2
            let k = 1 + (r.next() - 0.5) * j
            return (cx + rx * k * cos(a), cy + ry * k * sin(a))
        }
    }

    static func burst(_ n: Int, _ big: Double, _ small: Double, _ r: inout XiaoyaStickerRandom) -> [(Double, Double)] {
        (0..<(n * 2)).map { i in
            let a = (-90 + Double(i) * 180 / Double(n) + (r.next() - 0.5) * 12) * .pi / 180
            let rr = (i % 2 == 1 ? small : big) * (1 + (r.next() - 0.5) * 0.26)
            return (50 + rr * cos(a), 50 + rr * sin(a))
        }
    }

    static func bubble(_ r: inout XiaoyaStickerRandom) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for i in 0..<14 {
            let a = Double(i) / 14 * .pi * 2
            let k = 1 + (r.next() - 0.5) * 0.1
            out.append((52 + 44 * k * cos(a), 44 + 33 * k * sin(a)))
            if i == 5 { out.append((16, 95)) }
        }
        return out
    }

    static func bulbGlass(_ r: inout XiaoyaStickerRandom) -> [(Double, Double)] {
        var out: [(Double, Double)] = (0...10).map { i in
            let a = (140 + Double(i) * 26) * .pi / 180
            let k = 1 + (r.next() - 0.5) * 0.08
            return (50 + 33 * k * cos(a), 38 + 33 * k * sin(a))
        }
        out += [(64, 66), (62, 74), (38, 74), (36, 66)]
        return out
    }
}

/// 每种贴纸的纸层颜色（最外 → 最上；最外一层多半是白纸边，小样 LAY）
enum XiaoyaStickerPalette {
    static func layers(_ kind: XiaoyaStickerKind) -> [Color] {
        switch kind {
        case .burst: hex(["#FBF8F2", "#C77DDB", "#F0645A"])
        case .heart: hex(["#FBF8F2", "#EE8FB3"])
        case .ques: hex(["#6F8FE0", "#8FD6B8"])
        case .excl: hex(["#C3CAF7", "#9A6BE0"])
        case .bubble: hex(["#FFFFFF", "#E4E0D8"])
        case .bolt: hex(["#FBF8F2", "#2C3A78", "#E2463C"])
        case .bulb: hex(["#FBF8F2", "#F7D64A"])
        }
    }

    /// 「啪」那枚星爆：黄橙（小样 LAY.burstY）
    static let stamp = hex(["#FBF8F2", "#F49A4B", "#F7D64A"])

    private static func hex(_ values: [String]) -> [Color] { values.map(gardenColor) }
}

/// 一张剪纸贴纸。size = 画布边长（形状本身约占 78%）。Equatable：灯泡每帧晃的时候纸本身不重画
struct XiaoyaPaperSticker: View, Equatable {
    let kind: XiaoyaStickerKind
    var layers: [Color]? = nil
    var seed: UInt32 = 1
    var size: CGFloat = 40
    var rotation: Double = 0

    private static let border: CGFloat = 5.5

    var body: some View {
        let colors = layers ?? XiaoyaStickerPalette.layers(kind)
        let pieces = XiaoyaStickerShapes.pieces(kind, seed: seed)
        Canvas { ctx, canvas in
            let s = canvas.width / 128
            let top = colors.count - 1
            for (li, color) in colors.enumerated() {
                let depth = CGFloat(top - li)
                let w = Self.border * 2 * depth
                let dx = depth * 1.1 - (li == top ? 0.6 : 0)
                let dy = depth * 1.5 - (li == top ? 0.8 : 0)
                let place = CGAffineTransform(scaleX: s, y: s).translatedBy(x: 14 + dx, y: 14 + dy)
                // 每层一张纸：薄边影打在合成后的整层上（外层套一层再画，影子不会一块一块叠）
                ctx.drawLayer { sheet in
                    sheet.addFilter(.shadow(color: .black.opacity(0.3), radius: 0.5 * s, x: 0.7 * s, y: 1.1 * s))
                    sheet.drawLayer { paper in
                        for piece in pieces where li == top || piece.back {
                            let ink = li == top ? (piece.fill ?? color) : color
                            let path = piece.path.applying(place)
                            if let sw = piece.stroke {
                                paper.stroke(path, with: .color(ink),
                                             style: StrokeStyle(lineWidth: (sw + w) * s, lineCap: li == top ? .butt : .square, lineJoin: .bevel))
                            } else {
                                paper.fill(path, with: .color(ink))
                                if w > 0 { paper.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w * s, lineJoin: .bevel)) }
                            }
                        }
                        Self.grain(&paper, seed: seed &* 31 &+ UInt32(li), scale: s)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: gardenColor("#2a221a").opacity(0.26), radius: 1.8 * size / 128, x: 1.8 * size / 128, y: 3.2 * size / 128)
        .rotationEffect(.degrees(rotation))
        .accessibilityHidden(true)
    }

    /// 纸纤维：深浅小点只落在这层已经画了的纸上（sourceAtop）
    private static func grain(_ ctx: inout GraphicsContext, seed: UInt32, scale s: CGFloat) {
        var r = XiaoyaStickerRandom(seed)
        ctx.blendMode = .sourceAtop
        for _ in 0..<170 {
            let x = (r.next() * 128) * s
            let y = (r.next() * 128) * s
            let d = (0.5 + r.next() * 0.9) * s
            let dark = r.next() < 0.55
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                     with: .color(dark ? Color(red: 0.22, green: 0.19, blue: 0.15).opacity(0.16) : .white.opacity(0.22)))
        }
    }
}

// MARK: - 「啪」：完成一步拍在卡角的星爆（一次性；减弱动态时直接贴着）

struct XiaoyaStampSticker: View {
    /// 这一刻刚完成：拍一下；否则直接贴着（滚回来 / 重建不重拍）
    let fresh: Bool
    let onPlayed: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trigger = 0

    private struct Slap {
        var opacity = 1.0
        var scale = 1.0
        var angle = 0.0
        var rays = 0.0
        var raysOpacity = 0.0
    }

    var body: some View {
        KeyframeAnimator(initialValue: Slap(), trigger: trigger) { v in
            ZStack {
                rays
                    .scaleEffect(0.5 + 0.85 * v.rays)
                    .opacity(v.raysOpacity)
                XiaoyaPaperSticker(kind: .burst, layers: XiaoyaStickerPalette.stamp, seed: 14, size: 58, rotation: 8)
                    .scaleEffect(v.scale)
                    .rotationEffect(.degrees(v.angle))
                    .opacity(v.opacity)
            }
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.3)
            }
            KeyframeTrack(\.scale) {
                MoveKeyframe(2.6)
                CubicKeyframe(0.82, duration: 0.3)
                CubicKeyframe(1.1, duration: 0.13)
                CubicKeyframe(1, duration: 0.19)
            }
            KeyframeTrack(\.angle) {
                MoveKeyframe(-50)
                CubicKeyframe(10, duration: 0.3)
                CubicKeyframe(-5, duration: 0.13)
                CubicKeyframe(0, duration: 0.19)
            }
            KeyframeTrack(\.rays) {
                MoveKeyframe(0)
                LinearKeyframe(0, duration: 0.12)
                LinearKeyframe(1, duration: 0.5)
            }
            KeyframeTrack(\.raysOpacity) {
                MoveKeyframe(0)
                LinearKeyframe(0, duration: 0.12)
                LinearKeyframe(1, duration: 0.15)
                LinearKeyframe(0, duration: 0.35)
            }
        }
        .frame(width: 58, height: 58)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard fresh else { return }
            if !reduceMotion { trigger += 1 }
            onPlayed()
        }
    }

    /// 八道红色放射短线（小样 .rays）
    private var rays: some View {
        Canvas { ctx, size in
            let s = size.width / 80
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                var p = Path()
                p.move(to: CGPoint(x: (40 + cos(a) * 30) * s, y: (40 + sin(a) * 30) * s))
                p.addLine(to: CGPoint(x: (40 + cos(a) * 39) * s, y: (40 + sin(a) * 39) * s))
                ctx.stroke(p, with: .color(gardenColor("#E2463C")), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
            }
        }
        .frame(width: 86, height: 86)
    }
}

// MARK: - 灯泡（舞台头小芽左边，§12-A 定稿）：剪纸灯泡一直上下浮 + 柔和黄光晕呼吸；有没看的 tip 时光晕更亮 + 轻晃 + 红数字

struct XiaoyaTipBulb: View {
    /// 没看过的 tip 数：> 0 光晕更亮、轻晃、出红数字
    let unseen: Int
    /// 收到新 tip 时 +1：弹一下
    let pulse: Int
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.page2AppActive) private var appActive
    #else
    private let appActive = true
    #endif
    @State private var origin = Date.now

    static let size: CGFloat = 62

    private var lit: Bool { unseen > 0 }
    private var moving: Bool { !reduceMotion && appActive && scenePhase == .active }

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
                let t = moving ? context.date.timeIntervalSince(origin) : 0
                ZStack {
                    glow(breath: moving ? Self.breath(t) : 1)
                    XiaoyaPaperSticker(kind: .bulb, seed: 3, size: Self.size, rotation: -6)
                        .rotationEffect(.degrees(moving && lit ? Self.wobble(t) : 0), anchor: UnitPoint(x: 0.5, y: 0.88))
                }
                .frame(width: Self.size, height: Self.size)
                .overlay(alignment: .topTrailing) { if lit { badge } }
                .offset(y: moving ? Self.float(t) : 0)
            }
            .frame(width: Self.size, height: Self.size)
            .keyframeAnimator(initialValue: 1.0, trigger: pulse) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.18, duration: 0.22)
                SpringKeyframe(1, duration: 0.5)
            }
            .contentShape(Circle().inset(by: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("小芽的提示")
        .accessibilityValue(lit ? "\(unseen) 条没看" : "")
    }

    /// 呼吸：2.6 s 一个来回，0 = 最暗最小，1 = 最亮最大
    static func breath(_ t: Double) -> Double { (1 - cos(t / 2.6 * 2 * .pi)) / 2 }

    /// 浮：3.4 s 一个来回，上下各 3pt
    static func float(_ t: Double) -> Double { -3 * sin(t / 3.4 * 2 * .pi) }

    /// 轻晃：3.6 s 一圈，前 72% 不动，之后左右晃三下停住（小样 @keyframes wob）
    static func wobble(_ t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: 3.6) / 3.6
        let stops: [(Double, Double)] = [(0.72, 0), (0.78, -9), (0.84, 7), (0.9, -3), (1, 0)]
        guard p > stops[0].0 else { return 0 }
        for (a, b) in zip(stops, stops.dropFirst()) where p <= b.0 {
            let k = (p - a.0) / (b.0 - a.0)
            let eased = k * k * (3 - 2 * k)
            return a.1 + (b.1 - a.1) * eased
        }
        return 0
    }

    private func glow(breath b: Double) -> some View {
        RadialGradient(colors: [Color(red: 1, green: 0.886, blue: 0.431).opacity(0.9),
                                Color(red: 1, green: 0.831, blue: 0.314).opacity(0.38),
                                .clear],
                       center: .center, startRadius: 0, endRadius: 43)
            .frame(width: 86, height: 86)
            .scaleEffect(lit ? 0.86 + 0.24 * b : 0.76 + 0.14 * b)
            .opacity(lit ? 0.5 + 0.5 * b : 0.22 + 0.22 * b)
            .offset(y: Self.size * 0.42 - Self.size / 2)
            .allowsHitTesting(false)
    }

    private var badge: some View {
        Text("\(unseen)")
            .font(.system(size: 12.5, weight: .bold, design: .serif))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 21, minHeight: 21)
            .background(gardenColor("#D9483B"), in: Capsule())
            .overlay(Capsule().stroke(gardenColor("#FBF8F2"), lineWidth: 2))
            .shadow(color: .black.opacity(0.22), radius: 0, x: 1.5, y: 2.5)
            .rotationEffect(.degrees(-8))
            .offset(x: 3, y: 1)
            .allowsHitTesting(false)
    }
}
