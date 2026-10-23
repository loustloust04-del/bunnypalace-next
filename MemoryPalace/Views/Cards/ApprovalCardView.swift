import SwiftUI
import SwiftStreamingMarkdown

/// 审批卡（粟粟 10-03：按推荐）：AI 要跑命令 / 调要授权的工具时，出在对话最底下（不弹窗）。
/// 完整命令 / 参数一眼看清；拒绝 · 允许这一次 · 本对话都允许；跑命令可以先改再允许。卡在眼前不超时。
/// 一个决定只管这一次调用（改过的命令当场批，旧的允许不套到新命令上）
struct ApprovalCardView: View {
    let request: PermissionPromptCenter.Request

    @State private var editing = false
    @State private var draft = ""
    @State private var showFull = false
    /// 点了允许：先盖章（照抄小芽的邮戳）再收起
    @State private var stamped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var center: PermissionPromptCenter { .shared }

    var body: some View {
        if let approval = request.approval {
            let preview = ApprovalPreview(toolName: approval.toolName, argumentsJSON: approval.argumentsJSON)
            ChatCardShell(kindLabel: "审批") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield").foregroundStyle(Theme.branchIndicator)
                        Text("AI 想用「\(request.domain.displayName)」").font(.headline)
                    }
                    Text(approval.toolName).font(.caption.monospaced()).foregroundStyle(CodeBlockStyle.label)
                    if let command = preview.command { commandBlock(command) }
                    if !preview.rows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preview.rows, id: \.label) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(row.label).font(.caption).foregroundStyle(CodeBlockStyle.label)
                                    Text(row.value).font(.caption.monospaced()).lineLimit(3)
                                }
                            }
                        }
                    }
                    if let labels = request.secretLabels {
                        Text("会用到加密值 \(labels)（AI 看不到真值）").font(.caption).foregroundStyle(CodeBlockStyle.label)
                    }
                    DisclosureGroup(isExpanded: $showFull) {
                        ScrollView {
                            Text(preview.prettyJSON).font(.caption2.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 180)
                    } label: {
                        Text("完整参数").font(.caption).foregroundStyle(CodeBlockStyle.label)
                    }
                    buttons(approval, preview: preview)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    if stamped {
                        ApprovalSeal(text: "已准", date: Date(), color: Theme.branchIndicator)
                            .frame(width: 84, height: 54)
                            .rotationEffect(.degrees(-12))
                            .transition(.scale(scale: 1.6).combined(with: .opacity))
                    }
                }
            }
            .onAppear { center.markPresentedInline(request.id) }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func commandBlock(_ command: String) -> some View {
        if editing {
            TextEditor(text: $draft)
                .font(.callout.monospaced())
                .frame(minHeight: 60, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .fieldBox()
                .accessibilityLabel("改命令")
        } else {
            ScrollView {
                Text("$ " + command)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .fieldBox()
        }
    }

    @ViewBuilder
    private func buttons(_ approval: PermissionPromptCenter.Approval, preview: ApprovalPreview) -> some View {
        HStack(spacing: 14) {
            button("拒绝", role: .destructive) { center.respond(to: request.id, decision: .deniedOnce) }
            Spacer(minLength: 0)
            if preview.canEditCommand, request.secretLabels == nil {
                if editing {
                    button("用改过的允许", prominent: true) { allowEdited(approval, preview: preview) }
                } else {
                    button("修改") { draft = preview.command ?? ""; editing = true }
                }
            }
            if !editing {
                button("允许这一次", prominent: !approval.conversationGrant) { stampThen(.allowedOnce) }
                if approval.conversationGrant {
                    button("本对话都允许", prominent: true) { stampThen(.allowed) }
                }
            }
        }
        .font(.subheadline)
    }

    private func allowEdited(_ approval: PermissionPromptCenter.Approval, preview: ApprovalPreview) {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        if command == preview.command { stampThen(.allowedOnce); return }
        guard let json = ApprovalPreview.replacingCommand(in: approval.argumentsJSON, with: command) else { return }
        stampThen(.modified(json))
    }

    /// 盖一下章再放行（0.45 秒，减弱动态效果时直接放行）
    private func stampThen(_ decision: PermissionPromptCenter.Decision) {
        let id = request.id
        guard !reduceMotion else { PermissionPromptCenter.shared.respond(to: id, decision: decision); return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { stamped = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            PermissionPromptCenter.shared.respond(to: id, decision: decision)
        }
    }

    private func button(_ title: String, role: ButtonRole? = nil, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .fontWeight(prominent ? .semibold : .regular)
                .foregroundStyle(role == .destructive ? Color.red.opacity(0.85) : (prominent ? Theme.branchIndicator : CodeBlockStyle.label))
        }
        .buttonStyle(.plain)
        .disabled(stamped)
    }
}
