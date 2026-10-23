#if os(macOS)
import Darwin
import Foundation

/// 本地终端的启动参数（plan-mp-local-terminal A1，纯函数、可单测）：登录 shell 的 argv / 环境 / 工作目录、续跑命令怎么交给 shell、
/// 前台进程组与进程名 → 编程 agent、进程当前目录、wait status 解码。只从本进程环境派生，不注入 MP 的任何东西；与 cc 桥无关
enum LocalTerminalLaunch {
    struct Spec: Equatable {
        let executable: String
        let args: [String]
        /// argv[0]：登录 shell 惯例 `-zsh`
        let execName: String
        let environment: [String]
        let directory: String
        /// 非 POSIX shell（fish / nu…）起普通登录 shell 后往 PTY 写的那一行；nil = 命令已在 argv 里 / 没有命令
        let typedCommand: String?
        /// 要的目录用不了（不存在或读不进去）时记在这儿，起来之后在终端里说明一句；nil = 用的就是要的那个
        var droppedDirectory: String?
    }

    /// `-c "<run>; exec <shell> -l -i"` 成立的 shell（R-MT I6）；其余退回往 PTY 写命令
    static let posixShells: Set<String> = ["zsh", "bash", "sh", "ksh", "dash"]

    /// 用户的登录 shell：`$SHELL`，不在就查账户数据库，再兜底 /bin/zsh
    static func userShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    /// 无命令 = 登录交互 shell；有命令：POSIX 家族先跑它、结束后留在交互 shell 里（与 Ghostty 续跑同形），其余 shell 起好后往 PTY 写这一行。
    /// 目录一律走 forkpty 的工作目录，命令里不带 cd
    static func spec(command: String?, directory: String?, environment: [String: String],
                     home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Spec {
        let shell = userShell(environment: environment)
        let name = (shell as NSString).lastPathComponent
        var args = ["-l"]
        var typed: String?
        if let command, !command.isEmpty {
            if posixShells.contains(name) {
                args = ["-l", "-i", "-c", "\(command); exec \(CodingShellQuote.single(shell)) -l -i"]
            } else {
                typed = command
            }
        }
        let wanted = directory.flatMap { $0.isEmpty ? nil : $0 }
        let dir = wanted.flatMap { usableDirectory($0) } ?? home
        return Spec(executable: shell, args: args, execName: "-\(name)", environment: terminalEnvironment(environment), directory: dir,
                    typedCommand: typed, droppedDirectory: dir == wanted ? nil : wanted)
    }

    /// 一条续跑命令：`bin` + 单引号参数（R-MT I6：不带 `cd … &&`，目录交给 forkpty）
    static func command(bin: String, args: [String]) -> String {
        ([bin] + args.map(CodingShellQuote.single)).joined(separator: " ")
    }

    /// 不带进交互终端的环境变量（R-MT S4）：别的终端 / 会话的身份、调试注入、app 自己的目录
    static func isStripped(_ key: String) -> Bool {
        let exact: Set<String> = ["NO_COLOR", "PWD", "OLDPWD", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_SESSION_ID", "OS_ACTIVITY_DT_MODE"]
        if exact.contains(key) { return true }
        return ["TMUX", "ITERM_", "DYLD_", "__XPC_"].contains { key.hasPrefix($0) }
    }

    /// 交互终端的环境：本进程环境去掉 `isStripped` 的，终端能力按真终端报；其余原样
    static func terminalEnvironment(_ base: [String: String]) -> [String] {
        var env = base.filter { !isStripped($0.key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "MemoryPalace"
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// 前台进程名 → 编程 agent（只认进程名；node / python 包装的认不出就不显示，不猜）
    static func agent(forProcessName name: String) -> CodingAgent? {
        switch name.lowercased() {
        case "claude": return .claudeCode
        case "codex": return .codex
        case "kimi": return .kimi
        case "gemini": return .gemini
        case "cursor-agent": return .cursor
        case "opencode": return .opencode
        case "grok": return .grok
        case "pi": return .pi
        case "omp": return .omp
        case "qodercli": return .qoder
        case "hermes": return .hermes
        case "openclaw": return .openclaw
        case "kiro-cli": return .kiro
        case "dsh": return .dsh
        case "copilot": return .copilot
        default: return nil
        }
    }

    /// PTY 前台进程组（R-MT B1：会话首进程退出后 `tcgetpgrp` 回 0——0 / 1 / 本进程组一律当没有，绝不拿去发信号）
    static func foregroundGroup(ptyFD: Int32) -> pid_t? {
        guard ptyFD >= 0 else { return nil }
        let group = tcgetpgrp(ptyFD)
        guard group > 1, group != getpgrp() else { return nil }
        return group
    }

    /// 进程组里的全部进程。`-c` 跑的命令与 shell 同组（组长就是 shell），交互 shell 的作业自成一组——徽章要看组员，不能只看组长
    static func processes(inGroup group: pid_t) -> [pid_t] {
        guard group > 1 else { return [] }
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    // MARK: - 往 TUI 里塞一句话（阶段 B7）

    /// 多行或长文本要走括号粘贴：TUI 把裸换行当「提交」，一句话会被截成好几条发出去（cc 桥 `hub.ts:384-400` 的旧账）
    static func needsPasteMode(_ text: String) -> Bool {
        text.contains("\n") || text.count > 500
    }

    /// 写进 PTY 的字节：清掉 ESC 与 CR（别让内容自己控制终端 / 提前提交），需要时用 `ESC[200~ … ESC[201~` 包起来
    static func pasteBytes(_ text: String) -> [UInt8] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .filter { $0 != "\u{1b}" }
        guard needsPasteMode(clean) else { return Array(clean.utf8) }
        return Array("\u{1b}[200~\(clean)\u{1b}[201~".utf8)
    }

    /// 粘贴完到发回车之间要等的秒数（cc 桥 `PASTE_SETTLE_DELAY_S`：claude 的 `[Pasted text #N]` widget 异步渲染，
    /// settle 之前到的 Enter 会被吞）+ 回车之后多久回头看一眼还在不在
    static let pasteSettle: TimeInterval = 0.5
    static let pasteVerify: TimeInterval = 0.4
    /// 输入框里还留着这个 = 那次回车被吞了，要补发（cc 桥 `PASTE_PLACEHOLDER`）
    static let pastePlaceholder = "[Pasted text"

    /// 终端此刻是不是在等她答一道选择题（claude 的权限框之类）——是的话别让详情页那边盲发回车替她选（R-B7 B3）
    static func looksLikeChoicePrompt(_ screen: String) -> Bool {
        let markers = ["Do you want to", "❯ 1.", "1. Yes", "(y/n)", "[y/N]", "Continue?"]
        return markers.contains { screen.contains($0) }
    }

    /// 这个目录能不能当工作目录：既要在、又要**读得进去**。
    /// 存在但读不了是常态——TCC：记忆花园没拿到「桌面文件夹」权限时，`~/Desktop/…` 下的项目 `fileExists` 为真、
    /// `opendir` 却是 EPERM，shell 起在那儿之后每条命令都炸（09-15 她截图里的 brew 报错就是这个）
    static func usableDirectory(_ path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let handle = opendir(path) else { return nil }
        closedir(handle)
        return path
    }

    /// 一条命令续的是哪个会话（argv → native id；阶段 B）。旗标表与 `CodingSessionResume.invocation(for:)` 同源——
    /// 那边发什么这边就要认什么：`--resume <id>`（claude / grok / cursor / omp / qoder / hermes）、`resume <id>`（codex）、
    /// `--session <id>`（opencode / pi / kimi）、`--resume=<id>`（copilot）、`--conversation=<id>`（antigravity）。加一家两边一起改。
    /// 认不出回 nil（宁可不绑，绑错会把两条会话串在一起）
    static func resumedSessionID(args: [String]) -> String? {
        let flags = ["--resume", "-r", "resume", "--session", "--conversation"]
        for (i, arg) in args.enumerated() {
            if let eq = arg.firstIndex(of: "="), flags.contains(String(arg[arg.startIndex..<eq])) {
                if let id = validID(String(arg[arg.index(after: eq)...])) { return id }
                continue
            }
            guard flags.contains(arg), i + 1 < args.count else { continue }
            if let id = validID(args[i + 1]) { return id }
        }
        return nil
    }

    /// native id 的形状：不是选项、够长、不含冒号（key 用冒号分段，`CodingSessionKey.nativeId` 的口径）
    private static func validID(_ value: String) -> String? {
        guard !value.hasPrefix("-"), value.count >= 8,
              value.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
        return value
    }

    /// 把这条 pty 当控制终端的全部进程（除 shell 自己）：**前台组之外的也算**——Ctrl-Z 挂起的、`claude &` 起的、
    /// tmux 里跑的，退出时它们照样收到挂断，所以退出确认要按这个口径问（R-I8 I3 闭合档，她 09-15「接受」噪音）。
    /// 走内核按 tty 过滤（`KERN_PROC_TTY`），不遍历全表；只在退出 / 关 tab 时算一次，不进 1 Hz 徽章那条路
    static func processes(onPTY ptyFD: Int32, excluding shell: pid_t) -> [pid_t] {
        guard ptyFD >= 0, let slave = ptsname(ptyFD) else { return [] }
        var info = stat()
        guard stat(slave, &info) == 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(info.st_rdev))]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 4)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map(\.kp_proc.p_pid).filter { $0 > 1 && $0 != shell }
    }

    /// 进程名 = argv[0] 的末段（软链名，与在终端里敲的一致）；argv[0] 是 node / bun / deno / python 这类解释器时取脚本（第一个非选项参数）
    /// 的末段——npm / uv 装的 agent 就是这么起的（R-MT S2）。都取不到退回 p_comm。
    /// 不能只用 `proc_name` 或 p_comm：两者都是软链背后真文件的名字，原生装的 claude（`~/.local/bin/claude → versions/<版本号>`）会是版本号
    /// （09-14 测试宿主取证：软链 claude → /bin/sleep，p_comm = sleep；`ps` 的 comm 列才是 claude——它读的是 argv）
    static func processName(_ pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        if let argv = arguments(of: pid), let first = argv.first, !first.isEmpty {
            var name = (first as NSString).lastPathComponent
            if name.hasPrefix("-") { name.removeFirst() }   // 登录 shell 的 argv0 `-zsh`
            let interpreters: Set<String> = ["node", "bun", "deno"]
            if interpreters.contains(name) || name.hasPrefix("python"),
               let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                return (script as NSString).lastPathComponent
            }
            return name
        }
        return commandName(pid)
    }

    /// 进程的 argv（`KERN_PROCARGS2`：argc、exec 路径、补零、argv…）；同用户进程才读得到
    static func arguments(of pid: pid_t) -> [String]? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec 路径
        while index < size, buffer[index] == 0 { index += 1 }   // 补零
        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args
    }

    /// p_comm（兜底）
    static func commandName(_ pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }

    /// 进程当前目录（系统 shell 在 `TERM_PROGRAM` 不是 Apple_Terminal 时不发 OSC 7，R-MT S3）
    static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// `waitpid` 的原始 status → 退出码（R-MT I2：SwiftTerm 原样交出，`exit 3` 是 768）；被信号杀 = 128 + 信号
    static func exitCode(status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
#endif
