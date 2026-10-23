import SwiftUI

/// 一张图要画的东西（范围已切好、试算已算好）
struct ChartPlotInput: Equatable {
    let series: [ChartCard.Series]
    let hidden: Set<Int>
    let selected: String?
    let unit: String

    var categories: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in series { for p in s.points where seen.insert(p.label).inserted { out.append(p.label) } }
        return out
    }

    var visible: [Int] { series.indices.filter { !hidden.contains($0) } }

    func value(_ series: Int, _ label: String) -> Double? {
        self.series[series].points.first { $0.label == label }?.value
    }
}

/// 入场：整体 progress 0→1 线性走，每一项按顺序错开、各自 quartic out（快进快停，不弹）
enum ChartReveal {
    static func local(_ progress: Double, index: Int, count: Int, stagger: Double = 0.4) -> Double {
        guard count > 1 else { return ease(progress) }
        let start = stagger * Double(index) / Double(count - 1)
        return ease(min(max((progress - start) / (1 - stagger), 0), 1))
    }

    static func ease(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 4) }
}

/// 图表画布的小工具（第 2 批的图也用）
extension GraphicsContext {
    func text(_ s: String, _ font: Font, _ color: Color, at p: CGPoint, anchor: UnitPoint) {
        draw(resolve(Text(s).font(font).foregroundColor(color)), at: p, anchor: anchor)
    }

    func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, width: CGFloat) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    func dot(_ c: CGPoint, r: CGFloat, _ color: Color) {
        fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
    }
}

func shortLabel(_ s: String, max: Int = 6) -> String { s.count > max ? String(s.prefix(max - 1)) + "…" : s }

// MARK: - 梯格柱（F1 Rung Bars；多系列 = 并肩双梯 F6）

/// 一根柱是一摞能数的横线（一格 = rungUnit），每第 5 格右边一个小点。柱不断轴；负数往下长
struct RungBarsPlot: View, Animatable {
    var progress: Double
    let input: ChartPlotInput
    let onTap: (String?) -> Void

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let cats = input.categories
        GeometryReader { g in
            Canvas { ctx, size in draw(ctx, size, cats) }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    onTap(ChartGeometry.slot(at: p.x, plot: 0...g.size.width, count: cats.count).map { cats[$0] })
                }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ cats: [String]) {
        let visible = input.visible
        guard !cats.isEmpty, !visible.isEmpty else { return }
        let values = visible.flatMap { i in input.series[i].points.map(\.value) }
        let peakPos = max(0, values.max() ?? 0), peakNeg = max(0, -(values.min() ?? 0))
        let unit = ChartGeometry.rungUnit(maxMagnitude: max(peakPos, peakNeg))
        let posRungs = (peakPos / unit).rounded(.up), negRungs = (peakNeg / unit).rounded(.up)
        let totalRungs = max(posRungs + negRungs, 1)
        let top: CGFloat = 16, bottom: CGFloat = 18
        let plotH = size.height - top - bottom
        let step = plotH / CGFloat(totalRungs)
        let zeroY = top + plotH * CGFloat(posRungs / totalRungs)
        let slotW = size.width / CGFloat(cats.count)
        let groupW = min(slotW * 0.66, CGFloat(26 * visible.count))
        let colW = groupW / CGFloat(visible.count)
        let lineW = max(0.6, min(1.3, step * 0.45))
        // 数值标签放得下才每根都标（按最长那个数估宽）；放不下只标最高那根和选中的
        let longest = values.map { ChartMath.format($0).count }.max() ?? 0
        let room = visible.count > 1 ? colW : slotW
        let showValues = cats.count <= 12 && CGFloat(longest) * (visible.count > 1 ? 5.4 : 6.3) <= room - 2
        let peakCat = cats.max { a, b in
            (visible.compactMap { input.value($0, a) }.map(abs).max() ?? 0) < (visible.compactMap { input.value($0, b) }.map(abs).max() ?? 0)
        }

        for (ci, cat) in cats.enumerated() {
            let local = ChartReveal.local(progress, index: ci, count: cats.count)
            let isSelected = input.selected == cat
            for (k, si) in visible.enumerated() {
                guard let v = input.value(si, cat) else { continue }
                let rungs = Int((abs(v) / unit).rounded())
                let drawn = Int((Double(rungs) * local).rounded(.down))
                let x0 = slotW * CGFloat(ci) + (slotW - groupW) / 2 + colW * CGFloat(k) + colW * 0.12
                let x1 = x0 + colW * 0.76
                let color = isSelected ? ChartInk.focus : ChartInk.series(si, of: input.series.count)
                for r in 0..<drawn {
                    let y = v >= 0 ? zeroY - step * (CGFloat(r) + 0.5) : zeroY + step * (CGFloat(r) + 0.5)
                    ctx.line(CGPoint(x: x0, y: y), CGPoint(x: x1, y: y), color, width: lineW)
                    if (r + 1) % 5 == 0, colW > 6 { ctx.dot(CGPoint(x: x1 + 1.8, y: y), r: 0.8, ChartInk.muted) }
                }
                if showValues || isSelected || (input.selected == nil && cat == peakCat), local > 0.9 {
                    let edge = v >= 0 ? zeroY - step * CGFloat(drawn) - 2 : zeroY + step * CGFloat(drawn) + 2
                    ctx.text(ChartMath.format(v), ChartInk.valueFont(visible.count > 1 ? 8.5 : 10), isSelected ? ChartInk.focus : ChartInk.ink,
                             at: CGPoint(x: (x0 + x1) / 2, y: edge), anchor: v >= 0 ? .bottom : .top)
                }
            }
        }
        ctx.line(CGPoint(x: 0, y: zeroY), CGPoint(x: size.width, y: zeroY), ChartInk.grid, width: 0.5)
        let every = ChartGeometry.labelStride(count: cats.count, width: size.width, minSpacing: 34)
        let selIndex = input.selected.flatMap { cats.firstIndex(of: $0) }
        for (ci, cat) in cats.enumerated() where ci == selIndex || (ci % every == 0 && !(selIndex.map { abs($0 - ci) < every && $0 != ci } ?? false)) {
            ctx.text(shortLabel(cat), ChartInk.axisFont, input.selected == cat ? ChartInk.ink : ChartInk.muted,
                     at: CGPoint(x: slotW * (CGFloat(ci) + 0.5), y: size.height), anchor: .bottom)
        }
    }
}

// MARK: - 发丝折线（F2 Hairline Line）

/// 1pt 的线 + 每个读数一个小点；第一条系列的峰值和末值放大标数；底部一排条码刻度（一个读数一根）
struct HairlineLinePlot: View, Animatable {
    var progress: Double
    let input: ChartPlotInput
    let onTap: (String?) -> Void

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let cats = input.categories
        GeometryReader { g in
            Canvas { ctx, size in draw(ctx, size, cats) }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    onTap(ChartGeometry.slot(at: p.x, plot: 0...g.size.width, count: cats.count).map { cats[$0] })
                }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ cats: [String]) {
        let visible = input.visible
        guard !cats.isEmpty, let primary = visible.first else { return }
        let values = visible.flatMap { i in input.series[i].points.map(\.value) }
        var lo = values.min() ?? 0, hi = values.max() ?? 1
        if lo == hi { lo -= 1; hi += 1 }
        let pad = (hi - lo) * 0.12
        lo -= pad; hi += pad
        let top: CGFloat = 20, floorY = size.height - 15
        let plotH = floorY - 8 - top
        let slotW = size.width / CGFloat(cats.count)
        func pt(_ ci: Int, _ v: Double) -> CGPoint {
            CGPoint(x: slotW * (CGFloat(ci) + 0.5), y: top + plotH * CGFloat(1 - (v - lo) / (hi - lo)))
        }

        // 条码地板：一个读数一根，每 5 根长一点
        for ci in cats.indices {
            let x = slotW * (CGFloat(ci) + 0.5)
            ctx.line(CGPoint(x: x, y: floorY - (ci % 5 == 0 ? 5 : 3)), CGPoint(x: x, y: floorY), ChartInk.faint, width: 0.6)
        }
        if let sel = input.selected, let ci = cats.firstIndex(of: sel) {
            let x = slotW * (CGFloat(ci) + 0.5)
            ctx.line(CGPoint(x: x, y: top - 6), CGPoint(x: x, y: floorY), ChartInk.muted.opacity(0.6), width: 0.6)
        }

        for si in visible.reversed() {
            let pts = cats.enumerated().compactMap { ci, cat in input.value(si, cat).map { (ci, pt(ci, $0)) } }
            guard !pts.isEmpty else { continue }
            let color = ChartInk.series(si, of: input.series.count)
            let reach = ChartReveal.ease(progress) * Double(pts.count - 1)
            let full = Int(reach.rounded(.down))
            var path = Path()
            path.move(to: pts[0].1)
            for i in stride(from: 1, through: min(full, pts.count - 1), by: 1) { path.addLine(to: pts[i].1) }
            if full + 1 < pts.count {
                let a = pts[full].1, b = pts[full + 1].1, f = CGFloat(reach - Double(full))
                path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: si == primary ? 1.1 : 0.9, lineCap: .round, lineJoin: .round))
            if pts.count <= 90 {
                for i in 0...min(full, pts.count - 1) { ctx.dot(pts[i].1, r: si == primary ? 1.7 : 1.3, color) }
            }
        }

        // 第一条：峰值 + 末值放大标数（画完才出）
        if progress >= 0.999 {
            let pts = cats.enumerated().compactMap { ci, cat in input.value(primary, cat).map { (ci, $0) } }
            if let peak = pts.max(by: { $0.1 < $1.1 }), let last = pts.last {
                for (ci, v) in peak.0 == last.0 ? [peak] : [peak, last] {
                    let p = pt(ci, v)
                    ctx.dot(p, r: 3.2, ChartInk.ink)
                    ctx.text(ChartMath.format(v), ChartInk.valueFont(), ChartInk.ink, at: CGPoint(x: p.x, y: p.y - 6), anchor: .bottom)
                }
            }
        }
        if let sel = input.selected, let ci = cats.firstIndex(of: sel) {
            for si in visible { if let v = input.value(si, sel) { ctx.dot(pt(ci, v), r: 3.6, ChartInk.focus) } }
        }

        let every = ChartGeometry.labelStride(count: cats.count, width: size.width, minSpacing: 40)
        for (ci, cat) in cats.enumerated() where ci % every == 0 {
            ctx.text(shortLabel(cat), ChartInk.axisFont, ChartInk.muted, at: CGPoint(x: slotW * (CGFloat(ci) + 0.5), y: size.height), anchor: .bottom)
        }
    }
}

// MARK: - 刻度环（F4 Tick Donut）

/// 一圈 100 根刻度，一根 = 1%，12 点起顺时针；各段按大小排名取深浅（最大最黑）。环心是总数，选中一段换成它的读数
struct TickRingPlot: View, Animatable {
    var progress: Double
    let input: ChartPlotInput
    let onTap: (String?) -> Void

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var points: [ChartCard.Point] { input.series.first?.points ?? [] }

    static func radius(_ size: CGSize) -> CGFloat { max(20, min(size.height * 0.42, (size.width - 150) / 2)) }

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in onTap(hit(p, g.size)) }
                .overlay { center.position(x: g.size.width / 2, y: g.size.height / 2).allowsHitTesting(false) }
        }
    }

    private func hit(_ p: CGPoint, _ size: CGSize) -> String? {
        let r = Self.radius(size)
        let dx = Double(p.x - size.width / 2), dy = Double(p.y - size.height / 2)
        let d = (dx * dx + dy * dy).squareRoot()
        guard d >= Double(r) * 0.55, d <= Double(r) * 1.3 else { return nil }
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * .pi }
        let tick = min(99, Int(a / (2 * .pi) * 100))
        return ChartGeometry.ringSegment(atTick: tick, ticks: ChartGeometry.ringTicks(points.map(\.value))).map { points[$0].label }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let ticks = ChartGeometry.ringTicks(points.map(\.value))
        let order = points.indices.sorted { points[$0].value > points[$1].value }
        var rank = [Int](repeating: 0, count: points.count)
        for (r, i) in order.enumerated() { rank[i] = r }
        let selectedIndex = input.selected.flatMap { s in points.firstIndex { $0.label == s } }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = Self.radius(size)
        func polar(_ radius: CGFloat, _ deg: Double) -> CGPoint {
            CGPoint(x: c.x + radius * CGFloat(cos(deg * .pi / 180)), y: c.y + radius * CGFloat(sin(deg * .pi / 180)))
        }
        let drawn = Int((ChartReveal.ease(progress) * 100).rounded(.down))
        for t in 0..<drawn {
            guard let seg = ChartGeometry.ringSegment(atTick: t, ticks: ticks) else { continue }
            let deg = -90 + (Double(t) + 0.5) * 3.6
            let on = seg == selectedIndex
            ctx.line(polar(r * 0.8, deg), polar(on ? r * 1.07 : r, deg), on ? ChartInk.focus : ChartInk.rank(rank[seg]), width: 1.4)
            if t % 10 == 0 { ctx.dot(polar(r * 0.72, deg), r: 0.7, ChartInk.faint) }
        }
        guard progress >= 0.999 else { return }
        // 外圈标签：最大的 6 段，同一侧上下太挤的跳过（点一下照样能看）
        var placed: [(right: Bool, y: CGFloat)] = []
        var start = 0
        let starts = ticks.map { n -> Int in defer { start += n }; return start }
        for i in order.prefix(6) where ticks[i] > 0 {
            let deg = -90 + (Double(starts[i]) + Double(ticks[i]) / 2) * 3.6
            let p = polar(r + 10, deg)
            let right = p.x >= c.x
            guard !placed.contains(where: { $0.right == right && abs($0.y - p.y) < 13 }) else { continue }
            placed.append((right, p.y))
            ctx.text("\(shortLabel(points[i].label, max: 8)) · \(ticks[i])", .system(size: 9.5, weight: rank[i] == 0 ? .bold : .semibold),
                     i == selectedIndex ? ChartInk.focus : (rank[i] == 0 ? ChartInk.ink : ChartInk.muted),
                     at: p, anchor: right ? .leading : .trailing)
        }
    }

    @ViewBuilder
    private var center: some View {
        let total = points.map(\.value).reduce(0, +)
        VStack(spacing: 1) {
            if let s = input.selected, let p = points.first(where: { $0.label == s }) {
                Text(shortLabel(p.label, max: 8)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(ChartInk.muted)
                Text(ChartMath.format(p.value)).font(ChartInk.valueFont(19)).foregroundStyle(ChartInk.focus)
                Text("\(ChartGeometry.ringTicks(points.map(\.value))[points.firstIndex(of: p) ?? 0])%")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(ChartInk.muted)
            } else {
                Text(ChartMath.format(total)).font(ChartInk.valueFont(21)).foregroundStyle(ChartInk.ink)
                Text(input.unit.isEmpty ? "合计" : "合计 · \(input.unit)").font(.system(size: 9, weight: .semibold)).foregroundStyle(ChartInk.muted)
            }
        }
        .opacity(progress >= 0.999 ? 1 : 0)
    }
}
