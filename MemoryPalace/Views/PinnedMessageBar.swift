import SwiftUI

/// 顶部浮动 Pin Bar — 学 Telegram：玻璃胶囊，每次只显示一条 pin，tap 轮换到下一条。
/// 所有状态由外层 CardFlowView 持有（pin 列表、当前 index、是否隐藏）。
struct PinnedMessageBar: View {
    @Environment(\.chatMetrics) private var metrics
    let pinnedNodes: [MessageNode]
    @Binding var currentIndex: Int
    @Binding var isHidden: Bool
    let onTap: () -> Void
    let onUnpinCurrent: () -> Void
    let onUnpinAll: () -> Void

    var body: some View {
        if !pinnedNodes.isEmpty && !isHidden {
            let idx = min(currentIndex, max(pinnedNodes.count - 1, 0))
            let current = pinnedNodes[idx]
            HStack(spacing: 10) {
                // 左侧 accent 竖线
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.branchIndicator)
                    .frame(width: 3, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                    Text(previewText(current))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.trailing, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)   // 32 + 2×6 = 44pt 和 nav 圆按钮等高
            .frame(maxWidth: .infinity)
            #if os(iOS)
            // 不加 .interactive()：iOS 26 的 interactive glass 层会吞 tap
            // （回底按钮踩过坑，坐实了这个 bug）
            .glassEffect(.regular.tint(Color.white.opacity(0.15)),
                         in: Capsule(style: .continuous))
            #else
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Theme.accent.opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 3)
            #endif
            .contentShape(Capsule())
            .onTapGesture(perform: onTap)
            .contextMenu {
                Button(role: .destructive, action: onUnpinCurrent) {
                    Label("取消钉住此条", systemImage: "pin.slash")
                }
                Button(role: .destructive, action: onUnpinAll) {
                    Label("取消所有钉住", systemImage: "pin.slash.fill")
                }
                Button(action: { isHidden = true }) {
                    Label("暂时隐藏", systemImage: "eye.slash")
                }
            }
            // 外边距进表：mac 20/6/4 对齐 HoverButtons 外边缘；iOS 0（外围 padding 由 ContentView.iOSChatTopBar 的 HStack 管布局）
            .padding(metrics.pinBarInsets)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var titleText: String {
        if pinnedNodes.count <= 1 {
            return "Pinned Message"
        }
        let safeIdx = min(currentIndex, pinnedNodes.count - 1)
        return "Pinned #\(safeIdx + 1) / \(pinnedNodes.count)"
    }

    private func previewText(_ node: MessageNode) -> String {
        let cleaned = ContentCleaner.clean(node.content, cacheKey: node.id)
        return String(cleaned.prefix(60))
    }
}
