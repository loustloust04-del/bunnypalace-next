import SwiftData
import SwiftUI

/// 计时器到点自动告诉模型（research-chat-cards §8.2 / §8.5）：挂在聊天页（不在输入条上——贴纸 / 搜索面板会替换输入条）。
/// 条件：目标对话打开 + 前台 + 模型没在回 + 输入框没挂引用；受理成功才 ack，失败放回下次再试；消息已不在路径 → 丢弃。
enum TimerDelivery {
    enum Decision: Equatable { case send, wait, drop }

    static func shouldSend(event: TimerFinishedEvent, selectedConversationId: String?, pathNodeIds: Set<String>,
                           isActive: Bool, turnInFlight: Bool, hasQuote: Bool) -> Decision {
        guard selectedConversationId == event.conversationId else { return .wait }
        guard pathNodeIds.contains(event.nodeId) else { return .drop }
        guard isActive, !turnInFlight, !hasQuote else { return .wait }
        return .send
    }
}

private struct TimerDeliveryModifier: ViewModifier {
    let viewModel: ConversationViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @AppStorage("selectedChatModel") private var selectedModelId = ""

    private var store: TimerCardStore { .shared }

    func body(content: Content) -> some View {
        content
            .onChange(of: store.outbox) { _, _ in deliver() }
            .onChange(of: viewModel.selectedConversation?.id) { _, _ in deliver() }
            .onChange(of: viewModel.assistantTurnInFlight) { _, _ in deliver() }
            .onChange(of: viewModel.ccWaitingSince) { _, _ in deliver() }
            .onChange(of: viewModel.quotingPreview) { _, _ in deliver() }
            .onChange(of: scenePhase) { _, _ in deliver() }
            .onAppear {
                store.checkExpired()                                     // 关着 app 时到点的，回来先结算
                deliver()
            }
    }

    private func deliver() {
        guard let convId = viewModel.selectedConversation?.id, let providerManager else { return }
        while let event = store.claim(conversationId: convId) {
            let decision = TimerDelivery.shouldSend(
                event: event, selectedConversationId: convId,
                pathNodeIds: Set(viewModel.currentPath.map(\.id)),
                isActive: scenePhase == .active,
                turnInFlight: ConversationViewModel.isBusy(conversationId: convId),   // 所有窗口 + CC 等回复
                hasQuote: viewModel.quotingPreview != nil)
            switch decision {
            case .drop:
                store.ack(event.id)
            case .wait:
                store.release(event.id)
                return
            case .send:
                let prof = profileManager?.currentProfile ?? Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
                let preset = presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
                let model = providerManager.resolveModel(
                    conversationModelId: viewModel.selectedConversation?.selectedModelId,
                    globalFallbackId: selectedModelId)
                let accepted = viewModel.sendMessage(event.text, model: model, profile: prof, preset: preset,
                                                     providerManager: providerManager, context: modelContext, attachments: [])
                if accepted {
                    store.ack(event.id)
                } else if store.deliveryFailed(event.id) {         // 被拒（预算等）：隔 10 分钟再试，连败 3 次放弃
                    ToastCenter.shared.show("计时结束的消息没发出去，已放弃")
                }
                return                                                      // 一次发一条；发完 turn 结束会再触发
            }
        }
    }
}

extension View {
    func timerDelivery(viewModel: ConversationViewModel) -> some View {
        modifier(TimerDeliveryModifier(viewModel: viewModel))
    }
}
