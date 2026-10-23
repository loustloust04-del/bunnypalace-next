import CoreGraphics
import Foundation

// 画板笔刷引擎（docs/plan-page1-note-drawing.md §D，算法 1:1 搬自 docs/design-page1-笔刷与便利贴.html）。
// 坐标一律画布 pt、左上原点；位图按 `BrushEngine.scale` 倍。随机数全带种子，重开画稿同一笔画出来一样。

// MARK: - 模型

struct BrushPoint: Codable, Hashable {
    var x: CGFloat
    var y: CGFloat
    /// 秒
    var t: Double
    /// 触控笔压力 0…1；手指 / 鼠标为 nil（按速度出粗细）
    var p: CGFloat?
}

enum PaintTool: String, Codable, CaseIterable {
    case watercolor, pen, nib, eraser
}

struct PaintStroke: Codable, Identifiable {
    var id = UUID()
    var tool: PaintTool
    var color: String
    var size: CGFloat
    var water: CGFloat = 0.6
    /// 平头笔尖角（度）
    var angle: CGFloat = 35
    var seed: UInt64
    var points: [BrushPoint]
}

enum PaperKind: String, Codable, CaseIterable {
    case cream, cold, grid, magnet

    var title: String {
        switch self {
        case .cream: "奶白"
        case .cold: "水彩纸"
        case .grid: "方格"
        case .magnet: "磁性画板"
        }
    }
}

struct RenderedStroke: @unchecked Sendable {
    let image: CGImage
    /// 画布 pt
    let rect: CGRect
}

struct BrushRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}

// MARK: - 噪声场（纸纹 + 低频），整张画布一份

struct NoiseField: @unchecked Sendable {
    let width: Int
    let height: Int
    /// 高频：纸纹 / 颗粒
    let fine: [Float]
    /// 低频：水彩扭边 / 颜料浓淡 / 水花
    let low: [Float]

    init(canvas: CGSize, seed: UInt64, scale: CGFloat = BrushEngine.scale) {
        width = max(1, Int((canvas.width * scale).rounded(.up)))
        height = max(1, Int((canvas.height * scale).rounded(.up)))
        fine = Self.make(width, height, seed: seed, scales: [3, 9, 26], weights: [0.5, 0.32, 0.18], px: scale)
        low = Self.make(width, height, seed: seed &+ 7, scales: [18, 46, 110], weights: [0.25, 0.45, 0.3], px: scale)
    }

    @inline(__always) func fine(_ x: Int, _ y: Int) -> CGFloat {
        CGFloat(fine[min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))])
    }

    /// 低频场取样绕回（偏移取样不撞边）
    @inline(__always) func low(_ x: Int, _ y: Int) -> CGFloat {
        let xx = ((x % width) + width) % width, yy = ((y % height) + height) % height
        return CGFloat(low[yy * width + xx])
    }

    private static func make(_ w: Int, _ h: Int, seed: UInt64, scales: [CGFloat], weights: [Float], px: CGFloat) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        for (k, s) in scales.enumerated() {
            let step = Float(s * px)
            let gw = Int(Float(w) / step) + 3, gh = Int(Float(h) / step) + 3
            var rng = BrushRandom(seed: seed &+ UInt64(k) &* 1_000_003)
            let grid = (0..<(gw * gh)).map { _ in Float(rng.unit()) }
            let wt = weights[k]
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let fy = Float(y) / step, iy = Int(fy), ty = fy - Float(iy), sy = ty * ty * (3 - 2 * ty)
                    for x in 0..<w {
                        let fx = Float(x) / step, ix = Int(fx), tx = fx - Float(ix), sx = tx * tx * (3 - 2 * tx)
                        let i0 = iy * gw + ix
                        let a0 = grid[i0] + (grid[i0 + 1] - grid[i0]) * sx
                        let a1 = grid[i0 + gw] + (grid[i0 + gw + 1] - grid[i0 + gw]) * sx
                        o[y * w + x] += wt * (a0 + (a1 - a0) * sy)
                    }
                }
            }
        }
        return out
    }
}

// MARK: - 引擎

enum BrushEngine {
    /// 位图倍率：水彩本来就软，2× 够；比 3× 省一半多算力
    static let scale: CGFloat = 2

    struct Sample {
        var x: CGFloat, y: CGFloat, w: CGFloat, v: CGFloat
    }

    // MARK: 笔画几何

    /// 原始点 → 带半宽 / 速度的采样（压力优先，没有就按速度：慢 = 粗、浓）
    static func samples(_ s: PaintStroke) -> [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(s.points.count)
        var lastT = 0.0
        for (i, p) in s.points.enumerated() {
            var vs: CGFloat = 0
            if i > 0, let last = out.last {
                let dt = max(1, (p.t - lastT) * 1000)
                let v = hypot(p.x - last.x, p.y - last.y) / CGFloat(dt)
                vs = last.v * 0.7 + v * 0.3
            }
            let k: CGFloat
            if let pr = p.p, pr > 0 { k = pow(pr, 0.8) * 1.15 } else { k = max(0.28, 1 - min(1, vs / 1.6) * 0.72) }
            var w: CGFloat
            switch s.tool {
            case .watercolor: w = s.size * 0.5 * (0.55 + 0.6 * k)
            case .pen: w = max(0.45, s.size * 0.1 * (0.18 + 1.1 * k * k))
            case .nib, .eraser: w = s.size * 0.5
            }
            if let last = out.last { w = last.w * 0.6 + w * 0.4 }
            out.append(Sample(x: p.x, y: p.y, w: w, v: vs))
            lastT = p.t
        }
        return out
    }

    /// Catmull-Rom 插值 + 等距采样
    static func resample(_ raw: [Sample], step: CGFloat) -> [Sample] {
        guard raw.count >= 2 else { return raw }
        var out = [raw[0]]
        for i in 0..<(raw.count - 1) {
            let p0 = raw[max(0, i - 1)], p1 = raw[i], p2 = raw[i + 1], p3 = raw[min(raw.count - 1, i + 2)]
            let n = max(1, Int((hypot(p2.x - p1.x, p2.y - p1.y) / step).rounded(.up)))
            for k in 1...n {
                let t = CGFloat(k) / CGFloat(n), t2 = t * t, t3 = t2 * t
                func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(Sample(x: cr(p0.x, p1.x, p2.x, p3.x), y: cr(p0.y, p1.y, p2.y, p3.y),
                                  w: p1.w + (p2.w - p1.w) * t, v: p1.v + (p2.v - p1.v) * t))
            }
        }
        return out
    }

    /// 变宽笔画的轮廓多边形（两侧 + 圆头）
    static func outline(_ pts: [Sample]) -> [CGPoint] {
        guard let first = pts.first else { return [] }
        if pts.count == 1 {
            return stride(from: 0, to: CGFloat.pi * 2, by: 0.3).map { CGPoint(x: first.x + cos($0) * first.w, y: first.y + sin($0) * first.w) }
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in pts.indices {
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let l = max(hypot(dx, dy), 0.0001)
            dx /= l; dy /= l
            let p = pts[i]
            left.append(CGPoint(x: p.x - dy * p.w, y: p.y + dx * p.w))
            right.append(CGPoint(x: p.x + dy * p.w, y: p.y - dx * p.w))
        }
        func cap(_ p: Sample, from: CGPoint, to: CGPoint) -> [CGPoint] {
            let a0 = atan2(from.y - p.y, from.x - p.x)
            var a1 = atan2(to.y - p.y, to.x - p.x)
            if a1 > a0 { a1 -= .pi * 2 }
            var r: [CGPoint] = []
            var a = a0 - 0.35
            while a > a1 { r.append(CGPoint(x: p.x + cos(a) * p.w, y: p.y + sin(a) * p.w)); a -= 0.35 }
            return r
        }
        let last = pts[pts.count - 1]
        return left + cap(last, from: left[left.count - 1], to: right[right.count - 1])
            + right.reversed() + cap(first, from: right[0], to: left[0])
    }

    static func path(_ poly: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        if let f = poly.first { p.move(to: f); poly.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath() }
        return p
    }

    /// 尖头：起笔从 35% 粗长到满、收笔出尖
    static func taperedPen(_ s: PaintStroke) -> [Sample] {
        var pts = resample(samples(s), step: 1.2)
        let n = pts.count
        for i in pts.indices {
            let t0 = min(1, CGFloat(i) / 8), t1 = min(1, CGFloat(n - 1 - i) / 14)
            pts[i].w *= (0.35 + 0.65 * t0) * (0.15 + 0.85 * pow(t1, 0.7))
        }
        return pts
    }

    static func nibHalf(_ p: Sample, _ s: PaintStroke) -> CGFloat {
        s.size * 0.62 * (0.82 + 0.18 * min(1, 0.25 / (p.v + 0.05)))
    }

    /// 实时预览形：水彩 = 湿迹轮廓；钢笔 = 成品轮廓（不带墨色起伏）
    static func livePath(_ s: PaintStroke) -> CGPath {
        switch s.tool {
        case .watercolor: return path(outline(resample(samples(s), step: 3)))
        case .pen: return path(outline(taperedPen(s)))
        case .nib: return nibPath(s)
        case .eraser:
            let p = CGMutablePath()
            if let f = s.points.first { p.move(to: CGPoint(x: f.x, y: f.y)); s.points.dropFirst().forEach { p.addLine(to: CGPoint(x: $0.x, y: $0.y)) } }
            return p
        }
    }

    static func nibPath(_ s: PaintStroke) -> CGPath {
        let pts = resample(samples(s), step: 1)
        let th = s.angle * .pi / 180, c = cos(th), sn = sin(th)
        let path = CGMutablePath()
        for i in pts.indices.dropLast() {
            let a = pts[i], q = pts[i + 1], ha = nibHalf(a, s), hq = nibHalf(q, s)
            path.addLines(between: [CGPoint(x: a.x + c * ha, y: a.y - sn * ha), CGPoint(x: q.x + c * hq, y: q.y - sn * hq),
                                    CGPoint(x: q.x - c * hq, y: q.y + sn * hq), CGPoint(x: a.x - c * ha, y: a.y + sn * ha)])
            path.closeSubpath()
        }
        if pts.count == 1, let p = pts.first {
            let h = nibHalf(p, s)
            path.addLines(between: [CGPoint(x: p.x + c * h, y: p.y - sn * h - 0.6), CGPoint(x: p.x + c * h, y: p.y - sn * h + 0.6),
                                    CGPoint(x: p.x - c * h, y: p.y + sn * h + 0.6), CGPoint(x: p.x - c * h, y: p.y + sn * h - 0.6)])
            path.closeSubpath()
        }
        return path
    }

    // MARK: 渲染（后台线程安全：纯函数）

    static func render(_ s: PaintStroke, field: NoiseField, canvas: CGSize, paper: PaperKind) -> RenderedStroke? {
        guard !s.points.isEmpty else { return nil }
        switch s.tool {
        case .watercolor: return watercolor(s, field: field, canvas: canvas, paper: paper)
        case .pen, .nib: return pen(s, field: field, canvas: canvas)
        case .eraser: return nil
        }
    }

    private static func bounds(_ pts: [CGPoint], margin: CGFloat, canvas: CGSize) -> CGRect? {
        guard !pts.isEmpty else { return nil }
        var r = CGRect.null
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        r = r.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: canvas)).integral
        return r.isEmpty ? nil : r
    }

    /// 左上原点、pt 坐标的 RGBA 位图
    private static func rgbaContext(_ r: CGRect) -> CGContext? {
        let w = Int(r.width * scale), h = Int(r.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        return ctx
    }

    static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0
        return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }

    static func cgColor(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let (r, g, b) = rgb(hex)
        return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, alpha])!
    }

    static func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] {
        let r = max(1, radius), k = 1 / Float(2 * r + 1)
        var tmp = [Float](repeating: 0, count: w * h), out = src
        for _ in 0..<2 {
            for y in 0..<h {
                let row = y * w
                var acc: Float = 0
                for x in -r...r { acc += out[row + min(w - 1, max(0, x))] }
                for x in 0..<w {
                    tmp[row + x] = acc * k
                    acc += out[row + min(w - 1, x + r + 1)] - out[row + max(0, x - r)]
                }
            }
            for x in 0..<w {
                var acc: Float = 0
                for y in -r...r { acc += tmp[min(h - 1, max(0, y)) * w + x] }
                for y in 0..<h {
                    out[y * w + x] = acc * k
                    acc += tmp[min(h - 1, y + r + 1) * w + x] - tmp[max(0, y - r) * w + x]
                }
            }
        }
        return out
    }

    // MARK: 水彩
    // 平滑笔形 → 低频噪声场扭边（水往纸纹里渗）→ 软阈值出边 → 边上一圈积色（干边）
    // → 中频浓淡 → 纸纹颗粒 → 水多时冲出水花。叠色由调用方用正片叠底合成。

    private static func watercolor(_ s: PaintStroke, field: NoiseField, canvas: CGSize, paper: PaperKind) -> RenderedStroke? {
        var rng = BrushRandom(seed: s.seed)
        var pts = resample(samples(s), step: 3)
        let ph0 = rng.unit() * 6, ph1 = rng.unit() * 6
        var dist: CGFloat = 0
        for i in pts.indices {
            if i > 0 { dist += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
            pts[i].w *= 0.85 + 0.18 * sin(dist / s.size * 0.7 + ph0) + 0.08 * sin(dist / s.size * 1.9 + ph1)
        }
        let poly = outline(pts)
        let water = s.water
        let amp = s.size * (0.22 + 0.35 * water)
        guard let r = bounds(poly, margin: amp + s.size * 0.4 + 8, canvas: canvas) else { return nil }
        let w = Int(r.width * scale), h = Int(r.height * scale)
        guard w > 0, h > 0, let mask = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                 space: CGColorSpaceCreateDeviceGray(),
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        mask.translateBy(x: 0, y: CGFloat(h))
        mask.scaleBy(x: scale, y: -scale)
        mask.translateBy(x: -r.minX, y: -r.minY)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.addPath(path(poly))
        mask.fillPath()
        guard let mdata = mask.data else { return nil }
        let mp = mdata.bindMemory(to: UInt8.self, capacity: w * h)
        var m = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { m[i] = Float(mp[i]) / 255 }
        let sm = boxBlur(m, w, h, radius: Int(max(1.5, s.size * (0.1 + 0.12 * water) * scale)))

        let ox = Int((r.minX * scale).rounded()), oy = Int((r.minY * scale).rounded())
        let seed = Int(rng.next() % 400), A = CGFloat(scale) * amp
        let soft = 0.06 + 0.16 * water
        struct Bloom { var x: CGFloat, y: CGFloat, r: CGFloat, o: Int }
        var blooms: [Bloom] = []
        if water > 0.72, pts.count > 14 {
            for _ in 0..<(water > 0.82 ? 2 : 1) {
                let p = pts[Int(CGFloat(pts.count) * (0.25 + 0.5 * rng.unit()))]
                blooms.append(Bloom(x: (p.x - r.minX) * scale, y: (p.y - r.minY) * scale,
                                    r: p.w * (1.3 + 0.5 * rng.unit()) * scale, o: Int(rng.next() % 300)))
            }
        }
        let gran: CGFloat = paper == .cold ? 0.55 : 0.22
        let (cr, cg, cb) = rgb(s.color)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let gx = ox + x, gy = oy + y
                let u = (field.low(gx + seed, gy) - 0.5) * 2 * A, v = (field.low(gx, gy + seed) - 0.5) * 2 * A
                let sx = min(w - 1, max(0, x + Int(u))), sy = min(h - 1, max(0, y + Int(v)))
                let mv = CGFloat(sm[sy * w + sx])
                if mv < 0.02 { continue }
                let t = min(1, max(0, (mv - (0.5 - soft)) / (2 * soft)))
                let a0 = t * t * (3 - 2 * t)
                if a0 <= 0 { continue }
                let rim = exp(-pow((mv - 0.5) / (soft * 1.25 + 0.04), 2))
                let pig = field.low(gx + seed * 2, gy + seed)
                var a = a0 * (0.42 + 0.32 * pig) + rim * a0 * 0.42
                for bm in blooms {
                    let dx = CGFloat(x) - bm.x, dy = CGFloat(y) - bm.y
                    let re = bm.r * (0.45 + 1.1 * field.low(gx * 3 + bm.o, gy * 3)), d = hypot(dx, dy)
                    if d < re { a *= 0.68 + 0.3 * pow(d / re, 2) }
                    a += 0.24 * a0 * exp(-pow((d - re) / (1.4 * scale), 2))
                }
                a *= 1 - gran * (field.fine(gx, gy) - 0.45) * 1.4
                a = min(0.88, max(0, a))
                let o = (y * w + x) * 4
                out[o] = UInt8(cr * a * 255); out[o + 1] = UInt8(cg * a * 255); out[o + 2] = UInt8(cb * a * 255); out[o + 3] = UInt8(a * 255)
            }
        }
        return image(out, w, h).map { RenderedStroke(image: $0, rect: r) }
    }

    // MARK: 钢笔

    private static func pen(_ s: PaintStroke, field: NoiseField, canvas: CGSize) -> RenderedStroke? {
        let isNib = s.tool == .nib
        let shape: CGPath
        var pooling: [(CGPoint, CGFloat, CGFloat)] = []
        if isNib {
            shape = nibPath(s)
        } else {
            let pts = taperedPen(s)
            shape = path(outline(pts))
            // 积墨：起笔、慢处
            if let f = pts.first { pooling.append((CGPoint(x: f.x, y: f.y), f.w * 1.25 + 0.4, 0.55)) }
            if pts.count > 8 {
                for i in stride(from: 4, to: pts.count - 4, by: 3) where pts[i].v < 0.08 {
                    pooling.append((CGPoint(x: pts[i].x, y: pts[i].y), pts[i].w * 1.15, 0.18))
                }
            }
        }
        let bb = shape.boundingBoxOfPath
        guard !bb.isNull, let r = bounds([bb.origin, CGPoint(x: bb.maxX, y: bb.maxY)], margin: s.size * 0.4 + 6, canvas: canvas),
              let ctx = rgbaContext(r) else { return nil }
        ctx.setFillColor(cgColor(s.color))
        ctx.addPath(shape)
        ctx.fillPath(using: .winding)
        for (c, rad, a) in pooling {
            ctx.setFillColor(cgColor(s.color, alpha: a))
            ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        }
        // 墨色浓淡：随纸纹轻微起伏
        guard let data = ctx.data else { return nil }
        let w = ctx.width, h = ctx.height, amt: CGFloat = isNib ? 0.16 : 0.12
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let ox = Int((r.minX * scale).rounded()), oy = Int((r.minY * scale).rounded())
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if px[o + 3] == 0 { continue }
                let f = min(1, max(0, 1 - amt * 0.6 + amt * (field.fine(ox + x, oy + y) - 0.5) * 2.2))
                px[o] = UInt8(CGFloat(px[o]) * f); px[o + 1] = UInt8(CGFloat(px[o + 1]) * f)
                px[o + 2] = UInt8(CGFloat(px[o + 2]) * f); px[o + 3] = UInt8(CGFloat(px[o + 3]) * f)
            }
        }
        return ctx.makeImage().map { RenderedStroke(image: $0, rect: r) }
    }

    private static func image(_ rgba: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: 纸

    static func paperImage(_ kind: PaperKind, field: NoiseField) -> CGImage? {
        let w = field.width, h = field.height
        let base: (CGFloat, CGFloat, CGFloat) = switch kind {
        case .magnet: (224, 227, 215)
        case .cold: (250, 247, 240)
        case .cream, .grid: (252, 249, 242)
        }
        let amp: CGFloat = kind == .cold ? 26 : kind == .magnet ? 6 : 7
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let n = (CGFloat(field.fine[i]) - 0.5) * amp
            out[i * 4] = UInt8(min(255, max(0, base.0 + n)))
            out[i * 4 + 1] = UInt8(min(255, max(0, base.1 + n)))
            out[i * 4 + 2] = UInt8(min(255, max(0, base.2 + n * 1.1)))
        }
        guard let img = image(out, w, h) else { return nil }
        guard kind == .grid || kind == .magnet,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        let size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        if kind == .grid {
            ctx.setStrokeColor(red: 140 / 255, green: 175 / 255, blue: 168 / 255, alpha: 0.32)
            ctx.setLineWidth(0.6)
            for x in stride(from: CGFloat(16), to: size.width, by: 16) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: CGFloat(16), to: size.height, by: 16) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)) }
            ctx.strokePath()
        } else {
            ctx.setFillColor(red: 209 / 255, green: 212 / 255, blue: 199 / 255, alpha: 1)
            for x in stride(from: CGFloat(5), to: size.width, by: 5) {
                for y in stride(from: CGFloat(5), to: size.height, by: 5) { ctx.fill(CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)) }
            }
        }
        return ctx.makeImage()
    }
}
