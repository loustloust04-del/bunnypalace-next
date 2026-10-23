import SwiftUI

/// 待办小组件（plan-calendar-photos-todos §2.3）——日历这套纸的字：手写数字、打字机小标签、铅笔勾选框。
/// 四处共用（页 2 / Dashboard / iPad 桌面 / mac 桌面），外框仍用各平台的 surface。
/// 小组件里不做长按（宿主已有长按菜单）：点勾选框 = 勾，点文字 / 标题 = 打开日历那一天（有入口时）。
struct TodoWidgetView: View {
    var size: WidgetSize = .large
    /// 打开日历某一天（yyyy-MM-dd）；没有日历入口的宿主传 nil，标题就不带 ›
    var onOpenCalendar: ((String) -> Void)?

    @Environment(\.usesSystemDesktop) private var systemDesktop
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    /// 跨午夜 / 改时区时刷新（「今天」在求值时现算）
    @State private var dayTick = 0

    private var todo: TodoManager { TodoManager.shared }
    /// 系统桌面（玻璃 + 壁纸）强制深色外观，系统前景色会变白字——一律用明确的深墨；次要字在玻璃上提一档
    private var ink: Color { CalInk.ink }
    private var ink3: Color { systemDesktop ? CalInk.ink2 : CalInk.ink3 }

    var body: some View {
        let _ = dayTick
        let today = TodoManager.dayKey(Date())
        content(today: today)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if os(macOS)
            .modifier(MacShellWidgetSurface())
            #else
            .modifier(Page2LegacySurface())
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dayTick += 1 }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in dayTick += 1 }
    }

    @ViewBuilder
    private func content(today: String) -> some View {
        switch size {
        case .small: smallBody(today: today)
        case .medium: mediumBody(today: today)
        case .large: largeBody(today: today)
        }
    }

    // MARK: 小：今天还剩几项 + 下一条

    private func smallBody(today: String) -> some View {
        let list = todo.actionList(today: today)
        return VStack(alignment: .leading, spacing: 0) {
            header("today", today: today)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(list.count)").font(CalType.hand(46)).foregroundColor(ink)
                Text("left").font(CalType.type(CalType.m)).foregroundColor(ink3)
            }
            .padding(.horizontal, 14)
            Spacer(minLength: 0)
            Text(list.first?.text ?? "今天没有待办")
                .font(.system(size: CalType.s))
                .foregroundColor(list.isEmpty ? ink3 : ink)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 中：行动清单，放得下几行放几行

    private func mediumBody(today: String) -> some View {
        let list = todo.actionList(today: today)
        return VStack(alignment: .leading, spacing: 0) {
            header("today · \(list.count) left", today: today)
            GeometryReader { geo in
                let fit = max(1, Int((geo.size.height - 8) / Self.rowHeight))
                VStack(alignment: .leading, spacing: 0) {
                    if list.isEmpty {
                        Text("今天没有待办").font(.system(size: CalType.s)).foregroundColor(ink3).padding(.horizontal, 14)
                    }
                    ForEach(list.prefix(fit)) { item in row(item, today: today) }
                }
            }
        }
    }

    // MARK: 大：today（含过期）/ tomorrow / later / someday，可滚；底部输入

    private func largeBody(today: String) -> some View {
        let tomorrow = TodoManager.dayKey(after: today) ?? ""
        let groups: [(String, [TodoItem])] = [
            ("today", todo.todayGroup(today: today)),
            ("tomorrow", todo.items(on: tomorrow)),
            ("later", todo.later(today: today)),
            ("someday", todo.undated),
        ].filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            header("todo · \(todo.remaining) left", today: today)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty {
                        Text("还没有待办，写一条 ↓").font(.system(size: CalType.s)).foregroundColor(ink3).padding(.horizontal, 14)
                    }
                    ForEach(groups, id: \.0) { name, items in
                        Text(name).font(CalType.type(CalType.m)).tracking(1).foregroundColor(ink3)
                            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                        ForEach(items) { item in row(item, today: today) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Divider().opacity(0.5).padding(.horizontal, 14)
            HStack(spacing: 8) {
                Text("＋").font(.system(size: CalType.s)).foregroundColor(ink3)
                TextField("加一条…", text: $draft)
                    .font(.system(size: 14))
                    .foregroundColor(ink)
                    .focused($inputFocused)
                    .tint(CalInk.ink)
                    .submitLabel(.done)
                    .onSubmit {
                        todo.add(draft, date: today)
                        draft = ""
                        inputFocused = false
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: 零件

    private static let rowHeight: CGFloat = 34

    private func header(_ title: String, today: String) -> some View {
        let label = HStack {
            Text(title).font(CalType.type(CalType.m)).tracking(1).foregroundColor(ink3)
            Spacer()
            if onOpenCalendar != nil {
                Text(size == .large ? "calendar ›" : "\(Self.shortDate(today)) ›").font(CalType.type(CalType.m)).foregroundColor(ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        return Group {
            if let onOpenCalendar {
                Button { onOpenCalendar(today) } label: { label }.buttonStyle(.plain).accessibilityHint("打开日历")
            } else {
                label
            }
        }
    }

    /// `sep 27`
    private static func shortDate(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return key }
        return "\(StarCardCover.monthAbbrev(p[1])) \(p[2])"
    }

    private func row(_ item: TodoItem, today: String) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { todo.toggle(item.id) }
            } label: {
                TodoCheckbox(done: item.done, seed: item.id.uuidString, box: CalInk.ink2, tick: ink)
                    .frame(width: 16, height: 16)
                    .frame(width: 28, height: Self.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("勾选：\(item.text)")
            .accessibilityAddTraits(item.done ? .isSelected : [])
            Text(item.text)
                .font(.system(size: 14))
                .foregroundColor(item.done ? ink3 : ink)
                .strikethrough(item.done, color: ink3)
                .lineLimit(1)
            Spacer(minLength: 4)
            // 过期的 / 以后的：行尾标原来的日期
            if let d = item.date, d != today {
                Text(Self.shortDate(d)).font(CalType.type(10)).foregroundColor(ink3)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpenCalendar?(item.date ?? today) }
    }
}
