#if PERSONAL_APPS
import SwiftUI
import CoreText

/// 刻线引擎（plan-death-scale §4.6，移植自 design-death-scale.html）：只产出 `Path`，iOS / mac 共用。
/// 坐标系就是小样的 viewBox 单位，画的时候再整体缩放。
enum DeathScaleEngraver {
    struct RunPoint {
        var x: Double, y: Double, w: Double, nx: Double, ny: Double
    }

    /// 刻线自身的抖动比小样大一点（粟粟 10-01 第二轮）
    static let wobbleGain = 1.4
    static let wobbleFloor = 0.08

    // MARK: - 噪声 / 随机

    static func hash(_ x: Double, _ y: Double) -> Double {
        let h = sin(x * 127.1 + y * 311.7) * 43758.5453
        return h - floor(h)
    }

    static func noise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x), yi = floor(y), xf = x - xi, yf = y - yi
        func s(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        let u = s(xf), v = s(yf)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    struct Random {
        private var state: Int
        init(seed: Int) { state = max(1, seed % 2_147_483_647) }
        mutating func next() -> Double {
            state = (state * 16807) % 2_147_483_647
            return Double(state) / 2_147_483_647
        }
    }

    /// 小样里的 clamp：NaN（负数开分数次幂）当 0，刻线在那里断开
    static func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double {
        v.isNaN ? 0 : max(a, min(b, v))
    }

    // MARK: - 刻刀线

    /// 两头尖、中间粗的一根刻线
    static func ribbon(_ run: [RunPoint], into path: inout Path) {
        let n = run.count
        guard n >= 2 else { return }
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for (i, p) in run.enumerated() {
            let k = min(1, (Double(i) + 0.6) / 2.2, (Double(n - i) - 0.4) / 2.2)
            let w = p.w * k / 2
            left.append(CGPoint(x: p.x + p.nx * w, y: p.y + p.ny * w))
            right.append(CGPoint(x: p.x - p.nx * w, y: p.y - p.ny * w))
        }
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
    }

    struct Hatch {
        var box: (Double, Double, Double, Double)
        var angle: Double
        var gap: Double
        var step = 3.2
        var threshold = 0.0
        var maxWidth = 1.0
        var wobble = 0.35
        var gamma = 1.0
        var tone: (Double, Double) -> Double
        var inside: ((Double, Double) -> Bool)?
    }

    /// 平行排线铺调子：线宽跟着 tone 走，暗部粗，亮部断开
    static func hatch(_ o: Hatch) -> Path {
        let (x0, y0, x1, y1) = o.box
        let a = o.angle * .pi / 180, ca = cos(a), sa = sin(a)
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let r = hypot(x1 - x0, y1 - y0) / 2 + 2
        let wob = o.wobble * wobbleGain + wobbleFloor
        var path = Path()
        var run: [RunPoint] = []
        func flush() {
            ribbon(run, into: &path)
            run.removeAll(keepingCapacity: true)
        }
        for s in stride(from: -r, through: r, by: o.gap) {
            for t in stride(from: -r, through: r, by: o.step) {
                var x = cx + ca * t - sa * s, y = cy + sa * t + ca * s
                let wv = wob * (noise(x * 0.04 + s * 0.3, y * 0.04) - 0.5) * 2
                x -= sa * wv
                y += ca * wv
                if x < x0 || x > x1 || y < y0 || y > y1 || !(o.inside?(x, y) ?? true) { flush(); continue }
                let tv = (o.tone(x, y) - o.threshold) / (1 - o.threshold)
                if !(tv > 0.05) { flush(); continue }
                run.append(RunPoint(x: x, y: y, w: o.maxWidth * pow(min(1, tv), o.gamma), nx: -sa, ny: ca))
            }
            flush()
        }
        return path
    }

    /// 顺形刻线：沿给定折线走，线宽由 `width` 逐点给出，太细处断开
    static func strokeAlong(_ pts: [CGPoint], width: (CGPoint, Int) -> Double) -> Path {
        var path = Path()
        var cur: [RunPoint] = []
        for (i, p) in pts.enumerated() {
            let q = pts[min(i + 1, pts.count - 1)], o = pts[max(i - 1, 0)]
            let dx = q.x - o.x, dy = q.y - o.y
            let l = hypot(dx, dy)
            let len = l > 0 ? l : 1
            let w = width(p, i)
            if w > 0.06 {
                cur.append(RunPoint(x: p.x, y: p.y, w: w, nx: -dy / len, ny: dx / len))
            } else {
                ribbon(cur, into: &path)
                cur.removeAll(keepingCapacity: true)
            }
        }
        ribbon(cur, into: &path)
        return path
    }

    /// 点刻：一颗墨点
    static func dot(_ p: CGPoint, r: Double, into path: inout Path) {
        path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    // MARK: - 手刻抖动

    /// 轮廓细分后沿法线叠低频噪声（plan §2 第二轮）。噪声按位置取，闭合轮廓首尾自然接上；种子固定，每次画出来一样
    static func wobble(_ path: Path, amplitude: Double = 0.8, frequency: Double = 0.07, seed: Double = 0, step: Double = 1.6) -> Path {
        var out = Path()
        var pts: [CGPoint] = []
        var start = CGPoint.zero, current = CGPoint.zero

        func sampleLine(to p: CGPoint) {
            let n = max(1, Int((hypot(p.x - current.x, p.y - current.y) / step).rounded(.up)))
            for i in 1...n {
                let t = Double(i) / Double(n)
                pts.append(CGPoint(x: current.x + (p.x - current.x) * t, y: current.y + (p.y - current.y) * t))
            }
        }
        func sampleCurve(to p: CGPoint, length: Double, at: (Double) -> CGPoint) {
            let n = max(4, Int((length / step).rounded(.up)))
            for i in 1...n { pts.append(at(Double(i) / Double(n))) }
        }
        func emit(closed: Bool) {
            defer { pts.removeAll(keepingCapacity: true) }
            if closed, pts.count > 2, let f = pts.first, let l = pts.last, hypot(f.x - l.x, f.y - l.y) < 1e-6 { pts.removeLast() }
            guard pts.count > 1 else { return }
            let n = pts.count
            var moved: [CGPoint] = []
            moved.reserveCapacity(n)
            for i in 0..<n {
                let prev = closed ? pts[(i - 1 + n) % n] : pts[max(i - 1, 0)]
                let next = closed ? pts[(i + 1) % n] : pts[min(i + 1, n - 1)]
                let tx = next.x - prev.x, ty = next.y - prev.y
                let l = hypot(tx, ty)
                let p = pts[i]
                guard l > 0 else { moved.append(p); continue }
                let d = amplitude * (noise(p.x * frequency + seed, p.y * frequency + seed * 1.7) * 2 - 1)
                moved.append(CGPoint(x: p.x - ty / l * d, y: p.y + tx / l * d))
            }
            out.move(to: moved[0])
            for p in moved.dropFirst() { out.addLine(to: p) }
            if closed { out.closeSubpath() }
        }

        path.forEach { element in
            switch element {
            case .move(let p):
                emit(closed: false)
                pts = [p]
                start = p
                current = p
            case .line(let p):
                sampleLine(to: p)
                current = p
            case .quadCurve(let p, let c):
                let p0 = current
                let length = hypot(c.x - p0.x, c.y - p0.y) + hypot(p.x - c.x, p.y - c.y)
                sampleCurve(to: p, length: length) { t in
                    let u = 1 - t
                    return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p.y)
                }
                current = p
            case .curve(let p, let c1, let c2):
                let p0 = current
                let length = hypot(c1.x - p0.x, c1.y - p0.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p.x - c2.x, p.y - c2.y)
                sampleCurve(to: p, length: length) { t in
                    let u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p.x, y: a * p0.y + b * c1.y + c * c2.y + d * p.y)
                }
                current = p
            case .closeSubpath:
                if hypot(current.x - start.x, current.y - start.y) > 1e-6 { sampleLine(to: start) }
                emit(closed: true)
                current = start
                pts = [start]
            }
        }
        emit(closed: false)
        return out
    }

    // MARK: - 小几何

    static func polygon(_ pts: [CGPoint], closed: Bool = true) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for q in pts.dropFirst() { p.addLine(to: q) }
        if closed { p.closeSubpath() }
        return p
    }

    static func inPolygon(_ x: Double, _ y: Double, _ poly: [CGPoint]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let pi = poly[i], pj = poly[j]
            if (pi.y > y) != (pj.y > y), x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x { c.toggle() }
            j = i
        }
        return c
    }

    static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
    }

    /// 椭圆下半圈（从右端顺时针到左端），给秤盘前沿用
    static func lowerHalfEllipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, fromRight: Bool = true) -> [CGPoint] {
        (0...40).map { i in
            let t = Double.pi * Double(fromRight ? i : 40 - i) / 40
            return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
        }
    }

    /// 字距按 CoreText 量，给沿路径排字用
    static func advances(_ text: String, face: DeathScaleFont, size: Double) -> [Double] {
        let font = CTFontCreateWithName(face.rawValue as CFString, size, nil)
        return text.map { ch in
            let attr = NSAttributedString(string: String(ch), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attr)
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
    }
}

/// 版画字体（Resources/Fonts，FontManager 启动时注册）
enum DeathScaleFont: String {
    case english = "IM_FELL_English_Roman"
    case englishItalic = "IM_FELL_English_Italic"
    case smallCaps = "IM_FELL_English_SC"
    case pica = "IM_FELL_DW_Pica_Roman"
    case picaItalic = "IM_FELL_DW_Pica_Italic"

    func font(_ size: CGFloat) -> Font { .custom(rawValue, fixedSize: size) }

    /// 用户写的字（原因、小本子）：拉丁走 IM Fell，中文落到宋体（mac 系统 Songti SC；iOS 没有就用包内思源宋体）
    @MainActor
    func text(_ size: CGFloat) -> Font {
        let key = "\(rawValue)#\(size)"
        if let cached = Self.cache[key] { return cached }
        let cascade = ["STSongti-SC-Regular", "SourceHanSerifSC-Regular"].map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, size) }
        let attributes = [kCTFontNameAttribute: rawValue, kCTFontCascadeListAttribute: cascade] as [CFString: Any]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
        Self.cache[key] = font
        return font
    }

    @MainActor private static var cache: [String: Font] = [:]
}

/// 一版刻好的画：一串按顺序叠的填色 / 描线 / 字。tone 是抽象的墨 / 纸，画的时候才按深浅取色
struct DeathScaleArt {
    enum Tone { case ink, paper }

    struct Label {
        enum Align { case center, leading }
        var text: String
        var face: DeathScaleFont
        var size: Double
        var at: CGPoint
        var align: Align = .center
        var tracking: Double = 0
        var angle: Double = 0
        var halo = false
    }

    enum Op {
        case fill(Path, Tone)
        case stroke(Path, Tone, Double, [CGFloat])
        case label(Label)
    }

    var ops: [Op] = []

    mutating func fill(_ path: Path, _ tone: Tone = .ink) { ops.append(.fill(path, tone)) }

    mutating func stroke(_ path: Path, _ width: Double, _ tone: Tone = .ink, dash: [CGFloat] = []) {
        ops.append(.stroke(path, tone, width, dash))
    }

    /// 纸色填底 + 墨线描边；轮廓走手刻抖动
    mutating func shape(_ path: Path, _ width: Double, wobble amplitude: Double = 0.8, seed: Double = 0, fill: Tone? = .paper) {
        let w = DeathScaleEngraver.wobble(path, amplitude: amplitude, seed: seed)
        if let fill { ops.append(.fill(w, fill)) }
        ops.append(.stroke(w, .ink, width, []))
    }

    /// 只描不填的手刻轮廓
    mutating func outline(_ path: Path, _ width: Double, _ tone: Tone = .ink, wobble amplitude: Double = 0.8, seed: Double = 0, dash: [CGFloat] = []) {
        ops.append(.stroke(DeathScaleEngraver.wobble(path, amplitude: amplitude, seed: seed), tone, width, dash))
    }

    mutating func label(_ label: Label) { ops.append(.label(label)) }

    mutating func append(_ other: DeathScaleArt) { ops.append(contentsOf: other.ops) }

    func draw(in ctx: GraphicsContext, palette: DeathScalePalette) {
        for op in ops {
            switch op {
            case .fill(let path, let tone):
                ctx.fill(path, with: .color(palette.color(tone)))
            case .stroke(let path, let tone, let width, let dash):
                ctx.stroke(path, with: .color(palette.color(tone)), style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .miter, dash: dash))
            case .label(let label):
                Self.draw(label, in: ctx, palette: palette)
            }
        }
    }

    static func draw(_ label: Label, in ctx: GraphicsContext, palette: DeathScalePalette, tone: Tone = .ink) {
        var c = ctx
        c.translateBy(x: label.at.x, y: label.at.y)
        if label.angle != 0 { c.rotate(by: .radians(label.angle)) }
        func resolved(_ color: Color) -> GraphicsContext.ResolvedText {
            c.resolve(Text(label.text).font(label.face.font(label.size)).tracking(label.tracking).foregroundStyle(color))
        }
        let ink = resolved(palette.color(tone))
        let size = ink.measure(in: CGSize(width: 10_000, height: 10_000))
        let baseline = ink.firstBaseline(in: size)
        let origin = CGPoint(x: label.align == .center ? -size.width / 2 + label.tracking / 2 : 0, y: -baseline)
        if label.halo {
            let paper = resolved(palette.color(.paper))
            for k in 0..<8 {
                let a = Double(k) * .pi / 4
                c.draw(paper, in: CGRect(origin: CGPoint(x: origin.x + 1.2 * cos(a), y: origin.y + 1.2 * sin(a)), size: size))
            }
        }
        c.draw(ink, in: CGRect(origin: origin, size: size))
    }
}

/// 铜版的纸和墨：跟系统深浅走，不吃花园主题
struct DeathScalePalette: Equatable {
    let paper: Color, plate: Color, ink: Color, ink2: Color, faint: Color, desk: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            paper = Color(red: 0x16 / 255, green: 0x12 / 255, blue: 0x0e / 255)
            plate = Color(red: 0x1d / 255, green: 0x18 / 255, blue: 0x13 / 255)
            ink = Color(red: 0xe6 / 255, green: 0xd9 / 255, blue: 0xbd / 255)
            ink2 = Color(red: 0xbf / 255, green: 0xae / 255, blue: 0x8e / 255)
            faint = Color(red: 0x7a / 255, green: 0x6a / 255, blue: 0x52 / 255)
            desk = Color(red: 0x08 / 255, green: 0x07 / 255, blue: 0x06 / 255)
        } else {
            paper = Color(red: 0xec / 255, green: 0xe3 / 255, blue: 0xcb / 255)
            plate = Color(red: 0xe4 / 255, green: 0xd9 / 255, blue: 0xbd / 255)
            ink = Color(red: 0x1d / 255, green: 0x16 / 255, blue: 0x11 / 255)
            ink2 = Color(red: 0x4b / 255, green: 0x3d / 255, blue: 0x2f / 255)
            faint = Color(red: 0x8f / 255, green: 0x7d / 255, blue: 0x62 / 255)
            desk = Color(red: 0x7d / 255, green: 0x74 / 255, blue: 0x66 / 255)
        }
    }

    func color(_ tone: DeathScaleArt.Tone) -> Color { tone == .ink ? ink : paper }
}
#endif
