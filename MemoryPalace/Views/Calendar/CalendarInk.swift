import SwiftUI

// MARK: - 日历画笔工具箱（plan-calendar §2.3）
// 铅笔（p4）/ 闪星（p6）/ 点阵小花（p5 像素 · p7 点阵 · p8 刺绣）的纯绘制函数，全部在 Canvas 里用。
// 抖动一律走种子随机：同一楼层同一天每次画得一样。

enum CalendarInk {

    // MARK: 种子随机

    /// SplitMix64：可复现、够快。
    struct Rand {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

        mutating func next() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return CGFloat(z >> 11) / CGFloat(1 << 53)
        }

        /// [-amp/2, amp/2)
        mutating func jitter(_ amp: CGFloat) -> CGFloat { (next() - 0.5) * amp }
    }

    /// FNV-1a，把楼层 id / 日期之类拼成种子。
    static func seed(_ parts: String...) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for part in parts {
            for byte in part.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            h = (h ^ 0x1F) &* 0x0000_0100_0000_01B3
        }
        return h
    }

    // MARK: 字

    /// 手写数字 / 月份：系统自带 Bradley Hand（iOS 与 macOS 都有，PostScript 名 BradleyHandITCTT-Bold）
    static func hand(_ size: CGFloat) -> Font { .custom("BradleyHandITCTT-Bold", size: size) }

    // MARK: 颜色

    /// 和整页纸色一致（心框涂鸦的内底要和纸同色）
    static let paper = CalInk.paper
    static let graphite = Color(red: 0.31, green: 0.306, blue: 0.294)
    static let lineGray = Color(red: 0.365, green: 0.361, blue: 0.349)
    static let chalk = Color(red: 0.953, green: 0.945, blue: 0.925)
    /// 涂格子的五档：0 不涂 · 1 小点（不涂）· 2 浅灰 · 3 深灰 · 4 涂黑
    static func rubFill(level: Int) -> Color? {
        switch level {
        case 2: Color(red: 0.769, green: 0.761, blue: 0.741)
        case 3: Color(red: 0.49, green: 0.482, blue: 0.467)
        case 4: Color(red: 0.184, green: 0.18, blue: 0.173)
        default: nil
        }
    }

    // MARK: 铅笔线 / 涂块

    /// 手画直线：分段抖动，两端各出一点头。
    static func pencilLine(from a: CGPoint, to b: CGPoint, amp: CGFloat = 1.3, segments: Int = 6,
                           overshoot: CGFloat = 3, rng: inout Rand) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let start = CGPoint(x: a.x - ux * overshoot * rng.next(), y: a.y - uy * overshoot * rng.next())
        let end = CGPoint(x: b.x + ux * overshoot * rng.next(), y: b.y + uy * overshoot * rng.next())
        var p = Path()
        p.move(to: CGPoint(x: start.x + rng.jitter(amp), y: start.y + rng.jitter(amp)))
        for i in 1...segments {
            let t = CGFloat(i) / CGFloat(segments)
            p.addLine(to: CGPoint(x: start.x + (end.x - start.x) * t + rng.jitter(amp),
                                  y: start.y + (end.y - start.y) * t + rng.jitter(amp)))
        }
        return p
    }

    /// 涂出来的方块：八个点轻微抖动后直线连（铅笔涂块边缘不圆）。
    static func rubPath(in r: CGRect, amp: CGFloat = 2.6, rng: inout Rand) -> Path {
        let pts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ].map { CGPoint(x: $0.x + rng.jitter(amp), y: $0.y + rng.jitter(amp)) }
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }

    /// 平滑闭合曲线（Catmull-Rom），点先抖一下。
    static func blob(_ points: [CGPoint], amp: CGFloat, rng: inout Rand) -> Path {
        let P = points.map { CGPoint(x: $0.x + rng.jitter(amp), y: $0.y + rng.jitter(amp)) }
        let n = P.count
        var path = Path()
        guard n > 2 else { return path }
        path.move(to: P[0])
        for i in 0..<n {
            let p0 = P[(i - 1 + n) % n], p1 = P[i], p2 = P[(i + 1) % n], p3 = P[(i + 2) % n]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    // MARK: 铅笔颗粒

    /// 颗粒贴图：程序生成一次缓存。用 `.destinationIn` 叠在铅笔元素上，透出纸色。
    static let grainTile: Image = {
        let side = 128
        var rng = Rand(seed: 0x6A09_E667)
        // 黑色 + 每像素不同透明度（预乘 RGBA）；只用它的 alpha
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            let v = rng.next()
            // 大多数像素 0.62–1 之间，少量掉到 0.25：铅笔在纸纹上跳过的点
            let a = v < 0.12 ? 0.25 + v * 2 : 0.62 + v * 0.38
            bytes[i * 4 + 3] = UInt8(min(255, max(0, a * 255)))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return Image(systemName: "square.fill") }
        return Image(decorative: cg, scale: 2)
    }()

    /// 在 layer 里画完铅笔元素后调用：按颗粒贴图挖掉一点，像铅笔。
    static func applyGrain(_ ctx: inout GraphicsContext, in rect: CGRect) {
        ctx.blendMode = .destinationIn
        let tile = ctx.resolve(grainTile)
        let w = tile.size.width, h = tile.size.height
        guard w > 0, h > 0 else { return }
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                ctx.draw(tile, in: CGRect(x: x, y: y, width: w, height: h))
                x += w
            }
            y += h
        }
        ctx.blendMode = .normal
    }

    // MARK: 涂鸦（p4）

    enum Doodle: String, CaseIterable, Sendable {
        case star, heartBox, spiral, flower, bow, wishbone, cat, splat
    }

    /// center = 涂鸦中心，h = 半高；dark = 画在涂深的格子里（涂鸦变白）。
    static func draw(_ doodle: Doodle, in ctx: inout GraphicsContext, center c: CGPoint, h: CGFloat,
                     dark: Bool, rng: inout Rand) {
        let ink = dark ? chalk : graphite
        switch doodle {
        case .star:
            var p = Path()
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let r = i % 2 == 0 ? h * 1.05 : h * 0.45
                let pt = CGPoint(x: c.x + cos(a) * r + rng.jitter(h * 0.08), y: c.y + sin(a) * r + rng.jitter(h * 0.08))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            ctx.fill(p, with: .color(ink))
        case .heartBox:
            let outer = rubPath(in: CGRect(x: c.x - h * 1.05, y: c.y - h * 0.8, width: h * 2.1, height: h * 1.6), amp: 2, rng: &rng)
            let inner = rubPath(in: CGRect(x: c.x - h * 0.62, y: c.y - h * 0.42, width: h * 1.24, height: h * 0.86), amp: 1.5, rng: &rng)
            ctx.fill(outer, with: .color(rubFill(level: 4)!))
            ctx.fill(inner, with: .color(paper))
            ctx.fill(heart(center: CGPoint(x: c.x, y: c.y), size: h * 0.5), with: .color(rubFill(level: 4)!))
        case .spiral:
            var p = Path()
            p.move(to: CGPoint(x: c.x + h * 0.05, y: c.y))
            var t: CGFloat = 0
            while t < 11 {
                let r = h * 0.085 * t
                p.addLine(to: CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r))
                t += 0.25
            }
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: dark ? 2.4 : 1.6, lineCap: .round))
        case .flower:
            var stem = Path()
            stem.addPath(pencilLine(from: CGPoint(x: c.x, y: c.y + h * 1.1), to: CGPoint(x: c.x - h * 0.1, y: c.y - h * 0.1),
                                    amp: 1, segments: 4, overshoot: 0, rng: &rng))
            ctx.stroke(stem, with: .color(ink), lineWidth: 1.3)
            var leaf = Path()
            leaf.move(to: CGPoint(x: c.x - h * 0.05, y: c.y + h * 0.55))
            leaf.addQuadCurve(to: CGPoint(x: c.x - h * 0.55, y: c.y + h * 0.15), control: CGPoint(x: c.x - h * 0.5, y: c.y + h * 0.5))
            leaf.addQuadCurve(to: CGPoint(x: c.x - h * 0.05, y: c.y + h * 0.55), control: CGPoint(x: c.x - h * 0.1, y: c.y + h * 0.2))
            ctx.fill(leaf, with: .color(ink))
            let head = CGPoint(x: c.x - h * 0.1, y: c.y - h * 0.45)
            for i in 0..<5 {
                let a = CGFloat(i) / 5 * 2 * .pi - .pi / 2
                let pc = CGPoint(x: head.x + cos(a) * h * 0.3, y: head.y + sin(a) * h * 0.3)
                let petal = Path(ellipseIn: CGRect(x: -h * 0.22, y: -h * 0.14, width: h * 0.44, height: h * 0.28))
                    .applying(CGAffineTransform(rotationAngle: a).concatenating(CGAffineTransform(translationX: pc.x, y: pc.y)))
                ctx.fill(petal, with: .color(ink))
            }
        case .bow:
            let left = blob([c, CGPoint(x: c.x - h, y: c.y - h * 0.55), CGPoint(x: c.x - h * 1.05, y: c.y + h * 0.4)], amp: h * 0.12, rng: &rng)
            let right = blob([c, CGPoint(x: c.x + h, y: c.y - h * 0.5), CGPoint(x: c.x + h, y: c.y + h * 0.45)], amp: h * 0.12, rng: &rng)
            ctx.stroke(left, with: .color(ink), lineWidth: 1.6)
            ctx.stroke(right, with: .color(ink), lineWidth: 1.6)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - h * 0.14, y: c.y - h * 0.14, width: h * 0.28, height: h * 0.28)), with: .color(ink))
            ctx.stroke(pencilLine(from: CGPoint(x: c.x - h * 0.08, y: c.y + h * 0.05), to: CGPoint(x: c.x - h * 0.4, y: c.y + h * 1.05),
                                  amp: 1, segments: 3, overshoot: 0, rng: &rng), with: .color(ink), lineWidth: 1.5)
            ctx.stroke(pencilLine(from: CGPoint(x: c.x + h * 0.08, y: c.y + h * 0.05), to: CGPoint(x: c.x + h * 0.45, y: c.y + h),
                                  amp: 1, segments: 3, overshoot: 0, rng: &rng), with: .color(ink), lineWidth: 1.5)
        case .wishbone:
            var p = pencilLine(from: CGPoint(x: c.x, y: c.y + h), to: CGPoint(x: c.x, y: c.y + h * 0.1), amp: 1, segments: 3, overshoot: 0, rng: &rng)
            p.addLine(to: CGPoint(x: c.x - h * 0.7, y: c.y - h * 0.75))
            p.move(to: CGPoint(x: c.x, y: c.y + h * 0.1))
            p.addLine(to: CGPoint(x: c.x + h * 0.65, y: c.y - h * 0.8))
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: dark ? 3 : 2.1, lineCap: .round, lineJoin: .round))
        case .cat:
            let body = blob([
                CGPoint(x: c.x - h * 0.4, y: c.y + h * 0.9), CGPoint(x: c.x - h * 0.45, y: c.y - h * 0.1),
                CGPoint(x: c.x - h * 0.42, y: c.y - h * 0.75), CGPoint(x: c.x - h * 0.15, y: c.y - h * 0.4),
                CGPoint(x: c.x + h * 0.15, y: c.y - h * 0.4), CGPoint(x: c.x + h * 0.42, y: c.y - h * 0.75),
                CGPoint(x: c.x + h * 0.45, y: c.y - h * 0.1), CGPoint(x: c.x + h * 0.4, y: c.y + h * 0.9),
            ], amp: h * 0.08, rng: &rng)
            ctx.fill(body, with: .color(dark ? chalk.opacity(0.8) : Color(red: 0.545, green: 0.537, blue: 0.525)))
        case .splat:
            var pts: [CGPoint] = []
            for i in 0..<14 {
                let a = CGFloat(i) / 14 * 2 * .pi
                let r = i % 2 == 1 ? h * 0.45 : h * (0.85 + rng.next() * 0.35)
                pts.append(CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
            }
            ctx.fill(blob(pts, amp: h * 0.15, rng: &rng), with: .color(ink))
        }
    }

    static func heart(center c: CGPoint, size s: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y + s * 0.5))
        p.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.2), control1: CGPoint(x: c.x - s * 0.9, y: c.y - s * 0.05),
                   control2: CGPoint(x: c.x - s * 0.4, y: c.y - s * 0.7))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + s * 0.5), control1: CGPoint(x: c.x + s * 0.4, y: c.y - s * 0.7),
                   control2: CGPoint(x: c.x + s * 0.9, y: c.y - s * 0.05))
        p.closeSubpath()
        return p
    }

    // MARK: 闪星（p6）

    /// 米字闪星：四长四短，stroke 画。
    static func sparkle(center c: CGPoint, radius r: CGFloat) -> Path {
        let q = r * 0.45
        var p = Path()
        p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        p.move(to: CGPoint(x: c.x - q, y: c.y - q)); p.addLine(to: CGPoint(x: c.x + q, y: c.y + q))
        p.move(to: CGPoint(x: c.x - q, y: c.y + q)); p.addLine(to: CGPoint(x: c.x + q, y: c.y - q))
        return p
    }

    // MARK: 点阵小花（p5 / p7 / p8）

    /// `#` 花头 · `g` 茎叶 · `o` 花心
    struct DotPattern: Sendable {
        let name: String
        let rows: [String]
        var width: Int { rows.first?.count ?? 0 }
        var height: Int { rows.count }
    }

    enum DotMode: Sendable { case dot, pixel, stitch }

    static let patterns: [String: DotPattern] = {
        let list: [(String, [String])] = [
            ("tulip", ["..#.#.#..", "..#####..", "..#####..", "...###...", "....g....", "g...g...g", ".g..g..g.", "..g.g.g..", "...ggg...", "....g...."]),
            ("star8", ["....#....", "#...#...#", ".#.###.#.", "..##o##..", "####o####", "..##o##..", ".#.###.#.", "#...#...#", "....#...."]),
            ("sprig", ["...###...", "..##o##..", "...###...", "....g....", ".gg.g.gg.", "...gg....", "....g.g..", "....gg...", "....g...."]),
            ("quatre", ["...##.##...", "..#..#..#..", "..#.....#..", "...#...#...", ".##.....##.", "#....o....#", ".##.....##.", "...#...#...", "..#.....#..", "..#..#..#..", "...##.##..."]),
            ("apple", [".....g...", "....g.g..", "..##g##..", ".#.....#.", "#.......#", "#.......#", "#.......#", ".#.....#.", "..#####.."]),
            ("daisy", ["...#.#...", ".#.###.#.", "..#####..", "###ooo###", "..#####..", ".#.###.#.", "...#.#...", "....g....", "..g.g.g..", "...ggg...", "....g...."]),
            ("bell", ["....#....", "...###...", "..#####..", "..#####..", ".#######.", ".#.#.#.#.", "....g....", ".gg.g....", "...gg.gg.", "....g...."]),
            ("pix", ["....###....", "...#####...", "...##o##...", ".###.#.###.", "####.#.####", "#####o#####", "####.#.####", ".###.#.###.", "...##o##...", "...#####...", "....###....", ".....g.....", "..gg.g.gg..", ".gggggggg..", "..gg.g.gg..", ".....g....."]),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.0, DotPattern(name: $0.0, rows: $0.1)) })
    }()

    /// 每日页顶上那朵：六种结构按日期固定抽（plan §6.2）。
    static let dailyPatternNames = ["tulip", "star8", "sprig", "quatre", "daisy", "bell"]

    /// p8 刺绣色
    enum Stitch {
        static let orange = Color(red: 0.875, green: 0.541, blue: 0.333)
        static let rust = Color(red: 0.663, green: 0.31, blue: 0.169)
        static let olive = Color(red: 0.62, green: 0.647, blue: 0.298)
        static let lilac = Color(red: 0.78, green: 0.651, blue: 0.757)
        static let navy = Color(red: 0.294, green: 0.298, blue: 0.475)
        static let pink = Color(red: 0.886, green: 0.663, blue: 0.635)
        static let leaf = Color(red: 0.435, green: 0.541, blue: 0.271)
    }

    static func draw(_ pattern: DotPattern, mode: DotMode, in ctx: inout GraphicsContext, origin: CGPoint, cell: CGFloat,
                     head: Color, stem: Color? = nil, core: Color? = nil, rng: inout Rand) {
        for (j, row) in pattern.rows.enumerated() {
            for (i, ch) in row.enumerated() where ch != "." {
                let color: Color = ch == "g" ? (stem ?? head) : ch == "o" ? (core ?? head) : head
                let x = origin.x + CGFloat(i) * cell, y = origin.y + CGFloat(j) * cell
                switch mode {
                case .pixel:
                    ctx.fill(Path(CGRect(x: x, y: y, width: cell + 0.3, height: cell + 0.3)), with: .color(color))
                case .dot:
                    let r = cell * 0.3
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color))
                case .stitch:
                    let rx = cell * 0.36, ry = cell * 0.3
                    let cx = x + rng.jitter(cell * 0.15), cy = y + rng.jitter(cell * 0.15)
                    let stitch = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                        .applying(CGAffineTransform(rotationAngle: rng.jitter(0.9)).concatenating(CGAffineTransform(translationX: cx, y: cy)))
                    ctx.fill(stitch, with: .color(color))
                }
            }
        }
    }
}
