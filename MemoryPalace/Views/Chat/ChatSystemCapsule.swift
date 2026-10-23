import SwiftUI

struct ChatSystemCapsule: View {
    let text: String
    var symbol: String = "info.circle"
    var isError: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(isError ? Theme.danger : Theme.textMuted)
                .accessibilityHidden(true)
            Text(ChatSystemMessage.noticeText(text))
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture { showDetails = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("查看完整消息")
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                    .buttonStyle(.plain)
                    .fixedSize()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.accent.opacity(0.45)))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
        .sheet(isPresented: $showDetails) {
            DisclosureSheet(title: isError ? "报错详情" : "系统消息") {
                Text(ChatSystemMessage.noticeText(text))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
