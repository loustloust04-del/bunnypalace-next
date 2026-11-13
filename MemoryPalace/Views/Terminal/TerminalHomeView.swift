#if os(iOS)
import SwiftUI
import SwiftData

/// 终端首页（tab 条最左 ⌂）：上面 3D 小场景，中间三格三行（≥2 台时一台电脑一行），下面最近 4 条。
/// 不 attach 任何终端 —— 收不到 terminal_state 推送，状态靠 store 的 60s 对账 + 进来时刷一次。
struct TerminalHomeView: View {
    let model: TerminalPanelModel
    /// 每台电脑的三态（主电脑第一）
    let links: [String: TerminalLinkState]
    let profileId: String?
    /// 1 台时三格说的那台（= 主 hub）
    private var hubId: String { model.hubId }
    private var link: TerminalLinkState { links[hubId] ?? .unplugged }

    @Environment(\.modelContext) private var modelContext
    @State private var agents: [TerminalAgentConversation] = []
    /// 每台电脑上有没有 Claude / Codex 的对话（hub 没报装没装时，吉祥物按「出现过」放）
    @State private var seenEngines: [String: Set<TerminalEngine>] = [:]
    @State private var settingsPage: TerminalSceneItem?
    /// 3D 聚焦哪个（点电脑行的名字也会拉过去）
    @State private var sceneFocus: TerminalSceneItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TerminalHomeScene(input: sceneInput, focus: $sceneFocus, onAction: sceneAction,
                                  onManage: { model.managingHub = $0 })
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
        .onAppear { for (_, store) in model.hubStores { store.refresh() } }
        .task(id: [profileId ?? ""] + model.hubs.map(\.id) + waitingSessions.map { "\($0.hubId)|\($0.session)" }.sorted()) { loadAgents() }
        .sheet(item: $settingsPage) { page in
            TerminalAgentSettingsSheet(page: page)
        }
    }

    // MARK: 3D 小场景

    private var sceneInput: TerminalSceneInput {
        let local = TerminalLocalDevice.current
        return TerminalSceneInput(local: local.deviceClass, localName: local.name, hosts: model.hubs.map(sceneHost))
    }

    private func sceneHost(_ hub: CCHubRegistry.HubProfile) -> TerminalSceneHost {
        let primary = hub.id == CCHubRegistry.primaryId
        let store = CCHubRegistry.shared.windowStore(for: hub.id)
        // 断线也用上一份：断开态照样画那台电脑、写「某某现在连不上」
        let client = try? CCHubRegistry.shared.route(hub.id).get()
        let info = client?.hubInfo.map(TerminalHostInfo.init(hello:))
        let link = links[hub.id] ?? .unplugged
        let seen = seenEngines[hub.id] ?? []
        let claude = mascotFace(.claude, installed: info?.claudeInstalled, store: store, seen: seen)
        let codex = mascotFace(.codex, installed: info?.codexInstalled, store: store, seen: seen)
        var rows = [TerminalCRTScreen.Row(text: "> hub online", color: 0x87D6B0)]
        for (engine, face) in [(TerminalEngine.claude, claude), (.codex, codex)] where face != nil {
            let dot = agentDot(engine, store: store)
            let status = dot?.statusText ?? "空闲"
            let color: UInt = dot == .waiting ? 0xFFB05E : dot == .done ? 0x87D6B0 : 0x9fbcae
            rows.append(TerminalCRTScreen.Row(text: "> \(engine.rawName) · \(status)", color: color))
        }
        return TerminalSceneHost(
            id: hub.id,
            primary: primary,
            name: hub.name,
            link: link,
            device: CCHubRegistry.shared.lastKnownDevice(for: hub.id) ?? info?.deviceClass ?? .allInOne,
            modelName: info?.modelName,
            hostName: info?.hostName,
            claude: claude,
            codex: codex,
            screenTitle: info?.hostName?.uppercased() ?? (primary ? "MY-COMPUTER" : hub.name.uppercased()),
            screenRows: rows,
            lastSeen: link == .broken ? client?.lastAliveAt : nil,
            needsPairing: model.isMultiHub && hub.status == .needsPairing
        )
    }

    /// 电脑上有这个引擎就放吉祥物：hub 说没装才不放；不知道时按这台上出现过它的窗口 / 对话判。
    /// 有 Agent 等你或跑完了 = ^ ^，其余正常脸（没连上的 x.x 由场景按连接状态画）
    private func mascotFace(_ engine: TerminalEngine, installed: Bool?, store: TerminalWindowStore?,
                            seen: Set<TerminalEngine>) -> TerminalMascotFace? {
        if installed == false { return nil }
        if installed == nil && !engineSeen(engine, store: store, seen: seen) { return nil }
        let dot = agentDot(engine, store: store)
        return dot == .waiting || dot == .done ? .happy : .normal
    }

    private func engineSeen(_ engine: TerminalEngine, store: TerminalWindowStore?, seen: Set<TerminalEngine>) -> Bool {
        if seen.contains(engine) { return true }
        guard let store else { return false }
        if (store.windows + store.closed).contains(where: { TerminalEngine.forWindow(reported: $0.engine) == engine }) { return true }
        return store.sessionStates.contains { TerminalEngine.forAgentSession($0.key, reported: $0.value.engine) == engine }
    }

    /// 这个引擎最要紧的状态：等你 > 跑完了 > 在干活
    private func agentDot(_ engine: TerminalEngine, store: TerminalWindowStore?) -> TerminalDot? {
        guard let store else { return nil }
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
        case .remote(let hub): computerAction(hub)
        case .claude(let hub), .codex(let hub):
            // Agent 设置只主 hub（B5）；附加那台的吉祥物 = 在那台开新的
            if hub == CCHubRegistry.primaryId {
                settingsPage = item
            } else if links[hub] == .connected {
                model.open(engine: item == .claude(hub) ? "claude" : "codex", hub: hub)
            } else {
                reconnect(hub)
            }
        case .ghost: addComputer()
        }
    }

    /// 再接一台：主电脑还没配过对 → 先配主电脑（原来那页）；配过了 → 新增一台（扫码落到哪台由 classifyPairing 认，B4.3）
    private func addComputer() {
        if links[CCHubRegistry.primaryId] == .unplugged { model.showConnect = true } else { model.addingHub = true }
    }

    // MARK: 三格

    private var cells: some View {
        VStack(spacing: 6) {
            cell(.phone, title: "手机里的小电脑", detail: phoneDetail, action: "新终端 ›", off: false) {
                model.openLocal()
            }
            if model.isMultiHub {
                ForEach(hostRows, id: \.hubId) { hostRow($0) }
            } else {
                cell(.shell, title: "我的电脑", detail: computerDetail,
                     action: link == .connected ? "新 shell ›" : "接上我的电脑 ›", off: link != .connected) {
                    computerAction(hubId)
                }
                cell(.claude, title: "Agent", detail: claudeMissing ? "电脑上还没装 Claude Code" : agentDetail,
                     action: link == .connected ? "新 Claude Code ›" : "接上我的电脑 ›", off: link != .connected || claudeMissing) {
                    if link != .connected {
                        model.showConnect = true
                    } else if claudeMissing {
                        ToastCenter.shared.show(Self.claudeMissingToast)
                    } else {
                        model.open(engine: "claude")
                    }
                }
            }
        }
    }

    private static let claudeMissingToast = "电脑上还没装 Claude Code：Mac 上「让手机连这台 Mac」页有安装命令"

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
        link == .connected && model.client?.currentHubInfo?.tools.claude == false
    }

    private var agentDetail: String {
        let count = model.tabItems.filter { $0.engine.cell == .agent }.count
        return count > 0 ? "住在电脑上 · \(count) 个开着" : "住在电脑上"
    }

    /// 点电脑：接上了在那台开 shell；≥2 台断了就地重连；其余进配对页
    private func computerAction(_ hub: String) {
        if model.isMultiHub, model.hubs.first(where: { $0.id == hub })?.status == .needsPairing {
            model.rescanningHub = hub
            return
        }
        switch links[hub] ?? .unplugged {
        case .connected: model.open(engine: nil, hub: hub)
        case .broken where model.isMultiHub: reconnect(hub)
        default: model.showConnect = true
        }
    }

    /// 「重新连接」：现在就重连那台，不等退避；那台用不了（待配对 / 换了机器）就说要重新配对
    private func reconnect(_ hub: String) {
        switch CCHubRegistry.shared.route(hub) {
        case .success(let client) where client.hasCandidates: client.reconnectNow()
        case .success: model.showConnect = true
        case .failure: ToastCenter.shared.show("\(model.hubs.first { $0.id == hub }?.name ?? "这台电脑")要重新配对")
        }
    }

    private func cell(_ mark: TerminalEngine, title: String, detail: String, action: String, off: Bool,
                      perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            TerminalCellChip(engine: mark, size: 14)
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

    // MARK: 一台电脑一行（≥2 台）

    private var hostRows: [TerminalHostRow] {
        model.hubs.map { hub in
            let client = try? CCHubRegistry.shared.route(hub.id).get()
            return TerminalHostRow(hubId: hub.id, name: hub.name, link: links[hub.id] ?? .unplugged,
                                   claudeInstalled: client?.currentHubInfo?.tools.claude, lastSeen: client?.lastAliveAt, status: hub.status)
        }
    }

    private func hostRow(_ row: TerminalHostRow) -> some View {
        let connected = row.link == .connected
        return HStack(spacing: 10) {
            // 名字那半边：点了 3D 拉近聚焦这台
            HStack(spacing: 10) {
                Circle()
                    .fill(connected ? Palette.mint : row.link == .broken ? Palette.berry : Palette.placeholder)
                    .frame(width: 7, height: 7)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(connected ? TerminalChrome.ink : Color(hex: 0xb9b2ab))
                    // 断了的那行「N 分钟前还在」按分钟走
                    TimelineView(.periodic(from: .now, by: row.lastSeen == nil ? 3600 : 30)) { context in
                        Text(row.lastSeen == nil ? row.detail : TerminalLastSeen.broken(row.lastSeen, now: context.date))
                            .font(.system(size: 11.5))
                            .foregroundColor(row.link == .broken ? Palette.berry : TerminalChrome.dim)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { sceneFocus = .remote(row.hubId) }
            HStack(spacing: 5) {
                ForEach(row.buttons, id: \.self) { hostButton($0, row: row) }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private func hostButton(_ button: TerminalHostRow.Button, row: TerminalHostRow) -> some View {
        switch button {
        case .shell:
            pillButton(.shell, "shell") { model.open(engine: nil, hub: row.hubId) }
        case .claude(let enabled):
            pillButton(.claude, "Claude Code", enabled: enabled) {
                if enabled { model.open(engine: "claude", hub: row.hubId) } else { ToastCenter.shared.show(Self.claudeMissingToast) }
            }
        case .reconnect:
            pillButton(nil, "重新连接", tint: Palette.berry) { reconnect(row.hubId) }
        case .pair:
            pillButton(nil, "去配对", tint: Palette.apricot) {
                if row.hubId == CCHubRegistry.primaryId { model.showConnect = true } else { model.managingHub = row.hubId }
            }
        case .rescan:
            pillButton(nil, "重新扫码", tint: Palette.apricot) { model.rescanningHub = row.hubId }
        }
    }

    private func pillButton(_ mark: TerminalEngine?, _ title: String, tint: Color = Palette.mint, enabled: Bool = true,
                            perform: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let mark { TerminalCellChip(engine: mark) }
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(tint)
                .lineLimit(1)
        }
        .padding(.leading, mark == nil ? 12 : 7)
        .padding(.trailing, mark == nil ? 12 : 9)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture(perform: perform)
    }

    // MARK: 最近

    /// 所有电脑混排；≥2 台时连不上那台的条目变灰写「连不上」
    private var recentSources: [TerminalRecentSource] {
        model.hubStores.map { hub, store in
            TerminalRecentSource(hubId: hub, windows: store.windows, closed: store.closed,
                                 agents: agents.filter { $0.hubId == hub }, states: store.sessionStates,
                                 stale: store.isStale, offline: model.isMultiHub && links[hub] != .connected,
                                 needsPairing: model.isMultiHub && model.hubs.first { $0.id == hub }?.status == .needsPairing)
        }
    }

    @ViewBuilder
    private var recents: some View {
        let items = TerminalRecents.merge(recentSources)
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
            TerminalCellChip(engine: item.engine)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundColor(TerminalChrome.ink)
                .lineLimit(1)
            if let name = model.hubName(item.hubId) { TerminalHubTag(name: name, size: 10.5) }
            Spacer(minLength: 8)
            Text(trailing(item))
                .font(.system(size: 11.5))
                .foregroundColor(item.offline ? Palette.berry : item.dot.flatMap { $0 == .dead ? nil : $0.color } ?? TerminalChrome.dim)
        }
        .opacity(item.offline ? 0.45 : 1)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .onTapGesture { open(item) }
    }

    private func trailing(_ item: TerminalRecentItem) -> String {
        if item.offline { return item.needsPairing ? "要重新配对" : "连不上" }
        if let dot = item.dot, dot != .dead { return dot.statusText }
        let time = TerminalTimestamp.relative(item.date)
        if case .closedWindow = item.kind { return "收起 · \(time)" }
        return time
    }

    /// 连不上那台的条目照样点进去：窗口里是断桥卡
    private func open(_ item: TerminalRecentItem) {
        switch item.kind {
        case .window(let code):
            model.select(.window(hub: item.hubId, code: code))
        case .closedWindow(let code):
            model.openClosed(code, hub: item.hubId)
        case .agent(let session):
            let ref = TerminalAgentRef(hubId: item.hubId, session: session)
            model.pinnedAgent = ref
            model.select(ref.target)
        }
    }

    /// 绑了 Agent 的对话：按非 optional 字段缩范围（profileId / isTrashed）+ 最近打开排序取一小段，
    /// optional 的 ccBridgeSessionName 在内存里筛（SwiftData optional 谓词会静默查不到）。
    /// 不先截掉等你回复的（b4 #7）：前 4 个之外正等你回复的也留着，「最近」合并时提到最前；最近 60 个以外的按会话名定向补进来
    private func loadAgents() {
        guard let profileId else { agents = []; seenEngines = [:]; return }
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == profileId && !$0.isTrashed },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 60
        let conversations = (try? modelContext.fetch(descriptor)) ?? []
        let hubIds = Set(model.hubs.map(\.id))
        seenEngines = agentEngines(profileId: profileId, hubIds: hubIds)
        let waiting = waitingSessions
        var found = TerminalRecents.agents(conversations, hubIds: hubIds)
        let missing = TerminalRecents.missingWaiting(waiting, in: found)
        if !missing.isEmpty {
            var all = FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == profileId && !$0.isTrashed })
            all.propertiesToFetch = [\.ccBridgeSessionName, \.ccHubId]
            let extra = ((try? modelContext.fetch(all)) ?? []).filter { c in
                missing.contains { $0.session == c.ccBridgeSessionName && $0.hubId == CCHubRegistry.hubId(of: c) }
            }
            found += TerminalRecents.agents(extra, hubIds: hubIds)
        }
        agents = TerminalRecents.agentCandidates(found, waiting: waiting)
    }

    /// 各台上现在等你回复的会话
    private var waitingSessions: [(hubId: String, session: String)] {
        model.hubStores.flatMap { hub, store in
            store.sessionStates.compactMap { session, state in state.phase == "waiting" ? (hub, session) : nil }
        }
    }

    /// 本楼层每台电脑上有没有 Claude / Codex 的对话，不受「最近」截断。
    /// 谓词只用非 optional 字段（optional 字段的谓词会静默查不到），只取 session 名 / hub 两列，引擎在内存里按名字判
    private func agentEngines(profileId: String, hubIds: Set<String>) -> [String: Set<TerminalEngine>] {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == profileId && !$0.isTrashed })
        descriptor.propertiesToFetch = [\.ccBridgeSessionName, \.ccHubId]
        var engines: [String: Set<TerminalEngine>] = [:]
        for conversation in (try? modelContext.fetch(descriptor)) ?? [] {
            guard let session = conversation.ccBridgeSessionName else { continue }
            engines[CCHubRegistry.hubId(of: conversation), default: []].insert(TerminalEngine.forAgentSession(session, reported: nil))
            if hubIds.allSatisfy({ engines[$0]?.count == 2 }) { break }
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
                if case .codex = page { CodexSettingsTab() } else { CCSettingsView() }
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
