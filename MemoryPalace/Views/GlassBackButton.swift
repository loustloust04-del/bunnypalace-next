import SwiftUI

#if os(iOS)
/// 统一的玻璃返回/关闭按钮。
/// 样式取自聊天页顶栏返回键（ContentView.iOSChatTopBar）：
/// 暖灰薄荷主题下不死黑的 chevron + 玻璃圆圈，44pt 命中区。
/// push 子页传 chevron.left（返回），sheet 模态传 chevron.down（下拉关闭）。
struct GlassBackButton: View {
    var systemImage: String = "chevron.left"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }
}
#endif
