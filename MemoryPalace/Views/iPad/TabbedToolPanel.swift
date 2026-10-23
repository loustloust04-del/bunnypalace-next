import SwiftUI

/// 全屏模式的右栏：**一组 tab**（tab 栏 + 当前 tab 的内容），不再是 N 张卡竖排。
/// 「两个面板放一起就变成 tab，竖着的当 dock 用」（粟粟 09-05）。
///
/// - iPad tab 栏：选中的显示 图标 + 名 + ×，其余只有图标；mac 常驻名称与固定关闭区，切选不改命中位置
///   （横向 ScrollView 会吞 Button 的 tap，踩过）
/// - 长按任一 tab：关闭 / 浮出（变成一扇盖在正文上的 `FloatingWindow`，头上有停回钮）
/// - 内容 3 个同时活着（ZStack 切显隐），切 tab 不重建浏览器 / 终端；开销与之前 3 张卡相同
/// - mac（plan-mac-shape A2a）：tab 可拖——丢到别的 tab 左右半槽换位、丢到组正文追加到尾、丢到工作区空处浮出、
///   丢到浮窗标题栏回组；悬停画目标，松手才写；双击折成标题线，正文压高保活
struct TabbedToolPanel: View {
    let layout: IPadPanelLayout
    let availableSize: CGSize
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    /// mac 停靠壳：画哪个组（plan-panel-ps）。nil = 全部停靠组的投影（iPad 的样子）
    var groupId: String? = nil
    /// 这个组在横排的底列里：正文三带按 x 分
    var horizontal = false
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?

    /// 每个 tab 此刻的宽（半槽要它）
    @State private var tabWidths: [String: CGFloat] = [:]
    #if os(macOS)
    /// tab 栏可用宽（尾部占位量出来的）。塞不下的 tab 收进「+N」菜单（plan-mac-subapp-appearance §1.2）
    @State private var macBarWidth: CGFloat = 0
    #endif
    /// 悬停槽位；mac 在原生拖放结束时统一清理。
    @State private var insertSlot: Int?
    @State private var slotOwner: String?
    @State private var bodyTargeted = false
    @State private var hoveredTab: String?
    #if os(macOS)
    @State private var pressedTab: String?
    /// 正文三带的悬停分区 + 正文此刻的尺寸（分区按正文本地坐标，不含 tab 栏）
    @State private var bodyZone: GroupBodyDrop.Zone?
    @State private var bodySize: CGSize = .zero
    #endif

    private var tabs: [String] { groupId.map(layout.tabs(in:)) ?? layout.tabs }
    private var current: String? { groupId.map(layout.selected(in:)) ?? layout.currentTab }
    private var collapsed: Bool { groupId.map(layout.isCollapsed) ?? layout.tabGroupCollapsed }

    var body: some View {
        let tabs = tabs
        let current = current
        let collapsed = collapsed
        VStack(spacing: 0) {
            tabBar(tabs, current: current)
            ZStack {
                ForEach(tabs, id: \.self) { id in
                    RightPanelToolContent(toolId: id, selectedToolId: .constant(id),
                                          viewModel: viewModel, stickerVM: stickerVM)
                        #if os(macOS)
                        .opacity(id == current && layout.macFlightTargets[id] == nil ? 1 : 0)
                        .accessibilityHidden(id != current || collapsed)
                        .allowsHitTesting(id == current && layout.macFlightTargets[id] == nil)
                        .environment(\.isFrontmostTool, id == current && !collapsed && layout.macFlightTargets[id] == nil)
                        #else
                        .opacity(id == current ? 1 : 0)
                        .allowsHitTesting(id == current)
                        #endif
                }
            }
            // 折叠 = 高 0 不移除（浏览器 / 终端不重建）
            .frame(maxWidth: .infinity, maxHeight: collapsed ? 0 : .infinity)
            .clipped()
            #if os(macOS)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { bodySize = $0 }
            .overlay {
                ShellDropHighlight(active: bodyTargeted && layout.draggingTab != nil && (bodyZone ?? .merge) == .merge)
                    .padding(4)
            }
            .overlay(alignment: bandAlignment) {
                if bodyTargeted, layout.draggingTab != nil, let zone = bodyZone, zone != .merge {
                    ShellDropBand(horizontal: horizontal)
                }
            }
            .modifier(BodyDrop(perform: dropOnBody, located: { bodyZone = zone(at: $0) },
                               targeted: $bodyTargeted, draggingTab: { layout.draggingTab }))
            #else
            .modifier(BodyDrop(perform: { _ in dropToEnd() }, located: { _ in }, targeted: $bodyTargeted, draggingTab: { layout.draggingTab }))
            #endif
            #if os(macOS)
            .allowsHitTesting(!collapsed)
            #endif
        }
        #if os(macOS)
        // `ignoresSafeAreaEdges: []`：停靠壳里这列紧贴标题行，Color 背景默认漫进顶部安全区会盖死标题行右端的钮（09-18，同 PanelChrome）
        .background(ShellStyle.chrome, ignoresSafeAreaEdges: [])
        .environment(\.inGlassChrome, MacGlass.shared.enabled)
        .onChange(of: layout.macDragGeneration) { _, _ in
            if layout.draggingTab == nil { insertSlot = nil; slotOwner = nil; bodyTargeted = false; bodyZone = nil }
        }
        .onDisappear { insertSlot = nil; slotOwner = nil; bodyTargeted = false; bodyZone = nil }
        .animation(ShellStyle.structure, value: collapsed)
        #else
        .background(Theme.sidebarBg.ignoresSafeArea(edges: .vertical))
        #endif
    }

    private func tabBar(_ tabs: [String], current: String?) -> some View {
        #if os(macOS)
        let shown = Self.macVisibleTabs(tabs, current: current, width: macBarWidth)
        #else
        let shown = tabs
        #endif
        return HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()).filter { shown.contains($0.element) }, id: \.element) { i, id in
                tab(id, index: i, count: tabs.count, selected: id == current)
            }
            #if os(macOS)
            if shown.count < tabs.count {
                overflowMenu(tabs.filter { !shown.contains($0) })
            }
            // 定高：只给 minHeight 的 Color 会吃掉 VStack 提议的全部高度，tab 栏跟正文对半分（09-08 实测上半空）
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: ShellStyle.tabHeight)
                // 收起了 tab 时让可见 tab 先分宽，不然尾部占位跟它们平分、名字被挤成「…」
                .layoutPriority(shown.count < tabs.count ? -1 : 0)
                .contentShape(Rectangle())
                .overlay(ShellDropHighlight(active: insertSlot == tabs.count && layout.draggingTab != nil))
                .onDrop(of: [.toolTab], delegate: ToolTabDropZone(name: "tail",
                                                                hovering: { previewSlot($0 ? tabs.count : nil, owner: "tail") },
                                                                draggingTab: { layout.draggingTab },
                                                                perform: { _ in dropToEnd() }))
            #else
            Spacer(minLength: 0)
            #endif
        }
        .padding(.horizontal, 8)
        #if os(macOS)
        .padding(.vertical, 3)
        #else
        .padding(.top, 6)
        .padding(.bottom, 4)
        #endif
        #if os(macOS)
        // 可见 tab 永远塞得下，所以 HStack 宽 = 提议宽（尾部占位吃掉剩余），量它不会跟可见数互相追
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { macBarWidth = $0 }
        #endif
        #if os(macOS)
        .overlay(alignment: .bottom) {
            // 全屏模式的工具面板平铺在桌布上，tab 栏底这条线也一起收（R-FS S1.2；本 view 只在停靠时用）
            if MacShellMetrics.shared.panelHairline > 0 {
                Rectangle().fill(ShellStyle.hairline).frame(height: ShellStyle.hairlineWidth).allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ShellStyle.coordinateSpace)) } action: { frame in
            if let groupId { layout.macGroupBarFrames[groupId] = frame }
            if groupId == nil || groupId == IPadPanelLayout.mainGroup { layout.macReturnFrame = frame }
        }
        #endif
    }

    @ViewBuilder
    private func tab(_ id: String, index: Int, count: Int, selected: Bool) -> some View {
        #if os(macOS)
        macTab(id, index: index, count: count, selected: selected)
        #else
        let tool = toolManager?.tool(byId: id)
        let name = tool?.name ?? IPadPanelLayout.fallbackTitle(id)
        HStack(spacing: 5) {
            ToolGlyph(tool: tool, size: 15, color: selected ? Theme.branchIndicator : Theme.textSecondary)
                .frame(width: selected ? 20 : 36, height: 34)
            if selected {
                Text(name)
                    .font(.system(size: Theme.F.secondary, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { layout.close(id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 28, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
                .accessibilityLabel("关闭\(name)")
            }
        }
        .padding(.leading, selected ? 10 : 0)
        .padding(.trailing, selected ? 2 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.branchIndicator)
                .opacity(selected ? 0.18 : (hoveredTab == id ? 0.08 : 0))
        )
        .overlay(alignment: .leading) { insertLine.opacity(insertSlot == index ? 1 : 0).offset(x: -3) }
        .overlay(alignment: .trailing) { insertLine.opacity(insertSlot == count && index == count - 1 ? 1 : 0).offset(x: 3) }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidths[id] = $0 }
        .onHover { hoveredTab = $0 ? id : (hoveredTab == id ? nil : hoveredTab) }
        .modifier(IPadTabTap(id: id, selected: selected, layout: layout))
        .contextMenu {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { layout.detach(id, in: availableSize) }
            } label: {
                Label("浮出", systemImage: "macwindow.on.rectangle")
            }
            Button {
                let cells = DesktopGridPlacer.widgetCells(DashboardManager.shared.widgets, arrangement: layout.arrangement)
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { _ = layout.minimize(id, in: availableSize, widgetCells: cells) }
            } label: {
                Label("缩成小组件", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { layout.close(id) }
            } label: {
                Label("关闭", systemImage: "xmark")
            }
        }
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        #endif
    }

    #if os(macOS)
    private func macTab(_ id: String, index: Int, count: Int, selected: Bool) -> some View {
        let tool = toolManager?.tool(byId: id)
        let name = tool?.name ?? IPadPanelLayout.fallbackTitle(id)
        let shifted: CGFloat = insertSlot.map { $0 <= index ? 3.0 : -3.0 } ?? 0
        return HStack(spacing: 2) {
            HStack(spacing: 5) {
                ToolGlyph(tool: tool, size: ShellStyle.iconSize, color: ShellStyle.secondaryText)
                Text(name)
                    .font(ShellStyle.bodyFont)
                    .foregroundStyle(selected ? ShellStyle.text : ShellStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: ShellStyle.tabHeight)
            .contentShape(Rectangle())
            .overlay {
                MacShellDragSource(title: name, payload: id,
                    onBegin: { layout.beginMacTabDrag(id) },
                    onEnd: { accepted in layout.endMacTabDrag(id: id, accepted: accepted) },
                    onClick: { layout.clickMacTab(id, count: $0) },
                    onPressChanged: { pressedTab = $0 ? id : (pressedTab == id ? nil : pressedTab) },
                    menuItems: macTabMenu(id))
            }
            Button {
                withAnimation(ShellStyle.structure) { layout.close(id) }
            } label: {
                MacShellLabel(symbol: "xmark")
            }
            .buttonStyle(MacShellButton(width: ShellStyle.closeButtonWidth))
            .opacity(selected || hoveredTab == id ? 1 : 0)
            .allowsHitTesting(selected || hoveredTab == id)
            .accessibilityLabel("关闭\(name)")
            .help("关闭\(name)")
        }
        .padding(.leading, 7)
        .frame(maxWidth: .infinity)
        .modifier(MacShellControlSurface(selected: selected, hovered: hoveredTab == id, pressed: pressedTab == id))
        .offset(x: shifted)
        .animation(ShellStyle.feedback, value: insertSlot)
        .animation(ShellStyle.feedback, value: hoveredTab)
        .overlay(alignment: .leading) { insertLine.opacity(insertSlot == index ? 1 : 0).offset(x: -3) }
        .overlay(alignment: .trailing) { insertLine.opacity(insertSlot == count && index == count - 1 ? 1 : 0).offset(x: 3) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ShellStyle.coordinateSpace)) } action: {
            tabWidths[id] = $0.width
            layout.macTabFrames[id] = $0
        }
        .onHover { hoveredTab = $0 ? id : (hoveredTab == id ? nil : hoveredTab) }
        // S1-6：tab 可拖出去变浮窗 / 拖着换位，悬停换手型
        .hoverCursor(.openHand, hold: layout.draggingTab == id)
        .onDrop(of: [.toolTab], delegate: TabSlotDrop(tabIndex: index, width: tabWidths[id] ?? 60,
            onSlot: { previewSlot($0, owner: id) }, draggingTab: { layout.draggingTab }, perform: dropToSlot))
        .opacity(layout.macFlightTargets[id] == nil ? 1 : 0)
        .allowsHitTesting(layout.macFlightTargets[id] == nil)
        .help("\(name)：拖动排列或浮出；双击折叠")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "选择") { layout.clickMacTab(id, count: 1) }
        .accessibilityAction(named: "折叠或展开") {
            let g = layout.group(of: id)
            withAnimation(ShellStyle.structure) { layout.setCollapsed(g, !layout.isCollapsed(g)) }
        }
    }

    /// 图标 + 至少 3–4 个字 + 关闭钮占位；72 时名字只剩一个字（09-24 实拍）
    static let macMinTabWidth: CGFloat = 100
    static let macOverflowWidth: CGFloat = 46

    /// 放得下几个显示几个（按原顺序），选中的那个永远在里面；width 还没量到（0）时只放选中的
    static func macVisibleTabs(_ tabs: [String], current: String?, width: CGFloat) -> [String] {
        let avail = width - 16
        let step = macMinTabWidth + 4
        if CGFloat(tabs.count) * step - 4 <= avail { return tabs }
        let fit = max(1, Int((avail - macOverflowWidth) / step))
        var shown = Array(tabs.prefix(fit))
        if let current, tabs.contains(current), !shown.contains(current) {
            shown[shown.count - 1] = current
        }
        return tabs.filter { shown.contains($0) }
    }

    private func overflowMenu(_ hidden: [String]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { id in
                Button(toolManager?.tool(byId: id)?.name ?? IPadPanelLayout.fallbackTitle(id)) {
                    layout.clickMacTab(id, count: 1)
                }
            }
        } label: {
            // 一段 Text：borderless Menu 会把 label 里的 Image 挪到最前面
            Text("+\(hidden.count) \(Image(systemName: "chevron.down"))")
                .font(ShellStyle.secondaryFont.weight(.medium))
                .foregroundStyle(ShellStyle.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: ShellStyle.chipHeight)
        .overlay {
            RoundedRectangle(cornerRadius: ShellStyle.controlRadius, style: .continuous)
                .strokeBorder(ShellStyle.hairline, lineWidth: ShellStyle.hairlineWidth)
                .allowsHitTesting(false)
        }
        .help("还开着 \(hidden.count) 个工具")
        .accessibilityLabel("更多工具，\(hidden.count) 个")
    }

    private func macTabMenu(_ id: String) -> [MacShellMenuItem] {
        let here = layout.edge(of: layout.group(of: id))
        let moves: [MacShellMenuItem] = [(PanelEdge.left, "移到左栏"), (.right, "移到右栏"), (.bottom, "移到底栏")]
            .filter { $0.0 != here }
            .map { edge, title in .init(title: title) { layout.moveMacPanel(id, toColumn: edge, in: availableSize) } }
        // PS 栏顶的 »：整列折成图标，点 dock 图标临时弹出（plan-panel-ps 阶段 4）。放菜单不放 tab 栏——
        // tab 栏里多一枚钮会把每个 tab 的份额从 ~83 挤到 ~71，名字被截成「…」（09-24 实拍）
        let collapse: [MacShellMenuItem] = here.map { edge in
            [.init(title: layout.isColumnHidden(edge) ? "展开这一栏" : "这一栏折成图标") {
                withAnimation(ShellStyle.structure) { layout.toggleColumnCollapsed(edge) }
            }]
        } ?? []
        return moves + collapse + [
            .init(title: "浮出") { layout.detachMacPanel(id, in: availableSize) },
            .init(title: "缩成小组件") { layout.minimizeMacPanel(id, in: availableSize) },
            .init(title: "关闭") { withAnimation(ShellStyle.structure) { layout.close(id) } }
        ]
    }

    private func previewSlot(_ slot: Int?, owner: String) {
        if let slot {
            slotOwner = owner
            insertSlot = slot
        } else if slotOwner == owner {
            slotOwner = nil
            insertSlot = nil
        }
    }
    #endif

    private var insertLine: some View {
        Capsule().fill(Theme.branchIndicator).frame(width: 2, height: 26)
    }

    #if os(macOS)
    private var bandAlignment: Alignment {
        switch bodyZone {
        case .before: return horizontal ? .leading : .top
        case .after: return horizontal ? .trailing : .bottom
        default: return .center
        }
    }

    private func zone(at point: CGPoint) -> GroupBodyDrop.Zone {
        guard groupId != nil else { return .merge }
        return horizontal ? GroupBodyDrop.resolve(position: point.x, extent: bodySize.width)
                          : GroupBodyDrop.resolve(position: point.y, extent: bodySize.height)
    }

    /// 松手在正文：中间并进来；上 / 下带在这个组前 / 后新开一组（坐标按这一次松手重新分区）
    private func dropOnBody(_ point: CGPoint) -> Bool {
        let zone = zone(at: point)
        bodyZone = nil
        guard zone != .merge, let groupId, let id = layout.draggingTab,
              let edge = layout.edge(of: groupId),
              let index = layout.columnGroups[edge]?.firstIndex(of: groupId) else { return dropToEnd() }
        layout.draggingTab = nil
        // 这组只有它自己：拖到自己边上 = 不动
        if layout.tabs(in: groupId) == [id] { return true }
        layout.insertMacGroup(id, edge: edge, at: zone == .before ? index : index + 1, in: availableSize)
        return true
    }
    #endif

    /// 松手落在某个半槽：来源是 tab 就换位（跨组就搬过来），是浮窗标题就停回并插到这一槽
    private func dropToSlot(_ slot: Int) -> Bool {
        guard let id = layout.draggingTab else { return false }
        layout.draggingTab = nil
        #if os(macOS)
        layout.attachMacPanel(id, to: groupId, at: slot, in: availableSize)
        #else
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { layout.attach(id, at: slot) }
        #endif
        return true
    }

    /// 松手落在组正文：追加到组尾
    private func dropToEnd() -> Bool {
        dropToSlot(tabs.count)
    }
}

/// iPad 保留原单击选择，mac 的鼠标事件由原生拖把分派。
private struct IPadTabTap: ViewModifier {
    let id: String
    let selected: Bool
    let layout: IPadPanelLayout

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                guard !selected else { return }
                withAnimation(.easeOut(duration: 0.15)) { layout.selectedTool = id }
            }
    }
}

/// mac：组正文是落点（按正文本地坐标分三带）；iPad 原样
private struct BodyDrop: ViewModifier {
    let perform: (CGPoint) -> Bool
    let located: (CGPoint) -> Void
    @Binding var targeted: Bool
    let draggingTab: () -> String?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onDrop(of: [.toolTab], delegate: ToolTabDropZone(name: "body", hovering: { targeted = $0 },
                                                              located: located, draggingTab: draggingTab, perform: perform))
        #else
        content
        #endif
    }
}
