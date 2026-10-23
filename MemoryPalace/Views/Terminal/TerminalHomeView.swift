#if os(iOS)
import SwiftUI
import SwiftData

/// 小电脑和手机之间是什么状态（首页 3D 场景的三种画法）
enum TerminalLinkState: Equatable {
    /// 从没配过对
    case unplugged
    case connected
    /// 配过对，现在连不上
    case broken
}

/// 终端首页（tab 条最左 ⌂）：上面 3D 小场景，中间三格三行，下面最近 4 条。
/// 不 attach 任何终端 —— 收不到 terminal_state 推送，状态靠 store 的 60s 对账 + 进来时刷一次。
struct TerminalHomeView: View {
    let model: TerminalPanelModel
    let link: TerminalLinkState
    let profileId: String?

    @Environment(\.modelContext) private var modelContext
    @State private var agents: [TerminalAgentConversation] = []
    /// 这个楼层里有没有 Claude / Codex 的对话（hub 没报装没装时，吉祥物按「出现过」放）
    @State private var seenEngines: Set<TerminalEngine> = []
    @State private var settingsPage: TerminalSceneItem?
    private var store: TerminalWindowStore { .shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TerminalHomeScene(input: sceneInput, onAction: sceneAction)
                    .frame(height: 340)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                cells
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                recents
            }
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { store.refresh() }
        .task(id: profileId) { loadAgents() }
        .sheet(item: $settingsPage) { page in
            TerminalAgentSettingsSheet(page: page)
        }
    }

    // MARK: 3D 小场景

    private var sceneInput: TerminalSceneInput {
        let local = TerminalLocalDevice.current
        // 断线也用上一份：断开态照样画那台电脑、写「某某现在连不上」
        let info = CCBridgeWebSocketClient.shared.hubInfo.map(TerminalHostInfo.init(hello:))
        let claude = mascotFace(.claude, installed: info?.claudeInstalled)
        let codex = mascotFace(.codex, installed: info?.codexInstalled)
        var rows = [TerminalCRTScreen.Row(text: "> hub online", color: 0x87D6B0)]
        for (engine, face) in [(TerminalEngine.claude, claude), (.codex, codex)] where face != nil {
            let dot = agentDot(engine)
            let status = dot?.statusText ?? "空闲"
            let color: UInt = dot == .waiting ? 0xFFB05E : dot == .done ? 0x87D6B0 : 0x9fbcae
            rows.append(TerminalCRTScreen.Row(text: "> \(engine.rawName) · \(status)", color: color))
        }
        return TerminalSceneInput(
            link: link,
            local: local.deviceClass,
            localName: local.name,
            remote: info?.deviceClass ?? .allInOne,
            remoteName: info?.modelName,
            hostName: info?.hostName,
            claude: claude,
            codex: codex,
            screenTitle: info?.hostName?.uppercased() ?? "MY-COMPUTER",
            screenRows: rows
        )
    }

    /// 电脑上有这个引擎就放吉祥物：hub 说没装才不放；不知道时按这台上出现过它的窗口 / 对话判。
    /// 有 Agent 等你或跑完了 = ^ ^，其余正常脸（没连上的 x.x 由场景按连接状态画）
    private func mascotFace(_ engine: TerminalEngine, installed: Bool?) -> TerminalMascotFace? {
        if installed == false { return nil }
        if installed == nil && !engineSeen(engine) { return nil }
        let dot = agentDot(engine)
        return dot == .waiting || dot == .done ? .happy : .normal
    }

    private func engineSeen(_ engine: TerminalEngine) -> Bool {
        if seenEngines.contains(engine) { return true }
        if (store.windows + store.closed).contains(where: { TerminalEngine.forWindow(reported: $0.engine) == engine }) { return true }
        return store.sessionStates.contains { TerminalEngine.forAgentSession($0.key, reported: $0.value.engine) == engine }
    }

    /// 这个引擎最要紧的状态：等你 > 跑完了 > 在干活
    private func agentDot(_ engine: TerminalEngine) -> TerminalDot? {
        var dots: [TerminalDot] = []
        for window in store.windows where TerminalEngine.forWindow(reported: window.engine) == engine {
            if let dot = TerminalDot.resolve(phase: window.phase, dead: store.isStale || !window.alive) { dots.append(dot) }
        }
        for (session, state) in store.sessionStates where TerminalEngine.forAgentSession(session, reported: state.engine) == engine {
            if let dot = TerminalDot.resolve(phase: state.phase, dead: !state.alive) { dots.append(dot) }
        }
        return [TerminalDot.waiting, .done, .working].first { dots.contains($0) }
    }

    private func sceneAction(_ item: TerminalSceneItem) {
        switch item {
        case .local: model.openLocal()
        case .remote: computerAction()
        case .claude, .codex: settingsPage = item
        case .ghost: model.showConnect = true
        }
    }

    // MARK: 三格

    private var cells: some View {
        VStack(spacing: 6) {
            cell(.phone, title: "手机里的小电脑", detail: phoneDetail, action: "新终端 ›", off: false) {
                model.openLocal()
            }
            cell(.computer, title: "我的电脑", detail: computerDetail,
                 action: link == .connected ? "新 shell ›" : "接上我的电脑 ›", off: link != .connected,
                 perform: computerAction)
            cell(.agent, title: "Agent", detail: claudeMissing ? "电脑上还没装 Claude Code" : agentDetail,
                 action: link == .connected ? "新 Claude Code ›" : "接上我的电脑 ›", off: link != .connected || claudeMissing) {
                if link != .connected {
                    model.showConnect = true
                } else if claudeMissing {
                    ToastCenter.shared.show("电脑上还没装 Claude Code：Mac 上「让手机连这台 Mac」页有安装命令")
                } else {
                    model.open(engine: "claude")
                }
            }
        }
    }

    private var phoneDetail: String {
        let count = ISHTerminalSessionStore.shared.sessions.count
        return count > 0 ? "自带 Linux，断网也能用 · \(count) 个开着" : "自带 Linux，断网也能用"
    }

    private var computerDetail: String {
        switch link {
        case .connected: return "已接上"
        case .broken: return "连不上了"
        case .unplugged: return "还没接上"
        }
    }

    /// hello 明说电脑上没装 claude（#046）；不知道（老 hub / 探测没跑完）不拦
    private var claudeMissing: Bool {
        link == .connected && CCBridgeWebSocketClient.shared.currentHubInfo?.tools.claude == false
    }

    private var agentDetail: String {
        let count = model.tabItems.filter { $0.engine.cell == .agent }.count
        return count > 0 ? "住在电脑上 · \(count) 个开着" : "住在电脑上"
    }

    private func computerAction() {
        if link == .connected { model.open(engine: nil) } else { model.showConnect = true }
    }

    private func cell(_ cell: TerminalCell, title: String, detail: String, action: String, off: Bool,
                      perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text("\(cell.rawValue)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(TerminalChrome.chip)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(TerminalChrome.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(TerminalChrome.dim)
            }
            Spacer(minLength: 8)
            Text(action)
                .font(.system(size: 12))
                .foregroundColor(off ? Palette.apricot : Palette.mint)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture(perform: perform)
    }

    // MARK: 最近

    @ViewBuilder
    private var recents: some View {
        let items = TerminalRecents.merge(windows: store.windows, closed: store.closed, agents: agents,
                                          states: store.sessionStates, stale: store.isStale)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("最近")
                    .font(.system(size: 11))
                    .kerning(0.5)
                    .foregroundColor(TerminalChrome.dim)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    recentRow(item)
                }
            }
        }
    }

    private func recentRow(_ item: TerminalRecentItem) -> some View {
        HStack(spacing: 8) {
            TerminalStatusDot(dot: item.dot)
            TerminalCellChip(cell: item.cell)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundColor(TerminalChrome.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(trailing(item))
                .font(.system(size: 11.5))
                .foregroundColor(item.dot.flatMap { $0 == .dead ? nil : $0.color } ?? TerminalChrome.dim)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .onTapGesture { open(item) }
    }

    private func trailing(_ item: TerminalRecentItem) -> String {
        if let dot = item.dot, dot != .dead { return dot.statusText }
        let time = TerminalTimestamp.relative(item.date)
        if case .closedWindow = item.kind { return "收起 · \(time)" }
        return time
    }

    private func open(_ item: TerminalRecentItem) {
        switch item.kind {
        case .window(let code):
            model.select(.window(code))
        case .closedWindow(let code):
            model.restore(code)
        case .agent(let session):
            model.pinnedAgent = session
            model.select(.agent(session))
        }
    }

    /// 绑了 Agent 的对话：按非 optional 字段缩范围（profileId / isTrashed）+ 最近打开排序取一小段，
    /// optional 的 ccBridgeSessionName 在内存里筛（SwiftData optional 谓词会静默查不到）
    private func loadAgents() {
        guard let profileId else { agents = []; seenEngines = []; return }
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == profileId && !$0.isTrashed },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 60
        let conversations = (try? modelContext.fetch(descriptor)) ?? []
        seenEngines = agentEngines(profileId: profileId)
        agents = Array(conversations.lazy.compactMap { conversation -> TerminalAgentConversation? in
            guard let session = conversation.ccBridgeSessionName, let openedAt = conversation.lastOpenedAt else { return nil }
            return TerminalAgentConversation(session: session, title: conversation.title, openedAt: openedAt)
        }.prefix(4))
    }

    /// 本楼层有没有 Claude / Codex 的对话，不受「最近」截断。
    /// 谓词只用非 optional 字段（optional 字段的谓词会静默查不到），只取 session 名这一列，引擎在内存里按名字判
    private func agentEngines(profileId: String) -> Set<TerminalEngine> {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == profileId && !$0.isTrashed })
        descriptor.propertiesToFetch = [\.ccBridgeSessionName]
        var engines: Set<TerminalEngine> = []
        for conversation in (try? modelContext.fetch(descriptor)) ?? [] {
            guard let session = conversation.ccBridgeSessionName else { continue }
            engines.insert(TerminalEngine.forAgentSession(session, reported: nil))
            if engines.count == 2 { break }
        }
        return engines
    }
}

/// 点吉祥物：设置 › Claude Code / Codex（和「连接我的电脑」同一种外壳）
private struct TerminalAgentSettingsSheet: View {
    let page: TerminalSceneItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if page == .codex { CodexSettingsTab() } else { CCSettingsView() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
#endif
