import SwiftUI
import SwiftStreamingMarkdown

/// 进度卡（粟粟 10-03「都按推荐」）：API 模型连调工具时出在对话最底下（审批卡上面）。
/// 第几轮、正在用哪个工具（跑了几秒）、已做完的打勾 / 打叉、卡住的原因；「停下」= 输入框的停止
struct TurnActivityCardView: View {
    let activity: TurnActivity
    var blocked: TurnActivity.Block?
    let onStop: () -> Void

    private var finished: [TurnActivity.Step] { activity.steps.filter { $0.ok != nil } }

    var body: some View {
        ChatCardShell(kindLabel: "进度") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    statusIcon
                    // 秒数只在这一行跳（每秒重画这一行，不碰列表）
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(activity.headline(now: ctx.date, blocked: blocked))
                            .font(.subheadline)
                            .monospacedDigit()
                            .lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Button(action: onStop) {
                        Label("停下", systemImage: "stop.fill")
                            .font(.caption.weight(.medium))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("停止这一轮回复，和输入框的停止一样")
                }
                if !finished.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(finished, id: \.id) { step in chip(step) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch blocked {
        case .approval: Image(systemName: "lock.shield").foregroundStyle(Theme.branchIndicator)
        case .question: Image(systemName: "questionmark.circle").foregroundStyle(Theme.branchIndicator)
        case nil:
            if let running = activity.running {
                Image(systemName: running.icon ?? "wrench.and.screwdriver")
                    .foregroundStyle(Theme.branchIndicator)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Image(systemName: "ellipsis")
                    .foregroundStyle(CodeBlockStyle.label)
            }
        }
    }

    private func chip(_ step: TurnActivity.Step) -> some View {
        HStack(spacing: 4) {
            if let icon = step.icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(step.label).font(.caption)
            Image(systemName: step.ok == true ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(step.ok == true ? Theme.branchIndicator : Color.red.opacity(0.75))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(CodeBlockStyle.label.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.label)，\(step.ok == true ? "完成" : "失败")")
    }
}

/// 列表里挂的壳：所有读 VM / 审批中心的地方都在这里，列表 body 不因进度变化重算
struct TurnActivityHost: View {
    let viewModel: ConversationViewModel
    let conversationId: String
    let onStop: () -> Void

    var body: some View {
        if let activity = viewModel.turnActivity(for: conversationId) {
            TurnActivityCardView(activity: activity, blocked: blocked, onStop: onStop)
        }
    }

    private var blocked: TurnActivity.Block? {
        if let req = PermissionPromptCenter.shared.pendingRequest, req.approval?.conversationId == conversationId {
            return .approval(req.domain.displayName)
        }
        if viewModel.pendingUserQuestion?.conversationId == conversationId { return .question }
        return nil
    }
}
