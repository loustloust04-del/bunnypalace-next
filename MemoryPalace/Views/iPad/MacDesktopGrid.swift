#if os(macOS)
import SwiftUI

struct MacDesktopGrid: View {
    let layout: IPadPanelLayout
    let grid: GridFrame
    let viewModel: ConversationViewModel
    @State private var dash = DashboardManager.shared
    @State private var store = DesktopGridStore.shared
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @State private var editing: GridFrame.Side?
    @State private var selected: String?
    @State private var hovered: String?
    @State private var dragged: String?
    @State private var target: DesktopCell?
    @State private var focusRequest = 0
    @FocusState private var focused: Bool

    private var size: CGSize { CGSize(width: grid.width, height: grid.height) }
    private var placed: [DesktopPlaced] {
        DesktopGridPlacer.place(dash.widgets.map(DesktopItem.widget) + layout.minimized.map(DesktopItem.tool),
                               grid: grid, arrangement: layout.arrangement, store: store)
    }
    private var editableZones: [GridFrame.Zone] {
        grid.zones.filter { zone in
            guard zone.cols > 0, grid.rows > 0 else { return false }
            guard layout.mode == .docked else { return true }
            let toolsSide = IPadPanelLayout.toolsSide
            if zone.side == toolsSide {
                let groups = layout.visibleGroups(.right)
                return !layout.dockShown || groups.isEmpty || groups.allSatisfy(layout.isCollapsed)
            }
            return !layout.leftColumnVisible
        }
    }

    var body: some View {
        let all = placed
        let signature = all.map { "\($0.id):\($0.zone.side.rawValue):\($0.col):\($0.row)" }.joined(separator: "|")
        ZStack(alignment: .topLeading) {
            ForEach(editableZones, id: \.side) { zone in
                lane(zone)
            }
            ForEach(all) { item in
                tile(item)
            }
            if let target, let item = all.first(where: { $0.id == dragged }), let zone = grid.zone(target.side) {
                let plan = DesktopDropRules.dropPlan(item, at: target, all: all, grid: grid)
                let rect = grid.cellFrame(zone: zone, col: target.col, row: target.row,
                                          colSpan: item.colSpan, rowSpan: item.rowSpan)
                RoundedRectangle(cornerRadius: ShellStyle.cellRadius)
                    .fill(plan.ok ? ShellStyle.selection : Color.red.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: ShellStyle.cellRadius)
                            .strokeBorder(plan.ok ? Theme.branchIndicator : Color.red.opacity(0.6), lineWidth: 2)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
            if let side = editing, let zone = editableZones.first(where: { $0.side == side }) {
                Button { exit("done") } label: {
                    Label("完成", systemImage: "checkmark")
                        .font(ShellStyle.secondaryFont)
                }
                .buttonStyle(MacShellButton(selected: true, height: 20))
                .help("完成桌面整理（Esc）")
                .frame(width: laneWidth(zone))
                .offset(x: zone.x, y: max(0, grid.top - 20))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.pinnedOnDesktop, true)
        .focusable(editing != nil || selected != nil)
        .focusEffectDisabled()
        .focused($focused)
        .task(id: focusRequest) {
            guard editing != nil || selected != nil else { return }
            await Task.yield()
            guard !Task.isCancelled, editing != nil || selected != nil else { return }
            focused = true
            probe("focus", "request=\(focusRequest)")
        }
        .onExitCommand { exit("escape") }
        .onChange(of: focused) { _, value in probe("focus", "focused=\(value)") }
        .onChange(of: layout.arrangement) { _, _ in exit("arrangement") }
        .onChange(of: layout.dockSide) { _, _ in exit("dock-side") }
        .onChange(of: layout.mode) { _, _ in exit("mode") }
        .onChange(of: editableZones) { _, zones in
            if let editing, !zones.contains(where: { $0.side == editing }) { exit("covered-or-zero-columns") }
            if let selected, let item = all.first(where: { $0.id == selected }),
               !zones.contains(where: { $0.side == item.zone.side }) { exit("selection-covered") }
        }
        .onChange(of: grid) { _, _ in target = nil }
        .onDisappear { exit("disappear") }
        .onChange(of: signature, initial: true) { _, _ in
            let sides = Set(grid.zones.map(\.side))
            let fresh = all.filter {
                guard let saved = store.placement(of: $0.id, in: layout.arrangement) else { return true }
                return !sides.contains(saved.side)
            }
            if !fresh.isEmpty {
                store.merge(Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0.placement) }), in: layout.arrangement)
            }
            if let selected, !all.contains(where: { $0.id == selected }) { self.selected = nil }
        }
    }

    private func laneWidth(_ zone: GridFrame.Zone) -> CGFloat {
        CGFloat(zone.cols) * grid.spec.small + CGFloat(zone.cols - 1) * grid.spec.gutter
    }

    private func lane(_ zone: GridFrame.Zone) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: laneWidth(zone), height: grid.height - grid.top)
                .overlay {
                    MacShellDragSource(title: "桌面空白", payload: nil,
                        onClick: { _ in exit("background") },
                        onLongPress: { enter(zone.side, reason: "long-press") },
                        menuItems: editingMenu(zone.side),
                        onMenu: { probe("menu.open", "windowPoint=\($0) side=\(zone.side.rawValue)") })
                }
                .offset(x: zone.x, y: grid.top)
            ForEach(0..<zone.cols, id: \.self) { col in
                ForEach(0..<grid.rows, id: \.self) { row in
                    let cell = DesktopCell(side: zone.side, col: col, row: row)
                    let rect = grid.cellFrame(zone: zone, col: col, row: row)
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .overlay {
                            RoundedRectangle(cornerRadius: ShellStyle.cellRadius)
                                .strokeBorder(ShellStyle.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .opacity(editing != nil || dragged != nil ? 1 : 0)
                                .allowsHitTesting(false)
                        }
                        .overlay {
                            MacShellDragSource(title: "桌面空格", payload: nil,
                                onClick: { _ in exit("background") },
                                onLongPress: { enter(zone.side, reason: "long-press") },
                                menuItems: editingMenu(zone.side),
                                onMenu: { probe("menu.open", "windowPoint=\($0) side=\(zone.side.rawValue)") })
                        }
                        .onDrop(of: [.utf8PlainText], delegate: dropDelegate(cell))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }

    private func tile(_ item: DesktopPlaced) -> some View {
        let visible = editableZones.contains { $0.side == item.zone.side }
        return face(item)
            .frame(width: item.frame.width, height: item.frame.height)
            .overlay {
                RoundedRectangle(cornerRadius: ShellStyle.cellRadius)
                    .strokeBorder(Theme.branchIndicator, lineWidth: selected == item.id ? 2 : 1)
                    .padding(3)
                    .opacity(selected == item.id ? 1 : (hovered == item.id ? 0.45 : 0))
                    .animation(ShellStyle.feedback, value: selected)
                    .animation(ShellStyle.feedback, value: hovered)
                    .allowsHitTesting(false)
            }
            .overlay {
                if visible, editing != nil || isTool(item) {
                    MacShellDragSource(title: title(item), pasteboardType: .string, payload: item.id,
                        onBegin: {
                            dragged = item.id
                            select(item)
                            probe("lift", "id=\(item.id)")
                        },
                        onEnd: { accepted in
                            probe(accepted ? "end" : "flyback", "id=\(item.id)")
                            dragged = nil
                            target = nil
                        },
                        onClick: { count in
                            if count == 2, case .tool(let id) = item.item { restore(id, item: item) }
                            else { select(item) }
                        },
                        onLongPress: { enter(item.zone.side, reason: "long-press") },
                        menuItems: itemMenu(item), preview: {
                            let renderer = ImageRenderer(content: face(item)
                                .frame(width: item.frame.width, height: item.frame.height)
                                .environment(\.pinnedOnDesktop, true))
                            renderer.scale = 2
                            return renderer.nsImage
                        }, onMenu: { probe("menu.open", "windowPoint=\($0) id=\(item.id)") })
                }
            }
            .contextMenu {
                ForEach(Array(itemMenu(item).enumerated()), id: \.offset) { index, menu in
                    Button(menu.title, action: menu.action)
                        .onAppear { if index == 0 { probe("menu.open", "id=\(item.id) systemMenu=true") } }
                }
            }
            .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
            // S1-6：桌面小组件可拖，悬停换手型
            .hoverCursor(.openHand, hold: dragged == item.id)
            .onDrop(of: [.utf8PlainText], delegate: dropDelegate(.init(side: item.zone.side, col: item.col, row: item.row)))
            .opacity(isFlying(item) ? 0 : (dragged == item.id ? 0.35 : 1))
            .allowsHitTesting(visible && !isFlying(item))
            .offset(x: item.frame.minX, y: item.frame.minY)
            .animation(ShellStyle.structure, value: item.frame)
            .accessibilityAction(named: "整理桌面") { enter(item.zone.side, reason: "accessibility") }
    }

    private func dropDelegate(_ cell: DesktopCell) -> MacDesktopDrop {
        MacDesktopDrop(active: { dragged != nil && editableZones.contains { $0.side == cell.side } },
            entered: {
                target = cell
                probe("target", "side=\(cell.side.rawValue) col=\(cell.col) row=\(cell.row)")
            }, exited: { if target == cell { target = nil } }, perform: {
                defer { target = nil }
                guard let item = placed.first(where: { $0.id == dragged }),
                      editableZones.contains(where: { $0.side == cell.side }) else { return false }
                let plan = DesktopDropRules.dropPlan(item, at: cell, all: placed, grid: grid)
                guard plan.ok else { probe("reject", "id=\(item.id)"); return false }
                var changes: [String: DesktopGridStore.Placement] = [item.id: .init(side: cell.side, col: cell.col, row: cell.row)]
                if let other = plan.swap { changes[other.id] = item.placement }
                withAnimation(ShellStyle.structure) { store.merge(changes, in: layout.arrangement) }
                probe(plan.swap == nil ? "drop" : "swap", "id=\(item.id) other=\(plan.swap?.id ?? "nil")")
                return true
            })
    }

    private func enter(_ side: GridFrame.Side, reason: String) {
        guard editableZones.contains(where: { $0.side == side }) else { probe("edit.reject", side.rawValue); return }
        withAnimation(ShellStyle.feedback) { editing = side }
        focusRequest += 1
        probe("edit", "side=\(side.rawValue) reason=\(reason)")
    }

    private func exit(_ reason: String) {
        withAnimation(ShellStyle.feedback) { editing = nil; selected = nil; target = nil; dragged = nil }
        focused = false
        focusRequest += 1
        probe("exit", reason)
    }

    private func select(_ item: DesktopPlaced) {
        withAnimation(ShellStyle.feedback) { selected = item.id }
        focusRequest += 1
        probe("select", "id=\(item.id)")
    }

    private func restore(_ id: String, item: DesktopPlaced) {
        selected = nil
        probe("restore", "id=\(id)")
        layout.restoreMacPanel(id, from: item.frame, in: size)
    }

    private func editingMenu(_ side: GridFrame.Side) -> [MacShellMenuItem] {
        [.init(title: editing == nil ? "整理桌面" : "完成") {
            probe("menu", "side=\(side.rawValue)")
            if editing == nil { enter(side, reason: "context-menu") } else { exit("context-menu") }
        }]
    }

    private func itemMenu(_ item: DesktopPlaced) -> [MacShellMenuItem] {
        var menu = editingMenu(item.zone.side)
        switch item.item {
        case .tool(let id):
            menu.insert(.init(title: "恢复") { restore(id, item: item) }, at: 0)
            menu.append(.init(title: "关闭") { withAnimation(ShellStyle.structure) { layout.close(id) } })
        case .widget(let widget):
            if layout.arrangement == .b {
                menu += [.init(title: "小方") { dash.setSize(widget.kind, .small) },
                         .init(title: "长条") { dash.setSize(widget.kind, .medium) },
                         .init(title: "大方") { dash.setSize(widget.kind, .large) }]
            }
            menu.append(.init(title: "从桌面移除") { withAnimation(ShellStyle.structure) { dash.remove(widget.kind) } })
        }
        return menu
    }

    private func isTool(_ item: DesktopPlaced) -> Bool {
        if case .tool = item.item { return true }
        return false
    }

    private func isFlying(_ item: DesktopPlaced) -> Bool {
        if case .tool(let id) = item.item { return layout.macFlightTargets[id] != nil }
        return false
    }

    private func title(_ item: DesktopPlaced) -> String {
        switch item.item {
        case .tool(let id): return toolManager?.tool(byId: id)?.name ?? IPadPanelLayout.fallbackTitle(id)
        case .widget(let widget): return widget.kind.displayName
        }
    }

    @ViewBuilder
    private func face(_ item: DesktopPlaced) -> some View {
        switch item.item {
        case .tool(let id):
            ToolWidgetFace(tool: toolManager?.tool(byId: id), id: id, status: DesktopToolStatus.line(for: id, viewModel: viewModel))
                .accessibilityAction(named: "恢复") { restore(id, item: item) }
                .accessibilityAction(named: "选择") { select(item) }
        case .widget(let widget):
            switch widget.kind {
            case .pet: PetWidgetView(size: item.size)
            case .todo: TodoWidgetView(size: item.size)
            case .garden: GardenWidgetView(size: item.size)
            case .contacts: ContactsWidgetView(size: item.size)
            case .vocab: VocabWidgetView(size: item.size)
            }
        }
    }

    private func probe(_ event: String, _ detail: String) {
        #if DEBUG
        ShellProbe.p("[PROBE desk.\(event)] \(detail)")
        #endif
    }
}

private struct MacDesktopDrop: DropDelegate {
    let active: () -> Bool
    let entered: () -> Void
    let exited: () -> Void
    let perform: () -> Bool
    func validateDrop(info: DropInfo) -> Bool { active() && info.hasItemsConforming(to: [.utf8PlainText]) }
    func dropEntered(info: DropInfo) { if active() { entered() } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: active() ? .move : .cancel) }
    func dropExited(info: DropInfo) { exited() }
    func performDrop(info: DropInfo) -> Bool { active() && perform() }
}
#endif
