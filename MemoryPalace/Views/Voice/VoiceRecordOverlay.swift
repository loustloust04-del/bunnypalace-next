#if os(iOS)
import SwiftUI
import UIKit

// 录语音的浮层 + 输入条行内三态 + 预览胶囊 + 按住手势（plan-voice-note M5b–d）。
// 交互 / 视觉唯一参照：docs/design-voice-record.html（v2：点阵声浪点距 7、取消四叶点点花），数值照抄它的 JS / CSS。

// MARK: - 动画曲线

/// CSS cubic-bezier(x1,y1,x2,y2)：给进度 x 求 y（牛顿迭代 + 二分兜底）
struct VoiceBezier {
    let x1, y1, x2, y2: Double

    static let showSpring = VoiceBezier(x1: 0.3, y1: 1.6, x2: 0.55, y2: 1)    // 大按钮出场
    static let lockSpring = VoiceBezier(x1: 0.3, y1: 1.5, x2: 0.55, y2: 1)    // 锁出场

    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    func callAsFunction(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        var t = x
        for _ in 0..<6 {
            let err = sample(t, x1, x2) - x
            let u = 1 - t
            let d = 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2)
            guard abs(d) > 1e-6 else { break }
            t = min(1, max(0, t - err / d))
        }
        return sample(t, y1, y2)
    }
}

private enum Ease {
    static func outCubic(_ t: Double) -> Double { 1 - pow(1 - min(1, max(0, t)), 3) }
    static func inOutCubic(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    static func inOutQuad(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
    static func inQuad(_ t: Double) -> Double { let t = min(1, max(0, t)); return t * t }
    /// 小样 back：c = 1.9 的回弹
    static func back(_ t: Double) -> Double {
        let t = min(1, max(0, t)), c = 1.9
        return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }
    static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }
}

// MARK: - 点阵声浪（小样 drawBlob）

/// 声浪的一层（内圈 / 外圈）：8 点周期轮廓，在两组随机形状之间缓动；音量越大变得越快（1.1s → 0.25s）
struct VoiceBlobLayer {
    let minR: Double
    let maxR: Double
    var from = VoiceBlobLayer.shape()
    var to = VoiceBlobLayer.shape()
    var t = 0.0
    var dur = 1.0
    var cur: [Double]

    init(minR: Double, maxR: Double) {
        self.minR = minR
        self.maxR = maxR
        cur = from
    }

    static func shape() -> [Double] { (0..<8).map { _ in 0.84 + Double.random(in: 0...0.16) } }

    mutating func step(dt: Double, level p: Double) {
        t += dt / dur
        if t >= 1 {
            from = to
            to = Self.shape()
            t = 0
            dur = 1 / (0.9 + (4 - 0.9) * p)
        }
        let e = Ease.inOutQuad(t)
        for i in 0..<8 { cur[i] = from[i] + (to[i] - from[i]) * e }
    }

    func r(at a: Double) -> Double {
        let n = Double(cur.count)
        var f = (a / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        if f < 0 { f += 1 }
        f *= n
        let i = Int(f), t = f - Double(i)
        let w = (1 - cos(t * .pi)) / 2
        return cur[i % cur.count] * (1 - w) + cur[(i + 1) % cur.count] * w
    }
}

/// 浮层逐帧状态（住在 VoiceRecordLive 里，不被观察）
struct VoiceBlobState {
    var p = 0.0
    var pPrev = 0.0
    var layers = [VoiceBlobLayer(minR: 0.50, maxR: 0.82), VoiceBlobLayer(minR: 0.62, maxR: 1.0)]
    var ripples: [(r: Double, a: Double)] = []
    var rippleCool = 0.0
    var rot = 0.0
    var clock = 0.0
    var lastFrame: TimeInterval?
    /// 大按钮跟手（每帧 cur = cur×0.7 + target×0.3）
    var cur = CGPoint.zero
    var curScale: CGFloat = 1
    var lockness: CGFloat = 0
    /// 退场开始时的缩放（从这里缩回 0.2）
    var hideFromScale: Double?
}

/// 六角点阵（点距 7，中档）：建一次
private struct VoiceDot {
    let x, y, d, a, seed: Double
    /// 0 = 普通，1 = 粉，2 = 金（5%）
    let accent: Int
}

private enum VoiceDotField {
    static let radius = 110.0
    static let spacing = 7.0
    static let dots: [VoiceDot] = {
        var out: [VoiceDot] = []
        let rowH = spacing * 3.0.squareRoot() / 2
        let rows = Int((radius / rowH).rounded(.up))
        for row in -rows...rows {
            let y = Double(row) * rowH
            let off = row & 1 == 0 ? 0 : spacing / 2
            var x = -radius - spacing
            while x <= radius + spacing {
                let px = x + off, d = (px * px + y * y).squareRoot()
                if d <= radius {
                    let accent = Double.random(in: 0..<1) < 0.05 ? (Double.random(in: 0..<1) < 0.6 ? 1 : 2) : 0
                    out.append(VoiceDot(x: px, y: y, d: d, a: atan2(y, px), seed: .random(in: 0..<6.28), accent: accent))
                }
                x += spacing
            }
        }
        return out
    }()
}

/// 浮层画家：电平平滑、跟手、点阵、锁、取消花全在一个 Canvas 里逐帧算（只读写 VoiceRecordLive）
enum VoiceBlobRenderer {
    /// 花色（小样常量：粉 / 金；薄荷走 Theme.branchIndicator）
    static let pink = Color(red: 217 / 255, green: 154 / 255, blue: 165 / 255)
    static let gold = Color(red: 184 / 255, green: 149 / 255, blue: 76 / 255)
    static let petalPink = Color(red: 227 / 255, green: 169 / 255, blue: 176 / 255)

    private static let alphaSteps = 20

    static func render(_ g: inout GraphicsContext, size: CGSize, now: TimeInterval, live: VoiceRecordLive) {
        var s = live.frame
        let dt = min(0.05, max(0, now - (s.lastFrame ?? now)))
        s.lastFrame = now
        let f60 = dt * 60                                     // 小样每帧系数按 60fps 定，高刷按时长折算
        if live.capturing {
            s.p += (live.rawLevel - s.p) * (1 - pow(0.9, f60))
        } else {
            s.p *= pow(0.9, f60)
        }
        let locked = live.lockedAt != nil
        let target = locked || !live.capturing ? CGPoint.zero : CGPoint(x: live.dx, y: live.dy)
        let targetScale = locked || !live.capturing ? 1 : VoiceRecordGesture.bigButtonScale(dx: live.dx)
        let k = 1 - pow(0.7, f60)
        s.cur.x += (target.x - s.cur.x) * k
        s.cur.y += (target.y - s.cur.y) * k
        s.curScale += (targetScale - s.curScale) * k
        let lockTarget = locked ? 1 : VoiceRecordGesture.lockness(dy: live.dy)
        s.lockness += (lockTarget - s.lockness) * k
        s.rot += dt * 0.25
        s.clock += dt

        let anchor = CGPoint(x: live.sendCenter.x - live.overlayOrigin.x, y: live.sendCenter.y - live.overlayOrigin.y)
        let mint = Theme.branchIndicator
        let m = ThemeColorValue(color: mint)                  // 内圈点比按钮薄荷深一档（小样 127,165,141 vs 142,189,159）
        let innerMint = Color(red: m.red * 0.88, green: m.green * 0.88, blue: m.blue * 0.88)

        // 显隐：出场弹簧 0.5s（cubic-bezier(.3,1.6,.55,1)）/ 退场 0.18s 缩回 0.2
        var bigScale = 0.2 + 0.8 * VoiceBezier.showSpring((now - live.shownAt) / 0.5)
        var bigAlpha = Ease.clamp((now - live.shownAt) / 0.1)
        var lockY = 100 * (1 - VoiceBezier.lockSpring((now - live.shownAt) / 0.5))
        var lockAlpha = Ease.clamp((now - live.shownAt) / 0.15)
        var lockScale = 1.0
        if let hidden = live.hiddenAt {
            let h = Ease.clamp((now - hidden) / 0.18)
            let from = s.hideFromScale ?? bigScale
            s.hideFromScale = from
            bigScale = from + (0.2 - from) * Ease.inQuad(h)
            bigAlpha *= 1 - h
            lockAlpha *= 1 - h
            lockY += 30 * h
            lockScale = 1 - 0.4 * h
        } else {
            s.hideFromScale = nil
        }

        if lockAlpha > 0.01 {
            drawLock(&g, anchor: anchor, lockness: s.lockness, offsetY: lockY, scale: lockScale, alpha: lockAlpha,
                     now: now, lockedAt: live.lockedAt)
        }
        if bigAlpha > 0.01 {
            var bg = g
            bg.opacity = bigAlpha
            bg.translateBy(x: anchor.x + s.cur.x, y: anchor.y + s.cur.y)
            let sc = s.curScale * bigScale
            bg.scaleBy(x: sc, y: sc)
            drawBlob(&bg, state: &s, dt: dt, mint: mint, innerMint: innerMint)
            drawIcon(&bg, alpha: bigAlpha, now: now, lockedAt: live.lockedAt)
        }
        if let bloom = live.bloomAt {
            let o = live.overlayOrigin
            drawBloom(&g, t: (now - bloom) * 1000,
                      from: CGPoint(x: live.bloomFrom.x - o.x, y: live.bloomFrom.y - o.y),
                      to: CGPoint(x: live.bloomTo.x - o.x, y: live.bloomTo.y - o.y),
                      innerMint: innerMint)
        }
        live.frame = s
    }

    // 三层逻辑同 TG：实心按钮 0.38–0.44 / 内圈 0.50–0.82 / 外圈 0.62–1.0；点阵里落在圈内的点亮起来，峰值荡一圈放大的点
    private static func drawBlob(_ g: inout GraphicsContext, state s: inout VoiceBlobState, dt: Double,
                                 mint: Color, innerMint: Color) {
        let C = VoiceDotField.radius, p = s.p
        for i in s.layers.indices { s.layers[i].step(dt: dt, level: p) }
        let btnR = C * (0.38 + 0.06 * p)
        let L0 = s.layers[0], L1 = s.layers[1]
        let Rm = C * (L0.minR + (L0.maxR - L0.minR) * p)
        let Ro = C * (L1.minR + (L1.maxR - L1.minR) * p)
        s.rippleCool -= dt
        if s.p - s.pPrev > 0.006 * dt * 60, s.rippleCool <= 0, p > 0.25 {
            s.ripples.append((r: btnR, a: min(1, p * 1.3)))
            s.rippleCool = 0.22
        }
        s.pPrev = s.p
        s.ripples = s.ripples.compactMap { r in
            let next = (r: r.r + dt * 85, a: r.a * pow(0.25, dt))
            return next.r < C + 6 && next.a > 0.04 ? next : nil
        }

        // 同色同透明度的点并进一条 Path（20 档透明度 × 4 色），一帧几十次 fill 而不是近千次
        let steps = alphaSteps
        var buckets = [Path](repeating: Path(), count: 4 * (steps + 1))
        let rot = s.rot, clock = s.clock, ripples = s.ripples
        for o in VoiceDotField.dots {
            if o.d < btnR + 3 { continue }
            if o.d > Ro + 7 && ripples.isEmpty { continue }
            let a = o.a + rot
            let rm = Rm * L0.r(at: a), ro = Ro * L1.r(at: -a * 0.9)
            var alpha = 0.0, size = 0.0
            var color = 1                                          // 0 内圈薄荷 1 外圈薄荷 2 粉 3 金
            let accentColor = o.accent == 0 ? 0 : o.accent + 1
            if o.d <= rm {
                alpha = 0.78; size = 1.55; color = accentColor
            } else if o.d <= rm + 5 {
                let t = (o.d - rm) / 5
                alpha = 0.78 - 0.4 * t; size = 1.55 - 0.25 * t; color = accentColor
            } else if o.d <= ro {
                alpha = 0.38; size = 1.25
            } else if o.d <= ro + 7 {
                let t = (o.d - ro) / 7
                alpha = 0.38 * (1 - t); size = 1.2 * (1 - t * 0.4)
            }
            for r in ripples {
                let x = (o.d - r.r) / 3.2
                let gss = exp(-x * x) * r.a
                if gss > 0.02 {
                    size += gss
                    alpha = max(alpha, 0.85 * gss)
                    if o.accent != 0 { color = o.accent + 1 } else if alpha < 0.5 { color = 0 }
                }
            }
            if alpha < 0.02 { continue }
            alpha *= 0.86 + 0.14 * sin(clock * 3 + o.seed)
            let q = min(steps, max(1, Int((alpha * Double(steps)).rounded())))
            buckets[color * (steps + 1) + q].addEllipse(in: CGRect(x: o.x - size, y: o.y - size, width: size * 2, height: size * 2))
        }
        let palette = [innerMint, mint, pink, gold]
        for (i, path) in buckets.enumerated() where !path.isEmpty {
            let q = i % (steps + 1)
            g.fill(path, with: .color(palette[i / (steps + 1)].opacity(Double(q) / Double(steps))))
        }

        // 实心按钮 + 一圈珠串（大小交替，慢转）
        g.fill(Path(ellipseIn: CGRect(x: -btnR, y: -btnR, width: btnR * 2, height: btnR * 2)), with: .color(mint))
        let nb = 28, br = btnR - 5
        var big = Path(), small = Path()
        for i in 0..<nb {
            let a = Double(i) / Double(nb) * 2 * .pi + rot * 0.6
            let r = i % 2 == 1 ? 0.8 : 1.25
            let rect = CGRect(x: cos(a) * br - r, y: sin(a) * br - r, width: r * 2, height: r * 2)
            if i % 2 == 1 { small.addEllipse(in: rect) } else { big.addEllipse(in: rect) }
        }
        g.fill(big, with: .color(.white.opacity(0.7)))
        g.fill(small, with: .color(.white.opacity(0.45)))
    }

    /// 话筒 → 锁定后换成发送箭头（0.3s 缩放交叉）；24 单位的 SVG 路径放大到 30pt
    /// GraphicsContext 的 opacity 按赋值算（不随父层相乘），子层都写「父 alpha × 自己的」
    private static func drawIcon(_ g: inout GraphicsContext, alpha: Double, now: TimeInterval, lockedAt: TimeInterval?) {
        let t = lockedAt.map { Ease.clamp((now - $0) / 0.3) } ?? 0
        let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        let unit = 30.0 / 24
        if t < 1 {
            var mic = Path()
            mic.addRoundedRect(in: CGRect(x: 9, y: 3, width: 6, height: 11), cornerSize: CGSize(width: 3, height: 3))
            mic.move(to: CGPoint(x: 18.5, y: 11))
            mic.addArc(center: CGPoint(x: 12, y: 11), radius: 6.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            mic.move(to: CGPoint(x: 12, y: 17.5))
            mic.addLine(to: CGPoint(x: 12, y: 21))
            var mg = g
            mg.opacity = alpha * (1 - t)
            let sc = unit * max(0.001, 1 - t)
            mg.scaleBy(x: sc, y: sc)
            mg.translateBy(x: -12, y: -12)
            mg.stroke(mic, with: .color(.white), style: style)
        }
        if t > 0 {
            var send = Path()
            send.move(to: CGPoint(x: 12, y: 19)); send.addLine(to: CGPoint(x: 12, y: 5))
            send.move(to: CGPoint(x: 6, y: 11)); send.addLine(to: CGPoint(x: 12, y: 5)); send.addLine(to: CGPoint(x: 18, y: 11))
            var sg = g
            sg.opacity = alpha * t
            let sc = unit * (0.3 + 0.7 * t)
            sg.scaleBy(x: sc, y: sc)
            sg.translateBy(x: -12, y: -12)
            sg.stroke(send, with: .color(.white), style: style)
        }
    }

    /// 锁：40×72，中心在发送键上方 122；上拉时高 72→40、锁扣合上、箭头淡出；锁定后 0.56s 出 ■
    private static func drawLock(_ g: inout GraphicsContext, anchor: CGPoint, lockness L: CGFloat, offsetY: Double,
                                 scale: Double, alpha: Double, now: TimeInterval, lockedAt: TimeInterval?) {
        var lg = g
        lg.opacity = alpha
        let h = 72 - 32 * L
        let cy = anchor.y - VoiceRecordOverlay.lockLift + offsetY
        lg.translateBy(x: anchor.x, y: cy)
        lg.scaleBy(x: scale, y: scale)
        let box = CGRect(x: -20, y: -h / 2, width: 40, height: h)
        let shape = Path(roundedRect: box, cornerRadius: 20)
        lg.drawLayer { sh in
            sh.addFilter(.shadow(color: Color(red: 60 / 255, green: 50 / 255, blue: 40 / 255).opacity(0.14), radius: 6, x: 0, y: 2))
            sh.fill(shape, with: .color(Theme.mainBg.opacity(0.94)))
        }
        lg.stroke(shape, with: .color(Theme.textPrimary.opacity(0.06)), lineWidth: 1)
        lg.clip(to: shape)

        let lockedT = lockedAt.map { Ease.clamp((now - $0) / 0.15) } ?? 0
        let iconAlpha = 1 - lockedT
        let top = box.minY
        if iconAlpha > 0.01 {
            var ig = lg
            ig.opacity = alpha * iconAlpha
            ig.translateBy(x: -10, y: top + 10)                    // 20×22 的锁图标，顶距 10
            let style = StrokeStyle(lineWidth: 1.8, lineCap: .round)
            ig.stroke(Path(roundedRect: CGRect(x: 3, y: 10, width: 14, height: 10), cornerRadius: 3),
                      with: .color(Theme.textSecondary), style: style)
            var shackle = Path()
            let lift = -3 * (1 - L)
            shackle.move(to: CGPoint(x: 6, y: 10 + lift))
            shackle.addLine(to: CGPoint(x: 6, y: 7 + lift))
            shackle.addArc(center: CGPoint(x: 10, y: 7 + lift), radius: 4, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            shackle.addLine(to: CGPoint(x: 14, y: 10 + lift))
            ig.stroke(shackle, with: .color(Theme.textSecondary), style: style)

            // 上拉箭头：0.9s 来回浮 4pt，随上拉淡出
            let bobPhase = (now / 0.9).truncatingRemainder(dividingBy: 2)
            let bob = -4 * Ease.inOutQuad(bobPhase < 1 ? bobPhase : 2 - bobPhase)
            var ag = lg
            ag.opacity = alpha * iconAlpha * Double(1 - L)
            ag.translateBy(x: -6, y: top + 36 + bob)
            var arrow = Path()
            arrow.move(to: CGPoint(x: 2, y: 7)); arrow.addLine(to: CGPoint(x: 6, y: 3)); arrow.addLine(to: CGPoint(x: 10, y: 7))
            ag.stroke(arrow, with: .color(Theme.textMuted), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        if let lockedAt {
            let stopAlpha = Ease.clamp((now - lockedAt - 0.56) / 0.25)
            if stopAlpha > 0 {
                var sg = lg
                sg.opacity = alpha * stopAlpha
                sg.fill(Path(roundedRect: CGRect(x: -8, y: top + 12, width: 16, height: 16), cornerRadius: 4),
                        with: .color(Theme.danger))
            }
        }
    }

    /// 取消：红点沿低弧线飞回 +（0–420ms）→ 绽成四叶点点花（420–680）→ 停到 820 → 下沉、散开、淡出（820–1280）
    private static func drawBloom(_ g: inout GraphicsContext, t: Double, from: CGPoint, to: CGPoint, innerMint: Color) {
        guard t < VoiceRecordOverlay.bloomTotal * 1000 else { return }
        func dot(_ c: CGPoint, _ size: Double, _ color: Color, _ alpha: Double) {
            guard alpha > 0.01, size > 0 else { return }
            g.fill(Path(ellipseIn: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)),
                   with: .color(color.opacity(min(1, alpha))))
        }
        let lerp = { (a: Double, b: Double, t: Double) in a + (b - a) * t }
        let red = Theme.danger
        if t < 420 {
            let u = Ease.inOutCubic(t / 420)
            let cx = (from.x + to.x) / 2, cy = min(from.y, to.y) - 22
            let x = (1 - u) * (1 - u) * from.x + 2 * (1 - u) * u * cx + u * u * to.x
            let y = (1 - u) * (1 - u) * from.y + 2 * (1 - u) * u * cy + u * u * to.y
            dot(CGPoint(x: x, y: y), lerp(10, 6, u), red, 1)
            return
        }
        let b = Ease.clamp((t - 420) / 260)
        let f = Ease.clamp((t - 820) / 460)
        let sink = Ease.outCubic(f) * 10
        // 花心：红 → 金
        let r0 = ThemeColorValue(color: red), g1 = ThemeColorValue(color: gold), eb = Ease.outCubic(b)
        let center = Color(red: lerp(r0.red, g1.red, eb), green: lerp(r0.green, g1.green, eb), blue: lerp(r0.blue, g1.blue, eb))
        dot(CGPoint(x: to.x, y: to.y + sink), lerp(6, 4, eb), center, 1 - f)
        let cols = [innerMint, pink, innerMint, petalPink]
        for i in 0..<4 {
            let bi = Ease.clamp((t - 420 - Double(i) * 35) / 220)
            let fi = Ease.clamp((t - 820 - Double(i) * 35) / 420)
            let a = .pi / 4 + Double(i) * .pi / 2
            let r = lerp(0, 5.2, Ease.back(bi)) + Ease.outCubic(fi) * 4
            let size = lerp(2, 5.4, Ease.outCubic(bi)) * lerp(1, 0.7, fi)
            dot(CGPoint(x: to.x + cos(a) * r, y: to.y + sin(a) * r + Ease.outCubic(fi) * 10), size, cols[i],
                min(1, bi * 2) * (1 - fi))
        }
    }
}

// MARK: - 浮层

/// 挂在 ChatInputBar 上、往上溢出（carrier 是整页高、内容贴底，InputBarStack）：大按钮 + 锁 + 取消花，
/// 一个 TimelineView(.animation) + Canvas，只在录音期间（及退场 / 取消花的尾巴）挂载
struct VoiceRecordOverlay: View {
    static let height: CGFloat = 440
    /// 锁中心在发送键上方多少
    static let lockLift: CGFloat = 122
    /// 取消花：+ 号 1000ms 弹回，整段 1450ms
    static let bloomRegrow: TimeInterval = 1.0
    static let bloomTotal: TimeInterval = 1.45

    let voice: VoiceRecordController

    var body: some View {
        let live = voice.live
        ZStack(alignment: .topLeading) {
            TimelineView(.animation) { timeline in
                Canvas { g, size in
                    VoiceBlobRenderer.render(&g, size: size, now: timeline.date.timeIntervalSinceReferenceDate, live: live)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if voice.phase == .locked {
                let _ = voice.layoutRevision   // 锁定后几何变了 → 重算位置
                // 锁定后松了手：大按钮 = 发送，锁里的 ■ = 停下进预览（recordingHitRect 让 carrier 不把这块放行给列表）
                let a = CGPoint(x: live.sendCenter.x - live.overlayOrigin.x, y: live.sendCenter.y - live.overlayOrigin.y)
                Color.clear
                    .frame(width: 110, height: 110)
                    .contentShape(Circle())
                    .onTapGesture { voice.sendLocked() }
                    .position(a)
                    .accessibilityLabel("发送语音")
                    .accessibilityAddTraits(.isButton)
                Color.clear
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                    .onTapGesture { voice.stopToPreview() }
                    .position(x: a.x, y: a.y - Self.lockLift)
                    .accessibilityLabel("停止录音")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// ChatInputBar 上的挂点：浮层挂没挂、对话 / 转写状态同步给 controller、录完交货。
/// 只有它读 controller 的观察字段——ChatInputBar 的 body 不因录音重算
struct VoiceRecordOverlayHost: View {
    let voice: VoiceRecordController
    let conversationId: String?
    /// 正在编辑旧消息：不能录（转写忙状态不经这里，controller 直接读 VoiceNoteTranscribing 单例，重挂不覆盖）
    let editing: Bool
    let onDeliver: (VoiceRecordController.Delivery) -> Void

    var body: some View {
        ZStack {
            if voice.overlayMounted {
                VoiceRecordOverlay(voice: voice)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: VoiceRecordOverlay.height, alignment: .bottom)
        .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named("chatInputBar")).origin }) { origin in
            voice.geometryChanged(overlayOrigin: origin)
        }
        .onChange(of: conversationId, initial: true) { _, id in voice.conversationChanged(to: id) }
        .onChange(of: editing, initial: true) { _, e in voice.isEditing = e }
        .onChange(of: voice.deliveryToken) { _, _ in
            if let d = voice.takeDelivery() { onDeliver(d) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            voice.discard()
        }
        .onDisappear { voice.discard() }
    }
}

// MARK: - 输入条行内（高度不变，只换行内内容）

/// 录音中：红点（1s 一闪）+ m:ss + 「‹ 左滑取消」（±6 晃、过 8pt 半速跟手、靠左淡出）；
/// 锁定：提示上移淡出、「取消」从下升起；预览：删除 + 小胶囊 + （发送键在右边）；空闲且在转写：「转文字中…」
struct VoiceInlineRow: View {
    let voice: VoiceRecordController
    let transcribing: Bool

    var body: some View {
        switch voice.phase {
        case .recording, .locked:
            recordingRow(locked: voice.phase == .locked)
        case .preview:
            if let rec = voice.preview { previewRow(rec) }
        case .idle:
            if transcribing { transcribingRow }
        }
    }

    private func recordingRow(locked: Bool) -> some View {
        let live = voice.live
        return ZStack(alignment: .leading) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate - live.recordStart
                HStack(spacing: 10) {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 10, height: 10)
                        .opacity(Self.blink(t))
                    Text(Self.timer(t))
                        .font(.system(size: 15, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                        .frame(minWidth: 38, alignment: .leading)
                }
                .padding(.leading, 6)
            }

            TimelineView(.animation(minimumInterval: nil, paused: locked)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Text("‹ 左滑取消")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize()
                    .offset(x: locked ? 0 : Self.shimmy(t) + VoiceRecordGesture.hintOffset(dx: live.dx))
                    .opacity(locked ? 1 : VoiceRecordGesture.hintOpacity(dx: live.dx))
            }
            .offset(y: locked ? -22 : 0)
            .scaleEffect(locked ? 0.25 : 1)
            .opacity(locked ? 0 : 1)
            .animation(.easeOut(duration: 0.22), value: locked)
            .padding(.leading, 96)
            .allowsHitTesting(false)

            Button { voice.cancel(fromTrash: false) } label: {
                Text("取消")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.danger)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(y: locked ? 0 : 22)
            .opacity(locked ? 1 : 0)
            .allowsHitTesting(locked)
            .animation(.easeOut(duration: 0.25), value: locked)
            .padding(.leading, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {}                                           // 吞掉行内空白的点按，别聚焦到藏着的输入框
    }

    private func previewRow(_ rec: VoiceNoteRecorder.Recording) -> some View {
        HStack(spacing: 4) {
            Button { voice.cancel(fromTrash: true) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.danger)
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删掉这条录音")
            VoicePreviewCapsule(recording: rec)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var transcribingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("转文字中…")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// 红点 1s 一闪（小样 keyframes：0–45% 亮，91% 起全灭）
    static func blink(_ t: Double) -> Double {
        let f = t.truncatingRemainder(dividingBy: 1)
        if f < 0.45 { return 1 }
        if f < 0.91 { return 1 - Ease.inOutQuad((f - 0.45) / 0.46) }
        return 0
    }

    /// 提示 ±6pt 来回晃，周期 1s（ease-in-out alternate）
    static func shimmy(_ t: Double) -> CGFloat {
        let u = t.truncatingRemainder(dividingBy: 2)
        return CGFloat(6 - 12 * Ease.inOutQuad(u < 1 ? u : 2 - u))
    }

    static func timer(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 预览态小胶囊：播临时文件（VoiceMessagePlayer，id = 文件路径），声纹来自录音时采的峰值（条宽 2、间距 2、最高 18）
struct VoicePreviewCapsule: View {
    let recording: VoiceNoteRecorder.Recording

    private var id: String { recording.url.path }
    private var barCount: Int { max(10, min(26, Int((12 + recording.duration * 2.2).rounded()))) }

    var body: some View {
        let player = VoiceMessagePlayer.shared
        let state = player.state(for: id)
        let bars = VoiceWave.normalized(VoiceWave.resampledPeaks(recording.peaks, count: barCount), floor: VoiceWave.levelFloor)
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.branchIndicator)
                PlayPauseShape(morph: state == .playing ? 1 : 0)
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
            }
            .frame(width: 26, height: 26)
            TimelineView(.animation(paused: state != .playing)) { _ in
                let fraction = player.fraction(for: id) ?? 0
                Canvas { g, size in
                    let n = bars.count
                    for (i, a) in bars.enumerated() {
                        let h = max(2, min(18, CGFloat(a) * 18))
                        let rect = CGRect(x: CGFloat(i) * 4, y: (size.height - h) / 2, width: 2, height: h)
                        let played = state == .idle ? 0 : VoiceWave.playedFill(index: i, count: n, fraction: fraction)
                        g.fill(Path(roundedRect: rect, cornerRadius: 1),
                               with: .color(Theme.branchIndicator.opacity(0.4 + 0.6 * played)))
                    }
                }
                .frame(width: CGFloat(bars.count) * 4 - 2, height: 22)
            }
            Spacer(minLength: 0)
            Text(VoiceWave.clock(recording.duration))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .frame(height: 36)
        .background(Capsule().fill(Theme.userBubble))
        .contentShape(Capsule())
        .onTapGesture { player.toggle(url: recording.url, id: id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("录好的语音，\(VoiceWave.clock(recording.duration))")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 按住手势

/// waveform 发送键上的按住手势（DragGesture(minimumDistance: 0)，判定在 VoiceRecordGesture）。
/// 手势状态放在这个 modifier 里：按下 / 松开只重算它自己，不重算 InputFieldContainer
struct VoiceHoldGesture: ViewModifier {
    let voice: VoiceRecordController
    let enabled: Bool
    @GestureState private var pressing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())                            // 整个 44 框都按得住（waveform 态底是透明的）
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { v in voice.touchChanged(translation: v.translation) }
                    .onEnded { v in voice.touchEnded(translation: v.translation, velocity: v.velocity) },
                including: enabled ? .all : .subviews
            )
            .onChange(of: pressing) { _, now in
                if !now { voice.touchReset() }                    // 没走 onEnded（被系统收走）才有事做
            }
    }
}
#endif
