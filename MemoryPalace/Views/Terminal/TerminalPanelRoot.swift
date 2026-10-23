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
    private var store: TerminalWindowStore { .shared }
    private var localStore: ISHTerminalSessionStore { .shared }

    private var connected: Bool { CCBridgeWebSocketClient.shared.isConnected }
    private var paired: Bool { connected || !bridgeOverride.isEmpty }
    /// 只有 Agent 对话才有（D3：普通对话不再兜底 mp-cc，打开终端也不在电脑上起 claude）
    private var conversationAgent: String? { viewModel.selectedConversation?.ccBridgeSessionName }

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabBar(model: model, connected: connected)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { TerminalChrome.background.ignoresSafeArea() }
        .background { if appActive { shortcuts } }
        .onAppear(perform: start)
        .onDisappear { store.stopSyncing() }
        .onChange(of: conversationAgent) { _, new in model.pinnedAgent = new }
        // 停着的 Agent 不再是固定项（切了对话 / 换成「最近」里别的）→ 跟着换过去，没有就回首页，别停在 tab 条上找不到的那个
        .onChange(of: model.pinnedAgent) { _, new in
            if case .agent(let session) = model.current, session != new {
                model.select(new.map(TerminalTarget.agent) ?? .home)
            }
        }
        .onChange(of: navigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .onChange(of: store.windows.map(\.code)) { _, _ in model.ejectIfGone() }
        .onChange(of: localStore.sessions.map(\.id)) { _, _ in model.ejectIfGone() }
        .onChange(of: profileManager?.currentProfile.id, initial: true) { _, id in model.profileId = id }
        .onChange(of: store.syncSeq) { _, _ in model.ejectIfGone() }
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
    }

    @ViewBuilder
    private var content: some View {
        switch model.current {
        case .home:
            TerminalHomeView(model: model, link: link, profileId: profileManager?.currentProfile.id)
        case .agent(let session):
            TerminalSessionPane(sessionName: session, windowCode: nil, model: model, paired: paired)
                .id(session)
        case .window(let code):
            TerminalSessionPane(sessionName: "mp-win-\(code)", windowCode: code, model: model, paired: paired)
                .id("mp-win-\(code)")
        case .local(let id):
            if let session = localStore.session(id) {
                TerminalLocalSessionPane(session: session, model: model)
                    .id(id)
            }
        }
    }

    private var link: TerminalLinkState {
        if connected { return .connected }
        return paired ? .broken : .unplugged
    }

    private func start() {
        // 全局窗口列表：进页面拉一次 + 60s 对账（hub 是真相源，本地只为离线可见）
        store.startSyncing()
        model.pinnedAgent = conversationAgent
        if model.target == nil {
            if !homeSeen {
                homeSeen = true
                model.select(.home)
            } else {
                model.select(conversationAgent.map(TerminalTarget.agent) ?? .home)
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
        if store.windows.contains(where: { $0.code == target.id && !$0.isClosed }) {
            model.select(.window(target.id))
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
                case .window(let code): model.collapse(code)
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
#endif
