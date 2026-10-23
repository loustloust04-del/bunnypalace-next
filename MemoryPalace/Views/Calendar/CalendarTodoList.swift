import SwiftUI

// MARK: - 这天的待办（plan-calendar-photos-todos §2.2）
// 第五种能点的样子：铅笔勾选框 = 可勾。行尾没有 ›（点字不进任何地方）；
// 改日期 / 取消日期 / 删除在长按菜单里，也挂成读屏动作。

struct CalendarTodoList: View {
    /// yyyy-MM-dd
    let dayKey: String
    var look: CalendarLook = .paper
    /// 纸：勾选框（看得见的那个方框）左边离容器边多远
    var inset: CGFloat = 22

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var dating: TodoItem?
    /// 跨午夜时刷新（「今天」在求值时现算）
    @State private var dayTick = 0

    private var todo: TodoManager { TodoManager.shared }
    private var ios: Bool { look == .ios }
    /// 纸：方框 18 画在 44 的命中区正中，命中区往左让出 13
    private var paperLead: CGFloat { inset - 13 }

    var body: some View {
        let _ = dayTick
        let today = TodoManager.dayKey(Date())
        let items = todo.items(on: dayKey)
        VStack(alignment: .leading, spacing: 0) {
            if ios {
                IOSSubLabel(text: "待办")
            } else {
                CalendarBlockHeader(title: "待办", inset: inset, addLabel: "加一条待办", onAdd: startAdding)
            }
            ForEach(items) { item in row(item) }
            if dayKey == today {
                let overdue = todo.overdue(today: today)
                let undated = todo.undated.filter { !$0.done }
                if !overdue.isEmpty {
                    if ios {
                        IOSSubLabel(text: "过期")
                    } else {
                        CalendarSectionLabel(text: "过期", inset: inset).padding(.top, 6)
                    }
                    ForEach(overdue) { item in row(item, trailingText: item.date.map(Self.shortDate)) }
                }
                if !undated.isEmpty {
                    if ios {
                        IOSSubLabel(text: "没排日子")
                    } else {
                        CalendarSectionLabel(text: "没排日子", inset: inset).padding(.top, 6)
                    }
                    ForEach(undated) { item in row(item) }
                }
            }
            if adding {
                HStack(spacing: 12) {
                    check(done: false, seed: "draft")
                    TextField("写一条…", text: $draft)
                        .font(.system(size: ios ? 16 : CalType.b))
                        .foregroundColor(ios ? Theme.textPrimary : CalInk.ink)
                        .focused($focused)
                        .tint(ios ? Theme.branchIndicator : CalInk.ink)
                        .submitLabel(.done)
                        .onSubmit(commit)
                }
                .padding(.leading, ios ? IOSCal.pad - 11 : paperLead)
                .padding(.trailing, 18)
            } else if ios {
                Button(action: startAdding) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.system(size: 16)).frame(width: 22)
                        Text("新待办").font(.system(size: 16))
                        Spacer()
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .padding(.horizontal, IOSCal.pad)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // 换了一天：草稿丢掉；失焦时空草稿收起
        .onChange(of: dayKey) { _, _ in adding = false; draft = "" }
        .onChange(of: focused) { _, f in if !f, draft.trimmingCharacters(in: .whitespaces).isEmpty { adding = false } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dayTick += 1 }
        .sheet(item: $dating) { item in TodoDateSheet(item: item) }
    }

    private func startAdding() {
        adding = true
        focused = true
    }

    private func commit() {
        todo.add(draft, date: dayKey)
        draft = ""
        adding = false
    }

    /// 44 见方的命中区；纸 = 铅笔方框 18，iOS = 系统圆圈
    @ViewBuilder
    private func check(done: Bool, seed: String) -> some View {
        Group {
            if ios {
                IOSTodoCheck(done: done)
            } else {
                TodoCheckbox(done: done, seed: seed).frame(width: 18, height: 18)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private static func shortDate(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return key }
        return "\(p[1])月\(p[2])日"
    }

    private func row(_ item: TodoItem, trailingText: String? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { todo.toggle(item.id) }
                } label: {
                    check(done: item.done, seed: item.id.uuidString)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("勾选：\(item.text)")
                .accessibilityAddTraits(item.done ? .isSelected : [])
                Text(item.text)
                    .font(.system(size: ios ? 16 : CalType.b))
                    .foregroundColor(item.done ? (ios ? Theme.textMuted : CalInk.ink3) : (ios ? Theme.textPrimary : CalInk.ink))
                    .strikethrough(item.done, color: ios ? Theme.textMuted : CalInk.ink3)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: ios ? 13 : CalType.s))
                        .foregroundColor(ios ? Theme.textMuted : CalInk.ink3)
                }
            }
            .padding(.leading, ios ? IOSCal.pad - 11 : paperLead)
            .padding(.trailing, 18)
            if ios { IOSHairline(leading: IOSCal.pad + 22 + 12 - 11) }
        }
        .contentShape(Rectangle())
        .contextMenu { menu(item) }
        .accessibilityAction(named: "改日期") { dating = item }
        .accessibilityAction(named: "取消日期") { todo.setDate(nil, for: item.id) }
        .accessibilityAction(named: "删除") { todo.delete(item.id) }
    }

    @ViewBuilder
    private func menu(_ item: TodoItem) -> some View {
        Button("改日期…", systemImage: "calendar") { dating = item }
        Button("取消日期", systemImage: "calendar.badge.minus") { todo.setDate(nil, for: item.id) }
        Button("删除", systemImage: "trash", role: .destructive) { todo.delete(item.id) }
    }
}

/// 铅笔勾选框（日历里的待办、待办小组件共用）
struct TodoCheckbox: View {
    let done: Bool
    var seed = "todo"
    var box: Color = CalInk.ink2
    var tick: Color = CalInk.ink

    var body: some View {
        Canvas { ctx, size in
            var rng = CalendarInk.Rand(seed: CalendarInk.seed(seed, "box"))
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            ctx.stroke(CalendarInk.rubPath(in: r, amp: 0.9, rng: &rng), with: .color(box), lineWidth: 1.2)
            if done {
                var tickPath = Path()
                tickPath.move(to: CGPoint(x: size.width * 0.24, y: size.height * 0.52))
                tickPath.addLine(to: CGPoint(x: size.width * 0.44, y: size.height * 0.72))
                tickPath.addLine(to: CGPoint(x: size.width * 0.8, y: size.height * 0.26))
                ctx.stroke(tickPath, with: .color(tick), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 改日期：系统日期选择
struct TodoDateSheet: View {
    let item: TodoItem
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(item: TodoItem) {
        self.item = item
        _date = State(initialValue: item.date.flatMap { DailyActivity.date(fromKey: $0, calendar: .current) } ?? Date())
    }

    var body: some View {
        NavigationStack {
            DatePicker("日期", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle(item.text)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("好") {
                            TodoManager.shared.setDate(TodoManager.dayKey(date), for: item.id)
                            dismiss()
                        }
                    }
                }
        }
        .tint(Theme.branchIndicator)
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
