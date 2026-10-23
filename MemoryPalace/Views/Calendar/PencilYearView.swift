import SwiftUI

// MARK: - 铅笔年视图：12 个迷你月（plan-calendar §九 P3，手机版）
// 3 列 × 4 行，每个月一张小铅笔格子；今天画圈，纪念日画闪星（p6）。点某个月回到那个月的月历。

struct PencilYearView: View {
    let year: Int
    /// dayKey → 档位 0...4
    let levels: [String: Int]
    let anniversaryKeys: Set<String>
    let seedKey: String
    /// 每个月有聊的天数（读屏用）
    var activeDaysByMonth: [Int: Int] = [:]
    var onSelectMonth: (Int) -> Void = { _ in }

    private let calendar = Calendar.current
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    struct Geometry {
        /// 21 格 + 2 个月间距（各 1.2 格）+ 左右边距（各 1 格）
        static let units: CGFloat = 25.4
        let cell: CGFloat, pad: CGFloat, gapX: CGFloat, title: CGFloat, rowH: CGFloat
        init(width: CGFloat) {
            cell = width / Self.units
            pad = cell
            gapX = cell * 1.2
            title = cell * 1.5
            rowH = title + cell * 6 + cell * 1.1
        }
        func origin(month m: Int) -> CGPoint {
            CGPoint(x: pad + CGFloat(m % 3) * (cell * 7 + gapX), y: pad + CGFloat(m / 3) * rowH)
        }
        var height: CGFloat { pad * 2 + rowH * 4 - cell * 1.1 }
    }

    var body: some View {
        Canvas { ctx, size in
            draw(in: &ctx, size: size)
        }
        .aspectRatio(Geometry.units / Geometry(width: Geometry.units).height, contentMode: .fit)
        .overlay {
            GeometryReader { geo in
                let g = Geometry(width: geo.size.width)
                // 还没到的月份不建按钮：画法和可点用同一个判定（plan-calendar-page 裁定 #6）
                ForEach(0..<12, id: \.self) { m in
                    if !Self.isFuture(month: m + 1, year: year, today: Date(), calendar: calendar) {
                        let o = g.origin(month: m)
                        Button { onSelectMonth(m + 1) } label: { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .frame(width: g.cell * 7, height: g.title + g.cell * 6)
                            .position(x: o.x + g.cell * 3.5, y: o.y + (g.title + g.cell * 6) / 2)
                            .accessibilityLabel("\(m + 1)月，有 \(activeDaysByMonth[m + 1] ?? 0) 天在聊")
                    }
                }
            }
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let g = Geometry(width: size.width)
        var rng = CalendarInk.Rand(seed: CalendarInk.seed(seedKey, "year", String(year)))
        let today = calendar.startOfDay(for: Date())
        let full = CGRect(origin: .zero, size: size)

        struct Month { let origin: CGPoint; let leading: Int; let days: Int; let rows: Int; let first: Date }
        let months: [Month] = (0..<12).compactMap { m in
            guard let first = calendar.date(from: DateComponents(year: year, month: m + 1, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
            let leading = calendar.component(.weekday, from: first) - 1
            let o = g.origin(month: m)
            return Month(origin: CGPoint(x: o.x, y: o.y + g.title), leading: leading, days: days,
                         rows: Int(ceil(Double(leading + days) / 7)), first: first)
        }

        // 月份名：能进的带 ›，还没到的 ink3 不带
        let future = (0..<12).map { Self.isFuture(month: $0 + 1, year: year, today: today, calendar: calendar) }
        for (m, mo) in months.enumerated() {
            ctx.draw(Text(Self.monthNames[m] + (future[m] ? "" : "  ›")).font(CalType.type(CalType.m))
                        .foregroundColor(future[m] ? CalInk.ink3 : CalInk.ink),
                     at: CGPoint(x: mo.origin.x, y: mo.origin.y - g.title * 0.45), anchor: .leading)
        }

        // 涂块
        ctx.drawLayer { layer in
            for mo in months {
                for d in 0..<mo.days {
                    guard let date = calendar.date(byAdding: .day, value: d, to: mo.first),
                          let fill = CalendarInk.rubFill(level: levels[DailyActivity.dayKey(date, calendar: calendar)] ?? 0) else { continue }
                    let i = mo.leading + d
                    let r = CGRect(x: mo.origin.x + CGFloat(i % 7) * g.cell, y: mo.origin.y + CGFloat(i / 7) * g.cell, width: g.cell, height: g.cell)
                    layer.fill(CalendarInk.rubPath(in: r.insetBy(dx: g.cell * 0.1, dy: g.cell * 0.1), amp: g.cell * 0.08, rng: &rng), with: .color(fill))
                }
            }
            CalendarInk.applyGrain(&layer, in: full)
        }

        // 格线（淡）；还没到的月份用装饰灰
        ctx.drawLayer { layer in
            var past = Path(), later = Path()
            for (idx, mo) in months.enumerated() {
                var lines = Path()
                let gh = CGFloat(mo.rows) * g.cell, gw = 7 * g.cell
                for i in 0...7 {
                    let x = mo.origin.x + CGFloat(i) * g.cell
                    lines.addPath(CalendarInk.pencilLine(from: CGPoint(x: x, y: mo.origin.y), to: CGPoint(x: x, y: mo.origin.y + gh),
                                                         amp: 0.6, segments: 3, overshoot: 1, rng: &rng))
                }
                for j in 0...mo.rows {
                    let y = mo.origin.y + CGFloat(j) * g.cell
                    lines.addPath(CalendarInk.pencilLine(from: CGPoint(x: mo.origin.x, y: y), to: CGPoint(x: mo.origin.x + gw, y: y),
                                                         amp: 0.6, segments: 4, overshoot: 1, rng: &rng))
                }
                if future[idx] { later.addPath(lines) } else { past.addPath(lines) }
            }
            layer.stroke(past, with: .color(CalendarInk.lineGray.opacity(0.6)), lineWidth: 0.6)
            layer.stroke(later, with: .color(CalInk.graphite.opacity(0.7)), lineWidth: 0.6)
            CalendarInk.applyGrain(&layer, in: full)
        }

        // 小点 / 闪星 / 今天
        ctx.drawLayer { layer in
            for mo in months {
                for d in 0..<mo.days {
                    guard let date = calendar.date(byAdding: .day, value: d, to: mo.first) else { continue }
                    let key = DailyActivity.dayKey(date, calendar: calendar)
                    let lv = levels[key] ?? 0
                    let i = mo.leading + d
                    let c = CGPoint(x: mo.origin.x + (CGFloat(i % 7) + 0.5) * g.cell, y: mo.origin.y + (CGFloat(i / 7) + 0.5) * g.cell)
                    if lv == 1 {
                        let rr = g.cell * 0.08
                        layer.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(CalendarInk.graphite))
                    }
                    if anniversaryKeys.contains(key) {
                        layer.stroke(CalendarInk.sparkle(center: c, radius: g.cell * 0.38),
                                     with: .color(lv >= 3 ? CalendarInk.chalk : CalendarInk.graphite), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                    }
                    if calendar.isDate(date, inSameDayAs: today) {
                        layer.stroke(Path(ellipseIn: CGRect(x: c.x - g.cell * 0.42, y: c.y - g.cell * 0.42, width: g.cell * 0.84, height: g.cell * 0.84)),
                                     with: .color(CalendarInk.graphite), lineWidth: 0.9)
                    }
                }
            }
            CalendarInk.applyGrain(&layer, in: full)
        }
    }
}

extension PencilYearView {
    /// 这个月整个在今天之后（按年月比，不按日）
    static func isFuture(month: Int, year: Int, today: Date, calendar: Calendar) -> Bool {
        let t = calendar.dateComponents([.year, .month], from: today)
        return (year, month) > (t.year ?? 0, t.month ?? 0)
    }
}

/// 几点最爱聊：星期 × 小时的铅笔点（大小 / 深浅 = 条数）
struct PencilPunchCard: View {
    let grid: [[Int]]

    private static let weekdays = ["m", "t", "w", "t", "f", "s", "s"]

    var body: some View {
        let maxV = max(1, grid.flatMap { $0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("").frame(width: 16)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 6 == 0 ? "\(h)" : "").font(CalType.type(CalType.m)).foregroundColor(CalInk.ink3).fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<7, id: \.self) { w in
                HStack(spacing: 0) {
                    Text(Self.weekdays[w]).font(CalType.type(CalType.m)).foregroundColor(CalInk.ink3).frame(width: 16, alignment: .leading)
                    Canvas { ctx, size in
                        let cw = size.width / 24
                        for h in 0..<24 {
                            let v = grid[w][h]
                            let t = Double(v) / Double(maxV)
                            let r = v == 0 ? 0.8 : 1.4 + CGFloat(t) * min(cw, size.height) * 0.36
                            let c = CGPoint(x: (CGFloat(h) + 0.5) * cw, y: size.height / 2)
                            let color = v == 0 ? CalendarInk.graphite.opacity(0.18) : CalendarInk.graphite.opacity(0.35 + 0.6 * t)
                            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
                        }
                    }
                    .frame(height: 14)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("几点最爱聊")
    }
}
