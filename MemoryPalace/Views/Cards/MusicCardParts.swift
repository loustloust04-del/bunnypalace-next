import SwiftUI
import SwiftStreamingMarkdown

/// 音乐卡的波形（research-chat-cards §10.6）：56 根柱，高度按歌曲身份确定性生成；
/// volumeMorph 0 → 1：柱间隙收拢、高度统一，并成一条音量条（同一个形状原地变形）
enum MusicWave {
    static let count = 56
    static let gap: CGFloat = 3
    static let volumeBarHeight: CGFloat = 8

    /// 前奏低、主段满、间奏落、再起；抖动按 seed 固定（同一首每次一样）
    static func heights(seed: String) -> [Double] {
        var h: UInt64 = 1_469_598_103_934_665_603                   // FNV-1a
        for b in seed.utf8 { h ^= UInt64(b); h = h &* 1_099_511_628_211 }
        return (0..<count).map { i in
            h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let jitter = Double(h >> 11) / Double(1 << 53)
            let f = Double(i) / Double(count)
            let base = f < 1.0 / 6 ? 0.28 + f * 6 * 0.2 : (f >= 2.0 / 3 && f < 5.0 / 6) ? 0.34 : 0.6
            return min(1, max(0.25, base + jitter * 0.34))
        }
    }

    /// 跟着鼓点弹：播放头附近几根按当前音量变高（同小样），远处不动；最高 1.35 倍
    static func bounced(_ heights: [Double], progress: Double, level: Double) -> [Double] {
        guard level > 0 else { return heights }
        let n = Double(heights.count)
        return heights.enumerated().map { i, h in
            let c = (Double(i) + 0.5) / n
            let near = max(0, 1 - abs(c - progress) * n / 4)
            return min(1.35, h * (1 + level * near * 0.6))
        }
    }

    /// 音量表里 t 秒处的值（越界 = 0）
    static func level(_ levels: [Float], perSecond: Int, at t: Double) -> Float {
        let i = Int(t * Double(perSecond))
        return levels.indices.contains(i) ? levels[i] : 0
    }

    static func bars(in size: CGSize, heights: [Double], volumeMorph: Double) -> [CGRect] {
        let vm = CGFloat(min(max(volumeMorph, 0), 1))
        let n = CGFloat(heights.count)
        guard n > 0 else { return [] }
        let gap = Self.gap * (1 - vm)
        let bw = (size.width - gap * (n - 1)) / n
        let mid = size.height / 2
        return heights.enumerated().map { i, v in
            let wh = max(4, CGFloat(v) * (size.height - 6))
            let bh = wh + (volumeBarHeight - wh) * vm
            return CGRect(x: CGFloat(i) * (bw + gap), y: mid - bh / 2, width: bw, height: bh)
        }
    }
}

/// 波形柱（可动画的 volumeMorph）
struct WaveBars: Shape {
    let heights: [Double]
    var volumeMorph: Double

    var animatableData: Double {
        get { volumeMorph }
        set { volumeMorph = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let merged = volumeMorph > 0.98
        for r in MusicWave.bars(in: rect.size, heights: heights, volumeMorph: volumeMorph) {
            let radius = min(r.width / 2, r.height / 2, 2 + 2 * volumeMorph)
            let box = merged ? r.insetBy(dx: -0.5, dy: 0) : r                  // 并成一条时补上发丝缝
            path.addRoundedRect(in: box.offsetBy(dx: rect.minX, dy: rect.minY),
                                cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

/// 播放 ↔ 暂停：同一个图形的两块四边形插值（不换图标）
struct PlayPauseShape: Shape {
    var morph: Double

    var animatableData: Double {
        get { morph }
        set { morph = newValue }
    }

    private static let play: [[CGPoint]] = [
        [CGPoint(x: 10, y: 6), CGPoint(x: 18, y: 11), CGPoint(x: 18, y: 21), CGPoint(x: 10, y: 26)],
        [CGPoint(x: 18, y: 11), CGPoint(x: 26, y: 16), CGPoint(x: 26, y: 16), CGPoint(x: 18, y: 21)],
    ]
    private static let pause: [[CGPoint]] = [
        [CGPoint(x: 9, y: 7), CGPoint(x: 13.5, y: 7), CGPoint(x: 13.5, y: 25), CGPoint(x: 9, y: 25)],
        [CGPoint(x: 18.5, y: 7), CGPoint(x: 23, y: 7), CGPoint(x: 23, y: 25), CGPoint(x: 18.5, y: 25)],
    ]

    func path(in rect: CGRect) -> Path {
        let m = CGFloat(min(max(morph, 0), 1))
        let sx = rect.width / 32, sy = rect.height / 32
        var path = Path()
        for q in 0..<2 {
            let pts = (0..<4).map { i -> CGPoint in
                let a = Self.play[q][i], b = Self.pause[q][i]
                return CGPoint(x: rect.minX + (a.x + (b.x - a.x) * m) * sx, y: rect.minY + (a.y + (b.y - a.y) * m) * sy)
            }
            path.addLines(pts)
            path.closeSubpath()
        }
        return path
    }
}

/// 没有封面图时的黑胶：同心纹 + 薄荷圆标；播放时慢转、暂停停在原角度（不跳回，终审 minor 1）；
/// 盘面只画一次，转动是图层变换（不每帧重画，终审 minor 2）；减弱动态效果时不转
struct VinylCover: View {
    let spinning: Bool
    var labelColor: Color = Color(red: 0.498, green: 0.722, blue: 0.620)
    @State private var base = 0.0
    @State private var startedAt: Date?
    private static let speed = 1.1                                    // 弧度 / 秒
    /// 盘面比封面大（边缘被封面框裁掉，同小样）；画布再留余量，转到 45° 也不露方角
    static let discScale: CGFloat = 1.42

    var body: some View {
        ZStack {
            Color(red: 0.867, green: 0.922, blue: 0.890)
            GeometryReader { g in
                let side = max(g.size.width, g.size.height) * Self.discScale
                TimelineView(.animation(paused: !spinning)) { context in
                    disc
                        .frame(width: side, height: side)
                        .rotationEffect(.radians(angle(at: context.date)))
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }
            }
        }
        .onAppear { if spinning { startedAt = .now } }
        .onChange(of: spinning) { _, now in
            if now { startedAt = .now } else { base = angle(at: .now); startedAt = nil }
        }
    }

    private func angle(at date: Date) -> Double {
        base + (startedAt.map { date.timeIntervalSince($0) } ?? 0) * Self.speed
    }

    private var disc: some View {
        Canvas { g, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 * 0.875             // 1.42 × 0.4375 ≈ 封面的 0.62
            g.translateBy(x: c.x, y: c.y)
            let disc = { (k: CGFloat) in Path(ellipseIn: CGRect(x: -r * k, y: -r * k, width: 2 * r * k, height: 2 * r * k)) }
            g.fill(disc(1), with: .color(Color(red: 0.11, green: 0.11, blue: 0.10)))
            for i in 0..<14 {
                g.stroke(disc(0.38 + CGFloat(i) * 0.042), with: .color(Color.white.opacity(0.10)), lineWidth: 0.6)
            }
            var shine = Path()
            shine.addArc(center: .zero, radius: r * 0.7, startAngle: .radians(-0.5), endAngle: .radians(0.15), clockwise: false)
            g.stroke(shine, with: .color(Color.white.opacity(0.28)), lineWidth: 1)
            g.fill(disc(0.3), with: .color(labelColor))
            g.fill(disc(0.045), with: .color(CodeBlockStyle.body))
        }
        .drawingGroup()
    }
}
