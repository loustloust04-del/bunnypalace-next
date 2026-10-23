import SwiftUI

// 图表卡 v2 第 2 批（docs/plan-chart-cards-v2.md）：area · hbar · stack · diverging · hundred · barcode · stream ·
// calendar · heat · candle · dumbbell。画法照网页设计稿（粟粟 10-03「只做 html」那页）一比一搬过来，Canvas 自画。

/// 第 2 批共用的画布外壳：progress 驱动入场，点一下交给 hit 换成标签
struct ChartCanvasPlot: View, Animatable {
    var progress: Double
    let card: ChartCard
    let input: ChartPlotInput
    let onTap: (String?) -> Void

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in ChartDraw2.draw(card, input, ctx, size, progress) }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in onTap(ChartDraw2.hit(card, input, p, g.size)) }
        }
    }

    /// 每种图要多高（行数决定的图按行算）
    static func height(_ card: ChartCard, _ input: ChartPlotInput) -> CGFloat {
        switch card.type {
        case .hbar: return CGFloat(input.categories.count) * (input.series.count > 1 ? 26 : 22) + 8
        case .diverging: return CGFloat(input.categories.count) * 21 + 10
        case .dumbbell: return CGFloat(card.pairs?.count ?? 0) * 30 + 12
        case .heat: return CGFloat(card.rows?.count ?? 0) * 20 + 24
        case .calendar: return 92
        case .hundred: return 156
        case .scatter: return 200
        case .box: return CGFloat(card.boxes?.count ?? 0) * 30 + 24
        case .waterfall: return 190
        case .gauge: return 150
        case .funnel: return CGFloat(input.categories.count) * 26 + 4
        case .treemap: return 210
        default: return 180
        }
    }
}

enum ChartDraw2 {
    // MARK: 分发

    static func draw(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        switch card.type {
        case .area: area(input, ctx, size, progress)
        case .hbar: hbar(input, ctx, size, progress)
        case .stack: stack(input, ctx, size, progress)
        case .diverging: diverging(input, ctx, size, progress)
        case .hundred: hundred(input, ctx, size, progress)
        case .barcode: barcode(input, ctx, size, progress)
        case .stream: stream(input, ctx, size, progress)
        case .calendar: calendar(card, input, ctx, size, progress)
        case .heat: heat(card, input, ctx, size, progress)
        case .candle: candle(card, input, ctx, size, progress)
        case .dumbbell: dumbbell(card, input, ctx, size, progress)
        case .scatter: scatter(card, input, ctx, size, progress)
        case .histogram: histogram(input, ctx, size, progress)
        case .box: box(card, input, ctx, size, progress)
        case .waterfall: waterfall(card, input, ctx, size, progress)
        case .gauge: gauge(card, input, ctx, size, progress)
        case .funnel: funnel(input, ctx, size, progress)
        case .treemap: treemap(card, input, ctx, size, progress)
        default: break
        }
    }

    static func hit(_ card: ChartCard, _ input: ChartPlotInput, _ p: CGPoint, _ size: CGSize) -> String? {
        switch card.type {
        case .area, .barcode, .stack, .stream, .histogram:
            let cats = input.categories
            return ChartGeometry.slot(at: p.x, plot: 0...size.width, count: cats.count).map { cats[$0] }
        case .hbar, .diverging:
            let cats = input.categories
            let rowH = (size.height - (card.type == .hbar ? 8 : 10)) / CGFloat(max(cats.count, 1))
            let i = Int((p.y - 4) / rowH)
            return cats.indices.contains(i) ? cats[i] : nil
        case .dumbbell:
            let pairs = card.pairs ?? []
            let i = Int((p.y - 6) / 30)
            return pairs.indices.contains(i) ? pairs[i].label : nil
        case .candle:
            let ks = card.candles ?? []
            return ChartGeometry.slot(at: p.x, plot: 0...size.width, count: ks.count).map { ks[$0].label }
        case .hundred:
            let s = cellSize(size), cols = 10
            let c = Int((p.x - 4) / s), r = Int((p.y - 4) / s)
            if (0..<cols).contains(c), (0..<10).contains(r) {
                let ticks = ChartGeometry.ringTicks(input.series.first?.points.map(\.value) ?? [])
                return ChartGeometry.ringSegment(atTick: r * cols + c, ticks: ticks).map { input.series[0].points[$0].label }
            }
            // 右边图例那一列
            let legendX = 4 + s * 10 + 14
            guard p.x >= legendX else { return nil }
            let i = Int((p.y - 8) / 22)
            let pts = input.series.first?.points ?? []
            return pts.indices.contains(i) ? pts[i].label : nil
        case .heat:
            let rows = card.rows ?? [], cols = card.cols ?? []
            let lx: CGFloat = 32, cw = (size.width - lx - 4) / CGFloat(max(cols.count, 1)), rh: CGFloat = 20
            let c = Int((p.x - lx) / cw), r = Int(p.y / rh)
            guard p.x >= lx, rows.indices.contains(r), cols.indices.contains(c) else { return nil }
            return "\(rows[r]) · \(cols[c])"
        case .calendar:
            let cells = ChartCalendar.cells(card.days ?? [])
            let g = calendarGrid(cells, size)
            let c = Int((p.x - g.ox) / g.cs), r = Int((p.y - g.oy) / g.cs)
            return cells.first { $0.column == c && $0.row == r }?.day.date
        case .waterfall:
            let steps = ChartStats.waterfall(card)
            return ChartGeometry.slot(at: p.x, plot: 0...size.width, count: steps.count).map { steps[$0].label }
        case .scatter:
            let pts = card.scatter ?? [], g = scatterFrame(pts, size)
            return pts.map { ($0.label, hypot(g.x($0.x) - p.x, g.y($0.y) - p.y)) }.filter { $0.1 < 16 }.min { $0.1 < $1.1 }?.0
        case .box:
            let groups = card.boxes ?? []
            let i = Int((p.y - 6) / 30)
            return groups.indices.contains(i) ? groups[i].name : nil
        case .funnel:
            let cats = input.categories
            let i = Int((p.y - 2) / ((size.height - 4) / CGFloat(max(cats.count, 1))))
            return cats.indices.contains(i) ? cats[i] : nil
        case .gauge:
            return "进度"
        case .treemap:
            return treeCells(card, size).cells.first { $0.rect.contains(p) }?.label
        default:
            return nil
        }
    }

    // MARK: 发丝面积（F3）：一根竖发丝 = 一个读数 + 外轮廓

    private static func area(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let cats = input.categories, vis = input.visible
        guard !cats.isEmpty, let primary = vis.first else { return }
        let hi = (vis.flatMap { input.series[$0].points.map(\.value) }.max() ?? 1) * 1.12
        let top: CGFloat = 20, floor = size.height - 18, sw = size.width / CGFloat(cats.count)
        let x = { (i: Int) in sw * (CGFloat(i) + 0.5) }
        let y = { (v: Double) in floor - (floor - top) * CGFloat(max(v, 0) / max(hi, 1e-9)) }
        for (i, c) in cats.enumerated() {
            guard let v = input.value(primary, c) else { continue }
            let local = ChartReveal.local(progress, index: i, count: cats.count)
            let on = c == input.selected
            ctx.line(CGPoint(x: x(i), y: floor), CGPoint(x: x(i), y: floor - (floor - y(v)) * local), on ? ChartInk.focus : ChartInk.ladder[4], width: on ? 1.4 : 0.7)
        }
        if progress > 0.6 {
            for si in vis.reversed() {
                let pts = cats.enumerated().compactMap { i, c in input.value(si, c).map { CGPoint(x: x(i), y: y($0)) } }
                guard let first = pts.first else { continue }
                var path = Path()
                path.move(to: first)
                pts.dropFirst().forEach { path.addLine(to: $0) }
                ctx.stroke(path, with: .color(ChartInk.series(si, of: input.series.count).opacity((progress - 0.6) / 0.4)),
                           style: StrokeStyle(lineWidth: si == primary ? 1.2 : 0.9, lineJoin: .round))
            }
        }
        if progress >= 0.999, let peak = cats.enumerated().compactMap({ i, c in input.value(primary, c).map { (i, $0) } }).max(by: { $0.1 < $1.1 }) {
            ctx.dot(CGPoint(x: x(peak.0), y: y(peak.1)), r: 3, ChartInk.ink)
            ctx.text(ChartMath.format(peak.1), ChartInk.valueFont(), ChartInk.ink, at: CGPoint(x: x(peak.0), y: y(peak.1) - 6), anchor: .bottom)
        }
        ctx.line(CGPoint(x: 0, y: floor), CGPoint(x: size.width, y: floor), ChartInk.grid, width: 0.6)
        axisLabels(cats, ctx, size, minSpacing: 40)
    }

    // MARK: 刻度横条（F5）：一行一类，一根竖刻度 = 一个单位；第 2 条系列在下面一行细浅刻度

    private static func hbar(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let cats = input.categories, n = input.series.count
        guard !cats.isEmpty else { return }
        let rowH = (size.height - 8) / CGFloat(cats.count), lx: CGFloat = 58, rx = size.width - 34
        let peak = input.series.flatMap { $0.points.map(\.value) }.max() ?? 1
        let u = ChartGeometry.rungUnit(maxMagnitude: peak), maxT = max(1, (peak / u).rounded(.up))
        let gap = (rx - lx) / CGFloat(maxT)
        for (r, c) in cats.enumerated() {
            let yc = 6 + CGFloat(r) * rowH + rowH / 2, on = c == input.selected
            let local = ChartReveal.local(progress, index: r, count: cats.count)
            ctx.text(shortLabel(c, max: 5), ChartInk.axisFont, on ? ChartInk.ink : ChartInk.muted, at: CGPoint(x: lx - 8, y: yc), anchor: .trailing)
            for si in input.series.indices where !input.hidden.contains(si) {
                guard let v = input.value(si, c) else { continue }
                let total = Int((max(v, 0) / u).rounded()), drawn = Int(Double(total) * local)
                let y0 = si == 0 ? yc - 9 : yc + 5, h: CGFloat = si == 0 ? 9 : 4
                let color = on ? ChartInk.focus : ChartInk.series(si, of: n)
                for t in 0..<drawn {
                    let xx = lx + gap * (CGFloat(t) + 0.5)
                    ctx.line(CGPoint(x: xx, y: y0), CGPoint(x: xx, y: y0 + h + ((t + 1) % 5 == 0 && si == 0 ? 2 : 0)), color, width: min(1.2, gap * 0.45))
                }
                if si == 0, local > 0.9 {
                    ctx.text(ChartMath.format(v), ChartInk.valueFont(), on ? ChartInk.focus : ChartInk.ink,
                             at: CGPoint(x: lx + gap * CGFloat(total) + 5, y: yc - 4), anchor: .leading)
                }
            }
        }
    }

    // MARK: 堆叠梯（F7）：每格按所属段取灰阶，第一段在最下面，顶上是合计

    private static func stack(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let cats = input.categories, n = cats.count
        guard n > 0 else { return }
        let totals = cats.map { c in input.series.compactMap { $0.points.first { $0.label == c }?.value }.reduce(0, +) }
        let u = ChartGeometry.rungUnit(maxMagnitude: totals.max() ?? 1)
        let top: CGFloat = 18, floor = size.height - 18
        let step = (floor - top) / CGFloat(max(1, ((totals.max() ?? 1) / u).rounded(.up)))
        let sw = size.width / CGFloat(n), cw = min(sw * 0.5, 34), lineW = min(1.3, step * 0.45)
        let shades = [0, 2, 4, 5]
        for (i, c) in cats.enumerated() {
            let x0 = sw * CGFloat(i) + (sw - cw) / 2, on = c == input.selected
            let local = ChartReveal.local(progress, index: i, count: n)
            var r = 0
            for (si, s) in input.series.enumerated() {
                let k = Int(((s.points.first { $0.label == c }?.value ?? 0) / u).rounded())
                let color = on ? ChartInk.focus : ChartInk.ladder[shades[min(si, 3)]]
                for _ in 0..<k {
                    if Double(r) < Double(Int((totals[i] / u).rounded())) * local {
                        let y = floor - step * (CGFloat(r) + 0.5)
                        ctx.line(CGPoint(x: x0, y: y), CGPoint(x: x0 + cw, y: y), color, width: lineW)
                    }
                    r += 1
                }
            }
            if local > 0.9 {
                ctx.text(ChartMath.format(totals[i]), ChartInk.valueFont(), on ? ChartInk.focus : ChartInk.ink,
                         at: CGPoint(x: x0 + cw / 2, y: floor - step * CGFloat(r) - 3), anchor: .bottom)
            }
        }
        ctx.line(CGPoint(x: 0, y: floor), CGPoint(x: size.width, y: floor), ChartInk.grid, width: 0.6)
        axisLabels(cats, ctx, size, minSpacing: 34)
    }

    // MARK: 正负条（G10，Lupi 化成刻度行）：负左正右，类名在中线的另一侧

    private static func diverging(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let pts = input.series.first?.points ?? []
        guard !pts.isEmpty else { return }
        let rowH = (size.height - 10) / CGFloat(pts.count), cx = size.width / 2 + 20
        let peak = pts.map { abs($0.value) }.max() ?? 1, u = ChartGeometry.rungUnit(maxMagnitude: peak)
        let gap = (size.width - cx - 32) / CGFloat(max(1, (peak / u).rounded(.up)))
        ctx.line(CGPoint(x: cx, y: 2), CGPoint(x: cx, y: size.height - 2), ChartInk.grid, width: 0.7)
        for (r, p) in pts.enumerated() {
            let yc = 6 + CGFloat(r) * rowH + rowH / 2, dir: CGFloat = p.value >= 0 ? 1 : -1, on = p.label == input.selected
            let total = Int((abs(p.value) / u).rounded()), drawn = Int(Double(total) * ChartReveal.local(progress, index: r, count: pts.count))
            let color = on ? ChartInk.focus : (p.value >= 0 ? ChartInk.ink : ChartInk.ladder[3])
            for t in 0..<drawn {
                let xx = cx + dir * gap * (CGFloat(t) + 0.5)
                ctx.line(CGPoint(x: xx, y: yc - 5), CGPoint(x: xx, y: yc + 5), color, width: min(1.2, gap * 0.45))
            }
            if progress >= 0.999 {
                ctx.text((p.value > 0 ? "+" : "") + ChartMath.format(p.value), ChartInk.valueFont(9.5), color,
                         at: CGPoint(x: cx + dir * (gap * CGFloat(total) + 5), y: yc), anchor: p.value >= 0 ? .leading : .trailing)
            }
            ctx.text(shortLabel(p.label, max: 5), ChartInk.axisFont, on ? ChartInk.ink : ChartInk.muted,
                     at: CGPoint(x: cx - dir * 6, y: yc), anchor: p.value >= 0 ? .trailing : .leading)
        }
    }

    // MARK: 百格（L14）：10×10，一点 = 1%，按大小排名取深浅；右边一列「名称 · N」

    fileprivate static func cellSize(_ size: CGSize) -> CGFloat { min(15, (size.height - 8) / 10, (size.width - 150) / 10) }

    private static func hundred(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let pts = input.series.first?.points ?? []
        guard !pts.isEmpty else { return }
        let ticks = ChartGeometry.ringTicks(pts.map(\.value)), s = cellSize(size)
        let order = pts.indices.sorted { pts[$0].value > pts[$1].value }
        var rank = [Int](repeating: 0, count: pts.count)
        for (r, i) in order.enumerated() { rank[i] = r }
        let drawn = Int(ChartReveal.ease(progress) * 100)
        var k = 0
        for (i, p) in pts.enumerated() {
            let on = p.label == input.selected
            for _ in 0..<ticks[i] {
                if k < drawn {
                    ctx.dot(CGPoint(x: 4 + CGFloat(k % 10) * s + s / 2, y: 4 + CGFloat(k / 10) * s + s / 2), r: s * (on ? 0.36 : 0.33),
                            on ? ChartInk.focus : ChartInk.rank(rank[i]))
                }
                k += 1
            }
        }
        let lx = 4 + s * 10 + 14
        for (i, p) in pts.enumerated() {
            let y = 18 + CGFloat(i) * 22, on = p.label == input.selected
            ctx.dot(CGPoint(x: lx + 4, y: y), r: 4.5, on ? ChartInk.focus : ChartInk.rank(rank[i]))
            ctx.text("\(shortLabel(p.label, max: 6)) · \(ticks[i])", .system(size: 10.5, weight: rank[i] == 0 ? .bold : .semibold),
                     rank[i] == 0 || on ? ChartInk.ink : ChartInk.muted, at: CGPoint(x: lx + 14, y: y), anchor: .leading)
        }
    }

    // MARK: 条码棒棒糖（L3）：一天一根竖发丝 + 顶端小点，最高两天标数

    private static func barcode(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let pts = input.series.first?.points ?? []
        guard !pts.isEmpty else { return }
        let top: CGFloat = 22, floor = size.height - 18, hi = (pts.map(\.value).max() ?? 1) * 1.1, sw = size.width / CGFloat(pts.count)
        let x = { (i: Int) in sw * (CGFloat(i) + 0.5) }
        let y = { (v: Double) in floor - (floor - top) * CGFloat(max(v, 0) / max(hi, 1e-9)) }
        for (i, p) in pts.enumerated() {
            let local = ChartReveal.local(progress, index: i, count: pts.count, stagger: 0.6), on = p.label == input.selected
            let yy = floor - (floor - y(p.value)) * local
            ctx.line(CGPoint(x: x(i), y: floor), CGPoint(x: x(i), y: yy), on ? ChartInk.focus : ChartInk.ladder[3], width: on ? 1.3 : 0.7)
            ctx.dot(CGPoint(x: x(i), y: yy), r: on ? 2.6 : 1.4, on ? ChartInk.focus : ChartInk.ink)
        }
        if progress >= 0.999 {
            // 最高两天标数；挨得太近（标签会叠）就只标最高那天
            var marked: [CGFloat] = []
            for (i, p) in pts.enumerated().sorted(by: { $0.element.value > $1.element.value }).prefix(2)
            where !marked.contains(where: { abs($0 - x(i)) < 40 }) {
                marked.append(x(i))
                ctx.text(ChartMath.format(p.value), ChartInk.valueFont(), ChartInk.ink, at: CGPoint(x: x(i), y: y(p.value) - 6), anchor: .bottom)
            }
        }
        ctx.line(CGPoint(x: 0, y: floor + 0.5), CGPoint(x: size.width, y: floor + 0.5), ChartInk.grid, width: 0.6)
        axisLabels(pts.map(\.label), ctx, size, minSpacing: 46)
    }

    // MARK: 河流（F16）：2–5 层堆叠面积，实心灰阶，层间纸色细缝

    private static func stream(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let cats = input.categories, vis = input.visible, n = cats.count
        guard n > 0, !vis.isEmpty else { return }
        let totals = cats.map { c in vis.compactMap { input.value($0, c) }.reduce(0, +) }
        let hi = (totals.max() ?? 1) * 1.08, top: CGFloat = 14, floor = size.height - 18
        let x = { (i: Int) in n == 1 ? size.width / 2 : CGFloat(i) * size.width / CGFloat(n - 1) }
        let y = { (v: Double) in floor - (floor - top) * CGFloat(v / max(hi, 1e-9)) * CGFloat(ChartReveal.ease(progress)) }
        func curve(_ path: inout Path, _ pts: [CGPoint]) {
            for (i, p) in pts.enumerated() where i > 0 {
                let q = pts[i - 1], mx = (q.x + p.x) / 2
                path.addCurve(to: p, control1: CGPoint(x: mx, y: q.y), control2: CGPoint(x: mx, y: p.y))
            }
        }
        var base = cats.map { _ in 0.0 }
        for si in vis {
            let lo = cats.indices.map { CGPoint(x: x($0), y: y(base[$0])) }
            let next = cats.indices.map { base[$0] + (input.value(si, cats[$0]) ?? 0) }
            let up = cats.indices.map { CGPoint(x: x($0), y: y(next[$0])) }
            var path = Path()
            path.move(to: up[0])
            curve(&path, up)
            path.addLine(to: lo[lo.count - 1])
            curve(&path, Array(lo.reversed()))
            path.closeSubpath()
            ctx.fill(path, with: .color(ChartInk.series(si, of: input.series.count)))
            ctx.stroke(path, with: .color(Color(hex: 0xFFFDF9)), lineWidth: 0.8)
            base = next
        }
        if let sel = input.selected, let i = cats.firstIndex(of: sel) {
            ctx.line(CGPoint(x: x(i), y: top - 6), CGPoint(x: x(i), y: floor), ChartInk.focus, width: 1.2)
            ctx.dot(CGPoint(x: x(i), y: y(totals[i])), r: 3, ChartInk.focus)
            ctx.text(ChartMath.format(totals[i]), ChartInk.valueFont(), ChartInk.ink, at: CGPoint(x: x(i), y: y(totals[i]) - 6), anchor: .bottom)
        }
        ctx.line(CGPoint(x: 0, y: floor), CGPoint(x: size.width, y: floor), ChartInk.grid, width: 0.6)
        let every = ChartGeometry.labelStride(count: n, width: size.width, minSpacing: 44)
        for (i, c) in cats.enumerated() where i % every == 0 {
            ctx.text(shortLabel(c), ChartInk.axisFont, ChartInk.muted, at: CGPoint(x: min(max(x(i), 14), size.width - 14), y: size.height), anchor: .bottom)
        }
    }

    // MARK: 日历热力（L17）：一列 = 一周，周一在上，点面积 = 数；没数的日子是最浅的小点

    fileprivate static func calendarGrid(_ cells: [ChartCalendar.Cell], _ size: CGSize) -> (ox: CGFloat, oy: CGFloat, cs: CGFloat) {
        let cols = max(ChartCalendar.columnCount(cells), 1)
        return (18, 14, min((size.width - 22) / CGFloat(cols), 14, (size.height - 26) / 7))
    }

    private static func calendar(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let cells = ChartCalendar.cells(card.days ?? [])
        guard !cells.isEmpty else { return }
        let g = calendarGrid(cells, size), maxV = cells.map(\.day.value).max() ?? 1
        for (k, r) in [0, 2, 4, 6].enumerated() {
            ctx.text(["一", "三", "五", "日"][k], .system(size: 7.5, weight: .semibold), ChartInk.faint,
                     at: CGPoint(x: 3, y: g.oy + CGFloat(r) * g.cs + g.cs / 2), anchor: .leading)
        }
        for m in ChartCalendar.monthStarts(cells) {
            ctx.text(m.label, .system(size: 8, weight: .semibold), ChartInk.muted, at: CGPoint(x: g.ox + CGFloat(m.column) * g.cs, y: 1), anchor: .topLeading)
        }
        let cols = ChartCalendar.columnCount(cells)
        for c in cells {
            let local = ChartReveal.local(progress, index: c.column, count: cols, stagger: 0.6)
            guard local > 0.05 else { continue }
            let center = CGPoint(x: g.ox + CGFloat(c.column) * g.cs + g.cs / 2, y: g.oy + CGFloat(c.row) * g.cs + g.cs / 2)
            let on = c.day.date == input.selected
            if c.day.value > 0 {
                let r = max(ChartGeometry.areaRadius(c.day.value, max: maxV, maxRadius: g.cs * 0.48), 0.9) * CGFloat(local)
                ctx.dot(center, r: r, on ? ChartInk.focus : (c.day.value == maxV ? ChartInk.ink : ChartInk.ladder[2]))
            } else {
                ctx.dot(center, r: 0.7, ChartInk.faint)
            }
            if on {
                ctx.stroke(Path(ellipseIn: CGRect(x: center.x - g.cs * 0.62, y: center.y - g.cs * 0.62, width: g.cs * 1.24, height: g.cs * 1.24)),
                           with: .color(ChartInk.focus), lineWidth: 1)
            }
        }
        if progress >= 0.999, let peak = cells.max(by: { $0.day.value < $1.day.value }) {
            ctx.text("最多 \(peak.day.date.suffix(5)) · \(ChartMath.format(peak.day.value))\(card.unit)", .system(size: 8.5, weight: .semibold),
                     ChartInk.muted, at: CGPoint(x: size.width - 2, y: size.height), anchor: .bottomTrailing)
        }
    }

    // MARK: 点阵热力（F10）：面积 = 数，深浅四档，最大那格虚线圈

    private static func heat(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let rows = card.rows ?? [], cols = card.cols ?? [], values = card.values ?? []
        guard !rows.isEmpty, !cols.isEmpty else { return }
        let lx: CGFloat = 32, cw = (size.width - lx - 4) / CGFloat(cols.count), rh: CGFloat = 20
        let all = values.flatMap { $0 }.sorted(), maxV = all.last ?? 1
        let q = { (p: Double) in all[Int(p * Double(all.count - 1))] }
        let shade = { (v: Double) -> Color in v >= q(0.85) ? ChartInk.ladder[0] : v >= q(0.6) ? ChartInk.ladder[2] : v >= q(0.3) ? ChartInk.ladder[4] : ChartInk.ladder[5] }
        var peak: CGPoint?
        for (r, rn) in rows.enumerated() {
            ctx.text(shortLabel(rn, max: 4), .system(size: 8.5, weight: .semibold), ChartInk.muted, at: CGPoint(x: lx - 6, y: CGFloat(r) * rh + rh / 2), anchor: .trailing)
            for (c, cn) in cols.enumerated() {
                let v = values[r][c], center = CGPoint(x: lx + CGFloat(c) * cw + cw / 2, y: CGFloat(r) * rh + rh / 2)
                let local = ChartReveal.local(progress, index: r * cols.count + c, count: rows.count * cols.count, stagger: 0.6)
                let on = "\(rn) · \(cn)" == input.selected
                ctx.dot(center, r: max(ChartGeometry.areaRadius(v, max: maxV, maxRadius: min(cw, rh) * 0.46), 0.8) * CGFloat(local), on ? ChartInk.focus : shade(v))
                if v == maxV, peak == nil { peak = center }
            }
        }
        if progress >= 0.999, let p = peak {
            let r = min(cw, rh) * 0.6
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(ChartInk.ink),
                       style: StrokeStyle(lineWidth: 0.7, dash: [1.5, 1.5]))
        }
        let every = ChartGeometry.labelStride(count: cols.count, width: size.width - lx, minSpacing: 30)
        for (c, cn) in cols.enumerated() where c % every == 0 {
            ctx.text(cn, .system(size: 8.5, weight: .semibold), ChartInk.muted, at: CGPoint(x: lx + CGFloat(c) * cw + cw / 2, y: size.height), anchor: .bottom)
        }
    }

    // MARK: K 线（F17）：发丝影线 + 实体，空心 = 涨、实心 = 跌

    private static func candle(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let ks = card.candles ?? []
        guard !ks.isEmpty else { return }
        let lo = ks.map(\.low).min() ?? 0, hi = ks.map(\.high).max() ?? 1, pad = max((hi - lo) * 0.08, 1e-9)
        let top: CGFloat = 14, floor = size.height - 20, sw = size.width / CGFloat(ks.count), bw = max(2, min(sw * 0.56, 9))
        let y = { (v: Double) in top + (floor - top) * CGFloat(1 - (v - lo + pad) / (hi - lo + 2 * pad)) }
        for v in [lo, (lo + hi) / 2, hi] {
            ctx.line(CGPoint(x: 0, y: y(v)), CGPoint(x: size.width, y: y(v)), ChartInk.grid, width: 0.5)
            ctx.text(ChartMath.format(v), .system(size: 8, weight: .semibold), ChartInk.faint, at: CGPoint(x: size.width - 1, y: y(v) - 2), anchor: .bottomTrailing)
        }
        for (i, k) in ks.enumerated() where ChartReveal.local(progress, index: i, count: ks.count) > 0.5 {
            let x = sw * (CGFloat(i) + 0.5), on = k.label == input.selected, color = on ? ChartInk.focus : ChartInk.ink
            ctx.line(CGPoint(x: x, y: y(k.high)), CGPoint(x: x, y: y(k.low)), color, width: 0.7)
            let rect = CGRect(x: x - bw / 2, y: y(max(k.open, k.close)), width: bw, height: max(abs(y(k.open) - y(k.close)), 1))
            let body = Path(roundedRect: rect, cornerRadius: 0.6)
            ctx.fill(body, with: .color(k.rising ? Color(hex: 0xFFFDF9) : color))
            ctx.stroke(body, with: .color(color), lineWidth: 0.8)
        }
        axisLabels(ks.map(\.label), ctx, size, minSpacing: 42)
    }

    // MARK: 前后哑铃（F12）：空心 = 前、实心 = 后，中间串珠 = 真单位

    private static func dumbbell(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let pairs = card.pairs ?? []
        guard !pairs.isEmpty else { return }
        let lx: CGFloat = 66, rx = size.width - 18
        let maxV = (pairs.flatMap { [$0.before, $0.after] }.map(abs).max() ?? 1) * 1.05
        let x = { (v: Double) in lx + (rx - lx) * CGFloat(max(v, 0) / max(maxV, 1e-9)) }
        let unit = ChartGeometry.beadUnit(maxGap: pairs.map { abs($0.after - $0.before) }.max() ?? 0)
        let paper = Color(hex: 0xFFFDF9)
        for (r, p) in pairs.enumerated() {
            let yc = 10 + CGFloat(r) * 30 + 15, on = p.label == input.selected, color = on ? ChartInk.focus : ChartInk.ink
            let local = CGFloat(ChartReveal.local(progress, index: r, count: pairs.count))
            ctx.line(CGPoint(x: lx, y: yc), CGPoint(x: rx, y: yc), ChartInk.grid, width: 0.5)
            ctx.text(shortLabel(p.label, max: 5), ChartInk.axisFont, on ? ChartInk.ink : ChartInk.muted, at: CGPoint(x: lx - 8, y: yc), anchor: .trailing)
            let a = x(p.before), b = a + (x(p.after) - a) * local
            let beads = ChartGeometry.beads(gap: p.after - p.before, unit: unit)
            for k in stride(from: 1, through: beads, by: 1) {
                ctx.dot(CGPoint(x: a + (b - a) * CGFloat(k) / CGFloat(beads + 1), y: yc), r: 1.2, on ? ChartInk.focus : ChartInk.ladder[3])
            }
            let ring = Path(ellipseIn: CGRect(x: a - 4, y: yc - 4, width: 8, height: 8))
            ctx.fill(ring, with: .color(paper))
            ctx.stroke(ring, with: .color(color), lineWidth: 1.1)
            ctx.dot(CGPoint(x: b, y: yc), r: 4, color)
            if progress >= 0.999 {
                ctx.text(ChartMath.format(p.after), ChartInk.valueFont(), color, at: CGPoint(x: b, y: yc - 7), anchor: .bottom)
                ctx.text(ChartMath.format(p.before), .system(size: 9, weight: .semibold), ChartInk.muted, at: CGPoint(x: a, y: yc - 7), anchor: .bottom)
            }
        }
    }

    // MARK: 共用

    private static func axisLabels(_ cats: [String], _ ctx: GraphicsContext, _ size: CGSize, minSpacing: CGFloat) {
        guard !cats.isEmpty else { return }
        let sw = size.width / CGFloat(cats.count)
        let every = ChartGeometry.labelStride(count: cats.count, width: size.width, minSpacing: minSpacing)
        for (i, c) in cats.enumerated() where i % every == 0 {
            ctx.text(shortLabel(c), ChartInk.axisFont, ChartInk.muted, at: CGPoint(x: sw * (CGFloat(i) + 0.5), y: size.height), anchor: .bottom)
        }
    }
}
