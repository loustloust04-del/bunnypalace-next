import Foundation
import Observation

/// 手机里的小电脑的一个交互 shell（#045 T2，plan-terminal-t2 §2.3）。
///
/// 会话持有自己的终端 controller 和视图宿主：切 tab / 翻到别的应用只是把同一个 SwiftTerm 视图摘下、挂回，
/// 屏幕状态（全屏程序、往上翻的历史、各种模式）天然完整，不做字节回放（sol 审 #6）。
/// 只活在 App 进程里：App 被系统关掉 = shell 没了，rootfs 里的文件还在。
@MainActor
@Observable
final class ISHTerminalSession: Identifiable {
    enum State: Equatable {
        case starting
        case running
        /// 退出码；nil = 被信号结束 / 不知道
        case exited(Int32?)
        case failed(String)
    }

    let id: String
    let profileId: String
    var title: String
    private(set) var state: State = .starting

    @ObservationIgnored private(set) var controller: CCTerminalController!
    let host = TerminalHostCache()
    fileprivate let io: ISHSessionIO
    private let sequence: UInt64
    /// 结束后 +1：晚到的启动结果看到对不上就自己收掉
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var events: TerminalBackendEvents?
    /// 第一次 attach 拿到的真实尺寸。拿到之前不开 PTY（免得先按 80×24 出提示符再折行）
    @ObservationIgnored private var firstSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var launchInfo: (startDirectory: String, note: String?)?
    @ObservationIgnored private var launching = false
    /// 启动途中被结束：等启动回来、收掉那个 shell 之后再通知
    @ObservationIgnored private var closedWhileLaunching: [() -> Void] = []

    fileprivate init(id: String, sequence: UInt64, profileId: String) {
        self.id = id
        self.sequence = sequence
        self.profileId = profileId
        self.title = "小电脑"
        self.io = ISHSessionIO()
        self.controller = CCTerminalController(sessionName: id, backend: ISHTerminalBackend(session: self))
        io.deliver = { [weak self] data in self?.events?.onChunk(data) }
        prepare()
    }

    // MARK: 启动

    /// boot + 挂楼层文件库都在后台做，完了等第一次 attach 的尺寸
    private func prepare() {
        let profileId = self.profileId
        let generation = self.generation
        Task.detached(priority: .userInitiated) {
            let result: Result<(String, String?), Error>
            do {
                if RootfsManager.shared.didResetWhileBooted {
                    throw RootfsError.installFailed("小电脑已重置，重启 App 后才能用")
                }
                _ = try SandboxRuntime.ensureReady()
                result = .success(ISHTerminalSession.startDirectory(profileId: profileId))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation, !self.ended else { return }
                switch result {
                case .success(let info):
                    self.launchInfo = info
                    self.launchIfReady()
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 起点：当前楼层的文件库；挂不上就 /root，并说一句为什么
    nonisolated private static func startDirectory(profileId: String) -> (String, String?) {
        let fallback = "，先在 /root 里干活。"
        switch SandboxMount.mount(profileId: profileId) {
        case .mounted(let guestPath):
            return (guestPath, nil)
        case .skippedICloud:
            return ("/root", "这个楼层开了 iCloud 同步，文件库暂时接不进小电脑" + fallback)
        case .refusedSymlinkEscape:
            return ("/root", "文件库里有指向库外的链接，为安全起见没接进来" + fallback)
        case .failed(let message):
            return ("/root", "楼层文件库没接上（\(message)）" + fallback)
        }
    }

    private func launchIfReady() {
        guard !launching, io.ptyId == nil, !ended, let size = firstSize, let info = launchInfo else { return }
        launching = true
        events?.onChunk(LocalShellLaunch.banner(note: info.note))
        let generation = self.generation
        let token = LocalShellLaunch.token(sequence: sequence)
        let arguments = LocalShellLaunch.arguments(startDirectory: info.startDirectory)
        let environment = LocalShellLaunch.environment(base: ISHShellBackend().environment())
        let io = self.io
        ISHTerminalSessionStore.openQueue.async { [weak self] in
            let ptyId = ISHKernel.shared.openPTY(
                withArguments: arguments,
                environment: environment,
                token: token,
                columns: Int32(size.cols),
                rows: Int32(size.rows),
                output: { data in io.ingest(data) },
                exit: { [weak self] status in
                    MainActor.assumeIsolated { self?.didExit(waitStatus: status) }
                }
            )
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.generation == generation, !self.ended else {
                    // 启动途中被结束了：刚起的这个立刻收掉，收完再告诉等着的人
                    let waiters = self?.closedWhileLaunching ?? []
                    self?.closedWhileLaunching = []
                    self?.launching = false
                    io.closeLate(ptyId: ptyId > 0 ? ptyId : nil) { waiters.forEach { $0() } }
                    return
                }
                self.launching = false
                guard ptyId > 0 else {
                    self.state = .failed("小电脑里起不来 shell（错误码 \(ptyId)）")
                    return
                }
                io.started(ptyId: ptyId)
                // 秒退的 shell：退出回调可能比这里先到，那时状态已经是 exited，别盖掉（sol 实现审 #4）
                if self.state == .starting { self.state = .running }
            } }
        }
    }

    // MARK: 给 backend 用

    fileprivate func attach(cols: Int, rows: Int, events: TerminalBackendEvents) {
        self.events = events
        io.flushNow()
        if io.ptyId != nil {
            resize(cols: cols, rows: rows)
        } else {
            if firstSize == nil { firstSize = (cols, rows) }
            launchIfReady()
        }
    }

    fileprivate func resize(cols: Int, rows: Int) {
        if io.ptyId == nil { firstSize = (cols, rows); return }
        io.resize(cols: cols, rows: rows)
    }

    private var isLive: Bool { state == .starting || state == .running }

    /// 键盘输入。退出了：卡片在说，按键静默不发。队列满了在终端里说一声
    fileprivate func send(_ bytes: Data) {
        guard isLive else { return }
        if !io.enqueue(bytes, completion: nil) {
            events?.onChunk(LocalShellLaunch.notice("输入太多了，这段没收下，等它消化一下再贴"))
        }
    }

    /// 粘贴 / Compose：整段真写进 tty 才算送到（sol 实现审 #9），失败草稿要留着
    fileprivate func paste(_ bytes: Data, completion: @escaping (Bool, String?) -> Void) {
        guard isLive else { return completion(false, "shell 已经退出了") }
        let accepted = io.enqueue(bytes) { ok in
            completion(ok, ok ? nil : "小电脑没收完这段")
        }
        if !accepted { completion(false, "输入太多了，等它消化一下再贴") }
    }

    fileprivate var acceptsInput: Bool {
        if case .failed = state { return false }
        return true
    }

    private func didExit(waitStatus: Int32) {
        guard !ended, isLive else { return }
        let termSig = waitStatus & 0x7f
        let code: Int32? = termSig == 0 ? (waitStatus >> 8) & 0xff : nil
        state = .exited(code)
        io.flushNow()
        events?.onChunk(LocalShellLaunch.notice(code.map { "shell 已退出（退出码 \($0)）" } ?? "shell 已结束"))
    }

    // MARK: 结束

    /// 杀掉整棵进程树、回收、放掉 tty。幂等。`onClosed` 在真收干净后（主线程）调
    func end(onClosed: (() -> Void)? = nil) {
        if ended {
            onClosed?()
            return
        }
        ended = true
        generation += 1
        host.tearDown()
        if launching {
            if let onClosed { closedWhileLaunching.append(onClosed) }
            io.close(completion: nil)
        } else {
            io.close(completion: onClosed)
        }
    }
}

/// 跨线程那一半：输出缓冲 + 背压、输入 FIFO + 写泵、PTY id。
/// guest 线程只碰这里，不碰 `ISHTerminalSession`（主 actor）。
final class ISHSessionIO: @unchecked Sendable {
    /// 输出待显示上限。到了就让写的那一方等主线程排空（真 PTY 的背压），不丢字节。
    /// ObjC 那边每块 ≤64KB，所以待显示最多 cap + 64KB
    static let pendingCap = 256 * 1024

    let pumpQueue = DispatchQueue(label: "com.susu.MemoryPalace.ish.pty.pump")

    private struct InputItem {
        let data: Data
        /// 主线程上调：true = 整块写进 tty 了
        let completion: ((Bool) -> Void)?
    }

    private let condition = NSCondition()
    private var pending = Data()
    private var flushScheduled = false
    private var cancelled = false
    private var _ptyId: Int32?
    private var inputQueue: [InputItem] = []
    private var inputQueuedBytes = 0
    private var pumping = false

    /// 主线程上把一批输出交给终端
    @MainActor var deliver: ((Data) -> Void)?

    var ptyId: Int32? {
        condition.lock(); defer { condition.unlock() }
        return _ptyId
    }

    private var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    // MARK: 输出

    /// guest 线程上调。待显示满了就等主线程排空；关掉时立刻放行（丢弃）
    func ingest(_ data: Data) {
        condition.lock()
        while !pending.isEmpty && pending.count + data.count > Self.pendingCap && !cancelled {
            condition.wait()
        }
        guard !cancelled else { condition.unlock(); return }
        pending.append(data)
        let schedule = !flushScheduled
        flushScheduled = true
        condition.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.flushNow() }
            }
        }
    }

    @MainActor func flushNow() {
        condition.lock()
        let batch = pending
        pending = Data()
        flushScheduled = false
        condition.broadcast()
        condition.unlock()
        guard !batch.isEmpty else { return }
        deliver?(batch)
    }

    // MARK: 输入

    func started(ptyId: Int32) {
        condition.lock()
        _ptyId = ptyId
        condition.unlock()
        kickPump()
    }

    /// false = 已关 / 排队的输入太多，这次没收（completion 不会被调）
    func enqueue(_ data: Data, completion: ((Bool) -> Void)?) -> Bool {
        guard !data.isEmpty else {
            if let completion { DispatchQueue.main.async { completion(true) } }
            return true
        }
        condition.lock()
        guard !cancelled, inputQueuedBytes + data.count <= TerminalInputPump.maxQueuedBytes else {
            condition.unlock()
            return false
        }
        inputQueue.append(InputItem(data: data, completion: completion))
        inputQueuedBytes += data.count
        condition.unlock()
        kickPump()
        return true
    }

    private func kickPump() {
        condition.lock()
        guard !pumping, _ptyId != nil, !inputQueue.isEmpty, !cancelled else { condition.unlock(); return }
        pumping = true
        condition.unlock()
        pumpQueue.async { [weak self] in self?.pump() }
    }

    /// 写泵：同步循环，吃不完就等 10ms 再写同一块，顺序不乱
    private func pump() {
        while true {
            condition.lock()
            guard !cancelled, let ptyId = _ptyId, !inputQueue.isEmpty else {
                pumping = false
                condition.unlock()
                return
            }
            let item = inputQueue.removeFirst()
            inputQueuedBytes -= item.data.count
            condition.unlock()

            let outcome = TerminalInputPump.drain(
                item.data,
                again: ISHPTYWriteAgain,
                write: { buf in
                    guard let base = buf.baseAddress else { return 0 }
                    return ISHKernel.shared.ptyWrite(ptyId, bytes: base, length: UInt(buf.count))
                },
                isCancelled: { [weak self] in self?.isCancelled ?? true },
                pause: { usleep(10_000) }
            )
            switch outcome {
            case .done:
                Self.complete([item], ok: true)
            case .cancelled:
                Self.complete([item], ok: false)
            case .gaveUp, .failed:
                // 后面排着的多半也进不去：一起丢掉，在终端里说一声
                condition.lock()
                let dropped = inputQueue
                inputQueue.removeAll()
                inputQueuedBytes = 0
                condition.unlock()
                Self.complete([item] + dropped, ok: false)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.deliver?(LocalShellLaunch.notice("小电脑没响应，刚才那段没送完"))
                    }
                }
            }
        }
    }

    private static func complete(_ items: [InputItem], ok: Bool) {
        let completions = items.compactMap(\.completion)
        guard !completions.isEmpty else { return }
        DispatchQueue.main.async { completions.forEach { $0(ok) } }
    }

    func resize(cols: Int, rows: Int) {
        pumpQueue.async { [weak self] in
            guard let self, !self.isCancelled, let ptyId = self.ptyId else { return }
            ISHKernel.shared.ptyResize(ptyId, columns: Int32(cols), rows: Int32(rows))
        }
    }

    // MARK: 关

    /// 先置取消位（写泵立刻退出、卡在背压上的 guest 写放行），再在写泵队列上排 close（排在已开始的写后面）。
    /// completion（主线程）= 进程树杀完、僵尸回收、tty 放掉
    func close(completion: (() -> Void)?) {
        condition.lock()
        cancelled = true
        let dropped = inputQueue
        inputQueue.removeAll()
        inputQueuedBytes = 0
        pending = Data()
        condition.broadcast()
        condition.unlock()
        Self.complete(dropped, ok: false)
        pumpQueue.async { [weak self] in
            if let ptyId = self?.ptyId { ISHKernel.shared.ptyClose(ptyId) }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// 结束时还在启动，启动回来才拿到 ptyId：照样排在写泵队列上收掉
    func closeLate(ptyId: Int32?, completion: @escaping () -> Void) {
        pumpQueue.async {
            if let ptyId { ISHKernel.shared.ptyClose(ptyId) }
            DispatchQueue.main.async(execute: completion)
        }
    }
}

/// `TerminalBackend` 的小电脑实现：把 controller 的 I/O 接到 `ISHTerminalSession`。
@MainActor
final class ISHTerminalBackend: TerminalBackend {
    private weak var session: ISHTerminalSession?

    init(session: ISHTerminalSession) {
        self.session = session
    }

    var isReachable: Bool { session?.acceptsInput ?? false }
    var emulatorOwnsModes: Bool { true }

    func attach(cols: Int, rows: Int, openedAt: Date?, events: TerminalBackendEvents, onSent: @escaping (Bool) -> Void) {
        session?.attach(cols: cols, rows: rows, events: events)
        onSent(session != nil)
    }

    func resize(cols: Int, rows: Int) {
        session?.resize(cols: cols, rows: rows)
    }

    /// 视图摘下来 shell 照跑，输出照样进同一个 SwiftTerm
    func detach() {}

    func send(_ bytes: Data, completion: @escaping (Error?) -> Void) {
        session?.send(bytes)
        completion(nil)
    }

    /// busybox ash 不开 bracketed paste，多行会逐行执行——和任何真终端里贴给 ash 一样
    func paste(_ text: String, bracketed: Bool, completion: @escaping (TerminalPasteOutcome) -> Void) {
        guard let session else { return completion(.failed("终端已关闭")) }
        var data = Data(text.utf8)
        if bracketed { data = Data("\u{1b}[200~".utf8) + data + Data("\u{1b}[201~".utf8) }
        session.paste(data) { ok, reason in
            completion(ok ? .delivered : .failed(reason ?? "没送到"))
        }
    }

    /// 画面就在本地，没有可重拉的
    func refresh() {}
    func prepareReconnect() {}
}

/// 开着的小电脑终端（最多 4 个）。只活在内存，App 重开就没了。
@MainActor
@Observable
final class ISHTerminalSessionStore {
    static let shared = ISHTerminalSessionStore()
    static let maxSessions = 4
    /// 开 PTY 的专用串行队列（`become_new_init_child` 用线程局部的 current，别和别的线程混用）
    nonisolated static let openQueue = DispatchQueue(label: "com.susu.MemoryPalace.ish.pty.open")

    private(set) var sessions: [ISHTerminalSession] = []
    /// 正在重置小电脑：不许开新的（sol 实现审 #5）
    private(set) var resetting = false
    @ObservationIgnored private var nextSequence: UInt64 = 1

    private init() {}

    var isFull: Bool { sessions.count >= Self.maxSessions }

    /// 同步预占名额。满了 / 正在重置返回 nil
    func open(profileId: String) -> ISHTerminalSession? {
        guard !isFull, !resetting else { return nil }
        let sequence = nextSequence
        nextSequence += 1
        let session = ISHTerminalSession(id: "ish-\(sequence)", sequence: sequence, profileId: profileId)
        sessions.append(session)
        return session
    }

    func session(_ id: String) -> ISHTerminalSession? {
        sessions.first { $0.id == id }
    }

    func end(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index).end()
    }

    /// 重置屏障：先挡住新开，结束全部会话，等每个都真收干净（进程树杀完、tty 放掉）再回调。
    /// 重置失败要调 `finishReset()` 放开
    func beginReset(_ then: @escaping () -> Void) {
        resetting = true
        let all = sessions
        sessions.removeAll()
        let group = DispatchGroup()
        for session in all {
            group.enter()
            session.end { group.leave() }
        }
        group.notify(queue: .main, execute: then)
    }

    func finishReset() {
        resetting = false
    }

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        session(id)?.title = trimmed.isEmpty ? "小电脑" : trimmed
    }
}
