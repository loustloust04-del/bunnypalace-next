import SwiftUI

struct ChatSystemCapsule: View {
    let text: String
    var symbol: String = "info.circle"
    var isError: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// 第二个按钮位：报错「去改」（plan-api-draft-and-fix-jump §3.4）。默认 nil，现有调用方不受影响
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

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
            if let secondaryTitle, let secondaryAction {
                if actionTitle != nil && action != nil {
                    Text("·").foregroundStyle(Theme.textMuted)
                }
                Button(secondaryTitle, action: secondaryAction)
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
                VStack(alignment: .leading, spacing: 14) {
                    Text(ChatSystemMessage.noticeText(text))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 单行胶囊被挤时，点开详情也能找到「去改」
                    if let secondaryTitle, let secondaryAction {
                        Button {
                            showDetails = false
                            // 详情 sheet 收起再跳：iOS 同一时刻只能 present 一个
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: secondaryAction)
                        } label: {
                            Text(secondaryTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Theme.accent))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
