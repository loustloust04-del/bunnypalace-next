import SwiftUI

extension View {
    /// 壳的玻璃语言（plan-mac-shape ⧫3：保 macOS 15 兼容、26 有玻璃）：
    /// iOS 26 / macOS 26 用 Liquid Glass；macOS 15 退回材质 + 0.5pt 描边。
    /// 现役两处参数不同——面板 0.12 不可交互、悬浮条 0.15 可交互——所以 tint / interactive 都由调用方给。
    @ViewBuilder
    func shellGlass<S: Shape>(in shape: S, tint: Double, interactive: Bool = false) -> some View {
        #if os(iOS)
        if interactive {
            self.glassEffect(.regular.tint(Color.white.opacity(tint)).interactive(), in: shape)
        } else {
            self.glassEffect(.regular.tint(Color.white.opacity(tint)), in: shape)
        }
        #else
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.tint(Color.white.opacity(tint)).interactive(), in: shape)
            } else {
                self.glassEffect(.regular.tint(Color.white.opacity(tint)), in: shape)
            }
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(ShellStyle.hairline, lineWidth: ShellStyle.hairlineWidth).allowsHitTesting(false))
        }
        #endif
    }
}

extension EnvironmentValues {
    /// 当前在 mac 窗口玻璃的列里（`PanelChrome` 注入，plan-mac-glass-chrome §1.4）。iOS / sheet / 设置窗永远 false
    @Entry var inGlassChrome = false
}

extension View {
    /// 工具页整页底色：在玻璃列里清空、露窗底玻璃，其他地方照旧画 `color`。
    /// 只给「铺满整页、和列同色」那一层用；页里的卡片、列表行、输入框保持实底
    func toolPageBackground(_ color: Color = Theme.sidebarBg) -> some View {
        modifier(ToolPageBackground(color: color))
    }
}

private struct ToolPageBackground: ViewModifier {
    @Environment(\.inGlassChrome) private var inGlassChrome
    let color: Color

    func body(content: Content) -> some View {
        #if os(macOS)
        // mac 别漫进安全区：停靠壳工作区上方是标题行，漫进去会盖死标题行的钮（09-18，同 PanelChrome）
        content.background(inGlassChrome ? Color.clear : color, ignoresSafeAreaEdges: [])
        #else
        content.background(color)
        #endif
    }
}
