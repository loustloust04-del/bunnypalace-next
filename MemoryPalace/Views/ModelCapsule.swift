import SwiftUI

/// 聊天输入栏底部的模型胶囊（「cc-opus-4.6-1m」）。会话模型只在这里读（审查 R1-6，照 CCSendStatusBadge）：
/// 订阅者是胶囊自己，模型变了只重算它，不连带整个 ChatInputBar。父视图只传卡名和那一项（稳定对象，不读它的属性）
struct ModelCapsule: View {
    let cardName: String
    /// cc-bridge 卡且对话已绑会话时是那个会话的一项；别的卡 nil
    let entry: CCSessionModelEntry?
    let onTap: () -> Void

    /// 父视图取那一项用这个：只查索引、不读 model，父视图不会因此订阅模型变化
    @MainActor
    static func entry(isCCBridge: Bool, sessionName: String?, store: CCSessionModelStore? = nil) -> CCSessionModelEntry? {
        guard isCCBridge, let sessionName else { return nil }
        return (store ?? .shared).entry(for: sessionName)
    }

    var title: String { CCSessionModelStore.capsuleTitle(cardName: cardName, model: entry?.model) }

    var body: some View {
        #if os(iOS)
        // iOS26 玻璃教训：glassEffect(.interactive()) 套在 Button(.plain) 里会吞 hit test（时点不灵）。
        // 改普通视图 + onTapGesture，热区外扩 6pt（padding→contentShape→负 padding 还原布局），视觉不变。
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.branchIndicator.opacity(0.6))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                // 单行+中间截断（不 fixedSize）：排内挤压时这里优雅让位，超长模型名也不撑爆整排
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7))
                .foregroundColor(Theme.textMuted.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(Theme.accent).interactive())
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityLabel("模型：\(title)")
        .padding(-6)
        #else
        // mac 用真 Button：iOS 的手势 workaround 连带丢了 hover/焦点语义（A-8）
        Button { onTap() } label: {
            MacShellLabel(symbol: "circle.dotted", title: title, chevron: true)
                .truncationMode(.middle)   // B3：长模型名中间截断（MacShellLabel 已 lineLimit(1)），同 iOS
        }
        .buttonStyle(MacShellButton(compact: true, horizontalPadding: 7))
        .help("选择模型：\(title)")
        .accessibilityLabel("模型：\(title)")
        #endif
    }
}
