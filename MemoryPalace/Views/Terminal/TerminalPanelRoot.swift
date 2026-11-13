#if os(iOS)
import SwiftUI

/// iOS 的终端页（右栏「终端」）：系统状态栏下面一条 tab 条，下面是首页或某个 session 的终端。
/// Mac 走 `CCTerminalPanelView` 里原来那条路，不经过这里。
struct TerminalPanelRoot: View {
    var viewModel: ConversationViewModel
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.page2AppActive) private var appActive
    @State private var model = TerminalPanelModel()
    /// 第一次打开终端停在首页（之后按对话默认停 Agent）
    @AppStorage("terminalHomeSeen") private var homeSeen = false
    /// 扫码配对写的地址。空 = 从没配过对（iOS 上默认的 127.0.0.1 连不到任何东西）
    @AppStorage("ccBridgeBaseURLOverride") private var bridgeOverride = ""
    private var localStore: ISHTerminalSessionStore { .shared }

    /// 首页 / tab 条 / 窗口面板说的那台（R6：不再读 .shared）
    private var connected: Bool { model.client?.isConnected == true }
    /// 只有 Agent 对话才有（D3：普通对话不再兜底 mp-cc，打开终端也不在电脑上起 claude）；在这条对话连的那台上，那台删了 / 认不出就没有
    ///（待配对 / 换了机器还留着，点进去是修复卡，R5.6）
    private var conversationAgent: TerminalAgentRef? {
        guard let conversation = viewModel.selectedConversation, let session = conversation.ccBridgeSessionName else { return nil }
        let hub = CCHubRegistry.hubId(of: conversation)
        if case .failure(let why) = CCHubRegistry.shared.route(hub), why != .needsPairing, why != .identityChanged { return nil }
        return TerminalAgentRef(hubId: hub, session: session)
    }

    /// 配没配过对：主 hub 看扫码写的地址（原逻辑），附加 hub 看自己有没有候选地址
    private func paired(_ client: CCBridgeWebSocketClient) -> Bool {
        client.isConnected || (client.isPrimary ? !bridgeOverride.isEmpty : client.hasCandidates)
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabBar(model: model, connected: connected)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { TerminalChrome.background.ignoresSafeArea() }
        .background { if appActive { shortcuts } }
        .onAppear(perform: start)
        .onDisappear { for (_, store) in model.hubStores { store.stopSyncing() } }
        .onChange(of: conversationAgent) { _, new in model.pinnedAgent = new }
        // 停着的 Agent 不再是固定项（切了对话 / 换成「最近」里别的）→ 跟着换过去，没有就回首页，别停在 tab 条上找不到的那个
        .onChange(of: model.pinnedAgent) { _, new in
            if case .agent(let hub, let session) = model.current, TerminalAgentRef(hubId: hub, session: session) != new {
                model.select(new?.target ?? .home)
            }
        }
        .onChange(of: navigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .onChange(of: model.hubStores.map { $0.store.windows.map(\.code) }) { _, _ in model.ejectIfGone() }
        .onChange(of: localStore.sessions.map(\.id)) { _, _ in model.ejectIfGone() }
        .onChange(of: profileManager?.currentProfile.id, initial: true) { _, id in model.profileId = id }
        .onChange(of: model.hubStores.map(\.store.syncSeq)) { _, _ in model.ejectIfGone() }
        // 新加的电脑也要同步窗口表（tab 条放全部电脑的窗口）
        .onChange(of: model.hubs.map(\.id)) { _, _ in
            for (_, store) in model.hubStores { store.startSyncing() }
            model.pruneRemovedHubs()
        }
        .alert("改名", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("标题", text: Binding(get: { model.renaming?.text ?? "" }, set: { model.renaming?.text = $0 }))
            Button("取消", role: .cancel) {}
            Button("确定") { if let request = model.renaming { model.rename(request) } }
        }
        .confirmationDialog("结束这个窗口？", isPresented: Binding(get: { model.ending != nil }, set: { if !$0 { model.ending = nil } }),
                            titleVisibility: .visible, presenting: model.ending) { window in
            Button("结束", role: .destructive) { model.end(window) }
        } message: { _ in
            Text("里面跑的东西会被停掉，不能恢复。只想先放一边就用「收起」。")
        }
        .confirmationDialog("结束这个小电脑终端？", isPresented: Binding(get: { model.endingLocal != nil }, set: { if !$0 { model.endingLocal = nil } }),
                            titleVisibility: .visible, presenting: model.endingLocal) { id in
            Button("结束", role: .destructive) { model.endLocal(id) }
        } message: { _ in
            Text("里面跑的会停掉，文件还在。")
        }
        .sheet(isPresented: $model.showWindowPanel) {
            TerminalWindowSwitchSheet(model: model, connected: connected)
        }
        .sheet(isPresented: $model.showSandbox) {
            TerminalSandboxSheet {
                model.showSandbox = false
                model.openLocal()
            }
        }
        .sheet(isPresented: $model.showConnect) { TerminalConnectSheet() }
        .modifier(TerminalHubSheets(model: model))
    }

    @ViewBuilder
    private var content: some View {
        switch model.current {
        case .home:
            TerminalHomeView(model: model, links: links, profileId: profileManager?.currentProfile.id)
        case .agent(let hub, let session):
            hubPane(hub: hub, sessionName: session, windowCode: nil)
                .id("\(hub)|\(session)")
        case .window(let hub, let code):
            hubPane(hub: hub, sessionName: "mp-win-\(code)", windowCode: code)
                .id("\(hub)|mp-win-\(code)")
        case .local(let id):
            if let session = localStore.session(id) {
                TerminalLocalSessionPane(session: session, model: model)
                    .id(id)
            }
        }
    }

    /// session 在哪台就接哪台的 client（显式传，B3.4）；那台用不了 → 不接、回首页，不落到主 hub
    @ViewBuilder
    private func hubPane(hub: String, sessionName: String, windowCode: String?) -> some View {
        switch CCHubRegistry.shared.route(hub) {
        case .success(let client):
            if let pending = model.pendingRestore, pending.hubId == hub, pending.code == windowCode {
                TerminalPendingRestorePane(client: client, model: model, code: pending.code)
            } else {
                TerminalSessionPane(sessionName: sessionName, windowCode: windowCode, client: client, model: model, paired: paired(client))
            }
        case .failure(let why) where why == .needsPairing || why == .identityChanged:
            // 那台还在、只是要重新配对：留在修复卡上（带原 hub 的配对入口），不接终端（R5.6）
            TerminalRepairPane(hubId: hub, reason: why, model: model)
        case .failure(let why):
            Color.clear.onAppear {
                ToastCenter.shared.show(why.message)
                model.select(.home)
            }
        }
    }

    /// 每台电脑的三态。主 hub 照原逻辑；附加 hub 待配对 / 换了机器 = 配过但用不了，算断了
    private var links: [String: TerminalLinkState] {
        Dictionary(uniqueKeysWithValues: model.hubs.map { hub in
            let link: TerminalLinkState
            switch CCHubRegistry.shared.route(hub.id) {
            case .success(let client): link = client.isConnected ? .connected : paired(client) ? .broken : .unplugged
            case .failure: link = .broken
            }
            return (hub.id, link)
        })
    }

    private func start() {
        // 全局窗口列表：进页面拉一次 + 60s 对账（hub 是真相源，本地只为离线可见）；每台各同步各的
        for (_, store) in model.hubStores { store.startSyncing() }
        model.pinnedAgent = conversationAgent
        if model.target == nil {
            if !homeSeen {
                homeSeen = true
                model.select(.home)
            } else {
                model.select(conversationAgent?.target ?? .home)
            }
        }
        consumeDesktopTarget()
    }

    /// iPad 桌面卡 / 小组件点进来的那个窗口
    private func consumeDesktopTarget() {
        guard let target = navigator?.pendingTarget, target.tool == "ccTerminal" else { return }
        // 设置 › 手机里的小电脑 →「打开终端」（#045）
        if target.id == Self.newLocalTargetId {
            navigator?.pendingTarget = nil
            model.openLocal()
            return
        }
        // 窗口目标要说明在哪台（tab 条放全部电脑的窗口，哪台都认）
        if let hub = target.hubId,
           CCHubRegistry.shared.windowStore(for: hub)?.windows.contains(where: { $0.code == target.id && !$0.isClosed }) == true {
            model.select(.window(hub: hub, code: target.id))
        }
        navigator?.pendingTarget = nil
    }

    /// `RightPanelNavigator.pendingTarget.id`：开一个新的小电脑终端
    static let newLocalTargetId = "ish:new"

    /// 外接键盘：⌘1…9 按 tab 条顺序切（⌂ 是第 1 个）、⌘T 新 shell、⌘W 收起当前窗口。
    /// 只在这个应用在前台时挂，后台卡片里的终端不抢快捷键。
    private var shortcuts: some View {
        let targets = Array(([TerminalTarget.home] + model.tabItems.map(\.target)).prefix(9))
        return ZStack {
            ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                Button("切到第 \(index + 1) 个") { model.select(target) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            // 没接电脑时开小电脑终端（D4），接着就开电脑上的 shell
            Button("新 shell") {
                if connected { model.open(engine: nil) } else { model.openLocal() }
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("收起当前窗口") {
                switch model.current {
                case .window(let hub, let code): model.collapse(code, hub: hub)
                case .local(let id): model.endingLocal = id
                default: break
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// 再接一台 / 管理这台（B4.3）
private struct TerminalHubSheets: ViewModifier {
    @Bindable var model: TerminalPanelModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.addingHub) { HubPairingSheet(target: nil) }
            .sheet(isPresented: Binding(get: { model.managingHub != nil }, set: { if !$0 { model.managingHub = nil } })) {
                if let hub = model.managingHub { HubManageSheet(hubId: hub) }
            }
            .sheet(isPresented: Binding(get: { model.rescanningHub != nil }, set: { if !$0 { model.rescanningHub = nil } })) {
                if let hub = model.rescanningHub { HubPairingSheet(target: hub) }
            }
    }
}
#endif
