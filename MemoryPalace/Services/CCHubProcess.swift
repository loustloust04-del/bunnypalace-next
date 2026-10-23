import Foundation
import Combine
import Security

#if os(macOS)
import AppKit

/// cc-bridge hub 子进程管理（v1.1 整合方案）。
///
/// 职责：
/// - 把 bundle 内 hub-arm64/x64 二进制 spawn 成子进程
/// - 用 Application Support/MemoryPalace/cc-bridge/ 作 workdir + secrets dir
/// - 从 Keychain 读/写 hub token（16 字节随机 hex，本机限定 sync=false）
/// - 监听 stdout 第一行 parse 真实端口（hub.ts 输出 {event:"listening",port:N}）
/// - log 环形缓冲 500 条供 UI 显示
/// - 健康检查 watchdog：每 10s curl /health，连续 3 次失败重启 hub（60s 限频防 crash loop）
/// - app 退出时 SIGTERM + 3s 后 SIGKILL
/// - #046：开关开着就随 App 启动自动拉起、退出时停；这台 Mac 已有外部 hub（launchd / 7890 有应答）就一律不起；
///   拿到端口后把 Mac 自己的 WS 连接切过去（App 级，不靠设置页开着）
///
/// 开关本身（enabledByUser AppStorage）在「让手机连这台 Mac」页，手动开关走 `startUnlessExternal()` / `stop()`。
@MainActor
final class CCHubProcess: ObservableObject {
    static let shared = CCHubProcess()

    @Published private(set) var state: State = .idle
    @Published private(set) var port: Int? = nil
    @Published private(set) var lastError: String? = nil
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var startedAt: Date? = nil
    @Published private(set) var restartCount: Int = 0
    /// 这台 Mac 是不是已经有 hub 在跑（launchd 装的 / 7890 有人应答）。nil = 还没查过。true 时内嵌 hub 永远不起（astra P1-2）
    @Published private(set) var externalHub: Bool?

    enum State: String {
        case idle       // 没启动过
        case starting   // 启动中
        case running    // listening 端口已就绪
        case stopped    // 用户主动停止
        case crashed    // 子进程意外退出
        case unhealthy  // 健康检查 3 次失败但限频未到
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let time: Date
        let level: Level
        let text: String
        enum Level: String { case info, warn, error }
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var watchdogTimer: Timer?
    private var consecutiveHealthFailures = 0
    private var lastRestartAt: Date?
    private var stopRequested = false
    private var didAutoStart = false
    /// 在途的「查外部 hub → 起内嵌 hub」，stop() 取消它
    private var launchTask: Task<Void, Never>?
    /// 开关 AppStorage 的 key（「让手机连这台 Mac」页的开关同一个）
    static let enabledKey = "ccHubEnabledByUser"

    private let keychainAccount = "cc-bridge-hub-token"

    private init() {}

    // MARK: - Token（Keychain 16 字节 hex，sync=false 本机限定）

    private func getOrCreateToken() -> String {
        if let existing = KeychainStore.get(account: keychainAccount), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        _ = KeychainStore.set(hex, account: keychainAccount, sync: false)
        log(.info, "generated new hub token (16 bytes)")
        return hex
    }

    var currentToken: String? {
        KeychainStore.get(account: keychainAccount)
    }

    // MARK: - Workdir / Secrets

    private var supportDirURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("cc-bridge", isDirectory: true)
    }

    /// Claude 的家：和思考链 hook 装的是同一个（astra P1-4），不再自己另算一份
    var ccWorkdirURL: URL { CCThinkingHookInstaller.workdir }
    /// Codex 的家（hub 的 codexHome 兜底同一个位置）
    var codexWorkdirURL: URL { supportDirURL.appendingPathComponent("gpt-rp", isDirectory: true) }
    var secretsDirURL: URL { supportDirURL.appendingPathComponent("secrets", isDirectory: true) }

    private func prepareDirectories() {
        for dir in [supportDirURL, ccWorkdirURL, codexWorkdirURL, secretsDirURL] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// bundle 里的 mcp-server（hub 用它现写 mcp 配置，对话 Agent 才有 reply 工具）。没打进包就是 nil，hub 不带 --mcp-config
    private var mcpServerBinaryURL: URL? {
        #if arch(arm64)
        let name = "mcp-server-arm64"
        #else
        let name = "mcp-server-x64"
        #endif
        return Bundle.main.url(forResource: name, withExtension: nil)
    }

    // MARK: - Bundle binary（按运行架构选 arm64 / x64）

    private var hubBinaryURL: URL? {
        #if arch(arm64)
        let name = "hub-arm64"
        #else
        let name = "hub-x64"
        #endif
        return Bundle.main.url(forResource: name, withExtension: nil)
    }

    // MARK: - Lifecycle

    func start() {
        if TestHostIsolation.blocks(.hub) { return }   // #035 / astra 实现审 #8：测试宿主不起子进程
        guard process == nil else { log(.warn, "already running, ignore start()"); return }
        guard let hubURL = hubBinaryURL else {
            lastError = "hub binary not found in app bundle"
            log(.error, lastError!)
            state = .crashed
            return
        }

        log(.info, "starting hub: \(hubURL.lastPathComponent)")
        state = .starting
        stopRequested = false
        // 顺序（astra P1-4）：建家 → 装 hook → 起 hub。新账户第一次开开关时家还不存在，
        // ensureInstalled 会被 fileExists 闸跳过，文字回复靠的 Stop hook 就要等下次开 App 才装上
        prepareDirectories()
        CCThinkingHookInstaller.ensureInstalled()
        let token = getOrCreateToken()

        let p = Process()
        p.executableURL = hubURL
        p.currentDirectoryURL = supportDirURL   // 不再是 /：hub 找 cwd/.mcp.json 不会撞到根目录

        var env = ProcessInfo.processInfo.environment
        env["MP_CC_HUB_PORT"] = "0"                    // OS 分配（hub 记进 hub-config，下次先试同一个）
        env["MP_CC_HUB_HOST"] = "auto"                 // loopback + LAN + Tailscale（同 launchd），不然二维码出不来
        env["MP_CC_HUB_TOKEN"] = token
        env["MP_CC_WORKDIR"] = ccWorkdirURL.path
        env["MP_CODEX_WORKDIR"] = codexWorkdirURL.path
        env["MP_CC_SECRETS_DIR"] = secretsDirURL.path
        if let mcp = mcpServerBinaryURL { env["MP_CC_MCP_SERVER_BIN"] = mcp.path }
        // GUI app spawn 子进程 PATH 不含 brew/npm/bun，手动补
        let home = NSHomeDirectory()
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home)/.bun/bin:\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.parseStdout(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { self?.log(.error, "[stderr] \(text)") }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(exit: proc.terminationStatus)
            }
        }

        do {
            try p.run()
            self.process = p
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            startedAt = Date()
            log(.info, "spawned pid=\(p.processIdentifier)")
            startWatchdog()
        } catch {
            lastError = error.localizedDescription
            log(.error, "spawn failed: \(error.localizedDescription)")
            state = .crashed
        }
    }

    func stop() {
        stopRequested = true
        // 还在查外部 hub 的那次启动一起作废：不然查完照样 start()，开关关着服务却跑起来（astra 实现审 #5）
        launchTask?.cancel()
        launchTask = nil
        stopWatchdog()
        guard let p = process else {
            log(.info, "nothing to stop")
            if state != .idle { state = .stopped }
            return
        }
        log(.info, "SIGTERM pid=\(p.processIdentifier)")
        p.terminate()

        // 3s 内不退就 SIGKILL（防 hub.ts 卡死无法响应）
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            await MainActor.run {
                if let stillRunning = self.process, stillRunning.isRunning {
                    self.log(.warn, "SIGKILL after 3s timeout")
                    kill(stillRunning.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func handleTermination(exit code: Int32) {
        log(.info, "terminated exit=\(code) reason=\(stopRequested ? "user-stop" : "unexpected")")
        process = nil
        port = nil
        startedAt = nil
        stopWatchdog()
        if stopRequested {
            state = .stopped
        } else {
            state = .crashed
        }
    }

    // MARK: - stdout parse

    private func parseStdout(_ raw: String) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            log(.info, s)

            // 尝试 parse {"event":"listening","port":N}
            if state != .running,
               let data = s.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["event"] as? String == "listening",
               let p = json["port"] as? Int {
                port = p
                state = .running
                log(.info, "✅ hub listening on port \(p)")
                followPortWithMainConnection(p)
            }
        }
    }

    // MARK: - #046 外部 hub 闸 / 随 App 启停 / Mac 主连接跟端口

    /// 查一次这台 Mac 有没有外部 hub，结果记进 `externalHub`。测试宿主里不查（不敲 7890），按「没有」回。
    @discardableResult
    func refreshExternalHub() async -> Bool {
        if TestHostIsolation.blocks(.hub) { return false }
        let plist = ExternalHub.plistExists(inLaunchAgents: ExternalHub.userLaunchAgents)
        let responds = plist ? false : await ExternalHub.healthResponds()   // plist 在就不用再敲 7890
        let external = ExternalHub.isExternal(plistExists: plist, healthResponds: responds, embeddedPort: port)
        externalHub = external
        return external
    }

    /// 手动开开关 / 随 App 自动启动都走这里：有外部 hub 就不起，状态页写「这台 Mac 已有 hub 在跑」。
    func startUnlessExternal() {
        if TestHostIsolation.blocks(.hub) { return }
        guard process == nil else { return }
        launchTask?.cancel()
        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let external = await self.refreshExternalHub()
            // 等检查的这段时间里关了开关：stop() 取消了这个 Task；开关当前值也再核一次，关了就不起
            guard !Task.isCancelled, UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
            if external {
                self.log(.info, "这台 Mac 已有 hub 在跑（launchd / 7890），不起内嵌 hub")
                return
            }
            self.start()
        }
    }

    /// App 启动时调一次（幂等）：开关开着就拉起；同时挂上「App 退出就停」。测试宿主里什么都不做（不碰 7890、不起子进程）。
    func autoStartAtLaunch() {
        if TestHostIsolation.blocks(.hub) { return }
        guard NSClassFromString("XCTestCase") == nil, !didAutoStart else { return }
        didAutoStart = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CCHubProcess.shared.stopForTermination() }
        }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        startUnlessExternal()
    }

    /// 退出 App：只发 SIGTERM（进程马上就没了，3 秒后补 SIGKILL 的那个 Task 跑不到也无所谓）
    private func stopForTermination() {
        guard let p = process else { return }
        stopRequested = true
        stopWatchdog()
        p.terminate()
    }

    /// 内嵌 hub 拿到端口：Mac 自己的 WS 连接切过去（原来在设置页 onChange 里，设置页不开就跟不上）
    private func followPortWithMainConnection(_ port: Int) {
        guard let token = currentToken, let url = URL(string: "ws://127.0.0.1:\(port)/cc") else { return }
        CCBridgeWebSocketClient.shared.connect(urls: [url], token: token)
    }

    // MARK: - Log（环形缓冲 500 条）

    private func log(_ level: LogLine.Level, _ text: String) {
        let line = LogLine(time: Date(), level: level, text: text)
        logs.append(line)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    // MARK: - Watchdog（每 10s curl /health，连续 3 次失败重启）

    private func startWatchdog() {
        stopWatchdog()
        consecutiveHealthFailures = 0
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.healthCheck() }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        consecutiveHealthFailures = 0
    }

    private func healthCheck() async {
        guard let port, state == .running else { return }
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                consecutiveHealthFailures = 0
            } else {
                consecutiveHealthFailures += 1
                log(.warn, "health failed status=\((response as? HTTPURLResponse)?.statusCode ?? -1) (\(consecutiveHealthFailures)/3)")
            }
        } catch {
            consecutiveHealthFailures += 1
            log(.warn, "health failed: \(error.localizedDescription) (\(consecutiveHealthFailures)/3)")
        }

        if consecutiveHealthFailures >= 3 {
            // 限频：60s 内最多重启一次，防 crash loop 失控
            if let last = lastRestartAt, Date().timeIntervalSince(last) < 60 {
                log(.error, "3 health failures but last restart < 60s ago, mark unhealthy")
                state = .unhealthy
                return
            }
            log(.error, "3 consecutive health failures, restarting hub (restart #\(restartCount + 1))")
            lastRestartAt = Date()
            restartCount += 1
            consecutiveHealthFailures = 0
            stop()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            start()
        }
    }
}

#endif
