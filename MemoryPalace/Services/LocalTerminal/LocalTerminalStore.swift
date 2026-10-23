#if os(macOS)
import AppKit
import Observation

extension Notification.Name {
    /// 本机终端开了 tab、要把「终端」面板拉到前面（ContentView 接）
    static let openLocalTerminalTool = Notification.Name("openLocalTerminalTool")
}

/// 本地终端的全部 tab（plan-mp-local-terminal A3）。关「终端」面板 / 被别的工具顶掉 / 切楼层都只拆 UI，会话在这里继续跑，重开面板 tab 都在。
/// 关掉的 tab 在回收完之前留在 `closing` 里（R-MT I1）；退出 app 时全部 SIGHUP；徽章 1 s 刷一次，只在有 tab 时跑
@MainActor
@Observable
final class LocalTerminalStore {
    static let shared = LocalTerminalStore()

    private(set) var sessions: [LocalTerminalSession] = []
    var selectedID: UUID?
    /// 等她答「要不要关」的那个 tab（放在 store 而不是视图 @State：折叠 / 切 tab / 面板重建都不丢，R-I8 S2）
    var pendingCloseID: UUID?

    @ObservationIgnored private var closing: [UUID: LocalTerminalSession] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    /// 起 shell 用的环境（测试注入 tmp 的 HOME / ZDOTDIR，不读她的 dotfiles）
    @ObservationIgnored private let environment: [String: String]

    init(observeTermination: Bool = true, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        guard observeTermination else { return }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    var selected: LocalTerminalSession? {
        sessions.first { $0.id == selectedID } ?? sessions.last
    }

    @discardableResult
    func open(directory: String?, command: String? = nil, title: String? = nil, origin: LocalTerminalSession.Origin = .shell) -> UUID {
        let session = LocalTerminalSession(directory: directory, command: command, title: title, origin: origin, environment: environment)
        sessions.append(session)
        selectedID = session.id
        startTimerIfNeeded()
        return session.id
    }

    /// 开一个 tab 并把终端面板拉到前面（从编程会话「继续」进来）
    @discardableResult
    func present(directory: String?, command: String?, title: String?, origin: LocalTerminalSession.Origin) -> UUID {
        let id = open(directory: directory, command: command, title: title, origin: origin)
        NotificationCenter.default.post(name: .openLocalTerminalTool, object: nil)
        return id
    }

    /// 退出确认的输入（按当前 tab 顺序投影）
    var quitItems: [LocalTerminalQuitPrompt.Item] { sessions.map(\.quitItem) }

    /// 这条会话此刻有没有还在跑的 tab（阶段 B）。「还在跑」用退出确认那套 tty 宽口径（挂起的 / 后台的 / 带命令还没起来的都算，
    /// R-B B1/B2）。**纯读**——详情页的 body 里会调它，这里刷徽章就是「view update 期间改状态」
    func session(forKey key: String) -> LocalTerminalSession? {
        sessions.first { $0.sessionKey == key && $0.quitItem.isRunning }
    }

    /// 动作路径（「继续」防重复）用这个：先同步刷一次徽章再判，躲开 `agent` 那份 1 Hz 缓存的启动竞态
    func liveSession(forKey key: String) -> LocalTerminalSession? {
        refreshBadges()
        return session(forKey: key)
    }

    /// agent 起来之后再把这句话发给它（阶段 B7：她在详情页对一条没在跑的会话说话 = 先续跑再发）。
    /// 每 0.5 s 看一次，超时就把话交还给调用方（别默默吞了）
    func sendWhenReady(_ id: UUID, text: String, timeout: TimeInterval = 25, onTimeout: @escaping () -> Void) {
        guard let session = sessions.first(where: { $0.id == id }) else { onTimeout(); return }
        session.refreshBadge()
        if session.agent != nil {
            session.send(text)
            return
        }
        guard timeout > 0, session.state != .exited(nil) else { onTimeout(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendWhenReady(id, text: text, timeout: timeout - 0.5, onTimeout: onTimeout)
        }
    }

    /// 选中某个 tab 并把终端面板拉到前面（详情页「回到终端」）
    func focus(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        NotificationCenter.default.post(name: .openLocalTerminalTool, object: nil)
    }

    /// 关 tab 的入口：里面有 agent 在跑就先问一句（`pendingCloseID`），否则直接关（plan §8.3）
    func requestClose(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.refreshBadge()
        if LocalTerminalQuitPrompt.closeTab(session.quitItem) != nil {
            pendingCloseID = id
        } else {
            close(id)
        }
    }

    func close(_ id: UUID) {
        if pendingCloseID == id { pendingCloseID = nil }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        closing[id] = session
        session.close { [weak self] in self?.closing[id] = nil }
        if selectedID == id { selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id }
        if sessions.isEmpty { stopTimer() }
    }

    /// 退出 app：来不及等回收，信号先发出去（进程随后收到主端关闭的 hangup）
    func closeAll() {
        for session in sessions { session.close() }
        sessions.removeAll()
        selectedID = nil
        pendingCloseID = nil
        stopTimer()
    }

    func refreshBadges() {
        for session in sessions { session.refreshBadge() }
    }

    #if DEBUG
    /// 截图用（`--mp-open-terminal-demo`）：一个 tab 跑 vim 看 TUI 渲染，一个 tab 跑软链成 `claude` 的系统 sleep 看徽章；都在家目录（不碰 ~/Desktop 的 TCC）
    func debugDemo() {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("mp-terminal-demo")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        if !FileManager.default.fileExists(atPath: fake.path) {
            try? FileManager.default.createSymbolicLink(atPath: fake.path, withDestinationPath: "/bin/sleep")   // 拷贝会被启动约束杀掉
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // vim 那个后开：选中的 tab 才画得出东西（sleep 那个 tab 一直是空屏——`-c` 跑命令不回显、也没提示符）
        present(directory: home, command: CodingShellQuote.single(fake.path) + " 600", title: nil, origin: .shell)
        open(directory: home, command: "vim -u NONE /etc/shells")
    }

    /// 阶段 B 实拍用（`--mp-bind-terminal-demo`）：给某条会话挂一个「正在跑」的假 tab，详情页就会显示「回到终端」。
    /// 跑的是软链成 `claude` 的系统 sleep，**不碰她真正的 agent**
    func debugBind(key: String, agent: CodingAgent) {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("mp-terminal-demo")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        if !FileManager.default.fileExists(atPath: fake.path) {
            try? FileManager.default.createSymbolicLink(atPath: fake.path, withDestinationPath: "/bin/sleep")
        }
        open(directory: FileManager.default.homeDirectoryForCurrentUser.path,
             command: CodingShellQuote.single(fake.path) + " 600", title: nil,
             origin: .codingSession(key: key, agent: agent))
    }
    #endif

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
#endif
