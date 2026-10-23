import SwiftUI

/// Platform adapter: mac owns a configurable dock; iPad keeps its Page 2 dock.
struct VerticalDock: View {
    let layout: IPadPanelLayout
    var workspaceSize: CGSize = .zero
    #if os(macOS)
    var body: some View { MacWorkspaceDock(layout: layout, workspaceSize: workspaceSize) }
    #else
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @State private var deskMgr = Page2DesktopManager.shared
    @State private var draggingToolId: String? = nil
    @State private var hoveredToolId: String? = nil

    private var tools: [RightPanelTool] {
        guard let tm = toolManager else { return [] }
        return deskMgr.dockTools(tm)
    }

    /// 图标之间的间距。全屏模式走活参数（她在参数台里调），浮窗保持 2
    private var itemGap: CGFloat {
        2
    }


    var body: some View {
        VStack(spacing: itemGap) {
            // 装得下就贴着内容高（浮窗模式一条短短的），装不下才退成滚动
            ViewThatFits(in: .vertical) {
                toolColumn
                ScrollView(.vertical, showsIndicators: false) { toolColumn }
            }
            // 工具列与底部钮之间的分隔线。**两个模式共用同一个 VerticalDock**
            // （浮窗 dock 直接用它），所以全屏平铺要关的时候必须门控，别把浮窗 dock 的线一起收了（R-FS S1.3）
            dockDivider
            modeButton
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .frame(width: IPadPanelLayout.dockWidth)
        .frame(maxHeight: layout.mode == .docked ? .infinity : nil, alignment: .top)
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.35))
            .frame(height: 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
    }

    private var dockRadius: CGFloat {
        13
    }

    private var toolColumn: some View {
        VStack(spacing: itemGap) {
            ForEach(tools) { tool in
                dockItem(tool)
            }
        }
    }

    /// mac 拖放松手才排序，取消不写；iPad 排序仍在页 2 的 dock。
    @ViewBuilder
    private func dockItem(_ tool: RightPanelTool) -> some View {
        dockButton(tool)
    }

    private func dockButton(_ tool: RightPanelTool) -> some View {
        let on = layout.isOpen(tool.id)
        return Button {
            dockTap(tool.id)
        } label: {
            ToolGlyph(tool: tool, size: 17, color: on ? Theme.branchIndicator : Theme.textSecondary)
            .frame(width: 42, height: 42)
            .background(
                RoundedRectangle(cornerRadius: dockRadius, style: .continuous)
                    .fill(dockFill(on: on, hovered: hoveredToolId == tool.id))
            )
            .overlay(alignment: .leading) {
                if on {
                    Capsule().fill(Theme.branchIndicator)
                        .frame(width: 3, height: 16)
                        .offset(x: -5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredToolId = $0 ? tool.id : (hoveredToolId == tool.id ? nil : hoveredToolId) }
        .help(tool.name)
        .accessibilityLabel(tool.name)
    }

    private func dockTap(_ id: String) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { layout.dockTap(id) }
    }

    private func dockFill(on: Bool, hovered: Bool) -> Color {
        Theme.branchIndicator.opacity(on ? 0.18 : (hovered ? 0.08 : 0))
    }


    /// 两档菜单（窗口 / 全屏），图标画的是当前档
    private var modeButton: some View {
        Menu {
            Picker("面板模式", selection: Binding(
                get: { layout.mode },
                set: { m in withAnimation(ShellMotion.structure(.spring(response: 0.36, dampingFraction: 0.88))) { layout.mode = m } }
            )) {
                ForEach(IPadPanelLayout.Mode.allCases, id: \.self) { m in
                    Label(m.label, systemImage: m.icon).tag(m)
                }
            }
        } label: {
            Image(systemName: layout.mode.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("面板模式：\(layout.mode.label)")
    }
    #endif
}
