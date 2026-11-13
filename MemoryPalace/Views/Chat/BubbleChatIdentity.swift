#if os(iOS)
import SwiftUI
import SwiftData

struct BubbleChatIdentity<Avatar: View>: View {
    let name: String
    let viewModel: ConversationViewModel
    let conversationId: String
    let profileId: String
    let onProfile: () -> Void
    /// 资料页 zoom 转场的源（10-29 b：从头像放大成全屏，下拖缩回头像）
    var zoomNamespace: Namespace.ID? = nil
    /// 对话所属那台 hub（阶段卡按它读）
    var hubId: String = CCBridgeWebSocketClient.primaryHubId
    @ViewBuilder let avatar: Avatar
    @State private var details: BubbleTurnDetails?

    static var profileZoomID: String { "bubble-ai-profile-avatar" }

    var body: some View {
        let status = headerStatus
        VStack(spacing: -5) {
            Button(action: onProfile) { zoomSource(avatar) }
                .accessibilityLabel("查看\(name)资料")
                .zIndex(1)
            VStack(spacing: 3) {
                Button(action: onProfile) {
                    HStack(spacing: 5) {
                        Text(name).lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.chat.textMuted)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.chat.textPrimary)
                }
                if let status {
                    Button(action: showDetails) {
                        if status.text.isEmpty {
                            // 没工具、AI 也没写状态：轮换搞笑文案（10-29 从底部等待泡挪上来）
                            HStack(spacing: 5) {
                                Image(systemName: status.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.chat.textSecondary)
                                RotatingShimmerLabel()
                                    .lineLimit(1)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("正在思考")
                        } else {
                            Label(status.text, systemImage: status.icon)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.chat.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("bubble-turn-status")
                    .accessibilityHint("查看本轮思考和工具过程")
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, status == nil ? 6 : 8)
            .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule)
            .frame(maxWidth: status == nil ? 170 : 260)
        }
        .buttonStyle(.plain)
        .sheet(item: $details) { BubbleTurnSheet(viewModel: viewModel, details: $0) }
        .onChange(of: conversationId) { _, _ in details = nil }
        .onChange(of: profileId) { _, _ in details = nil }
    }

    @ViewBuilder
    private func zoomSource(_ content: Avatar) -> some View {
        if let zoomNamespace {
            content.matchedTransitionSource(id: Self.profileZoomID, in: zoomNamespace) { $0.clipShape(RoundedRectangle(cornerRadius: 30)) }   // 头像 60pt：半径 30 = 圆
        } else {
            content
        }
    }

    /// text 为空 = 显示轮换文案。优先级（10-29）：等待批准 > 问问题 > 工具名 > AI 自己写的状态 > 轮换文案
    private var headerStatus: (text: String, icon: String)? {
        if viewModel.assistantTurnInFlight, viewModel.activeConversationId == conversationId {
            let activity = viewModel.turnActivity(for: conversationId)
            let action = activity?.pendingAction ?? activity?.running?.action
            let text: String
            let icon: String
            if let request = PermissionPromptCenter.shared.pendingRequest,
               request.approval?.conversationId == conversationId {
                text = "等待批准 · \(action ?? request.domain.displayName)"
                icon = "hand.raised"
            } else if viewModel.pendingUserQuestion?.conversationId == conversationId {
                text = "问问题 · 等你回答"
                icon = "questionmark.circle"
            } else if let action {
                text = action
                icon = activity?.pendingTool?.symbol ?? activity?.running?.detail.symbol ?? "wrench.and.screwdriver"
            } else if !viewModel.streamingHasText {
                return (viewModel.turnStatus(for: conversationId) ?? "", "ellipsis")
            } else {
                return nil
            }
            return (text + (viewModel.turnStatus(for: conversationId).map { " · \($0)" } ?? ""), icon)
        }
        if let phase = CCSessionPhaseStore.shared.phase(for: conversationId, hubId: hubId) {
            switch phase.phase {
            case .working:
                return (phase.tool.map(CCSessionPhase.toolName) ?? "", phase.tool == nil ? "ellipsis" : "wrench.and.screwdriver")
            case .waiting:
                return ("等待回答", "questionmark.circle")
            case .idle, .done:
                break
            }
        }
        return viewModel.ccWaitingSince[conversationId] == nil ? nil : ("", "ellipsis")
    }

    private func showDetails() {
        var node = viewModel.currentTurnNode(for: conversationId)
        let phase = node == nil ? CCSessionPhaseStore.shared.phase(for: conversationId, hubId: hubId) : nil
        if node == nil, let since = viewModel.ccWaitingSince[conversationId] ?? phase?.since,
           let last = viewModel.currentPath.last, last.role == "assistant", (last.createTime ?? .distantPast) >= since {
            node = last
        }
        details = BubbleTurnDetails(conversationId: conversationId, profileId: profileId,
                                    turnID: viewModel.activeConversationId == conversationId ? viewModel.currentTurnID : nil,
                                    content: .init(node: node), bridgePhase: phase)
    }
}

struct BubbleTurnDetails: Identifiable {
    let id = UUID()
    let conversationId: String
    let profileId: String
    let turnID: Int?
    let content: Content
    let bridgePhase: CCSessionPhase?

    struct Content {
        let nodeId: String?
        let segments: [MessageSegment]
        let thought: String?

        init(node: MessageNode?) {
            nodeId = node?.id
            segments = node.flatMap { ChatDisplaySnapshot.segments(of: $0) } ?? []
            thought = segments.nativeThinkingText ?? node?.ccThinking
        }
    }
}

struct BubbleTurnSheet: View {
    let viewModel: ConversationViewModel
    let details: BubbleTurnDetails
    @Environment(\.modelContext) private var context
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("fontScale") private var fontScale = 1.2
    @AppStorage(DisclosureKind.tool.key) private var toolMode = DisclosureKind.tool.migratedDefault.rawValue
    @State private var finishedContent: BubbleTurnDetails.Content?
    @State private var finishedActivity: TurnActivity?
    @State private var finishedLiveThought: String?

    private var isCurrentTurn: Bool {
        details.turnID != nil && viewModel.currentTurnID == details.turnID
            && viewModel.activeConversationId == details.conversationId
    }

    var body: some View {
        let content = isCurrentTurn
            ? BubbleTurnDetails.Content(node: viewModel.currentTurnNode(for: details.conversationId))
            : finishedContent ?? details.content
        let activity = isCurrentTurn ? viewModel.turnActivity(for: details.conversationId) : finishedActivity
        let storedThought = activity.flatMap { $0.thoughts.isEmpty ? nil : $0.thoughts.joined(separator: "\n\n") } ?? content.thought
        let liveThought = isCurrentTurn ? viewModel.providerRouter.lastThinkingSegments.nativeThinkingText : finishedLiveThought
        let toolSegments = content.segments.filter {
            switch $0 { case .toolUse, .toolResult: true; default: false }
        }
        DisclosureSheet(title: "本轮过程", detent: .large, scope: .chat) {
            VStack(alignment: .leading, spacing: 16) {
                if isCurrentTurn {
                    TurnActivityHost(viewModel: viewModel, conversationId: details.conversationId, spacingBefore: 0) {
                        guard isCurrentTurn else { return }
                        viewModel.cancelAssistantTurn(context: context)
                    }
                }
                if let phase = details.bridgePhase {
                    Text("打开时的桥接状态").font(.caption).foregroundStyle(Theme.chat.textMuted)
                    Text(phase.headline(now: phase.updated)).font(.subheadline)
                }
                if let storedThought, !storedThought.isEmpty { thought(storedThought, nodeId: content.nodeId) }
                if let liveThought, storedThought?.hasSuffix(liveThought) != true { thought(liveThought, nodeId: content.nodeId) }
                if storedThought == nil, liveThought == nil {
                    Text("本轮尚未返回可显示的思考内容。")
                        .font(.subheadline).foregroundStyle(Theme.chat.textMuted)
                }
                if let activity {
                    ForEach(activity.steps, id: \.id) { step in
                        tool(step.detail, action: step.action, finished: !isCurrentTurn)
                    }
                    if let pending = activity.pendingTool, !activity.steps.contains(where: { $0.id == pending.id }) {
                        tool(pending, action: activity.pendingAction ?? pending.name, finished: !isCurrentTurn)
                    }
                } else if !toolSegments.isEmpty {
                    if DisclosureMode(rawValue: toolMode) == .hidden {
                        Text("工具调用已在消息显示设置中隐藏。")
                            .font(.subheadline).foregroundStyle(Theme.chat.textMuted)
                    } else {
                        MessageSegmentsView(segments: toolSegments, selectedFont: selectedFont, fontScale: fontScale,
                                            lineSpacingScale: 1.45, paragraphSpacingScale: 1.65, regexScripts: [],
                                            profileId: details.profileId, nodeId: content.nodeId)
                    }
                } else {
                    Text(details.bridgePhase == nil ? "本轮还没有工具记录。" : "桥接目前只提供阶段信息，尚未收到本轮详细工具记录。")
                        .font(.subheadline).foregroundStyle(Theme.chat.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("bubble-turn-sheet")
        .onReceive(NotificationCenter.default.publisher(for: .assistantTurnDidFinish)) { notification in
            guard isCurrentTurn, notification.userInfo?["conversationId"] as? String == details.conversationId else { return }
            finishedContent = .init(node: viewModel.currentTurnNode(for: details.conversationId))
            finishedActivity = viewModel.turnActivity(for: details.conversationId)
            finishedLiveThought = viewModel.providerRouter.lastThinkingSegments.nativeThinkingText
        }
    }

    private func thought(_ text: String, nodeId: String?) -> some View {
        ChatMarkdownView(text: text, fontName: selectedFont,
                         nodeId: nodeId.map { "thinking:\($0)" }, profileId: details.profileId, role: .chatPlain)
    }

    private func tool(_ step: ChatToolStep, action: String, finished: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(action) · \(finished && step.result == nil ? "已结束，未返回结果" : step.status)", systemImage: step.symbol)
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.chat.textPrimary)
            ToolCallCardView(name: step.name, inputJSON: step.inputJSON, resultText: step.result,
                             isError: step.isError, integration: step.integration, icon: step.icon,
                             profileId: details.profileId, forceDetail: true)
        }
    }
}
#endif
