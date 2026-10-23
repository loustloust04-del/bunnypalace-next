#if os(iOS)
import SwiftUI

/// 一个 session 的终端区域（Agent 或全局窗口）。外层 `.id(sessionName)`：切 session 就整块重建 → 新 controller + 重 attach，
/// 旧的 onDisappear detach，成对。
struct TerminalSessionPane: View {
    let sessionName: String
    /// 全局窗口才有。session 没了时「重新开一个」要按它的引擎开
    let windowCode: String?
    let model: TerminalPanelModel
    let paired: Bool

    @StateObject private var controller: CCTerminalController
    @Environment(\.page2AppActive) private var appActive
    @State private var showToolbarSettings = false
    /// 桥断了 1 秒以上才盖卡，启动 / 换网那一下的抖动不闪卡
    @State private var bridgeDown = false
    @State private var keyboardUp = false
    /// 按了「重新连接」还没连上（T05）：卡上按钮变「连接中…」。连上或 12 秒没连上都收
    @State private var reconnecting = false

    init(sessionName: String, windowCode: String?, model: TerminalPanelModel, paired: Bool) {
        self.sessionName = sessionName
        self.windowCode = windowCode
        self.model = model
        self.paired = paired
        _controller = StateObject(wrappedValue: CCTerminalController(sessionName: sessionName))
    }

    private var client: CCBridgeWebSocketClient { .shared }
    private var connected: Bool { client.isConnected }

    private var issue: TerminalBridgeIssue? {
        if !connected { return paired ? (bridgeDown ? .disconnected : nil) : .notPaired }
        if controller.error == "session_not_found" { return .sessionGone }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            errorLine
            TerminalRepresentable(
                controller: controller,
                onOpenWindowSwitcher: {
                    model.panelExpandsClosed = false
                    model.showWindowPanel = true
                },
                onOpenSettings: { showToolbarSettings = true },
                dimsToolbar: !connected
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .bottom) {
                if controller.showsOfflineInputHint {
                    TerminalOfflineInputBanner()
                } else if issue == nil, !keyboardUp, controller.mouseMode == .forwarding {
                    TerminalInputHint()
                }
            }
            .overlay {
                if let issue {
                    TerminalBridgeCard(issue: issue,
                                       reason: issue == .disconnected ? BridgeDisconnectWording.humanize(client.lastError) : nil,
                                       hint: issue == .disconnected
                                           ? BridgeDisconnectWording.tailscaleHint(lastError: client.lastError, candidateHosts: client.candidateHosts)
                                           : nil,
                                       busy: issue == .disconnected && reconnecting,
                                       primary: { primaryAction(issue) },
                                       secondary: { model.showConnect = true })
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: issue)
            .animation(.easeInOut(duration: 0.2), value: controller.showsOfflineInputHint)
            .padding(.bottom, 10)
        }
        .sensoryFeedback(.impact, trigger: model.refreshSeq)
        .onChange(of: model.refreshSeq) { _, _ in controller.refresh() }
        .onChange(of: controller.usage, initial: true) { _, usage in model.usage = usage }
        // T21：终端在前台、画面真出来了才算看过（这块只给当前选中的 tab 画）
        .onChange(of: appActive && controller.hasShownSnapshot, initial: true) { _, seen in
            if seen { CCBridgeWebSocketClient.shared.sendTerminalSeen(session: sessionName) }
        }
        .task(id: connected) {
            guard !connected else { bridgeDown = false; reconnecting = false; return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { bridgeDown = true }
        }
        .task(id: reconnecting) {
            guard reconnecting else { return }
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { reconnecting = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
        .onAppear {
            controller.noteOpened()
            // Agent session 幂等 spawn（已存在 hub 回 session_exists，忽略）→ 新会话终端不黑屏。
            // 全局窗口由 hub 的 open_window 起，不走这条（这条会 spawn claude）。
            if !sessionName.hasPrefix("mp-win-") {
                CCBridgeWebSocketClient.shared.spawnSession(sessionName) { _ in }
            }
            // attach 由 sizeChanged 拿到真实 cols/rows 负责；2s 兜底防 layout 异常 sizeChanged 没 fire
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak controller] in
                controller?.attachIfNotYet(cols: 80, rows: 24)
            }
        }
        .onDisappear { controller.detach() }
        .sheet(isPresented: $showToolbarSettings) {
            NavigationStack { TerminalSettingsTab() }
                .presentationBackground(Theme.sidebarBg)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = controller.error, error != "session_not_found" {
            // stream_session = 无终端模式的会话（hub 侧 stream 传输），不是故障，不盖卡
            let isStream = error == "stream_session"
            Text(isStream ? "这个会话是无终端模式：消息直接送达，权限和提问在对话里答，这里没有画面。" : "⚠️ \(TerminalErrorWording.humanize(error))")
                .font(.system(size: 11))
                .foregroundColor(isStream ? TerminalChrome.dim : Palette.berry)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    // 人话之外留原文（T07）：给她拿去问 / 贴给我看
                    if !isStream {
                        Button("复制原因", systemImage: "doc.on.doc") { TerminalErrorClipboard.copy(error) }
                    }
                }
        }
    }

    private func primaryAction(_ issue: TerminalBridgeIssue) {
        switch issue {
        case .notPaired:
            model.showConnect = true
        case .disconnected:
            // 立刻重连桥（T05），不等退避；连上后 didOpen 自动补订阅这个终端，session 没了会自动 spawn（T06）
            reconnecting = true
            client.reconnectNow()
        case .sessionGone:
            if let windowCode {
                let engine = TerminalWindowStore.shared.windows.first { $0.code == windowCode }?.engine
                model.open(engine: engine == "shell" ? nil : engine)
            } else {
                // Agent session：reconnect 会先幂等 spawn 再 attach，等于重新开一个
                controller.reconnect()
            }
        }
    }
}
#endif
