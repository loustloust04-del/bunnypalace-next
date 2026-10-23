#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct MacPanelFlight: Identifiable {
    let id = UUID()
    let destination: IPadPanelLayout.WindowFrame
    let tracksTab: Bool
}

extension IPadPanelLayout {
    func beginMacTabDrag(_ id: String) {
        guard isOpen(id), !minimized.contains(id) else { return }
        macDropTarget = nil
        macFirstClickExpandedTab = nil
        macDragGeneration += 1
        draggingTab = id
        #if DEBUG
        ShellProbe.p("[PROBE tab.source] id=\(id) types=[\(UTType.toolTab.identifier)] native=true")
        #endif
    }

    func endMacTabDrag(id: String? = nil, accepted: Bool? = nil) {
        #if DEBUG
        ShellProbe.p("[PROBE tab.end] id=\(id ?? draggingTab ?? "nil") accepted=\(accepted?.description ?? "cleanup")")
        #endif
        draggingTab = nil
        macDropTarget = nil
        macDragGeneration += 1
        // 从 fly-out 里拖走东西后它要么空了、要么换了列，收掉
        if macFlyout != nil { macFlyout = nil }
    }

    /// 工具所在列收着（右列工具钮关了 / 左、底列折成图标）时点 dock：临时弹出它所在的组（PS 点图标列里的图标）。
    /// 返回 true = 这里处理了；列看得见的一律 false，走今天的三段式（A I3 状态表）
    func macFlyoutTap(_ id: String) -> Bool {
        if !isOpen(id) {
            guard !dockShown else { return false }
            open(id)
            macFlyout = id
            return true
        }
        guard tabs.contains(id), isColumnHidden(edge(of: group(of: id))) else { return false }
        let g = group(of: id)
        if let shown = macFlyout, group(of: shown) == g, selected(in: g) == id {
            macFlyout = nil
        } else {
            select(id)
            macFlyout = id
        }
        return true
    }

    /// fly-out 此刻要画的组（它的工具还在、列还收着；否则 nil）
    var macFlyoutGroup: String? {
        guard mode == .docked, let id = macFlyout, tabs.contains(id), isColumnHidden(edge(of: group(of: id))) else { return nil }
        return group(of: id)
    }

    /// 单击选中（折着就顺手展开）；双击折 / 展**它所在的那个组**（PS 双击 tab）
    func clickMacTab(_ id: String, count: Int) {
        guard tabs.contains(id) else { return }
        let g = group(of: id)
        let collapsed = isCollapsed(g)
        let changesHeight = count == 1 ? collapsed : (count == 2 && macFirstClickExpandedTab != id)
        withAnimation(changesHeight ? ShellStyle.structure : ShellStyle.feedback) {
            if count == 1 {
                macFirstClickExpandedTab = collapsed ? id : nil
                select(id)
            } else if count == 2 {
                if selectedTool != id { selectedTool = id }
                if g != Self.mainGroup, groupSelected[g] != id { groupSelected[g] = id }
                if macFirstClickExpandedTab != id { setCollapsed(g, !collapsed) }
                macFirstClickExpandedTab = nil
            }
        }
        #if DEBUG
        ShellProbe.p("[PROBE tab.tap] id=\(id) count=\(count) collapsed=\(isCollapsed(g))")
        #endif
    }

    func macTabFrame(_ id: String) -> CGRect {
        macTabFrames[id] ?? macReturnFrame
    }

    /// 停回某个组时飞行的终点：那个组的 tab 栏（量过的）；没量过（组还没画出来 / 在收起的列里）退回主组的估算
    func macDockingFrame(for toolId: String, in size: CGSize) -> CGRect {
        let g = group(of: toolId)
        if let bar = macGroupBarFrames[g], bar.width > 0 { return bar }
        return macDockingFrame(in: size)
    }

    func macDockingFrame(in size: CGSize) -> CGRect {
        if macReturnFrame.width > 0 { return macReturnFrame }
        // 停靠壳的工具面板宽是 `toolWidth`（渲染钳后），不再是格子两列；面板收着时按存档宽估一个落点
        let frame = macShellFrame(in: size)
        let width = frame.tool ?? MacShellFrame.toolWidth(stored: toolWidth, width: size.width, dock: frame.dock,
                                                            conv: frame.conv, cardEdges: shellMetrics.cardEdges)
        // 工具面板恒在右（09-16 解耦）；dock 在右时最外沿被它占着要减掉，在左时不减（R-LD #6）
        let dockGutter = dockSide == .right ? Self.dockWidth : 0
        let inset = mode == .docked ? ShellStyle.paneInset : 0
        return CGRect(x: size.width - dockGutter - width + inset,
                      y: mode == .docked ? shellMetrics.cardGapTop : 0,
                      width: max(0, width - 2 * inset), height: ShellStyle.barHeight)
    }

    func presentMacFlight(_ id: String, from: CGRect, to: CGRect, tracksTab: Bool = false, change: () -> Void) {
        guard from.width > 0, from.height > 0, to.width > 0, to.height > 0 else {
            withAnimation(ShellStyle.structure, change)
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flights[id] = .init(x: from.minX, y: from.minY, w: from.width, h: from.height)
            macFlightTargets[id] = MacPanelFlight(destination: .init(x: to.minX, y: to.minY, w: to.width, h: to.height), tracksTab: tracksTab)
            change()
        }
    }

    func detachMacPanel(_ id: String, at point: CGPoint? = nil, in size: CGSize) {
        guard mode == .docked, isOpen(id), !minimized.contains(id) else { return }
        let from = detached.contains(id) ? currentFrame(windowId(of: id), in: size).rect : macTabFrame(id)
        // Existing model methods remain the only authority for placement and persistence.
        if let point { detach(id, at: point, in: size) } else { detach(id, in: size) }
        presentMacFlight(id, from: from, to: currentFrame(id, in: size).rect) {}
    }

    /// 停回 / 拖进 tab 栏。`group` 给了 = 进那个组的那一槽（停靠的跨组搬、同组换位）；nil = 回它原来的组
    func attachMacPanel(_ id: String, to group: String? = nil, at slot: Int? = nil, in size: CGSize) {
        guard mode == .docked, isOpen(id), !minimized.contains(id) else { return }
        let commit = {
            if let group { self.attach(id, to: group, at: slot ?? self.tabs(in: group).count) }
            else if let slot { self.attach(id, at: slot) }
            else { self.attach(id) }
        }
        guard detached.contains(id) else {
            withAnimation(ShellStyle.structure, commit)
            return
        }
        if let group, group != self.group(of: id) { setGroupHint(id, group) }
        let destination = macDockingFrame(for: id, in: size)
        presentMacFlight(id, from: currentFrame(windowId(of: id), in: size).rect, to: destination, tracksTab: true) {
            if self.edge(of: self.group(of: id)) == .right { dockShown = true }
            commit()
        }
    }

    /// 飞行前先把目标组记到映射上，终点按那个组的 tab 栏取（提交时 `attach(_:to:at:)` 会再写一遍同值）
    private func setGroupHint(_ id: String, _ group: String) {
        let value: String? = group == Self.mainGroup ? nil : group
        if dockGroupOf[id] != value { dockGroupOf[id] = value }
    }

    /// 拖到列边 / 组正文上下带：在某列某位新开一个组（浮着的一起停进去）
    func insertMacGroup(_ id: String, edge: PanelEdge, at index: Int, in size: CGSize) {
        guard mode == .docked, isOpen(id), !minimized.contains(id) else { return }
        withAnimation(ShellStyle.structure) { _ = insertGroup(with: id, edge: edge, at: index) }
    }

    /// tab 菜单「移到左栏 / 右栏」：进那一列第一个工具组的尾巴；那列没有工具组就在列尾新开一组
    func moveMacPanel(_ id: String, toColumn edge: PanelEdge, in size: CGSize) {
        guard tabs.contains(id), self.edge(of: group(of: id)) != edge else { return }
        if let target = (columnGroups[edge] ?? []).first(where: { $0 != Self.convWindowId && !tabs(in: $0).isEmpty })
            ?? (edge == .right ? Self.mainGroup : nil) {
            withAnimation(ShellStyle.structure) {
                move(id, toGroup: target, at: tabs(in: target).count)
                if edge == .right, !dockShown { dockShown = true }
            }
        } else {
            insertMacGroup(id, edge: edge, at: columnGroups[edge]?.count ?? 0, in: size)
        }
    }

    func finishMacFlight(_ id: String, token: UUID) {
        guard macFlightTargets[id]?.id == token else { return }
        macFlightTargets[id] = nil
        flights[id] = nil
    }

    func minimizeMacPanel(_ id: String, in size: CGSize) {
        let cells = DesktopGridPlacer.widgetCells(DashboardManager.shared.widgets, arrangement: arrangement)
        guard canMinimize(id, in: size, widgetCells: cells) else { return }
        let from = mode == .docked && tabs.contains(id) ? macTabFrame(id) : currentFrame(windowId(of: id), in: size).rect
        guard let grid = grid(in: size), let target = DesktopGridPlacer.landingFrame(forTool: id, layout: self, grid: grid) else {
            withAnimation(ShellStyle.structure) { minimize(id, in: size, widgetCells: cells) }
            return
        }
        presentMacFlight(id, from: from, to: target) { minimize(id, in: size, widgetCells: cells) }
    }

    func restoreMacPanel(_ id: String, from cell: CGRect, in size: CGSize) {
        guard minimized.contains(id) else { return }
        let returnsToTab = minimizedFrom[id] == "tab" && mode == .docked
        let destination = returnsToTab ? macDockingFrame(for: id, in: size) : currentFrame(id, in: size).rect
        presentMacFlight(id, from: cell, to: destination, tracksTab: returnsToTab) {
            if minimizedFrom[id] == "tab", mode == .docked, edge(of: group(of: id)) == .right { dockShown = true }
            restore(id)
            // 回到折着的左 / 底列：弹出来给她看见（右列在上一行已经打开）
            if tabs.contains(id), isColumnHidden(edge(of: group(of: id))) { macFlyout = id }
        }
    }

    func cancelMacPresentation() {
        for id in macFlightTargets.keys { flights[id] = nil }
        macFlightTargets.removeAll()
        macTabFrames.removeAll()
        macGroupBarFrames.removeAll()
        macReturnFrame = .zero
        macFirstClickExpandedTab = nil
        macFlyout = nil
        endMacTabDrag()
        snapGuides = []
    }
}

extension IPadPanelLayout.WindowFrame {
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct MacPanelFlightLayer: View {
    let layout: IPadPanelLayout
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.macFlightTargets.keys.sorted(), id: \.self) { id in
                if let target = layout.macFlightTargets[id], let origin = layout.flights[id] {
                    MacPanelFlightView(layout: layout, toolId: id, tool: toolManager?.tool(byId: id),
                                       origin: origin, flight: target)
                        .id(target.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MacPanelFlightView: View {
    let layout: IPadPanelLayout
    let toolId: String
    let tool: RightPanelTool?
    let origin: IPadPanelLayout.WindowFrame
    let flight: MacPanelFlight
    @State private var arrived = false
    @State private var measuredDestination: IPadPanelLayout.WindowFrame?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let destination = measuredDestination ?? flight.destination
        let f = reduceMotion || arrived ? destination : origin
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ToolGlyph(tool: tool, size: ShellStyle.iconSize, color: ShellStyle.secondaryText)
                Text(tool?.name ?? IPadPanelLayout.fallbackTitle(toolId))
                    .font(ShellStyle.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: min(ShellStyle.barHeight, f.h))
            Spacer(minLength: 0)
        }
        .frame(width: max(1, f.w), height: max(1, f.h))
        .background(ShellStyle.background)
        .overlay(RoundedRectangle(cornerRadius: ShellStyle.tabRadius)
            .strokeBorder(ShellStyle.hairline, lineWidth: ShellStyle.hairlineWidth))
        .clipShape(RoundedRectangle(cornerRadius: ShellStyle.tabRadius))
        .opacity(reduceMotion && !arrived ? 0 : 1)
        .offset(x: f.x, y: f.y)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            if flight.tracksTab, let rect = layout.macTabFrames[toolId] {
                measuredDestination = .init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
            }
            withAnimation(reduceMotion ? ShellStyle.feedback : ShellStyle.structure, completionCriteria: .removed) {
                arrived = true
            } completion: {
                layout.finishMacFlight(toolId, token: flight.id)
            }
        }
    }
}
#endif
