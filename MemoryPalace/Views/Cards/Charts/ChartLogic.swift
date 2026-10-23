import Foundation
import CoreGraphics

// 图表卡 v2 的纯函数（docs/plan-chart-cards-v2.md）：试算、几何、控件。画法学 lieflat-charts 的 Mono 语法
// （PolyForm Noncommercial，只学规矩不拷代码）——单位可数、刻度一共 100、柱不断轴。

/// 试算：参数 + 公式 → 系列（对方拖滑块就重算）
enum ChartTrial {
    static func defaults(_ card: ChartCard) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: (card.params ?? []).map { ($0.key, $0.snapped($0.value)) })
    }

    static func series(_ card: ChartCard, values: [String: Double]) -> [ChartCard.Series] {
        guard let formulas = card.formulas, let axis = card.x else { return card.series }
        let keys = Set((card.params ?? []).map(\.key)).union(["x"])
        let xs = axis.values
        return formulas.map { f in
            guard let formula = ChartFormula(f.y, variables: keys) else { return ChartCard.Series(name: f.name, points: []) }
            var seen = Set<String>()
            let points: [ChartCard.Point] = xs.compactMap { x in
                var vars = values
                vars["x"] = x
                guard let y = formula.evaluate(vars) else { return nil }   // 除零 / 溢出的点不画
                let text = Self.label(for: x, template: axis.label)
                guard seen.insert(text).inserted else { return nil }
                return ChartCard.Point(label: text, value: y)
            }
            return ChartCard.Series(name: f.name, points: points)
        }
    }

    static func label(for x: Double, template: String?) -> String {
        let number = ChartMath.format(x)
        guard let template, template.contains("{x}") else { return number }
        return template.replacingOccurrences(of: "{x}", with: number)
    }
}

enum ChartGeometry {
    /// 梯格柱一格代表多少：1 / 2 / 5 × 10ⁿ 里最小的、让最高那根不超过 40 格（于是至少 16 格，能数）
    static func rungUnit(maxMagnitude: Double) -> Double {
        guard maxMagnitude.isFinite, maxMagnitude > 0 else { return 1 }
        var exponent = (log10(maxMagnitude / 40)).rounded(.down)
        while true {
            for m in [1.0, 2, 5] {
                let u = m * pow(10, exponent)
                if maxMagnitude / u <= 40 + 1e-9 { return clean(u) }
            }
            exponent += 1
        }
    }

    /// 0.1 + 0.1 这类浮点尾巴去掉（显示「一格 = 0.2」而不是 0.20000000000000001）
    private static func clean(_ v: Double) -> Double { Double(String(format: "%.10g", v)) ?? v }

    /// 刻度环：100 格按占比分给各段（最大余数法，一共正好 100）
    static func ringTicks(_ values: [Double]) -> [Int] {
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0 else { return values.map { _ in 0 } }
        let exact = values.map { max($0, 0) / total * 100 }
        var ticks = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - Double(ticks[$0])) > (exact[$1] - Double(ticks[$1])) }
        for i in order.prefix(100 - ticks.reduce(0, +)) { ticks[i] += 1 }
        return ticks
    }

    /// 第几格（0…99）属于哪一段
    static func ringSegment(atTick tick: Int, ticks: [Int]) -> Int? {
        var acc = 0
        for (i, n) in ticks.enumerated() {
            acc += n
            if tick < acc { return i }
        }
        return nil
    }

    /// 横向等分 count 个槽，x 落在哪个槽
    static func slot(at x: CGFloat, plot: ClosedRange<CGFloat>, count: Int) -> Int? {
        let width = plot.upperBound - plot.lowerBound
        guard count > 0, width > 0, plot.contains(x) else { return nil }
        return min(count - 1, Int((x - plot.lowerBound) / width * CGFloat(count)))
    }

    /// 标签每隔几个出一个（1 / 2 / 5 / 10 …），保证相邻标签不挤
    static func labelStride(count: Int, width: CGFloat, minSpacing: CGFloat) -> Int {
        guard count > 0, width > 0 else { return 1 }
        let need = Int((minSpacing / (width / CGFloat(count))).rounded(.up))
        return [1, 2, 5, 10, 15, 20, 30, 50].first { $0 >= need } ?? need
    }

    /// 面积编码：半径按 √ 换算（值翻四倍，点只大一倍）
    static func areaRadius(_ v: Double, max: Double, maxRadius: CGFloat) -> CGFloat {
        guard max > 0, v > 0 else { return 0 }
        return CGFloat((v / max).squareRoot()) * maxRadius
    }

    /// 哑铃中间一颗串珠代表多少：最宽那行不超过 10 颗
    static func beadUnit(maxGap: Double) -> Double {
        guard maxGap.isFinite, maxGap > 0 else { return 1 }
        var exponent = (log10(maxGap / 10)).rounded(.down)
        while true {
            for m in [1.0, 2, 5] {
                let u = m * pow(10, exponent)
                if maxGap / u <= 10 + 1e-9 { return Double(String(format: "%.10g", u)) ?? u }
            }
            exponent += 1
        }
    }

    /// 两端之间的串珠（真单位，不含两端两颗），最多 20 颗
    static func beads(gap: Double, unit: Double) -> Int {
        guard unit > 0, gap.isFinite else { return 0 }
        return min(20, max(0, Int((abs(gap) / unit).rounded()) - 1))
    }

    /// 没写 subtitle 时按图型给一句「怎么读」
    static func autoSubtitle(_ card: ChartCard, series: [ChartCard.Series]) -> String {
        if !card.subtitle.isEmpty { return card.subtitle }
        let peak = series.flatMap { $0.points.map { abs($0.value) } }.max() ?? 0
        let unitText = { (u: Double) in card.unit.isEmpty ? ChartMath.format(u) : "\(ChartMath.format(u)) \(card.unit)" }
        switch card.type {
        case .bar:
            return "一格 = \(unitText(rungUnit(maxMagnitude: peak)))"
        case .stack:
            let totals = ChartReadings.labels(card, series: series).map { l in series.compactMap { s in s.points.first { $0.label == l }?.value }.reduce(0, +) }
            return "一格 = \(unitText(rungUnit(maxMagnitude: totals.max() ?? 0)))"
        case .hbar, .diverging:
            return "一根刻度 = \(unitText(rungUnit(maxMagnitude: peak)))"
        case .pie, .donut:
            return "一圈 100 格 · 一格 = 1%"
        case .hundred:
            return "一百个点 · 一点 = 1%"
        case .area:
            return "一根竖线 = 一个读数"
        case .barcode:
            return "一根 = 一个读数"
        case .calendar:
            return "一列 = 一周 · 点的面积 = 数"
        case .heat:
            return "点的面积 = 数 · 虚线圈 = 最多那格"
        case .candle:
            return "空心 = 涨 · 实心 = 跌"
        case .dumbbell:
            let names = card.pairNames ?? ["之前", "之后"]
            let gap = (card.pairs ?? []).map { abs($0.after - $0.before) }.max() ?? 0
            return "空心 = \(names[0]) · 实心 = \(names[1]) · 中间一颗 = \(unitText(beadUnit(maxGap: gap)))"
        case .histogram:
            return "一格 = \(unitText(rungUnit(maxMagnitude: peak)))"
        case .waterfall:
            let top = ChartStats.waterfall(card).flatMap { [abs($0.from), abs($0.to)] }.max() ?? 0
            return "一格 = \(unitText(rungUnit(maxMagnitude: top))) · 实线 = 加 · 虚线 = 减"
        case .scatter:
            return "每个点垂一根线：看线脚读\(card.xLabel ?? "横轴")、看高度读\(card.yLabel ?? "纵轴")"
        case .box:
            return "粗线 = 中位数 · 刻度块 = 中间一半 · 空心 = 离群"
        case .gauge:
            return "一根刻度 = 目标的 1%"
        case .funnel:
            return "每一步留下了上一步的多少"
        case .treemap:
            return "面积 = 值 · 同组同一深浅"
        case .line, .stream:
            return ""
        }
    }
}

/// 图表当控件用：开关系列、切范围、选中后「问问这个」
enum ChartControls {
    /// 点多了才给范围档：只给比点数少的
    static func rangeOptions(count: Int) -> [Int?] {
        guard count > 12 else { return [] }
        return [7, 30, 90].filter { $0 < count }.map { Optional($0) } + [nil]
    }

    /// 只留全部类目里的最后 last 个（多条系列按同一组类目对齐）
    static func applyRange(_ series: [ChartCard.Series], last: Int?) -> [ChartCard.Series] {
        guard let last else { return series }
        var order: [String] = []
        var seen = Set<String>()
        for s in series { for p in s.points where seen.insert(p.label).inserted { order.append(p.label) } }
        let keep = Set(order.suffix(last))
        return series.map { ChartCard.Series(name: $0.name, points: $0.points.filter { keep.contains($0.label) }) }
    }

    /// 开关一条系列；最后一条关不掉
    static func toggle(_ hidden: Set<Int>, series i: Int, total: Int) -> Set<Int> {
        if hidden.contains(i) { return hidden.subtracting([i]) }
        return hidden.count + 1 >= total ? hidden : hidden.union([i])
    }

    /// 选中那一项的读数：（系列名, 「5.4 小时」），关掉的系列不算
    static func rows(_ series: [ChartCard.Series], label: String, unit: String, hidden: Set<Int>) -> [(name: String, text: String)] {
        series.enumerated().compactMap { i, s in
            guard !hidden.contains(i), let v = s.points.first(where: { $0.label == label })?.value else { return nil }
            return (s.name, unit.isEmpty ? ChartMath.format(v) : "\(ChartMath.format(v)) \(unit)")
        }
    }

    static func paramSummary(_ card: ChartCard, values: [String: Double]) -> [String] {
        (card.params ?? []).map { p in
            let v = ChartMath.format(values[p.key] ?? p.snapped(p.value))
            return p.unit.map { "\(p.label) \(v) \($0)" } ?? "\(p.label) \(v)"
        }
    }

    /// 「问问这个」引用进输入框的那句
    static func quote(card: ChartCard, label: String, rows: [(name: String, text: String)], params: [String]) -> String {
        let head = card.title.isEmpty ? "图表 " : "图表「\(card.title)」"   // 」后面不再空一格
        let body = rows.map { $0.name.isEmpty ? $0.text : "\($0.name) \($0.text)" }.joined(separator: "，")
        let tail = params.isEmpty ? "" : "（参数：\(params.joined(separator: "，"))）"
        return "\(head)· \(label)：\(body)\(tail)"
    }
}

/// 日历热力的排布：一列 = 一周（周一在最上面），第一天所在那周是第 0 列
enum ChartCalendar {
    struct Cell: Equatable {
        let day: ChartCard.Day
        let row: Int
        let column: Int
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func cells(_ days: [ChartCard.Day]) -> [Cell] {
        let dated = days.compactMap { d in ChartCard.Day.parse(d.date).map { (d, $0) } }.sorted { $0.1 < $1.1 }
        guard let first = dated.first?.1 else { return [] }
        let row = { (date: Date) in (calendar.component(.weekday, from: date) + 5) % 7 }
        let monday = calendar.date(byAdding: .day, value: -row(first), to: first) ?? first
        return dated.map { d, date in
            let offset = calendar.dateComponents([.day], from: monday, to: date).day ?? 0
            return Cell(day: d, row: row(date), column: offset / 7)
        }
    }

    static func columnCount(_ cells: [Cell]) -> Int { (cells.map(\.column).max() ?? -1) + 1 }

    /// 第几列是不是一个月的第一周（标月份用）：返回（列, 「3月」）
    static func monthStarts(_ cells: [Cell]) -> [(column: Int, label: String)] {
        var out: [(Int, String)] = []
        var lastMonth = -1
        for c in cells {
            guard let d = ChartCard.Day.parse(c.day.date) else { continue }
            let m = calendar.component(.month, from: d)
            if m != lastMonth, out.last?.0 != c.column {
                out.append((c.column, "\(m)月"))
                lastMonth = m
            }
        }
        return out
    }
}

/// 选中一项的读数（选中行 / 问问这个 / 读屏共用）：系列图按类目，其余按各自的标签
enum ChartReadings {
    static func labels(_ card: ChartCard, series: [ChartCard.Series]) -> [String] {
        switch card.type {
        case .calendar: return (card.days ?? []).map(\.date)
        case .heat:
            let rows = card.rows ?? [], cols = card.cols ?? []
            return rows.flatMap { r in cols.map { "\(r) · \($0)" } }
        case .candle: return (card.candles ?? []).map(\.label)
        case .dumbbell: return (card.pairs ?? []).map(\.label)
        case .scatter: return (card.scatter ?? []).map(\.label)
        case .box: return (card.boxes ?? []).map(\.name)
        case .gauge: return ["进度"]
        case .treemap: return (card.tree ?? []).flatMap { g in g.items.map { "\(g.name) · \($0.label)" } }
        case .waterfall: return ChartStats.waterfall(card).map(\.label)
        default:
            var seen = Set<String>()
            var out: [String] = []
            for s in series { for p in s.points where seen.insert(p.label).inserted { out.append(p.label) } }
            return out
        }
    }

    static func rows(_ card: ChartCard, series: [ChartCard.Series], label: String, hidden: Set<Int>) -> [(name: String, text: String)] {
        let withUnit = { (v: Double) in card.unit.isEmpty ? ChartMath.format(v) : "\(ChartMath.format(v)) \(card.unit)" }
        switch card.type {
        case .calendar:
            return (card.days ?? []).first { $0.date == label }.map { [("", withUnit($0.value))] } ?? []
        case .heat:
            let rows = card.rows ?? [], cols = card.cols ?? []
            for (r, rn) in rows.enumerated() {
                for (c, cn) in cols.enumerated() where "\(rn) · \(cn)" == label {
                    return [("", withUnit(card.values?[r][c] ?? 0))]
                }
            }
            return []
        case .candle:
            guard let k = (card.candles ?? []).first(where: { $0.label == label }) else { return [] }
            let f = ChartMath.format
            return [("", "开 \(f(k.open)) · 高 \(f(k.high)) · 低 \(f(k.low)) · 收 \(f(k.close))")]
        case .dumbbell:
            guard let p = (card.pairs ?? []).first(where: { $0.label == label }) else { return [] }
            let names = card.pairNames ?? ["之前", "之后"]
            return [("", "\(names[0]) \(withUnit(p.before)) → \(names[1]) \(withUnit(p.after))")]
        case .hundred:
            let points = series.first?.points ?? []
            let ticks = ChartGeometry.ringTicks(points.map(\.value))
            guard let i = points.firstIndex(where: { $0.label == label }) else { return [] }
            return [("", "\(withUnit(points[i].value))（\(ticks[i]) 格）")]
        case .scatter:
            guard let p = (card.scatter ?? []).first(where: { $0.label == label }) else { return [] }
            return [("", "\(card.xLabel ?? "x") \(ChartMath.format(p.x)) · \(card.yLabel ?? "y") \(ChartMath.format(p.y))")]
        case .box:
            guard let g = (card.boxes ?? []).first(where: { $0.name == label }) else { return [] }
            let s = ChartStats.five(g.values)
            return [("", "中位 \(withUnit(s.median)) · 中间一半 \(ChartMath.format(s.q1))–\(ChartMath.format(s.q3)) · \(g.values.count) 个")]
        case .gauge:
            guard let v = card.value, let t = card.target else { return [] }
            return [("", "\(withUnit(v)) / \(withUnit(t))（\(Int((v / t * 100).rounded()))%）")]
        case .treemap:
            let total = (card.tree ?? []).flatMap(\.items).map(\.value).reduce(0, +)
            for g in card.tree ?? [] {
                if let it = g.items.first(where: { "\(g.name) · \($0.label)" == label }) {
                    return [("", "\(withUnit(it.value))（占 \(Int((it.value / max(total, 1e-9) * 100).rounded()))%）")]
                }
            }
            return []
        case .waterfall:
            guard let step = ChartStats.waterfall(card).first(where: { $0.label == label }) else { return [] }
            let sign = step.kind == .delta && step.value > 0 ? "+" : ""
            return [("", sign + withUnit(step.value))]
        case .funnel:
            let pts = series.first?.points ?? []
            guard let i = pts.firstIndex(where: { $0.label == label }) else { return [] }
            guard i > 0, pts[i - 1].value > 0 else { return [("", withUnit(pts[i].value))] }
            return [("", "\(withUnit(pts[i].value)) · 留下上一步的 \(Int((pts[i].value / pts[i - 1].value * 100).rounded()))%")]
        case .stack:
            var out = ChartControls.rows(series, label: label, unit: card.unit, hidden: hidden)
            let total = series.enumerated().compactMap { i, s in hidden.contains(i) ? nil : s.points.first { $0.label == label }?.value }.reduce(0, +)
            if out.count > 1 { out.append(("合计", withUnit(total))) }
            return out
        default:
            return ChartControls.rows(series, label: label, unit: card.unit, hidden: hidden)
        }
    }
}

/// 第 3 批的统计 / 布局（纯函数，可测）
enum ChartStats {
    struct Five: Equatable {
        let low: Double, q1: Double, median: Double, q3: Double, high: Double
        let outliers: [Double]
    }

    /// 五数概括：四分位按线性插值；须线到 1.5 倍四分距内最远的那个值，之外的是离群
    static func five(_ values: [Double]) -> Five {
        let s = values.sorted()
        guard !s.isEmpty else { return Five(low: 0, q1: 0, median: 0, q3: 0, high: 0, outliers: []) }
        func q(_ p: Double) -> Double {
            let i = Double(s.count - 1) * p, lo = Int(i.rounded(.down)), hi = Int(i.rounded(.up))
            return s[lo] + (s[hi] - s[lo]) * (i - Double(lo))
        }
        let q1 = q(0.25), q3 = q(0.75), iqr = q3 - q1
        let low = s.first { $0 >= q1 - 1.5 * iqr } ?? s[0]
        let high = s.last { $0 <= q3 + 1.5 * iqr } ?? s[s.count - 1]
        return Five(low: low, q1: q1, median: q(0.5), q3: q3, high: high, outliers: s.filter { $0 < low || $0 > high })
    }

    struct Step: Equatable {
        enum Kind { case start, delta, total }
        let label: String
        let value: Double
        let from: Double
        let to: Double
        let kind: Kind
    }

    /// 瀑布：第一项是起点，之后带符号增减；给了 total 末尾补一根合计
    static func waterfall(_ card: ChartCard) -> [Step] {
        var run = 0.0
        var out: [Step] = []
        for (i, p) in (card.series.first?.points ?? []).enumerated() {
            let from = i == 0 ? 0 : run
            run = i == 0 ? p.value : run + p.value
            out.append(Step(label: p.label, value: p.value, from: from, to: run, kind: i == 0 ? .start : .delta))
        }
        if let total = card.total, !out.isEmpty { out.append(Step(label: total, value: run, from: 0, to: run, kind: .total)) }
        return out
    }

    /// squarified 矩形树（Bruls 等）：按值降序一排一排铺，挑长宽比最接近 1 的切法。返回顺序同输入
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let order = values.indices.sorted { values[$0] > values[$1] }
        var out = [CGRect](repeating: .zero, count: values.count)
        var free = rect
        var row: [Int] = []
        func area(_ i: Int) -> Double { max(values[i], 0) * scale }
        func worst(_ r: [Int], _ side: Double) -> Double {
            let s = r.map(area).reduce(0, +), mx = r.map(area).max() ?? 0, mn = r.map(area).min() ?? 0
            guard s > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }
        func lay(_ r: [Int]) {
            let s = r.map(area).reduce(0, +)
            if free.width >= free.height {
                let w = CGFloat(s / Double(free.height))
                var y = free.minY
                for i in r { let h = CGFloat(area(i)) / w; out[i] = CGRect(x: free.minX, y: y, width: w, height: h); y += h }
                free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
            } else {
                let h = CGFloat(s / Double(free.width))
                var x = free.minX
                for i in r { let w = CGFloat(area(i)) / h; out[i] = CGRect(x: x, y: free.minY, width: w, height: h); x += w }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
            }
        }
        var rest = order[...]
        while let next = rest.first {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [next], side) <= worst(row, side) {
                row.append(next)
                rest = rest.dropFirst()
            } else {
                lay(row)
                row = []
            }
        }
        if !row.isEmpty { lay(row) }
        return out
    }
}
