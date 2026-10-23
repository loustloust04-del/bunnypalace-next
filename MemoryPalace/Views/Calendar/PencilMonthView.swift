import SwiftUI

// MARK: - 铅笔月历（plan-calendar §三，参考 p4）
// 一张 Canvas：纸 → 涂块 → 格线 → 手写数字 → 小点 / 涂鸦。只吃 `PencilMonthDay`，不碰数据层。

struct PencilMonthDay: Equatable, Sendable {
    /// 0 没聊 · 1 聊一点（小点）· 2 浅灰 · 3 深灰 · 4 涂黑
    var level: Int = 0
    var doodle: CalendarInk.Doodle?
    /// 经期：格子右下角一个很小的玫瑰点（亲密记录不进日历）
    var periodMark = false
    /// 待办：nil 没有 / false 有没做完的 / true 全做完（右上角铅笔小方框，不占「一格只画一个」）
    var todo: Bool?
}

struct PencilMonthView: View {
    /// 这个月里任意一天
    let month: Date
    /// key = 日（1...31）
    let days: [Int: PencilMonthDay]
    let selected: Date?
    /// 种子前缀（楼层 id）：同一楼层同一个月每次画得一样
    let seedKey: String
    var showLightDots = true
    /// 读屏念的附加信息（例如「聊了 186 条」）
    var accessibilityDetail: (Int) -> String = { _ in "" }
    var onSelect: (Date) -> Void = { _ in }

    private let calendar = Calendar.current
    private static let weekdayLetters = ["s", "m", "t", "w", "t", "f", "s"]
    private static let rose = Color(red: 0.788, green: 0.541, blue: 0.541)

    private var layout: Layout { Layout(month: month, calendar: calendar) }

    var body: some View {
        let lay = layout
        Canvas { ctx, size in
            draw(in: &ctx, size: size, lay: lay)
        }
        .aspectRatio(Layout.aspect(rows: lay.rows), contentMode: .fit)
        // 命中 + 无障碍：每天一个透明按钮，和绘制共用同一份格子几何（astra #15）
        .overlay {
            GeometryReader { geo in
                let m = lay.metrics(width: geo.size.width)
                ForEach(1...lay.daysInMonth, id: \.self) { d in
                    let r = m.cellRect(lay.index(ofDay: d))
                    let date = calendar.date(byAdding: .day, value: d - 1, to: lay.firstOfMonth) ?? lay.firstOfMonth
                    let isSelected = selected.map { calendar.isDate($0, inSameDayAs: date) } ?? false
                    Button { onSelect(date) } label: { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .accessibilityLabel(Text(date, format: .dateTime.month().day()) + Text(accessibilityDetail(d)))
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: 绘制

    private func draw(in ctx: inout GraphicsContext, size: CGSize, lay: Layout) {
        let m = lay.metrics(width: size.width)
        var rng = CalendarInk.Rand(seed: CalendarInk.seed(seedKey, lay.monthKey))
        let today = calendar.startOfDay(for: Date())

        // 底色透明：整页已经是纸（plan-calendar-page 裁定 #10）

        // 星期：打字机小写
        for i in 0..<7 {
            ctx.draw(Text(Self.weekdayLetters[i]).font(CalType.type(CalType.m)).foregroundColor(CalInk.ink3),
                     at: CGPoint(x: m.x0 + (CGFloat(i) + 0.5) * m.cell, y: m.y0 - m.cell * 0.3), anchor: .center)
        }

        // 涂块（铅笔颗粒）
        ctx.drawLayer { layer in
            for d in 1...lay.daysInMonth {
                guard let fill = CalendarInk.rubFill(level: days[d]?.level ?? 0) else { continue }
                let r = m.cellRect(lay.index(ofDay: d))
                let inset = m.cell * 0.05 + rng.next() * m.cell * 0.05
                layer.fill(CalendarInk.rubPath(in: r.insetBy(dx: inset, dy: inset), amp: m.cell * 0.045, rng: &rng), with: .color(fill))
            }
            CalendarInk.applyGrain(&layer, in: CGRect(origin: .zero, size: size))
        }

        // 格线
        ctx.drawLayer { layer in
            let gw = m.cell * 7, gh = m.cell * CGFloat(lay.rows)
            var lines = Path()
            for i in 0...7 {
                let x = m.x0 + CGFloat(i) * m.cell + rng.jitter(2)
                lines.addPath(CalendarInk.pencilLine(from: CGPoint(x: x, y: m.y0), to: CGPoint(x: x + rng.jitter(2), y: m.y0 + gh), rng: &rng))
            }
            for j in 0...lay.rows {
                let y = m.y0 + CGFloat(j) * m.cell + rng.jitter(2)
                lines.addPath(CalendarInk.pencilLine(from: CGPoint(x: m.x0, y: y), to: CGPoint(x: m.x0 + gw, y: y + rng.jitter(2)), segments: 7, rng: &rng))
            }
            layer.stroke(lines, with: .color(CalendarInk.lineGray.opacity(0.9)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            CalendarInk.applyGrain(&layer, in: CGRect(origin: .zero, size: size))
        }

        // 数字 / 小点 / 涂鸦 / 经期点 / 今天
        ctx.drawLayer { layer in
            for d in 1...lay.daysInMonth {
                let info = days[d] ?? PencilMonthDay()
                let r = m.cellRect(lay.index(ofDay: d))
                let dark = info.level >= 3
                layer.draw(Text("\(d)").font(CalType.hand(CalType.s))
                            .foregroundColor(dark ? CalendarInk.chalk : CalendarInk.graphite),
                           at: m.numberOrigin(r), anchor: .topLeading)
                let center = CGPoint(x: r.minX + m.cell * 0.55, y: r.minY + m.cell * 0.6)
                if let doodle = info.doodle {
                    CalendarInk.draw(doodle, in: &layer, center: center, h: m.cell * 0.26, dark: dark, rng: &rng)
                } else if info.level == 1, showLightDots {
                    let rr = m.cell * 0.045
                    layer.fill(Path(ellipseIn: CGRect(x: center.x - rr + rng.jitter(3), y: center.y - rr + rng.jitter(3), width: rr * 2, height: rr * 2)),
                               with: .color(CalendarInk.graphite))
                }
                if info.periodMark {
                    let rr = m.cell * 0.035
                    layer.fill(Path(ellipseIn: CGRect(x: r.maxX - m.cell * 0.14 - rr, y: r.maxY - m.cell * 0.14 - rr, width: rr * 2, height: rr * 2)),
                               with: .color(Self.rose))
                }
                if let date = calendar.date(byAdding: .day, value: d - 1, to: lay.firstOfMonth), calendar.isDate(date, inSameDayAs: today) {
                    let o = m.numberOrigin(r), y = o.y + 16
                    layer.stroke(CalendarInk.pencilLine(from: CGPoint(x: o.x - 1, y: y), to: CGPoint(x: o.x + 16, y: y),
                                                        amp: 0.8, segments: 3, overshoot: 0, rng: &rng),
                                 with: .color(dark ? CalendarInk.chalk : CalendarInk.graphite), lineWidth: 1)
                }
            }
            // 待办：右上角铅笔小方框，全做完打勾
            for d in 1...lay.daysInMonth {
                guard let done = days[d]?.todo else { continue }
                let r = m.cellRect(lay.index(ofDay: d))
                let dark = (days[d]?.level ?? 0) >= 3
                Self.drawTodoBox(in: &layer, at: CGPoint(x: r.maxX - m.cell * 0.1 - 9, y: r.minY + m.cell * 0.1), done: done,
                                 color: dark ? CalendarInk.chalk : CalInk.ink2, rng: &rng)
            }
            // 选中日：铅笔圈圈住日期数字（今天仍是下划线）
            if let selected, calendar.isDate(selected, equalTo: lay.firstOfMonth, toGranularity: .month) {
                let d = calendar.component(.day, from: selected)
                let r = m.cellRect(lay.index(ofDay: d))
                var ringRng = CalendarInk.Rand(seed: CalendarInk.seed(seedKey, lay.monthKey, "ring", String(d)))
                layer.stroke(PencilRing.path(around: m.ringRect(r), rng: &ringRng),
                             with: .color((days[d]?.level ?? 0) >= 3 ? CalendarInk.chalk : CalInk.ink), lineWidth: 1.1)
            }
            CalendarInk.applyGrain(&layer, in: CGRect(origin: .zero, size: size))
        }
    }

    /// 9pt 的铅笔小方框（月历 / 星孔卡 / 图例共用）
    static func drawTodoBox(in ctx: inout GraphicsContext, at o: CGPoint, done: Bool, color: Color, rng: inout CalendarInk.Rand) {
        ctx.stroke(CalendarInk.rubPath(in: CGRect(x: o.x, y: o.y, width: 9, height: 9), amp: 0.6, rng: &rng), with: .color(color), lineWidth: 1)
        if done {
            var tick = Path()
            tick.move(to: CGPoint(x: o.x + 1.8, y: o.y + 4.6))
            tick.addLine(to: CGPoint(x: o.x + 3.9, y: o.y + 7.2))
            tick.addLine(to: CGPoint(x: o.x + 8.2, y: o.y + 1.4))
            ctx.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: 版式

    struct Layout: Equatable {
        let firstOfMonth: Date
        let leading: Int      // 1 号前空几格（周日起）
        let daysInMonth: Int
        let rows: Int
        let monthKey: String

        init(month: Date, calendar: Calendar) {
            let comps = calendar.dateComponents([.year, .month], from: month)
            firstOfMonth = calendar.date(from: comps) ?? month
            leading = calendar.component(.weekday, from: firstOfMonth) - 1
            daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
            rows = Int(ceil(Double(leading + daysInMonth) / 7))
            monthKey = "\(comps.year ?? 0)-\(comps.month ?? 0)"
        }

        /// 留白（以格为单位）：左右各 0.57，顶上 0.82（写星期），底下 0.55——星孔卡的点点花边压在这圈里
        static let side: CGFloat = 0.57, top: CGFloat = 0.82, bottom: CGFloat = 0.55
        static var unitsWide: CGFloat { 7 + side * 2 }

        static func aspect(rows: Int) -> CGFloat { unitsWide / (CGFloat(rows) + top + bottom) }

        struct Metrics {
            let cell: CGFloat, x0: CGFloat, y0: CGFloat
            func cellRect(_ index: Int) -> CGRect {
                CGRect(x: x0 + CGFloat(index % 7) * cell, y: y0 + CGFloat(index / 7) * cell, width: cell, height: cell)
            }
            /// 格子里日期数字的位置（左上锚点），铅笔纸、星孔卡、选中圈共用
            func numberOrigin(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX + cell * 0.11, y: r.minY + cell * 0.07) }
            /// 选中圈：圈住日期数字
            func ringRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX - cell * 0.02, y: r.minY - cell * 0.02, width: cell * 0.52, height: cell * 0.47) }
        }

        func metrics(width: CGFloat) -> Metrics {
            let cell = width / Self.unitsWide
            return Metrics(cell: cell, x0: cell * Self.side, y0: cell * Self.top)
        }

        func index(ofDay day: Int) -> Int { leading + day - 1 }

        func day(at point: CGPoint, width: CGFloat) -> Int? {
            let m = metrics(width: width)
            let col = Int(floor((point.x - m.x0) / m.cell)), row = Int(floor((point.y - m.y0) / m.cell))
            guard (0..<7).contains(col), (0..<rows).contains(row) else { return nil }
            let day = row * 7 + col - leading + 1
            return (1...daysInMonth).contains(day) ? day : nil
        }
    }
}
