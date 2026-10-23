#if os(iOS)
import UIKit
import os

/// 花园四季会动的细节（#039）：水（倒影横带 / 细纹 / 涟漪 / 碎光）、云、星、火盆、萤火、飘落，全是 Core Animation 小层。
/// 时间由 app 推（#051）：各组容器常驻 speed = 0（暂停态不产生脏区，😷 实测 0 帧），一条 display link 按基准帧率（30，低电量 20）
/// 每拍只写到点那几组的 timeOffset（水 / 萤火 / 飘落每拍，云 / 火盆 15，星 10），全在一条网格上 → 整屏合成 = 基准。
/// 不靠动画级 preferredFrameRateRange：60Hz 屏（😷 iPhone 14）上它不限帧，整屏照 60 合成。
/// link 挂 `.default`：手指拖着任何滚动视图时 runloop 在 tracking，时间自然停住（拖动翻页时冻）。
/// 所有层按 t = GardenParts.t0 起播，刚挂上那一刻的样子 = 静帧。
final class GardenMotion {
    #if DEBUG || PERF_BENCH
    static let log = Logger(subsystem: "com.susu.MemoryPalace", category: "garden")
    #endif
    /// 动画钉在组时间 epoch（beginTime 写 0 会被 CA 换成「挂上那一刻」，补挂就丢相位）；组时间写 epoch + elapsed，正好抵消
    private static let epoch: CFTimeInterval = 1e-6
    let root = CALayer()
    private var registered: [(layer: CALayer, key: String, animation: CAAnimation)] = []
    private let clockBase: Int
    private var clocks: [(layer: CALayer, stride: Int)] = []
    private var link: CADisplayLink?
    private var tick = 0
    private var elapsed: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    #if DEBUG || PERF_BENCH
    private var summaryStart: CFTimeInterval = 0
    private var summaryTicks = 0
    #endif

    init(parts p: GardenParts, lowPower: Bool) {
        clockBase = GardenParts.clockBase(lowPower: lowPower)
        let W = p.width, H = p.height, s = p.voxel, u = p.unit, scale = CGFloat(p.scale)
        let env = p.env
        root.frame = CGRect(x: 0, y: 0, width: W, height: H)

        // ── 星：一颗一个小层，各自明灭 ──
        let sky = CALayer()
        sky.frame = root.bounds
        clock(sky, fps: 10)
        root.addSublayer(sky)
        // 静帧里星画在山、树和月亮下面：被挡住的那些不建层（动画层都叠在底图上面，没法夹进去）
        for st in p.stars where p.inOpenSky(st.x, st.y, st.r) {
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: st.r * 2, height: st.r * 2)
            l.position = CGPoint(x: st.x, y: st.y)
            l.cornerRadius = st.r
            l.backgroundColor = Self.color(st.color)
            sky.addSublayer(l)
            add(l, "twinkle", wave("opacity", period: 2 * .pi / st.omega, phase: st.phase) { NSNumber(value: st.alpha * (st.lo + st.amp * sin($0))) })
        }
        if let gold = p.goldStar {
            for st in p.golds where p.inOpenSky(st.x, st.y, p.goldBox.width / 2) {
                let l = Self.imageLayer(gold, box: p.goldBox, scale: scale)
                l.position = CGPoint(x: st.x, y: st.y)
                sky.addSublayer(l)
                add(l, "twinkle", wave("opacity", period: 2 * .pi / st.omega, phase: st.phase) { NSNumber(value: st.alpha * (st.lo + st.amp * sin($0))) })
            }
        }

        // ── 云：横着飘，出右边从左边回来。竖屏云都在天际线以上，不裁；横屏会飘到山后，用天际线 mask（多一次离屏，只在这种时候） ──
        let clouds = CALayer()
        clouds.frame = root.bounds
        clock(clouds, fps: 15)
        let skyTop = p.skyline.min() ?? H
        if p.clouds.contains(where: { $0.y + $0.box.maxY > skyTop }) {
            let mask = CAShapeLayer()
            mask.path = p.skyPath
            clouds.mask = mask
        }
        root.addSublayer(clouds)
        for c in p.clouds {
            let l = Self.imageLayer(c.image, box: c.box, scale: scale)
            l.position = CGPoint(x: c.x, y: c.y)
            clouds.addSublayer(l)
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = c.start
            drift.toValue = c.start + c.span
            let period = c.span / c.speed
            drift.duration = period
            drift.timeOffset = Self.frac((c.x - c.start) / c.span) * period
            add(l, "drift", drift)
        }

        // ── 水：倒影切 2pt 横带，每条两个正弦叠加左右晃（同小样）；上面细纹、涟漪、碎光；容器用池子轮廓裁 ──
        if let image = p.water, let rect = p.waterRect, let path = p.waterPath {
            let pool = CALayer()
            pool.frame = rect
            clock(pool, fps: 30)
            let mask = CAShapeLayer()
            var shift = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            mask.path = path.copy(using: &shift)
            pool.mask = mask
            root.addSublayer(pool)
            var yy = rect.minY
            while yy < rect.maxY - 0.01 {
                let h = min(2, rect.maxY - yy)
                let strip = CALayer()
                strip.contents = image
                strip.contentsScale = scale
                strip.contentsRect = CGRect(x: 0, y: (yy - rect.minY) / rect.height, width: 1, height: h / rect.height)
                strip.frame = CGRect(x: 0, y: yy - rect.minY, width: rect.width, height: h)
                pool.addSublayer(strip)
                let y = yy
                add(strip, "wave1", wave("position.x", period: 2 * .pi / 1.7, phase: y * 0.45, additive: true) { NSNumber(value: sin($0) * s * 0.1) })
                add(strip, "wave2", wave("position.x", period: 2 * .pi / 0.6, phase: -y * 0.12, additive: true) { NSNumber(value: -sin($0) * s * 0.16) })
                yy += 2
            }
            let wb = p.waterBounds.offsetBy(dx: -rect.minX, dy: -rect.minY)
            let lineColor = Self.color(p.lineColor)
            for ln in p.lines {
                let l = CALayer()
                l.bounds = CGRect(x: 0, y: 0, width: ln.len, height: p.lineWidth)
                l.cornerRadius = p.lineWidth / 2
                l.backgroundColor = lineColor
                l.position = CGPoint(x: ln.x - rect.minX, y: wb.minY)
                pool.addSublayer(l)
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = wb.minY
                fall.toValue = wb.maxY
                fall.duration = 1 / ln.rate
                fall.timeOffset = Self.frac(ln.frac0 + ln.rate * GardenParts.t0) / ln.rate
                add(l, "drift", fall)
                add(l, "breathe", wave("opacity", period: 2 * .pi / 0.8, phase: ln.phase) { NSNumber(value: 0.16 * (0.5 + 0.5 * sin($0))) })
            }
            for (k, spots) in p.ripples.enumerated() where !spots.isEmpty {
                let phase0 = GardenParts.t0 / 7 + Double(k) * 0.5
                let offset = Self.frac(phase0) * 7
                for ring in 0..<2 {
                    let l = CAShapeLayer()
                    l.fillColor = nil
                    l.strokeColor = lineColor
                    l.lineWidth = p.rippleWidth
                    l.opacity = 0
                    pool.addSublayer(l)
                    let hop = CAKeyframeAnimation(keyPath: "position")
                    hop.values = spots.map { NSValue(cgPoint: CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY)) }
                    hop.keyTimes = (0...spots.count).map { NSNumber(value: Double($0) / Double(spots.count)) }
                    hop.calculationMode = .discrete
                    hop.duration = 7 * Double(spots.count)
                    hop.timeOffset = offset
                    add(l, "hop", hop)
                    let n = 28
                    func ff(_ i: Int) -> Double { Double(i) / Double(n) - Double(ring) * 0.18 }
                    let grow = CAKeyframeAnimation(keyPath: "path")
                    grow.values = (0...n).map { i -> CGPath in
                        let rr = s * (0.4 + max(0, ff(i)) * 4.5)
                        return CGPath(ellipseIn: CGRect(x: -rr, y: -rr / 2, width: rr * 2, height: rr), transform: nil)
                    }
                    grow.duration = 7
                    grow.timeOffset = offset
                    add(l, "grow", grow)
                    let fade = CAKeyframeAnimation(keyPath: "opacity")
                    fade.values = (0...n).map { NSNumber(value: ff($0) <= 0 ? 0 : (1 - ff($0)) * 0.3) }
                    fade.duration = 7
                    fade.timeOffset = offset
                    add(l, "fade", fade)
                }
            }
            let glintColor = Self.color(p.glintColor)
            for g in p.glints {
                let l = CALayer()
                l.frame = CGRect(x: g.x - rect.minX, y: g.y - rect.minY, width: 0, height: 0)
                l.opacity = 0
                for r in [CGRect(x: -g.len, y: -0.35 * u, width: g.len * 2, height: 0.7 * u), CGRect(x: -0.35 * u, y: -g.len * 0.45, width: 0.7 * u, height: g.len * 0.9)] {
                    let bar = CALayer()
                    bar.frame = r
                    bar.backgroundColor = glintColor
                    l.addSublayer(bar)
                }
                pool.addSublayer(l)
                add(l, "glint", wave("opacity", period: 2 * .pi / g.omega, phase: g.phase, samples: 48) { NSNumber(value: g.alpha * pow(max(0, sin($0)), 6)) })
            }
            if let front = p.front {
                let l = CALayer()
                l.frame = rect
                l.contents = front
                l.contentsScale = scale
                root.addSublayer(l)
            }
        }

        // ── 火盆光晕：0.88 + 0.12·sin(9.3t)·sin(5.1t) = 0.88 + 0.06·cos(4.2t) − 0.06·cos(14.4t) ──
        if let halo = p.halo, !p.halos.isEmpty {
            let halos = CALayer()
            halos.frame = root.bounds
            clock(halos, fps: 15)
            root.addSublayer(halos)
            for g in p.halos {
                let l = Self.imageLayer(halo, box: p.haloBox, scale: scale)
                l.position = g
                l.opacity = 0.88
                halos.addSublayer(l)
                add(l, "flicker1", wave("opacity", period: 2 * .pi / 4.2, phase: .pi / 2, additive: true) { NSNumber(value: 0.06 * sin($0)) })
                add(l, "flicker2", wave("opacity", period: 2 * .pi / 14.4, phase: .pi / 2, additive: true) { NSNumber(value: -0.06 * sin($0)) })
            }
        }

        // ── 萤火：绕固定点游，三个正弦分量叠加（网格坐标 → 屏幕是线性的），一明一暗 ──
        if let fly = p.firefly, !p.fireflies.isEmpty {
            let flies = CALayer()
            flies.frame = root.bounds
            clock(flies, fps: 30)
            root.addSublayer(flies)
            for (i, base) in p.fireflies.enumerated() {
                let l = Self.imageLayer(fly, box: p.fireflyBox, scale: scale)
                l.position = base
                l.opacity = 0
                flies.addSublayer(l)
                let di = Double(i)
                add(l, "swayX", wave("position", period: 2 * .pi / 0.5, phase: di, additive: true) { NSValue(cgPoint: CGPoint(x: s * 1.5 * sin($0), y: s * 0.75 * sin($0))) })
                add(l, "swayY", wave("position", period: 2 * .pi / 0.4, phase: di * 1.7 + .pi / 2, additive: true) { NSValue(cgPoint: CGPoint(x: -s * 1.5 * sin($0), y: s * 0.75 * sin($0))) })
                add(l, "swayZ", wave("position", period: 2 * .pi / 0.7, phase: di * 2.3, additive: true) { NSValue(cgPoint: CGPoint(x: 0, y: -s * 0.8 * sin($0))) })
                add(l, "glow", wave("opacity", period: 2 * .pi / 1.9, phase: di * 2.7, samples: 32) {
                    NSNumber(value: p.fireflyAlpha * GardenMath.smooth(0.2, 1, 0.5 + 0.5 * sin($0)))
                })
            }
        }

        // ── 飘落：春花瓣 / 秋叶 / 冬雪，每个粒子一条固定路径；季节交界两种都有，按季节权重定透明度 ──
        let lightK = 0.45 + 0.55 * env.day
        for f in GardenParts.falls {
            let weight = env.sw.weight(f.season)
            if weight < 0.02 { continue }
            let group = CALayer()
            group.frame = root.bounds
            group.opacity = Float(weight)
            clock(group, fps: 30)
            root.addSublayer(group)
            for i in 0..<f.count {
                if lowPower && i % 2 == 1 { continue }
                let l = CALayer()
                let alpha: Double
                var spin: Double = 0
                switch f.season {
                case 0:
                    l.bounds = CGRect(x: 0, y: 0, width: 6 * u, height: 3.4 * u)
                    l.cornerRadius = 1.7 * u
                    l.backgroundColor = Self.color(GardenMath.hex(i % 2 == 1 ? "#f1cad0" : "#e3a9b0") * lightK)
                    alpha = 0.85; spin = 9
                case 2:
                    l.bounds = CGRect(x: 0, y: 0, width: 2.8 * u, height: 2.8 * u)
                    l.backgroundColor = Self.color(GardenMath.hex(["#d99b7b", "#cc8681", "#dca385"][i % 3]) * lightK)
                    alpha = 0.85; spin = 7
                default:
                    let r = u * (0.8 + GardenMath.hash(i, 6) * 1.2)
                    l.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
                    l.cornerRadius = r
                    l.backgroundColor = Self.color(GardenMath.mix(GardenMath.hex("#f8f6f1"), env.hor, 0.1))
                    alpha = 0.55 + 0.45 * GardenMath.hash(i, 5)
                }
                l.opacity = 0
                group.addSublayer(l)
                let period = GardenParts.fallPeriod(f, i), offset = GardenParts.fallPhase0(f, i) * period
                let n = 40
                let path = CAKeyframeAnimation(keyPath: "position")
                path.values = (0...n).map { NSValue(cgPoint: GardenParts.fallPoint(f, i, Double($0) / Double(n), width: W, height: H)) }
                path.duration = period
                path.timeOffset = offset
                add(l, "fall", path)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = (0...n).map { NSNumber(value: alpha * GardenParts.fallAlpha(Double($0) / Double(n))) }
                fade.duration = period
                fade.timeOffset = offset
                add(l, "fade", fade)
                if spin > 0 {
                    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                    turn.fromValue = Double(i)
                    turn.toValue = Double(i) + spin
                    turn.duration = period
                    turn.timeOffset = offset
                    add(l, "spin", turn)
                }
            }
        }

        // ── 四角暗角：盖在最上面（底图里没有它） ──
        if let vignette = p.vignette {
            let l = CALayer()
            l.frame = root.bounds
            l.contents = vignette
            root.addSublayer(l)
        }

        let link = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.step(_:)))
        let f = Float(clockBase)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: f, maximum: f, preferred: f)
        link.isPaused = true
        link.add(to: .main, forMode: .default)
        self.link = link
    }

    deinit { link?.invalidate() }

    var isPaused: Bool { link?.isPaused ?? true }

    func pause() {
        guard let link, !link.isPaused else { return }
        link.isPaused = true
        lastTimestamp = nil
        #if DEBUG || PERF_BENCH
        summaryStart = 0
        #endif
        trace("时钟 停 elapsed=\(String(format: "%.2f", elapsed))")
    }

    func resume() {
        guard let link, link.isPaused else { return }
        link.isPaused = false
        trace("时钟 走 base=\(clockBase)")
    }

    /// 退后台 / 移出窗口时 CA 会把动画摘掉：恢复、回到窗口、回前台时补挂（钉在组时间 0，补挂不丢相位）
    func ensureAnimations() {
        for r in registered where r.layer.animation(forKey: r.key) == nil { r.layer.add(r.animation, forKey: r.key) }
    }

    fileprivate func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { now - $0 } ?? 1 / Double(clockBase)
        if dt > 0.2 { trace("时钟 回调缺口 \(String(format: "%.2f", dt))s（拖动 tracking / 主线程卡）") }
        lastTimestamp = now
        #if DEBUG || PERF_BENCH
        summaryTicks += 1
        if now - summaryStart >= 5 {
            if summaryStart > 0 { trace("时钟 \(String(format: "%.1f", now - summaryStart))s 内 \(summaryTicks) 拍") }
            summaryStart = now
            summaryTicks = 0
        }
        #endif
        elapsed += GardenParts.clockStep(dt, base: clockBase)
        tick += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in clocks where tick % c.stride == 0 { c.layer.timeOffset = Self.epoch + elapsed }
        CATransaction.commit()
    }

    // MARK: - 小工具

    private final class LinkProxy: NSObject {
        weak var owner: GardenMotion?
        init(_ owner: GardenMotion) { self.owner = owner }
        @objc func step(_ link: CADisplayLink) { owner?.step(link) }
    }

    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG || PERF_BENCH
        let m = message()
        Self.log.info("\(m, privacy: .public)")
        #endif
    }

    /// 一组动画层的时间由 app 推：容器常驻暂停，step 到点写 timeOffset
    private func clock(_ layer: CALayer, fps: Int) {
        layer.speed = 0
        layer.timeOffset = Self.epoch
        clocks.append((layer, GardenParts.clockStride(fps: fps, base: clockBase)))
    }

    private func add(_ layer: CALayer, _ key: String, _ animation: CAAnimation) {
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = Self.epoch
        layer.add(animation, forKey: key)
        registered.append((layer, key, animation))
    }

    /// 周期动画：value(θ)，θ 从 0 到 2π；对齐到「θ = ω·t + phase，t 从 t0 起」
    private func wave(_ keyPath: String, period: Double, phase: Double, samples: Int = 24, additive: Bool = false, value: (Double) -> Any) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = (0...samples).map { value(2 * .pi * Double($0) / Double(samples)) }
        a.duration = period
        a.timeOffset = Self.frac((2 * .pi / period * GardenParts.t0 + phase) / (2 * .pi)) * period
        a.isAdditive = additive
        return a
    }

    private static func frac(_ v: Double) -> Double { v - v.rounded(.down) }

    private static func color(_ c: GardenRGB, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: GardenMath.clamp(c.x), green: GardenMath.clamp(c.y), blue: GardenMath.clamp(c.z), alpha: a)
    }

    private static func imageLayer(_ image: CGImage, box: CGRect, scale: CGFloat) -> CALayer {
        let l = CALayer()
        l.contents = image
        l.contentsScale = scale
        l.bounds = CGRect(origin: .zero, size: box.size)
        l.anchorPoint = CGPoint(x: -box.minX / box.width, y: -box.minY / box.height)
        return l
    }
}
#endif
