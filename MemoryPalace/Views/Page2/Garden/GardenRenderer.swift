import CoreGraphics
import Foundation

/// 花园四季静帧：Core Graphics 照小样 render() 逐段移植（飘落物 / 萤火交给粒子层，不画进静帧）。
/// 纯函数、线程安全，可在后台队列调用；坐标单位是 pt，scale 是像素倍率。
enum GardenRenderer {
    struct Layout {
        let s: Double, ox: Double, oy: Double, y0: Double
        /// 屏幕点落在地面（z=0 体素的顶面）上对应的网格坐标
        func groundCell(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
            let a = (px - ox) / s, b = (py - oy + s) * 2 / s
            return ((a + b) / 2, (b - a) / 2)
        }
    }

    /// 竖屏按宽、横屏按高定体素尺寸；宽扁的画面（iPhone 横屏、矮预览）把地面起点往上提、体素放大，保证两个底角都落在地面上
    static func layout(width W: Double, height H: Double) -> Layout {
        let y0 = min(H * 0.62, H - W / 4 - W * 0.02)
        let fit = ((H - y0) * 2 + W / 2) / (2 * Double(GardenScene.n - 2))
        let s = max(min(W / 64, H / 138), fit)
        return Layout(s: s, ox: W / 2, oy: y0 + s, y0: y0)
    }

    static func render(width W: Double, height H: Double, scale: Double, hour: Double, season: Double, t: Double = 30) -> CGImage? {
        let pw = Int((W * scale).rounded()), ph = Int((H * scale).rounded())
        guard pw > 0, ph > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = context(pw, ph, space, scale: scale),
              let off = context(pw, ph, space, scale: scale) else { return nil }
        draw(ctx, off: off, W: W, H: H, scale: scale, env: GardenEnvironment(hour: hour, season: season), t: t, sink: nil)
        return ctx.makeImage()
    }

    /// 主屏动画版（#039）：同一遍绘制，底图去掉星 / 云 / 火盆光晕，水画成位移为 0 的定格；水和挡水的前景另裁两张；
    /// 外加各动画层的参数。动画层在 t=30 那一刻的样子 = `render` 的静帧
    static func renderParts(width W: Double, height H: Double, scale: Double, hour: Double, season: Double) -> GardenParts? {
        let pw = Int((W * scale).rounded()), ph = Int((H * scale).rounded())
        guard pw > 0, ph > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = context(pw, ph, space, scale: scale),
              let off = context(pw, ph, space, scale: scale) else { return nil }
        let sink = GardenParts(width: W, height: H, scale: scale, hour: hour, season: season)
        draw(ctx, off: off, W: W, H: H, scale: scale, env: GardenEnvironment(hour: hour, season: season), t: GardenParts.t0, sink: sink)
        guard let base = ctx.makeImage() else { return nil }
        sink.base = base
        return sink
    }

    /// 在 y 朝下的上下文里把图正着画进 rect
    static func drawUpright(_ c: CGContext, _ image: CGImage, in rect: CGRect) {
        c.saveGState()
        c.translateBy(x: 0, y: rect.minY * 2 + rect.height)
        c.scaleBy(x: 1, y: -1)
        c.draw(image, in: rect)
        c.restoreGState()
    }

    /// 小贴图：pt 尺寸 × scale 像素，y 朝下，`origin` 是贴图左上角在场景里的坐标（画的时候用场景坐标）
    static func sprite(_ rect: CGRect, scale: Double, _ paint: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = context(max(1, Int((rect.width * scale).rounded(.up))), max(1, Int((rect.height * scale).rounded(.up))), space, scale: scale) else { return nil }
        c.translateBy(x: -rect.minX, y: -rect.minY)
        paint(c)
        return c.makeImage()
    }

    private static func context(_ pw: Int, _ ph: Int, _ space: CGColorSpace, scale: Double) -> CGContext? {
        guard let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(ph))
        c.scaleBy(x: 1, y: -1)
        c.scaleBy(x: scale, y: scale)
        c.setLineJoin(.round)
        return c
    }

    private static func draw(_ ctx: CGContext, off: CGContext, W: Double, H: Double, scale: Double, env: GardenEnvironment, t: Double, sink: GardenParts?) {
        let scene = GardenScene.shared
        let n = GardenScene.n, zOff = GardenScene.zOff, zSize = GardenScene.zSize
        let mix = GardenMath.mix, hex = GardenMath.hex, smooth = GardenMath.smooth
        func hash(_ x: Int, _ y: Int, _ z: Int = 0, _ k: Int = 0) -> Double { GardenMath.hash(x, y, z, k) }
        let clamp = { GardenMath.clamp($0) }
        let white = GardenRGB(1, 1, 1)
        let lay = layout(width: W, height: H)
        let s = lay.s, ox = lay.ox, y0 = lay.y0, oy = lay.oy
        func P(_ x: Double, _ y: Double, _ z: Double) -> CGPoint { CGPoint(x: ox + (x - y) * s, y: oy + (x + y) * s / 2 - z * s) }
        let horizonY = y0 + s * 4
        let u = W / 390
        let warm = env.day * (1 - smooth(0.12, 0.55, sin(max(0, env.el))))
        let sp = GardenMath.clamp(env.p, -0.05, 1.05)
        let sunX = W * (0.12 + 0.76 * sp), sunY = horizonY - sin(.pi * clamp(sp)) * H * 0.5
        let q = env.nightQ
        let moonX = W * (0.2 + 0.6 * q), moonY = H * 0.42 - sin(.pi * q) * H * 0.3
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let ext: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        func cg(_ c: GardenRGB, _ a: Double = 1) -> CGColor {
            CGColor(srgbRed: clamp(c.x), green: clamp(c.y), blue: clamp(c.z), alpha: GardenMath.clamp(a))
        }
        func grad(_ stops: [(Double, GardenRGB, Double)]) -> CGGradient? {
            CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { cg($0.1, $0.2) } as CFArray, locations: stops.map { CGFloat($0.0) })
        }
        // 画到哪：默认整屏；动画版出水裁片 / 前景裁片 / 云贴图时临时换掉
        var cur = ctx
        func linear(_ clipRect: CGRect, _ a: CGPoint, _ b: CGPoint, _ stops: [(Double, GardenRGB, Double)]) {
            guard let g = grad(stops) else { return }
            cur.saveGState(); cur.clip(to: clipRect); cur.drawLinearGradient(g, start: a, end: b, options: ext); cur.restoreGState()
        }
        func radial(_ clip: (CGContext) -> Void, _ c: CGPoint, _ r0: Double, _ r1: Double, _ stops: [(Double, GardenRGB, Double)]) {
            guard let g = grad(stops) else { return }
            cur.saveGState(); clip(cur); cur.clip()
            cur.drawRadialGradient(g, startCenter: c, startRadius: r0, endCenter: c, endRadius: r1, options: ext)
            cur.restoreGState()
        }
        func circlePath(_ x: Double, _ y: Double, _ r: Double) -> (CGContext) -> Void {
            { $0.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
        }
        func rectPath(_ r: CGRect) -> (CGContext) -> Void { { $0.addRect(r) } }
        func dot(_ x: Double, _ y: Double, _ r: Double, _ c: GardenRGB, _ a: Double) {
            cur.setFillColor(cg(c, a)); cur.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }

        // ── 天空：天顶更深，地平线发亮 ──
        let zen = mix(env.top, hex("#b4adc4"), 0.2 * env.day)
        ctx.setFillColor(cg(env.hor)); ctx.fill(full)
        linear(full, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: horizonY),
               [(0, zen, 1), (0.5, env.top, 1), (0.85, mix(env.top, env.hor, 0.6), 1), (1, mix(env.hor, white, 0.12 * env.day), 1)])
        func skyColorAt(_ y: Double) -> GardenRGB {
            y < horizonY * 0.5 ? mix(zen, env.top, y / (horizonY * 0.5)) : mix(env.top, env.hor, clamp((y - horizonY * 0.5) / (horizonY * 0.5)))
        }
        if env.day > 0.02 {
            radial(rectPath(full), CGPoint(x: sunX, y: horizonY), 0, W * 1.1,
                   [(0, env.sunC, 0.5 * warm + 0.1 * env.day), (0.45, env.sunC, 0.15 * warm), (1, env.sunC, 0)])
            if warm > 0.05 {
                let pink = hex("#e9c3cb")
                radial(rectPath(full), CGPoint(x: W - sunX, y: horizonY - H * 0.08), 0, W * 0.9, [(0, pink, 0.28 * warm), (1, pink, 0)])
            }
        }

        // 画在星 / 云之后、却属于底图的两层薄雾（地平线一层、后坡一层，都只随 y 变）。动画版的星 / 云叠在底图上面，
        // 要把这两层（和月晕）预先烘进星色和云贴图，t0 那一下才和静帧对得上
        let bandTop = y0 - s * 4, bandBot = y0 + s * 14
        let hazeTop = horizonY - s * 12, hazeBot = horizonY + s * 2
        let hazeStops: [(Double, GardenRGB, Double)] = [(0, env.hor, 0), (0.7, mix(env.hor, white, 0.15 * env.day), 0.45), (1, env.hor, 0)]
        let mistStops: [(Double, GardenRGB, Double)] = [(0, env.hor, 0), (0.35, env.hor, 0.14), (1, env.hor, 0)]
        func stop(_ stops: [(Double, GardenRGB, Double)], _ f: Double) -> (GardenRGB, Double) {
            let f = clamp(f)
            for k in 1..<stops.count where f <= stops[k].0 {
                let a = stops[k - 1], b = stops[k], u = (f - a.0) / max(b.0 - a.0, 1e-9)
                return (mix(a.1, b.1, u), a.2 + (b.2 - a.2) * u)
            }
            return (stops[stops.count - 1].1, stops[stops.count - 1].2)
        }
        func veil(_ c: GardenRGB, _ y: Double) -> GardenRGB {
            var c = c
            if y >= hazeTop && y <= hazeBot { let v = stop(hazeStops, (y - hazeTop) / (hazeBot - hazeTop)); c = mix(c, v.0, v.1) }
            if y >= bandTop && y <= bandBot { let v = stop(mistStops, (y - bandTop) / (bandBot - bandTop)); c = mix(c, v.0, v.1) }
            return c
        }
        /// 当前上下文里按场景 y 画那两层薄雾（调用方定混合模式）
        func veilBands() {
            linear(CGRect(x: -W * 4, y: hazeTop, width: W * 9, height: hazeBot - hazeTop), CGPoint(x: 0, y: hazeTop), CGPoint(x: 0, y: hazeBot), hazeStops)
            linear(CGRect(x: -W * 4, y: bandTop, width: W * 9, height: bandBot - bandTop), CGPoint(x: 0, y: bandTop), CGPoint(x: 0, y: bandBot), mistStops)
        }

        // ── 夜空：银河、星星、点点金星 ──
        if env.night > 0.05 {
            let na = pow(env.night, 1.6)
            let a0 = (-0.1 * W, 0.04 * H), a1 = (1.1 * W, 0.46 * H)
            let dx = a1.0 - a0.0, dy = a1.1 - a0.1, dl = hypot(dx, dy)
            let band = hex("#ddd3ea")
            for i in 0..<18 {
                let f = Double(i) / 17, offset = (hash(i, 8, 0, 43) - 0.5) * W * 0.08
                let bx = a0.0 + dx * f - dy / dl * offset, by = a0.1 + dy * f + dx / dl * offset
                let br = W * (0.09 + hash(i, 9, 0, 43) * 0.08)
                radial(rectPath(CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2)), CGPoint(x: bx, y: by), 0, br, [(0, band, 0.07 * na), (1, band, 0)])
            }
            let dust = hex("#efe8f4")
            for i in 0..<220 {
                let f = hash(i, 1, 0, 42), offset = (hash(i, 2, 0, 42) + hash(i, 3, 0, 42) + hash(i, 4, 0, 42) - 1.5) * W * 0.09
                let x = a0.0 + dx * f - dy / dl * offset, y = a0.1 + dy * f + dx / dl * offset
                ctx.setFillColor(cg(dust, na * (0.15 + 0.35 * hash(i, 5, 0, 42))))
                ctx.fill(CGRect(x: x, y: y, width: 0.7 * u, height: 0.7 * u))
            }
            for i in 0..<80 {
                let x = hash(i, 1, 0, 40) * W, y = hash(i, 2, 0, 40) * H * 0.5
                let omega = 0.6 + hash(i, 3) * 1.4
                let tv = hash(i, 7, 0, 40)
                let tint = tv < 0.3 ? hex("#f3dcc6") : tv > 0.8 ? hex("#dcd6f2") : hex("#f4ecdc")
                let r = u * (0.45 + hash(i, 4) * 0.8)
                if let sink {
                    // 静帧里月晕盖在星上
                    var c = tint
                    if env.night > 0.15 {
                        let mr = W * 0.032, d = hypot(x - moonX, y - moonY)
                        if d < mr * 9 { c = mix(c, hex("#efe6f2"), 0.2 * smooth(0.15, 0.6, env.night) * (1 - max(0, d - mr) / (mr * 8))) }
                    }
                    sink.stars.append(.init(x: x, y: y, r: r, color: veil(c, y), alpha: na * 0.8, omega: omega, phase: Double(i), lo: 0.55, amp: 0.45))
                    continue
                }
                let tw = 0.55 + 0.45 * sin(t * omega + Double(i))
                dot(x, y, r, tint, na * tw * 0.8)
            }
            let k = u * 1.3, gold = hex("#d6b679")
            let star: [(Double, Double, Double)] = [(0, 0, 1.25), (2.2, 0, 0.85), (-2.2, 0, 0.85), (0, 2.2, 0.85), (0, -2.2, 0.85), (4, 0, 0.55), (-4, 0, 0.55), (0, 4, 0.55), (0, -4, 0.55)]
            if let sink {
                let box = CGRect(x: -5 * k, y: -5 * k, width: 10 * k, height: 10 * k)
                sink.goldStar = sprite(box, scale: scale) { c in
                    cur = c
                    for d in star { dot(d.0 * k, d.1 * k, d.2 * k, gold, 1) }
                    cur = ctx
                }
                sink.goldBox = box
            }
            for i in 0..<6 {
                let x = (0.08 + hash(i, 5, 0, 41) * 0.84) * W, y = (0.05 + hash(i, 6, 0, 41) * 0.36) * H
                if let sink {
                    sink.golds.append(.init(x: x, y: y, r: 0, color: gold, alpha: na, omega: 0.9, phase: Double(i) * 2.1, lo: 0.45 + 0.55 * 0.5, amp: 0.55 * 0.5))
                    continue
                }
                let tw = 0.5 + 0.5 * sin(t * 0.9 + Double(i) * 2.1)
                for d in star { dot(x + d.0 * k, y + d.1 * k, d.2 * k, gold, na * (0.45 + 0.55 * tw)) }
            }
        }

        // ── 太阳 / 月亮 ──
        if env.day > 0.02 {
            radial(circlePath(sunX, sunY, W * 0.4), CGPoint(x: sunX, y: sunY), 0, W * 0.4,
                   [(0, mix(env.sunC, white, 0.4), 0.55 * env.day), (0.18, env.sunC, 0.22 * env.day), (1, env.sunC, 0)])
            ctx.saveGState()
            ctx.translateBy(x: sunX, y: sunY); ctx.scaleBy(x: 1, y: 1 - 0.08 * warm)
            dot(0, 0, W * 0.04, mix(env.sunC, white, 0.55 - 0.3 * warm), 0.95 * env.day)
            ctx.restoreGState()
        }
        if env.night > 0.15 {
            let a = smooth(0.15, 0.6, env.night), r = W * 0.032, halo = hex("#efe6f2")
            radial(circlePath(moonX, moonY, r * 9), CGPoint(x: moonX, y: moonY), r, r * 9, [(0, halo, 0.2 * a), (1, halo, 0)])
            dot(moonX, moonY, r, hex("#f5eedf"), 0.96 * a)
            dot(moonX + r * 0.42, moonY - r * 0.22, r * 0.86, skyColorAt(moonY - r * 0.2), a)
            sink?.moon = CGRect(x: moonX - r, y: moonY - r, width: r * 2, height: r * 2)
        }

        // ── 云：阴面、亮面、朝太阳的金边，都用点点拼 ──
        let sunLit = env.amb + env.sunC * (env.sunI * 0.9)
        let cloudLight = mix(hex("#fffaf3") * sunLit, env.hor, 0.1)
        let cloudShade = mix(cloudLight, mix(env.top, hex("#9d96ad"), 0.3), 0.42)
        let cloudRim = mix(cloudLight, mix(env.sunC, white, 0.2), 0.25 + 0.55 * warm)
        let cloudA = 0.75 * (1 - 0.45 * env.night)
        for i in 0..<2 {
            let span = W * 1.6, x = (t * 1.2 + hash(i, 9, 0, 61) * span).truncatingRemainder(dividingBy: span) - W * 0.3, y = H * (0.07 + Double(i) * 0.09)
            func streak(_ c: CGContext, _ ax: Double, _ ay: Double) {
                c.saveGState(); c.translateBy(x: ax, y: ay); c.rotate(by: -0.04)
                c.setFillColor(cg(cloudLight, 0.14 * cloudA))
                c.fillEllipse(in: CGRect(x: -W * 0.32, y: -H * 0.006, width: W * 0.64, height: H * 0.012))
                c.restoreGState()
            }
            if let sink {
                let box = CGRect(x: -W * 0.33, y: -H * 0.006 - W * 0.02, width: W * 0.66, height: H * 0.012 + W * 0.04)
                if let image = sprite(box, scale: scale, { c in
                    streak(c, 0, 0)
                    cur = c; c.setBlendMode(.sourceAtop); c.translateBy(x: 0, y: -y); veilBands(); cur = ctx
                }) {
                    sink.clouds.append(.init(image: image, box: box, y: y, x: x, start: -W * 0.3, span: span, speed: 1.2))
                }
                continue
            }
            streak(ctx, x, y)
        }
        for i in 0..<5 {
            let cw = W * (0.2 + hash(i, 1, 0, 60) * 0.24), span = W + cw * 2
            let speed = 1.5 + hash(i, 4, 0, 60) * 3
            let x = (t * speed + hash(i, 2, 0, 60) * span).truncatingRemainder(dividingBy: span) - cw
            let y = H * (0.1 + hash(i, 3, 0, 60) * 0.3)
            // 云贴图按「锚点 = (x, y)」的相对坐标画，整屏版直接平移过去
            let dots: [(Double, Double, Double)] = (0..<13).map { k in
                let f = Double(k) / 12
                return ((f - 0.5) * cw, -(hash(i, k, 1, 62) - 0.3) * cw * 0.07, cw * (0.08 + 0.1 * sin(.pi * f) + hash(i, k, 2, 62) * 0.03))
            }
            let toward: Double = ((env.day > 0.1 ? sunX : moonX) - x) < 0 ? -1 : 1
            func paint(_ ax: Double, _ ay: Double) {
                for d in dots { dot(ax + d.0, ay + d.1 + d.2 * 0.2, d.2, cloudShade, cloudA) }
                for d in dots { dot(ax + d.0, ay + d.1, d.2 * 0.93, cloudLight, cloudA) }
                for d in dots { dot(ax + d.0 + toward * d.2 * 0.2, ay + d.1 - d.2 * 0.25, d.2 * 0.62, cloudRim, cloudA * 0.8) }
            }
            if let sink {
                var box = CGRect.null
                for d in dots { box = box.union(CGRect(x: d.0 - d.2 * 1.25, y: d.1 - d.2 * 1.3, width: d.2 * 2.5, height: d.2 * 2.6)) }
                box = box.integral
                if let image = sprite(box, scale: scale, { c in
                    cur = c; paint(0, 0)
                    c.setBlendMode(.sourceAtop); c.translateBy(x: 0, y: -y); veilBands(); cur = ctx
                }) {
                    sink.clouds.append(.init(image: image, box: box, y: y, x: x, start: -cw, span: span, speed: speed))
                }
                continue
            }
            paint(x, y)
        }

        // ── 远山：四层，越远越淡；中间那层山脊上几棵小柏树 ──
        let hillTone = ["#d2d7cc", "#c4ccbe", "#b5c1b2", "#a9b7a7"].map(hex)
        let litH = env.amb + env.sunC * (env.sunI * 0.6)
        func ridge(_ k: Int, _ x: Double) -> Double {
            let base = [y0 - s * 9, y0 - s * 6, y0 - s * 3, y0 + s][k]
            let kd = Double(k)
            return base - (sin(x / W * .pi * (1.2 + kd * 0.55) + kd * 1.9) * 0.5 + 0.5) * s * (6 - kd * 1.2) - sin(x / W * .pi * 5.1 + kd) * s * 0.6
        }
        for k in 0..<4 {
            let col = mix(env.hor, hillTone[k] * litH, 0.2 + Double(k) * 0.14)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: H))
            var x = 0.0
            while x <= W + 6 { path.addLine(to: CGPoint(x: x, y: ridge(k, x))); x += 5 }
            path.addLine(to: CGPoint(x: W, y: H)); path.closeSubpath()
            if let g = grad([(0, col, 1), (1, mix(col, env.hor, 0.35), 1)]) {
                ctx.saveGState(); ctx.addPath(path); ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: ridge(k, W / 2) - s * 6), end: CGPoint(x: 0, y: horizonY + s * 4), options: ext)
                ctx.restoreGState()
            }
            if k == 2 {
                let tree = mix(col, col * 0.85, 0.8)
                ctx.setFillColor(cg(tree))
                for i in 0..<9 {
                    let tx = (0.05 + hash(i, 1, 0, 63) * 0.9) * W, h = s * (1.1 + hash(i, 2, 0, 63) * 0.9)
                    let r = CGRect(x: tx - s * 0.28, y: ridge(k, tx) - h * 0.45 - h * 0.55, width: s * 0.56, height: h * 1.1)
                    ctx.fillEllipse(in: r)
                    sink?.cover(r.minX, r.maxX, r.minY)
                }
            }
            if let sink {
                var x = 0.0
                while x <= W + GardenParts.skyStep { sink.cover(x, x, ridge(k, x)); x += GardenParts.skyStep }
            }
        }
        linear(CGRect(x: 0, y: hazeTop, width: W, height: hazeBot - hazeTop), CGPoint(x: 0, y: hazeTop), CGPoint(x: 0, y: hazeBot), hazeStops)

        // ── 光照：半影软阴影、阴面偏冷、火盆照亮周围 ──
        var occ = scene.staticOcc
        let leafOn = { (r: Double) in r < env.leafA }
        for leaf in scene.leaves where leafOn(leaf.r) { occ[leaf.cell] = 1 }
        func occAt(_ x: Int, _ y: Int, _ z: Int) -> Bool {
            GardenScene.inBounds(x, y, z) && occ[GardenScene.cell(x, y, z)] != 0
        }
        let normals = [SIMD3<Double>(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let l1 = env.light
        let l2raw = env.light + SIMD3(0.07, -0.07, 0.06)
        let l2 = l2raw / max((l2raw * l2raw).sum().squareRoot(), 1e-9)
        func blocked(_ p: SIMD3<Double>, _ l: SIMD3<Double>) -> Bool {
            if l.z <= 0 { return false }
            for k in 1..<56 {
                let d = Double(k) * 0.4
                let x = Int((p.x + l.x * d).rounded(.down)), y = Int((p.y + l.y * d).rounded(.down)), z = Int((p.z + l.z * d).rounded(.down))
                if x < 0 || y < 0 || x >= n || y >= n || z >= zSize - zOff { return false }
                if z >= -zOff && occ[GardenScene.cell(x, y, z)] != 0 { return true }
            }
            return false
        }
        let ambTop = mix(env.amb, mix(env.top, zen, 0.5) * 0.6, 0.25 * env.day)
        let ambSide = env.amb * SIMD3(0.96, 0.95, 0.94) + hex("#c9c2a8") * (0.05 * env.day)
        let fireC = hex("#f6b98a")
        let flicker = 0.88 + 0.12 * sin(t * 9.3) * sin(t * 5.1)
        let fireK = env.lights * flicker
        func lightAt(_ face: Int, _ p: SIMD3<Double>, _ ao: Double) -> GardenRGB {
            let nn = normals[face]
            var m = (face == 0 ? ambTop : ambSide) * ao
            if env.sunI > 0.001 {
                let ld = (nn * l1).sum()
                if ld > 0 {
                    let sh = ((blocked(p, l1) ? 1.0 : 0) + (blocked(p, l2) ? 1.0 : 0)) / 2
                    if sh < 1 { m += env.sunC * (env.sunI * ld * (1 - sh)) }
                }
            }
            if env.moonI > 0.001 {
                let md = (nn * env.moonL).sum()
                if md > 0 { m += env.moonC * (env.moonI * md * (blocked(p, env.moonL) ? 0.3 : 1)) }
            }
            if fireK > 0.01 {
                for f in scene.fires {
                    let dv = f - p, d2 = (dv * dv).sum()
                    if d2 > 260 { continue }
                    let d = max(d2.squareRoot(), 1e-9), nd = (nn * dv).sum() / d
                    if nd > 0 { m += fireC * (fireK * nd * 2.4 / (1 + d2 / 5)) }
                }
            }
            return m
        }

        let lineW = max(0.5, s * 0.08)
        ctx.setLineWidth(lineW); off.setLineWidth(lineW)
        func face(_ c: CGContext, _ pts: [CGPoint], _ col: GardenRGB) {
            c.beginPath(); c.addLines(between: pts); c.closePath()
            let cc = cg(col); c.setFillColor(cc); c.setStrokeColor(cc)
            c.drawPath(using: .fillStroke)
        }
        func topPts(_ x: Double, _ y: Double, _ z: Double) -> [CGPoint] { [P(x, y, z + 1), P(x + 1, y, z + 1), P(x + 1, y + 1, z + 1), P(x, y + 1, z + 1)] }
        func cube(_ c: CGContext, _ x: Int, _ y: Int, _ z: Int, _ colT: GardenRGB?, _ colX: GardenRGB?, _ colY: GardenRGB?) {
            let X = Double(x), Y = Double(y), Z = Double(z)
            if let colT { face(c, topPts(X, Y, Z), colT) }
            if let colX { face(c, [P(X + 1, Y, Z + 1), P(X + 1, Y + 1, Z + 1), P(X + 1, Y + 1, Z), P(X + 1, Y, Z)], colX) }
            if let colY { face(c, [P(X, Y + 1, Z + 1), P(X + 1, Y + 1, Z + 1), P(X + 1, Y + 1, Z), P(X, Y + 1, Z)], colY) }
        }

        var glows: [CGPoint] = []
        let palettes = [["#e3a9b0", "#d99aa5", "#b3a2cc", "#f4ece4"], ["#d99aa5", "#b3a2cc", "#c98f9e", "#f4ece4"], ["#d9a07f", "#c98f9e", "#c9827a", "#d9a07f"], ["#f4ece4"]]
        let flowerPal = palettes[env.sw.w < 0.5 ? env.sw.i0 : env.sw.i1].map(hex)
        let gold = hex("#d6b679"), snowC = hex("#f8f6f1")
        let waterPath = CGMutablePath()
        var wbb = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        var wSum = GardenRGB(0, 0, 0), wN = 0.0
        let wuSpan = Double(max(1, scene.waterU.hi - scene.waterU.lo))
        let table = GardenMaterial.table

        /// `front` 非空：只把这一块额外画进前景裁片（不记火盆位置）
        func drawVoxel(_ v: GardenVoxel, front: CGContext? = nil) {
            let x = v.x, y = v.y, z = v.z, m = table[v.mat.rawValue]
            let c = P(Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5)
            if c.x < -2 * s || c.x > W + 2 * s || c.y < -2 * s || c.y > H + 2 * s { return }
            let showT = !occAt(x, y, z + 1)
            let showX = !m.water && !occAt(x + 1, y, z)
            let showY = !m.water && !occAt(x, y + 1, z)
            if !showT && !showX && !showY { return }
            // 天际线：体素六边形的上沿是个尖顶——顶点 P(x, y, z+1)，左右各 s、斜率 1/2
            if front == nil, let sink {
                let apex = P(Double(x), Double(y), Double(z) + 1)
                sink.coverTent(apex.x, s, apex.y)
            }
            let alb = m.color(env.sw) * ((m.grass ? 0.96 : 0.98) + (m.grass ? 0.08 : 0.04) * v.r)
            var albTop = alb
            var snowy = false
            if m.snowy && env.snow > 0.01 && hash(x, y, z, 31) < env.snow * 1.3 - 0.15 { albTop = snowC; snowy = true }
            if m.water {
                let f = clamp(Double(x + y - scene.waterU.lo) / wuSpan)
                albTop = mix(alb, mix(env.hor, env.top, 0.2 + 0.6 * f), 0.55 - 0.3 * f)
                if !scene.pool(x - 1, y) || !scene.pool(x, y - 1) || !scene.pool(x + 1, y) || !scene.pool(x, y + 1) { albTop *= 0.9 }
            }
            let haze = 0.03 + 0.12 * (1 - clamp(Double(x + y) / 90))
            var aoT = 1.0
            if showT {
                var cnt = 0
                for dx in -1...1 { for dy in -1...1 where (dx != 0 || dy != 0) && occAt(x + dx, y + dy, z + 1) { cnt += 1 } }
                aoT = 1 - 0.05 * Double(cnt)
            }
            let X = Double(x), Y = Double(y), Z = Double(z)
            let cT = showT ? lightAt(0, SIMD3(X + 0.5, Y + 0.5, Z + 1.02), aoT) : nil
            let cX = showX ? lightAt(1, SIMD3(X + 1.02, Y + 0.5, Z + 0.5), occAt(x + 1, y, z - 1) ? 0.82 : 0.9) : nil
            let cY = showY ? lightAt(2, SIMD3(X + 0.5, Y + 1.02, Z + 0.5), occAt(x, y + 1, z - 1) ? 0.82 : 0.9) : nil
            var colT = cT.map { mix(albTop * $0, env.hor, haze) }
            var colX = cX.map { mix(alb * $0, env.hor, haze) }
            var colY = cY.map { mix(alb * $0, env.hor, haze) }
            if let glow = m.glow, env.lights > 0.01 {
                let gk = env.lights * 0.95 * flicker
                colT = colT.map { mix($0, glow, gk) }; colX = colX.map { mix($0, glow, gk) }; colY = colY.map { mix($0, glow, gk) }
                if front == nil { glows.append(P(X + 0.5, Y + 0.5, Z + 0.9)) }
            }
            if m.water, showT, let colT {
                let pts = topPts(X, Y, Z)
                waterPath.addLines(between: pts); waterPath.closeSubpath()
                for p in pts { wbb = (min(wbb.minX, p.x), min(wbb.minY, p.y), max(wbb.maxX, p.x), max(wbb.maxY, p.y)) }
                wSum += colT; wN += 1
            }
            cube(front ?? ctx, x, y, z, colT, colX, colY)

            // 点点花：贴在草面上
            if showT, m.grass, !snowy, let cT, let f = scene.flowers[v.cell], f.b < env.bloom {
                let fp = P(X + 0.5 + f.ox * 0.3, Y + 0.5 + f.oy * 0.3, Z + 1)
                let petal = mix(flowerPal[Int(f.a * Double(flowerPal.count))] * cT, env.hor, haze)
                let core = mix(gold * cT, env.hor, haze)
                let r = s * 0.17, o = s * 0.24, lift = s * 0.15
                for d in [(o, 0.0), (-o, 0), (0, o * 0.6), (0, -o * 0.6)] { dot(fp.x + d.0, fp.y + d.1 - lift, r, petal, 1) }
                dot(fp.x, fp.y - lift, r * 0.8, core, 1)
            }
        }

        // 第一遍：地面（含水面）
        for v in scene.terrain { drawVoxel(v) }
        // 后坡和远山交界处起一层薄雾
        linear(CGRect(x: 0, y: bandTop, width: W, height: bandBot - bandTop), CGPoint(x: 0, y: bandTop), CGPoint(x: 0, y: bandBot), mistStops)

        // 第二遍：水面——倒影（按 t 定格的波纹位移）、近透远反、细纹、涟漪、碎光（动画版只画位移为 0 的倒影，其余交给动画层）
        if wN > 0 {
            let waterCol = wSum / wN
            let litSide = env.amb + env.sunC * (env.sunI * 0.55) + env.moonC * (env.moonI * 0.5)
            let under = env.amb * 0.7
            for v in scene.mirror {
                let m = table[v.mat.rawValue]
                if m.leaf && !leafOn(v.r) { continue }
                let x = v.x, y = v.y, z = v.z, mz = -z - 1
                let c = P(Double(x) + 0.5, Double(y) + 0.5, Double(mz) + 0.5)
                if c.x < wbb.minX - 2 * s || c.x > wbb.maxX + 2 * s || c.y < wbb.minY - 2 * s || c.y > wbb.maxY + 2 * s { continue }
                let showT = !occAt(x, y, z - 1), showX = !occAt(x + 1, y, z), showY = !occAt(x, y + 1, z)
                if !showT && !showX && !showY { continue }
                let alb = m.color(env.sw)
                var cT = mix(alb * under, waterCol, 0.5)
                var cX = mix(alb * (litSide * 0.95), waterCol, 0.38)
                var cY = mix(alb * (litSide * 0.85), waterCol, 0.38)
                if let glow = m.glow, fireK > 0.01 { let gk = fireK * 0.85; cT = mix(cT, glow, gk); cX = mix(cX, glow, gk); cY = mix(cY, glow, gk) }
                cube(off, x, y, mz, showT ? cT : nil, showX ? cX : nil, showY ? cY : nil)
            }
            let wRect = CGRect(x: wbb.minX, y: wbb.minY, width: wbb.maxX - wbb.minX, height: wbb.maxY - wbb.minY)
            let rc = mix(env.hor, white, 0.4)
            let glint: (x: Double, c: GardenRGB, k: Double)? = env.sunI > 0.03 ? (sunX, mix(env.sunC, white, 0.5), min(1, env.sunI * 1.4))
                : env.moonI > 0.08 ? (moonX, hex("#f4eee2"), env.moonI * 1.5) : nil
            if let sink {
                // 动画版：水裁片 = 地面上的水色 + 位移为 0 的倒影 + 水色渐变，池子里不透明、池子外透明；底图里也画这一张。
                // 细纹 / 涟漪 / 碎光不画，交给动画层
                func px(_ v: Double, _ up: Bool) -> Double { (up ? (v * scale).rounded(.up) : (v * scale).rounded(.down)) / scale }
                let x0 = px(wbb.minX - s, false), y0r = px(wbb.minY - 1, false)
                let rect = CGRect(x: x0, y: y0r, width: px(wbb.maxX + s, true) - x0, height: px(wbb.maxY + 1, true) - y0r)
                let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
                if let space = CGColorSpace(name: CGColorSpace.sRGB), let wc = context(Int(pixels.width), Int(pixels.height), space, scale: scale),
                   let below = ctx.makeImage()?.cropping(to: pixels), let mirror = off.makeImage()?.cropping(to: pixels) {
                    wc.translateBy(x: -rect.minX, y: -rect.minY)
                    wc.saveGState()
                    wc.addPath(waterPath); wc.clip()
                    drawUpright(wc, below, in: rect)
                    drawUpright(wc, mirror, in: rect)
                    cur = wc
                    linear(wRect, CGPoint(x: 0, y: wbb.minY), CGPoint(x: 0, y: wbb.maxY), [(0, waterCol, 0), (1, waterCol * 0.92, 0.3)])
                    cur = ctx
                    wc.restoreGState()
                    if let plain = wc.makeImage() { drawUpright(ctx, plain, in: rect) }
                    sink.waterContext = wc
                    sink.waterRect = rect
                    sink.waterPath = waterPath.copy()
                }
                sink.waterBounds = wRect
                sink.lineColor = rc
                sink.lineWidth = max(0.5, s * 0.1)
                sink.rippleWidth = max(0.5, s * 0.08)
                for i in 0..<22 {
                    sink.lines.append(.init(x: wbb.minX + hash(i, 1, 0, 70) * wRect.width, len: s * (1.5 + hash(i, 4, 0, 70) * 3),
                                            frac0: hash(i, 2, 0, 70), rate: 0.01 * (0.5 + hash(i, 3, 0, 70)), phase: Double(i) * 1.3))
                }
                sink.ripples = (0..<2).map { k in
                    let nn0 = Int((GardenParts.t0 / 7 + Double(k) * 0.5).rounded(.down))
                    return (0..<GardenParts.rippleCycles).map { j in
                        let cell = scene.waterCells[Int(hash(nn0 + j, k, 0, 90) * Double(scene.waterCells.count))]
                        return P(Double(cell.x) + 0.5, Double(cell.y) + 0.5, 0)
                    }
                }
                if let gl = glint {
                    sink.glintColor = gl.c
                    for i in 0..<70 {
                        let gx = wbb.minX + hash(i, 1, 0, 80) * wRect.width, gy = wbb.minY + hash(i, 2, 0, 80) * wRect.height
                        let peak = exp(-pow((gx - gl.x) / (W * 0.17), 2)) * gl.k
                        if peak < 0.03 { continue }
                        sink.glints.append(.init(x: gx, y: gy, len: s * (0.25 + hash(i, 4, 0, 80) * 0.35), alpha: peak,
                                                 omega: 1.4 + hash(i, 3, 0, 80) * 2.6, phase: Double(i) * 2.1))
                    }
                }
            } else {
                ctx.saveGState()
                ctx.addPath(waterPath); ctx.clip()
                if let mirrorImage = off.makeImage() {
                    let stripPx = max(1, Int((2 * scale).rounded()))
                    var yy = wbb.minY.rounded(.down)
                    while yy < wbb.maxY {
                        let dx = sin(yy * 0.45 + t * 1.7) * s * 0.1 + sin(yy * 0.12 - t * 0.6) * s * 0.16
                        let srcY = Int((yy * scale).rounded())
                        if srcY >= 0, srcY + stripPx <= mirrorImage.height,
                           let strip = mirrorImage.cropping(to: CGRect(x: 0, y: srcY, width: mirrorImage.width, height: stripPx)) {
                            ctx.saveGState()
                            ctx.translateBy(x: 0, y: yy * 2 + 2); ctx.scaleBy(x: 1, y: -1)
                            ctx.draw(strip, in: CGRect(x: dx, y: yy, width: W, height: 2))
                            ctx.restoreGState()
                        }
                        yy += 2
                    }
                }
                linear(wRect, CGPoint(x: 0, y: wbb.minY), CGPoint(x: 0, y: wbb.maxY), [(0, waterCol, 0), (1, waterCol * 0.92, 0.3)])
                ctx.setLineCap(.round)
                ctx.setLineWidth(max(0.5, s * 0.1))
                for i in 0..<22 {
                    let rx = wbb.minX + hash(i, 1, 0, 70) * wRect.width
                    let ry = wbb.minY + (hash(i, 2, 0, 70) + t * 0.01 * (0.5 + hash(i, 3, 0, 70))).truncatingRemainder(dividingBy: 1) * wRect.height
                    let len = s * (1.5 + hash(i, 4, 0, 70) * 3)
                    ctx.setStrokeColor(cg(rc, 0.16 * (0.5 + 0.5 * sin(t * 0.8 + Double(i) * 1.3))))
                    ctx.strokeLineSegments(between: [CGPoint(x: rx - len / 2, y: ry), CGPoint(x: rx + len / 2, y: ry)])
                }
                ctx.setLineWidth(max(0.5, s * 0.08))
                for k in 0..<2 {
                    let ph = t / 7 + Double(k) * 0.5, nn = Int(ph.rounded(.down)), f = ph - Double(nn)
                    let cell = scene.waterCells[Int(hash(nn, k, 0, 90) * Double(scene.waterCells.count))]
                    let cp = P(Double(cell.x) + 0.5, Double(cell.y) + 0.5, 0)
                    for r in 0..<2 {
                        let ff = f - Double(r) * 0.18
                        if ff <= 0 { continue }
                        let rr = s * (0.4 + ff * 4.5)
                        ctx.setStrokeColor(cg(rc, (1 - ff) * 0.3))
                        ctx.strokeEllipse(in: CGRect(x: cp.x - rr, y: cp.y - rr / 2, width: rr * 2, height: rr))
                    }
                }
                if let gl = glint {
                    for i in 0..<70 {
                        let gx = wbb.minX + hash(i, 1, 0, 80) * wRect.width, gy = wbb.minY + hash(i, 2, 0, 80) * wRect.height
                        let bandK = exp(-pow((gx - gl.x) / (W * 0.17), 2))
                        let tw = pow(max(0, sin(t * (1.4 + hash(i, 3, 0, 80) * 2.6) + Double(i) * 2.1)), 6)
                        let a = bandK * tw * gl.k
                        if a < 0.03 { continue }
                        ctx.setFillColor(cg(gl.c, a))
                        let l = s * (0.25 + hash(i, 4, 0, 80) * 0.35)
                        ctx.fill(CGRect(x: gx - l, y: gy - 0.35 * u, width: l * 2, height: 0.7 * u))
                        ctx.fill(CGRect(x: gx - 0.35 * u, y: gy - l * 0.45, width: 0.7 * u, height: l * 0.9))
                    }
                }
                ctx.restoreGState()
            }
        }

        // 第三遍：柱廊、雕像、树、废墟（动画版另把池子范围里的那些画进前景裁片，好盖在会动的水上面）
        ctx.setLineWidth(lineW)
        var front: CGContext?
        if let sink, let rect = sink.waterRect, let space = CGColorSpace(name: CGColorSpace.sRGB),
           let fc = context(Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()), space, scale: scale) {
            fc.translateBy(x: -rect.minX, y: -rect.minY)
            fc.setLineWidth(lineW)
            front = fc
        }
        let reach = (sink?.waterRect ?? .null).insetBy(dx: -2 * s, dy: -2 * s)
        for v in scene.objects {
            if table[v.mat.rawValue].leaf && !leafOn(v.r) { continue }
            drawVoxel(v)
            if let front, reach.contains(P(Double(v.x) + 0.5, Double(v.y) + 0.5, Double(v.z) + 0.5)) { drawVoxel(v, front: front) }
        }

        // 夜里火盆的光晕（动画版交给动画层闪）
        let fireHalo = hex("#f6c79e"), fireCore = hex("#f8d2a8")
        let haloR = s * 6, haloA = env.lights * 0.32
        if let sink {
            if haloA > 0.003, !glows.isEmpty {
                let box = CGRect(x: -haloR, y: -haloR, width: haloR * 2, height: haloR * 2)
                sink.halo = sprite(box, scale: scale) { c in
                    cur = c
                    radial(circlePath(0, 0, haloR), .zero, 0, haloR, [(0, fireCore, haloA), (0.3, fireHalo, haloA * 0.45), (1, fireHalo, 0)])
                    cur = ctx
                }
                sink.haloBox = box
                sink.halos = glows
            }
        } else {
            for g in glows {
                let a = haloA * flicker
                radial(circlePath(g.x, g.y, haloR), g, 0, haloR, [(0, fireCore, a), (0.3, fireHalo, a * 0.45), (1, fireHalo, 0)])
            }
        }

        // 萤火（只有动画版：静帧里不画，同 v1）
        if let sink {
            let ff = env.night * (1 - env.sw.weight(3)) * (0.5 + 0.5 * env.sw.weight(1))
            if ff > 0.02 {
                sink.fireflyAlpha = ff
                sink.fireflies = GardenParts.fireflySpots.map { P($0.0, $0.1, $0.2) }
                let box = CGRect(x: -2 * s, y: -2 * s, width: 4 * s, height: 4 * s)
                sink.firefly = sprite(box, scale: scale) { c in
                    cur = c
                    radial(circlePath(0, 0, 2 * s), .zero, 0, 2 * s, [(0, gold, 0.5), (1, gold, 0)])
                    dot(0, 0, s * 0.2, hex("#f6e2b0"), 1)
                    cur = ctx
                }
                sink.fireflyBox = box
            }
        }

        // 收尾：黄昏 / 清晨一层柔光，四角轻微压暗。动画版暗角不进底图，单独出一张小图盖在所有动画层上面（星 / 云 / 粒子也被压暗）
        func glow() {
            if warm > 0.03 {
                cur.saveGState()
                cur.setBlendMode(.screen)
                radial(rectPath(full), CGPoint(x: sunX, y: sunY), 0, W * 0.95, [(0, env.sunC, 0.12 * warm), (1, env.sunC, 0)])
                cur.restoreGState()
            }
        }
        func vignette() {
            radial(rectPath(full), CGPoint(x: W / 2, y: H * 0.55), H * 0.35, H * 0.8,
                   [(0, env.top, 0), (1, env.top * 0.6, 0.06 + 0.2 * env.night)])
        }
        glow()
        if let sink {
            sink.vignette = sprite(full, scale: GardenParts.vignetteScale) { c in cur = c; vignette(); cur = ctx }
        } else {
            vignette()
        }
        // 两张裁片也吃同样的柔光，再按之前的透明度裁回去（池子外 / 前景空处保持透明）
        if let sink, let rect = sink.waterRect {
            func finished(_ c: CGContext) -> CGImage? {
                guard let shape = c.makeImage() else { return nil }
                cur = c
                glow()
                cur = ctx
                c.saveGState(); c.setBlendMode(.destinationIn); drawUpright(c, shape, in: rect); c.restoreGState()
                return c.makeImage()
            }
            sink.water = sink.waterContext.flatMap(finished)
            sink.front = front.flatMap(finished)
            sink.waterContext = nil
        }
    }
}
