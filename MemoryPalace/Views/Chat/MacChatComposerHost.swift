#if os(macOS)
import SwiftUI
import SwiftData
import AppKit

/// A sibling of the transcript, not a child of its loading branch. Keystrokes
/// invalidate the composer only; switching messages/loading cannot destroy its draft.
struct MacChatComposerHost: View {
    let viewModel: ConversationViewModel
    let stickerVM: StickerViewModel
    @Environment(\.modelContext) private var context
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @State private var draft = MacComposerDraft()

    var body: some View {
        @Bindable var vm = viewModel
        let editingSession = draft.sessionID
        Group {
            if viewModel.messageSelection.isActive {
                // 多选气泡：输入条换成选择条（草稿在 draft，换装不丢）
                MacChatSelectionBar(viewModel: viewModel)
            } else if stickerVM.showStickerPanel || stickerVM.isEditingStickers {
                StickerKeyboardPanel(stickerVM: stickerVM, viewModel: viewModel, onDismiss: dismissStickers,
                    onStickerTap: { withAnimation { stickerVM.showStickerPanel.toggle() } },
                    selectedAttachments: $vm.selectedAttachments)
            } else if let providerManager {
                ChatInputBar(viewModel: viewModel, modelContext: context, profileManager: profileManager,
                    providerManager: providerManager, presetManager: presetManager,
                    selectedAttachments: $vm.selectedAttachments,
                    // 编辑旧消息中框里是编辑文字，不落盘（plan-edit-in-composer §5）
                    draftText: Binding(get: { draft.text }, set: {
                        draft.edit($0, session: editingSession, context: context, persist: viewModel.editingMessage == nil)
                    }),
                    onStickerTap: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            stickerVM.showStickerPanel = false
                            stickerVM.isEditingStickers = true
                        }
                    })
                    .equatable()
                    .id(editingSession)
                    .disabled(viewModel.isLoading)
            }
        }
        .onChange(of: viewModel.selectedConversation?.id, initial: true) { _, _ in
            draft.switchConversation(to: viewModel.selectedConversation,
                temporary: viewModel.isDraftConversation, viewModel: viewModel, context: context)
        }
        .onChange(of: viewModel.isDraftConversation) { _, temporary in
            draft.updateTemporary(temporary, conversationId: viewModel.selectedConversation?.id)
        }
        .onDisappear { draft.flush(viewModel: viewModel, context: context) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            draft.flush(viewModel: viewModel, context: context)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            draft.flush(viewModel: viewModel, context: context)
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            // Text edits are saved immediately. Drop model references before the old context is released.
            draft.reset()
        }
    }

    private func dismissStickers() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if stickerVM.showStickerPanel {
                stickerVM.showStickerPanel = false
            } else {
                stickerVM.isEditingStickers = false
                stickerVM.selectedPlacedStickerId = nil
            }
        }
    }
}

/// Draft ownership follows the conversation that loaded it, never the newly
/// selected conversation. The existing immediate-save durability contract stays intact.
@Observable
@MainActor
final class MacComposerDraft {
    private(set) var text = ""
    private(set) var sessionID = UUID()
    @ObservationIgnored private var owner: Conversation?
    @ObservationIgnored private var temporary = true

    func edit(_ value: String, session: UUID, context: ModelContext, persist: Bool = true) {
        guard session == sessionID else { return }
        text = value
        guard persist, let owner, !temporary, !owner.isTrashed else { return }
        owner.draftText = value
        try? context.save()
    }

    func updateTemporary(_ value: Bool, conversationId: String?) {
        guard owner?.id == conversationId else { return }
        temporary = value
    }

    func switchConversation(to conversation: Conversation?, temporary: Bool,
                            viewModel: ConversationViewModel, context: ModelContext) {
        guard owner?.id != conversation?.id || owner?.profileId != conversation?.profileId else { return }
        flush(viewModel: viewModel, context: context)
        viewModel.editingMessage = nil   // 切对话 = 取消编辑
        owner = conversation
        sessionID = UUID()
        self.temporary = temporary
        text = conversation?.draftText ?? ""
        if let data = conversation?.draftAttachmentsData,
           let attachments = try? JSONDecoder().decode([PendingChatAttachment].self, from: data) {
            viewModel.selectedAttachments = attachments
        } else {
            viewModel.selectedAttachments = []
        }
        viewModel.quotingPreview = (conversation?.draftQuotePreview.isEmpty ?? true) ? nil : conversation?.draftQuotePreview
        viewModel.quotingReplyTo = (conversation?.draftQuoteReplyTo.isEmpty ?? true) ? nil : conversation?.draftQuoteReplyTo
    }

    func flush(viewModel: ConversationViewModel, context: ModelContext) {
        guard let owner, !temporary, !owner.isTrashed else { return }
        // 编辑旧消息中：落盘的是进入前收起的那份
        if let stash = viewModel.editingMessage?.stash {
            owner.draftText = stash.text
            owner.draftAttachmentsData = stash.attachments.isEmpty ? nil : try? JSONEncoder().encode(stash.attachments)
            owner.draftQuotePreview = stash.quotePreview ?? ""
            owner.draftQuoteReplyTo = stash.quoteReplyTo ?? ""
            try? context.save()
            return
        }
        owner.draftText = text
        owner.draftAttachmentsData = viewModel.selectedAttachments.isEmpty
            ? nil : try? JSONEncoder().encode(viewModel.selectedAttachments)
        owner.draftQuotePreview = viewModel.quotingPreview ?? ""
        owner.draftQuoteReplyTo = viewModel.quotingReplyTo ?? ""
        try? context.save()
    }

    func reset() { owner = nil; temporary = true; sessionID = UUID(); text = "" }
}
#endif
