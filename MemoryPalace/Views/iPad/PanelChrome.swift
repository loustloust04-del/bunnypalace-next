import SwiftUI

/// 面板头：标题 + 关闭（+ 浮窗在全屏模式下的「停回」；mac 再加「缩成小组件」）。左面板、浮窗共用。
struct PanelHeader: View {
    let title: String
    let closeLabel: String
    let onClose: () -> Void
    /// 有值就多一枚停回钮（全屏模式下浮出去的窗回右栏当 tab）
    var onDock: (() -> Void)? = nil
    /// 这个头是**全屏模式**里平铺在桌布上的面板头（只有 `IPadPanelOverlay.convPanel` 传 true）。
    /// 浮窗的头照旧留底部那条线——它有自己的窗形，线是形的一部分（R-FS S1.1：这里两模式共用，不门控会连坐浮窗）
    var docked: Bool = false
    /// mac：有值就把标题换成面板组的 tab 栏（左栏「对话 | Code」，PS 面板组 = tab 栏 + 内容）；iOS 忽略，照旧画 `title`
    var tabs: PanelGroupTabs? = nil
    /// mac 才画的「缩成小组件」钮（拉过头缩在 mac 关了，plan-mac-shape A2a-5 ⧫j）；iOS 走长按菜单 + 拉过头
    var onMinimize: (() -> Void)? = nil
    /// mac：标题文字当 tab 拖走（回 tab 栏 / 换槽 / 挪位置）；nil 不可拖。标题栏其余部分仍是移窗手势
    var titleDrag: (() -> NSItemProvider)? = nil
    #if os(macOS)
    var macDrag: MacShellDragSource? = nil
    /// 多 tab 浮窗（plan-panel-ps 阶段 3）：非空时标题换成一排 tab，每个 tab 自己是拖源（拖出去 = 拆 / 停 / 并）
    var macTabs: [MacHeaderTab] = []
    var onMove: ((CGSize) -> Void)? = nil
    var onMoveEnd: (() -> Void)? = nil
    @State private var titleHovered = false
    #endif

    var body: some View {
        HStack(spacing: 2) {
            #if os(macOS)
            if let tabs {
                PanelGroupTabStrip(tabs: tabs)
            } else if macTabs.isEmpty {
                macTitle
            } else {
                ForEach(macTabs) { tab in
                    Text(tab.title)
                        .font(ShellStyle.bodyFont)
                        .foregroundStyle(tab.selected ? ShellStyle.text : ShellStyle.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: ShellStyle.tabHeight)
                        .modifier(MacShellControlSurface(selected: tab.selected))
                        .overlay { tab.drag }
                        .help("\(tab.title)：拖出去拆成一扇窗 / 停回栏里 / 并进别的窗")
                }
            }
            Color.clear
                .frame(minWidth: 20, maxWidth: .infinity)
                .frame(height: ShellStyle.tabHeight)
                .contentShape(Rectangle())
                .modifier(HeaderMove(enabled: true, changed: onMove, ended: onMoveEnd))
            #else
            Text(title)
                .font(.system(size: Theme.F.caption, weight: .bold))
                .foregroundColor(Theme.textSecondary)
                .kerning(0.5)
                .modifier(TitleDrag(provider: titleDrag))
            Spacer(minLength: 0)
            #endif
            #if os(macOS)
            if let onMinimize {
                headerButton("arrow.down.right.and.arrow.up.left", label: "缩成小组件", action: onMinimize)
            }
            #endif
            if let onDock {
                headerButton("rectangle.trailinghalf.inset.filled", label: "停回右栏", action: onDock)
            }
            headerButton("xmark", label: closeLabel, action: onClose)
        }
        .padding(.horizontal, 13)
        #if os(macOS)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) {
            if !docked || MacShellMetrics.shared.panelHairline > 0 {
                Rectangle().fill(ShellStyle.hairline).frame(height: ShellStyle.hairlineWidth).allowsHitTesting(false)
            }
        }
        #else
        .padding(.top, 9)
        .padding(.bottom, 5)
        #endif
    }

    #if os(macOS)
    private var macTitle: some View {
        Text(title)
            .font(ShellStyle.bodyFont)
            .foregroundStyle(ShellStyle.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: ShellStyle.tabHeight)
            .modifier(MacShellControlSurface(hovered: titleHovered))
            .onHover { titleHovered = $0 }
            .overlay { if let macDrag { macDrag } }
            .modifier(HeaderMove(enabled: macDrag == nil, changed: onMove, ended: onMoveEnd))
            .help(onMove == nil ? title : (macDrag == nil ? "拖动以移动窗口" : "拖动标题停回面板；拖动旁边空白移动窗口"))
    }
    #endif

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        Button(action: action) { MacShellLabel(symbol: symbol) }
            .buttonStyle(MacShellButton(width: ShellStyle.headerButtonWidth))
            .help(label)
            .accessibilityLabel(label)
        #else
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        #endif
    }
}

#if os(macOS)
/// 多 tab 浮窗头上的一个 tab
struct MacHeaderTab: Identifiable {
    let id: String
    let title: String
    let selected: Bool
    let drag: MacShellDragSource
}

private struct HeaderMove: ViewModifier {
    let enabled: Bool
    let changed: ((CGSize) -> Void)?
    let ended: (() -> Void)?
    @GestureState private var moving = false

    func body(content: Content) -> some View {
        if enabled, let changed {
            content
                .contentShape(Rectangle())
                .hoverCursor(.openHand)
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .updating($moving) { _, active, _ in active = true }
                    .onChanged { changed($0.translation) }
                    .onEnded { _ in ended?() })
                .onChange(of: moving) { _, active in if !active { ended?() } }
        } else {
            content
        }
    }
}
#endif

private struct TitleDrag: ViewModifier {
    let provider: (() -> NSItemProvider)?

    func body(content: Content) -> some View {
        #if os(macOS)
        if let provider {
            content.onDrag(provider)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// 面板外观：全屏模式实底贴边（底色漫进状态栏/底部安全区，内容不漫）；浮窗模式玻璃圆角。
/// 玻璃走 `shellGlass`：iOS 26 / macOS 26 Liquid Glass，macOS 15 退回材质（plan-mac-shape ⧫3）
struct PanelChrome: ViewModifier {
    let docked: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        chrome(content.environment(\.inGlassChrome, MacGlass.shared.enabled))
        #else
        chrome(content)
        #endif
    }

    @ViewBuilder
    private func chrome(_ content: some View) -> some View {
        #if os(macOS)
        if docked {
            // 全屏模式：面板平铺在桌布上 ⇒ 和桌布同色。
            // **不能改成透明**：`IPadPanelOverlay.dockedBody` 把桌面组件层压在最底（那里的注释：
            // 面板盖住那一侧的格子，所以不能往那儿拖），透明会漏出组件，也塌掉那条交互前提。
            // **必须 `ignoresSafeAreaEdges: []`**（09-18）：停靠壳里工作区上方那 32pt 是标题行，`.background(Color)`
            // 默认漫进安全区，底色被工作区的 `.clipped()` 裁掉画面但命中还在，把标题行两端的钮整个盖死。
            // 桌布本来就是整棵树的背景（`macDockedTree`），这里不用再漫。
            // 窗口玻璃开 → `chrome` 是 clear，露窗底玻璃（plan-mac-glass-chrome §1.3）
            content.background(ShellStyle.chrome, ignoresSafeAreaEdges: [])
        } else if MacGlass.shared.enabled {
            // 玻璃开：浮窗是一块独立玻璃，盖在正文卡上也看得清
            content
                .clipShape(RoundedRectangle(cornerRadius: ShellStyle.windowRadius, style: .continuous))
                .shellGlass(in: RoundedRectangle(cornerRadius: ShellStyle.windowRadius, style: .continuous), tint: 0.12)
                .shadow(color: ShellStyle.shadow, radius: ShellStyle.shadowRadius, y: 4)
        } else {
            content
                .background(ShellStyle.background)
                .clipShape(RoundedRectangle(cornerRadius: ShellStyle.windowRadius, style: .continuous))
                .shadow(color: ShellStyle.shadow, radius: ShellStyle.shadowRadius, y: 4)
                .overlay {
                    RoundedRectangle(cornerRadius: ShellStyle.windowRadius, style: .continuous)
                        .strokeBorder(ShellStyle.hairline, lineWidth: ShellStyle.hairlineWidth)
                        .allowsHitTesting(false)
                }
        }
        #else
        if docked {
            content.background(Theme.sidebarBg.ignoresSafeArea(edges: .vertical))
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shellGlass(in: RoundedRectangle(cornerRadius: 19), tint: 0.12)
        }
        #endif
    }
}

/// 工具图标：dock 钮和 tab 共用一套（`topicBox` 是像素灯泡特例，其余走 `AppIconView`）
struct ToolGlyph: View {
    let tool: RightPanelTool?
    let size: CGFloat
    let color: Color

    var body: some View {
        if tool?.id == "topicBox" {
            PixelIcon(bitmap: PixelGlyph.lightbulb, size: size - 1, color: color)
        } else {
            AppIconView(name: tool?.icon ?? "square.grid.2x2", size: size, tint: color, weight: .medium, toolID: tool?.id)
        }
    }
}
