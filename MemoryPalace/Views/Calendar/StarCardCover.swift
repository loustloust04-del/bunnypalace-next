import SwiftUI

// MARK: - 星孔外卡（plan-calendar §四，参考 p1 / p2）
// 格点上摆满看不见的圆；星孔 = 每个有聊天的格子一块菱形（相邻格子之间补细桥）减去格点圆，
// 再模糊 + 阈值把尖角磨圆。聊一点 = 小圆孔，聊得多一点 = 小星孔，聊得多 = 星孔（相邻的收腰连通）。

enum StarCardColor: String, CaseIterable, Sendable {
    case white, black, sky

    var label: String {
        switch self {
        case .white: "白"
        case .black: "黑"
        case .sky: "天蓝"
        }
    }

    var fill: Color {
        switch self {
        case .white: Color(red: 0.984, green: 0.984, blue: 0.976)
        case .black: Color(red: 0.137, green: 0.137, blue: 0.129)
        case .sky: Color(red: 0.369, green: 0.659, blue: 0.847)
        }
    }

    /// 卡上印的星期和日期（天蓝卡原来的浅字对比只有 2:1，改深蓝）
    var number: Color {
        switch self {
        case .white: CalInk.ink3
        case .black: Color(red: 0.663, green: 0.659, blue: 0.635)
        case .sky: Color(red: 0.141, green: 0.282, blue: 0.373)
        }
    }

    /// 选中圈 / 今天下划线的颜色
    var mark: Color {
        switch self {
        case .white: CalInk.ink
        case .black: Color(red: 0.91, green: 0.906, blue: 0.886)
        case .sky: Color(red: 0.102, green: 0.2, blue: 0.267)
        }
    }

    /// 盲压的明暗幅度：深色卡要大一点才看得出
    var embossAmp: Double {
        switch self {
        case .white: 0.75
        case .black: 0.7
        case .sky: 0.6
        }
    }
}

/// 卡面（不含选中圈 / 今天）：输入不变就不重画——选日只动上面那层 `StarCardMarks`
struct StarCardCover: View, Equatable {
    let month: Date
    /// key = 日，value = 档位 0...4
    let levels: [Int: Int]
    let color: StarCardColor
    let seedKey: String

    private let calendar = Calendar.current

    static func == (a: Self, b: Self) -> Bool {
        a.month == b.month && a.levels == b.levels && a.color == b.color && a.seedKey == b.seedKey
    }

    var body: some View {
        let lay = PencilMonthView.Layout(month: month, calendar: calendar)
        Canvas { ctx, size in
            draw(in: &ctx, size: size, lay: lay)
        }
        .aspectRatio(PencilMonthView.Layout.aspect(rows: lay.rows), contentMode: .fit)
        .allowsHitTesting(false)
    }

    // 顺序：卡面 → 盲压 → 印字 → 统一挖孔 → 整卡投影（plan-calendar-page 裁定 #4）
    private func draw(in ctx: inout GraphicsContext, size: CGSize, lay: PencilMonthView.Layout) {
        let m = lay.metrics(width: size.width)
        let holes = Self.holes(lay: lay, metrics: m, levels: levels, seed: CalendarInk.seed(seedKey, lay.monthKey, "card"))
        let full = CGRect(origin: .zero, size: size)
        let art = Self.embossArt(lay: lay, metrics: m, size: size)

        ctx.drawLayer { card in
            card.addFilter(.shadow(color: .black.opacity(0.2), radius: 1.8, x: 1.2, y: 2.2))
            card.drawLayer { face in
                face.fill(Path(roundedRect: full, cornerRadius: 3), with: .color(color.fill))
                Self.emboss(art, in: &face, fill: color.fill, amp: color.embossAmp)
                for i in 0..<7 {
                    face.draw(Text(["s", "m", "t", "w", "t", "f", "s"][i]).font(CalType.type(CalType.m)).foregroundColor(color.number),
                              at: CGPoint(x: m.x0 + (CGFloat(i) + 0.5) * m.cell, y: m.y0 - m.cell * 0.3), anchor: .center)
                }
                for d in 1...lay.daysInMonth {
                    let r = m.cellRect(lay.index(ofDay: d))
                    face.draw(Text("\(d)").font(CalType.type(CalType.m)).foregroundColor(color.number), at: m.numberOrigin(r), anchor: .topLeading)
                }
                // 挖孔：模糊 + 阈值磨圆尖角
                face.blendMode = .destinationOut
                face.drawLayer { h in
                    h.addFilter(.alphaThreshold(min: 0.5, color: .black))
                    h.addFilter(.blur(radius: m.cell * 0.028))
                    h.fill(holes, with: .color(.black))
                }
            }
        }
    }

    // MARK: 盲压（参考 2：点点边框 + 六瓣小花 + 空格里的小植物）

    /// 纸的盲压近似：暗面往右下、亮面往左上，都糊开；原位再用卡面色盖一层（凸起的顶和纸同色）
    static func emboss(_ art: Path, in ctx: inout GraphicsContext, fill: Color, amp: Double) {
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 1.2))
            l.translateBy(x: 0.9, y: 1.1)
            l.fill(art, with: .color(.black.opacity(0.5 * amp)))
        }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 1.2))
            l.translateBy(x: -0.7, y: -0.8)
            l.fill(art, with: .color(.white.opacity(amp)))
        }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 0.66))
            l.fill(art, with: .color(fill))
        }
    }

    /// 压花图案（一个 Path，一次合成）
    static func embossArt(lay: PencilMonthView.Layout, metrics m: PencilMonthView.Layout.Metrics, size: CGSize) -> Path {
        var p = Path()
        let x0: CGFloat = 12, x1 = size.width - 12, y0: CGFloat = 11, y1 = size.height - 11
        func dot(_ c: CGPoint, _ r: CGFloat) { p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        func side(_ a: CGPoint, _ b: CGPoint) {
            let n = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 7.2).rounded()))
            for i in 0..<n { let t = CGFloat(i) / CGFloat(n); dot(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), 1.35) }
        }
        func rosette(_ x: CGFloat, _ y: CGFloat) {
            let s: CGFloat = 2.3
            dot(CGPoint(x: x, y: y), s * 0.6)
            for i in 0..<6 { let a = CGFloat(i) / 6 * 2 * .pi; dot(CGPoint(x: x + cos(a) * s * 1.4, y: y + sin(a) * s * 1.4), s * 0.62) }
        }
        side(CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0)); side(CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1))
        side(CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)); side(CGPoint(x: x0, y: y1), CGPoint(x: x0, y: y0))
        for k in 0...5 { let x = x0 + (x1 - x0) * CGFloat(k) / 5; rosette(x, y0); rosette(x, y1) }
        for k in 1..<5 { let y = y0 + (y1 - y0) * CGFloat(k) / 5; rosette(x0, y); rosette(x1, y) }
        // 本月前后的空格里压小植物
        var empty: [Int] = Array(0..<lay.leading)
        let lastIndex = lay.index(ofDay: lay.daysInMonth)
        empty += Array((lastIndex + 1)..<(lay.rows * 7))
        let plants = ["tulip", "bell", "sprig", "quatre", "daisy"]
        for (i, idx) in empty.enumerated() {
            guard let pat = CalendarInk.patterns[plants[i % plants.count]] else { continue }
            let c = min(3.8, m.cell / 11.5)
            let r = m.cellRect(idx)
            let ox = r.minX + (r.width - CGFloat(pat.width) * c) / 2 + c / 2
            let oy = r.minY + (r.height - CGFloat(pat.height) * c) / 2 + c / 2
            for (j, row) in pat.rows.enumerated() {
                for (k, ch) in row.enumerated() where ch != "." { dot(CGPoint(x: ox + CGFloat(k) * c, y: oy + CGFloat(j) * c), c * 0.3) }
            }
        }
        return p
    }

    /// 页头的月份：小写英文（手写体没有中文字形，不跟系统语言走）
    static func monthName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM"
        return f.string(from: date).lowercased()
    }

    /// 英文月名缩写（`aug`）：月度回顾按钮
    static func monthAbbrev(_ month: Int) -> String {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return (1...12).contains(month) ? names[month - 1] : ""
    }

    /// 纯函数（可测）：一个月的孔。
    static func holes(lay: PencilMonthView.Layout, metrics m: PencilMonthView.Layout.Metrics, levels: [Int: Int], seed: UInt64) -> Path {
        let cells = (1...lay.daysInMonth).compactMap { d -> StarHoleCell? in
            let level = levels[d] ?? 0
            guard level > 0 else { return nil }
            let idx = lay.index(ofDay: d)
            return StarHoleCell(col: idx % 7, row: idx / 7, level: level)
        }
        return holes(cells: cells, cols: 7, rows: lay.rows, cell: m.cell, origin: CGPoint(x: m.x0, y: m.y0), seed: seed)
    }

    /// 通用版（月历、纪念日镂空卡共用）：格点圆 + 每个格子按档位开孔；level 1 小圆 · 2 小星 · ≥3 星孔（右 / 下邻居也是星孔就补桥）。
    static func holes(cells: [StarHoleCell], cols: Int, rows: Int, cell s: CGFloat, origin: CGPoint, seed: UInt64) -> Path {
        var rng = CalendarInk.Rand(seed: seed)
        // 格点圆（位置和半径轻微抖动）
        var circles = Path()
        for gx in 0...cols {
            for gy in 0...rows {
                let r: CGFloat = s * (0.44 + rng.jitter(0.05))
                let cx: CGFloat = origin.x + CGFloat(gx) * s + rng.jitter(s * 0.06)
                let cy: CGFloat = origin.y + CGFloat(gy) * s + rng.jitter(s * 0.06)
                circles.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        }
        var stars = Path()
        var extras = Path()
        let starCells = Set(cells.filter { $0.level >= 3 }.map { StarHoleCell(col: $0.col, row: $0.row, level: 0) })
        for cellInfo in cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) {
            let c = CGPoint(x: origin.x + (CGFloat(cellInfo.col) + 0.5) * s, y: origin.y + (CGFloat(cellInfo.row) + 0.5) * s)
            switch cellInfo.level {
            case ...0:
                continue
            case 1:
                let r = s * (0.11 + rng.next() * 0.04)
                let cc = CGPoint(x: c.x + rng.jitter(s * 0.04), y: c.y + rng.jitter(s * 0.04))
                extras.addEllipse(in: CGRect(x: cc.x - r, y: cc.y - r, width: r * 2, height: r * 2))
            case 2:
                let h = s * (0.27 + rng.next() * 0.06)
                let k = h * 0.08
                extras.move(to: CGPoint(x: c.x, y: c.y - h))
                extras.addQuadCurve(to: CGPoint(x: c.x + h, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
                extras.addQuadCurve(to: CGPoint(x: c.x, y: c.y + h), control: CGPoint(x: c.x + k, y: c.y + k))
                extras.addQuadCurve(to: CGPoint(x: c.x - h, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
                extras.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h), control: CGPoint(x: c.x - k, y: c.y - k))
                extras.closeSubpath()
            default:
                stars.move(to: CGPoint(x: c.x, y: c.y - s / 2))
                stars.addLine(to: CGPoint(x: c.x + s / 2, y: c.y))
                stars.addLine(to: CGPoint(x: c.x, y: c.y + s / 2))
                stars.addLine(to: CGPoint(x: c.x - s / 2, y: c.y))
                stars.closeSubpath()
                // 右边、下边的邻居也是星孔：补一条细桥，被两个格点圆夹成收腰
                if cellInfo.col + 1 < cols, starCells.contains(StarHoleCell(col: cellInfo.col + 1, row: cellInfo.row, level: 0)) {
                    stars.addRect(CGRect(x: c.x, y: c.y - s * 0.09, width: s, height: s * 0.18))
                }
                if starCells.contains(StarHoleCell(col: cellInfo.col, row: cellInfo.row + 1, level: 0)) {
                    stars.addRect(CGRect(x: c.x - s * 0.09, y: c.y, width: s * 0.18, height: s))
                }
            }
        }
        let carved = Path(stars.cgPath.normalized().subtracting(circles.cgPath.normalized()))
        var all = carved
        all.addPath(extras)
        return all
    }
}

struct StarHoleCell: Hashable, Sendable {
    let col: Int
    let row: Int
    let level: Int
}

/// 卡上方的一层：选中圈 + 今天下划线（选日只重画这层，不重画卡面）
struct StarCardMarks: View {
    let month: Date
    let selected: Date?
    let color: StarCardColor
    /// 日 → 待办全做完了没
    var todos: [Int: Bool] = [:]

    private let calendar = Calendar.current

    var body: some View {
        let lay = PencilMonthView.Layout(month: month, calendar: calendar)
        Canvas { ctx, size in
            let m = lay.metrics(width: size.width)
            let inMonth = { (d: Date) in calendar.isDate(d, equalTo: lay.firstOfMonth, toGranularity: .month) }
            let today = Date()
            if inMonth(today) {
                let r = m.cellRect(lay.index(ofDay: calendar.component(.day, from: today)))
                let o = m.numberOrigin(r)
                var line = Path(); line.move(to: CGPoint(x: o.x - 1, y: o.y + 14)); line.addLine(to: CGPoint(x: o.x + 14, y: o.y + 14))
                ctx.stroke(line, with: .color(color.mark), lineWidth: 1)
            }
            var boxRng = CalendarInk.Rand(seed: 77)
            for (d, done) in todos where (1...lay.daysInMonth).contains(d) {
                let r = m.cellRect(lay.index(ofDay: d))
                PencilMonthView.drawTodoBox(in: &ctx, at: CGPoint(x: r.maxX - m.cell * 0.1 - 9, y: r.minY + m.cell * 0.1), done: done, color: color.mark, rng: &boxRng)
            }
            if let selected, inMonth(selected) {
                let d = calendar.component(.day, from: selected)
                var rng = CalendarInk.Rand(seed: CalendarInk.seed("card-ring", String(d)))
                ctx.stroke(PencilRing.path(around: m.ringRect(m.cellRect(lay.index(ofDay: d))), rng: &rng), with: .color(color.mark), lineWidth: 1.1)
            }
        }
        .aspectRatio(PencilMonthView.Layout.aspect(rows: lay.rows), contentMode: .fit)
        .allowsHitTesting(false)
    }
}
