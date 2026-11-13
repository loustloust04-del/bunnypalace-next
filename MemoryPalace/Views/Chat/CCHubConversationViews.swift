import SwiftUI
import SwiftData

/// 对话里看出连的是哪台电脑（plan-multi-hub B4.4，小样第 5 屏）。那台能不能用一律读 route，不自己判状态
enum CCHubTitle {
    /// 标题下那行小灰字：≥2 台才写（连主电脑的也写）；那台用不了（删了 / 待配对 / 换了机器 / 认不出）1 台也写；1 台且能用 = nil，标题不变
    static func subtitle(hubCount: Int, name: String?, blocker: CCHubRegistry.Unavailable?) -> String? {
        let name = name ?? "那台电脑"
        switch blocker {
        case nil: return hubCount >= 2 ? name : nil
        case .removed?: return "\(name) · 已删除"
        case .needsPairing?: return "\(name) · 要重新配对"
        case .identityChanged?: return "\(name) · 换了机器"
        case .unbound?: return "电脑不在这台设备上"
        }
    }

    /// 输入框上方那条：删了的照小样说法，其余用 route 带的说明
    static func notice(_ blocker: CCHubRegistry.Unavailable, name: String?) -> String {
        if blocker == .removed, let name { return "这个对话连的是「\(name)」，那台电脑已经删掉了，消息发不出去。" }
        return blocker.message
    }

    /// 改连时原来那台还有没回完的：回复照旧回原来那台（B3.5），不拦。不报条数（b4 #9）
    static func rebindNotice(unfinished: Bool, from name: String) -> String? {
        unfinished ? "还有没回完的在\(name)上，回复会回到\(name)" : nil
    }

    /// 新建对话选电脑那一节：≥2 台才出
    static func showsHubChoice(hubCount: Int) -> Bool { hubCount >= 2 }

    /// 走 hub 的对话（Claude Code / Codex 卡）
    static func isHubConversation(_ conversation: Conversation, providerManager: ProviderManager?, profileModelId: String?) -> Bool {
        guard let providerManager else { return conversation.ccBridgeSessionName != nil || conversation.ccHubId != nil }
        let model = providerManager.resolveModel(conversationModelId: conversation.selectedModelId, profileModelId: profileModelId,
                                                 globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        return providerManager.credential(for: model)?.type == .ccBridge
    }

    @MainActor
    static func name(of hubId: String, registry: CCHubRegistry = .shared) -> String? {
        registry.hubs.first { $0.id == hubId }?.name ?? registry.removedName(of: hubId)
    }

    @MainActor
    static func blocker(for conversation: Conversation, registry: CCHubRegistry = .shared) -> CCHubRegistry.Unavailable? {
        if case .failure(let why) = registry.route(CCHubRegistry.hubId(of: conversation)) { return why }
        return nil
    }

    @MainActor
    static func subtitle(for conversation: Conversation, registry: CCHubRegistry = .shared) -> String? {
        subtitle(hubCount: registry.hubs.count, name: name(of: CCHubRegistry.hubId(of: conversation), registry: registry),
                 blocker: blocker(for: conversation, registry: registry))
    }

    /// 每台一句状态 + 能不能用
    @MainActor
    static func status(of hub: CCHubRegistry.HubProfile, registry: CCHubRegistry = .shared) -> (text: String, ok: Bool) {
        switch hub.status {
        case .needsPairing: return ("要重新配对", false)
        case .identityChanged: return ("换了机器", false)
        case .ready: return registry.client(for: hub.id)?.isConnected == true ? ("已接上", true) : ("连不上", false)
        }
    }

    /// 新建对话选了这台：记成「上次选的」，按新对话规则绑（主电脑 hub_id 还不知道就留 nil，同 bindNewCCConversation）；
    /// 已经挑过会话名的走改绑
    @MainActor
    static func pickForNewConversation(_ conversation: Conversation, hubId: String, registry: CCHubRegistry = .shared) {
        registry.lastHubId = hubId
        if conversation.ccBridgeSessionName == nil {
            conversation.ccHubId = nil
            conversation.ccHubIdentity = nil
            registry.bindNewCCConversation(conversation)
            if registry.focus?.chatId == conversation.id { registry.updateFocus(conversation) }
        } else {
            registry.rebind(conversation, to: hubId)
        }
    }

    /// 已有对话改连（「换一台」/ 菜单「连哪台电脑」）。返回要提示的话：原来那台还在、还有没回完的
    @MainActor
    static func rebind(_ conversation: Conversation, to hubId: String, unfinished: Bool,
                       registry: CCHubRegistry = .shared) -> String? {
        let old = CCHubRegistry.hubId(of: conversation)
        guard hubId != old, registry.rebind(conversation, to: hubId) else { return nil }
        guard registry.status(for: old) != nil, let oldName = name(of: old, registry: registry) else { return nil }
        return rebindNotice(unfinished: unfinished, from: oldName)
    }
}

/// 标题下那行小灰字（iOS 竖屏顶栏下 / iPad 胶囊里 / Mac 标题旁）。1 台且能用时什么都不画
struct CCHubTitleLine: View {
    let conversation: Conversation
    var font: Font = .system(size: 11.5)
    var color: Color = Theme.chat.textMuted
    var trailing: CGFloat = 0

    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        if CCHubTitle.isHubConversation(conversation, providerManager: providerManager,
                                        profileModelId: profileManager?.currentProfile.preferredModel),
           let text = CCHubTitle.subtitle(for: conversation) {
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .padding(.trailing, trailing)
        }
    }
}

/// 「接到哪台电脑上」：「换一台」和对话菜单「连哪台电脑」弹的是同一份
struct CCHubChoiceItems: View {
    let conversation: Conversation
    let viewModel: ConversationViewModel

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let registry = CCHubRegistry.shared
        let current = CCHubRegistry.hubId(of: conversation)
        Section("接到哪台电脑上") {
            ForEach(registry.hubs) { hub in
                Button { pick(hub.id) } label: {
                    Label(hub.id == current ? "\(hub.name)（现在连的）" : hub.name,
                          systemImage: hub.id == current ? "checkmark" : "desktopcomputer")
                    Text(detail(hub))
                }
                .disabled(hub.id == current)
            }
        }
    }

    private func detail(_ hub: CCHubRegistry.HubProfile) -> String {
        let status = CCHubTitle.status(of: hub).text
        return hub.id == CCHubRegistry.primaryId ? "主电脑 · \(status)" : status
    }

    private func pick(_ id: String) {
        let unfinished = viewModel.ccHasUnfinished(for: conversation)
        let notice = CCHubTitle.rebind(conversation, to: id, unfinished: unfinished)
        try? modelContext.save()
        if let notice { ToastCenter.shared.show(notice) }
    }
}

/// 输入框上方：这条对话连的那台用不了（删了 / 待配对 / 换了机器 / 认不出）+「换一台」。只是连不上不出，照现有断线提示走
struct CCHubBlockedBanner: View {
    let conversation: Conversation
    let blocker: CCHubRegistry.Unavailable
    let viewModel: ConversationViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text(CCHubTitle.notice(blocker, name: CCHubTitle.name(of: CCHubRegistry.hubId(of: conversation))))
                .font(.system(size: 12.5))
                .foregroundColor(Theme.chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                CCHubChoiceItems(conversation: conversation, viewModel: viewModel)
            } label: {
                Text("换一台")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0x1F2A24))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.branchIndicator))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.chat.textPrimary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.chat.textPrimary.opacity(0.07), lineWidth: 0.5))
        )
    }
}

/// 对话菜单里那行「连哪台电脑」：hub 对话、≥2 台或者连的那台用不了才出
struct CCHubMenuEntry: View {
    let conversation: Conversation
    let viewModel: ConversationViewModel

    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        if CCHubTitle.isHubConversation(conversation, providerManager: providerManager,
                                        profileModelId: profileManager?.currentProfile.preferredModel),
           CCHubRegistry.shared.hubs.count >= 2 || CCHubTitle.blocker(for: conversation) != nil {
            Menu {
                CCHubChoiceItems(conversation: conversation, viewModel: viewModel)
            } label: {
                Label("连哪台电脑 · \(CCHubTitle.name(of: CCHubRegistry.hubId(of: conversation)) ?? "那台电脑")",
                      systemImage: "desktopcomputer")
            }
        }
    }
}
