import SwiftUI

/// 缩放拉过最小尺寸多少就算「要缩成小组件」（泛型 struct 里放不了 static 存储属性，搁文件级）。只 iOS 用：
/// mac 关了这条（可发现性差，plan-mac-shape A2a-5 ⧫j），缩组件走标题栏「缩」钮 + 菜单
private let floatingWindowMinimizeOvershoot: CGFloat = 40

/// 浮窗命中区 / 把手尺寸（泛型 struct 放不了 static，搁文件级）。
/// 触屏：角 36pt 骑角 ±18。mac（A2a-4）：四条边 6pt 命中带 + 角 8pt，都骑一半在窗外
private enum FloatingWindowMetrics {
    #if os(macOS)
    static let cornerHit = ShellStyle.cornerHit
    static let edgeHit = ShellStyle.edgeHit
    #else
    static let cornerHit: CGFloat = 36
    #endif
    /// 命中区骑在角 / 边上：一半在窗外
    static var cornerOverhang: CGFloat { cornerHit / 2 }
    /// 圆弧把手：视觉直径 + 内距，命中区 36
    static let gripVisual: CGFloat = 26
    static let gripPadding: CGFloat = 6
    static let gripHit: CGFloat = 36
}

/// 浮窗模式的一扇窗：可叠、触摸落下即置顶、按住标题栏拖动移位、**四个角都能缩放**（学 iPadOS 26 窗口：
/// 只有一个角画弧，但哪个角都能拖）。位置尺寸存在 `layout.frames[id]`，各窗互不相干——「每个动的只挂自己」。
/// 开着「吸边对齐」时拖近屏边 / 邻窗吸上去并画辅助线。
/// 全屏模式下从右栏浮出来的工具也是这扇窗，头上多一枚停回钮（`onDock`）。
/// iOS：缩到最小尺寸再往小拉 40pt 松手 = 缩成桌面上的小组件（`onMinimize`）；标题栏长按菜单里也有这一项。
/// mac：四边也能拖（光标随边换），标题栏多一枚「缩」钮；全屏模式下标题文字可当 tab 拖回 tab 栏 / 别的位置，
/// 标题栏也接别的 tab 落进来（= 回停靠组）。
/// 飞行中（`layout.flights[id]` 有值）整扇窗画成目标格那么大的小组件脸，飞到格子上再消失 / 从格子上飞回来。
///
/// 弧画在**内侧下角**：工具窗靠右长，往左下拉最顺手 → 左下；对话窗靠左 → 右下。
/// 其余三角是看不见的命中区，**骑在角上**（一半在窗外）——完全放窗内会压住右上的 × 和标题栏。
struct FloatingWindow<Content: View>: View {
    let layout: IPadPanelLayout
    let id: String
    let title: String
    let anchor: IPadPanelLayout.WindowAnchor
    let availableSize: CGSize
    let onDock: (() -> Void)?
    let onMinimize: (() -> Void)?
    let onClose: () -> Void
    /// mac：面板组 tab 栏（左栏「对话 | Code」）；有值时头上画 tab 栏不画标题
    var headerTabs: PanelGroupTabs? = nil
    @ViewBuilder var content: () -> Content

    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @State private var moveStart: IPadPanelLayout.WindowFrame?
    @State private var resizeStart: IPadPanelLayout.WindowFrame?
    /// 正在拖哪些边（光标在拖动中途离开命中带也不换回去）
    @State private var resizingEdges: Set<Edge> = []
    /// 缩放时手指已经拉过最小尺寸多少（iOS：松手时超过阈值就缩成组件）
    @State private var overshoot: CGFloat = 0
    @State private var headerTargeted = false
    @State private var bodyTargeted = false
    #if os(macOS)
    @GestureState private var macResizeActive = false
    #endif

    private var frame: IPadPanelLayout.WindowFrame { layout.currentFrame(id, in: availableSize) }
    /// 这扇窗里的 tab：停靠模式的多 tab 浮窗（plan-panel-ps 阶段 3）；浮窗模式 / 对话窗恒只有自己
    private var members: [String] { layout.mode == .docked && onDock != nil ? layout.floatMembers(of: id) : [id] }
    private var gripCorner: ResizeGrip.Corner { anchor == .trailing ? .bottomLeading : .bottomTrailing }

    var body: some View {
        let flight = layout.flights[id]
        let f = flight ?? frame
        let flying = flight != nil
        VStack(spacing: 0) {
            windowHeader
                .overlay {
                    #if os(macOS)
                    ShellDropHighlight(active: headerTargeted && layout.draggingTab != nil)
                        .padding(4)
                    #else
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.branchIndicator, lineWidth: 2)
                        .padding(4)
                        .opacity(headerTargeted ? 1 : 0)
                        .allowsHitTesting(false)
                    #endif
                }
                .modifier(HeaderDrop(enabled: onDock != nil, targeted: $headerTargeted,
                                     draggingTab: { layout.draggingTab }, perform: dropOnHeader))
                .contextMenu {
                    if let onMinimize {
                        Button(action: onMinimize) { Label("缩成小组件", systemImage: "arrow.down.right.and.arrow.up.left") }
                    }
                    if let onDock {
                        Button(action: onDock) { Label("停回右栏", systemImage: "rectangle.trailinghalf.inset.filled") }
                    }
                    Button(role: .destructive, action: onClose) { Label("关闭", systemImage: "xmark") }
                }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                #if os(macOS)
                // 正文也接 tab：并进这扇窗（PS 把面板拖到另一个浮动面板上）
                .overlay {
                    ShellDropHighlight(active: bodyTargeted && layout.draggingTab != nil).padding(4)
                }
                .modifier(HeaderDrop(enabled: onDock != nil, targeted: $bodyTargeted,
                                     draggingTab: { layout.draggingTab }, perform: dropOnHeader))
                #endif
        }
        .opacity(flying ? 0 : 1)
        .frame(width: f.w, height: f.h)
        .modifier(PanelChrome(docked: false))
        .overlay {
            #if os(macOS)
            if flying, layout.macFlightTargets[id] == nil {
                ToolWidgetFace(tool: toolManager?.tool(byId: id), id: id)
                    .transition(.opacity)
            }
            #else
            if flying {
                ToolWidgetFace(tool: toolManager?.tool(byId: id), id: id)
                    .transition(.opacity)
            }
            #endif
        }
        #if os(macOS)
        .opacity(layout.macFlightTargets[id] == nil ? 1 : 0)
        .onChange(of: layout.macDragGeneration) { _, _ in
            if layout.draggingTab == nil { headerTargeted = false; bodyTargeted = false }
        }
        .onChange(of: macResizeActive) { _, active in
            if !active { resizeStart = nil; resizingEdges = []; layout.snapGuides = [] }
        }
        .onDisappear {
            headerTargeted = false
            bodyTargeted = false
            moveStart = nil
            resizeStart = nil
            resizingEdges = []
            layout.snapGuides = []
        }
        #endif
        .overlay(alignment: .top) { if !flying { edgeHandle(.top) } }
        .overlay(alignment: .bottom) { if !flying { edgeHandle(.bottom) } }
        .overlay(alignment: .leading) { if !flying { edgeHandle(.leading) } }
        .overlay(alignment: .trailing) { if !flying { edgeHandle(.trailing) } }
        .overlay(alignment: .topLeading) { if !flying { cornerHandle(.topLeading) } }
        .overlay(alignment: .topTrailing) { if !flying { cornerHandle(.topTrailing) } }
        .overlay(alignment: .bottomLeading) { if !flying { cornerHandle(.bottomLeading) } }
        .overlay(alignment: .bottomTrailing) { if !flying { cornerHandle(.bottomTrailing) } }
        // 触摸落到窗上就置顶；simultaneous 不吞里面的按钮和滚动
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in layout.bringToFront(id) }
                .onEnded { _ in layout.bringToFront(id) }
        )
        .allowsHitTesting(!flying)
        .offset(x: f.x, y: f.y)
        .onAppear {
            // 没记过位置的窗第一次出现时把默认位置存下来，之后级联序号变了它也不跳
            if layout.frames[id] == nil { layout.frames[id] = frame }
        }
    }

    @ViewBuilder
    private var windowHeader: some View {
        #if os(macOS)
        PanelHeader(title: title, closeLabel: "关闭", onClose: onClose, onDock: onDock, tabs: headerTabs, onMinimize: onMinimize,
                    macDrag: onDock == nil ? nil : MacShellDragSource(title: title, payload: id,
                        onBegin: { layout.bringToFront(id); layout.beginMacTabDrag(id) },
                        onEnd: { accepted in layout.endMacTabDrag(id: id, accepted: accepted) },
                        onClick: { _ in layout.bringToFront(id) }, menuItems: headerMenu),
                    macTabs: members.count > 1 ? members.map(memberTab) : [],
                    onMove: moveWindow, onMoveEnd: { moveStart = nil; layout.snapGuides = [] })
        #else
        PanelHeader(title: title, closeLabel: "关闭", onClose: onClose, onDock: onDock, onMinimize: onMinimize,
                    titleDrag: onDock == nil ? nil : {
                        layout.draggingTab = id
                        let provider = ToolTabDrag.provider(id)
                        #if DEBUG
                        ShellProbe.p("[PROBE tab.source] id=\(id) types=\(provider.registeredTypeIdentifiers)")
                        #endif
                        return provider
                    })
            .contentShape(Rectangle())
            .gesture(moveGesture)
        #endif
    }

    #if os(macOS)
    /// 多 tab 浮窗头上的一个 tab：点 = 选中，拖 = 这一个工具（拆出 / 停回 / 并进别处）
    private func memberTab(_ member: String) -> MacHeaderTab {
        let name = toolManager?.tool(byId: member)?.name ?? IPadPanelLayout.fallbackTitle(member)
        return MacHeaderTab(
            id: member, title: name, selected: member == layout.floatSelection(in: id),
            drag: MacShellDragSource(title: name, payload: member,
                onBegin: { layout.bringToFront(id); layout.beginMacTabDrag(member) },
                onEnd: { accepted in layout.endMacTabDrag(id: member, accepted: accepted) },
                onClick: { _ in withAnimation(ShellStyle.feedback) { layout.selectFloat(member) } },
                menuItems: [
                    .init(title: "停回面板") { layout.attachMacPanel(member, in: availableSize) },
                    .init(title: "关闭") { withAnimation(ShellStyle.structure) { layout.close(member) } }
                ]))
    }

    private var headerMenu: [MacShellMenuItem] {
        var items: [MacShellMenuItem] = []
        if let onMinimize { items.append(.init(title: "缩成小组件", action: onMinimize)) }
        if let onDock { items.append(.init(title: "停回面板", action: onDock)) }
        items.append(.init(title: "关闭", action: onClose))
        return items
    }
    #endif

    private func moveWindow(_ translation: CGSize) {
        if moveStart == nil {
            moveStart = frame
            #if os(macOS)
            layout.bringToFront(id)
            #endif
            #if DEBUG && os(macOS)
            ShellProbe.p("[PROBE window.move] begin id=\(id)")
            #endif
        }
        guard let start = moveStart else { return }
        var f = start
        f.x += translation.width
        f.y += translation.height
        if layout.snapToEdges { f = layout.magnetize(move: f, id: id, in: availableSize) }
        layout.frames[id] = layout.clamped(f, in: availableSize)
    }

    /// 别的 tab / 浮窗标题落到这扇窗的标题栏或正文：mac = 并进这扇窗（多 tab 浮窗，plan-panel-ps 阶段 3）；
    /// iPad = 回停靠组。自己窗里的 tab 落回自己不算
    private func dropOnHeader(_ point: CGPoint) -> Bool {
        guard let dragged = layout.draggingTab, layout.windowId(of: dragged) != id else { return false }
        layout.draggingTab = nil
        #if os(macOS)
        withAnimation(ShellStyle.structure) { layout.merge(dragged, into: id) }
        #else
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { layout.attach(dragged) }
        #endif
        return true
    }

    @ViewBuilder
    private func cornerHandle(_ corner: ResizeGrip.Corner) -> some View {
        #if os(macOS)
        Color.clear
            .frame(width: ShellStyle.cornerHit, height: ShellStyle.cornerHit)
            .contentShape(Rectangle())
            .offset(x: corner.isLeading ? -ShellStyle.cornerHit / 2 : ShellStyle.cornerHit / 2,
                    y: corner.isTop ? -ShellStyle.cornerHit / 2 : ShellStyle.cornerHit / 2)
            .gesture(resizeGesture(corner.edges))
            .modifier(EdgeCursor(edges: corner.edges, hold: resizingEdges == corner.edges))
            .accessibilityHidden(true)
        #else
        if corner == gripCorner {
            ResizeGrip(corner: corner)
                .gesture(resizeGesture(corner.edges))
                .modifier(EdgeCursor(edges: corner.edges, hold: resizingEdges == corner.edges))
        } else {
            Color.clear
                .frame(width: FloatingWindowMetrics.cornerHit, height: FloatingWindowMetrics.cornerHit)
                .contentShape(Rectangle())
                .offset(x: corner.isLeading ? -FloatingWindowMetrics.cornerOverhang : FloatingWindowMetrics.cornerOverhang,
                        y: corner.isTop ? -FloatingWindowMetrics.cornerOverhang : FloatingWindowMetrics.cornerOverhang)
                .gesture(resizeGesture(corner.edges))
                .modifier(EdgeCursor(edges: corner.edges, hold: resizingEdges == corner.edges))
                .accessibilityHidden(true)
        }
        #endif
    }

    /// mac 四条边的命中带（角留给角的命中区）；iOS 没有——触屏拖边太细，角就够
    @ViewBuilder
    private func edgeHandle(_ edge: Edge) -> some View {
        #if os(macOS)
        let t = FloatingWindowMetrics.edgeHit
        let horizontal = edge == .top || edge == .bottom
        Color.clear
            .frame(width: horizontal ? nil : t, height: horizontal ? t : nil)
            .frame(maxWidth: horizontal ? .infinity : nil, maxHeight: horizontal ? nil : .infinity)
            .padding(horizontal ? .horizontal : .vertical, FloatingWindowMetrics.cornerHit)
            .contentShape(Rectangle())
            .offset(x: edge == .leading ? -t / 2 : (edge == .trailing ? t / 2 : 0),
                    y: edge == .top ? -t / 2 : (edge == .bottom ? t / 2 : 0))
            .gesture(resizeGesture([edge]))
            .modifier(EdgeCursor(edges: [edge], hold: resizingEdges == [edge]))
            .accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { v in
                moveWindow(v.translation)
            }
            .onEnded { _ in
                moveStart = nil
                layout.snapGuides = []
            }
    }

    /// 动哪几条边（角 = 两条，边 = 一条）；对边固定不动。左 / 上边在动时位置跟着边走
    private func resizeGesture(_ edges: Set<Edge>) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            #if os(macOS)
            .updating($macResizeActive) { _, active, _ in active = true }
            #endif
            .onChanged { v in
                if resizeStart == nil { resizeStart = frame; overshoot = 0; resizingEdges = edges }
                guard let s = resizeStart else { return }
                var f = s
                let minW = IPadPanelLayout.minWindowSize.width
                let minH = IPadPanelLayout.minWindowSize.height
                let rawW = edges.contains(.leading) ? s.w - v.translation.width
                         : (edges.contains(.trailing) ? s.w + v.translation.width : s.w)
                let rawH = edges.contains(.top) ? s.h - v.translation.height
                         : (edges.contains(.bottom) ? s.h + v.translation.height : s.h)
                overshoot = max(minW - rawW, minH - rawH)
                if edges.contains(.leading) {
                    let newW = max(minW, rawW)
                    f.x = s.x + (s.w - newW)
                    f.w = newW
                } else {
                    f.w = max(minW, rawW)
                }
                if edges.contains(.top) {
                    let newH = max(minH, rawH)
                    f.y = s.y + (s.h - newH)
                    f.h = newH
                } else {
                    f.h = max(minH, rawH)
                }
                if layout.snapToEdges {
                    f = layout.magnetize(resize: f, movingEdges: edges, id: id, in: availableSize)
                }
                layout.frames[id] = layout.clamped(f, in: availableSize)
            }
            .onEnded { _ in
                resizeStart = nil
                resizingEdges = []
                layout.snapGuides = []
                #if os(iOS)
                if overshoot >= floatingWindowMinimizeOvershoot { onMinimize?() }
                #endif
                overshoot = 0
            }
    }
}

/// mac：浮窗标题栏接 tab 落进来（全屏模式下的浮窗才有组可回）；iPad 原样
private struct HeaderDrop: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let draggingTab: () -> String?
    let perform: (CGPoint) -> Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        if enabled {
            content.onDrop(of: [.toolTab], delegate: ToolTabDropZone(name: "header", hovering: { targeted = $0 },
                                                                  draggingTab: draggingTab, perform: perform))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// mac：悬停在缩放命中区换成对应方向的框缩放光标（macOS 15 `frameResize`）；iPad 无光标
private struct EdgeCursor: ViewModifier {
    let edges: Set<Edge>
    let hold: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.hoverCursor(.frameResize(position: Self.position(edges), directions: .all), hold: hold)
        #else
        content
        #endif
    }

    #if os(macOS)
    private static func position(_ e: Set<Edge>) -> NSCursor.FrameResizePosition {
        switch (e.contains(.top), e.contains(.bottom), e.contains(.leading), e.contains(.trailing)) {
        case (true, _, true, _):  return .topLeft
        case (true, _, _, true):  return .topRight
        case (_, true, true, _):  return .bottomLeft
        case (_, true, _, true):  return .bottomRight
        case (true, _, _, _):     return .top
        case (_, true, _, _):     return .bottom
        case (_, _, true, _):     return .left
        default:                  return .right
        }
    }
    #endif
}

/// 角上的圆弧把手（学 iPadOS 26 窗口右下那枚半月）。视觉 r=13 的四分之一弧，命中区 36×36。
struct ResizeGrip: View {
    enum Corner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
        /// 这个角在动的两条边
        var edges: Set<Edge> { [isTop ? .top : .bottom, isLeading ? .leading : .trailing] }

        /// Circle 的 0 在三点钟方向、顺时针：0–.25 右下象限，.25–.5 左下，.5–.75 左上，.75–1 右上
        var trim: (from: CGFloat, to: CGFloat) {
            switch self {
            case .bottomTrailing: return (0, 0.25)
            case .bottomLeading:  return (0.25, 0.5)
            case .topLeading:     return (0.5, 0.75)
            case .topTrailing:    return (0.75, 1)
            }
        }
    }
    let corner: Corner

    var body: some View {
        Circle()
            .trim(from: corner.trim.from, to: corner.trim.to)
            .stroke(Theme.textMuted.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: FloatingWindowMetrics.gripVisual, height: FloatingWindowMetrics.gripVisual)
            .padding(FloatingWindowMetrics.gripPadding)
            .frame(width: FloatingWindowMetrics.gripHit, height: FloatingWindowMetrics.gripHit)
            .contentShape(Rectangle())
            .accessibilityLabel("调整大小")
    }
}
