import SwiftData
import SwiftUI

/// 表情包点即发：一条正文只有 `[meme:UUID]` 的消息；输入框里正在写的字 / 附件不动
private struct MemeSendModifier: ViewModifier {
    let viewModel: ConversationViewModel
    let stickerVM: StickerViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @AppStorage("selectedChatModel") private var selectedModelId = ""

    func body(content: Content) -> some View {
        content.onChange(of: stickerVM.pendingMemeSend) { _, id in
            guard let id else { return }
            stickerVM.pendingMemeSend = nil
            send(id)
        }
    }

    private func send(_ id: UUID) {
        guard viewModel.selectedConversation != nil, let providerManager,
              let meme = MemeStore.fetch(id, in: modelContext) else { return }
        let prof = profileManager?.currentProfile ?? Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
        let preset = presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
        let model = providerManager.resolveModel(conversationModelId: viewModel.selectedConversation?.selectedModelId,
                                                 profileModelId: prof.preferredModel, globalFallbackId: selectedModelId)
        guard viewModel.preCheckBudget(text: MemeToken.promptText(name: meme.name, detail: meme.detail),
                                       model: model, profile: prof, preset: preset, providerManager: providerManager) else { return }
        viewModel.selectedConversation?.selectedModelId = model.id
        if viewModel.sendMessage(MemeToken.make(id), model: model, profile: prof, preset: preset,
                                 providerManager: providerManager, context: modelContext) {
            meme.lastSentAt = Date()
            try? modelContext.save()
        }
    }
}

extension View {
    func memeSending(viewModel: ConversationViewModel, stickerVM: StickerViewModel) -> some View {
        modifier(MemeSendModifier(viewModel: viewModel, stickerVM: stickerVM))
    }
}
