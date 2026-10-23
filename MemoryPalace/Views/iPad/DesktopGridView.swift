import SwiftUI

// 排位 / 落格规则在 `DesktopGridRules.swift`（平台无关，mac 测试目标编得到）；这里只有视图。

/// 横屏的桌面层：页 2 那份小组件（`DashboardManager.widgets`，同一个桌面的另一种排法）和缩成组件的窗口
/// （`IPadPanelLayout.minimized`）钉在聊天两侧的格子上。格线来自 `GridFrame`；两种模式都画，压在最底层——
/// 全屏模式面板开着时盖住那一侧（甲）。
///
/// 排位见 `DesktopGridPlacer`；存档**只加不删**：新来的自动填完写那一项，拖动落格写涉及的两项，
/// 存过的临时放不下就先不显示（删一个留洞，新来的填第一个空格，别人不挪）。
/// **拖动**走系统拖放（`onDrag` / `onDrop`）：按住拎起来再拖，iPad 主屏小组件的手法；跟长按菜单是一家的，
/// 按住不动出菜单、按住再动就拎起来，两者不打架。（之前用 DragGesture：按住一会再拖时长按菜单先赢，
/// 拖动永远起不来——模拟器按住 0.7s 必复现、0s 才拖得动，就是粟粟说的「推不过去」。）
/// 只能落在两区的格子里；落到别人格上两个对换（都是 1×1 时），落不下飞回；悬在格子上时画虚线 + 目标格薄荷边。
///
/// **不存「正在拖」这个状态**：系统拖放取消时没有任何回调，存了就会漏（虚线永远留在屏幕上）。
/// 落点层长在最底下、一直在，只有虚线在有东西悬停（`target != nil`）时才画。
struct DesktopGridView: View {
    let layout: IPadPanelLayout
    let grid: GridFrame
    /// 只为了给缩起来的工具算状态一行（`DesktopToolStatus`）
    var viewModel: ConversationViewModel
    #if os(iOS)
    @State private var dash = DashboardManager.shared
    @State private var store = DesktopGridStore.shared
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?

    /// 手上拎着哪块（只在松手那一下读；拖放取消后留着旧值也无害）
    @State private var draggedId: String?
    /// 悬在哪一格（`dropEntered` / `dropExited` 成对给，落下清）
    @State private var target: DesktopCell?
    /// 悬着的这一格放不放得下（决定边框是薄荷还是红）
    @State private var targetOK = true
    /// 编辑态：长按空格进入（mac 另有空格 / 工具脸右键「整理桌面」），记在哪一道触发的（「完成」胶囊浮在那一道底下）。
    /// 编辑态里空格一直画虚线——不进这个态根本看不出桌面有格子、能拖
    @State private var editing: GridFrame.Side?
    /// mac：单击选中的那块工具脸（瞬态，点空处 / Esc / 恢复清）；iPad 单击直接恢复，用不上
    @State private var selectedFace: String?
    @State private var hoveredId: String?
    #endif

    var body: some View {
        #if os(macOS)
        MacDesktopGrid(layout: layout, grid: grid, viewModel: viewModel)
        #else
        let placed = DesktopGridPlacer.place(dash.widgets.map(DesktopItem.widget) + layout.minimized.map(DesktopItem.tool),
                                             grid: grid, arrangement: layout.arrangement, store: store)
        let signature = placed.map { "\($0.id):\($0.zone.side.rawValue):\($0.col):\($0.row)" }.joined(separator: "|")
        ZStack(alignment: .topLeading) {
            dropTargets(placed)
            ForEach(placed) { p in
                cell(p)
                    .frame(width: p.frame.width, height: p.frame.height)
                    .overlay {
                        // 悬停 / 选中的薄荷边（opacity 控，不 if）
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.branchIndicator, lineWidth: selectedFace == p.id ? 2 : 1)
                            .opacity(selectedFace == p.id ? 1 : (hoveredId == p.id ? 0.6 : 0))
                            .allowsHitTesting(false)
                    }
                    .onHover { hoveredId = $0 ? p.id : (hoveredId == p.id ? nil : hoveredId) }
                    .offset(x: p.frame.minX, y: p.frame.minY)
                    .onDrag {
                        draggedId = p.id
                        #if DEBUG
                        print("[PROBE desktop] lift \(p.id)")
                        #endif
                        return NSItemProvider(object: p.id as NSString)
                    } preview: {
                        face(p).frame(width: p.frame.width, height: p.frame.height)
                    }
                    // 占着的格子也要能接：落上去两个对换
                    .onDrop(of: [.text], delegate: cellDrop(at: DesktopCell(side: p.zone.side, col: p.col, row: p.row), all: placed))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if let side = editing, let zone = grid.zone(side), zone.cols > 0 { doneChip(in: zone) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.pinnedOnDesktop, true)
        // 换排版 / 换 dock 侧 / 换模式 → 格子整个变了，编辑态跟着退，别让虚线赖在新布局上
        .onChange(of: layout.arrangement) { _, _ in editing = nil }
        .onChange(of: layout.dockSide) { _, _ in editing = nil }
        .onChange(of: layout.mode) { _, _ in editing = nil }
        // 只写**没存过**的新项（自动填位落定），和**存的那一侧已经不存在**的（dock 换边后搬过去的）；
        // 其余一律不碰——临时布局永远覆盖不了存档
        .onChange(of: signature, initial: true) { _, _ in
            let sides = Set(grid.zones.map(\.side))
            let fresh = placed.filter {
                guard let stored = store.placement(of: $0.id, in: layout.arrangement) else { return true }
                return !sides.contains(stored.side)
            }
            guard !fresh.isEmpty else { return }
            store.merge(Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0.placement) }), in: layout.arrangement)
        }
        #endif
    }

    #if os(iOS)
    // MARK: 拖动落格

    /// 落点层：每格一个透明落点，一直在（拖放没有取消回调，不能靠状态开关它）；
    /// 虚线在**编辑态**或有东西悬在格子上时画，不吃触摸。长按空格进编辑态，点空格出
    private func dropTargets(_ all: [DesktopPlaced]) -> some View {
        ForEach(grid.zones, id: \.side) { zone in
            // 09-18 清障：这里原有一块 `#if os(macOS)` 的「点泳道空白退出编辑态」，
            // 但整个 `dropTargets` 在 `#if os(iOS)` 段内，那块不编译。mac 的等价行为在
            // `MacDesktopGrid:118,138` 的 `MacShellDragSource(onClick:)` → `exit("background")`。
            ForEach(0..<zone.cols, id: \.self) { c in
                ForEach(0..<grid.rows, id: \.self) { r in
                    let f = grid.cellFrame(zone: zone, col: c, row: r)
                    let t = DesktopCell(side: zone.side, col: c, row: r)
                    let isTarget = target == t
                    Color.clear
                        .frame(width: f.width, height: f.height)
                        // 没有 contentShape 的透明色接不到落点
                        .contentShape(Rectangle())
                        .overlay {
                            if editing != nil || target != nil {
                                // 悬着的那格：放得下薄荷、放不下红（别让人以为能落）
                                let color = isTarget ? (targetOK ? Theme.branchIndicator : Color.red.opacity(0.5))
                                                     : Theme.textMuted.opacity(0.35)
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(color, style: StrokeStyle(lineWidth: isTarget ? 2 : 1,
                                                                           dash: isTarget ? [] : [5, 4]))
                                    .allowsHitTesting(false)
                            }
                        }
                        .offset(x: f.minX, y: f.minY)
                        .onDrop(of: [.text], delegate: cellDrop(at: t, all: all))
                        // 点空格：在编辑态里就退出（学 iPad 主屏点背景收工）；不在就什么都不做（mac 再清掉选中的脸）
                        .onTapGesture {
                            selectedFace = nil
                            if editing != nil { withAnimation(.easeOut(duration: 0.18)) { editing = nil } }
                        }
                        .onLongPressGesture { withAnimation(.easeOut(duration: 0.18)) { editing = zone.side } }
                }
            }
        }
    }

    /// 编辑态的「完成」胶囊：浮在触发那一道格子区的正下方
    private func doneChip(in zone: GridFrame.Zone) -> some View {
        let s = grid.spec.small, g = grid.spec.gutter
        let width = CGFloat(zone.cols) * (s + g) - g
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { editing = nil }
        } label: {
            Text("完成")
                .font(.system(size: Theme.F.secondary, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.sidebarBg.opacity(0.95)))
                .overlay(Capsule().stroke(Theme.accent.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .offset(x: zone.x, y: grid.top + CGFloat(grid.rows) * (s + g) - g + 12)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private func cellDrop(at t: DesktopCell, all: [DesktopPlaced]) -> CellDrop {
        CellDrop(entered: {
                    target = t
                    // 悬停就先裁一次，好让边框用合法 / 不合法两个颜色
                    targetOK = all.first { $0.id == draggedId }
                        .map { DesktopDropRules.dropPlan($0, at: t, all: all, grid: grid).ok } ?? true
                 },
                 exited: { if target == t { target = nil } },
                 perform: { drop(at: t, all: all) })
    }

    /// 松手：放得下就写档，放不下返回 false 让系统把预览飞回原位
    private func drop(at t: DesktopCell, all: [DesktopPlaced]) -> Bool {
        target = nil
        guard let p = all.first(where: { $0.id == draggedId }) else { return false }
        let plan = DesktopDropRules.dropPlan(p, at: t, all: all, grid: grid)
        #if DEBUG
        print("[PROBE desktop] drop \(p.id) from \(p.zone.side.rawValue):\(p.col),\(p.row) → \(t.side.rawValue):\(t.col),\(t.row) \(plan.ok ? (plan.swap.map { "对换 \($0.id)" } ?? "落格") : "飞回")")
        #endif
        if plan.ok {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { commit(p, to: t, swap: plan.swap) }
        }
        return plan.ok
    }

    /// 只写拖的这块（和被对换的那块）。对换的那块由 `dropPlan` 裁出来——
    /// 不能再靠「目标格左上角的占用者」找，多格块压住的可能不是它的左上角
    private func commit(_ p: DesktopPlaced, to t: DesktopCell, swap o: DesktopPlaced?) {
        var map: [String: DesktopGridStore.Placement] = [p.id: .init(side: t.side, col: t.col, row: t.row)]
        if let o { map[o.id] = p.placement }
        store.merge(map, in: layout.arrangement)
    }

    // MARK: 一块

    /// 只有脸，没有交互（拎起来时的预览用它）
    @ViewBuilder
    private func face(_ p: DesktopPlaced) -> some View {
        switch p.item {
        case .widget(let w): widget(w.kind, size: p.size)
        case .tool(let id):  ToolWidgetFace(tool: toolManager?.tool(byId: id), id: id,
                                            status: DesktopToolStatus.line(for: id, viewModel: viewModel))
        }
    }

    @ViewBuilder
    private func cell(_ p: DesktopPlaced) -> some View {
        switch p.item {
        case .widget(let w):
            face(p)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contextMenu { widgetMenu(w, side: p.zone.side) }
        case .tool(let id):
            face(p)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { restore(id, from: p.frame) }
                .contextMenu {
                    Button { restore(id, from: p.frame) } label: {
                        Label("恢复", systemImage: "macwindow.on.rectangle")
                    }
                    // 09-18 清障：这里原有一条 `#if os(macOS)` 的「整理桌面」，但整段在 `#if os(iOS)` 里不编译。
                    // mac 的这一条在 `MacDesktopGrid.itemMenu`（走 `editingMenu`，AppKit `NSMenu`）。
                    Button(role: .destructive) { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { layout.close(id) } } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                }
        }
    }

    /// 恢复：窗先出现在这一格（`flights` 盖住 frames），下一帧飞回原位
    private func restore(_ id: String, from cell: CGRect) {
        selectedFace = nil
        layout.flights[id] = .init(x: cell.minX, y: cell.minY, w: cell.width, h: cell.height)
        withAnimation(.easeOut(duration: 0.12)) { layout.restore(id) }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { layout.flights[id] = nil }
        }
    }

    @ViewBuilder
    private func widget(_ kind: WidgetKind, size: WidgetSize) -> some View {
        switch kind {
        case .pet:      PetWidgetView(size: size)
        case .todo:     TodoWidgetView(size: size)
        case .garden:   GardenWidgetView(size: size)
        case .contacts: ContactsWidgetView(size: size)
        case .vocab:    VocabWidgetView(size: size)
        }
    }

    @ViewBuilder
    private func widgetMenu(_ w: WidgetInstance, side: GridFrame.Side) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { editing = side }
        } label: {
            Label("整理桌面", systemImage: "square.grid.2x2")
        }
        Divider()
        if layout.arrangement == .b {
            Button { dash.setSize(w.kind, .small) }  label: { Label("小方", systemImage: "square") }
            Button { dash.setSize(w.kind, .medium) } label: { Label("长条", systemImage: "rectangle") }
            Button { dash.setSize(w.kind, .large) }  label: { Label("大方", systemImage: "square.fill") }
            Divider()
        }
        Button(role: .destructive) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dash.remove(w.kind) }
        } label: {
            Label("从桌面移除", systemImage: "trash")
        }
    }
    #endif
}

#if os(iOS)
// 09-18 清障：本文件整段在 `#if os(iOS)` 里，历史上却嵌了 6 处 `#if os(macOS)`——那些分支在 mac 上
// 根本不编译，注释却在描述 mac 行为（单击选中/双击恢复、空格右键整理桌面、Esc 退编辑态），
// 照着它写方案会翻车。全部删掉，mac 的真实路径一律在 `MacDesktopGrid`：
//   · 点/双击 → `MacShellDragSource(onClick:)` → `layout.clickMacTab`
//   · 空格右键「整理桌面 / 完成」→ `MacDesktopGrid.editingMenu`（AppKit `NSMenu`，`:118,138,251`）
//   · 组件右键「整理桌面」→ `MacDesktopGrid.itemMenu`（`:258`）
//   · Esc 退编辑态 → `MacDesktopGrid:84` `onExitCommand`
//   · 点泳道空白退编辑态 → `MacShellDragSource(onClick:)` → `exit("background")`
// 连带删掉三个只剩空壳的 modifier：`ToolFaceTap` / `EmptyCellMenu` / `DesktopEscape`。

/// 一格落点。提议一律 `.move`（`.cancel` 不会回调 `performDrop`，状态清不掉），放不放得下在 `perform` 里裁
private struct CellDrop: DropDelegate {
    let entered: () -> Void
    let exited: () -> Void
    let perform: () -> Bool

    func dropEntered(info: DropInfo) { entered() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { exited() }
    func performDrop(info: DropInfo) -> Bool { perform() }
}

#endif

/// 缩起来的工具，脸上那行状态。**没有真实数据源的工具一律返回 nil**——
/// 硬凑「已打开」「后台运行中」只是废话文案。
///
/// 现在只有 CC 终端有源（`ccBridgeSessionName` + `CCBridgeWebSocketClient.isConnected`）。
/// 其余 14 个工具要这一行，得各自面板往外暴露状态（工具插件化的活），见 `review-ipad-step3.md` 技术债。
@MainActor
enum DesktopToolStatus {
    static func line(for toolId: String, viewModel: ConversationViewModel) -> String? {
        switch toolId {
        case "ccTerminal":
            let session = viewModel.selectedConversation?.ccBridgeSessionName ?? "mp-cc"
            let state = TerminalWindowStore.shared.sessionStates[session]
            // 窗口名不露 session 名（T52）；对话终端明知是 CC → engine 兜底 claude
            let title = TerminalTitle.resolve(title: state?.title, engine: state?.engine ?? "claude", code: session)
            return title + (CCBridgeWebSocketClient.shared.isConnected ? " · 已连接" : " · 未连接")
        default:
            return nil
        }
    }
}

/// 缩成组件的窗口的脸：图标 + 名 + （有源的话）状态一行。点它飞回窗口 / tab
struct ToolWidgetFace: View {
    let tool: RightPanelTool?
    let id: String
    /// 缩窗飞行途中那张脸不传（`FloatingWindow` 拿不到 viewModel）；落到格子上就有了
    var status: String? = nil

    var body: some View {
        #if os(macOS)
        VStack(spacing: 6) {
            ToolGlyph(tool: tool, size: ShellStyle.iconSize, color: ShellStyle.secondaryText)
            Text(tool?.name ?? IPadPanelLayout.fallbackTitle(id))
                .font(ShellStyle.bodyFont)
                .foregroundStyle(ShellStyle.text)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(ShellStyle.secondaryFont)
                    .foregroundStyle(ShellStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(MacShellWidgetSurface())
        .accessibilityLabel("\(tool?.name ?? id)，双击恢复")
        #else
        VStack(spacing: 6) {
            ToolGlyph(tool: tool, size: 26, color: Theme.textSecondary)
            Text(tool?.name ?? IPadPanelLayout.fallbackTitle(id))
                .font(.system(size: Theme.F.secondary, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.sidebarBg.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.55), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel("\(tool?.name ?? id)，点击恢复")
        #endif
    }
}
