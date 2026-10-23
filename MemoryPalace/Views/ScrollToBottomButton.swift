import SwiftUI

/// 右下悬浮玻璃按钮 — 离底时出现，点击回底。
///
/// **iOS 26 正确做法**：用 `.buttonStyle(.glass)` 官方 GlassButtonStyle，不要
/// 用 `.glassEffect(...)` + `.buttonStyle(.plain)` 的 hack 组合（会吞 hit test
/// 和按压反馈，粟粟实测 5/6 次点不中）。
/// - Pin bar 用 `.glassEffect(...)` 没问题是因为它是 HStack + .onTapGesture，
///   不是 SwiftUI Button
struct ScrollToBottomButton: View {
    let isVisible: Bool
    /// 底下正在生成（流式回合中）→ 徽章位呼吸薄荷点
    var isGenerating: Bool = false
    /// 有没看的新回复（翻历史时到达/生成完）→ 徽章常亮
    var hasNewReply: Bool = false
    let action: () -> Void

    /// 呼吸动画驱动（只在生成中挂 repeatForever，徽章消失即拆）
    @State private var breathing = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.textMuted)
        }
        #if os(iOS)
        // 不 clipShape、不 frame — glass 内置按压 morph 动画需要空间自由形变
        .buttonStyle(.glass)
        #else
        .buttonStyle(.plain)
        .background(Circle().fill(.ultraThinMaterial))
        .overlay(Circle().stroke(Theme.accent.opacity(0.4), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        #endif
        // 徽章：同一颗薄荷点两种状态——呼吸=底下在生成，常亮=有新回复没看
        .overlay(alignment: .topTrailing) {
            if isVisible && (isGenerating || hasNewReply) {
                Circle()
                    .fill(Theme.branchIndicator)
                    .frame(width: 7, height: 7)
                    .opacity(isGenerating && !hasNewReply ? (breathing ? 1.0 : 0.35) : 1.0)
                    .offset(x: 1, y: -1)
                    .onAppear {
                        guard isGenerating && !hasNewReply else { return }
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            breathing = true
                        }
                    }
                    .onDisappear { breathing = false }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: hasNewReply)
        .animation(.spring(duration: 0.3), value: isGenerating)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 8)
        .animation(.spring(duration: 0.3), value: isVisible)
        .allowsHitTesting(isVisible)
        .accessibilityIdentifier("scroll-to-bottom")
    }
}
