import SwiftUI
import SwiftStreamingMarkdown

/// 计时器卡（research-chat-cards §8.2 / §8.5）：本机倒计时；定稿后才登记自动开始；旧版本（含首次出现就是旧版）自动取消
struct TimerCardView: View {
    let card: TimerCard
    let nodeId: String?
    let streaming: Bool
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?

    private var store: TimerCardStore { .shared }
    private var conversationId: String? { viewModel?.selectedConversation?.id }
    private var key: String? {
        guard let nodeId, let conversationId, let id = ChatCard.timer(card).id else { return nil }
        return TimerCardStore.key(conversationId: conversationId, nodeId: nodeId, cardId: id)
    }

    static func clockText(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var body: some View {
        let status: ChatCardStatus = streaming ? .readOnly : (viewModel?.cardStatus(.timer(card), nodeId: nodeId) ?? .readOnly)
        let phase = key.map(store.phase) ?? .idle
        ChatCardShell(kindLabel: "计时器", badge: status == .stale ? .stale : .none) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(CodeBlockStyle.stroke.opacity(0.4), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: progress(phase: phase, now: context.date))
                            .stroke(Theme.branchIndicator, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.displayTitle).font(.headline)
                        Text(remainingText(phase: phase, now: context.date))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer()
                    if status == .live, let key, let conversationId, let nodeId {
                        controls(phase: phase, key: key, conversationId: conversationId, nodeId: nodeId)
                    }
                }
            }
        }
        // 定稿后（streaming 变 false）才登记；旧版本随时取消——含第一次出现就是旧版
        .task(id: "\(streaming)|\(status)") { reconcile(status: status) }
    }

    private func reconcile(status: ChatCardStatus) {
        guard !streaming, let key else { return }
        if status == .stale { store.cancel(key); return }
        guard status == .live, card.autoStart, let conversationId, let nodeId,
              let sentAt = viewModel?.currentPath.first(where: { $0.id == nodeId })?.createTime else { return }
        store.registerAutoStart(key: key, conversationId: conversationId, nodeId: nodeId, card: card, sentAt: sentAt)
    }

    @ViewBuilder
    private func controls(phase: TimerPhase, key: String, conversationId: String, nodeId: String) -> some View {
        HStack(spacing: 10) {
            switch phase {
            case .running:
                button("pause.fill") { store.pause(key) }
            case .idle, .paused, .finished:
                button(phase == .finished ? "arrow.clockwise" : "play.fill") {
                    store.start(key: key, conversationId: conversationId, nodeId: nodeId, card: card)
                }
            }
            if case .running = phase { button("arrow.counterclockwise") { store.reset(key) } }
            if case .paused = phase { button("arrow.counterclockwise") { store.reset(key) } }
        }
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(CodeBlockStyle.stroke.opacity(0.3)))
                .foregroundStyle(CodeBlockStyle.label)
        }
        .buttonStyle(.plain)
    }

    private func remainingText(phase: TimerPhase, now: Date) -> String {
        switch phase {
        case .idle: return Self.clockText(TimeInterval(card.seconds))
        case .running(let end): return Self.clockText(max(0, end.timeIntervalSince(now)))
        case .paused(let r): return Self.clockText(r)
        case .finished: return "时间到"
        }
    }

    private func progress(phase: TimerPhase, now: Date) -> CGFloat {
        let total = TimeInterval(card.seconds)
        switch phase {
        case .idle: return 1
        case .running(let end): return CGFloat(max(0, end.timeIntervalSince(now)) / total)
        case .paused(let r): return CGFloat(r / total)
        case .finished: return 0
        }
    }
}
