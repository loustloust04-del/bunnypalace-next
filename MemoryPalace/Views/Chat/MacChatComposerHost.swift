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
        let editingSession = draft.sessionID
        let selectedAttachments = Binding(
            get: { viewModel.selectedAttachments },
            set: { draft.editAttachments($0, session: editingSession, viewModel: viewModel, context: context) }
        )
        Group {
            if viewModel.messageSelection.isActive {
                // 多选气泡：输入条换成选择条（草稿在 draft，换装不丢）
                MacChatSelectionBar(viewModel: viewModel)
            } else if stickerVM.showStickerPanel || stickerVM.isEditingStickers {
                StickerKeyboardPanel(stickerVM: stickerVM, viewModel: viewModel, onDismiss: dismissStickers,
                    onStickerTap: { withAnimation { stickerVM.showStickerPanel.toggle() } },
                    selectedAttachments: selectedAttachments)
            } else if let providerManager {
                ChatInputBar(viewModel: viewModel, modelContext: context, profileManager: profileManager,
                    providerManager: providerManager, presetManager: presetManager,
                    selectedAttachments: selectedAttachments,
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
        #if DEBUG || PERF_BENCH
        .background { if PerfHarnessMac.enabled { MacPerfAnchor(key: "composer") } }
        .onAppear {
            guard PerfHarnessMac.enabled else { return }
            PerfHarnessMacDriver.sendStream = { conversationID, presetID in
                guard viewModel.selectedConversation?.id == conversationID,
                      let profile = profileManager?.currentProfile,
                      let preset = presetManager?.preset(byId: presetID),
                      let providerManager else {
                    throw PerfHarnessMacDriver.Failure.invalid("M6 actual send dependencies missing")
                }
                let model = ProviderModel(credentialId: PerfHarnessMacStream.credentialID,
                    modelId: PerfHarnessMacStream.modelID, name: "Synthetic 30 chars/s")
                guard viewModel.sendMessage("mac synthetic stream fixture", model: model,
                    profile: profile, preset: preset, providerManager: providerManager, context: context) else {
                    throw PerfHarnessMacDriver.Failure.invalid("M6 real sendMessage rejected")
                }
            }
        }
        #endif
        .onChange(of: viewModel.selectedConversation?.id, initial: true) { _, _ in
            draft.switchConversation(to: viewModel.selectedConversation,
                temporary: viewModel.isDraftConversation, viewModel: viewModel, context: context)
        }
        // 报错「去改」要开模型选择器：贴纸面板占着输入条的位置 → 先收起，输入条回来后自己接手请求
        .onChange(of: viewModel.modelPickerRequested) { _, requested in
            if requested, stickerVM.showStickerPanel {
                withAnimation(.easeInOut(duration: 0.25)) { stickerVM.showStickerPanel = false }
            }
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
    @ObservationIgnored private var persistence = InputBarDraftPersistence()

    func edit(_ value: String, session: UUID, context: ModelContext, persist: Bool = true) {
        guard session == sessionID else { return }
        text = value
        guard persist, let owner, !temporary, !owner.isTrashed else { return }
        persistence.persistText(value, to: owner, context: context)
    }

    func editAttachments(_ value: [PendingChatAttachment], session: UUID,
                         viewModel: ConversationViewModel, context: ModelContext) {
        guard session == sessionID else { return }
        viewModel.selectedAttachments = value
        guard viewModel.editingMessage == nil, let owner, !temporary, !owner.isTrashed else { return }
        persistence.persistAttachments(value, to: owner, context: context)
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
        persistence.load(text: text, attachments: viewModel.selectedAttachments,
                         quotePreview: viewModel.quotingPreview, quoteReplyTo: viewModel.quotingReplyTo)
    }

    func flush(viewModel: ConversationViewModel, context: ModelContext) {
        guard let owner, !temporary, !owner.isTrashed else { return }
        // 编辑旧消息中：落盘的是进入前收起的那份
        if let stash = viewModel.editingMessage?.stash {
            persistence.flush(to: owner, text: stash.text, attachments: stash.attachments,
                              quotePreview: stash.quotePreview, quoteReplyTo: stash.quoteReplyTo, context: context)
            return
        }
        persistence.flush(to: owner, text: text, attachments: viewModel.selectedAttachments,
                          quotePreview: viewModel.quotingPreview, quoteReplyTo: viewModel.quotingReplyTo,
                          context: context)
    }

    func reset() {
        owner = nil; temporary = true; sessionID = UUID(); text = ""
        persistence = InputBarDraftPersistence()
    }
}
#endif
