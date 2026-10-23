import SwiftUI

// MARK: - 日历页的纸上零件（plan-calendar-page §一）
// 能点的只有四种样子：铅笔方框按钮 / 行尾 › / 月历格子 / 打字机英文词（页签、← →）。
// 这里的装饰（铁门、分割线、签名）都不响应点击。

// MARK: 纸

/// 整页的纸：纯纸色，不叠纸纹（颗粒贴图平均 alpha 高，铺满会整体压暗；铅笔笔画自己有颗粒）
struct CalendarPaperBackground: View {
    var body: some View { CalInk.paper.allowsHitTesting(false) }
}

// MARK: 铁门页签（参考 1 的花园门顶）

struct GardenGateTabs: View {
    @Binding var selection: CalendarTab

    private static let rail: CGFloat = 32
    private static let height: CGFloat = 66
    /// 三个页签的中心，按宽度比例（小样 390 宽时是 72 / 195 / 318）
    private static let centers: [CGFloat] = [72.0 / 390, 195.0 / 390, 318.0 / 390]

    var body: some View {
        let tabs = CalendarTab.allCases
        GeometryReader { geo in
            let w = geo.size.width
            let on = tabs.firstIndex(of: selection) ?? 0
            Canvas { ctx, size in Self.drawGate(in: &ctx, width: size.width, selected: on) }
                .allowsHitTesting(false)
            ForEach(Array(tabs.enumerated()), id: \.element) { i, t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = t }
                } label: {
                    Text(t.englishLabel)
                        .font(CalType.type(CalType.tab))
                        .tracking(2)
                        .foregroundColor(i == on ? CalInk.ink : CalInk.ink3)
                        .frame(width: 96, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: w * Self.centers[i], y: Self.rail + 20)
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(i == on ? [.isSelected] : [])
            }
        }
        .frame(height: Self.height)
    }

    private static func drawGate(in ctx: inout GraphicsContext, width w: CGFloat, selected on: Int) {
        let rail = Self.rail
        let xs = centers.map { $0 * w }
        // 一排细栏杆尖（页签位置空出来）
        var pickets = Path(), tips = Path()
        var x: CGFloat = 26
        while x < w - 20 {
            if !xs.contains(where: { abs($0 - x) < 22 }) {
                pickets.move(to: CGPoint(x: x, y: rail)); pickets.addLine(to: CGPoint(x: x, y: rail - 8))
                tips.move(to: CGPoint(x: x, y: rail - 12)); tips.addLine(to: CGPoint(x: x + 1.6, y: rail - 8.5))
                tips.addLine(to: CGPoint(x: x, y: rail - 7.6)); tips.addLine(to: CGPoint(x: x - 1.6, y: rail - 8.5)); tips.closeSubpath()
            }
            x += 12
        }
        ctx.stroke(pickets, with: .color(CalInk.graphite), lineWidth: 0.9)
        ctx.fill(tips, with: .color(CalInk.graphite))
        // 主梁 + 副梁 + 两头铆钉
        var beam = Path(); beam.move(to: CGPoint(x: 18, y: rail)); beam.addLine(to: CGPoint(x: w - 18, y: rail))
        ctx.stroke(beam, with: .color(CalInk.ink2), lineWidth: 1.2)
        var sub = Path(); sub.move(to: CGPoint(x: 18, y: rail + 3.5)); sub.addLine(to: CGPoint(x: w - 18, y: rail + 3.5))
        ctx.stroke(sub, with: .color(CalInk.graphite), lineWidth: 0.8)
        for cx in [18, w - 18] { ctx.fill(Path(ellipseIn: CGRect(x: cx - 2.2, y: rail + 1.8 - 2.2, width: 4.4, height: 4.4)), with: .color(CalInk.ink2)) }
        // 矛尖
        for (i, cx) in xs.enumerated() {
            if i == on {
                ctx.stroke(flourish(x: cx, rail: rail), with: .color(CalInk.ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                drawSpear(in: &ctx, x: cx, rail: rail, h: 15, w: 9, color: CalInk.ink)
            } else {
                drawSpear(in: &ctx, x: cx, rail: rail, h: 9, w: 5.5, color: CalInk.graphite)
            }
        }
    }

    private static func drawSpear(in ctx: inout GraphicsContext, x: CGFloat, rail: CGFloat, h: CGFloat, w: CGFloat, color: Color) {
        let t = rail - h - 7
        var p = Path()
        p.move(to: CGPoint(x: x, y: t))
        p.addCurve(to: CGPoint(x: x + w * 0.5, y: t + h * 0.72), control1: CGPoint(x: x + w * 0.25, y: t + h * 0.3), control2: CGPoint(x: x + w * 0.5, y: t + h * 0.55))
        p.addCurve(to: CGPoint(x: x, y: t + h), control1: CGPoint(x: x + w * 0.5, y: t + h * 0.9), control2: CGPoint(x: x + w * 0.2, y: t + h))
        p.addCurve(to: CGPoint(x: x - w * 0.5, y: t + h * 0.72), control1: CGPoint(x: x - w * 0.2, y: t + h), control2: CGPoint(x: x - w * 0.5, y: t + h * 0.9))
        p.addCurve(to: CGPoint(x: x, y: t), control1: CGPoint(x: x - w * 0.5, y: t + h * 0.55), control2: CGPoint(x: x - w * 0.25, y: t + h * 0.3))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
        ctx.fill(Path(ellipseIn: CGRect(x: x - w * 0.32, y: t + h + 0.8, width: w * 0.64, height: 2.8)), with: .color(color))
        var stem = Path(); stem.move(to: CGPoint(x: x, y: t + h + 2)); stem.addLine(to: CGPoint(x: x, y: rail))
        ctx.stroke(stem, with: .color(color), lineWidth: w > 7 ? 1.8 : 1.2)
    }

    /// 选中矛尖两侧甩出去的一对卷草
    private static func flourish(x: CGFloat, rail r: CGFloat) -> Path {
        var p = Path()
        for k: CGFloat in [-1, 1] {
            p.move(to: CGPoint(x: x, y: r - 4))
            p.addCurve(to: CGPoint(x: x + k * 17, y: r - 9), control1: CGPoint(x: x + k * 5, y: r - 15), control2: CGPoint(x: x + k * 15, y: r - 16))
            p.addCurve(to: CGPoint(x: x + k * 11.5, y: r - 6), control1: CGPoint(x: x + k * 18, y: r - 4), control2: CGPoint(x: x + k * 13, y: r - 2))
            p.addCurve(to: CGPoint(x: x + k * 14, y: r - 8), control1: CGPoint(x: x + k * 10.8, y: r - 8), control2: CGPoint(x: x + k * 12.5, y: r - 9.5))
        }
        return p
    }
}

extension CalendarTab {
    /// 页签上只写英文打字机字；读屏念中文 `label`
    var englishLabel: String {
        switch self {
        case .month: "month"
        case .year: "year"
        case .anniversaries: "days"
        }
    }
}

// MARK: 铅笔方框 = 按钮

/// 抖动的四条铅笔线，出头一点点。种子固定 → 同一个按钮每次画得一样。
struct PencilFrame: View {
    let seed: String
    var color: Color = CalInk.ink2

    var body: some View {
        Canvas { ctx, size in
            var rng = CalendarInk.Rand(seed: CalendarInk.seed(seed, "box"))
            let w = size.width, h = size.height
            func o() -> CGFloat { 1.5 + rng.next() * 2.5 }
            var p = Path()
            p.addPath(CalendarInk.pencilLine(from: CGPoint(x: -o(), y: 0), to: CGPoint(x: w + o(), y: 0), amp: 0.8, segments: 4, overshoot: 0, rng: &rng))
            p.addPath(CalendarInk.pencilLine(from: CGPoint(x: w, y: -o()), to: CGPoint(x: w, y: h + o()), amp: 0.8, segments: 3, overshoot: 0, rng: &rng))
            p.addPath(CalendarInk.pencilLine(from: CGPoint(x: w + o(), y: h), to: CGPoint(x: -o(), y: h), amp: 0.8, segments: 4, overshoot: 0, rng: &rng))
            p.addPath(CalendarInk.pencilLine(from: CGPoint(x: 0, y: h + o()), to: CGPoint(x: 0, y: -o()), amp: 0.8, segments: 3, overshoot: 0, rng: &rng))
            ctx.drawLayer { layer in
                layer.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                CalendarInk.applyGrain(&layer, in: CGRect(x: -6, y: -6, width: w + 12, height: h + 12))
            }
        }
        .allowsHitTesting(false)
    }
}

struct PencilPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(CalInk.ink.opacity(configuration.isPressed ? 0.05 : 0))
    }
}

struct PencilBoxButton<Label: View>: View {
    let seed: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(PencilFrame(seed: seed))
                .contentShape(Rectangle())
        }
        .buttonStyle(PencilPressStyle())
    }
}

// MARK: 分割线 / 选中圈 / 小节标题

struct PencilRule: View {
    var seed = "rule"
    var body: some View {
        Canvas { ctx, size in
            var rng = CalendarInk.Rand(seed: CalendarInk.seed(seed))
            let line = CalendarInk.pencilLine(from: CGPoint(x: 2, y: size.height / 2), to: CGPoint(x: size.width - 2, y: size.height / 2),
                                              amp: 1.4, segments: max(3, Int(size.width / 28)), overshoot: 0, rng: &rng)
            ctx.drawLayer { layer in
                layer.stroke(line, with: .color(CalInk.graphite), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                CalendarInk.applyGrain(&layer, in: CGRect(origin: .zero, size: size))
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }
}

enum PencilRing {
    /// 圈住一个矩形的抖动闭合曲线（月历选中日、心情选中、图例共用）
    static func path(around r: CGRect, rng: inout CalendarInk.Rand) -> Path {
        CalendarInk.blob([
            CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ], amp: min(r.width, r.height) * 0.07, rng: &rng)
    }
}

/// 自己单独一个视图的选中圈
struct PencilRingView: View {
    var seed = "ring"
    var color: Color = CalInk.ink
    var body: some View {
        Canvas { ctx, size in
            var rng = CalendarInk.Rand(seed: CalendarInk.seed(seed))
            ctx.stroke(PencilRing.path(around: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5), rng: &rng),
                       with: .color(color), lineWidth: 1.1)
        }
        .allowsHitTesting(false)
    }
}

struct CalendarSectionLabel: View {
    let text: String
    var inset: CGFloat = 22
    var body: some View {
        Text(text)
            .font(.system(size: CalType.s))
            .tracking(0.5)
            .foregroundColor(CalInk.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
    }
}

// MARK: 当天区的块（手绘波浪框 = 装饰，不响应点击；和按钮的铅笔方框分开：更淡、边是小波浪）

struct WavyPencilFrame: View {
    private static let out: CGFloat = 4
    var seed = "block"
    var body: some View {
        Canvas { ctx, size in
            var rng = CalendarInk.Rand(seed: CalendarInk.seed(seed, "wavy"))
            let phase = rng.next() * 6
            func edge(_ a: CGPoint, _ b: CGPoint) -> Path {
                let len = hypot(b.x - a.x, b.y - a.y)
                guard len > 0 else { return Path() }
                let n = max(4, Int((len / 4).rounded()))
                let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
                var p = Path()
                for i in 0...n {
                    let t = CGFloat(i) / CGFloat(n)
                    let s = sin(t * len / 13 * 2 * .pi + phase) * 0.7 + (rng.next() - 0.5) * 0.5
                    let pt = CGPoint(x: a.x + (b.x - a.x) * t - uy * s, y: a.y + (b.y - a.y) * t + ux * s)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            func o() -> CGFloat { 1 + rng.next() * 2 }
            // Canvas 往外扩了 out：框画在里面那圈，出头的线头才不会被裁掉
            let m = Self.out, w = size.width - m * 2, h = size.height - m * 2
            var p = Path()
            p.addPath(edge(CGPoint(x: -o(), y: 0), CGPoint(x: w + o(), y: 0)))
            p.addPath(edge(CGPoint(x: w, y: -o()), CGPoint(x: w, y: h + o())))
            p.addPath(edge(CGPoint(x: w + o(), y: h), CGPoint(x: -o(), y: h)))
            p.addPath(edge(CGPoint(x: 0, y: h + o()), CGPoint(x: 0, y: -o())))
            p = p.applying(CGAffineTransform(translationX: m, y: m))
            ctx.drawLayer { layer in
                layer.stroke(p, with: .color(CalInk.frame), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                CalendarInk.applyGrain(&layer, in: CGRect(origin: .zero, size: size))
            }
        }
        .padding(-Self.out)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum CalendarBlockStyle {
    /// 块内左右留白（行、标题都按这个缩进）
    static let inset: CGFloat = 14
}

/// 一块：块内上下 10、左右由里面的行自己按 `CalendarBlockStyle.inset` 留
struct CalendarBlock<Content: View>: View {

    let seed: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WavyPencilFrame(seed: seed))
    }
}

/// 块标题行：左小标题，右边可选一个打字机 ＋（44 命中区）
struct CalendarBlockHeader: View {
    let title: String
    var inset: CGFloat = CalendarBlockStyle.inset
    var addLabel: String?
    var onAdd: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.system(size: CalType.s)).tracking(1).foregroundColor(CalInk.ink3)
            Spacer()
            if let onAdd {
                Button(action: onAdd) {
                    Text("+").font(CalType.type(CalType.n)).foregroundColor(CalInk.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PencilPressStyle())
                .accessibilityLabel(addLabel ?? "加一条")
                .padding(.trailing, -14)
            }
        }
        .padding(.horizontal, inset)
        .frame(minHeight: 28)
    }
}

// MARK: 列表行（行尾 › = 进入）

struct CalendarRow: View {
    let icon: String
    let title: String
    var tag: String?
    var meta: String?
    var inset: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(CalInk.ink2)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: CalType.b))
                    .foregroundColor(CalInk.ink)
                    .lineLimit(1)
                if let tag {
                    Text(tag).font(CalType.type(CalType.m)).foregroundColor(CalInk.ink3).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 8)
                if let meta {
                    Text(meta).font(.system(size: CalType.s)).foregroundColor(CalInk.ink3).lineLimit(1).fixedSize()
                }
                Text("›").font(CalType.type(15)).foregroundColor(CalInk.ink3).accessibilityHidden(true)
            }
            .padding(.horizontal, inset)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PencilPressStyle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: 页底：签名（page0 的 mneme atrium 字标，铅笔灰，纯装饰）+ 右边铅笔齿轮 = 日历设置

struct CalendarSignature: View {
    let onSettings: () -> Void

    var body: some View {
        HStack {
            Image("MnemeWordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 18)
                .foregroundColor(Color(red: 0.42, green: 0.42, blue: 0.41))
                .mask(GrainMask())
                .accessibilityHidden(true)
            Spacer()
            Button(action: onSettings) {
                PencilGear(seed: "settings")
                    .frame(width: 26, height: 26)
                    .frame(width: 44, height: 44)
                    .background(PencilFrame(seed: "settings-box"))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PencilPressStyle())
            .accessibilityLabel("日历设置")
        }
        .padding(.leading, 22)
        .padding(.trailing, 16)
        .padding(.top, 26)
    }
}

/// 铅笔齿轮：一个小圈 + 八根短齿，抖一点
struct PencilGear: View {
    var seed = "gear"
    var body: some View {
        Canvas { ctx, size in
            var rng = CalendarInk.Rand(seed: CalendarInk.seed(seed))
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let s = min(size.width, size.height) / 26
            var p = Path()
            for k in 0..<8 {
                let a = Double(k) / 8 * 2 * .pi
                p.addPath(CalendarInk.pencilLine(from: CGPoint(x: c.x + cos(a) * 6.2 * s, y: c.y + sin(a) * 6.2 * s),
                                                 to: CGPoint(x: c.x + cos(a) * 9 * s, y: c.y + sin(a) * 9 * s),
                                                 amp: 0.3, segments: 1, overshoot: 0, rng: &rng))
            }
            p.addPath(PencilRing.path(around: CGRect(x: c.x - 5.6 * s, y: c.y - 5.6 * s, width: 11.2 * s, height: 11.2 * s), rng: &rng))
            p.addPath(PencilRing.path(around: CGRect(x: c.x - 2.2 * s, y: c.y - 2.2 * s, width: 4.4 * s, height: 4.4 * s), rng: &rng))
            ctx.drawLayer { layer in
                layer.stroke(p, with: .color(CalInk.ink2), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                CalendarInk.applyGrain(&layer, in: CGRect(origin: .zero, size: size))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 铅笔颗粒遮罩：颗粒贴图的 alpha（0.25–1）铺满
private struct GrainMask: View {
    var body: some View {
        Canvas { ctx, size in
            let tile = ctx.resolve(CalendarInk.grainTile)
            let w = tile.size.width, h = tile.size.height
            guard w > 0, h > 0 else { return }
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width { ctx.draw(tile, in: CGRect(x: x, y: y, width: w, height: h)); x += w }
                y += h
            }
        }
    }
}

// MARK: 日记点阵纸

/// 她的日记：淡点阵纸上显示正文。只认一个极小的子集——`#` 标题（去井号加粗）、`- [ ]` / `- [x]` 待办（只读快照），其余原样
struct JournalDotPaper: View {
    let markdown: String

    enum Line: Equatable {
        case heading(String), todo(String, done: Bool), text(String), blank
    }

    static func lines(_ md: String) -> [Line] {
        md.components(separatedBy: "\n").map { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .blank }
            if t.hasPrefix("#") { return .heading(String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)) }
            for (p, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where t.hasPrefix(p) {
                return .todo(String(t.dropFirst(p.count)), done: done)
            }
            return .text(raw)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.lines(markdown).enumerated()), id: \.offset) { _, line in
                Group {
                    switch line {
                    case .heading(let t): Text(t).fontWeight(.semibold)
                    case .todo(let t, let done): Text("\(done ? "☑" : "☐")  \(t)")
                    case .text(let t): Text(t)
                    case .blank: Text(" ")
                    }
                }
                .font(.system(size: CalType.b))
                .foregroundColor(CalInk.ink)
                .lineSpacing(7)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DotGrid())
    }
}

/// 很淡的点阵：14pt 一格
private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 7
            while y < size.height {
                var x: CGFloat = 7
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7)), with: .color(Color(red: 0.804, green: 0.8, blue: 0.776)))
                    x += 14
                }
                y += 14
            }
        }
        .allowsHitTesting(false)
    }
}


enum CalendarText {
    static func yearsAgo(_ years: Int) -> String {
        switch years {
        case 1: "一年前"
        case 2: "两年前"
        case 3: "三年前"
        default: "\(years) 年前"
        }
    }
}
