import SwiftUI
import UniformTypeIdentifiers

/// 桌面 / 仪表盘 —— page2 主场。widget 列表由 DashboardManager 驱动，支持三档尺寸网格。
/// 长按进编辑态：抖动 + ✕删除 + ⤢改尺寸 + 拖动重排（学 iOS 主屏）。
struct DashboardView: View {
    @State private var dash = DashboardManager.shared
    @State private var editing = false
    @State private var dragging: WidgetKind? = nil
    @State private var wobble = false

    private let gap: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            // 夹上限：卡片边长和「大方」高度都是 contentW 的函数，不夹的话 iPad 上
            // contentW≈1000 → 小卡 494pt 见方、大方 1000pt 高（一行占位文案配一张整屏卡）。
            let contentW = min(max(0, geo.size.width - 32), Theme.contentMaxWidth)
            let smallSide = (contentW - gap) / 2

            ScrollView {
                VStack(alignment: .leading, spacing: gap) {
                    header

                    ForEach(Array(packRows().enumerated()), id: \.offset) { _, row in
                        rowView(row, smallSide: smallSide, contentW: contentW)
                    }

                    if dash.widgets.isEmpty {
                        Text("桌面空了 —— 长按空白处编辑，或点下面加回来")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    }

                    if (editing || dash.widgets.isEmpty) && !dash.availableToAdd.isEmpty {
                        addSection
                    }

                    if !editing && !dash.widgets.isEmpty {
                        Text("长按组件：改尺寸 / 删除 / 排序")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                // 内容栏跟着 contentW 夹住并居中（+32 补回上面这行 padding）；
                // 窄屏上 contentW+32 就等于屏宽，等于没加。
                .frame(maxWidth: contentW + 32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            if !editing { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editing = true } }
                        }
                        // S1-7：mac 补右键入口，**长按保留不删**（加能力不换路）。
                        // 这里用 #if os(macOS) 而不是 widePanelMode——iPad 上长按**已经**是进编辑态，
                        // 再挂 contextMenu 两个长按识别器会打架（长按菜单先赢，feedback_contextmenu_kills_draggesture）
                        #if os(macOS)
                        .contextMenu {
                            if editing {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editing = false }
                                } label: {
                                    Label("完成", systemImage: "checkmark")
                                }
                            } else {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editing = true }
                                } label: {
                                    Label("整理桌面", systemImage: "square.grid.2x2")
                                }
                            }
                        }
                        #endif
                )
            }
            .overlay(alignment: .topTrailing) {
                if editing { doneButton }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { wobble = true }
        }
    }

    // MARK: - 打包成行：小方两两并排，长条/大方独占一行
    private func packRows() -> [[WidgetInstance]] {
        var rows: [[WidgetInstance]] = []
        var pending: WidgetInstance? = nil
        for w in dash.widgets {
            if w.size == .small {
                if let p = pending { rows.append([p, w]); pending = nil }
                else { pending = w }
            } else {
                if let p = pending { rows.append([p]); pending = nil }
                rows.append([w])
            }
        }
        if let p = pending { rows.append([p]) }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: [WidgetInstance], smallSide: CGFloat, contentW: CGFloat) -> some View {
        if row.count == 1, row[0].size != .small {
            // 长条 / 大方：整行
            let inst = row[0]
            let h: CGFloat = inst.size == .large ? contentW : smallSide
            widgetCell(inst, width: nil, height: h)
        } else {
            // 一到两个小方
            HStack(spacing: gap) {
                ForEach(row) { inst in
                    widgetCell(inst, width: smallSide, height: smallSide)
                }
                if row.count == 1 { Spacer(minLength: 0) }
            }
        }
    }

    private func widgetCell(_ inst: WidgetInstance, width: CGFloat?, height: CGFloat) -> some View {
        let sized = Group {
            switch inst.kind {
            case .pet:      PetWidgetView(size: inst.size)
            case .todo:     TodoWidgetView(size: inst.size)
            case .garden:   GardenWidgetView(size: inst.size)
            case .contacts: ContactsWidgetView(size: inst.size)
            case .vocab:    VocabWidgetView(size: inst.size)
            #if PERSONAL_APPS
            #if DEBUG
            case .topicBox: TopicWidgetView(size: inst.size)
            #endif
            #endif
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)

        let decorated = sized
            .overlay(alignment: .topLeading) {
                if editing {
                    editBadge("xmark") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dash.remove(inst.kind) }
                    }
                    .offset(x: -7, y: -7)
                }
            }
            .rotationEffect(.degrees(editing ? (wobble ? 1.3 : -1.3) : 0))

        // 编辑态：拖动重排；非编辑态：长按弹菜单(改尺寸/删除/进排序)。
        return Group {
            if editing {
                dragReorder(decorated, kind: inst.kind)
            } else {
                decorated.contextMenu { sizeMenu(inst.kind) }
            }
        }
    }

    @ViewBuilder
    private func sizeMenu(_ kind: WidgetKind) -> some View {
        Button { dash.setSize(kind, .small) }  label: { Label("小方", systemImage: "square") }
        Button { dash.setSize(kind, .medium) } label: { Label("长条", systemImage: "rectangle") }
        Button { dash.setSize(kind, .large) }  label: { Label("大方", systemImage: "square.fill") }
        Divider()
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editing = true }
        } label: { Label("排序 / 编辑", systemImage: "arrow.up.arrow.down") }
        Button(role: .destructive) {
            withAnimation { dash.remove(kind) }
        } label: { Label("删除", systemImage: "trash") }
    }

    private var doneButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editing = false }
        } label: {
            Text("完成")
                .font(.system(size: Theme.F.body, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.branchIndicator))
                .shadow(color: Color.black.opacity(0.14), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .padding(.top, 6)
    }

    private func editBadge(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private func dragReorder(_ view: some View, kind: WidgetKind) -> some View {
        if editing {
            view
                .onDrag { dragging = kind; return NSItemProvider(object: kind.rawValue as NSString) }
                .onDrop(of: [UTType.text], delegate: WidgetReorderDrop(kind: kind, dash: dash, dragging: $dragging))
        } else {
            view
        }
    }

    private var header: some View {
        Text("桌面")
            .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("添加组件")
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textMuted)
            HStack(spacing: 8) {
                ForEach(dash.availableToAdd) { kind in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dash.add(kind) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: kind.icon).font(.system(size: 12))
                            Text(kind.displayName).font(.system(size: Theme.F.secondary, weight: .medium))
                        }
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.branchIndicator.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.top, 4)
    }
}

/// 拖动重排的 drop delegate（dragged 落到 target 之前）。
struct WidgetReorderDrop: DropDelegate {
    let kind: WidgetKind
    let dash: DashboardManager
    @Binding var dragging: WidgetKind?

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != kind else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dash.move(from, before: kind)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { true }
}
