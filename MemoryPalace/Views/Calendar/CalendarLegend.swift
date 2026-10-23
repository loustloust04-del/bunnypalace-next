import SwiftUI

// MARK: - 月历上的记号（年页底部；只是说明，不能点——不带框、不带 ›）

struct CalendarLegend: View {
    private enum Icon { case shades, dot, doodle(CalendarInk.Doodle), period, today, ring, todo }

    private static let items: [(Icon, String)] = [
        (.dot, "聊了一点"), (.doodle(.bow), "生日"),
        (.doodle(.star), "纪念日"), (.doodle(.heartBox), "写了日记"),
        (.doodle(.flower), "心情是开心"), (.doodle(.spiral), "一个对话达到 100 条"),
        (.period, "经期"), (.today, "今天"),
        (.ring, "选中的那天"), (.todo, "有待办（全做完打勾）"),
    ]

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(.shades, "聊得越多，涂得越深", width: 64)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(Self.items.enumerated()), id: \.offset) { _, item in row(item.0, item.1, width: 26) }
            }
            Text("一格只画一个：纪念日 › 日记 › 开心 › 100 条")
                .font(.system(size: CalType.s))
                .foregroundColor(CalInk.ink3)
        }
        .padding(.horizontal, 22)
        .accessibilityElement(children: .combine)
    }

    private func row(_ icon: Icon, _ text: String, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            Canvas { ctx, size in Self.draw(icon, in: &ctx, size: size) }
                .frame(width: width, height: 26)
                .accessibilityHidden(true)
            Text(text).font(.system(size: CalType.s)).foregroundColor(CalInk.ink2)
        }
    }

    private static func draw(_ icon: Icon, in ctx: inout GraphicsContext, size: CGSize) {
        var rng = CalendarInk.Rand(seed: 44)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        switch icon {
        case .shades:
            ctx.drawLayer { layer in
                for (i, lv) in [2, 3, 4].enumerated() {
                    let r = CGRect(x: 2 + CGFloat(i) * 21, y: 5, width: 16, height: 16)
                    if let fill = CalendarInk.rubFill(level: lv) { layer.fill(CalendarInk.rubPath(in: r, amp: 1.3, rng: &rng), with: .color(fill)) }
                }
                CalendarInk.applyGrain(&layer, in: CGRect(origin: .zero, size: size))
            }
        case .dot:
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(CalendarInk.graphite))
        case .doodle(let d):
            CalendarInk.draw(d, in: &ctx, center: c, h: 8, dark: false, rng: &rng)
        case .period:
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Color(red: 0.788, green: 0.541, blue: 0.541)))
        case .today:
            ctx.draw(Text("27").font(CalType.hand(CalType.s)).foregroundColor(CalendarInk.graphite), at: CGPoint(x: 4, y: 4), anchor: .topLeading)
            var line = Path(); line.move(to: CGPoint(x: 3, y: 20)); line.addLine(to: CGPoint(x: 20, y: 20))
            ctx.stroke(line, with: .color(CalendarInk.graphite), lineWidth: 1)
        case .todo:
            PencilMonthView.drawTodoBox(in: &ctx, at: CGPoint(x: c.x - 4.5, y: c.y - 4.5), done: true, color: CalInk.ink2, rng: &rng)
        case .ring:
            ctx.stroke(PencilRing.path(around: CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 6), rng: &rng), with: .color(CalInk.ink), lineWidth: 1.1)
        }
    }
}
