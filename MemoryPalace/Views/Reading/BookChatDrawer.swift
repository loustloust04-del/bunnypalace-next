import SwiftUI
import SwiftData

/// 阅读 sheet 底部抽屉 — 显示这本书相关的最近对话（user 提问 + 小克回复）。
/// 不重新做对话引擎，只读 ConversationViewModel.currentPath 里带 bookRef 的消息。
///
/// 行为（学 page1 ModelPickerPopover：`.sheet + presentationDetents + dragIndicator`）：
/// - 默认 medium，可上拉到 large
/// - "问小克"成功后自动弹一次，关掉后下次按底部按钮再开
/// - 流式回复自然反应式更新（@Bindable viewModel）
///
/// MVP：只读视图，继续追问要关 sheet 去主对话。v2 可在抽屉里直接发。
struct BookChatDrawer: View {
    let bookSafeName: String
    let bookDisplayName: String
    /// 当前阅读章节（继续追问时盖 bookRef 用）
    let currentChapter: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @Bindable var viewModel: ConversationViewModel

    /// M3.5：从阅读页点击 AI 划线段触发时传入，抽屉打开后 scroll + 短暂高亮对应消息。
    var highlightMessageId: String? = nil

    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    /// 这本书相关的消息：currentPath 里 bookRef 以 `<safeName>#` 开头的，按 createTime 排序。
    private var bookMessages: [MessageNode] {
        let prefix = "\(bookSafeName)#"
        // user 节点带 bookRef；assistant 是该 user 的 reply（沿 parentId 链），bookRef 一般无
        // 改用「找到所有带 bookRef 的 user 节点 + 它们 currentPath 下游的 assistant」收集
        let userNodes = viewModel.currentPath.filter { $0.bookRef?.hasPrefix(prefix) == true }
        var result: [MessageNode] = []
        for u in userNodes {
            result.append(u)
            // 在 currentPath 找 u 的下一个 assistant（path 已扁平有序）
            if let idx = viewModel.currentPath.firstIndex(where: { $0.id == u.id }),
               idx + 1 < viewModel.currentPath.count {
                let next = viewModel.currentPath[idx + 1]
                if next.role == "assistant" { result.append(next) }
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if bookMessages.isEmpty {
                        emptyState
                    } else {
                        messageList
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                inputCard
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(bookDisplayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("收起") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 540)
        #endif
    }

    // MARK: - 输入卡片（自画，不用玻璃）

    private var inputCard: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 多行 TextField，圆角卡片包起来
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("继续问\(assistantName)这本书…")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextField("", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.F.body))
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .focused($inputFocused)
                    .onSubmit { send() }
            }
            .background(Theme.mainBg)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Theme.accent, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))

            // 发送按钮（自画圆形 mint 底）
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Theme.branchIndicator : Theme.textMuted.opacity(0.3))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.sidebarBg)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let prof = profileManager?.currentProfile,
              let pm = providerManager,
              let psm = presetManager else { return }

        if viewModel.selectedConversation == nil {
            viewModel.startDraftConversation(profileId: prof.id)
        }

        let model = pm.resolveModel(
            conversationModelId: viewModel.selectedConversation?.selectedModelId,
            globalFallbackId: nil
        )
        let preset = psm.preset(byId: prof.presetId) ?? .balanced
        let bookRef = "\(bookSafeName)#chapter\(currentChapter)"

        let sent = viewModel.sendMessage(
            text,
            model: model,
            profile: prof,
            preset: preset,
            providerManager: pm,
            context: modelContext
        )
        if sent {
            // 给刚发的 user node 盖 bookRef（跟 askXiaoke 同套路径）
            if let lastUser = viewModel.currentPath.last(where: { $0.role == "user" }) {
                lastUser.bookRef = bookRef
                try? lastUser.modelContext?.save()
            }
            inputText = ""
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundColor(Theme.textMuted.opacity(0.5))
            Text("还没问过\(assistantName)")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textSecondary)
            Text("选段后点「问\(assistantName)」试试")
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var transientHighlight: String? = nil   // 短暂高亮 ring，1.5s 后消失

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(bookMessages, id: \.id) { node in
                        messageBubble(node)
                            .id(node.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onAppear {
                if let target = highlightMessageId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(target, anchor: .center)
                            transientHighlight = target
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut(duration: 0.5)) { transientHighlight = nil }
                        }
                    }
                }
            }
        }
    }

    private func messageBubble(_ node: MessageNode) -> some View {
        let isUser = node.role == "user"
        let isHighlighted = transientHighlight == node.id
        return HStack(alignment: .top) {
            if isUser { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? userName : assistantName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isUser ? Theme.branchIndicator : Theme.textMuted)
                Text(node.content.isEmpty ? "（\(assistantName)正在回答…）" : node.content)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(isUser ? Theme.accent : Theme.mainBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.branchIndicator, lineWidth: isHighlighted ? 2 : 0)
            )
            if !isUser { Spacer(minLength: 30) }
        }
    }
}
