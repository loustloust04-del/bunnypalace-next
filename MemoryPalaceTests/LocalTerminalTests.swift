#if os(macOS)
import XCTest
@testable import 记忆花园

/// plan-mp-local-terminal §5 + R-MT I7：启动参数（纯）+ 真 PTY 会话 + store。真 PTY 用例的 shell 环境全在 tmp（HOME / ZDOTDIR 指 tmp，
/// PATH 只给系统目录），不读她的 dotfiles
final class LocalTerminalLaunchTests: XCTestCase {
    private func env(_ list: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: list.map { entry -> (String, String) in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
    }

    func testLoginShellWithoutCommand() {
        let spec = LocalTerminalLaunch.spec(command: nil, directory: "/tmp", environment: ["SHELL": "/bin/zsh"], home: "/Users/x")
        XCTAssertEqual(spec.executable, "/bin/zsh")
        XCTAssertEqual(spec.args, ["-l"])
        XCTAssertEqual(spec.execName, "-zsh")
        XCTAssertEqual(spec.directory, "/tmp")
        XCTAssertNil(spec.typedCommand)
    }

    /// R-MT I6：POSIX 家族命令进 argv（先跑、结束后留在交互 shell 里）；其余 shell 起好后往 PTY 写
    func testCommandShapePerShellFamily() {
        let zsh = LocalTerminalLaunch.spec(command: "claude --resume 'abc'", directory: "/tmp", environment: ["SHELL": "/bin/zsh"])
        XCTAssertEqual(zsh.args, ["-l", "-i", "-c", "claude --resume 'abc'; exec '/bin/zsh' -l -i"])
        XCTAssertNil(zsh.typedCommand)
        let bash = LocalTerminalLaunch.spec(command: "codex resume 'x'", directory: "/tmp", environment: ["SHELL": "/bin/bash"])
        XCTAssertEqual(bash.args, ["-l", "-i", "-c", "codex resume 'x'; exec '/bin/bash' -l -i"])
        XCTAssertEqual(bash.execName, "-bash")
        XCTAssertEqual(LocalTerminalLaunch.command(bin: "claude", args: ["--resume", "it's"]), "claude '--resume' 'it'\\''s'")
    }

/// 09-15 她报的「有时候打不开」：目录在、但记忆花园没权限读（TCC 没给桌面文件夹），
    /// 这种要退回家目录并把原因带出来，不能把 shell 起在一个读不进去的地方
    func testUnreadableDirectoryFallsBackAndReportsWhy() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-home-\(UUID().uuidString)")
        let locked = FileManager.default.temporaryDirectory.appendingPathComponent("mp-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o000])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
            try? FileManager.default.removeItem(at: home)
        }
        XCTAssertNil(LocalTerminalLaunch.usableDirectory(locked.path), "读不进去的目录不能当工作目录")
        XCTAssertNotNil(LocalTerminalLaunch.usableDirectory(home.path))
        XCTAssertNil(LocalTerminalLaunch.usableDirectory(home.path + "/nope"), "不存在的同理")

        let spec = LocalTerminalLaunch.spec(command: nil, directory: locked.path,
                                            environment: ["SHELL": "/bin/zsh"], home: home.path)
        XCTAssertEqual(spec.directory, home.path, "退回家目录")
        XCTAssertEqual(spec.droppedDirectory, locked.path, "把用不了的那个带出来，好在终端里说明原因")

        let ok = LocalTerminalLaunch.spec(command: nil, directory: home.path,
                                          environment: ["SHELL": "/bin/zsh"], home: home.path)
        XCTAssertNil(ok.droppedDirectory, "正常目录不报")
    }

    func testMissingDirectoryFallsBackToHome() {
        XCTAssertEqual(LocalTerminalLaunch.spec(command: nil, directory: "/nope/nope", environment: ["SHELL": "/bin/zsh"], home: "/Users/x").directory,
                       "/Users/x")
        XCTAssertEqual(LocalTerminalLaunch.spec(command: nil, directory: nil, environment: ["SHELL": "/bin/zsh"], home: "/Users/x").directory, "/Users/x")
    }

    func testShellFallsBackWhenSHELLIsUnusable() {
        let shell = LocalTerminalLaunch.userShell(environment: ["SHELL": "/nonexistent/shell"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell), shell)
    }

    /// R-MT S4：别的终端 / 会话的身份、调试注入、app 自己的目录都不带进去
    func testTerminalEnvironment() {
        let base = ["NO_COLOR": "1", "TERM": "dumb", "PATH": "/x", "LANG": "", "PWD": "/", "OLDPWD": "/a", "CLAUDECODE": "1",
                    "CLAUDE_CODE_ENTRYPOINT": "cli", "TMUX": "/t", "TMUX_PANE": "%1", "TERM_SESSION_ID": "s", "ITERM_PROFILE": "p",
                    "DYLD_INSERT_LIBRARIES": "/lib", "__XPC_DYLD_LIBRARY_PATH": "/x", "OS_ACTIVITY_DT_MODE": "YES", "HOME": "/Users/x"]
        let result = env(LocalTerminalLaunch.terminalEnvironment(base))
        for key in ["NO_COLOR", "PWD", "OLDPWD", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TMUX", "TMUX_PANE", "TERM_SESSION_ID", "ITERM_PROFILE",
                    "DYLD_INSERT_LIBRARIES", "__XPC_DYLD_LIBRARY_PATH", "OS_ACTIVITY_DT_MODE"] {
            XCTAssertNil(result[key], key)
        }
        XCTAssertEqual(result["TERM"], "xterm-256color")
        XCTAssertEqual(result["COLORTERM"], "truecolor")
        XCTAssertEqual(result["TERM_PROGRAM"], "MemoryPalace")
        XCTAssertEqual(result["LANG"], "en_US.UTF-8")
        XCTAssertEqual(result["PATH"], "/x", "其余原样")
        XCTAssertEqual(result["HOME"], "/Users/x")
        XCTAssertEqual(env(LocalTerminalLaunch.terminalEnvironment(["LANG": "zh_CN.UTF-8"]))["LANG"], "zh_CN.UTF-8")
    }

    /// R-MT I2：SwiftTerm 交出的是原始 wait status
    func testExitStatusDecoding() {
        XCTAssertEqual(LocalTerminalLaunch.exitCode(status: 768), 3)
        XCTAssertEqual(LocalTerminalLaunch.exitCode(status: 0), 0)
        XCTAssertEqual(LocalTerminalLaunch.exitCode(status: 9), 137, "SIGKILL = 128 + 9")
    }

    func testProcessNamesMapToAgents() {
        XCTAssertEqual(LocalTerminalLaunch.agent(forProcessName: "claude"), .claudeCode)
        XCTAssertEqual(LocalTerminalLaunch.agent(forProcessName: "codex"), .codex)
        XCTAssertEqual(LocalTerminalLaunch.agent(forProcessName: "cursor-agent"), .cursor)
        XCTAssertNil(LocalTerminalLaunch.agent(forProcessName: "zsh"))
        XCTAssertNil(LocalTerminalLaunch.agent(forProcessName: "node"), "node 包装的认不出就不显示，不猜")
    }

    /// R-MT B1：0 / 负 fd 一律没有前台组
    func testForegroundGroupGuards() {
        XCTAssertNil(LocalTerminalLaunch.foregroundGroup(ptyFD: -1))
        XCTAssertNil(LocalTerminalLaunch.processName(0))
        XCTAssertNil(LocalTerminalLaunch.currentDirectory(of: 0))
        XCTAssertNotNil(LocalTerminalLaunch.currentDirectory(of: getpid()), "本进程的当前目录读得到")
        XCTAssertNotNil(LocalTerminalLaunch.processName(getpid()), "本进程的名字读得到")
        XCTAssertEqual(LocalTerminalLaunch.arguments(of: getpid())?.first, CommandLine.arguments.first, "argv[0] 与本进程一致")
    }

/// B7：往 TUI 里塞一句话——多行 / 长文本要包括号粘贴，ESC 与 CR 要剥掉（R-B7 B1/B6）
    func testPasteBytesForTUI() {
        XCTAssertFalse(LocalTerminalLaunch.needsPasteMode("一句话"))
        XCTAssertTrue(LocalTerminalLaunch.needsPasteMode("第一行\n第二行"), "裸换行会被 TUI 当提交")
        XCTAssertTrue(LocalTerminalLaunch.needsPasteMode(String(repeating: "a", count: 501)))

        XCTAssertEqual(String(decoding: LocalTerminalLaunch.pasteBytes("一句话"), as: UTF8.self), "一句话", "短的原样写")
        XCTAssertEqual(String(decoding: LocalTerminalLaunch.pasteBytes("第一行\n第二行"), as: UTF8.self),
                       "\u{1b}[200~第一行\n第二行\u{1b}[201~")
        XCTAssertEqual(String(decoding: LocalTerminalLaunch.pasteBytes("第一行\r\n第二行"), as: UTF8.self),
                       "\u{1b}[200~第一行\n第二行\u{1b}[201~", "CRLF 归一成 LF，别让内容自己提交")
        XCTAssertEqual(String(decoding: LocalTerminalLaunch.pasteBytes("前\u{1b}[31m后"), as: UTF8.self), "前[31m后",
                       "内容里的 ESC 剥掉，不让它控制终端")
    }

    /// B7 B3：终端里正等她答选择题时，详情页那边不能盲发回车替她选
    func testChoicePromptDetection() {
        XCTAssertTrue(LocalTerminalLaunch.looksLikeChoicePrompt("Do you want to make this edit to foo.swift?"))
        XCTAssertTrue(LocalTerminalLaunch.looksLikeChoicePrompt("❯ 1. Yes\n  2. No"))
        XCTAssertTrue(LocalTerminalLaunch.looksLikeChoicePrompt("Overwrite? (y/n)"))
        XCTAssertFalse(LocalTerminalLaunch.looksLikeChoicePrompt("susu@mac ~ % ls"))
        XCTAssertFalse(LocalTerminalLaunch.looksLikeChoicePrompt(""))
    }

    /// 阶段 B：argv 认会话 id。旗标表与 `CodingSessionResume.invocation(for:)` 同源（R-B B3）
    func testResumedSessionIDFromArgs() {
        let id = "0ddb0348-14da-4d50-b849-ecb20b2e2b09"
        XCTAssertEqual(LocalTerminalLaunch.resumedSessionID(args: ["claude", "--resume", id]), id)
        XCTAssertEqual(LocalTerminalLaunch.resumedSessionID(args: ["claude", "-r", id]), id)
        XCTAssertEqual(LocalTerminalLaunch.resumedSessionID(args: ["codex", "resume", id]), id, "codex 是子命令位")
        XCTAssertEqual(LocalTerminalLaunch.resumedSessionID(args: ["kimi", "--session", id]), id)
        XCTAssertEqual(LocalTerminalLaunch.resumedSessionID(args: ["copilot", "--resume=\(id)"]), id, "= 连写")
        XCTAssertEqual(LocalTerminalLaunch.resumedSessionID(args: ["agy", "--conversation=\(id)"]), id)
        XCTAssertEqual(LocalTerminalLaunch.resumedSessionID(args: ["hermes", "--profile", "work", "--resume", id]), id,
                       "前面还有别的旗标也认得出")

        XCTAssertNil(LocalTerminalLaunch.resumedSessionID(args: ["claude", "--resume"]), "后面没值")
        XCTAssertNil(LocalTerminalLaunch.resumedSessionID(args: ["claude", "-c"]), "裸续跑没有 id")
        XCTAssertNil(LocalTerminalLaunch.resumedSessionID(args: ["claude", "--resume", "--verbose"]), "后面是另一个旗标")
        XCTAssertNil(LocalTerminalLaunch.resumedSessionID(args: ["claude", "--resume", "short"]), "太短不认")
        XCTAssertNil(LocalTerminalLaunch.resumedSessionID(args: ["claude", "--resume", "claude-code:abc12345"]),
                     "带冒号的是 key 不是 native id")
        XCTAssertNil(LocalTerminalLaunch.resumedSessionID(args: ["vim", "/etc/shells"]))
    }

    func testMemoryPalaceIsTheFirstResumeTarget() {
        for agent in CodingAgent.allCases {
            XCTAssertEqual(CodingResumeTarget.memoryPalace.supports(agent), CodingSessionResume.canResume(agent), "\(agent)")
        }
        XCTAssertEqual(CodingResumeTarget.installed(for: .claudeCode).first, .memoryPalace)
        XCTAssertEqual(CodingResumeTarget.memoryPalace.displayName, "记忆花园")
    }
}

/// 收 SIGHUP 的计数（B1 守卫用例装在本进程上）
nonisolated(unsafe) private var hangupsReceived = 0

@MainActor
final class LocalTerminalSessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-local-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// shell 只读 tmp 里的配置：HOME / ZDOTDIR 指 tmp，PATH 只给 tmp/bin 与系统目录
    private var environment: [String: String] {
        ["SHELL": "/bin/zsh", "HOME": dir.path, "ZDOTDIR": dir.path, "PATH": "\(dir.appendingPathComponent("bin").path):/usr/bin:/bin",
         "NO_COLOR": "1"]
    }

    private func session(_ command: String?) -> LocalTerminalSession {
        let session = LocalTerminalSession(directory: dir.path, command: command, title: nil, origin: .shell, environment: environment)
        session.view.setFrameSize(NSSize(width: 800, height: 480))   // 像挂进面板那样给尺寸 → 立刻起
        return session
    }

    private func wait(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    private func screen(_ session: LocalTerminalSession) -> String {
        let terminal = session.view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
    }

    private func diagnose(_ s: LocalTerminalSession) -> String {
        let fd = s.view.process.childfd
        let raw = fd >= 0 ? tcgetpgrp(fd) : -9
        let group = LocalTerminalLaunch.foregroundGroup(ptyFD: fd)
        let members = group.map { LocalTerminalLaunch.processes(inGroup: $0) } ?? []
        let names = members.map { "\($0):\(LocalTerminalLaunch.processName($0) ?? "nil")" }
        return "fd=\(fd) tcgetpgrp=\(raw) getpgrp=\(getpgrp()) shell=\(s.view.process.shellPid) group=\(String(describing: group)) members=\(names) "
            + "state=\(s.state) agent=\(String(describing: s.agent)) screen=[\(screen(s))]"
    }

    /// 回收完（不是僵尸）才算不在了
    private func reaped(_ pid: pid_t) -> Bool {
        pid > 1 && kill(pid, 0) == -1 && errno == ESRCH
    }

    func testCommandOutputAndDecodedExitCode() {
        let s = session("printf 'hi-from-pty'; exit 3")
        XCTAssertTrue(wait { if case .exited = s.state { return true }; return false }, "进程没结束")
        XCTAssertEqual(s.state, .exited(3), "wait status 要解码")
        XCTAssertTrue(screen(s).contains("hi-from-pty"), screen(s))
    }

    /// R-MT I5：没挂进面板也会在 1 s 兜底按像样的尺寸起，不是 2×1
    func testStartsWithASaneSizeEvenWithoutAHost() {
        let s = LocalTerminalSession(directory: dir.path, command: "stty size; exit 0", title: nil, origin: .shell, environment: environment)
        XCTAssertEqual(s.state, .starting, "没尺寸不起")
        XCTAssertTrue(wait { if case .exited = s.state { return true }; return false })
        let size = screen(s).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.range(of: #"^\d+ \d+$"#, options: .regularExpression) != nil }
        let parts = (size ?? "").split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2, screen(s))
        XCTAssertGreaterThanOrEqual(parts.first ?? 0, 5, "行数")
        XCTAssertGreaterThanOrEqual(parts.last ?? 0, 20, "列数")
    }

    func testEnvironmentInsideThePTY() {
        let s = session("printf '[%s:%s]' \"$TERM\" \"$NO_COLOR\"; exit 0")
        XCTAssertTrue(wait { if case .exited = s.state { return true }; return false })
        XCTAssertTrue(screen(s).contains("[xterm-256color:]"), screen(s))
    }

    /// 续跑形态：命令跑完留在那个目录的交互 shell 里
    func testCommandLeavesAnInteractiveShellInTheDirectory() {
        let s = session("true")
        XCTAssertTrue(wait(3) { s.state == .running })
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(s.state, .running, "命令跑完 shell 应当还在")
        s.type("pwd\r")
        XCTAssertTrue(wait { self.screen(s).contains(self.dir.lastPathComponent) }, screen(s))
        s.close()
    }

    /// 前台进程名认 agent（tmp/bin/claude 软链到系统 sleep）；关 tab 后前台进程与 shell 都被回收（不是僵尸）
    func testBadgeRecognisesAgentAndCloseReapsTheProcessGroup() throws {
        // 软链而不是拷贝：系统程序拷到别处执行会被 macOS 启动约束杀掉；软链让二进制留在原位、p_comm 取软链名（原生 claude 的装法同形）
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("bin/claude").path, withDestinationPath: "/bin/sleep")
        let s = session("claude 30")
        var claude: pid_t = 0
        XCTAssertTrue(wait {
            s.refreshBadge()
            if let group = LocalTerminalLaunch.foregroundGroup(ptyFD: s.view.process.childfd) {
                claude = LocalTerminalLaunch.processes(inGroup: group).first { LocalTerminalLaunch.processName($0) == "claude" } ?? 0
            }
            return s.agent == .claudeCode && claude > 0
        }, "前台进程没认出来：\(diagnose(s))")
        let foreground = claude
        let shell = s.view.process.shellPid
        var done = false
        s.close { done = true }
        XCTAssertTrue(wait(5) { done && self.reaped(shell) }, "shell 没被回收")
        XCTAssertTrue(wait(5) { self.reaped(foreground) }, "前台进程没被收掉")
    }

    /// R-I8 I3 闭合档：后台作业不在前台进程组里（徽章看不见），但挂在同一条 pty 上——退出确认要认得出它
    func testBackgroundJobCountsAsRunningEvenThoughTheBadgeCannotSeeIt() {
        let s = session("sleep 30 &")
        XCTAssertTrue(wait {
            s.refreshBadge()
            return s.quitItem.job == "sleep"
        }, "后台作业没认出来：\(diagnose(s))")
        XCTAssertNil(s.agent, "前台是空闲的 shell，徽章本来就不该显示")
        XCTAssertTrue(s.quitItem.isRunning, "退出要问一句")
        XCTAssertEqual(LocalTerminalQuitPrompt.quit([s.quitItem])?.title, "有 1 个终端在跑 sleep")
        s.close()
    }

    /// R-MT B1：shell 先退出、后台持有者还占着 pty 时关 tab，绝不能把 SIGHUP 发回本进程组
    func testClosingAfterTheShellExitedNeverSignalsOurOwnGroup() {
        hangupsReceived = 0
        let previous = signal(SIGHUP) { _ in hangupsReceived += 1 }
        defer { signal(SIGHUP, previous) }
        let s = session("trap '' HUP; sleep 3 & exit 0")
        XCTAssertTrue(wait { if case .exited = s.state { return true }; return false }, "shell 没退出")
        var done = false
        s.close { done = true }
        XCTAssertTrue(wait(3) { done })
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(hangupsReceived, 0, "SIGHUP 发回了本进程组")
    }
}

@MainActor
final class LocalTerminalStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-local-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testOpenCloseSelectionAndPresent() {
        let store = LocalTerminalStore(observeTermination: false,
                                       environment: ["SHELL": "/bin/zsh", "HOME": dir.path, "ZDOTDIR": dir.path, "PATH": "/usr/bin:/bin"])
        let a = store.open(directory: dir.path)
        let b = store.open(directory: dir.path)
        let c = store.open(directory: dir.path)
        XCTAssertEqual(store.selectedID, c, "新开的选中")
        store.close(c)
        XCTAssertEqual(store.selectedID, b, "关掉选中的 → 选相邻的")
        store.selectedID = a
        store.close(b)
        XCTAssertEqual(store.selectedID, a, "关的不是选中的 → 不动")
        let posted = expectation(forNotification: .openLocalTerminalTool, object: nil)
        store.present(directory: dir.path, command: nil, title: "t", origin: .codingSession(key: "k", agent: .codex))
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(store.selected?.origin, .codingSession(key: "k", agent: .codex))
        store.closeAll()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedID)
    }

    /// 阶段 B：按会话 key 找活着的 tab + focus 切过去（详情页「回到终端」走这条）
    func testFindsLiveTabBySessionKeyAndFocusesIt() throws {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("claude").path,
                                                   withDestinationPath: "/bin/sleep")
        let store = LocalTerminalStore(observeTermination: false,
                                       environment: ["SHELL": "/bin/zsh", "HOME": dir.path, "ZDOTDIR": dir.path,
                                                     "PATH": "\(bin.path):/usr/bin:/bin"])
        let key = CodingSessionKey.make(.claudeCode, host: "", nativeId: "0ddb0348-14da-4d50-b849-ecb20b2e2b09")
        let other = store.open(directory: dir.path)
        let mine = store.present(directory: dir.path, command: "claude 30", title: "t",
                                 origin: .codingSession(key: key, agent: .claudeCode))
        XCTAssertEqual(store.session(forKey: key)?.id, mine, "按 key 找得到那个 tab")
        XCTAssertNil(store.session(forKey: CodingSessionKey.make(.codex, host: "", nativeId: "nope1234")), "别的 key 找不到")

        store.selectedID = other
        let posted = expectation(forNotification: .openLocalTerminalTool, object: nil)
        store.focus(mine)
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(store.selectedID, mine, "focus 切过去并把面板拉到前面")

        store.closeAll()
    }

    /// 关 tab：普通 shell 直接关，带命令起的先问一句（plan §8.3）
    func testRequestCloseAsksOnlyWhenSomethingIsRunning() {
        let store = LocalTerminalStore(observeTermination: false,
                                       environment: ["SHELL": "/bin/zsh", "HOME": dir.path, "ZDOTDIR": dir.path, "PATH": "/usr/bin:/bin"])
        let plain = store.open(directory: dir.path)
        store.requestClose(plain)
        XCTAssertNil(store.pendingCloseID, "普通 shell 不问")
        XCTAssertTrue(store.sessions.isEmpty)

        let agent = store.open(directory: dir.path, command: "claude 30")
        XCTAssertEqual(store.sessions.first?.quitItem.startingWithCommand, true, "进程还没起来也算在跑")
        store.requestClose(agent)
        XCTAssertEqual(store.pendingCloseID, agent, "先问")
        XCTAssertEqual(store.sessions.count, 1, "没答之前不关")
        store.close(agent)
        XCTAssertNil(store.pendingCloseID)
        XCTAssertTrue(store.sessions.isEmpty)
    }
}
/// 退出 / 关 tab 确认的判定与文案（plan §8，R-I8 I6：判定也要是纯函数）
final class LocalTerminalQuitPromptTests: XCTestCase {
    private func item(_ agent: CodingAgent?, _ dir: String = "/Users/tester/MemoryPalace", job: String? = nil, starting: Bool = false)
        -> LocalTerminalQuitPrompt.Item {
        .init(agent: agent, job: job, directory: dir, startingWithCommand: starting)
    }

    func testWhatCountsAsRunning() {
        XCTAssertTrue(item(.claudeCode).isRunning, "认出来的 agent")
        XCTAssertTrue(item(nil, starting: true).isRunning, "带命令起、进程还没起来的那一小段也算")
        XCTAssertTrue(item(nil, job: "vim").isRunning, "挂在这条终端上的活都算——挂起的 / 后台的 / vim（R-I8 I3 闭合档）")
        XCTAssertFalse(item(nil).isRunning, "空着的 shell 不算")
        XCTAssertEqual(LocalTerminalQuitPrompt.blocking([item(.claudeCode), item(nil), item(nil, job: "npm"), item(nil, starting: true)]).count, 3)
    }

    func testLabelUsesDirectoryNotTitle() {
        XCTAssertEqual(item(.claudeCode).label, "Claude Code · MemoryPalace")
        XCTAssertEqual(item(nil, "/tmp/wt", job: "vim").label, "vim · wt", "认不出那家就报进程名")
        XCTAssertEqual(item(nil, "/tmp/wt", starting: true).label, "命令 · wt", "还没起来的时候什么都报不出")
        XCTAssertEqual(item(.codex, "/tmp/wt", job: "vim").label, "Codex · wt", "认出来的那家优先")
    }

    func testQuitText() {
        XCTAssertNil(LocalTerminalQuitPrompt.quit([]), "没 tab 不问")
        XCTAssertNil(LocalTerminalQuitPrompt.quit([item(nil), item(nil)]), "只有普通 shell 不问")

        let one = LocalTerminalQuitPrompt.quit([item(.claudeCode), item(nil)])
        XCTAssertEqual(one?.title, "有 1 个终端在跑 Claude Code")
        XCTAssertEqual(one?.body, "退出后会被挂断：\nClaude Code · MemoryPalace")

        let two = LocalTerminalQuitPrompt.quit([item(.claudeCode), item(.codex, "/tmp/vocab")])
        XCTAssertEqual(two?.title, "还有 2 个终端在跑东西")
        XCTAssertEqual(two?.body, "退出后会被挂断：\nClaude Code · MemoryPalace\nCodex · vocab")
    }

    func testQuitTextCapsTheList() {
        let five = LocalTerminalQuitPrompt.quit(Array(repeating: item(.codex, "/tmp/a"), count: 5))
        XCTAssertEqual(five?.body.components(separatedBy: "\n").count, 5, "抬头 + 3 条 + 省略行")
        XCTAssertTrue(five?.body.hasSuffix("…等 5 个") == true, five?.body ?? "nil")
    }

    func testCloseTabText() {
        XCTAssertNil(LocalTerminalQuitPrompt.closeTab(item(nil)))
        XCTAssertEqual(LocalTerminalQuitPrompt.closeTab(item(.codex, "/tmp/vocab"))?.title, "这个终端在跑 Codex")
        XCTAssertEqual(LocalTerminalQuitPrompt.closeTab(item(.codex, "/tmp/vocab"))?.body, "关掉会挂断它：Codex · vocab")
    }

    /// R-I8 B1：注销 / 关机绝不挡；脚本不弹窗（AppleScript 的 quit 会同步等到 AE 超时）；Dock 与真 ⌘Q 一样算她本人
    func testQuitSource() {
        XCTAssertEqual(LocalTerminalQuitPrompt.source(isAppleEventQuit: false, hasQuitReason: false, senderName: nil), .userGesture)
        XCTAssertEqual(LocalTerminalQuitPrompt.source(isAppleEventQuit: true, hasQuitReason: true, senderName: "loginwindow"), .system)
        XCTAssertEqual(LocalTerminalQuitPrompt.source(isAppleEventQuit: true, hasQuitReason: false, senderName: "Dock"), .userGesture)
        XCTAssertEqual(LocalTerminalQuitPrompt.source(isAppleEventQuit: true, hasQuitReason: false, senderName: "osascript"), .automation)
        XCTAssertEqual(LocalTerminalQuitPrompt.source(isAppleEventQuit: true, hasQuitReason: false, senderName: nil), .automation)
    }
}
#endif
