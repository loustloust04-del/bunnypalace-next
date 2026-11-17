import Foundation
import SwiftData

/// mainsession 里发 `/clear`（plan-floor-main-thread §2.1）：不发给模型，原来那条存档、换一条空的打开
extension ConversationViewModel {
    /// 发送入口在主线程
    func clearMainSession(_ conversation: Conversation, context: ModelContext) {
        let cleared = MainActor.assumeIsolated {
            MainSession.clear(conversation, profileManager: WakeEngine.shared.profileManager, context: context)
        }
        guard let fresh = cleared else { return }
        try? context.save()
        NotificationCenter.default.post(name: .wakeDidDeliver, object: fresh.id)   // 列表刷：存档那条换了名、新的顶上
        loadConversation(fresh, context: context)
    }
}
