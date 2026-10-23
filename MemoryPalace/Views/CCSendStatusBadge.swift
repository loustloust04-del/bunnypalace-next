import SwiftUI

struct CCSendStatusBadge: View {
    let entry: CCSendStatusEntry

    var body: some View {
        switch entry.state {
        case .uncertain:
            ChatSystemCapsule(text: "正在确认有没有送到", symbol: "clock")
        case .failed:
            ChatSystemCapsule(text: "没送达" + (entry.visibleReason.map { " · " + $0 } ?? ""),
                              symbol: "exclamationmark.circle", isError: true,
                              actionTitle: entry.canRetry ? "重发" : nil,
                              action: entry.canRetry ? { CCBridgeWebSocketClient.shared.retrySend(messageId: entry.messageId) } : nil)
                .accessibilityValue(entry.accessibilityValue)
        case .delivered:
            EmptyView()
        }
    }
}
