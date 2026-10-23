#if os(macOS)
import Foundation
import Darwin

/// `run_command` 的 macOS 后端（plan-离线沙箱-phase1，代码原样从 `RunCommandTool` 搬来）：
/// 在这台 Mac 上跑 `/bin/zsh -c`。**零隔离**——用户可见文案不叫「沙箱」，那个词留给 iOS 的 iSH 后端。
/// 子进程是自己的进程组组长（posix_spawn + SETPGROUP）：超时 / 停止 / 命令结束时 `kill(-pgid)`
/// 整棵树一并回收，不留孤儿（Foundation `Process.terminate()` 只杀 zsh 本身，`sleep 100 &` 会漏）。
struct MacShellBackend: RunCommandBackend {

    var toolDescription: String {
        "在用户的 Mac 上运行一条 shell 命令（/bin/zsh -c）。每次调用是独立进程，无共享会话；命令返回时同一进程组里的后台进程会一并结束（自己 setsid 或交给 launchd 的守护进程不在此列，别指望它们被清理）；工作目录默认是当前楼层的文件库根。适合列目录、搜索、跑脚本、调用命令行工具；改文件库里的文件内容优先用 fs_write/fs_edit（原子写）。返回 exit_code/stdout/stderr，非零退出码也原样返回。"
    }

    var cwdParamDescription: String {
        "工作目录：绝对路径，或相对文件库根的路径；默认文件库根"
    }

    func prepare() async throws {}   // macOS 没有要预热的东西

    /// 相对路径经文件库根 containment（同 `FileLibraryStore.resolve` 语义）；绝对路径放行（macOS 无沙箱，askOnce 已授权整条对话）。
    func resolveCwd(_ raw: String?, profileId: String) -> Result<String, RunCommandTool.CwdError> {
        // 两边都解 symlink 再比前缀：库里一个指向库外的 symlink 不能把 cwd 带出去（B 报告 R5 同款漏，这里先堵）
        let root = FileLibraryStore.libraryRoot(profileId: profileId).standardizedFileURL.resolvingSymlinksInPath()
        let target: URL
        if let raw {
            if raw.hasPrefix("/") {
                target = URL(fileURLWithPath: raw).standardizedFileURL
            } else {
                target = root.appendingPathComponent(raw).standardizedFileURL.resolvingSymlinksInPath()
                guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
                    return .failure(RunCommandTool.CwdError(message: "cwd 不能逃出文件库根（相对路径按库根解析）"))
                }
            }
        } else {
            target = root
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(RunCommandTool.CwdError(message: "cwd 不存在或不是目录：\(target.path)"))
        }
        return .success(target.path)
    }

    /// app 环境 + PATH 前置（GUI app 不含 brew/npm，`CCHubProcess` 同套路）。**不注入 MP 自己的任何密钥。**
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home)/.bun/bin:\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// `/bin/zsh -c command`，stdin=/dev/null，stdout/stderr 各一根管道，chdir cwd，自成进程组，其余 fd 不继承。
    func spawn(command: String, cwd: String, env: [String: String]) throws -> any RunCommandHandle {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw NSError(domain: "RunCommand", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "pipe 失败"]) }

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)   // pgid = 自己的 pid

        let argv = ["/bin/zsh", "-c", command]
        let envp = env.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = Self.withCStrings(argv) { argvPtr in
            Self.withCStrings(envp) { envPtr in
                posix_spawn(&pid, "/bin/zsh", &fa, &attr, argvPtr, envPtr)
            }
        }
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw NSError(domain: "RunCommand", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(rc))])
        }
        return MacSpawned(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0], start: Date(), backend: self)
    }

    /// SIGTERM 整组 → 还有活口再等 200ms → SIGKILL。组已空直接返回。
    func killTree(_ pgid: pid_t) {
        guard pgid > 1 else { return }
        guard kill(-pgid, SIGTERM) == 0 || errno == EPERM else { return }   // ESRCH = 组已空
        usleep(200_000)
        if kill(-pgid, 0) == 0 { kill(-pgid, SIGKILL) }
    }

    fileprivate static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var cstrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cstrs.append(nil)
        defer { cstrs.forEach { free($0) } }
        return cstrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

struct MacSpawned: RunCommandHandle {
    let pid: pid_t
    let stdoutFD: Int32
    let stderrFD: Int32
    let start: Date
    let backend: MacShellBackend

    /// 等退出（轮询 waitpid，50ms）→ 超时杀树 → 结束时无论如何回收进程组 → 收管道。
    func waitAndCollect(timeout: TimeInterval) -> RunCommandOutcome {
        let collector = PipeCollector(fds: [stdoutFD, stderrFD])
        var status: Int32 = 0
        var outcome = RunCommandOutcome()
        let deadline = start.addingTimeInterval(timeout)
        var reaped = false
        var reapedElsewhere = false
        while !reaped {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { reaped = true; break }
            if r < 0 && errno != EINTR { reapedElsewhere = true; break }   // ECHILD：被别处回收，status 不可信
            if Date() >= deadline {
                outcome.timedOut = true
                backend.killTree(pid)
                if waitpid(pid, &status, 0) < 0 { reapedElsewhere = true }
                reaped = true
                break
            }
            usleep(50_000)
        }
        // 命令结束 = 整个进程组结束（不允许从这里派生常驻进程）
        backend.killTree(pid)
        let (out, err) = collector.finish(grace: 1.0)
        outcome.stdout = out
        outcome.stderr = err
        let termSig = Int(status & 0x7f)
        if reapedElsewhere {
            // exitCode / signal 都留 nil：调用方报「退出状态未知」，不拿零初始化的 status 谎报 exit 0
        } else if termSig == 0 {
            outcome.exitCode = Int((status >> 8) & 0xff)
        } else {
            outcome.signal = termSig
        }
        outcome.durationMs = Int(Date().timeIntervalSince(start) * 1000)
        return outcome
    }
}

/// 面板快照：进程组里的进程 + 它们监听的 TCP 端口。纯函数解析，`ps`/`lsof` 文本进、结构出（可单测）。
enum RunPanelSnapshot {
    struct Proc: Identifiable, Equatable { let pid: pid_t; let pgid: pid_t; let etime: String; let comm: String; var id: pid_t { pid } }
    struct Port: Identifiable, Equatable { let port: Int; let pid: pid_t; let comm: String; var id: String { "\(pid):\(port)" } }

    /// `ps -axo pid,pgid,etime,comm` 输出 → 只留 pgids 里的进程
    static func parsePS(_ text: String, pgids: Set<pid_t>) -> [Proc] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4, let pid = pid_t(cols[0]), let pgid = pid_t(cols[1]), pgids.contains(pgid) else { return nil }
            let comm = String(cols[3]).split(separator: "/").last.map(String.init) ?? String(cols[3])
            return Proc(pid: pid, pgid: pgid, etime: String(cols[2]), comm: comm)
        }
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -a -p …` 输出 → 端口；NAME 列形如 `*:8765` / `127.0.0.1:8765`
    static func parseLSOF(_ text: String) -> [Port] {
        var out: [Port] = []
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9, let pid = pid_t(cols[1]),
                  let portStr = cols[8].split(separator: ":").last, let port = Int(portStr) else { continue }
            let p = Port(port: port, pid: pid, comm: String(cols[0]))
            if !out.contains(p) { out.append(p) }
        }
        return out.sorted { $0.port < $1.port }
    }

    /// 跑 ps + lsof（后台线程调）。
    static func take(pgids: Set<pid_t>) -> (procs: [Proc], ports: [Port]) {
        guard !pgids.isEmpty else { return ([], []) }
        let ps = run("/bin/ps", ["-axo", "pid,pgid,etime,comm"])
        let procs = parsePS(ps, pgids: pgids)
        guard !procs.isEmpty else { return ([], []) }
        let pidList = procs.map { String($0.pid) }.joined(separator: ",")
        let lsof = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pidList])
        return (procs, parseLSOF(lsof))
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // 先读到 EOF 再 wait（管道满互等）
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 两根管道各一个后台读线程读到 EOF，有界缓冲用共享层的 `BoundedOutput`。
/// `finish` 最多等 grace 秒（组已被回收，EOF 必到；万一有逃出组的 setsid 进程，超时后放弃并关 fd）。
private final class PipeCollector {
    private let lock = NSLock()
    private var buffers: [Int32: BoundedOutput] = [:]
    private let group = DispatchGroup()
    private let fds: [Int32]

    init(fds: [Int32]) {
        self.fds = fds
        for fd in fds {
            buffers[fd] = BoundedOutput()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n > 0 {
                        let chunk = Data(buf[0..<n])
                        lock.lock(); buffers[fd]?.append(chunk); lock.unlock()
                    } else if n == 0 || errno != EINTR {
                        break
                    }
                }
                group.leave()
            }
        }
    }

    func finish(grace: TimeInterval) -> (String, String) {
        _ = group.wait(timeout: .now() + grace)
        fds.forEach { close($0) }
        lock.lock(); defer { lock.unlock() }
        return (buffers[fds[0]]?.text ?? "", buffers[fds[1]]?.text ?? "")
    }
}
#endif
