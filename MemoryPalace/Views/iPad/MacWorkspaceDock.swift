#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let macDockEntry = UTType(exportedAs: "com.susu.MemoryPalace.mac-dock-entry", conformingTo: .data)
}

struct MacWorkspaceDock: View {
    let layout: IPadPanelLayout
    let workspaceSize: CGSize
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @Environment(\.openSettings) private var openSettings
    @State private var preferences = MacWorkspacePreferences.shared
    @State private var legacy = Page2DesktopManager.shared
    @State private var dragging: String?
    @State private var target: DropSlot?

    private struct DropSlot: Equatable { let id: String; let after: Bool }
    private var seed: [String] { legacy.dockToolIds ?? tools?.pinnedTools.map(\.id) ?? [] }
    private var itemSize: CGFloat { layout.mode == .docked ? MacShellMetrics.shared.dockItem : ShellStyle.dockHit }
    private var gap: CGFloat { layout.mode == .docked ? MacShellMetrics.shared.dockGap : 2 }
    private var items: [MacWorkspacePreferences.DockItem] {
        preferences.items(seed: seed).filter { item in
            item.kind == .divider || item.toolID == MacWorkspacePreferences.homeID ||
            item.toolID == MacWorkspacePreferences.modeID ||
            (item.toolID.flatMap { tools?.tool(byId: $0) }.map { $0.isEnabled } ?? false)
        }
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            column
            MacDockScrollView { column }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .frame(width: IPadPanelLayout.dockWidth)
        .frame(maxHeight: layout.mode == .docked ? .infinity : nil, alignment: .top)
        .contentShape(Rectangle())
        .contextMenu {
            Button("添加分隔线") { preferences.insertDivider(seed: seed) }
            Button("管理 Mac 工作区…", action: manage)
        }
        .onDisappear { dragging = nil; target = nil }
    }

    private var column: some View {
        VStack(spacing: gap) {
            ForEach(items) { item in
                let tool = descriptor(item)
                let height = item.kind == .divider ? CGFloat(18) : itemSize
                MacWorkspaceDockItem(item: item, tool: tool, size: itemSize,
                    selected: item.toolID.map { layout.isOpen($0) } ?? false,
                    dragging: dragging == item.id,
                    targetAfter: target?.id == item.id ? target?.after : nil,
                    menu: menu(item), clickMenu: item.toolID == MacWorkspacePreferences.modeID ? modeMenu : [],
                    onTap: { if let id = item.toolID { tap(id) } },
                    onBegin: {
                        #if DEBUG
                        ShellProbe.keep("[PROBE mac.dock.drag] begin \(item.id)")
                        #endif
                        dragging = item.id
                    }, onEnd: { dragging = nil; target = nil })
                    .onDrop(of: [.macDockEntry], delegate: MacWorkspaceDockDrop(
                        active: { dragging != nil }, height: height,
                        hover: { after in
                            let next = after.map { DropSlot(id: item.id, after: $0) }
                            if next != target { target = next }
                        },
                        perform: { after in
                            guard let source = dragging else { return false }
                            #if DEBUG
                            ShellProbe.keep("[PROBE mac.dock.drop] \(source) -> \(item.id) after=\(after)")
                            #endif
                            preferences.move(source, relativeTo: item.id, after: after, seed: seed)
                            target = nil; return true
                        }))
            }
            // Explicit terminal target: dropping below the last icon always appends.
            Rectangle().fill(target?.id == "end" ? Theme.branchIndicator : .clear)
                .frame(width: itemSize, height: 8)
                .contentShape(Rectangle())
                .onDrop(of: [.macDockEntry], delegate: MacWorkspaceDockDrop(
                    active: { dragging != nil }, height: 8,
                    hover: { target = $0 == nil ? nil : DropSlot(id: "end", after: true) },
                    perform: { _ in
                        guard let source = dragging else { return false }
                        preferences.move(source, relativeTo: nil, seed: seed)
                        target = nil; return true
                    }))
        }
    }

    private func descriptor(_ item: MacWorkspacePreferences.DockItem) -> RightPanelTool? {
        switch item.toolID {
        case MacWorkspacePreferences.homeID:
            return .init(id: MacWorkspacePreferences.homeID, name: "桌面", icon: "square.grid.2x2")
        case MacWorkspacePreferences.modeID:
            return .init(id: MacWorkspacePreferences.modeID, name: "面板布局", icon: layout.mode.icon)
        case .some(let id): return tools?.tool(byId: id)
        case .none: return nil
        }
    }

    private func menu(_ item: MacWorkspacePreferences.DockItem) -> [MacShellMenuItem] {
        [
            .init(title: item.kind == .divider ? "移除分隔线" : "从 Dock 移除", action: { preferences.remove(item.id, seed: seed) }),
            .init(title: "在后面添加分隔线", action: { preferences.insertDivider(after: item.id, seed: seed) }),
            .init(title: "管理 Mac 工作区…", action: manage)
        ]
    }

    /// 两档模式 + 存过的工作区（点一下切过去，plan-panel-ps 阶段 1）
    private var modeMenu: [MacShellMenuItem] {
        let modes: [MacShellMenuItem] = IPadPanelLayout.Mode.allCases.map { mode in
            .init(title: mode.label, action: {
                withAnimation(ShellStyle.structure) { layout.mode = mode }
            }, checked: mode == layout.mode)
        }
        let store = PanelWorkspaceStore.shared
        let workspaces: [MacShellMenuItem] = store.workspaces.map { w in
            .init(title: "工作区：\(w.name)", action: { PanelWorkspaceActions.activate(w.id) }, checked: store.activeId == w.id)
        }
        return modes + workspaces + [.init(title: "存为新工作区…", action: { PanelWorkspaceActions.saveAsNew() })]
    }

    private func manage() { preferences.settingsRequested = true; openSettings() }

    private func tap(_ id: String) {
        guard id != MacWorkspacePreferences.modeID else { return }
        if layout.minimized.contains(id), let grid = layout.desktopGrid(in: workspaceSize),
           let item = DesktopGridPlacer.place(DesktopGridPlacer.items(layout), grid: grid, arrangement: layout.arrangement,
                                              store: DesktopGridStore.shared).first(where: { $0.id == "t." + id }) {
            layout.restoreMacPanel(id, from: item.frame, in: workspaceSize)
        } else {
            let selecting = layout.mode == .docked && layout.isOpen(id) && !layout.detached.contains(id)
                && layout.currentTab != id && !layout.isCollapsed(layout.group(of: id))
            withAnimation(selecting ? ShellStyle.feedback : ShellStyle.structure) { layout.dockTap(id) }
        }
    }
}

private struct MacWorkspaceDockItem: View {
    let item: MacWorkspacePreferences.DockItem
    let tool: RightPanelTool?
    let size: CGFloat
    let selected: Bool
    let dragging: Bool
    let targetAfter: Bool?
    let menu: [MacShellMenuItem]
    let clickMenu: [MacShellMenuItem]
    let onTap: () -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Group {
            if item.kind == .divider {
                Rectangle().fill(ShellStyle.hairline).frame(width: 24, height: 1)
                    .frame(width: size, height: 18)
            } else {
                ToolGlyph(tool: tool, size: ShellStyle.iconSize, color: ShellStyle.secondaryText)
                    .frame(width: size, height: size)
            }
        }
        .background(ShellStyle.controlFill(selected: selected, hovered: hovered, pressed: pressed),
                    in: RoundedRectangle(cornerRadius: ShellStyle.controlRadius))
        .opacity(dragging ? 0.35 : 1)
        .overlay {
            MacShellDragSource(title: tool?.name ?? "分隔线", pasteboardType: .init(UTType.macDockEntry.identifier), payload: item.id,
                onBegin: onBegin, onEnd: { accepted in
                    #if DEBUG
                    ShellProbe.keep("[PROBE mac.dock.drag] end accepted=\(accepted)")
                    #endif
                    onEnd()
                }, onClick: { _ in onTap() },
                onPressChanged: { pressed = $0 }, menuItems: menu,
                clickMenuItems: clickMenu, keyboardActivatable: item.kind != .divider)
        }
        .overlay(alignment: targetAfter == true ? .bottom : .top) {
            if targetAfter != nil {
                Capsule().fill(Theme.branchIndicator).frame(height: 2).allowsHitTesting(false)
            }
        }
        .onHover { hovered = $0 }
        .transaction { $0.animation = nil }
        .help((tool?.name ?? "分隔线") + " · 拖动排序，右键管理")
    }
}

private struct MacWorkspaceDockDrop: DropDelegate {
    let active: () -> Bool
    let height: CGFloat
    let hover: (Bool?) -> Void
    let perform: (Bool) -> Bool
    func validateDrop(info: DropInfo) -> Bool { active() && info.hasItemsConforming(to: [.macDockEntry]) }
    func dropEntered(info: DropInfo) { if active() { hover(info.location.y >= height / 2) } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard active() else { return DropProposal(operation: .cancel) }
        hover(info.location.y >= height / 2)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { hover(nil) }
    func performDrop(info: DropInfo) -> Bool { active() && perform(info.location.y >= height / 2) }
}
#endif
