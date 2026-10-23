import SwiftUI

/// 列表行的指针悬停底色（plan-mac-pointer-model S1-2）。
///
/// **为什么按 `widePanelMode` 而不是 `#if os(macOS)`**：iPad 横屏接妙控板的指针和 mac 是一回事，
/// 两边都该亮；只有窄屏 iPhone 没有指针（审计 §8 P5 的判定）。
///
/// **为什么不按 `widePanelMode` 分支返回 content**：plan 原写「false 时直接返回 content 不挂 `.onHover`」，
/// 实现时改了——那样 body 会产出 `_ConditionalContent`，而 iPad 转屏时 `widePanelMode` 会翻，
/// 列表里整片行的 identity 跟着换（`feedback_swiftui_conditional_view_frozen` / `feedback_id_rebuild_minefield`）。
/// 现在恒挂一层，用**颜色**兜住：窄屏时 `widePanel` 为 false，不透明度恒 0，视觉零变化。
/// iPhone 上 `.onHover` 本来也永远不触发，代价只有一层 `background`。
///
/// 底色优先级：**选中 > 悬停 > 透明**。悬停色 = `Theme.textSecondary.opacity(0.07)`，
/// 和 mac 壳的 `ShellStyle.hover` 同一配方（`ShellStyle` 是 `#if os(macOS)`，iPad 够不着，所以抄配方不抄符号）。
/// 中性灰，**不给薄荷垫薄荷**（`feedback_no_green_on_green`）。
struct RowHover: ViewModifier {
    /// 行内容到悬停矩形的水平内缩。默认 4 = `ConversationRow` 自己那层选中底的内缩
    var insetH: CGFloat = 4
    var radius: CGFloat = 10
    /// 这一行已经被选中 → 不画悬停层，让选中色自己说话
    var selected: Bool = false

    @Environment(\.widePanelMode) private var widePanel
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.textSecondary.opacity(0.07))
                    // 显隐走 opacity 不走 if（.claude/rules/swiftui-ui.md）
                    .opacity(widePanel && hovered && !selected ? 1 : 0)
                    .padding(.horizontal, insetH)
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

extension View {
    /// 列表行悬停底色。`selected` 传行自己的选中态，避免悬停色盖在选中色上。
    func rowHover(selected: Bool = false, insetH: CGFloat = 4, radius: CGFloat = 10) -> some View {
        modifier(RowHover(insetH: insetH, radius: radius, selected: selected))
    }
}

/// 订阅一条通知。**给 `ContentView.body` 那种已经贴着类型检查预算的长链用**——
/// 直接在链上写 `.onReceive(NotificationCenter.default.publisher(for:))` 会多一层 Publisher 泛型要解，
/// S1-4 加 ⌘N 时就是这么把 iOS 侧顶成 "unable to type-check this expression in reasonable time" 的
/// （把闭包体抽成方法不够，压垮它的是链上那一项本身）。包成独立 modifier，泛型在这里解完。
struct OnNotify: ViewModifier {
    let name: Notification.Name
    let action: () -> Void

    init(_ name: Notification.Name, action: @escaping () -> Void) {
        self.name = name
        self.action = action
    }

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
