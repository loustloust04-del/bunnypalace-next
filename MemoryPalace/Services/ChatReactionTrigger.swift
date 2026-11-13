import Foundation

/// 贴表情立刻告诉 AI（10-29 粟粟拍板 A；10-30 去掉 2 秒防抖：点了就发）。
/// 正在生成就一直等（10-31 粟粟拍板「要回完就发」，不设上限）：那轮收口时 `turnDidEnd` 马上再投一次；
/// 另隔 2 秒轮询兜底（isLoading / CC 准备期这类不经过回合收口的 busy）。
/// 投递闭包由聊天输入条注册（它手里有模型 / 楼层 / 预设），真发走 `/trigger` 同一条管线。
@MainActor
final class ChatReactionTrigger {
    static let shared = ChatReactionTrigger()

    enum Outcome: Equatable {
        /// 发出去了
        case sent
        /// 箱里没有新贴的表情（撤掉了 / 被她刚发的消息带走了）
        case nothingPending
        /// 正在生成：等那轮结束
        case busy
        /// 输入框里有字：不单独触发，表情跟她正在打的那条一起走
        case typing
        /// 文章对话 / CC 没连上 / 换了对话 / 预算拦：留在箱里随下一条
        case unsupported
    }

    /// 等待期间隔多久轮询一次（兜底；回合收口走 turnDidEnd，不等这个）
    var retryDelay: Duration = .seconds(2)
    var deliver: ((String) -> Outcome)?
    private var tasks: [String: Task<Void, Never>] = [:]
    /// 投递时遇到 busy、正在等那轮结束的对话
    private var waiting: Set<String> = []

    func isPending(_ conversationId: String) -> Bool { tasks[conversationId] != nil }

    func schedule(conversationId: String) {
        attempt(conversationId, after: .zero)
    }

    func cancel(conversationId: String) {
        tasks.removeValue(forKey: conversationId)?.cancel()
        waiting.remove(conversationId)
    }

    /// 一轮回复收口（assistantTurnInFlight 已落回 false、排队发送已排上之后）调：在等的对话马上再投一次
    func turnDidEnd() {
        for conversationId in waiting { attempt(conversationId, after: .zero) }
    }

    private func attempt(_ conversationId: String, after delay: Duration) {
        tasks[conversationId]?.cancel()
        tasks[conversationId] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.tasks[conversationId] = nil
            let registered = self.deliver != nil
            let outcome = self.deliver?(conversationId) ?? .unsupported
            if outcome == .busy {
                if self.waiting.insert(conversationId).inserted {
                    Self.log(.busy, conversationId: conversationId, registered: registered, waited: false)
                }
                self.attempt(conversationId, after: self.retryDelay)
            } else {
                let waited = self.waiting.remove(conversationId) != nil
                Self.log(outcome, conversationId: conversationId, registered: registered, waited: waited)
            }
        }
    }

    /// 10-31：每种没发出去的结果记一条面包屑，事后能看出拦在哪道门；busy 只记「开始等」和「等到了 / 放弃」。
    /// 只带对话 id 前 8 位，不带正文 / 标题
    private static func log(_ outcome: Outcome, conversationId: String, registered: Bool, waited: Bool) {
        let cid = "对话 \(conversationId.prefix(8))"
        let head = waited ? "贴表情等那轮结束后" : "贴表情"
        switch outcome {
        case .sent:
            if waited { BreadcrumbLog.shared.add("⏳", "\(head)发出去了（\(cid)）") }   // 没等过的 triggerReactionReply 自己记 📤
        case .busy:
            BreadcrumbLog.shared.add("⏳", "贴表情开始等：正在生成，那轮结束就发（\(cid)）")
        case .typing:
            BreadcrumbLog.shared.add("⏸️", "\(head)没单独发：输入框有字，留在箱里跟下一条走（\(cid)）")
        case .unsupported:
            let why = registered ? "文章 / CC 没连上 / 只读 / 换了对话 / 预算拦" : "聊天页没注册投递"
            BreadcrumbLog.shared.add("⏸️", "\(head)没单独发：\(why)，留在箱里（\(cid)）")
        case .nothingPending:
            BreadcrumbLog.shared.add("⏸️", "\(head)没发：箱里没有新贴的（撤了 / 被带走了）（\(cid)）")
        }
    }
}
