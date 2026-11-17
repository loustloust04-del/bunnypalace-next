import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

// 聊天页的对话菜单（11-16 合一，plan-chat-menus）：清单跟列表长按同一份 `ConversationMenu`。
// iOS 窄屏右上 ⋯ 弹 page1 同款自绘浮层（`ChatConversationMenuButton`）；Mac 标题栏 / iOS 宽屏悬浮条是系统 Menu（`ChatConversationMenuItems`）。
// 菜单收起后弹窗（重命名 / 收藏到标签 / 导出 / 记忆弹层）还得有人挂：`ConversationMenuHost` + `ConversationMenuHostSheets`。

/// 菜单点完要弹的东西
@Observable
final class ConversationMenuHost {
    var renaming = false
    var renameText = ""
    var favoriteTagTarget: FavoriteTags.Target?
    var exporting: Conversation?
    var memorySheet: ConversationMemorySheetTarget?
}

/// 挂在菜单收起后还在的那一层
struct ConversationMenuHostSheets: ViewModifier {
    @Bindable var host: ConversationMenuHost
    let viewModel: ConversationViewModel
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: $host.renaming) {
                TextField("对话名称", text: $host.renameText)
                Button("取消", role: .cancel) { }
                Button("确认") {
                    let trimmed = host.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let conv = viewModel.selectedConversation {
                        conv.title = trimmed
                        conv.updateTime = Date()
                        viewModel.markConversationDirty()
                    }
                }
            }
            .sheet(item: $host.favoriteTagTarget) { FavoriteTagSheet(target: $0, onDone: {}) }
            .sheet(item: $host.exporting) { conv in
                ExportOptionsSheet(conversation: conv, viewModel: viewModel, userName: userName, assistantName: assistantName)
            }
            .modifier(ConversationMemorySheets(target: $host.memorySheet))
    }
}

/// 聊天页那份清单：iOS 浮层和 Mac / 宽屏系统菜单共用
enum ChatConversationMenu {
    /// 底下那行：最后聊的时间 · 条数（时间写法同聊天里的时间分隔）
    static func infoLine(_ conv: Conversation, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = "\(ChatTimeDivider.day(conv.updateTime, now: now, calendar: calendar)) \(ChatTimeDivider.clock(conv.updateTime, calendar: calendar))"
        return conv.nodeCount > 0 ? "\(time) · \(conv.nodeCount) 条" : time
    }

    @MainActor
    static func specs(for conv: Conversation, viewModel: ConversationViewModel, host: ConversationMenuHost,
                      modelContext: ModelContext, profileManager: ProfileManager?,
                      providerManager: ProviderManager?, presetManager: PresetManager?,
                      branchCount: Int, canSearch: Bool,
                      onSearch: @escaping () -> Void, onBranchMap: @escaping () -> Void) -> [MenuActionSpec] {
        let pid = conv.profileId
        var folders = FetchDescriptor<ConversationTag>(predicate: #Predicate { $0.profileId == pid },
                                                      sortBy: [SortDescriptor(\.order)])
        folders.fetchLimit = 200
        let state = ConversationMenu.State(
            isPinned: conv.isPinned, isFavorite: conv.isFavorite, isBubble: conv.isBubbleMode,
            memoryEnabled: conv.memoryEnabled, folderId: conv.folderId, personaId: conv.personaId,
            folders: ((try? modelContext.fetch(folders)) ?? []).map { ConversationMenu.Choice(id: $0.id, name: $0.name) },
            personas: UserPersonaStore.shared.personas.map { ConversationMenu.Choice(id: $0.id, name: $0.name) },
            memoryWriteEnabled: WriteMemoryNowButton.isEnabled,
            rerecord: RerecordFragmentsButton.availability(conv),
            isMainSession: MainSession.isMain(conv), isFolderSession: conv.isFolderSession)
        let handlers = ConversationMenu.Handlers(
            rename: {
                host.renameText = conv.title
                host.renaming = true
            },
            duplicate: { viewModel.duplicateConversation(conv, context: modelContext) },
            togglePin: {
                conv.pinnedAt = conv.isPinned ? nil : Date()
                try? modelContext.save()
            },
            toggleFavorite: { FavoriteTags.setFavorite(conv, !conv.isFavorite) },
            delete: { viewModel.softDeleteConversation(conv) },
            search: onSearch,
            branchMap: onBranchMap,
            toggleDisplayMode: {
                viewModel.setDisplayMode(conv.isBubbleMode ? .article : .bubble, for: conv, context: modelContext)
            },
            moveToFolder: { folderId in
                conv.folderId = folderId
                try? modelContext.save()
            },
            toggleMemory: {
                conv.memoryEnabled.toggle()
                try? modelContext.save()
            },
            openWindowNote: { viewModel.editOpenWindowNote(for: conv) },
            windowSummary: {
                host.memorySheet = ConversationMemorySheetTarget(kind: .windowSummary, conversationId: conv.id,
                                                                 profileId: conv.profileId, title: conv.title)
            },
            contextSummary: {
                host.memorySheet = ConversationMemorySheetTarget(kind: .contextSummary, conversationId: conv.id,
                                                                 profileId: conv.profileId, title: conv.title)
            },
            writeMemoryNow: {
                WriteMemoryNowButton.run(viewModel: viewModel, profileManager: profileManager,
                                         providerManager: providerManager, presetManager: presetManager)
            },
            rerecord: { RerecordFragmentsButton.ask(conv, viewModel: viewModel) },
            regenerateTitle: { ConversationTitler.regenerate(conv, context: modelContext, providerManager: providerManager) },
            favoriteTag: { host.favoriteTagTarget = FavoriteTags.Target(conversation: conv) },
            setPersona: { personaId in
                conv.personaId = personaId
                try? modelContext.save()
            },
            export: { host.exporting = conv })
        let cc = ConversationMenu.ccSpecs(
            conv, viewModel: viewModel,
            isHubConversation: CCHubTitle.isHubConversation(conv, providerManager: providerManager,
                                                            profileModelId: profileManager?.currentProfile.preferredModel),
            save: { try? modelContext.save() })
        return ConversationMenu.specs(place: .chat(branchCount: branchCount, canSearch: canSearch),
                                      state: state, cc: cc, handlers: handlers)
    }
}

/// Mac 标题栏 / iOS 宽屏悬浮条的系统 Menu 内容：标题 + 同一份清单 + 底下一行时间 · 条数。
/// 自己拿 manager：ContentView 不订阅 ProviderManager / PresetManager（见 ContentView 顶上的说明）
struct ChatConversationMenuItems: View {
    let viewModel: ConversationViewModel
    let host: ConversationMenuHost
    var branchCount: Int = 0
    var canSearch = false
    var onSearch: () -> Void = {}
    var onBranchMap: () -> Void = {}

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if let conv = viewModel.selectedConversation {
            Section { Text(conv.title) }
            MenuActionSpec.menuItems(from: MenuActionSpec.systemMenuOrder(ChatConversationMenu.specs(
                for: conv, viewModel: viewModel, host: host, modelContext: modelContext,
                profileManager: profileManager, providerManager: providerManager, presetManager: presetManager,
                branchCount: branchCount, canSearch: canSearch, onSearch: onSearch, onBranchMap: onBranchMap)))
            Section { Text(ChatConversationMenu.infoLine(conv)) }
        }
    }
}

#if os(iOS)
/// iOS 窄屏聊天页右上 ⋯：点了弹 page1 同款自绘浮层——对话标题卡 + 清单 + 底下一行小灰字（同气泡菜单底下那行）
struct ChatConversationMenuButton<Label: View>: View {
    let viewModel: ConversationViewModel
    var branchCount: Int = 0
    let onSearch: () -> Void
    var onBranchMap: () -> Void = {}
    @ViewBuilder let label: Label

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(\.modelContext) private var modelContext

    @StateObject private var overlay = BubbleMenuOverlayModel()
    @State private var probe = ButtonWindowFrame.Holder()
    @State private var host = ConversationMenuHost()

    var body: some View {
        Button(action: open) { label }
            .buttonStyle(.plain)
            .background(ButtonWindowFrame(holder: probe))
            .accessibilityLabel("更多")
            .modifier(ConversationMenuHostSheets(host: host, viewModel: viewModel))
    }

    private func open() {
        guard let conv = viewModel.selectedConversation, overlay.session == nil,
              let button = probe.view, let window = button.window else { return }
        // 点的那一刻现量：顶栏会随滚动收放，记下来的位置可能过期
        let frameInWindow = button.convert(button.bounds, to: window)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        window.endEditing(true)
        // 标题卡钉在 ⋯ 下面、右边对齐（isUser = 列靠右），宽度跟菜单卡一样
        let width: CGFloat = 235
        let origin = CGRect(x: frameInWindow.maxX - width, y: frameInWindow.maxY + 8, width: width, height: 44)
        overlay.session = BubbleMenuSession(
            preview: AnyView(titleCard(conv.title)),
            originFrameInWindow: origin,
            cornerRadius: 18,
            tailBackdrop: false,
            specs: ChatConversationMenu.specs(
                for: conv, viewModel: viewModel, host: host, modelContext: modelContext,
                profileManager: profileManager, providerManager: providerManager, presetManager: presetManager,
                branchCount: branchCount, canSearch: true,
                onSearch: {
                    // 输入栏要被查找面板顶替：先把没打完的拼音定稿进草稿（同 InputBarStack 切对话）
                    ChatInputHandle.shared.finalizeCompositionAndCommit()
                    onSearch()
                },
                onBranchMap: onBranchMap),
            isUser: true,
            infoLine: ChatConversationMenu.infoLine(conv),
            onRestore: {}
        )
        BubbleMenuOverlayPresenter.shared.present(model: overlay, in: window)
    }

    private func titleCard(_ title: String) -> some View {
        Text(title.isEmpty ? "新对话" : title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.chat.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

/// 拿到 ⋯ 按钮背后那块 UIView，点的时候换算到 window 坐标（聊天页在分页器 child HC 里，SwiftUI .global ≠ window 坐标）
private struct ButtonWindowFrame: UIViewRepresentable {
    final class Holder {
        weak var view: UIView?
    }

    let holder: Holder

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        holder.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        holder.view = view
    }
}
#endif
