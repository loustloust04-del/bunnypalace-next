import SwiftUI

/// 用户消息头上的「📎 n」：这条捎带了几条事件给模型（research-chat-cards §13），点开看是哪些
struct CardEventsChip: View {
    let node: MessageNode
    @State private var showing = false

    var body: some View {
        let events = node.role == "user" ? node.cardEvents : []
        if !events.isEmpty {
            Button { showing = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 8))
                    Text("\(events.count)")
                        .font(.caption2.weight(.medium))
                }
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.accent.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("捎带了 \(events.count) 条事件")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这条顺带告诉了模型")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textMuted)
                    ForEach(events) { event in
                        Text("· \(event.text)")
                            .font(.footnote)
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: 320, alignment: .leading)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}
