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
}

struct TerminalRecentItem: Equatable {
    enum Kind: Equatable {
        case window(code: String)
        case closedWindow(code: String)
        case agent(session: String)
    }

    let kind: Kind
    let title: String
    let cell: TerminalCell
    let date: Date
    let dot: TerminalDot?
}

/// 首页「最近」：开着的窗口（createdAt）+ 收起的（closedAt）+ 绑了 Agent 的对话（lastOpenedAt），按时间倒序取前几条。
enum TerminalRecents {
    static func merge(
        windows: [TerminalWindowInfo],
        closed: [TerminalWindowInfo],
        agents: [TerminalAgentConversation],
        states: [String: TerminalStateEntry],
        stale: Bool,
        limit: Int = 4
    ) -> [TerminalRecentItem] {
        var items: [TerminalRecentItem] = []
        for window in windows {
            guard let date = TerminalTimestamp.parse(window.createdAt) else { continue }
            items.append(windowItem(window, kind: .window(code: window.code), date: date,
                                    dot: TerminalDot.resolve(phase: window.phase, dead: stale || !window.alive)))
        }
        for window in closed {
            guard let date = TerminalTimestamp.parse(window.closedAt) else { continue }
            items.append(windowItem(window, kind: .closedWindow(code: window.code), date: date, dot: nil))
        }
        for agent in agents {
            let state = states[agent.session]
            let engine = TerminalEngine.forAgentSession(agent.session, reported: state?.engine)
            items.append(TerminalRecentItem(
                kind: .agent(session: agent.session),
                title: agent.title,
                cell: engine.cell,
                date: agent.openedAt,
                dot: TerminalDot.resolve(phase: state?.phase, dead: state.map { !$0.alive } ?? false)
            ))
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }

    private static func windowItem(_ window: TerminalWindowInfo, kind: TerminalRecentItem.Kind,
                                   date: Date, dot: TerminalDot?) -> TerminalRecentItem {
        let engine = TerminalEngine.forWindow(reported: window.engine)
        return TerminalRecentItem(
            kind: kind,
            title: TerminalTitle.resolve(title: window.title, engine: engine.rawName, code: window.code),
            cell: engine.cell,
            date: date,
            dot: dot
        )
    }
}
