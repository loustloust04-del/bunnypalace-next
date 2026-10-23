#if PERSONAL_APPS
import SwiftUI

/// 版面（plan-death-scale §3，照 design-death-scale.html 的 viewBox 360×600 逐项移植）
enum DeathScaleScene {
    typealias E = DeathScaleEngraver

    static let width = 360.0, height = 600.0
    static let horizon = 214.0, ledge = 262.0, pier = 274.0, floorEnd = 548.0
    static let pivot = CGPoint(x: 180, y: 80)
    static let arm = 116.0
    static let comet = CGPoint(x: 52, y: 40)
    static let panRadius = 60.0, rim = 172.0, depth = 28.0
    static let pictureTop = 30.0
    static let pictureRect = CGRect(x: 9, y: pictureTop, width: width - 18, height: floorEnd - 4)
    static let barY = pictureTop + floorEnd - 4
    /// 画心坐标 → 版面坐标
    static let sceneTransform = CGAffineTransform(translationX: 9, y: pictureTop)
        .scaledBy(x: (width - 18) / width, y: (floorEnd - 4) / floorEnd)
    static let sealCenters: [DeathScale.Side: CGPoint] = [.die: CGPoint(x: 40, y: barY + 9), .live: CGPoint(x: width - 40, y: barY + 9)]
    static let stoneRects: [DeathScale.Side: CGRect] = [.die: CGRect(x: 20, y: floorEnd - 30, width: 128, height: 20),
                                                        .live: CGRect(x: 196, y: floorEnd - 30, width: 128, height: 20)]
    static let hourglassOrigin = CGPoint(x: 46, y: 410)
    static let hourglassHit = CGRect(x: 22, y: 404, width: 50, height: 96)
    static let bookHit = CGRect(x: 64, y: 462, width: 70, height: 42)
    /// 墙上的魔方阵石牌 = 账簿入口（粟粟 10-02：账簿不放主页底部）
    static let registerHit = CGRect(x: 280, y: 344, width: 76, height: 76)

    static let roman = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"]
    static func roman(_ w: Int) -> String { roman.indices.contains(w) ? roman[w] : String(w) }

    struct Static {
        var frame: DeathScaleArt
        var scene: DeathScaleArt
    }

    /// 静态版：框、天、海、墙、道具。只算一次
    static let staticArt: Static = {
        var rng = E.Random(seed: 7)
        var scene = background(&rng)
        scene.append(gallows())
        scene.append(bell(316, 44))
        scene.append(magicSquare(288, 352))
        scene.append(banner(112, 150))
        scene.append(bat(92, 147))
        scene.append(sphere(318, 482, 30, &rng))
        scene.append(polyhedron())
        scene.append(book())
        for side in DeathScale.Side.allCases { scene.append(stone(side)) }
        return Static(frame: frame(), scene: scene)
    }()

    static let beamArt = beam()
    static let forkArt = fork()
    static let shadowArt: DeathScaleArt = {
        var a = DeathScaleArt()
        a.fill(E.hatch(.init(box: (-60, -8, 60, 8), angle: 0, gap: 1.6, step: 2, maxWidth: 1, wobble: 0.2, tone: { x, y in
            let q = pow(x / 56, 2) + pow(y / 6, 2)
            return q < 1 ? 0.55 * (1 - q) + 0.2 : 0
        })))
        return a
    }()
    static let panBackArt = panBack()
    static let panFrontArt: [DeathScale.Side: DeathScaleArt] = [.die: panFront(.die), .live: panFront(.live)]
    static let hourglassArt: [Bool: DeathScaleArt] = [false: hourglass(open: false), true: hourglass(open: true)]

    // MARK: - 调子

    static func inRainbow(_ x: Double, _ y: Double) -> Bool {
        let d = hypot(x - 140, y - 300)
        return (d > 252 && d < 262) || (d > 241 && d < 245)
    }

    static func skyTone(_ x: Double, _ y: Double) -> Double {
        var t = 0.22 + 0.34 * pow(1 - y / horizon, 1.3) + 0.1 * (E.noise(x * 0.03, y * 0.05) - 0.5)
        let dc = hypot(x - comet.x, y - comet.y)
        t -= 0.55 * exp(-dc / 38)
        let wedge = abs(atan2(y - comet.y, x - comet.x) - 0.52)
        if wedge < 0.1, dc < 260 { t -= 0.22 * (1 - wedge / 0.1) * (1 - dc / 260) }
        if inRainbow(x, y) { t *= 0.25 }
        return t
    }

    static func seaTone(_ x: Double, _ y: Double) -> Double {
        let k = (y - horizon) / (ledge - horizon)
        return 0.32 + 0.28 * k + 0.14 * (E.noise(x * 0.08, y * 0.9) - 0.5)
    }

    static func ledgeTone(_ x: Double, _ y: Double) -> Double { y < ledge + 2.2 ? 0.05 : 0.66 + 0.14 * E.noise(x * 0.1, y * 0.3) }

    static func floorTone(_ x: Double, _ y: Double) -> Double {
        let k = (y - ledge) / (floorEnd - ledge)
        var t = 0.26 + 0.36 * k + 0.1 * (E.noise(x * 0.02, y * 0.02) - 0.5)
        t += 0.45 * exp(-(pow((x - 46) / 26, 2) + pow((y - 498) / 6, 2)))
        t += 0.5 * exp(-(pow((x - 316) / 40, 2) + pow((y - 508) / 7, 2)))
        t += 0.4 * exp(-(pow((x - 104) / 30, 2) + pow((y - 500) / 4, 2)))
        if y > 470, y < 494, x > 150, x < 262 - (y - 470) * 0.6 { t += 0.42 }
        return t
    }

    static func pierTone(_ x: Double, _ y: Double) -> Double {
        var t = 0.58 + 0.16 * (E.noise(x * 0.06, y * 0.04) - 0.5) + 0.18 * E.clamp((y - 360) / 200) + 0.1 * E.clamp(1 - (x - pier) / 10)
        t -= 0.25 * exp(-(pow((x - 316) / 44, 2) + pow((y - 130) / 50, 2)))
        return t
    }

    // MARK: - 框 / 底栏

    static func frame() -> DeathScaleArt {
        var a = DeathScaleArt()
        a.outline(Path(CGRect(x: 1, y: 1, width: width - 2, height: height - 2)), 1.6, seed: 1)
        a.outline(Path(CGRect(x: 5, y: 5, width: width - 10, height: height - 10)), 0.5, seed: 2)
        a.label(.init(text: "XIII", face: .smallCaps, size: 15, at: CGPoint(x: width / 2, y: 22), tracking: 5))
        var rules = Path()
        rules.move(to: CGPoint(x: 120, y: 17)); rules.addLine(to: CGPoint(x: 150, y: 17))
        rules.move(to: CGPoint(x: 210, y: 17)); rules.addLine(to: CGPoint(x: 240, y: 17))
        a.outline(rules, 0.5, wobble: 0.4, seed: 3)
        a.fill(E.ellipse(117, 17, 1.3, 1.3))
        a.fill(E.ellipse(243, 17, 1.3, 1.3))
        a.outline(Path(pictureRect), 1, seed: 4)
        let bar = CGRect(x: 9, y: barY, width: width - 18, height: height - barY - 9)
        a.shape(Path(bar), 1, seed: 5)
        var line = Path()
        line.move(to: CGPoint(x: 9, y: barY + 3)); line.addLine(to: CGPoint(x: width - 9, y: barY + 3))
        a.outline(line, 0.4, wobble: 0.4, seed: 6)
        for (side, c) in sealCenters.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let s = side == .die ? 7.0 : 8.0
            a.shape(E.ellipse(c.x, c.y, 13.5, 13.5), 0.9, wobble: 0.5, seed: s)
            a.outline(E.ellipse(c.x, c.y, 11, 11), 0.4, wobble: 0.4, seed: s + 10)
        }
        a.label(.init(text: "LA BALANCE .", face: .smallCaps, size: 17, at: CGPoint(x: width / 2, y: barY + 16), tracking: 6))
        return a
    }

    static func stone(_ side: DeathScale.Side) -> DeathScaleArt {
        var a = DeathScaleArt()
        let r = stoneRects[side]!
        let seed = side == .die ? 40.0 : 41.0
        a.shape(Path(r), 0.9, wobble: 0.6, seed: seed)
        a.outline(Path(r.insetBy(dx: 2.5, dy: 2.5)), 0.35, wobble: 0.5, seed: seed + 5)
        a.label(.init(text: side == .die ? "POUR MOURIR" : "POUR VIVRE", face: .smallCaps, size: 10,
                      at: CGPoint(x: r.midX, y: r.minY + 13.6), tracking: 2.4))
        return a
    }

    // MARK: - 背景

    static func background(_ rng: inout E.Random) -> DeathScaleArt {
        var a = DeathScaleArt()
        let sky: (Double, Double) -> Bool = { x, y in x < pier && y < horizon }
        a.fill(E.hatch(.init(box: (0, 0, pier, horizon), angle: 0, gap: 2.15, maxWidth: 1.05, wobble: 0.25, tone: skyTone, inside: sky)))
        a.fill(E.hatch(.init(box: (0, 0, pier, horizon), angle: 9, gap: 2.6, threshold: 0.42, maxWidth: 0.8, tone: skyTone, inside: sky)))

        func shore(_ x: Double) -> Double {
            horizon - 9 * exp(-pow((x - 44) / 38, 2)) - 5 * exp(-pow((x - 120) / 22, 2)) - 3 * exp(-pow((x - 206) / 18, 2))
        }
        a.fill(E.hatch(.init(box: (0, horizon - 14, pier, horizon + 1), angle: 0, gap: 1.3, step: 2, maxWidth: 1, wobble: 0.1,
                             tone: { x, y in y > shore(x) ? 0.78 : 0 })))
        for (i, (x, h)) in [(30.0, 6.0), (38, 9), (46, 7), (57, 11), (64, 6), (116, 5), (123, 7)].enumerated() {
            let b = shore(x)
            let pts = [CGPoint(x: x - 2, y: b), CGPoint(x: x - 2, y: b - h), CGPoint(x: x, y: b - h - 3), CGPoint(x: x + 2, y: b - h), CGPoint(x: x + 2, y: b)]
            let house = E.wobble(E.polygon(pts, closed: false), amplitude: 0.25, seed: 60 + Double(i))
            a.fill(house, .paper)
            a.stroke(house, 0.45)
        }
        a.fill(E.hatch(.init(box: (0, horizon, pier, ledge), angle: 0, gap: 1.75, step: 2.6, maxWidth: 0.95, wobble: 0.5, tone: seaTone)))

        var rays = Path()
        for i in 0..<64 {
            let ang = Double(i) / 64 * .pi * 2 + (rng.next() - 0.5) * 0.04
            let len = (i % 4 == 0 ? 46.0 : i % 2 == 1 ? 18 : 30) * (0.8 + rng.next() * 0.4)
            let pts = (0...10).map { k in
                let r = 6 + len * Double(k) / 10
                return CGPoint(x: comet.x + cos(ang) * r, y: comet.y + sin(ang) * r)
            }
            rays.addPath(E.strokeAlong(pts) { _, k in 0.9 * (1 - Double(k) / 10) })
        }
        let beamPts = (0...40).map { k in CGPoint(x: comet.x + cos(0.52) * (8 + Double(k) * 6.5), y: comet.y + sin(0.52) * (8 + Double(k) * 6.5)) }
        rays.addPath(E.strokeAlong(beamPts) { _, k in 1.3 * (1 - Double(k) / 40) })
        a.fill(rays)
        a.shape(E.ellipse(comet.x, comet.y, 4.2, 4.2), 0.7, wobble: 0.35, seed: 70)

        for r in [241.0, 245, 252, 262] {
            var pts: [CGPoint] = []
            for t in stride(from: -Double.pi * 0.98, to: -Double.pi * 0.28, by: 0.01) {
                let x = 140 + cos(t) * r, y = 300 + sin(t) * r
                if x < pier, y < horizon { pts.append(CGPoint(x: x, y: y)) }
            }
            a.fill(E.strokeAlong(pts) { _, _ in 0.45 })
        }

        a.fill(Path(CGRect(x: 0, y: ledge, width: pier, height: 14)), .paper)
        a.fill(E.hatch(.init(box: (0, ledge, pier, ledge + 14), angle: 90, gap: 1.9, step: 2, maxWidth: 1, wobble: 0.2, tone: ledgeTone)))
        a.outline(line(0, ledge, pier, ledge), 0.9, seed: 80)
        a.outline(line(0, ledge + 14, pier, ledge + 14), 1.2, seed: 81)

        let fl: (Double, Double) -> Bool = { x, y in y > ledge + 14 && (x < pier || y > 470) }
        a.fill(E.hatch(.init(box: (0, ledge + 14, width, floorEnd), angle: 0, gap: 2.3, maxWidth: 1.1, wobble: 0.45, tone: floorTone, inside: fl)))
        a.fill(E.hatch(.init(box: (0, ledge + 14, width, floorEnd), angle: -14, gap: 2.8, threshold: 0.48, maxWidth: 0.85, tone: floorTone, inside: fl)))

        let pr: (Double, Double) -> Bool = { x, y in x >= pier && y <= 470 }
        a.fill(E.hatch(.init(box: (pier, 0, width, 470), angle: 90, gap: 2, maxWidth: 1.05, wobble: 0.3, tone: pierTone, inside: pr)))
        a.fill(E.hatch(.init(box: (pier, 0, width, 470), angle: 38, gap: 2.5, threshold: 0.38, maxWidth: 0.85, tone: pierTone, inside: pr)))
        a.fill(E.hatch(.init(box: (pier, 0, width, 470), angle: -40, gap: 2.9, threshold: 0.66, maxWidth: 0.7, tone: pierTone, inside: pr)))
        var i = 0
        for y in stride(from: 34.0, to: 470, by: 36) {
            a.outline(line(pier, y, width, y), 1.1, wobble: 0.5, seed: 90 + Double(i), dash: [CGFloat(40 + i * 3), 2])
            let jx = pier + (i % 2 == 1 ? 30 : 58)
            a.outline(line(jx, y, jx, y + 36), 0.9, wobble: 0.5, seed: 120 + Double(i))
            i += 1
        }
        a.outline(line(pier, 0, pier, 470), 1.6, seed: 150)
        a.outline(line(pier, 470, width, 470), 1.4, seed: 151)
        return a
    }

    static func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x1, y: y1))
        return p
    }

    // MARK: - 墙上的东西

    static func magicSquare(_ x: Double, _ y: Double) -> DeathScaleArt {
        var a = DeathScaleArt()
        let numbers = [16, 3, 2, 13, 5, 10, 11, 8, 9, 6, 7, 12, 4, 15, 14, 1]
        let c = 15.0
        a.shape(Path(CGRect(x: x - 4, y: y - 4, width: c * 4 + 8, height: c * 4 + 8)), 1.2, wobble: 0.6, seed: 200)
        a.fill(E.hatch(.init(box: (x - 4, y - 4, x + c * 4 + 4, y + c * 4 + 4), angle: 45, gap: 1.5, step: 1.5, maxWidth: 0.8, wobble: 0, tone: { px, py in
            (px < x || py < y || px > x + c * 4 || py > y + c * 4) ? 0.8 : 0
        })))
        a.outline(Path(CGRect(x: x, y: y, width: c * 4, height: c * 4)), 0.8, wobble: 0.5, seed: 201)
        for (i, n) in numbers.enumerated() {
            let cx = x + Double(i % 4) * c, cy = y + Double(i / 4) * c
            a.outline(Path(CGRect(x: cx, y: cy, width: c, height: c)), 0.45, wobble: 0.4, seed: 210 + Double(i))
            a.label(.init(text: String(n), face: .english, size: 9.5, at: CGPoint(x: cx + c / 2, y: cy + c / 2 + 3.3)))
        }
        return a
    }

    static func bell(_ x: Double, _ y: Double) -> DeathScaleArt {
        var a = DeathScaleArt()
        func hw(_ t: Double) -> Double { 3 + 12 * pow(t, 1.7) }
        a.outline(line(x - 9, y - 4, x + 9, y - 4), 2, wobble: 0.3, seed: 230)
        a.stroke(line(x, y - 4, x, y + 2), 1.4)
        let right = (0...20).map { i -> CGPoint in let t = Double(i) / 20; return CGPoint(x: x + hw(t), y: y + 2 + t * 22) }
        let left = right.map { CGPoint(x: 2 * x - $0.x, y: $0.y) }.reversed()
        var body = E.polygon(Array(left) + right, closed: false)
        body.addQuadCurve(to: CGPoint(x: x - 15, y: y + 24), control: CGPoint(x: x, y: y + 28))
        body.closeSubpath()
        a.shape(body, 0.9, wobble: 0.6, seed: 231)
        var h = Path()
        for u in stride(from: -0.95, through: 0.95, by: 0.14) {
            let pts = (1...20).map { i -> CGPoint in let t = Double(i) / 20; return CGPoint(x: x + u * hw(t), y: y + 2 + t * 22) }
            h.addPath(E.strokeAlong(pts) { _, _ in 0.95 * E.clamp(0.15 + 0.8 * pow((u + 0.4) / 1.4, 1.3)) })
        }
        a.fill(h)
        a.fill(E.ellipse(x, y + 28, 2.6, 2.6))
        return a
    }

    static func bannerCurve(_ x: Double, _ y: Double, dy: Double = 0) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        (CGPoint(x: x, y: y + dy), CGPoint(x: x + 40, y: y - 12 + dy), CGPoint(x: x + 80, y: y + 10 + dy), CGPoint(x: x + 150, y: y - 4 + dy))
    }

    static func banner(_ x: Double, _ y: Double) -> DeathScaleArt {
        var a = DeathScaleArt()
        let top = bannerCurve(x, y, dy: -7)
        var body = Path()
        body.move(to: top.0)
        body.addCurve(to: top.3, control1: top.1, control2: top.2)
        body.addLine(to: CGPoint(x: x + 150, y: y + 4))
        body.addCurve(to: CGPoint(x: x, y: y + 8), control1: CGPoint(x: x + 80, y: y + 18), control2: CGPoint(x: x + 40, y: y - 4))
        body.closeSubpath()
        a.shape(body, 0.8, wobble: 0.5, seed: 240)
        let tail = E.polygon([CGPoint(x: x + 150, y: y - 11), CGPoint(x: x + 168, y: y - 14), CGPoint(x: x + 160, y: y - 6),
                              CGPoint(x: x + 170, y: y + 1), CGPoint(x: x + 150, y: y + 4)])
        a.shape(tail, 0.8, wobble: 0.5, seed: 241)
        a.fill(E.hatch(.init(box: (x + 150, y - 15, x + 171, y + 5), angle: 80, gap: 1.2, step: 1, maxWidth: 0.7, wobble: 0, tone: { _, _ in 0.7 }, inside: { px, py in
            px > x + 151 && py > y - 13 + (px - x - 150) * 0.1 && py < y + 3 - (px - x - 150) * 0.1
        })))

        let curve = bannerCurve(x, y)
        let samples = (0...200).map { i -> CGPoint in
            let t = Double(i) / 200, u = 1 - t
            let k0 = u * u * u, k1 = 3 * u * u * t, k2 = 3 * u * t * t, k3 = t * t * t
            return CGPoint(x: k0 * curve.0.x + k1 * curve.1.x + k2 * curve.2.x + k3 * curve.3.x,
                           y: k0 * curve.0.y + k1 * curve.1.y + k2 * curve.2.y + k3 * curve.3.y)
        }
        var lengths = [0.0]
        for i in 1..<samples.count { lengths.append(lengths[i - 1] + hypot(samples[i].x - samples[i - 1].x, samples[i].y - samples[i - 1].y)) }
        func at(_ d: Double) -> (CGPoint, Double) {
            let i = min(max(lengths.firstIndex { $0 >= d } ?? lengths.count - 1, 1), lengths.count - 1)
            let p0 = samples[i - 1], p1 = samples[i]
            let f = (d - lengths[i - 1]) / max(lengths[i] - lengths[i - 1], 1e-6)
            return (CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f), atan2(p1.y - p0.y, p1.x - p0.x))
        }
        let text = "MORT SANS SÉPULTURE", size = 8.4, spacing = 1.1
        let adv = E.advances(text, face: .smallCaps, size: size)
        let total = adv.reduce(0) { $0 + $1 + spacing }
        var d = lengths.last! / 2 - total / 2
        for (ch, w) in zip(text, adv) {
            let (p, ang) = at(d + w / 2)
            let base = CGPoint(x: p.x - sin(ang) * 3, y: p.y + cos(ang) * 3)
            if ch != " " { a.label(.init(text: String(ch), face: .smallCaps, size: size, at: base, angle: ang)) }
            d += w + spacing
        }
        return a
    }

    static func bat(_ x: Double, _ y: Double) -> DeathScaleArt {
        var a = DeathScaleArt()
        func wing(_ s: Double) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: x, y: y))
            p.addCurve(to: CGPoint(x: x + s * 24, y: y - 6), control1: CGPoint(x: x + s * 6, y: y - 10), control2: CGPoint(x: x + s * 16, y: y - 13))
            p.addCurve(to: CGPoint(x: x + s * 24, y: y + 7), control1: CGPoint(x: x + s * 21, y: y - 1), control2: CGPoint(x: x + s * 22, y: y + 3))
            p.addCurve(to: CGPoint(x: x + s * 15, y: y + 9), control1: CGPoint(x: x + s * 19, y: y + 3), control2: CGPoint(x: x + s * 16, y: y + 6))
            p.addCurve(to: CGPoint(x: x + s * 7, y: y + 10), control1: CGPoint(x: x + s * 11, y: y + 5), control2: CGPoint(x: x + s * 8, y: y + 8))
            p.addCurve(to: CGPoint(x: x, y: y + 5), control1: CGPoint(x: x + s * 5, y: y + 6), control2: CGPoint(x: x + s * 2, y: y + 6))
            p.closeSubpath()
            return p
        }
        a.shape(wing(1), 0.7, wobble: 0.35, seed: 250)
        a.shape(wing(-1), 0.7, wobble: 0.35, seed: 251)
        a.fill(E.hatch(.init(box: (x - 25, y - 14, x + 25, y + 11), angle: 30, gap: 1.2, step: 1.3, maxWidth: 0.75, wobble: 0, tone: { _, _ in 0.75 }, inside: { px, py in
            py < y + 5 + 4 * cos(abs(px - x) / 3.8) && py > y - 12 + abs(px - x) * 0.2
        })))
        a.fill(E.ellipse(x, y + 2, 3, 4.5))
        var ears = E.polygon([CGPoint(x: x - 2.4, y: y - 2), CGPoint(x: x - 2, y: y - 6), CGPoint(x: x - 0.6, y: y - 2.5)])
        ears.addPath(E.polygon([CGPoint(x: x + 0.6, y: y - 2.5), CGPoint(x: x + 2, y: y - 6), CGPoint(x: x + 2.4, y: y - 2)]))
        a.fill(ears)
        return a
    }

    // MARK: - 地上的东西

    static func sphere(_ cx: Double, _ cy: Double, _ r: Double, _ rng: inout E.Random) -> DeathScaleArt {
        var a = DeathScaleArt()
        let outline = E.wobble(E.ellipse(cx, cy, r, r), amplitude: 0.7, seed: 260)
        a.fill(outline, .paper)
        let light = (-0.55, -0.6, 0.58)
        var dots = Path()
        for _ in 0..<5200 {
            let ang = rng.next() * .pi * 2, q = sqrt(rng.next())
            let x = cos(ang) * q, y = sin(ang) * q, z = sqrt(max(0, 1 - x * x - y * y))
            var tone = 1 - E.clamp(x * light.0 + y * light.1 + z * light.2)
            tone = 0.06 + 0.9 * pow(tone, 1.25)
            if q > 0.93 { tone = max(tone, 0.75) }
            if rng.next() < tone {
                let rr = 0.38 + rng.next() * 0.2
                E.dot(CGPoint(x: cx + x * r, y: cy + y * r), r: rr, into: &dots)
            }
        }
        a.fill(dots)
        a.stroke(outline, 0.6)
        return a
    }

    static func polyhedron() -> DeathScaleArt {
        var a = DeathScaleArt()
        let pa = CGPoint(x: 146, y: 396), pb = CGPoint(x: 196, y: 382), pc = CGPoint(x: 222, y: 414), pd = CGPoint(x: 208, y: 474)
        let pe = CGPoint(x: 152, y: 486), pf = CGPoint(x: 126, y: 444), pg = CGPoint(x: 180, y: 428)
        let faces: [([CGPoint], Double, Double, Double)] = [
            ([pa, pb, pc, pg], 18, 2.1, 0.14),
            ([pf, pa, pg, pe], 72, 1.7, 0.46),
            ([pg, pc, pd, pe], -62, 1.5, 0.8),
        ]
        for (i, (poly, ang, gap, tone)) in faces.enumerated() {
            let xs = poly.map(\.x), ys = poly.map(\.y)
            let box: (Double, Double, Double, Double) = (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
            let minY = box.1
            a.shape(E.polygon(poly), 1, wobble: 0.7, seed: 270 + Double(i))
            a.fill(E.hatch(.init(box: box, angle: ang, gap: gap, step: 1.6, maxWidth: 1, wobble: 0.1, tone: { x, y in
                E.inPolygon(x, y, poly) ? tone + 0.12 * (E.noise(x * 0.2, y * 0.2) - 0.5) + 0.1 * ((y - minY) / 90) : 0
            })))
            if tone > 0.7 {
                a.fill(E.hatch(.init(box: box, angle: 20, gap: 2.2, step: 1.6, maxWidth: 0.7, wobble: 0.1, tone: { x, y in
                    E.inPolygon(x, y, poly) ? 0.7 : 0
                })))
            }
        }
        a.outline(E.polygon([pa, pb, pc, pd, pe, pf]), 1.3, wobble: 0.8, seed: 280)
        var edges = Path()
        for p in [pa, pc, pe] { edges.move(to: pg); edges.addLine(to: p) }
        a.outline(edges, 0.9, wobble: 0.6, seed: 281)
        return a
    }

    static func book() -> DeathScaleArt {
        var a = DeathScaleArt()
        let pa = CGPoint(x: 72, y: 478), pb = CGPoint(x: 114, y: 469), pc = CGPoint(x: 128, y: 482), pd = CGPoint(x: 86, y: 492)
        let th = 6.0
        func dn(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y + th) }
        let cover = [pa, pb, pc, pd], edge = [pd, pc, dn(pc), dn(pd)], side = [pa, pd, dn(pd), dn(pa)]
        a.shape(E.polygon(edge), 0.8, wobble: 0.35, seed: 290)
        var leaves = Path()
        for k in stride(from: 1.0, to: th, by: 1.1) {
            leaves.move(to: CGPoint(x: pd.x + 1, y: pd.y + k))
            leaves.addLine(to: CGPoint(x: pc.x - 1, y: pc.y + k))
        }
        a.stroke(leaves, 0.35)
        a.fill(E.wobble(E.polygon(side), amplitude: 0.35, seed: 291))
        a.shape(E.polygon(cover), 1, wobble: 0.45, seed: 292)
        let xs = cover.map(\.x), ys = cover.map(\.y)
        a.fill(E.hatch(.init(box: (xs.min()!, ys.min()!, xs.max()!, ys.max()!), angle: -12, gap: 1.25, step: 1.4, maxWidth: 0.85, wobble: 0.05, tone: { x, y in
            E.inPolygon(x, y, cover) ? 0.55 + 0.2 * ((x - 72) / 56) : 0
        })))
        let inset = E.wobble(E.polygon([CGPoint(x: 78, y: 479), CGPoint(x: 112, y: 472.5), CGPoint(x: 122, y: 482), CGPoint(x: 88, y: 489)]), amplitude: 0.3, seed: 293)
        a.stroke(inset, 0.9, .paper)
        a.stroke(inset, 0.35)
        let oval = E.ellipse(100, 481, 5, 2.6).applying(CGAffineTransform(translationX: 100, y: 481).rotated(by: -12 * .pi / 180).translatedBy(x: -100, y: -481))
        a.shape(oval, 0.6, wobble: 0.2, seed: 294)
        a.fill(E.polygon([CGPoint(x: 127, y: 483), CGPoint(x: 132, y: 484.4), CGPoint(x: 132, y: 488.8), CGPoint(x: 127, y: 487.6)]))
        var mark = Path()
        mark.move(to: CGPoint(x: 96, y: 493.5))
        mark.addCurve(to: CGPoint(x: 98, y: 503.5), control1: CGPoint(x: 97, y: 497.5), control2: CGPoint(x: 95, y: 500.5))
        a.stroke(mark, 1.6)
        return a
    }

    static let hourglassBulb: Path = {
        let x = hourglassOrigin.x, y = hourglassOrigin.y, h = 82.0
        var p = Path()
        p.move(to: CGPoint(x: x - 11, y: y + 9))
        p.addCurve(to: CGPoint(x: x - 1.4, y: y + h / 2), control1: CGPoint(x: x - 11, y: y + 30), control2: CGPoint(x: x - 1.4, y: y + 34))
        p.addCurve(to: CGPoint(x: x - 11, y: y + h - 9), control1: CGPoint(x: x - 1.4, y: y + h - 34), control2: CGPoint(x: x - 11, y: y + h - 30))
        p.addLine(to: CGPoint(x: x + 11, y: y + h - 9))
        p.addCurve(to: CGPoint(x: x + 1.4, y: y + h / 2), control1: CGPoint(x: x + 11, y: y + h - 30), control2: CGPoint(x: x + 1.4, y: y + h - 34))
        p.addCurve(to: CGPoint(x: x + 11, y: y + 9), control1: CGPoint(x: x + 1.4, y: y + 34), control2: CGPoint(x: x + 11, y: y + 30))
        p.closeSubpath()
        return p
    }()

    static let hourglassStream: Path = line(hourglassOrigin.x, hourglassOrigin.y + 41 - 2, hourglassOrigin.x, hourglassOrigin.y + 82 - 22)

    static func hourglass(open: Bool) -> DeathScaleArt {
        var a = DeathScaleArt()
        let x = hourglassOrigin.x, y = hourglassOrigin.y, w = 30.0, h = 82.0
        let bulb = hourglassBulb
        a.shape(bulb, 0.8, wobble: 0.4, seed: 300)
        let lower: (Double, Double) -> Double = { px, py in py > y + h - 22 + (open ? -3 : 0) - 4 * exp(-pow((px - x) / 5, 2)) ? 0.62 : 0 }
        let upper: (Double, Double) -> Double = { _, py in py > y + 18 + (open ? 6 : 0) && py < y + h / 2 - 4 ? 0.55 : 0 }
        a.fill(E.hatch(.init(box: (x - 12, y, x + 12, y + h), angle: 70, gap: 1.3, step: 1.2, maxWidth: 0.8, wobble: 0,
                             tone: { max(lower($0, $1), upper($0, $1)) }, inside: { bulb.contains(CGPoint(x: $0, y: $1)) })))
        a.fill(E.strokeAlong([CGPoint(x: x - 6, y: y + 14), CGPoint(x: x - 7.5, y: y + 24), CGPoint(x: x - 4, y: y + 32)]) { _, _ in 0.6 })
        for (i, px) in [x - w / 2, x + w / 2].enumerated() {
            a.outline(line(px, y + 7, px, y + h - 7), 1.6, wobble: 0.3, seed: 310 + Double(i))
            for k in 0..<4 { a.shape(E.ellipse(px, y + 12 + Double(k) * 19, 2.4, 1.6), 0.6, wobble: 0.15, seed: 320 + Double(k)) }
            a.fill(E.polygon([CGPoint(x: px - 2, y: y + 7), CGPoint(x: px, y: y - 2), CGPoint(x: px + 2, y: y + 7)]))
        }
        for (i, py) in [y, y + h - 7].enumerated() {
            a.shape(Path(CGRect(x: x - w / 2 - 4, y: py, width: w + 8, height: 7)), 0.9, wobble: 0.4, seed: 330 + Double(i))
            a.fill(E.hatch(.init(box: (x - w / 2 - 4, py, x + w / 2 + 4, py + 7), angle: 90, gap: 1.6, step: 1.4, maxWidth: 0.9, wobble: 0,
                                 tone: { px, _ in 0.3 + 0.6 * ((px - x + w / 2) / w) })))
        }
        return a
    }

    // MARK: - 天平

    static func gallows() -> DeathScaleArt {
        var a = DeathScaleArt()
        let bar = E.wobble(line(pier, 18, 164, 18), amplitude: 0.5, seed: 400)
        a.stroke(bar, 5.2)
        a.stroke(bar, 3.2, .paper)
        a.fill(E.hatch(.init(box: (164, 15.4, pier, 20.6), angle: 0, gap: 1.05, step: 1.5, maxWidth: 0.7, wobble: 0, tone: { _, y in 0.2 + 0.8 * ((y - 15.4) / 5.2) })))
        let brace = E.wobble(line(pier, 58, 236, 19), amplitude: 0.5, seed: 401)
        a.stroke(brace, 3.4)
        a.stroke(brace, 1.6, .paper)
        a.shape(E.ellipse(164, 18, 3, 3), 1, wobble: 0.2, seed: 402)
        a.stroke(line(180, 21, 180, 30), 1.8)
        a.outline(E.ellipse(180, 34, 3.2, 4.2), 1.4, wobble: 0.25, seed: 403)
        return a
    }

    static func fork() -> DeathScaleArt {
        var a = DeathScaleArt()
        let x = pivot.x, y = pivot.y
        a.stroke(line(x - 7, 42, x + 7, 42), 2.4)
        a.stroke(line(x, 38, x, 42), 2)
        for (i, s) in [-6.0, 6].enumerated() {
            a.outline(line(x + s, 42, x + s, y + 6), 2.6, wobble: 0.3, seed: 410 + Double(i))
            a.stroke(line(x + s - 0.5, 44, x + s - 0.5, y + 4), 0.7, .paper)
        }
        a.shape(E.ellipse(x, y, 2.4, 2.4), 1, wobble: 0.15, seed: 412)
        a.fill(E.ellipse(x, y, 0.8, 0.8))
        return a
    }

    static func beam() -> DeathScaleArt {
        var a = DeathScaleArt()
        let x = pivot.x, y = pivot.y
        func th(_ u: Double) -> Double { 1.7 + 3.3 * pow(1 - abs(u), 1.5) }
        let top = (0...40).map { i -> CGPoint in let u = -1 + Double(i) / 20; return CGPoint(x: x + u * arm, y: y - th(u)) }
        let bottom = (0...40).map { i -> CGPoint in let u = -1 + Double(i) / 20; return CGPoint(x: x + u * arm, y: y + th(u) * 1.2) }
        a.shape(E.polygon(top + bottom.reversed()), 0.9, wobble: 0.45, seed: 420)
        var h = Path()
        for v in stride(from: -0.8, through: 0.95, by: 0.3) {
            let pts = (0...60).map { i -> CGPoint in let u = -1 + Double(i) / 30; return CGPoint(x: x + u * arm, y: y + v * th(u) * (v > 0 ? 1.2 : 1)) }
            h.addPath(E.strokeAlong(pts) { _, _ in 0.4 + 0.55 * E.clamp((v + 0.6) / 1.5) })
        }
        a.fill(h)
        a.fill(E.polygon([CGPoint(x: x - 2.4, y: y - 4), CGPoint(x: x, y: y - 36), CGPoint(x: x + 2.4, y: y - 4)]))
        for s in [-1.0, 1] {
            let ex = x + s * arm
            a.shape(E.ellipse(ex, y, 3.4, 3.4), 1, wobble: 0.2, seed: 421 + s)
            a.fill(E.ellipse(ex + s * 4.6, y, 1.8, 1.8))
            a.stroke(line(ex, y + 3, ex, y + 8), 1.4)
        }
        a.shape(E.ellipse(x, y, 7, 7), 1, wobble: 0.3, seed: 425)
        a.fill(E.hatch(.init(box: (x - 7, y - 7, x + 7, y + 7), angle: 45, gap: 1.1, step: 1, maxWidth: 0.7, wobble: 0, tone: { px, py in
            hypot(px - x, py - y) < 6.5 ? 0.25 + 0.7 * E.clamp((px - x + py - y) / 12 + 0.5) : 0
        })))
        return a
    }

    static func chain(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> DeathScaleArt {
        var a = DeathScaleArt()
        let n = Int((hypot(x2 - x1, y2 - y1) / 4.2).rounded())
        let ang = atan2(y2 - y1, x2 - x1)
        var bars = Path()
        for i in 0..<n {
            let t = (Double(i) + 0.5) / Double(n), x = x1 + (x2 - x1) * t, y = y1 + (y2 - y1) * t
            if i % 2 == 1 {
                let ring = E.ellipse(0, 0, 2.6, 1.2).applying(CGAffineTransform(translationX: x, y: y).rotated(by: ang))
                a.stroke(ring, 0.75)
            } else {
                let dx = (x2 - x1) / Double(n) * 0.55, dy = (y2 - y1) / Double(n) * 0.55
                bars.move(to: CGPoint(x: x - dx, y: y - dy))
                bars.addLine(to: CGPoint(x: x + dx, y: y + dy))
            }
        }
        a.stroke(bars, 1.1)
        return a
    }

    static func panBack() -> DeathScaleArt {
        var a = chain(0, 8, -panRadius + 5, rim)
        a.append(chain(0, 8, panRadius - 5, rim))
        a.append(chain(0, 8, 0, rim - 5))
        a.shape(E.ellipse(0, 8, 2.6, 2.6), 1, wobble: 0.15, seed: 430)
        a.shape(E.ellipse(0, rim, panRadius, 7), 0.9, wobble: 0.5, seed: 431)
        a.fill(E.hatch(.init(box: (-panRadius, rim - 7, panRadius, rim + 7), angle: -8, gap: 1.35, step: 1.6, maxWidth: 0.8, wobble: 0, tone: { x, y in
            (pow(x / panRadius, 2) + pow((y - rim) / 7, 2) < 0.82) ? 0.35 + 0.4 * E.clamp((-x / panRadius + 1) / 2) : 0
        })))
        return a
    }

    static func panFront(_ side: DeathScale.Side) -> DeathScaleArt {
        var a = DeathScaleArt()
        let pr = panRadius
        var bowl = Path()
        bowl.move(to: CGPoint(x: -pr, y: rim))
        bowl.addCurve(to: CGPoint(x: 0, y: rim + depth), control1: CGPoint(x: -pr + 2, y: rim + 15), control2: CGPoint(x: -28, y: rim + depth))
        bowl.addCurve(to: CGPoint(x: pr, y: rim), control1: CGPoint(x: 28, y: rim + depth), control2: CGPoint(x: pr - 2, y: rim + 15))
        for p in E.lowerHalfEllipse(0, rim, pr, 7).dropFirst() { bowl.addLine(to: p) }
        bowl.closeSubpath()
        a.shape(bowl, 1, wobble: 0.6, seed: side == .die ? 440 : 441)
        var h = Path()
        for k in stride(from: 0.08, to: 1, by: 0.075) {
            let yk = rim + 4 + (depth - 4) * k, hw = pr * sqrt(1 - k * k) * 0.98
            let pts = (0...36).map { i -> CGPoint in let u = -1 + Double(i) / 18; return CGPoint(x: u * hw, y: yk + 3.4 * (1 - k) * (1 - u * u) * 0.9) }
            h.addPath(E.strokeAlong(pts) { p, _ in
                1.05 * E.clamp(0.12 + 0.55 * pow((p.x / pr + 1) / 2, 1.3) + 0.45 * k - (abs(p.x / pr + 0.42) < 0.1 ? 0.5 : 0))
            })
        }
        if side == .die {
            for k in stride(from: 0.2, to: 1, by: 0.14) {
                let pts = (0...24).map { i -> CGPoint in
                    let u = -1 + Double(i) / 12
                    return CGPoint(x: u * pr * 0.9, y: rim + 3 + (depth - 3) * (k * 0.4 + 0.6 * (u + 1) / 2) * k)
                }
                h.addPath(E.strokeAlong(pts) { p, _ in 0.6 * E.clamp(p.x / pr + 0.2) })
            }
        }
        a.fill(h)
        a.outline(E.polygon(E.lowerHalfEllipse(0, rim, pr, 7, fromRight: false), closed: false), 2.1, wobble: 0.5, seed: 442)
        a.stroke(E.polygon(E.lowerHalfEllipse(0, rim + 1.4, pr - 3, 5.6, fromRight: false), closed: false), 0.6, .paper)
        a.stroke(line(-6, rim + depth - 0.4, 6, rim + depth - 0.4), 2)
        a.fill(E.ellipse(0, rim + depth + 2.6, 2, 2))
        return a
    }

    // MARK: - 砝码

    /// 铃形砝码：铅（想死那边，多一层横排线）/ 黄铜（活着那边）
    static func weight(_ s: Double, side: DeathScale.Side, seed: Double = 0) -> DeathScaleArt {
        var a = DeathScaleArt()
        func hw(_ t: Double) -> Double { s * (0.46 - 0.15 * pow(t, 1.6) - 0.31 * pow(t, 6)) }
        let tall = s * 0.78
        let right = (0...18).map { i -> CGPoint in let t = Double(i) / 18; return CGPoint(x: hw(t), y: -s * 0.07 - t * tall) }
        let left = right.reversed().map { CGPoint(x: -$0.x, y: $0.y) }
        let jitter = min(0.8, s * 0.028)
        a.shape(E.polygon(right + left), max(0.5, s / 40), wobble: jitter, frequency: 0.07 * 26 / max(s, 26), seed: seed)
        let lines = Int((7 + s / 5).rounded()), mw = max(0.35, s / 38)
        let dark = side == .die ? 0.22 : 0
        var h = Path()
        for j in 0...lines {
            let u = -1 + 2 * Double(j) / Double(lines)
            let pts = (1..<18).map { i -> CGPoint in let t = Double(i) / 18; return CGPoint(x: u * hw(t) * 0.97, y: -s * 0.07 - t * tall) }
            h.addPath(E.strokeAlong(pts) { _, i in
                let t = Double(i + 1) / 18
                var tone = 0.08 + 0.7 * pow(E.clamp((u + 0.45) / 1.45), 1.3) + dark + 0.12 * t
                if abs(u + 0.5) < 0.16 { tone -= 0.5 }
                return mw * E.clamp(tone)
            })
        }
        if side == .die {
            for k in 1..<7 {
                let t = Double(k) / 7
                let pts = (0...14).map { i -> CGPoint in
                    let u = -1 + Double(i) / 7
                    return CGPoint(x: u * hw(t) * 0.97, y: -s * 0.07 - t * tall + s * 0.02 * (1 - u * u))
                }
                h.addPath(E.strokeAlong(pts) { p, _ in mw * 0.75 * E.clamp((p.x / s + 0.1) * 2.4) })
            }
        }
        a.fill(h)
        a.fill(E.wobble(Path(CGRect(x: -s * 0.5, y: -s * 0.08, width: s, height: s * 0.08)), amplitude: jitter * 0.6, seed: seed + 1))
        let waistY = -s * 0.07 - 0.12 * tall
        var waist = Path()
        waist.move(to: CGPoint(x: -hw(0.12), y: waistY))
        waist.addQuadCurve(to: CGPoint(x: hw(0.12), y: waistY), control: CGPoint(x: 0, y: waistY + s * 0.05))
        a.stroke(waist, max(0.4, s / 50))
        a.shape(E.ellipse(0, -s * 0.07 - tall - s * 0.07, s * 0.07, s * 0.07), max(0.5, s / 45), wobble: jitter * 0.4, seed: seed + 2)
        a.outline(E.ellipse(0, -s * 0.07 - tall - s * 0.23, s * 0.12, s * 0.085), max(0.6, s / 30), wobble: jitter * 0.5, seed: seed + 3)
        return a
    }

    static func cartouche(_ s: Double, weight: Int, seed: Double = 0) -> DeathScaleArt {
        var a = DeathScaleArt()
        guard s >= 15 else { return a }
        let cy = -s * 0.36
        a.shape(E.ellipse(0, cy, s * 0.2, s * 0.14), max(0.35, s / 70), wobble: min(0.5, s * 0.012), seed: seed + 4)
        a.label(.init(text: roman(weight), face: .smallCaps, size: s * 0.18, at: CGPoint(x: 0, y: cy + s * 0.065)))
        return a
    }

    static func seed(_ id: UUID) -> Double {
        let b = id.uuid
        return Double(Int(b.0) << 8 | Int(b.1)) / 7.0
    }
}

private extension DeathScaleArt {
    mutating func shape(_ path: Path, _ width: Double, wobble amplitude: Double, frequency: Double, seed: Double) {
        let w = DeathScaleEngraver.wobble(path, amplitude: amplitude, frequency: frequency, seed: seed)
        fill(w, .paper)
        stroke(w, width)
    }
}
#endif
