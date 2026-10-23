import SwiftUI

/// 宽屏面板总装。最底层是**桌面格子**（页 2 那份小组件钉在聊天两侧，`DesktopGridView`），两种模式共用；上面两套布局：
/// - **全屏**：对话列表 / 工具 tab 组 / 竖 dock 贴边平铺，正文被推开（`DockedInsetHost`）；面板开着时盖住那一侧的格子（甲）；
///   从 tab 组浮出去的工具是盖在正文上的 `FloatingWindow`
/// - **浮窗**：每个面板是一扇 `FloatingWindow`，绝对定位、可叠、点哪个哪个到前面；dock 悬在格线的 dock 道上
///
/// 09-16 解耦：dock 图标条 / 对话列表 / 工具面板**各占一条 lane**——工具恒右、列表恒左，
/// `dockSide` 只决定那条图标条贴哪边（她「工具页面永远放右边，列表永远从左边出来」）。
///
/// 挂 `ContentView.body` 的 overlay（child HC 不继承 SwiftUI env，`SidebarView` 要的 manager
/// 只有这层拿得到）。**宽高由这个视图自己读**——`ContentView.body` 不读 `leftWidth` / `frames`，
/// 拖动就不会带它重算（否则每帧 `updatePages` 三棵 HC 树）。
struct IPadPanelOverlay<Sidebar: View, Chat: View>: View {
    let layout: IPadPanelLayout
    let availableSize: CGSize
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    /// mac 停靠壳的正文卡槽内容（plan-mac-fullscreen-shell-v2 §1）。**值不是闭包**：拖面板宽只有这层重算，
    /// 值没变 `CardFlowView` 不重建（同 `DockedInsetHost` 的做法）。iOS / 浮窗传 `EmptyView`（见文末的 init 扩展）
    var chat: Chat
    @ViewBuilder var sidebar: () -> Sidebar

    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?

    /// 拖对话列表 / 工具面板宽度的起点（松手清空）
    @State private var leftWidthStart: CGFloat?
    @State private var toolWidthStart: CGFloat?
    #if os(macOS)
    /// 拖 tab 悬停在正文卡槽上时落在哪一区（左 / 右沿停靠、中间浮出）；只是预览，松手按那一刻坐标重分
    @State private var cardZone: CardDropZone.Zone?
    /// 正文部分此刻的尺寸（卡槽落点按它分区；底列开着时比卡槽矮）
    @State private var chatSize: CGSize = .zero
    @State private var bottomHeightStart: CGFloat?
    #endif

    private var grid: GridFrame? { layout.grid(in: availableSize) }

    var body: some View {
        #if os(macOS)
        Group {
            if layout.mode == .docked {
                macDockedBody
            } else {
                floatingBody
            }
        }
        .animation(ShellStyle.structure, value: layout.leftShown)
        .animation(ShellStyle.structure, value: layout.dockShown)
        .animation(ShellStyle.structure, value: layout.tabGroupCollapsed)
        .animation(ShellStyle.structure, value: layout.groupCollapsed)
        .animation(ShellStyle.structure, value: layout.columnGroups)
        #else
        if layout.mode == .docked {
            dockedBody
        } else {
            floatingBody
        }
        #endif
    }

    /// 永远压在最底层：面板开着那一侧的格子被盖住，也就不能往那儿拖（看不见的地方本来也放不了）。
    /// mac 停靠壳：格子只在空地上（`desktopGrid` → `MacShellFrame.grid`），面板和格子是兄弟，谁也不盖谁
    @ViewBuilder
    private var desktop: some View {
        if let grid = layout.desktopGrid(in: availableSize) { DesktopGridView(layout: layout, grid: grid, viewModel: viewModel) }
    }

    #if os(iOS)
    // MARK: 全屏（iPad）：平铺 + 浮出去的窗

    private var dockedBody: some View {
        ZStack(alignment: .topLeading) {
            desktop
            // 中间那个 Spacer 没有 hit shape，正文照常可点
            HStack(alignment: .top, spacing: 0) {
                // 09-16 解耦：**dock 条 / 对话列表 / 工具面板各占一条 lane**。工具恒右、列表恒左，
                // `dockSide` 只决定那条竖 dock 贴哪边（她「工具页面永远放右边，列表永远从左边出来」）。
                // `dockShown` 的语义不变：「工具」那颗仍然同时收起 dock 条和工具面板
                if layout.dockShown, layout.dockSide == .left {
                    dockStrip(hairlineEdge: .trailing)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if layout.leftShown {
                    convPanel()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if layout.dockShown {
                    toolPanel()
                }
                if layout.dockShown, layout.dockSide == .right {
                    dockStrip(hairlineEdge: .leading)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            windows
            snapGuides
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    #endif

    #if os(macOS)
    // MARK: 全屏（mac 停靠壳）：四列并排实占（plan-mac-fullscreen-shell-v2 §1）

    /// 可见面板并排占位，关闭侧直接归还正文；dock 条始终保留。
    private var macDockedBody: some View {
        let frame = layout.macShellFrame(in: availableSize)
        return ZStack(alignment: .topLeading) {
            desktop
            HStack(alignment: .top, spacing: 0) {
                if layout.dockSide == .left {
                    dockStrip(hairlineEdge: .trailing)
                        .zIndex(1)
                }
                if layout.leftColumnVisible, let width = frame.conv {
                    macColumn(.left, width: width)
                        .focusSection()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else if frame.leftLane > 0 {
                    Spacer().frame(width: frame.leftLane)
                }
                chatSlot(frame)
                    .focusSection()
                if layout.macToolShown, let width = frame.tool {
                    macColumn(.right, width: width)
                        .focusSection()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if frame.rightLane > 0 {
                    Spacer().frame(width: frame.rightLane)
                }
                if layout.dockSide == .right {
                    dockStrip(hairlineEdge: .leading)
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            windows
            if let group = layout.macFlyoutGroup {
                flyout(group)
                    .transition(.opacity)
                    .zIndex(1500)
            }
            snapGuides
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(ShellStyle.feedback, value: layout.macFlyout)
        .onChange(of: macShapeKey) { _, _ in layout.commitMacColumns(width: availableSize.width) }
    }

    /// 列收着时点 dock 弹出来的组（plan-panel-ps 阶段 4）：浮在 dock 旁，点外面 / Esc / 再点那个图标收；
    /// 组的 tab 栏上「展开这一栏」= 把列放回来（fly-out 跟着消失）
    private func flyout(_ group: String) -> some View {
        let edge = layout.edge(of: group)
        let width = edge == .left ? max(IPadPanelLayout.minPanelWidth, min(IPadPanelLayout.maxPanelWidth, layout.leftWidth))
            : edge == .right ? max(MacShellFrame.toolMinWidth, min(MacShellFrame.toolMaxWidth, layout.toolWidth)) : 480
        let height = max(ShellStyle.barHeight, min(560, availableSize.height * 0.7))
        let gap: CGFloat = 8
        let x = layout.dockSide == .right ? availableSize.width - IPadPanelLayout.dockWidth - width - gap : IPadPanelLayout.dockWidth + gap
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { layout.macFlyout = nil }
                .accessibilityHidden(true)
            TabbedToolPanel(layout: layout, availableSize: availableSize,
                            viewModel: viewModel, stickerVM: stickerVM, groupId: group)
                .frame(width: width, height: height)
                .modifier(PanelChrome(docked: false))
                .offset(x: max(0, x), y: MacShellMetrics.shared.cardGapTop)
            Button("收起") { layout.macFlyout = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 列数的输入（`commitMacColumns` 的触发键）：模式 / 排版 / 开关 / 面板存档宽 / 卡边（R-FS2 S2）
    private var macShapeKey: String {
        "\(layout.mode.rawValue)|\(layout.arrangement.rawValue)|\(layout.leftColumnVisible)|\(layout.dockShown)|\(layout.macToolShown)|" +
        "\(Int(layout.leftWidth))|\(Int(layout.toolWidth))|\(Int(layout.shellMetrics.cardEdges))"
    }

    /// 正文卡槽：宽钉死在 `frame.card`（正文的固有最小宽不许把面板挤出去，超出的在槽里裁）；
    /// 拖 tab 到卡上 → 在落点浮出（落区 = 高亮区 = 卡槽，R-FS2 S4）；框上报给标题行居卡用
    private func chatSlot(_ frame: MacShellFrame) -> some View {
        VStack(spacing: 0) {
            chatPart(frame)
            if let bottom = frame.bottom {
                bottomColumn(width: frame.card, height: bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: frame.card > 0 ? frame.card : nil)
        .frame(maxHeight: .infinity, alignment: .top)
        // 卡槽**整体**（正文 + 底列）的框：拖底列高时它不变，标题行（读 x / 宽）不跟着逐帧重算（A I1）
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ShellStyle.coordinateSpace)) } action: {
            layout.macCardFrame = $0
        }
    }

    /// 卡槽里的正文部分：tab 落点在这里（左 / 右 / 底沿 = 停到那一列，中间 = 浮出），底列有自己的落点
    private func chatPart(_ frame: MacShellFrame) -> some View {
        chat
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: frame.bottom == nil ? nil : frame.cardHeight)
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { chatSize = $0 }
            .overlay {
                ShellDropHighlight(active: layout.macDropTarget == "workspace" && layout.draggingTab != nil && (cardZone ?? .float) == .float,
                                   radius: ShellStyle.windowRadius)
                    .padding(4)
            }
            .overlay(alignment: cardZone == .right ? .trailing : cardZone == .bottom ? .bottom : .leading) {
                if layout.macDropTarget == "workspace", layout.draggingTab != nil, let zone = cardZone, zone != .float {
                    ShellDockEdgeBand(horizontal: zone == .bottom)
                }
            }
            .onChange(of: layout.macDragGeneration) { _, _ in if layout.draggingTab == nil { cardZone = nil } }
            .onDrop(of: [.toolTab], delegate: ToolTabDropZone(name: "workspace",
                hovering: { layout.macDropTarget = $0 ? "workspace" : nil; if !$0 { cardZone = nil } },
                located: { cardZone = CardDropZone.resolve($0, in: chatSize, bottomEnabled: true) },
                draggingTab: { layout.draggingTab }) { point in
                guard let id = layout.draggingTab else { return false }
                layout.draggingTab = nil
                let zone = CardDropZone.resolve(point, in: chatSize, bottomEnabled: true)
                cardZone = nil
                switch zone {
                case .left, .right, .bottom:
                    // 贴沿 = 停到那一列的尾巴上新开一组（浮着的一起停进去）
                    let edge: PanelEdge = zone == .left ? .left : zone == .right ? .right : .bottom
                    layout.insertMacGroup(id, edge: edge, at: layout.columnGroups[edge]?.count ?? 0, in: availableSize)
                case .float:
                    // 落点是正文本地坐标，正文在卡槽顶上，加上卡槽在工作区里的 origin 就是 `detach(at:)` 存的那套坐标
                    let origin = layout.macCardFrame.origin
                    layout.detachMacPanel(id, at: CGPoint(x: point.x + origin.x, y: point.y + origin.y), in: availableSize)
                }
                return true
            })
    }

    /// 底列（plan-panel-ps 阶段 4）：只在正文卡下方，组左右排；左右 / 下边距跟正文卡对齐，顶缘把手拖高
    private func bottomColumn(width: CGFloat, height: CGFloat) -> some View {
        let m = MacShellMetrics.shared
        return MacDockColumn(layout: layout, edge: .bottom, length: width,
                             insets: EdgeInsets(top: 0, leading: m.cardGapX, bottom: m.cardGapBottom, trailing: m.cardGapX)) { id in
            TabbedToolPanel(layout: layout, availableSize: availableSize,
                            viewModel: viewModel, stickerVM: stickerVM, groupId: id, horizontal: true)
        } empty: {
            EmptyView()
        }
        .frame(height: height)
        .overlay(alignment: .top) {
            PanelResizeHandle(axis: .horizontal) { dy in
                if bottomHeightStart == nil { bottomHeightStart = layout.bottomHeight }
                layout.bottomHeight = MacShellFrame.bottomHeight(stored: (bottomHeightStart ?? 0) - dy, height: availableSize.height)
            } onEnded: { bottomHeightStart = nil }
            .offset(y: -8)
        }
    }
    #endif

    #if os(macOS)
    /// 停靠壳的一列（plan-panel-ps 2b）：组叠起来，外缘一条 hairline + 拖列宽的把手
    /// （左列 = `leftWidth`、右列 = `toolWidth`，钳法跟改造前的两块面板一样）
    private func macColumn(_ edge: PanelEdge, width: CGFloat) -> some View {
        MacDockColumn(layout: layout, edge: edge, length: availableSize.height) { id in
            if id == IPadPanelLayout.convWindowId {
                convBody
            } else {
                TabbedToolPanel(layout: layout, availableSize: availableSize,
                                viewModel: viewModel, stickerVM: stickerVM, groupId: id)
            }
        } empty: {
            if edge == .right { returnStrip }
        }
        .frame(width: width)
        // 兜底：以后再有东西把列撑宽，也只是被裁掉，不会盖到正文卡（09-24 9 个 tab 撑到 514 盖卡）
        .clipped()
        .frame(maxHeight: .infinity)
        .overlay(alignment: edge == .left ? .trailing : .leading) { hairline }
        .overlay(alignment: edge == .left ? .trailing : .leading) {
            if edge == .left {
                PanelResizeHandle(axis: .vertical) { dx in
                    if leftWidthStart == nil { leftWidthStart = layout.leftWidth }
                    layout.leftWidth = clampConv((leftWidthStart ?? 0) + dx)
                } onEnded: { leftWidthStart = nil }
                .offset(x: 8)
            } else {
                toolResizeHandle
            }
        }
    }
    #endif

    /// 对话列表的内容（标题 + 列表），mac 停靠列和 iPad 面板共用
    private var convBody: some View {
        VStack(spacing: 0) {
            // onClose 显式写出来：`docked` 排在 onClose 后面，再用尾随闭包会被匹配到别的闭包参数上
            // mac：标题位置是面板组的 tab 栏（「对话 | Code」，PS 面板组 = tab 栏 + 内容）；iPad 照旧写死「对话」
            PanelHeader(title: "对话", closeLabel: "收起", onClose: {
                withAnimation(ShellMotion.structure(.spring(response: 0.34, dampingFraction: 0.88))) { layout.leftShown = false }
            }, docked: true, tabs: convTabs)
            sidebar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelChrome(docked: true))
    }

    /// 左栏面板组的 tab（mac）；iOS 没有 Code，nil = 照旧画标题
    private var convTabs: PanelGroupTabs? {
        #if os(macOS)
        MacLeftPanelGroup.tabs
        #else
        nil
        #endif
    }

    #if os(iOS)
    /// iPad 的对话列表面板。09-16 解耦后**恒在左**，把手和 hairline 固定在右缘（不再有 mirrored）。
    /// mac 停靠壳改走 `macColumn(.left)`（plan-panel-ps 2b）
    private func convPanel() -> some View {
        convBody
            // 存的宽按当前可用尺寸钳过：窗口缩到放不下时面板先让（不改档），别让整层溢出被两边裁
            .frame(width: layout.dockedConvWidth(in: availableSize))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { hairline }
            .overlay(alignment: .trailing) {
                PanelResizeHandle(axis: .vertical) { dx in
                    if leftWidthStart == nil { leftWidthStart = layout.leftWidth }
                    layout.leftWidth = clampConv((leftWidthStart ?? 0) + dx)
                } onEnded: { leftWidthStart = nil }
                .offset(x: 8)
            }
    }
    #endif

    /// 拖列表把手的钳：mac 停靠壳按 `MacShellFrame` 的口径（给工具面板留 280），其余按老口径。
    /// 写回的是钳后值（今天的行为，保留：窄窗拖一次存的宽就变小，R-FS2 Q7-5）
    private func clampConv(_ w: CGFloat) -> CGFloat {
        #if os(macOS)
        if layout.mode == .docked { return layout.macClampedConvWidth(w, in: availableSize) }
        #endif
        return layout.clampedConvWidth(w, availableSize: availableSize)
    }

    #if os(iOS)
    /// iPad 的工具面板（全部停靠组投影成一组 tab）。09-16 解耦后**恒在右**，dock 条已经独立成另一条 lane。
    /// 宽度固定 = 工具侧预留的两列 + 缝，正好盖在格子上，开关不推聊天（没有拖宽把手）。
    /// mac 停靠壳改走 `macColumn(.right)`（plan-panel-ps 2b）
    @ViewBuilder
    private func toolPanel() -> some View {
        if !layout.tabs.isEmpty {
            TabbedToolPanel(layout: layout, availableSize: availableSize,
                            viewModel: viewModel, stickerVM: stickerVM)
                .frame(width: layout.dockedToolPanelWidth(in: availableSize))
                // 折成标题线时外框只有 tab 栏那么高，底下露出格子（A2a-3）
                .frame(maxHeight: layout.tabGroupCollapsed ? nil : .infinity)
                .overlay(alignment: .leading) { hairline }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
    #endif

    /// mac 停靠壳工具面板的拖宽把手（leading 缘；往左拖变宽）。写入钳 280…460 再按窗宽（`macClampedToolWidth`）
    @ViewBuilder
    private var toolResizeHandle: some View {
        #if os(macOS)
        if layout.mode == .docked {
            PanelResizeHandle(axis: .vertical) { dx in
                if toolWidthStart == nil { toolWidthStart = layout.toolWidth }
                layout.toolWidth = layout.macClampedToolWidth((toolWidthStart ?? 0) - dx, in: availableSize)
            } onEnded: { toolWidthStart = nil }
            .offset(x: -8)
        }
        #endif
    }

    #if os(macOS)
    private var returnStrip: some View {
        Text("拖到这里停靠")
            .font(ShellStyle.secondaryFont)
            .foregroundStyle(ShellStyle.mutedText)
            .frame(maxWidth: .infinity)
            .frame(height: ShellStyle.barHeight)
            .background(ShellStyle.chrome, ignoresSafeAreaEdges: [])   // 同 PanelChrome：别漫进标题行盖钮（09-18）
            .overlay(ShellDropHighlight(active: layout.macDropTarget == "return" && layout.draggingTab != nil))
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ShellStyle.coordinateSpace)) } action: {
                layout.macReturnFrame = $0
            }
            .onDrop(of: [.toolTab], delegate: ToolTabDropZone(name: "return",
                hovering: { layout.macDropTarget = $0 ? "return" : nil }, draggingTab: { layout.draggingTab }) { _ in
                    guard let id = layout.draggingTab else { return false }
                    layout.draggingTab = nil
                    layout.attachMacPanel(id, in: availableSize)
                    return true
                })
    }
    #endif

    private func dockStrip(hairlineEdge: Alignment) -> some View {
        verticalDock
            .modifier(PanelChrome(docked: true))
            .overlay(alignment: hairlineEdge) {
                if !layout.tabs.isEmpty { hairline }
            }
    }

    private var verticalDock: some View {
        VerticalDock(layout: layout, workspaceSize: availableSize)
    }

    /// 面板之间的竖分隔线。只被 `dockedBody` 的三条 lane 用（convPanel / toolPanel / dockStrip），
    /// 所以按「桌布上不留线」直接关掉即可，浮窗那边碰不到（它的边是 `PanelChrome(docked:false)` 的圆角+描边）。
    /// mac（09-24 粟粟拍）：卡片自带描边，缝里只留把手；再画竖线就成了「卡边 + 线 + 卡边」三条，不画
    @ViewBuilder
    private var hairline: some View {
        #if os(macOS)
        EmptyView()
        #else
        Rectangle()
            .fill(Theme.textMuted.opacity(0.25))
            .frame(width: 1)
        #endif
    }

    // MARK: 浮窗：真窗口

    private var floatingBody: some View {
        ZStack(alignment: .topLeading) {
            desktop
            windows
            if layout.dockShown {
                floatingDock
                    .zIndex(1000)
                    .transition(.move(edge: layout.dockSide == .left ? .leading : .trailing).combined(with: .opacity))
            }
            snapGuides
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 玻璃 dock：有格子时悬在 dock 道上（x = dockX），**竖向居中**（粟粟：「dock 位置都不居中」）；
    /// 没格子（Split View）退回贴角
    @ViewBuilder
    private var floatingDock: some View {
        let dock = verticalDock.modifier(PanelChrome(docked: false))
        if let grid {
            dock
                .frame(maxHeight: .infinity)
                .offset(x: grid.dockX)
        } else {
            dock
                .padding(.horizontal, IPadPanelLayout.floatingMargin)
                .padding(.top, IPadPanelLayout.floatingMargin)
                .frame(maxWidth: .infinity, alignment: layout.dockSide == .left ? .topLeading : .topTrailing)
        }
    }

    // MARK: 两种模式共用：窗 + 吸边辅助线

    /// `windowIds` 的数组顺序就是层级；再叠一层 zIndex 让重排时动画不闪。
    /// 浮窗模式 = 全部成员；全屏模式 = 只有浮出去的
    private var windows: some View {
        ForEach(Array(layout.windowIds.enumerated()), id: \.element) { i, id in
            window(id)
                .zIndex(Double(i))
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    /// 吸边辅助线（PS 的蓝线，我们用薄荷）：只在拖动吸住时有
    private var snapGuides: some View {
        ForEach(layout.snapGuides, id: \.self) { g in
            Rectangle()
                .fill(Theme.branchIndicator.opacity(0.9))
                .frame(width: g.vertical ? 1 : nil, height: g.vertical ? nil : 1)
                .frame(maxWidth: g.vertical ? nil : .infinity, maxHeight: g.vertical ? .infinity : nil)
                .offset(x: g.vertical ? g.at : 0, y: g.vertical ? 0 : g.at)
                .allowsHitTesting(false)
                .zIndex(2000)
        }
    }

    @ViewBuilder
    private func window(_ id: String) -> some View {
        if id == IPadPanelLayout.convWindowId {
            FloatingWindow(layout: layout, id: id, title: "对话", anchor: .leading,
                           availableSize: availableSize, onDock: nil, onMinimize: nil,
                           onClose: { withAnimation(ShellMotion.structure(.spring(response: 0.34, dampingFraction: 0.88))) { layout.leftShown = false } },
                           headerTabs: convTabs) {
                sidebar()
            }
        } else {
            FloatingWindow(layout: layout, id: id, title: toolManager?.tool(byId: id)?.name ?? IPadPanelLayout.fallbackTitle(id), anchor: .trailing,
                           availableSize: availableSize,
                           onDock: layout.mode == .docked
                               ? { dockWindow(id) }
                               : nil,
                           // 多 tab 浮窗：缩的是选中的那一个、关的是整扇窗（plan-panel-ps 阶段 3）
                           onMinimize: { minimizeWithFlight(layout.mode == .docked ? layout.floatSelection(in: id) : id) },
                           onClose: { withAnimation(ShellMotion.structure(.spring(response: 0.32, dampingFraction: 0.86))) {
                               if layout.mode == .docked { layout.closeWindow(id) } else { layout.close(id) }
                           } }) {
                FloatGroupContent(layout: layout, anchor: id, viewModel: viewModel, stickerVM: stickerVM)
            }
        }
    }

    private func dockWindow(_ id: String) {
        #if os(macOS)
        if layout.floatMembers(of: id).count > 1 {
            withAnimation(ShellStyle.structure) { layout.attachWindow(id) }
        } else {
            layout.attachMacPanel(id, in: availableSize)
        }
        #else
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { layout.attach(id) }
        #endif
    }

    /// 桌面小组件此刻占的格数（按当前排版），喂 canMinimize / minimize 判格子满没满
    private var widgetCells: Int {
        DesktopGridPlacer.widgetCells(DashboardManager.shared.widgets, arrangement: layout.arrangement)
    }

    /// 缩成小组件：窗先变成小组件脸飞到它要落的那一格，落定再真正缩起来（格子满了就什么都不做）
    private func minimizeWithFlight(_ id: String) {
        #if os(macOS)
        layout.minimizeMacPanel(id, in: availableSize)
        #else
        guard layout.canMinimize(id, in: availableSize, widgetCells: widgetCells) else { return }
        guard let grid, let target = DesktopGridPlacer.landingFrame(forTool: id, layout: layout, grid: grid) else {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { layout.minimize(id, in: availableSize, widgetCells: widgetCells) }
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            layout.flights[id] = .init(x: target.minX, y: target.minY, w: target.width, h: target.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.easeOut(duration: 0.12)) {
                // 飞行这 0.42s 里桌面可能增删了组件：提交时重新取当前占格数，不用飞行前的快照
                layout.minimize(id, in: availableSize, widgetCells: widgetCells)
                layout.flights[id] = nil
            }
        }
        #endif
    }
}

/// 一扇浮窗的正文：停靠模式的多 tab 浮窗把成员都挂着（切 tab 不重建浏览器 / 终端，同 tab 组），只露选中的那个；
/// 其余情形就是那一个工具
private struct FloatGroupContent: View {
    let layout: IPadPanelLayout
    let anchor: String
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel

    var body: some View {
        let members = layout.mode == .docked ? layout.floatMembers(of: anchor) : [anchor]
        let current = members.count > 1 ? layout.floatSelection(in: anchor) : anchor
        ZStack {
            ForEach(members.isEmpty ? [anchor] : members, id: \.self) { m in
                RightPanelToolContent(toolId: m, selectedToolId: .constant(m), viewModel: viewModel, stickerVM: stickerVM)
                    .opacity(m == current ? 1 : 0)
                    .allowsHitTesting(m == current)
                    #if os(macOS)
                    .environment(\.isFrontmostTool, m == current)
                    #endif
            }
        }
    }
}

/// iOS 宽屏 / mac 浮窗的调用点不传 `chat`（正文不在 overlay 里，它盖在 `DockedInsetHost` 上）：
/// `sidebar:` 仍是最后一个参数，尾随闭包照常匹配；调用点一字不改
extension IPadPanelOverlay where Chat == EmptyView {
    init(layout: IPadPanelLayout, availableSize: CGSize, viewModel: ConversationViewModel, stickerVM: StickerViewModel,
         @ViewBuilder sidebar: @escaping () -> Sidebar) {
        self.init(layout: layout, availableSize: availableSize, viewModel: viewModel, stickerVM: stickerVM,
                  chat: EmptyView(), sidebar: sidebar)
    }
}

/// 宽屏下把翻页容器（= 聊天页 + 挂在 chat HC 上的输入条）往里推，正文让位给桌面格子和贴边面板；
/// 输入条约束在 chat HC 的 leading/trailing 上，容器一缩它跟着缩，键盘管线一行不动。
///
/// `content` 是**值**不是闭包：拖动时只有这层重算，它把同一个 `PagingContainerView` 值原样交回，
/// SwiftUI 比对输入没变就不会 `updateUIViewController`（真机探针已验，plan §2.2）。
struct DockedInsetHost<Content: View>: View {
    let layout: IPadPanelLayout
    let active: Bool
    let availableSize: CGSize
    let content: Content

    var body: some View {
        content
            .padding(.leading, active ? layout.leftInset(in: availableSize) : 0)
            .padding(.trailing, active ? layout.rightInset(in: availableSize) : 0)
            #if os(macOS)
            .animation(ShellStyle.structure, value: layout.leftShown)
            .animation(ShellStyle.structure, value: layout.dockShown)
            .animation(ShellStyle.structure, value: layout.mode)
            #endif
    }
}
