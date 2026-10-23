import SwiftUI

/// 进度卡 B（粟粟 10-03「都按推荐」）：CC / codex 对话底部的三个点换成状态卡——
/// 干活中 · 3 分钟 / 在等你回答：…… / 做完了。tmux 会话带「停下」（= 终端里按 Esc）
struct CCPhaseCardView: View {
    let phase: CCSessionPhase

    var body: some View {
        ChatCardShell(kindLabel: "进度") {
            HStack(alignment: .center, spacing: 8) {
                icon
                // 只有「干活中」要走秒：只这一行每秒重画（等你 / 做完了不跳）
                if phase.phase == .working {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in headline(ctx.date) }
                } else {
                    headline(Date())
                }
                Spacer(minLength: 6)
                if phase.phase == .working, phase.canStop {
                    Button {
                        CCBridgeWebSocketClient.shared.sendTerminalInput(session: phase.sessionName, bytes: Data([0x1b]))
                    } label: {
                        Label("停下", systemImage: "stop.fill")
                            .font(.caption.weight(.medium))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("在终端里按一下 Esc，让它停下手上的事")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func headline(_ now: Date) -> some View {
        Text(phase.headline(now: now))
            .font(.subheadline)
            .monospacedDigit()
            .lineLimit(2)
    }

    @ViewBuilder
    private var icon: some View {
        switch phase.phase {
        case .working:
            Image(systemName: "hammer").foregroundStyle(Theme.branchIndicator)
                .symbolEffect(.pulse, options: .repeating)
        case .waiting: Image(systemName: "questionmark.circle").foregroundStyle(Theme.branchIndicator)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(Theme.branchIndicator)
        case .idle: EmptyView()
        }
    }
}

/// 列表里挂的壳：有 hub 推来的状态、且这一轮真在干活（用了工具）或在等你，才出状态卡；否则照旧三个点。
/// 粟粟 10-04：普通聊天（ccrp 只回话）不出卡。「做完了」亮 8 秒后由 task 收起——不再常驻 1 秒一跳的 TimelineView
struct CCPhaseHost: View {
    let conversationId: String
    /// 这个对话发出去了、回复还没落地（原来的三个点）
    let waitingForReply: Bool

    /// 已经亮够的那次「做完了」（按 updated 认）
    @State private var expiredDone: Date?

    var body: some View {
        if let phase = CCSessionPhaseStore.shared.phase(for: conversationId), shows(phase) {
            CCPhaseCardView(phase: phase)
                .task(id: phase.updated) {
                    guard phase.phase == .done else { return }
                    let left = CCSessionPhase.doneLinger - Date().timeIntervalSince(phase.updated)
                    if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                    if !Task.isCancelled { expiredDone = phase.updated }
                }
        } else if waitingForReply {
            CCWaitingBubbleRow()
        }
    }

    private func shows(_ phase: CCSessionPhase) -> Bool {
        if phase.phase == .done, expiredDone == phase.updated { return false }
        return phase.isVisible(now: Date())
    }
}
