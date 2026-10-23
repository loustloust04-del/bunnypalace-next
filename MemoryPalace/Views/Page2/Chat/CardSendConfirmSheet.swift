#if os(iOS)
import SwiftUI

/// 卡库第二批 B5（小样 ①）：卡里的网页第一次要替你发消息时的半屏确认。
/// 卡名 + 要发的话（你自己的气泡样式）+ 会不会让 AI 回复；「允许并记住 / 只这一次 / 不允许」从重到轻排
struct CardSendConfirmSheet: View {
    let confirmation: CardSendConfirmation
    var avatarData: Data?
    let onChoice: (CardSendChoice) -> Void

    private static let space = "cardSendConfirm"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                head
                TicketNotch()
                Text(confirmation.texts.isEmpty ? "不发新消息" : "要发的话")
                    .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 22).padding(.bottom, 7)
                if !confirmation.texts.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(Array(confirmation.texts.enumerated()), id: \.offset) { _, text in bubble(text) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 22)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: confirmation.replies ? "arrowshape.turn.up.left" : "text.bubble")
                        .font(.system(size: 14)).foregroundColor(Theme.branchIndicator)
                    Text(explain).font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                }
                .padding(.horizontal, 22).padding(.top, 14)
                Text("选「允许并记住」后，这张卡的按钮会直接发送；可在 卡库 › 设置 › 前端卡 里改回。")
                    .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 47).padding(.trailing, 22).padding(.top, 5)
                actions
            }
            .padding(.top, 18).padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .coordinateSpace(name: Self.space)
        .background(Theme.mainBg)
    }

    private var explain: String {
        if confirmation.texts.isEmpty { return "会让 AI 接着现在的对话回复一次。" }
        return confirmation.replies ? "发出后会让 AI 回复一次。" : "只加进聊天，不会让 AI 回复。"
    }

    private var head: some View {
        HStack(spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text("「\(confirmation.cardName)」想替你\(confirmation.texts.isEmpty ? "让 AI 回复" : "发一条消息")")
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("来自这张卡里的网页按钮").font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 4)
    }

    @ViewBuilder
    private var avatar: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let avatarData, let image = UIImage(data: avatarData) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 38, height: 38).clipShape(shape)
        } else {
            Text(String(confirmation.cardName.prefix(1)))
                .font(.system(size: 16, weight: .medium)).foregroundColor(Theme.textPrimary)
                .frame(width: 38, height: 38)
                .background(Theme.accent, in: shape)
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14)).foregroundColor(Theme.userText)
            .lineLimit(6)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background {
                UserBubbleFill(shape: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5, topTrailingRadius: 18),
                               base: Theme.userBubble, gradient: Theme.userBubbleGradient, anchor: .named(Self.space))
            }
            .frame(maxWidth: 280, alignment: .trailing)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            button("允许并记住", primary: true) { onChoice(.allowAlways) }
            button("只这一次", primary: false) { onChoice(.once) }
            Button { onChoice(.deny) } label: {
                Text("不允许").font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(confirmation.texts.isEmpty ? "不允许时，不会让 AI 回复。" : "不允许时，这句话放进输入框，由你决定发不发。")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22).padding(.top, 14)
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: primary ? .semibold : .regular))
                .foregroundColor(primary ? Theme.textPrimary : Theme.branchIndicator)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(primary ? Theme.branchIndicator.opacity(0.85) : Theme.textPrimary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// UIKit sheet 被手势划掉（不是代码 dismiss）时回调
final class SheetDismissWatcher: NSObject, UIAdaptivePresentationControllerDelegate {
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss() }
}
#endif
