import SwiftUI

/// 消息下面常驻的一行小灰字：发送时发生了什么（`MessageNode.sendNotice`，plan-send-notice-marker A）
struct SendNoticeLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Theme.chat.textMuted)
            .padding(.horizontal, 6)
            .accessibilityIdentifier("send-notice")
    }
}
