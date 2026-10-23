import SwiftUI

// MARK: - iOS 风日历零件（plan-calendar-v5 §1）
// 旧日历打法：薄荷底（sidebarBg）上一张暖白纸（mainBg），纸底部也是圆角；页里分段一律用票根缺口。
// 颜色全走 Theme（跟主题、深色）；纸风那套 CalInk 不进这里。

enum IOSCal {
    static let pad: CGFloat = 18
    static let radius: CGFloat = 22
}

/// 票根纸：圆角纸 + 描边，分段之间放 `TicketNotch`。
/// 描边画在内容下面、再整体裁圆角——缺口圆（页底色）盖住描边，看起来就是纸被咬掉一块。
struct CalendarTicket<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IOSCal.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Theme.mainBg)
                shape.strokeBorder(Theme.accent, lineWidth: 1)
            }
            .clipShape(shape)
            .padding(.horizontal, 8)
    }
}

/// 票根缺口：两侧各咬一个半圆 + 中间一道虚线撕口（装饰）
struct TicketNotch: View {
    private static let d: CGFloat = 28

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 22, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width - 22, y: size.height / 2))
                ctx.stroke(p, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
            HStack {
                bite.offset(x: -Self.d / 2)
                Spacer()
                bite.offset(x: Self.d / 2)
            }
        }
        .frame(height: Self.d)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bite: some View {
        Circle().fill(Theme.sidebarBg)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1))
            .frame(width: Self.d, height: Self.d)
    }
}

/// 小灰字分段标题
struct IOSSubLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).tracking(0.5).foregroundColor(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IOSCal.pad)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

/// 行底发丝线（从正文起，右边到纸边）
struct IOSHairline: View {
    var leading: CGFloat = IOSCal.pad
    var body: some View {
        Rectangle().fill(Theme.accent).frame(height: 0.5).padding(.leading, leading)
    }
}

/// 列表行：图标 / 标题 / 标签 / 右侧数字 / ›，整行一个按钮
struct IOSCalendarRow: View {
    let icon: String
    let title: String
    var tag: String?
    var meta: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 20)
                    Text(title).font(.system(size: 16)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    if let tag {
                        Text(tag).font(.system(size: 11)).foregroundColor(Theme.textMuted).lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: 8)
                    if let meta {
                        Text(meta).font(.system(size: 13)).foregroundColor(Theme.textMuted).lineLimit(1).fixedSize()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, IOSCal.pad)
                .frame(minHeight: 44)
                IOSHairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// 系统圆圈勾（待办）
struct IOSTodoCheck: View {
    let done: Bool
    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21, weight: .light))
            .foregroundColor(done ? Theme.branchIndicator : Theme.textMuted)
            .accessibilityHidden(true)
    }
}

// MARK: 月历格子（普通数字；选中 = accent 圆角底；今天 = 薄荷粗字；底下最多两个小点）

struct IOSMonthGrid: View {
    let month: Date
    /// key = 日（1...31）
    let days: [Int: PencilMonthDay]
    /// 那天聊过（messages > 0；不看涂深档位）
    let chatDays: Set<Int>
    let selected: Date
    var accessibilityDetail: (Int) -> String = { _ in "" }
    let onSelect: (Date) -> Void

    private let calendar = Calendar.current
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    /// 经期玫瑰（和旧日历 / 健康页同色族）
    static let rose = Color(red: 0xC9 / 255.0, green: 0x8A / 255.0, blue: 0x8A / 255.0)
    static let anniversaryPink = Color(red: 0xD9 / 255.0, green: 0xA0 / 255.0, blue: 0xA8 / 255.0)

    var body: some View {
        let lay = PencilMonthView.Layout(month: month, calendar: calendar)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Self.weekdays, id: \.self) { w in
                    Text(w).font(.system(size: 12)).foregroundColor(Theme.textMuted).frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: columns, spacing: 2) {
                // 1 号前的空格用负数当 id，和 1...31 不撞
                ForEach(-lay.leading..<0, id: \.self) { _ in Color.clear.frame(height: 42) }
                ForEach(1...lay.daysInMonth, id: \.self) { d in cell(d, lay: lay) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func cell(_ d: Int, lay: PencilMonthView.Layout) -> some View {
        let date = calendar.date(byAdding: .day, value: d - 1, to: lay.firstOfMonth) ?? lay.firstOfMonth
        let isSelected = calendar.isDate(date, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(date)
        let mark = days[d] ?? PencilMonthDay()
        let dots = Self.dots(chat: chatDays.contains(d), mark)
        return Button { onSelect(date) } label: {
            VStack(spacing: 2) {
                Text("\(d)")
                    .font(.system(size: 16, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundColor(isToday ? Theme.branchIndicator : Theme.textPrimary)
                HStack(spacing: 3) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, c in Circle().fill(c).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent).padding(.horizontal, 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(calendar.component(.month, from: date))月\(d)日\(isToday ? "，今天" : "")\(accessibilityDetail(d))"
                            + (Self.isAnniversary(mark) ? "，纪念日" : "") + (mark.periodMark ? "，经期" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    static func isAnniversary(_ m: PencilMonthDay) -> Bool { m.doodle == .bow || m.doodle == .star }

    /// 最多两个：聊过（薄荷）+ 纪念日（粉）或经期（玫瑰）；三样同天经期让位（读屏照念）。待办不标在格子上。
    static func dots(chat: Bool, _ m: PencilMonthDay) -> [Color] {
        var out: [Color] = []
        if chat { out.append(Theme.branchIndicator) }
        if isAnniversary(m) { out.append(anniversaryPink) } else if m.periodMark { out.append(rose) }
        return out
    }
}

// MARK: 底部浮动页签（mac 用；iOS 走系统 TabView）：玻璃胶囊，选中项垫一块会滑的亮胶囊

enum CalendarIOSTab: PanelFloatingTab {
    case month, year, anniversaries, settings

    var title: String {
        switch self {
        case .month: "月"
        case .year: "年"
        case .anniversaries: "纪念日"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .month: "calendar"
        case .year: "chart.bar"
        case .anniversaries: "heart"
        case .settings: "gearshape"
        }
    }
}

/// 画法、动画原样搬进 `PanelFloatingTabBar`（记忆也用），日历这边一点不变
typealias CalendarIOSTabBar = PanelFloatingTabBar<CalendarIOSTab>

// MARK: 纯计算（进单测）

enum CalendarIOSMath {
    struct MonthRow: Equatable {
        enum Kind: Equatable { case recap, current }
        let month: Int
        let activeDays: Int
        let daysInMonth: Int
        let kind: Kind
        var fraction: Double { daysInMonth > 0 ? min(1, Double(activeDays) / Double(daysInMonth)) : 0 }
    }

    /// 年页「每个月」：从近到远；今年只到本月（本月 = current，点了跳月页），以后的月合成 `futureFrom`
    static func monthRows(activeByMonth: [Int: Int], year: Int, today: Date, calendar: Calendar) -> (rows: [MonthRow], futureFrom: Int?) {
        let thisYear = calendar.component(.year, from: today)
        if year > thisYear { return ([], 1) }
        let last = year == thisYear ? calendar.component(.month, from: today) : 12
        var rows: [MonthRow] = []
        for m in stride(from: last, through: 1, by: -1) {
            guard let first = calendar.date(from: DateComponents(year: year, month: m, day: 1)) else { continue }
            let n = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
            rows.append(MonthRow(month: m, activeDays: activeByMonth[m] ?? 0, daysInMonth: n,
                                 kind: year == thisYear && m == last ? .current : .recap))
        }
        return (rows, last < 12 ? last + 1 : nil)
    }

    /// 24 小时各聊了多少（punch card 七行合起来）
    static func hourTotals(_ punch: [[Int]]) -> [Int] {
        (0..<24).map { h in punch.reduce(0) { $0 + ($1.indices.contains(h) ? $1[h] : 0) } }
    }

    /// 全年心情色带：一周一格，取那周出现最多的心情（一样多取靠前的那种）；今年只到今天那周
    static func weeklyMoods(year: Int, moods: [String: JournalMood], today: Date, calendar: Calendar) -> [JournalMood?] {
        guard let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let next = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)),
              year <= calendar.component(.year, from: today) else { return [] }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)) ?? next
        let end = calendar.component(.year, from: today) == year ? min(next, tomorrow) : next
        guard end > jan1 else { return [] }
        let days = calendar.dateComponents([.day], from: jan1, to: end).day ?? 0
        let weeks = Int(ceil(Double(max(days, 1)) / 7))
        return (0..<weeks).map { w in
            var count: [JournalMood: Int] = [:]
            for i in 0..<7 {
                guard let d = calendar.date(byAdding: .day, value: w * 7 + i, to: jan1), d < end else { break }
                if let m = moods[DailyActivity.dayKey(d, calendar: calendar)] { count[m, default: 0] += 1 }
            }
            let top = count.values.max() ?? 0
            return top == 0 ? nil : JournalMood.allCases.first { count[$0] == top }
        }
    }
}
