import Foundation
import Observation

/// 一个全局终端窗口。
///
/// 「全局」= 跟对话无关，从任何对话进 CC 终端页看到的都是同一批。
/// 对话绑定的终端（`Conversation.ccBridgeSessionName`）不归这里管，那条路径没动。
struct TerminalWindowInfo: Identifiable, Equatable, Codable {
    /// 永久身份。UI 上显示的是序号（会随开关漂），这个不漂。
    let code: String
    let createdAt: String
    /// 有值 = 已关闭。tmux session 还活着，能从长按 [+] 的菜单恢复。
    var closedAt: String?
    /// hub 报的 tmux 存活状态。离线时是缓存里的旧值。
    var alive: Bool
    /// 以下三个来自 `terminal_state` 帧和新 hub 的 `list_windows`（老 hub 的 `list_windows` 不带）。都没到时恒 nil，
    /// 标题走 app 侧兜底链（`TerminalTitle.resolve`），状态点不画。
    var title: String?
    var engine: String?
    var phase: String?

    var id: String { code }
    var isClosed: Bool { closedAt != nil }
    var sessionName: String { "mp-win-\(code)" }
}

/// `terminal_state` 帧里的一条（plan §A1 冻结的 schema）。
///
/// hub 把**对话绑定的 session 和全局窗口放在同一个轴上**发下来，两者 `code` 字段的写法不同：
/// 全局窗口是短 code（`3f2a`），对话 session 是完整 session 名（`mp-cc-3f2a`）。这里归一成
/// `Target`，顺手容忍 hub 把窗口写成 `mp-win-3f2a` 的那种写法。
struct TerminalStateEntry: Equatable {
    enum Target: Equatable {
        case window(code: String)
        case session(name: String)
    }

    let target: Target
    var title: String?
    var engine: String?
    var phase: String?
    var alive: Bool

    init(target: Target, title: String? = nil, engine: String? = nil,
         phase: String? = nil, alive: Bool = true) {
        self.target = target
        self.title = title
        self.engine = engine
        self.phase = phase
        self.alive = alive
    }

    init?(frame item: [String: Any]) {
        guard let raw = item["code"] as? String,
              let target = Self.normalize(raw) else { return nil }
        self.init(
            target: target,
            title: item["title"] as? String,
            engine: item["engine"] as? String,
            phase: item["phase"] as? String,
            // 帧里出现 = hub 认为它在；缺字段按活的算（关掉的窗口根本不进这帧）
            alive: item["alive"] as? Bool ?? true
        )
    }

    static func normalize(_ raw: String) -> Target? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("mp-win-") {
            let code = String(raw.dropFirst("mp-win-".count))
            return code.isEmpty ? nil : .window(code: code)
        }
        // mp-cc / mp-cc-xxx：对话绑定的 session，不进排 3 的横滚条（它是左边那个固定项）
        if raw.hasPrefix("mp-") { return .session(name: raw) }
        return .window(code: raw)
    }
}

/// 排 3 标签的显示名。
///
/// **hub 算好的 `title` 是单一真相源**（plan §A3：手动改名 > tmux pane_title > 引擎名 > code），
/// 这里只是 app 侧兜底层 —— 老 hub 不发 title、或帧还没到时，不至于露出一串没意义的 code。
enum TerminalTitle {
    // 不显示对话名（粟粟 08-31：「对话框和终端窗又不是同一个东西」）——
    // 终端窗的身份是它自己的：手动名 > pane_title > 引擎名 > code 后四位。
    static func resolve(title: String?,
                        engine: String?,
                        code: String) -> String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        // engine nil 不猜（全局窗口老 hub 下 engine 恒 nil，多半是 shell）——
        // 对话终端明知自己是 CC，由调用方传 engine 兜底
        if engine == "claude" { return "claude" }
        if engine == "codex" { return "codex" }
        return String(code.suffix(4))
    }

    /// 岛宽有限，尾截。截断了才补省略号。
    static func truncate(_ text: String, limit: Int = 8) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

/// 全局终端窗口的本地缓存 + 跟 hub 对账。
///
/// 粟粟拍的「都存 + 定时同步」：**hub 是真相源**（它知道 tmux 实际死活），
/// 本地存一份只为离线时列表不空。连上就拉，之后 60s 对一次账。
@MainActor
@Observable
final class TerminalWindowStore {
    static let shared = TerminalWindowStore()

    /// 导航里显示的（未关闭的），按创建时间排
    private(set) var windows: [TerminalWindowInfo] = []
    /// 长按 [+] 的「恢复」菜单里显示的
    private(set) var closed: [TerminalWindowInfo] = []
    /// true = 当前列表来自本地缓存，没跟 hub 对上账（离线）。UI 据此标灰。
    private(set) var isStale = true
    /// 对话绑定 session 的状态（`terminal_state` 帧里跟窗口同轴发下来的那部分），key = session 名。
    /// 它们不进 `windows` —— 排 3 的横滚条只放全局窗口，对话终端是左边那个固定项。
    private(set) var sessionStates: [String: TerminalStateEntry] = [:]
    /// 每收到一次 hub 的权威列表（`list_windows` 结果 / `terminal_state` 帧）加 1
    private(set) var syncSeq = 0

    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private let defaultsKey = "terminalWindowsCache"
    @ObservationIgnored private static let syncInterval: TimeInterval = 60

    private init() {
        loadCache()
    }

    // MARK: 同步

    /// 进 CC 终端页时调。拉一次 + 起 60s 对账。
    func startSyncing() {
        refresh()
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 离开 CC 终端页时调，别让定时器空转。
    func stopSyncing() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func refresh() {
        CCBridgeWebSocketClient.shared.listWindows(includeClosed: true) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let all):
                    self.apply(all)
                    self.isStale = false
                    self.saveCache(all)
                    self.syncSeq += 1
                case .failure:
                    // 拉不到就守着缓存，标 stale 让 UI 标灰。绝不清空列表 ——
                    // 网络抖一下就让窗口全消失是最糟的体验。
                    self.isStale = true
                }
            }
        }
    }

    private func apply(_ all: [TerminalWindowInfo]) {
        // 老 hub 的 `list_windows` 不带 title/engine/phase（engine 为 nil）—— 60s 对账不能把 `terminal_state`
        // 填进来的那部分抹掉（否则标题每分钟闪回 code 一次）。新 hub 带了就以它为准。
        let known = knownByCode()
        var merged = all
        for i in merged.indices where merged[i].engine == nil {
            guard let old = known[merged[i].code] else { continue }
            merged[i].title = old.title
            merged[i].engine = old.engine
            merged[i].phase = old.phase
        }
        let sorted = merged.sorted { $0.createdAt < $1.createdAt }
        windows = sorted.filter { !$0.isClosed }
        closed = sorted.filter { $0.isClosed }
    }

    private func knownByCode() -> [String: TerminalWindowInfo] {
        var map: [String: TerminalWindowInfo] = [:]
        for w in windows + closed { map[w.code] = w }
        return map
    }

    /// `terminal_state` 帧到货：**全量替换** windows（hub 是真相源），对话 session 的条目旁路存。
    ///
    /// 帧只带活着的窗口，不带 createdAt —— 已知窗口沿用本地 createdAt（排序不跳），
    /// 没见过的按「刚创建」算（排到最后）。`closed` 一行不动：它归 60s 的
    /// `list_windows(include_closed:)` 对账管，恢复 sheet 要靠它。
    func applyState(_ entries: [TerminalStateEntry]) {
        let known = knownByCode()
        let closedCodes = Set(closed.map(\.code))
        let now = ISO8601DateFormatter().string(from: Date())
        var next: [TerminalWindowInfo] = []
        var sessions: [String: TerminalStateEntry] = [:]

        for entry in entries {
            switch entry.target {
            case .session(let name):
                sessions[name] = entry
            case .window(let code):
                // 本地刚关掉的别让在途帧复活（乐观关闭 → close_window 在飞的窗口期）。
                // hub 那边收到后下一帧就不会再带它；真出现分歧由 60s 对账以 hub 为准修正。
                guard !closedCodes.contains(code) else { continue }
                var info = known[code] ?? TerminalWindowInfo(code: code, createdAt: now, alive: entry.alive)
                info.closedAt = nil
                info.alive = entry.alive
                info.title = entry.title
                info.engine = entry.engine
                info.phase = entry.phase
                next.append(info)
            }
        }

        windows = next.sorted { $0.createdAt < $1.createdAt }
        sessionStates = sessions
        isStale = false
        syncSeq += 1
    }

    // MARK: 操作（乐观更新 + 下次对账修正）

    /// 轻点 [+]：开一个新窗口。`engine` 不传 = 裸 shell（轻点的行为）；长按菜单可指定 claude/codex。
    /// 回调给出新窗口的 code，调用方可以立刻切过去；失败带原因（新 hub 会说缺 tmux / 没装 claude 之类，#046）。
    func open(engine: String? = nil, completion: @escaping (Result<String, CCBridgeRemoteError>) -> Void) {
        CCBridgeWebSocketClient.shared.openWindow(engine: engine) { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.refresh() }
                completion(result)
            }
        }
    }

    /// 关闭 = 从导航收起来。**tmux 不动**，里面跑的东西还活着。
    func close(_ code: String) {
        guard let idx = windows.firstIndex(where: { $0.code == code }) else { return }
        var w = windows.remove(at: idx)
        w.closedAt = ISO8601DateFormatter().string(from: Date())
        closed.append(w)
        CCBridgeWebSocketClient.shared.closeWindow(code: code)
    }

    func restore(_ code: String, completion: @escaping (Result<String, CCBridgeRemoteError>) -> Void) {
        CCBridgeWebSocketClient.shared.restoreWindow(code: code) { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.refresh() }
                completion(result)
            }
        }
    }

    /// 结束 = hub 真 kill tmux。成功后两个列表都删掉它（不再能恢复）。
    func end(_ code: String, completion: ((Result<Void, TerminalWindowEndError>) -> Void)? = nil) {
        CCBridgeWebSocketClient.shared.endWindow(code: code) { [weak self] result in
            Task { @MainActor in
                if case .success = result, let self {
                    self.windows.removeAll { $0.code == code }
                    self.closed.removeAll { $0.code == code }
                    self.saveCache(self.windows + self.closed)
                }
                completion?(result)
            }
        }
    }

    /// 导航里的显示序号。1-based，按创建顺序。code 才是身份，这个只是给眼睛看的。
    func displayIndex(of code: String) -> Int? {
        windows.firstIndex { $0.code == code }.map { $0 + 1 }
    }

    // MARK: 本地缓存

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let cached = try? JSONDecoder().decode([TerminalWindowInfo].self, from: data)
        else { return }
        apply(cached)
    }

    private func saveCache(_ all: [TerminalWindowInfo]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
