import SwiftUI

#if os(macOS)
/// Insets are part of the existing slot budget, so panel drag/drop coordinates remain stable.
struct MacWorkspacePane: ViewModifier {
    var enabled: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        let metrics = MacShellMetrics.shared
        let shape = RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
        if enabled {
            content
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(ShellStyle.hairline, lineWidth: metrics.cardBorder)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, ShellStyle.paneInset)
                .padding(.top, metrics.cardGapTop)
                .padding(.bottom, metrics.cardGapBottom)
        } else { content }
    }
}

/// 列里一个组的卡片外形（圆角裁切 + 描边），**不带**外边距——列容器把 `MacWorkspacePane` 的边距整列只扣一次
/// （plan-panel-ps §6 2b，A I5），组与组之间的缝就是拖尺寸的把手
struct MacPaneCard: ViewModifier {
    func body(content: Content) -> some View {
        let metrics = MacShellMetrics.shared
        let shape = RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(ShellStyle.hairline, lineWidth: metrics.cardBorder)
                    .allowsHitTesting(false)
            }
    }
}
#endif
