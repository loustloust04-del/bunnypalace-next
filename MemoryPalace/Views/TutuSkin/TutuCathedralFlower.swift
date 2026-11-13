#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics

final class TutuCathedralFlower {
    private struct Petal {
        let kind: Character
        let angle: Double
        let length: Double
        let width: Double
        let radius: Double
        let bow: Double
    }
    private struct Stamen { let angle: Double; let length: Double; let bend: Double }
    private struct Lobe { let angle: Double; let length: Double }
    private struct Frame { let a: SIMD3<Double>; let u1: SIMD3<Double>; let u2: SIMD3<Double> }
    private struct Geometry {
        let base: SIMD3<Double>
        let tip: SIMD3<Double>
        let mid: SIMD3<Double>
        let tangent: SIMD3<Double>
        let width: Double
        let kind: Character
    }
    private enum FlowerError: Error { case bitmapContext, gradient }
    private let petals: [Petal]
    private let stamens: [Stamen]
    private let lobes: [Lobe]
    private static let center = SIMD3<Double>(64, 214, 0)
    private static let layer = 64.0 / 255.0

    init() {
        var seed: Int64 = 20241127
        func random() -> Double {
            seed = (seed * 16807) % 2147483647
            return Double(seed - 1) / 2147483646
        }
        var p: [Petal] = []
        p.reserveCapacity(41)
        for i in 0..<18 {
            p.append(Petal(kind: "o", angle: Double(i) / 18 * 2 * .pi + (random() - 0.5) * 0.16,
                           length: 84 + random() * 12, width: 7.5 + random() * 2,
                           radius: 10, bow: -0.20 - random() * 0.08))
        }
        for i in 0..<14 {
            p.append(Petal(kind: "i", angle: (Double(i) + 0.5) / 14 * 2 * .pi + (random() - 0.5) * 0.12,
                           length: 78 + random() * 10, width: 27 + random() * 5, radius: 8, bow: 0.07))
        }
        for i in 0..<9 {
            p.append(Petal(kind: "j", angle: (Double(i) + 0.2) / 9 * 2 * .pi + (random() - 0.5) * 0.14,
                           length: 60 + random() * 6, width: 22 + random() * 4, radius: 5, bow: 0.12))
        }
        var s: [Stamen] = []
        s.reserveCapacity(64)
        for _ in 0..<64 {
            s.append(Stamen(angle: random() * 2 * .pi, length: 24 + random() * 16, bend: 0.26 + random() * 0.44))
        }
        var l: [Lobe] = []
        l.reserveCapacity(15)
        for i in 0..<15 {
            l.append(Lobe(angle: Double(i) / 15 * 2 * .pi + (random() - 0.5) * 0.2, length: 6 + random() * 2.2))
        }
        petals = p
        stamens = s
        lobes = l
    }

    func pixels(openness e: Double) throws -> [UInt8] {
        let size = 1024
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw FlowerError.bitmapContext }
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            // Bitmap rows are returned top-down; Canvas's positive Y points down.
            context.translateBy(x: 0, y: Double(size))
            context.scaleBy(x: 1, y: -1)
            let k = 1024.0 / 300.0
            context.concatenate(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: 50 * k, ty: -40 * k))
            try draw(context, e)
        }
        return bytes
    }

    private static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func normalized(_ v: SIMD3<Double>) -> SIMD3<Double> {
        v / sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    }
    private static func frame(_ e: Double) -> Frame {
        let g = lerp(0.18, 0.95, ease(e / 0.8))
        let a = normalized(SIMD3<Double>(cos(g) * sin(0.85), -cos(g) * cos(0.85), sin(g)))
        let u1 = normalized(SIMD3<Double>(1 - a.x * a.x, -a.x * a.y, -a.x * a.z))
        var u2 = SIMD3<Double>(a.y * u1.z - a.z * u1.y, a.z * u1.x - a.x * u1.z, a.x * u1.y - a.y * u1.x)
        if u2.z < 0 { u2 = -u2 }
        return Frame(a: a, u1: u1, u2: u2)
    }
    private static func geometry(_ p: Petal, _ e: Double, _ f: Frame) -> Geometry {
        let eo: Double, b0: Double, b1: Double, width: Double
        if p.kind == "o" {
            eo = ease(e / 0.72); b0 = 0.075; b1 = 1.80; width = p.width * (0.72 + 0.28 * eo)
        } else if p.kind == "i" {
            eo = ease((e - 0.12) / 0.78); b0 = 0.05; b1 = 1.12; width = p.width * (0.42 + 0.58 * eo)
        } else {
            eo = ease((e - 0.22) / 0.74); b0 = 0.035; b1 = 0.90; width = p.width * (0.42 + 0.58 * eo)
        }
        let be = lerp(b0, b1, eo), ca = cos(p.angle), sa = sin(p.angle)
        let r = f.u1 * ca + f.u2 * sa, t = f.u1 * -sa + f.u2 * ca
        let d = f.a * cos(be) + r * sin(be), n = f.a * -sin(be) + r * cos(be)
        let base = center + r * (p.radius * (0.4 + 0.6 * eo))
        return Geometry(base: base, tip: base + d * p.length,
                        mid: base + d * (0.5 * p.length) + n * (p.bow * p.length * eo),
                        tangent: t, width: width, kind: p.kind)
    }
    private static func point(_ v: SIMD3<Double>) -> CGPoint { CGPoint(x: v.x, y: v.y) }
    private static func quadratic(_ b: SIMD3<Double>, _ m: SIMD3<Double>, _ t: SIMD3<Double>, _ s: Double) -> SIMD3<Double> {
        b * ((1 - s) * (1 - s)) + m * (2 * (1 - s) * s) + t * (s * s)
    }
    private static func grainPath(_ context: CGContext, _ g: Geometry) {
        let m = g.mid * 2 - (g.base + g.tip) * 0.5
        let dx = g.tip.x - g.base.x, dy = g.tip.y - g.base.y
        let length = sqrt(dx * dx + dy * dy)
        let divisor = length == 0 ? 1 : length
        let qx = -dy / divisor, qy = dx / divisor
        let f = abs(g.tangent.x * qx + g.tangent.y * qy)
        let hw = 0.5 * g.width * max(f, 0.26)
        func edge(_ j: Int, _ sign: Double) -> CGPoint {
            let s = Double(j) / 20
            let c = quadratic(g.base, m, g.tip, s)
            let profile = g.kind == "o" ? pow(sin(.pi * s), 0.55) * (1 - 0.42 * s) : pow(s, 0.6) * pow(1 - s, 0.42) / 0.501
            let h = profile * hw * sign
            return CGPoint(x: c.x + qx * h, y: c.y + qy * h)
        }
        context.beginPath()
        context.move(to: edge(0, 1))
        for j in 1...20 { context.addLine(to: edge(j, 1)) }
        for j in stride(from: 20, through: 0, by: -1) { context.addLine(to: edge(j, -1)) }
        context.closePath()
    }
    private static func centerLine(_ context: CGContext, _ g: Geometry) {
        let m = g.mid * 2 - (g.base + g.tip) * 0.5
        context.beginPath()
        for j in 0...12 {
            let s = 0.08 + (0.78 - 0.08) * Double(j) / 12
            let p = point(quadratic(g.base, m, g.tip, s))
            if j == 0 { context.move(to: p) } else { context.addLine(to: p) }
        }
    }
    private static func grey(_ value: Double) -> Double { floor(255 * min(1, max(0, value)) + 0.5) / 255 }
    private static func fill(_ context: CGContext, _ value: Double) {
        let g = grey(value)
        context.setFillColor(red: g, green: g, blue: g, alpha: 1)
    }
    private static func stroke(_ context: CGContext, _ value: Double, _ width: Double) {
        let g = grey(value)
        context.setStrokeColor(red: g, green: g, blue: g, alpha: 1)
        context.setLineWidth(width)
        context.strokePath()
    }
    private func draw(_ context: CGContext, _ e: Double) throws {
        let f = Self.frame(e), layer = Self.layer, center = Self.center
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setBlendMode(.plusLighter)
        let tb0 = SIMD3<Double>(12, 310, 0), tb1 = SIMD3<Double>(30, 254, 0), tb2 = SIMD3<Double>(54, 228, 0)
        for j in 0..<14 {
            let u0 = Double(j) / 14, u1 = Double(j + 1) / 14
            context.beginPath()
            context.move(to: Self.point(Self.quadratic(tb0, tb1, tb2, u0)))
            context.addLine(to: Self.point(Self.quadratic(tb0, tb1, tb2, u1)))
            Self.stroke(context, layer * 1.6, 3.2 + 5 * pow(u1, 2.2))
        }
        for petal in petals {
            let g = Self.geometry(petal, e, f)
            Self.grainPath(context, g)
            Self.fill(context, g.kind == "o" ? layer * 1.75 : layer)
            context.fillPath()
            if g.kind != "o" {
                Self.centerLine(context, g)
                Self.stroke(context, layer * 0.22, 0.9)
            }
        }
        let tr = 15 * (0.45 + 0.55 * Self.ease(e / 0.8))
        let values = [Self.grey(layer * 2.6), Self.grey(layer * 1.4), 0]
        let components: [CGFloat] = values.flatMap { [CGFloat($0), CGFloat($0), CGFloat($0), 1] }
        guard let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceRGB(), colorComponents: components,
                                        locations: [0, 0.55, 1], count: 3) else { throw FlowerError.gradient }
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - tr, y: center.y - tr, width: 2 * tr, height: 2 * tr))
        context.clip()
        context.drawRadialGradient(gradient, startCenter: Self.point(center), startRadius: 0,
                                   endCenter: Self.point(center), endRadius: tr, options: [])
        context.restoreGState()
        let es = Self.ease((e - 0.42) / 0.5), eg = Self.ease((e - 0.55) / 0.42)
        if es > 0.001 {
            for st in stamens {
                let be = Self.lerp(0.05, st.bend, es), ca = cos(st.angle), sa = sin(st.angle)
                let r = f.u1 * ca + f.u2 * sa, d = f.a * cos(be) + r * sin(be)
                let b = center + r * 2.5
                let tp = b + d * (st.length * (0.55 + 0.45 * es))
                let md = b + d * (st.length * 0.5) + r * 1.8
                context.setAlpha(es)
                context.beginPath()
                context.move(to: Self.point(b))
                context.addQuadCurve(to: Self.point(tp), control: Self.point(md))
                Self.stroke(context, layer * 0.45, 0.55)
                context.saveGState()
                context.translateBy(x: tp.x, y: tp.y)
                context.rotate(by: atan2(tp.y - md.y, tp.x - md.x))
                context.beginPath()
                context.addEllipse(in: CGRect(x: -1.35, y: -0.8, width: 2.7, height: 1.6))
                Self.fill(context, layer * 0.9)
                context.fillPath()
                context.restoreGState()
            }
            context.setAlpha(1)
        }
        if eg > 0.001 {
            let s = center + f.a * (46 * eg)
            context.setAlpha(eg)
            context.beginPath()
            context.move(to: Self.point(center))
            context.addLine(to: Self.point(s))
            Self.stroke(context, layer * 0.5, 1.1)
            for lobe in lobes {
                let ca = cos(lobe.angle), sa = sin(lobe.angle)
                let r = f.u1 * ca + f.u2 * sa
                let d = f.a * cos(1.2) + r * sin(1.2)
                let t = f.u1 * -sa + f.u2 * ca
                Self.grainPath(context, Geometry(base: s, tip: s + d * (lobe.length * eg),
                                                mid: s + d * (lobe.length * eg * 0.5), tangent: t, width: 2.8, kind: "o"))
                Self.fill(context, layer * 0.6)
                context.fillPath()
            }
            context.setAlpha(1)
        }
        context.setBlendMode(.normal)
    }
}
#endif
#endif
