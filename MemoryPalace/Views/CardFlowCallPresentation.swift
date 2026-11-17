#if os(iOS)
import SwiftUI

/// 聊天页的通话页挂载（11-16 从 CardFlowView.swift 拆出来：那个文件只许变短）。
/// 独立 modifier，避免给 CardFlow 的大视图表达式叠加两个 Observation 泛型。
struct CardFlowCallPresentation<CallContent: View>: ViewModifier {
    let conversationID: String?
    @Binding var presented: Bool
    let callContent: CallContent
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $presented) { callContent }
            .modifier(NativeCallPresentation(conversationID: conversationID, presented: $presented))
            // 人页「通话」（11-16）：同 + 号条 📞 打开通话页
            .onReceive(NotificationCenter.default.publisher(for: .voiceCallRequested)) { _ in
                if conversationID != nil { presented = true }
            }
    }
}

private struct NativeCallPresentation: ViewModifier {
    let conversationID: String?
    @Binding var presented: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: NativeCallCoordinator.shared.readyToPresent, initial: true) { _, _ in presentIfReady() }
            .onChange(of: conversationID) { _, _ in presentIfReady() }
    }
    private func presentIfReady() {
        if NativeCallCoordinator.shared.readyToPresent,
           NativeCallCoordinator.shared.current?.chat_id == conversationID { presented = true }
    }
}
#endif
