#if os(macOS)
import AppKit
import Darwin
import SwiftTerm

/// 本地终端的一个 tab（plan-mp-local-terminal A2）：本机 PTY 里的一个登录 shell。NSView 由 session 持有——SwiftUI 重建、面板隐藏都不销毁，
/// 缓冲与进程都在。进程在第一次拿到像样的尺寸时才起（R-MT I5）；关闭按「SIGHUP → 等回收 → 关主端 → 超时自己回收」收尾（R-MT B1 / I1）
@MainActor
@Observable
final class LocalTerminalSession: Identifiable {
    enum Origin: Equatable {
        case shell
        /// 从编程会话「继续」进来的（阶段 B 的对话视图按 key 找回这个 tab；徽章认不出进程名时用这家兜底）
        case codingSession(key: String, agent: CodingAgent)
    }

    enum State: Equatable {
        case starting
        case running
        case exited(Int32?)
    }

    enum Activity: Equatable {
        case idle
        /// 近 2 s 有输出
        case busy
        /// 响铃之后、她敲键之前
        case awaiting
    }

    let id = UUID()
    let origin: Origin
    private(set) var directory: String
    private(set) var title: String
    private(set) var state: State = .starting
    /// 前台进程是编程 agent 时的那家；nil = 普通 shell
    private(set) var agent: CodingAgent?
    private(set) var activity: Activity = .idle

    @ObservationIgnored let view: MPLocalTerminalView
    /// 起的时候带了命令（续跑 / demo）：进程还没起来的那一小段里，这个 tab 也算「在跑」（R-I8 I1）
    @ObservationIgnored let startedWithCommand: Bool
    @ObservationIgnored private var pendingSpec: LocalTerminalLaunch.Spec?
    @ObservationIgnored private let explicitTitle: String?
    @ObservationIgnored private var oscTitle: String?
    @ObservationIgnored private var onReaped: [() -> Void] = []
    @ObservationIgnored private var closing = false

    init(directory: String?, command: String?, title: String?, origin: Origin,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        let spec = LocalTerminalLaunch.spec(command: command, directory: directory, environment: environment)
        self.origin = origin
        startedWithCommand = command?.isEmpty == false
        self.directory = spec.directory
        explicitTitle = title
        self.title = title ?? (spec.directory as NSString).lastPathComponent
        pendingSpec = spec
        view = MPLocalTerminalView(frame: .zero)
        let background = NSColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0)   // 与 CC 终端同一底色：暖调近黑
        view.nativeBackgroundColor = background
        view.layer?.backgroundColor = background.cgColor
        view.processDelegate = self
        view.session = self
        // 1 s 内没挂上面板（没拿到尺寸）就按约 80×24 起，别让进程一直不起
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pendingSpec != nil else { return }
            self.view.setFrameSize(NSSize(width: 720, height: 440))
            self.startIfReady(force: true)
        }
    }

    /// 第一次拿到 ≥ 20×5 的尺寸才起进程（R-MT I5：零 frame 起跑是 2×1，shell 的横幅会按 2 列画进回滚区）
    fileprivate func startIfReady(force: Bool = false) {
        guard let spec = pendingSpec else { return }
        let terminal = view.getTerminal()
        guard force || (terminal.cols >= 20 && terminal.rows >= 5) else { return }
        pendingSpec = nil
        view.startProcess(executable: spec.executable, args: spec.args, environment: spec.environment,
                          execName: spec.execName, currentDirectory: spec.directory)
        state = .running
        // 要的目录用不了就说明一句（最常见是 TCC 没给「桌面文件夹」权限：路径在、但读不进去，
        // shell 起在那儿之后 brew / git 全炸）。写进终端本身，她一眼看得见
        if let dropped = spec.droppedDirectory {
            view.feed(text: "\u{1b}[33m⚠︎ 打不开 \(dropped)：记忆花园没有读这个文件夹的权限。"
                + "去「系统设置 › 隐私与安全性 › 文件与文件夹 › 记忆花园」打开对应的文件夹开关（桌面 / 文稿 / 下载），"
                + "然后重开这个 tab。先在家目录开了。\u{1b}[0m\r\n")
        }
        if let typed = spec.typedCommand { view.process.send(data: ArraySlice(Array((typed + "\r").utf8))) }
    }

    /// 往 shell 里敲一段（拖文件进来粘路径用）
    func type(_ text: String) {
        guard state == .running else { return }
        view.process.send(data: ArraySlice(Array(text.utf8)))
    }

    /// 终端此刻画面上的字（发送前看一眼是不是在等她答选择题；发完回头看回车有没有被吞）
    var screenText: String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// 从编程会话那边发一句给这个 tab 里的 agent（阶段 B7）。时序照搬 cc 桥的 paste commit race 兜底
    /// （`cc-bridge/hub.ts:384-400`）：包好 → 等 settle → 回车 → 回头看输入框里还留不留着 `[Pasted text`，留着就补发，最多 3 次。
    /// cc 桥要 capture-pane 才看得见，我们的缓冲就在本进程里
    func send(_ text: String) {
        guard state == .running, view.process.running, !text.isEmpty else { return }
        view.process.send(data: ArraySlice(LocalTerminalLaunch.pasteBytes(text)))
        commitAfterPaste(retriesLeft: 3)
    }

    private func commitAfterPaste(retriesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + LocalTerminalLaunch.pasteSettle) { [weak self] in
            guard let self, self.state == .running, self.view.process.running else { return }
            self.view.process.send(data: ArraySlice(Array("\r".utf8)))
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + LocalTerminalLaunch.pasteVerify) { [weak self] in
                guard let self, self.screenText.contains(LocalTerminalLaunch.pastePlaceholder) else { return }
                self.commitAfterPaste(retriesLeft: retriesLeft - 1)   // 那次回车被吞了
            }
        }
    }

    /// 这个 tab 对应哪条编程会话（阶段 B）：先看「继续」带进来的 origin；没有就看前台进程 argv 里续的是哪条，
    /// 且只有认得出是哪家 agent 时才认（R-B B6）。现算，不进 1 Hz 徽章路径
    var sessionKey: String? {
        if case .codingSession(let key, _) = origin { return key }
        guard let agent, state == .running, view.process.running else { return nil }
        let foreground = LocalTerminalLaunch.foregroundGroup(ptyFD: view.process.childfd)
            .map { LocalTerminalLaunch.processes(inGroup: $0) } ?? []
        for pid in foreground where pid != view.process.shellPid {
            if let args = LocalTerminalLaunch.arguments(of: pid),
               let id = LocalTerminalLaunch.resumedSessionID(args: args) {
                return CodingSessionKey.make(agent, host: "", nativeId: id)
            }
        }
        return nil
    }

    /// 退出 / 关 tab 确认用的投影（判定与文案都在 `LocalTerminalQuitPrompt` 里）。`job` 现算——挂在这条终端上的
    /// 进程要连挂起的 / 后台的一起看，这条 sysctl 只在退出 / 关 tab 时走，不进 1 Hz 徽章那条路
    var quitItem: LocalTerminalQuitPrompt.Item {
        .init(agent: agent, job: job(), directory: directory,
              startingWithCommand: state == .starting && startedWithCommand)
    }

    /// 这条终端上除 shell 外还在跑的东西，取名字：认得出的那家优先（挂起的 claude 也认得出来），否则第一个进程名
    private func job() -> String? {
        guard state == .running, view.process.running else { return nil }
        let names = LocalTerminalLaunch.processes(onPTY: view.process.childfd, excluding: view.process.shellPid)
            .compactMap { LocalTerminalLaunch.processName($0) }
        return names.first { LocalTerminalLaunch.agent(forProcessName: $0) != nil } ?? names.first
    }

    /// 1 s 一次：前台进程组里除 shell 外还有进程在跑 → 认 agent（认不出且是从编程会话进来的，用那家兜底）；最近输出 / 响铃 → 活动；
    /// shell 当前目录 → 目录与标题。只在变化时写
    func refreshBadge(now: Date = Date()) {
        guard state == .running, view.process.running else { return }
        let shell = view.process.shellPid
        var found: CodingAgent?
        if let group = LocalTerminalLaunch.foregroundGroup(ptyFD: view.process.childfd) {
            let running = LocalTerminalLaunch.processes(inGroup: group).filter { $0 != shell }
            if !running.isEmpty {
                found = running.lazy.compactMap { LocalTerminalLaunch.processName($0).flatMap(LocalTerminalLaunch.agent(forProcessName:)) }.first
                if found == nil, case .codingSession(_, let originAgent) = origin { found = originAgent }
            }
        }
        if agent != found { agent = found }
        let next: Activity = view.awaiting ? .awaiting : (now.timeIntervalSince(view.lastOutput) < 2 ? .busy : .idle)
        if activity != next { activity = next }
        if let dir = LocalTerminalLaunch.currentDirectory(of: shell), dir != directory { directory = dir }
        refreshTitle()
    }

    private func refreshTitle() {
        let next = oscTitle ?? explicitTitle ?? (directory as NSString).lastPathComponent
        if title != next { title = next }
    }

    /// 关 tab（R-MT B1 / I1）：前台进程组与 shell 收 SIGHUP → 等 SwiftTerm 回收（2 s）→ terminate 关主端（还占着 pty 的后台持有者收到 hangup）
    /// → 超时的自己回收。done 在收尾后调，调用方这时才释放 session
    func close(done: @escaping () -> Void = {}) {
        if pendingSpec != nil {
            pendingSpec = nil
            state = .exited(nil)
            done()
            return
        }
        guard !closing else { return }
        closing = true
        guard let process = view.process else { done(); return }
        guard process.running else {
            view.terminate()
            done()
            return
        }
        if let group = LocalTerminalLaunch.foregroundGroup(ptyFD: process.childfd) { kill(-group, SIGHUP) }
        let pid = process.shellPid
        if pid > 1 { kill(pid, SIGHUP) }
        onReaped.append { [weak self] in
            self?.view.terminate()
            done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.onReaped.isEmpty else { return }
            self.onReaped.removeAll()
            self.view.terminate()   // SIGTERM shell + 关主端；terminate 取消了 SwiftTerm 的进程监视，得自己回收
            Self.reap(pid)
            self.state = .exited(nil)
            done()
        }
    }

    /// 超时分支的回收：5 s 内等它自己退，还不退就 SIGKILL，最后阻塞收尸（后台队列，不卡界面）
    nonisolated private static func reap(_ pid: pid_t) {
        guard pid > 1 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<50 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
    }

    /// 进程结束（SwiftTerm 已 waitpid 过）：解码退出码，跑挂着的收尾
    fileprivate func processEnded(status: Int32?) {
        state = .exited(status.map(LocalTerminalLaunch.exitCode(status:)))
        agent = nil
        activity = .idle
        let pending = onReaped
        onReaped.removeAll()
        pending.forEach { $0() }
    }
}

extension LocalTerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            self.oscTitle = title.isEmpty ? nil : title
            self.refreshTitle()
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        Task { @MainActor in
            if self.directory != url.path { self.directory = url.path }
            self.refreshTitle()
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.processEnded(status: exitCode) }
    }
}

/// 起跑时机（第一次拿到像样尺寸）、最近输出、响铃「等你」；其余照 SwiftTerm 原样
final class MPLocalTerminalView: LocalProcessTerminalView {
    weak var session: LocalTerminalSession?
    private(set) var lastOutput = Date.distantPast
    fileprivate(set) var awaiting = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        session?.startIfReady()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutput = Date()
        super.dataReceived(slice: slice)
    }

    /// agent 等你时会响铃：记下来给徽章，不响系统提示音（R-MT S1：只由 C0 BEL 触发，OSC 结尾的 BEL 不会进来）
    override func bell(source: Terminal) {
        awaiting = true
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        awaiting = false
        super.send(source: source, data: data)
    }
}
#endif
