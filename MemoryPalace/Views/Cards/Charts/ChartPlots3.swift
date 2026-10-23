import SwiftUI

// 图表卡 v2 第 3 批（docs/plan-chart-cards-v2.md）：scatter · histogram · box · waterfall · gauge · funnel · treemap。
// 画法照网页设计稿一比一搬，Canvas 自画；分发在 ChartDraw2.draw / hit 里。

extension ChartDraw2 {
    // MARK: 垂线散点（F8）：每个点垂一根发丝到地板，读 x 看线脚、读 y 看高度；最高 / 最低各标一个

    static func scatter(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let pts = card.scatter ?? []
        guard !pts.isEmpty else { return }
        let g = scatterFrame(pts, size)
        ctx.line(CGPoint(x: g.lx, y: g.floor), CGPoint(x: g.rx, y: g.floor), ChartInk.grid, width: 0.6)
        for t in 0...20 {
            let xx = g.lx + (g.rx - g.lx) * CGFloat(t) / 20
            ctx.line(CGPoint(x: xx, y: g.floor), CGPoint(x: xx, y: g.floor + (t % 5 == 0 ? 4 : 2)), ChartInk.faint, width: 0.6)
        }
        for (i, p) in pts.enumerated() {
            let local = CGFloat(ChartReveal.local(progress, index: i, count: pts.count)), on = p.label == input.selected
            let x = g.x(p.x), y = g.floor - (g.floor - g.y(p.y)) * local
            ctx.line(CGPoint(x: x, y: g.floor), CGPoint(x: x, y: y), on ? ChartInk.focus : ChartInk.grid, width: 0.7)
            ctx.dot(CGPoint(x: x, y: y), r: on ? 3.8 : 2.4, on ? ChartInk.focus : ChartInk.ink)
        }
        if progress >= 0.999 {
            let marks = [pts.max { $0.y < $1.y }, pts.min { $0.y < $1.y }].compactMap { $0 }
            for (k, p) in marks.enumerated() where k == 0 || p.label != marks[0].label {
                let x = g.x(p.x), anchor: UnitPoint = x > size.width - 60 ? .bottomTrailing : x < 60 ? .bottomLeading : .bottom
                ctx.text("\(shortLabel(p.label)) · \(ChartMath.format(p.y))", .system(size: 9, weight: .bold), ChartInk.ink,
                         at: CGPoint(x: x, y: g.y(p.y) - 6), anchor: anchor)
            }
        }
        ctx.text("← \(card.xLabel ?? "")低", .system(size: 8, weight: .semibold), ChartInk.faint, at: CGPoint(x: g.lx, y: size.height), anchor: .bottomLeading)
        ctx.text("\(card.xLabel ?? "")高 →", .system(size: 8, weight: .semibold), ChartInk.faint, at: CGPoint(x: g.rx, y: size.height), anchor: .bottomTrailing)
    }

    struct ScatterFrame {
        let lx: CGFloat, rx: CGFloat, top: CGFloat, floor: CGFloat
        let x0: Double, x1: Double, y1: Double
        func x(_ v: Double) -> CGFloat { lx + (rx - lx) * CGFloat((v - x0) / max(x1 - x0, 1e-9)) }
        func y(_ v: Double) -> CGFloat { floor - (floor - top) * CGFloat(max(v, 0) / max(y1, 1e-9)) }
    }

    static func scatterFrame(_ pts: [ChartCard.XY], _ size: CGSize) -> ScatterFrame {
        let xs = pts.map(\.x)
        let x0 = xs.min() ?? 0, x1 = xs.max() ?? 1
        return ScatterFrame(lx: 8, rx: size.width - 8, top: 18, floor: size.height - 20,
                            x0: x0, x1: x1 == x0 ? x0 + 1 : x1, y1: (pts.map(\.y).max() ?? 1) * 1.1)
    }

    // MARK: 梯格直方（F14）：柱挨着柱（分箱是连续的）

    static func histogram(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let pts = input.series.first?.points ?? []
        guard !pts.isEmpty else { return }
        let peak = pts.map(\.value).max() ?? 1, u = ChartGeometry.rungUnit(maxMagnitude: peak)
        let top: CGFloat = 16, floor = size.height - 18, step = (floor - top) / CGFloat(max(1, (peak / u).rounded(.up)))
        let sw = size.width / CGFloat(pts.count), lineW = min(1.3, step * 0.45)
        for (i, p) in pts.enumerated() {
            let on = p.label == input.selected, k = Int((p.value / u).rounded())
            let drawn = Int(Double(k) * ChartReveal.local(progress, index: i, count: pts.count))
            for r in 0..<drawn {
                let y = floor - step * (CGFloat(r) + 0.5)
                ctx.line(CGPoint(x: sw * CGFloat(i) + 1.5, y: y), CGPoint(x: sw * CGFloat(i + 1) - 1.5, y: y), on ? ChartInk.focus : ChartInk.ink, width: lineW)
            }
            if progress >= 0.999 {
                ctx.text(ChartMath.format(p.value), ChartInk.valueFont(9.5), on ? ChartInk.focus : ChartInk.ink,
                         at: CGPoint(x: sw * (CGFloat(i) + 0.5), y: floor - step * CGFloat(k) - 3), anchor: .bottom)
            }
        }
        ctx.line(CGPoint(x: 0, y: floor), CGPoint(x: size.width, y: floor), ChartInk.grid, width: 0.6)
        let every = ChartGeometry.labelStride(count: pts.count, width: size.width, minSpacing: 34)
        for (i, p) in pts.enumerated() where i % every == 0 {
            ctx.text(shortLabel(p.label, max: 5), .system(size: 8.5, weight: .semibold), ChartInk.muted, at: CGPoint(x: sw * (CGFloat(i) + 0.5), y: size.height), anchor: .bottom)
        }
    }

    // MARK: 刻度箱线（F15）：箱体由竖刻度排成，粗线 = 中位数，须线到 1.5 倍四分距，空心 = 离群

    static func box(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let groups = card.boxes ?? []
        guard !groups.isEmpty else { return }
        let all = groups.flatMap(\.values), mn = min(0, all.min() ?? 0), mx = (all.max() ?? 1) * 1.04
        let lx: CGFloat = 50, rx = size.width - 10, rowH: CGFloat = 30
        let x = { (v: Double) in lx + (rx - lx) * CGFloat((v - mn) / max(mx - mn, 1e-9)) }
        let paper = Color(hex: 0xFFFDF9)
        for (r, g) in groups.enumerated() where ChartReveal.local(progress, index: r, count: groups.count) > 0.3 {
            let s = ChartStats.five(g.values), yc = 6 + CGFloat(r) * rowH + rowH / 2, on = g.name == input.selected
            let color = on ? ChartInk.focus : ChartInk.ink
            ctx.text(shortLabel(g.name, max: 4), ChartInk.axisFont, on ? ChartInk.ink : ChartInk.muted, at: CGPoint(x: lx - 8, y: yc), anchor: .trailing)
            for (a, b) in [(s.low, s.q1), (s.q3, s.high)] { ctx.line(CGPoint(x: x(a), y: yc), CGPoint(x: x(b), y: yc), ChartInk.ladder[3], width: 0.7) }
            for v in [s.low, s.high] { ctx.line(CGPoint(x: x(v), y: yc - 4), CGPoint(x: x(v), y: yc + 4), ChartInk.ladder[3], width: 0.7) }
            var t = x(s.q1)
            while t <= x(s.q3) {
                ctx.line(CGPoint(x: t, y: yc - 7), CGPoint(x: t, y: yc + 7), on ? ChartInk.focus : ChartInk.ladder[4], width: 0.8)
                t += 3
            }
            ctx.line(CGPoint(x: x(s.median), y: yc - 10), CGPoint(x: x(s.median), y: yc + 10), color, width: 2.2)
            for o in s.outliers {
                let ring = Path(ellipseIn: CGRect(x: x(o) - 2.4, y: yc - 2.4, width: 4.8, height: 4.8))
                ctx.fill(ring, with: .color(paper))
                ctx.stroke(ring, with: .color(ChartInk.ladder[2]), lineWidth: 0.9)
            }
        }
        for t in 0...4 {
            let v = mn + (mx - mn) * Double(t) / 4
            ctx.text(ChartMath.format(v.rounded()), .system(size: 8, weight: .semibold), ChartInk.faint, at: CGPoint(x: x(v), y: size.height), anchor: .bottom)
        }
    }

    // MARK: 梯格瀑布（F9）：实线格 = 加，虚线格 = 减，台阶往下走，虚线连台阶

    static func waterfall(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let steps = ChartStats.waterfall(card)
        guard !steps.isEmpty else { return }
        let hi = steps.flatMap { [$0.from, $0.to] }.max() ?? 1, u = ChartGeometry.rungUnit(maxMagnitude: hi)
        let top: CGFloat = 18, floor = size.height - 18, step = (floor - top) / CGFloat(max(1, (hi / u).rounded(.up)))
        let sw = size.width / CGFloat(steps.count), cw = min(sw * 0.5, 30), lineW = min(1.3, step * 0.45)
        let y = { (v: Double) in floor - CGFloat(v / u) * step }
        for (i, s) in steps.enumerated() {
            let x0 = sw * CGFloat(i) + (sw - cw) / 2, on = s.label == input.selected
            let negative = s.kind == .delta && s.value < 0
            let a = min(s.from, s.to), b = max(s.from, s.to)
            let local = ChartReveal.local(progress, index: i, count: steps.count)
            var v = a
            while v < b - u / 2, (v - a) < (b - a) * local + u / 2 {
                let yy = y(v + u / 2)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x0, y: yy)); $0.addLine(to: CGPoint(x: x0 + cw, y: yy)) },
                           with: .color(on ? ChartInk.focus : ChartInk.ink),
                           style: StrokeStyle(lineWidth: lineW, dash: negative ? [1.2, 1.6] : []))
                v += u
            }
            if i < steps.count - 1, progress >= 0.999 {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x0 + cw, y: y(s.to))); $0.addLine(to: CGPoint(x: x0 + sw, y: y(s.to))) },
                           with: .color(ChartInk.faint), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
            }
            if progress >= 0.999 {
                ctx.text((s.kind == .delta && s.value > 0 ? "+" : "") + ChartMath.format(s.value), ChartInk.valueFont(9.5),
                         on ? ChartInk.focus : (negative ? ChartInk.muted : ChartInk.ink), at: CGPoint(x: x0 + cw / 2, y: y(b) - 3), anchor: .bottom)
            }
            ctx.text(shortLabel(s.label, max: 4), .system(size: 8.5, weight: .semibold), on ? ChartInk.ink : ChartInk.muted,
                     at: CGPoint(x: x0 + cw / 2, y: size.height), anchor: .bottom)
        }
        ctx.line(CGPoint(x: 0, y: floor), CGPoint(x: size.width, y: floor), ChartInk.grid, width: 0.6)
    }

    // MARK: 刻度表盘（F11）：半圈 100 根，一根 = 目标的 1%，墨到哪是进度

    static func gauge(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        guard let value = card.value, let target = card.target else { return }
        let pct = min(value / target, 1), on = input.selected != nil
        let c = CGPoint(x: size.width / 2, y: size.height - 30), r = min(size.width / 2 - 20, size.height - 40)
        let inked = Int((pct * 100 * ChartReveal.ease(progress)).rounded())
        for t in 0..<100 {
            let a = Double.pi * (1 + (Double(t) + 0.5) / 100), len: CGFloat = t % 10 == 0 ? 16 : 11
            let p0 = CGPoint(x: c.x + CGFloat(cos(a)) * (r - len), y: c.y + CGFloat(sin(a)) * (r - len))
            let p1 = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
            ctx.line(p0, p1, t < inked ? (on ? ChartInk.focus : ChartInk.ink) : ChartInk.ladder[6], width: 1.3)
        }
        for p in [0, 25, 50, 75, 100] {
            let a = Double.pi * (1 + Double(p) / 100)
            ctx.text("\(p)", .system(size: 7.5, weight: .semibold), ChartInk.faint,
                     at: CGPoint(x: c.x + CGFloat(cos(a)) * (r - 26), y: c.y + CGFloat(sin(a)) * (r - 26)), anchor: .center)
        }
        ctx.text("\(Int((value / target * 100).rounded()))%", ChartInk.valueFont(32), ChartInk.ink, at: CGPoint(x: c.x, y: c.y - 8), anchor: .bottom)
        let u = card.unit.isEmpty ? "" : " \(card.unit)"
        ctx.text("\(ChartMath.format(value)) / \(ChartMath.format(target))\(u)", .system(size: 10, weight: .semibold), ChartInk.muted,
                 at: CGPoint(x: c.x, y: c.y + 4), anchor: .top)
    }

    // MARK: 漏斗：一行一步，宽度 = 数（刻度横排、居中），右边写留下上一步的多少

    static func funnel(_ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let pts = input.series.first?.points ?? []
        guard let first = pts.first?.value, first > 0 else { return }
        let rowH = (size.height - 4) / CGFloat(pts.count), cx = size.width / 2 + 18, half = size.width - cx - 52
        for (r, p) in pts.enumerated() {
            let yc = 2 + CGFloat(r) * rowH + rowH / 2, on = p.label == input.selected
            let w = half * CGFloat(p.value / first) * CGFloat(ChartReveal.local(progress, index: r, count: pts.count))
            let n = max(1, Int((w / 2.6).rounded()))
            for t in 0..<n {
                let xx = cx - w + 2 * w * (CGFloat(t) + 0.5) / CGFloat(n)
                ctx.line(CGPoint(x: xx, y: yc - 7), CGPoint(x: xx, y: yc + 7), on ? ChartInk.focus : (r == 0 ? ChartInk.ink : ChartInk.ladder[2]), width: 0.8)
            }
            ctx.text(shortLabel(p.label, max: 5), ChartInk.axisFont, on ? ChartInk.ink : ChartInk.muted, at: CGPoint(x: cx - half - 10, y: yc), anchor: .trailing)
            if progress >= 0.999 {
                ctx.text(ChartMath.format(p.value), ChartInk.valueFont(), on ? ChartInk.focus : ChartInk.ink, at: CGPoint(x: cx + w + 6, y: yc), anchor: .leading)
                if r > 0, pts[r - 1].value > 0 {
                    ctx.text("\(Int((p.value / pts[r - 1].value * 100).rounded()))%", .system(size: 8.5, weight: .semibold), ChartInk.muted,
                             at: CGPoint(x: size.width - 2, y: yc), anchor: .trailing)
                }
            }
        }
    }

    // MARK: 矩形树（F13）：squarified，面积 = 值；组按大小取深浅，组内同一深浅；组名在格子上沿

    struct TreeCell {
        let label: String
        let item: String
        let value: Double
        let rect: CGRect
        let shade: Int
    }

    static func treeCells(_ card: ChartCard, _ size: CGSize) -> (groups: [(name: String, rect: CGRect)], cells: [TreeCell]) {
        let groups = card.tree ?? []
        let sums = groups.map { $0.items.map(\.value).reduce(0, +) }
        let outer = ChartStats.squarify(sums, in: CGRect(origin: .zero, size: size))
        let rank = groups.indices.sorted { sums[$0] > sums[$1] }
        var cells: [TreeCell] = []
        for (gi, g) in groups.enumerated() {
            let box = outer[gi], shade = [1, 3, 4, 5][min(rank.firstIndex(of: gi) ?? 3, 3)]
            let inner = CGRect(x: box.minX + 2, y: box.minY + 16, width: max(box.width - 4, 0), height: max(box.height - 18, 0))
            for (k, r) in ChartStats.squarify(g.items.map(\.value), in: inner).enumerated() {
                cells.append(TreeCell(label: "\(g.name) · \(g.items[k].label)", item: g.items[k].label, value: g.items[k].value, rect: r, shade: shade))
            }
        }
        return (groups.enumerated().map { ($0.element.name, outer[$0.offset]) }, cells)
    }

    static func treemap(_ card: ChartCard, _ input: ChartPlotInput, _ ctx: GraphicsContext, _ size: CGSize, _ progress: Double) {
        let layout = treeCells(card, size), paper = Color(hex: 0xFFFDF9)
        let alpha = ChartReveal.ease(progress)
        for g in layout.groups {
            ctx.text(shortLabel(g.name, max: 8), .system(size: 9, weight: .bold), ChartInk.ink, at: CGPoint(x: g.rect.minX + 4, y: g.rect.minY + 3), anchor: .topLeading)
        }
        for c in layout.cells {
            let on = c.label == input.selected, r = c.rect.insetBy(dx: 1, dy: 1)
            guard r.width > 0, r.height > 0 else { continue }
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color((on ? ChartInk.focus : ChartInk.ladder[c.shade]).opacity(alpha)))
            if r.width > 34, r.height > 24, progress >= 0.999 {
                let ink = c.shade <= 2 && !on ? paper : ChartInk.ink
                ctx.text(shortLabel(c.item, max: max(2, Int(r.width / 11))), .system(size: 9, weight: .semibold), ink, at: CGPoint(x: r.minX + 4, y: r.minY + 3), anchor: .topLeading)
                ctx.text(ChartMath.format(c.value), ChartInk.valueFont(9), ink, at: CGPoint(x: r.minX + 4, y: r.minY + 15), anchor: .topLeading)
            }
        }
    }
}
