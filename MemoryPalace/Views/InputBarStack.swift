#if os(iOS)
import SwiftUI
import SwiftData

/// B2（plan-keyboard-layoutguide）：输入条栈独立容器——inputBarHost（UIKit 层
/// UIHostingController，底边约束 keyboardLayoutGuide）的 rootView。
///
/// 从 CardFlowView.iOSBottomInset 整体搬迁：三分支（贴纸面板垫高/编辑模式垫高/输入条）
/// + 草稿全套（B41 每键直写实时同步）。环境注入两层链与 chat page 相同
/// （ContentView.injectPagingEnv 四件套 + PagingContainerView.injectChatManagers 三 manager），
/// ⚠️ 缺一个 manager 输入条静默不渲染——DEBUG 空环境断言探针在 body 兜底。
struct InputBarStack: View {
    var stickerVM: StickerViewModel

    @Environment(ConversationViewModel.self) private var viewModelEnv: ConversationViewModel?
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @ObservedObject private var keyboardBridge = KeyboardInsetBridge.shared
    @State private var draftText: String = ""
    /// 已加载草稿的对话（同 CardFlowView 老语义：防同对话重载空草稿冲掉正在打的字）
    @State private var loadedConvId: String? = nil

    var body: some View {
        Group {
            if !keyboardBridge.chatInputSuppressed,
               let viewModel = viewModelEnv, viewModel.selectedConversation != nil {
                content(viewModel: viewModel)
            }
        }
        // C-slide（research-input-newline-carrier）：carrier 定高（=chat 页高，PagingVC 装配），
        // sizingOptions=[] 后 proposal=bounds，这个 frame 真正填满 carrier、内容钉底——换行是纯
        // SwiftUI 内部重排，底边由构造固定。可见栈实高自报给 bridge（containerTop/growth/hitTest 的真相源），
        // 变化踢一次 publish（kick sink 只剩发布职责）。
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
            // ⚠️ 必须挂在 .frame **之前**：量的是内容（可见栈）实高；挂后面量到的是整个 carrier
            let b = KeyboardInsetBridge.shared
            guard abs(b.barVisibleHeight - h) > 0.5 else { return }
            b.barVisibleHeight = h
            b.barKick.send()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // 占位态告诉 carrier 整块放行（astra R6 C1）。挂在输入条自己身上：它随贴纸状态重算，不靠流式中被跳过的 rootView 刷新
        .onChange(of: InputBarHitRule.isPlaceholder(searchActive: viewModelEnv?.inConvSearchActive ?? false,
                                                     stickerPanel: stickerVM.showStickerPanel,
                                                     editingStickers: stickerVM.isEditingStickers), initial: true) { _, placeholder in
            KeyboardInsetBridge.shared.barIsPlaceholder = placeholder
        }
        .onAppear {
            #if DEBUG
            // 空环境断言探针（injectPagingEnv 教训：child HC 缺注入 = 静默白屏，这里叫出来）
            if viewModelEnv == nil { PROBE("[INPUTBAR] ⚠️ viewModel env 缺失") }
            if providerManager == nil { PROBE("[INPUTBAR] ⚠️ ProviderManager env 缺失") }
            if profileManager == nil { PROBE("[INPUTBAR] ⚠️ ProfileManager env 缺失") }
            if presetManager == nil { PROBE("[INPUTBAR] ⚠️ PresetManager env 缺失") }
            #endif
        }
    }

    @ViewBuilder
    private func content(viewModel: ConversationViewModel) -> some View {
        Group {
            if viewModel.inConvSearchActive {
                // 对话内查找：输入栏整体换成 40pt 面板（plan-chat-find 方案 3）；进入前已定稿组字
                ChatFindPanel(viewModel: viewModel)
                    .transition(.opacity)
            } else if viewModel.messageSelection.isActive {
                // 多选气泡：输入栏整体换成操作栏（同查找面板；草稿在本层 @State，换装不丢）
                ChatSelectActionBar(viewModel: viewModel)
                    .transition(.opacity)
            } else if stickerVM.showStickerPanel {
                Color.clear.frame(height: 320)
            } else if stickerVM.isEditingStickers {
                Color.clear.frame(height: 60)
            } else if let pm = providerManager {
                @Bindable var vmB = viewModel
                VStack(spacing: 0) {
                    ChatInputBar(
                        viewModel: viewModel, modelContext: modelContext,
                        profileManager: profileManager, providerManager: pm, presetManager: presetManager,
                        // 附件同源：vm.selectedAttachments（贴纸面板/macOS 输入条同一份）
                        selectedAttachments: $vmB.selectedAttachments,
                        draftText: $draftText,
                        onStickerTap: {
                            KBProbe.log("sticker → resign")
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            withAnimation(.easeInOut(duration: 0.25)) {
                                stickerVM.showStickerPanel = false
                                stickerVM.isEditingStickers = true
                            }
                        }
                    )
                    .equatable()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // ── 草稿全套（B41：每键直写 + 显式 save；切换/后台 flush 兜底）——从 CardFlowView 原样搬迁
        // input-jank C2：`draftText` 现在只在**提交点**变（coordinator 判定），这条自然成了
        // 「去抖落盘」。kick 从这里拿掉（kimi J3）：高度变化已由 ChatInputBar 的
        // onGeometryChange(height) → kickBarLayout() 覆盖，每个提交点再踢一次是重复发送。
        // ⚠️ 键盘管线接收端零改动，这里只是少发。
        .onChange(of: draftText) { _, newText in
            #if DEBUG
            let saveT0 = CACurrentMediaTime()
            #endif
            guard let conv = viewModel.selectedConversation, conv.id == loadedConvId,
                  !conv.isTrashed, !viewModel.isDraftConversation else { return }
            // 编辑旧消息中：框里是编辑文字不是草稿，盘上保留进入前那份（plan-edit-in-composer §5）
            guard viewModel.editingMessage == nil else { return }
            conv.draftText = newText
            #if DEBUG
            let saveT1 = CACurrentMediaTime()
            #endif
            try? modelContext.save()
            #if DEBUG
            // input-jank F2 探针：每键落盘到底几毫秒（真机日志判 F2 值不值得做）
            KBProbe.log(String(format: "[SAVE] draft assign=%.1fms save=%.1fms len=%d", (saveT1 - saveT0) * 1000, (CACurrentMediaTime() - saveT1) * 1000, newText.count))
            #endif
        }
        .onChange(of: viewModel.selectedConversation?.id) { _, _ in
            // 提交点 8（kimi B1）：flush 读的是 binding，切对话前先把 UITextView 的尾巴记下来。
            // codex A2：组字期间 commitNow 会被 marked 冻住 → 先 unmarkText 把候选拼音定稿
            // 成文本再提交，旧会话的组字内容和新会话的草稿才各有 owner，两边都不丢。
            ChatInputHandle.shared.finalizeCompositionAndCommit()
            flushDraft(to: loadedConversation(), viewModel: viewModel)
            // 切对话 = 取消编辑（草稿已按 stash 落盘，新对话照常装载）
            viewModel.editingMessage = nil
            // 会话身份先换：loadDraft 的外部写若又被 marked 挡住，那条待重试要记成新会话的
            ChatInputHandle.shared.sessionKey = viewModel.selectedConversation?.id
            loadDraft(from: viewModel.selectedConversation, viewModel: viewModel)
            loadedConvId = viewModel.selectedConversation?.id
        }
        .onAppear {
            if loadedConvId != viewModel.selectedConversation?.id {
                ChatInputHandle.shared.sessionKey = viewModel.selectedConversation?.id
                loadDraft(from: viewModel.selectedConversation, viewModel: viewModel)
                loadedConvId = viewModel.selectedConversation?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // 提交点 8（kimi B1）+ codex A2：后台 flush 同理，先定稿组字再提交
            ChatInputHandle.shared.finalizeCompositionAndCommit()
            flushDraft(to: loadedConversation(), viewModel: viewModel)
        }
    }

    /// loadedConvId → 模型对象（flush 目标；对象已换库时返回 nil 安全跳过）
    private func loadedConversation() -> Conversation? {
        guard let id = loadedConvId else { return nil }
        var d = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    private func flushDraft(to conv: Conversation?, viewModel: ConversationViewModel) {
        guard let conv, !conv.isTrashed else { return }
        if viewModel.isDraftConversation { return }
        // 编辑旧消息中：落盘的是进入前收起的那份，不是框里的编辑文字
        if let stash = viewModel.editingMessage?.stash {
            conv.draftText = stash.text
            conv.draftAttachmentsData = stash.attachments.isEmpty ? nil : (try? JSONEncoder().encode(stash.attachments))
            conv.draftQuotePreview = stash.quotePreview ?? ""
            conv.draftQuoteReplyTo = stash.quoteReplyTo ?? ""
            try? modelContext.save()
            return
        }
        // C2：真相在 UITextView（binding 是「提交后文本」）。调用方已 commitNow，这里再直读
        // liveText 一次，不依赖「@State 写完同一轮读得到新值」
        conv.draftText = ChatInputHandle.shared.liveText ?? draftText
        conv.draftAttachmentsData = viewModel.selectedAttachments.isEmpty
            ? nil
            : (try? JSONEncoder().encode(viewModel.selectedAttachments))
        conv.draftQuotePreview = viewModel.quotingPreview ?? ""
        conv.draftQuoteReplyTo = viewModel.quotingReplyTo ?? ""
        try? modelContext.save()
    }

    private func loadDraft(from conv: Conversation?, viewModel: ConversationViewModel) {
        draftText = conv?.draftText ?? ""
        // 命令通道（plan-input-command-channel）：草稿装载显式落 tv（binding 只作镜像）。
        // 组字中会挂起，解除后按 session 校验重放/丢弃——旧会话组字不污染新会话。
        ChatInputHandle.shared.issueText(draftText, session: conv?.id)
        if let data = conv?.draftAttachmentsData,
           let atts = try? JSONDecoder().decode([PendingChatAttachment].self, from: data) {
            viewModel.selectedAttachments = atts
        } else {
            viewModel.selectedAttachments = []
        }
        viewModel.quotingPreview = (conv?.draftQuotePreview.isEmpty ?? true) ? nil : conv?.draftQuotePreview
        viewModel.quotingReplyTo = (conv?.draftQuoteReplyTo.isEmpty ?? true) ? nil : conv?.draftQuoteReplyTo
    }
}
#endif
