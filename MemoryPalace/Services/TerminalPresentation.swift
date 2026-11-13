import Foundation

/// 终端三格的格标（plan-terminal-three-cells §1）：① 手机里的小电脑 / ② 我的电脑 / ③ Agent。
enum TerminalCell: Int, CaseIterable {
    case phone = 1
    case computer = 2
    case agent = 3
}

/// 窗口里跑的是什么。只决定格标和面板上的引擎名，标题仍走 `TerminalTitle`。
enum TerminalEngine: Equatable {
    case claude
    case codex
    case shell
    /// 手机里的小电脑（iSH，#045 T2）。只在 App 本地出现，hub 不会报这个
    case phone

    /// 对话绑定的 Agent session：状态帧报了就信它；帧到之前按名字前缀判（T24：codex 对话别先显示成 claude）
    static func forAgentSession(_ name: String, reported: String?) -> TerminalEngine {
        if let engine = parse(reported) { return engine }
        return name.hasPrefix("mp-codex-") ? .codex : .claude
    }

    /// 全局窗口：没报 engine 的按裸 shell 算（老 hub 下恒 nil）
    static func forWindow(reported: String?) -> TerminalEngine {
        parse(reported) ?? .shell
    }

    private static func parse(_ raw: String?) -> TerminalEngine? {
        switch raw {
        case "claude": return .claude
        case "codex": return .codex
        case "shell": return .shell
        default: return nil
        }
    }

    /// 喂给 `TerminalTitle.resolve` 的 engine 参数
    var rawName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .shell: return "shell"
        case .phone: return "ish"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "shell"
        case .phone: return "小电脑"
        }
    }

    var cell: TerminalCell {
        switch self {
        case .claude, .codex: return .agent
        case .shell: return .computer
        case .phone: return .phone
        }
    }
}

/// 状态点。idle 不画（「没事不说话」）；死 / stale 压过 phase —— 连不上的窗口报什么 phase 都不可信。
enum TerminalDot: Equatable {
    case waiting
    case working
    case done
    case dead

    static func resolve(phase: String?, dead: Bool) -> TerminalDot? {
        if dead { return .dead }
        switch phase {
        case "waiting": return .waiting
        case "working": return .working
        case "done": return .done
        default: return nil
        }
    }

    var statusText: String {
        switch self {
        case .waiting: return "等你回复"
        case .working: return "在干活"
        case .done: return "跑完了"
        case .dead: return "停了"
        }
    }
}

enum TerminalNames {
    /// 重名自动编号：第一个保留原名，后面的「claude 2」「claude 3」。编号避开已经被别人占用的名字。
    static func numbered(_ titles: [String]) -> [String] {
        var taken = Set(titles)
        var seen: [String: Int] = [:]
        return titles.map { title in
            guard let count = seen[title] else {
                seen[title] = 1
                return title
            }
            var n = count + 1
            while taken.contains("\(title) \(n)") { n += 1 }
            seen[title] = n
            let name = "\(title) \(n)"
            taken.insert(name)
            return name
        }
    }
}

enum TerminalTimestamp {
    /// hub 写的是 `toISOString()`（带毫秒），app 乐观收起写的是不带毫秒的，两种都认。
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "昨天" }
        return "\(Int(seconds / 86_400)) 天前"
    }
}

/// 绑了 Agent 的对话（「最近」里的一种来源）
struct TerminalAgentConversation: Equatable {
    let session: String
    let title: String
    let openedAt: Date
    /// 对话绑的那台 hub（plan-multi-hub B2.8；B1 之前都是主 hub）
    var hubId: String = CCBridgeWebSocketClient.primaryHubId
}

struct TerminalRecentItem: Equatable {
    enum Kind: Equatable {
        case window(code: String)
        case closedWindow(code: String)
        case agent(session: String)
    }

    let kind: Kind
    /// 在哪台 hub 上（「最近」混排所有电脑，plan-multi-hub B4.2c）
    let hubId: String
    let title: String
    /// 出哪个小标记（螃蟹 / Codex 分开）
    let engine: TerminalEngine
    let date: Date
    let dot: TerminalDot?
    /// ≥2 台时那台连不上：条目变灰写「连不上」
    var offline = false
    /// 连不上是因为那台待配对：写「要重新配对」（跟首页那行一个说法）
    var needsPairing = false
}

/// 一台电脑给「最近」的料
struct TerminalRecentSource {
    let hubId: String
    var windows: [TerminalWindowInfo] = []
    var closed: [TerminalWindowInfo] = []
    var agents: [TerminalAgentConversation] = []
    var states: [String: TerminalStateEntry] = [:]
    var stale = false
    /// 只在 ≥2 台时给 true（1 台断线照旧：点变灰、右边写时间）
    var offline = false
    var needsPairing = false
}

/// 首页「最近」：每台的开着的窗口（createdAt）+ 收起的（closedAt）+ 绑了 Agent 的对话（lastOpenedAt），混排；
/// 等你回复的固定排最前，其余按时间倒序，取前几条。
enum TerminalRecents {
    static func merge(_ sources: [TerminalRecentSource], limit: Int = 4) -> [TerminalRecentItem] {
        var items: [TerminalRecentItem] = []
        for source in sources {
            let dead = source.stale || source.offline
            for window in source.windows {
                guard let date = TerminalTimestamp.parse(window.createdAt) else { continue }
                items.append(windowItem(window, source: source, kind: .window(code: window.code), date: date,
                                        dot: TerminalDot.resolve(phase: window.phase, dead: dead || !window.alive)))
            }
            for window in source.closed {
                guard let date = TerminalTimestamp.parse(window.closedAt) else { continue }
                items.append(windowItem(window, source: source, kind: .closedWindow(code: window.code), date: date, dot: nil))
            }
            for agent in source.agents {
                let state = source.states[agent.session]
                items.append(TerminalRecentItem(
                    kind: .agent(session: agent.session),
                    hubId: source.hubId,
                    title: agent.title,
                    engine: TerminalEngine.forAgentSession(agent.session, reported: state?.engine),
                    date: agent.openedAt,
                    dot: TerminalDot.resolve(phase: state?.phase, dead: source.offline || state.map { !$0.alive } ?? false),
                    offline: source.offline,
                    needsPairing: source.needsPairing
                ))
            }
        }
        let sorted = items.sorted { a, b in
            let aw = a.dot == .waiting, bw = b.dot == .waiting
            return aw != bw ? aw : a.date > b.date
        }
        return Array(sorted.prefix(limit))
    }

    /// 绑了会话、打开过、绑的是名单里某台电脑的对话（条目带 hub），按传进来的顺序（最近打开在前）
    static func agents(_ conversations: [Conversation], hubIds: Set<String>,
                       hubOf: (Conversation) -> String = CCHubRegistry.hubId(of:)) -> [TerminalAgentConversation] {
        conversations.compactMap { conversation in
            let hub = hubOf(conversation)
            guard hubIds.contains(hub), let session = conversation.ccBridgeSessionName, let openedAt = conversation.lastOpenedAt else { return nil }
            return TerminalAgentConversation(session: session, title: conversation.title, openedAt: openedAt, hubId: hub)
        }
    }

    /// 给「最近」的 Agent 候选（b4 #7）：照旧最近打开的前 limit 个，再补上排在后面、正等你回复的会话（每个会话一条）——
    /// 先截再置顶会把第 5 个等你回复的截掉
    static func agentCandidates(_ agents: [TerminalAgentConversation], waiting: [(hubId: String, session: String)],
                                limit: Int = 4) -> [TerminalAgentConversation] {
        var picked = Array(agents.prefix(limit))
        for agent in agents.dropFirst(limit) where waiting.contains(where: { $0.hubId == agent.hubId && $0.session == agent.session })
            && !picked.contains(where: { $0.hubId == agent.hubId && $0.session == agent.session }) {
            picked.append(agent)
        }
        return picked
    }

    /// 等你回复的 (hub, session) 里，候选里还没有的（最近 N 个对话以外的）：要定向补取它们的对话
    static func missingWaiting(_ waiting: [(hubId: String, session: String)], in agents: [TerminalAgentConversation]) -> [(hubId: String, session: String)] {
        waiting.filter { w in !agents.contains { $0.hubId == w.hubId && $0.session == w.session } }
    }

    private static func windowItem(_ window: TerminalWindowInfo, source: TerminalRecentSource, kind: TerminalRecentItem.Kind,
                                   date: Date, dot: TerminalDot?) -> TerminalRecentItem {
        let engine = TerminalEngine.forWindow(reported: window.engine)
        return TerminalRecentItem(
            kind: kind,
            hubId: source.hubId,
            title: TerminalTitle.resolve(title: window.title, engine: engine.rawName, code: window.code),
            engine: engine,
            date: date,
            dot: dot,
            offline: source.offline,
            needsPairing: source.needsPairing
        )
    }
}

/// 名单变了（删了一台）终端页要收的尾（b4 #6）：固定的 Agent / 当前停的 / 弹着的窗都不能还指着删掉的那台。nil = 不在 hub 上（首页 / 小电脑）
enum TerminalHubPrune {
    static func isGone(_ hubId: String?, hubs: Set<String>) -> Bool {
        guard let hubId else { return false }
        return !hubs.contains(hubId)
    }
}

/// 小电脑和手机之间是什么状态（首页 3D 场景的三种画法）
enum TerminalLinkState: Equatable {
    /// 从没配过对
    case unplugged
    case connected
    /// 配过对，现在连不上
    case broken
}

/// 首页下半截「一台电脑一行」（≥2 台时，plan-multi-hub B4.2b）：灯 + 名字 + 接没接上 + 右边的按钮
struct TerminalHostRow: Equatable {
    enum Button: Hashable {
        case shell
        /// 没装 Claude Code（hub 明说）→ 置灰
        case claude(enabled: Bool)
        case reconnect
        /// 从没配过对
        case pair
        /// 待配对 / 换了机器：重新扫码（B7.2 B3，跟管理页一致）
        case rescan
    }

    let hubId: String
    let name: String
    let link: TerminalLinkState
    let detail: String
    let buttons: [Button]
    /// 断了时那台最后还在的时间（界面按分钟刷新 detail 用）
    let lastSeen: Date?

    /// claudeInstalled：hello 报的工具探测，nil = 不知道（不拦）；lastSeen：断了时那台最后还在的时间（client.lastAliveAt）；
    /// status：那台待配对 / 换了机器时不说「连不上」、不给「重新连接」（点了也连不了），给「重新扫码」
    init(hubId: String, name: String, link: TerminalLinkState, claudeInstalled: Bool?, lastSeen: Date? = nil,
         status: CCHubRegistry.Status = .ready, now: Date = Date()) {
        self.hubId = hubId
        self.name = name
        self.link = link
        self.lastSeen = link == .broken && status == .ready ? lastSeen : nil
        switch status {
        case .needsPairing:
            detail = "要重新配对"
            buttons = [.rescan]
            return
        case .identityChanged:
            detail = "连上的是另一台电脑，先停住了"
            buttons = [.rescan]
            return
        case .ready:
            break
        }
        switch link {
        case .connected:
            detail = "已接上"
            buttons = [.shell, .claude(enabled: claudeInstalled != false)]
        case .broken:
            detail = TerminalLastSeen.broken(lastSeen, now: now)
            buttons = [.reconnect]
        case .unplugged:
            detail = "还没接上"
            buttons = [.pair]
        }
    }
}

/// 断了的那台怎么说（首页电脑行 / 底部条 / 管理这台）：「连不上 · 3 分钟前还在」；这次启动没连上过 = 「连不上」
enum TerminalLastSeen {
    static func broken(_ lastSeen: Date?, now: Date = Date()) -> String {
        guard let lastSeen else { return "连不上" }
        return "连不上 · \(TerminalTimestamp.relative(lastSeen, now: now))还在"
    }
}

/// ＋ 菜单 / ⌘T 新窗口开在哪台（≥2 台时 ＋ 菜单顶上「在哪台」）：记住上次选的，那台删了 / 没选过 = 主电脑
enum TerminalHubChoice {
    static let key = "terminalLastHubId"

    static func load(_ defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: key) }

    static func save(_ id: String, _ defaults: UserDefaults = .standard) { defaults.set(id, forKey: key) }

    static func resolve(_ stored: String?, hubs: [String]) -> String {
        guard let stored, hubs.contains(stored) else { return CCHubRegistry.primaryId }
        return stored
    }
}
