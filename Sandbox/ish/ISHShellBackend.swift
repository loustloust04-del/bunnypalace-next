import Foundation

/// `run_command` 的 iOS 后端（plan-离线沙箱-phase2 §1.4）：app 内的 Alpine guest。
///
/// 与 macOS 后端的三个本质差异：
///   1. **真隔离**——guest 只看得见 rootfs 和显式 bind mount 进去的东西，文案可以叫「沙箱」
///   2. **不继承 app 环境**——env 是固定白名单，一个密钥都不注入
///      （Minis 把 Keychain 密钥灌进 guest env 是反面教材）
///   3. **必须前台**——切后台/锁屏后系统挂起整个 app，跑着的命令**原地冻结**：既不完成
///      也不报错，回到前台才继续（T4 真机实测推翻了「30s 被杀报 cancelled」的旧说法；
///      模拟器不挂起，跑完 90s sleep 照样 exit 0，不具代表性）
///
/// 放在 `Sandbox/ish/` 而不是 `MemoryPalace/Services/DeviceTools/`：它依赖 `ISHShellExecutor`
/// 这个 ObjC 类，只有 iOS target 编译；放共用 sources 里 macOS 也会编（见
/// project.yml 里两个 target 共用 `MemoryPalace` 那条）。
struct ISHShellBackend: RunCommandBackend {

    var toolDescription: String {
        "在 app 内置的 Linux 沙箱里运行一条 shell 命令（Alpine Linux aarch64，busybox ash）。这是真隔离：命令碰不到沙箱外的任何东西，也没有网络保证。工作目录默认 /root。每次调用是独立进程，无共享会话（cd、变量、后台进程都不跨调用保留）。注意：每条命令有约 200ms 固定开销，别用它做循环里的小操作；app 必须停留在前台：切到后台/锁屏后系统会挂起整个 app，正在跑的命令会**原地冻结**（既不完成也不报错），要等回到前台才继续；系统内存紧张时还可能直接回收 app。所以别起长命令然后让用户切走；`apk add` 装包依赖网络，暂不保证可用。返回 exit_code/stdout/stderr，非零退出码也原样返回。"
    }

    var cwdParamDescription: String {
        "工作目录：沙箱内的绝对路径（如 /tmp），或相对当前楼层文件库挂载点的路径；默认就是该楼层的文件库根 /mnt/library/<楼层>"
    }

    /// 起 guest 前先确保 rootfs 解压好、内核 boot 过（首次 400-1800 ms，之后 <1 ms）
    func prepare() async throws {
        if RootfsManager.shared.didResetWhileBooted {
            throw RunCommandTool.CwdError(message: "沙箱已重置，请重启 app")
        }
        try await Task.detached(priority: .userInitiated) {
            _ = try SandboxRuntime.ensureReady()
        }.value
    }


    /// **iOS cwd 语义定稿（T3a）**
    ///
    /// - 默认 cwd = `/mnt/library/<slug>`（该楼层文件库的挂载点）；挂不上时回落 `/root`
    /// - 用户给的**相对**路径按这个根解析
    /// - 用户给的**绝对**路径原样放行，只挡换行/空字节
    ///
    /// 为什么绝对路径不做宿主式 containment：**guest 命名空间本身就是边界**。
    /// 08-25 探针实证过两个方向都出不去——guest 造的 symlink 在宿主上只是一个内容
    /// 为目标路径的普通文件；宿主造的真 symlink guest 也不跟随；`../..` 只走到 guest 根
    /// （probe-report 步骤 6A/6B）。所以再抄一遍 macOS 那套前缀比对没有安全收益，
    /// 只会把「让 AI 去 /tmp 里干活」这类正常用法误伤掉。
    /// 真正的边界在**挂了什么**：只挂 `filesystem/`，`.memorypalace/` 天然在外。
    func resolveCwd(_ raw: String?, profileId: String) -> Result<String, RunCommandTool.CwdError> {
        if let raw, raw.contains("\0") || raw.contains("\n") {
            return .failure(RunCommandTool.CwdError(message: "cwd 不能包含换行或空字节"))
        }
        // 绝对路径：原样放行
        if let raw, raw.hasPrefix("/") { return .success(raw) }

        // 相对路径 / 缺省：先把该楼层的文件库挂上，拿到根
        let root: String
        switch SandboxMount.mount(profileId: profileId) {
        case .mounted(let guestPath):
            root = guestPath
        case .skippedICloud:
            root = "/root"
        case .refusedSymlinkEscape(let paths):
            print("[ISHShellBackend] 库里有越界 symlink，拒挂，cwd 回落 /root：\(paths)")
            root = "/root"
        case .failed(let msg):
            print("[ISHShellBackend] 挂载失败，cwd 回落 /root：\(msg)")
            root = "/root"
        }
        guard let raw, !raw.isEmpty else { return .success(root) }
        return .success(root + "/" + raw)
    }

    /// 工具结果里的补充说明（R4：iCloud 楼层挂不进沙箱要如实告诉模型）
    func resultNote(profileId: String) -> String? {
        if FileLibraryStore.iCloudEnabled, FileLibraryStore.iCloudFloorsRoot() != nil {
            return "当前楼层开了 iCloud 同步，暂时不能挂进沙箱；工作目录回落到 /root，要读写文件库请用 fs_* 工具。"
        }
        let escapes = SandboxMount.escapingSymlinks(in: FileLibraryStore.libraryRoot(profileId: profileId))
        if !escapes.isEmpty {
            let list = escapes.prefix(10).joined(separator: "、")
            let more = escapes.count > 10 ? "（共 \(escapes.count) 个，只列前 10 个）" : ""
            return "文件库里有指向库外的符号链接，为安全起见没有挂进沙箱，工作目录回落到 /root：\(list)\(more)。"
                 + "请在「文件」App 里把它们删掉或改成普通文件后重试；这期间要读写文件库请用 fs_* 工具。"
        }
        return nil
    }

    /// **固定白名单**，不继承 app 环境、不注入任何 MP 密钥。
    /// 后半截那批是上游 fork 长期踩坑的沉淀（`ISHKernel.m:1063-1123`），别当可有可无的调参删掉。
    func environment() -> [String: String] {
        [
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "TERM": "dumb",             // 非交互管道，别让程序以为有终端
            "LANG": "C.UTF-8",
            "CHARSET": "UTF-8",
            "TZ": Self.posixTimeZone(),
            "NO_COLOR": "1",
            // 上游 workaround：模拟器里这些运行时的默认行为会踩 emulation 的坑
            "OPENSSL_armcap": "0",
            "GODEBUG": "asyncpreemptoff=1",
            "GOMAXPROCS": "2",
            "PYTHONMALLOC": "malloc",
            "PYTHONDONTWRITEBYTECODE": "1",
        ]
    }

    /// POSIX TZ 格式 + 固定名字：musl 的 TZ 解析器认不了 "GMT+8" 这种带 +/- 的缩写
    /// （抄 `ISHKernel.m:1027-1042`；注意 POSIX 的符号是**反的**，东八区写 LCL-8）。
    private static func posixTimeZone() -> String {
        let secs = TimeZone.current.secondsFromGMT()
        let hrs = secs / 3600
        let mins = abs(secs % 3600) / 60
        return mins != 0 ? String(format: "LCL%+d:%02d", -hrs, mins) : String(format: "LCL%+d", -hrs)
    }

    func spawn(command: String, cwd: String, env: [String: String]) throws -> any RunCommandHandle {
        // 命令走 stdin 管道喂给 /bin/sh，不做 shell 引用拼接（多行 / 特殊字符都安全）。
        // 三个细节抄自 OpenMinis（GPL-3.0）ISHExecutionCoordinator.swift:277-311，每个都有事故背书：
        //  1. `cd <cwd>` 单独一行——ash 没有 chdir 参数
        //  2. `{ exec 0</dev/null; } 2>/dev/null || true` 让子进程 stdin 立刻 EOF，
        //     否则 stdio 类子进程会继承这根用完的管道并永远挂着；`2>/dev/null` 只
        //     静音 exec 内建自己（/dev/null 可能不在 meta.db 里），命令本身的 stderr 照常回来
        //  3. **subshell 闭括号前必须有换行**——命令以 heredoc 终止符结尾时，
        //     `…\nEOF)` 会让 ash 永远认不出终止符，确定性地报
        //     `unexpected end of file (expecting ")")`
        let script = "cd \(cwd)\n({ exec 0</dev/null; } 2>/dev/null || true; \(command)\n)\n"
        let handle = ISHGuestHandle(start: Date())
        let pid = ISHShellExecutor.executeExecutable(
            "/bin/sh",
            arguments: nil,
            environment: env,
            stdinData: Data(script.utf8),
            lineCallback: { line, isStdErr in handle.appendLine(line, isStdErr: isStdErr) },
            completion: { result in handle.finish(result) }
        )
        guard pid > 0 else {
            throw NSError(domain: "ISHShellBackend", code: Int(pid),
                          userInfo: [NSLocalizedDescriptionKey: "沙箱里起不来进程（错误码 \(pid)）"])
        }
        handle.pid = pid
        return handle
    }

    /// guest 侧杀树：按 pgid **或**祖先链匹配（busybox ash 有时把 subshell 塞进新进程组，
    /// 只扫 pgid 会漏掉 `sleep` 这类孙子进程——`ISHShellExecutor.m:555-` 的实现注释）
    func killTree(_ pid: pid_t) {
        guard pid > 0 else { return }
        ISHShellExecutor.killProcessGroup(Int32(pid))
    }
}

/// 一条 guest 命令的句柄。`ISHShellExecutor` 的回调都在主队列上来，这里只做加锁写缓冲 +
/// 信号量唤醒；真正等待发生在后台线程的 `waitAndCollect` 里（主队列不被阻塞）。
final class ISHGuestHandle: RunCommandHandle {
    var pid: pid_t = 0
    let start: Date

    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private let stdoutBuf = BoundedOutput()
    private let stderrBuf = BoundedOutput()
    private var result: ISHShellExecutionResult?
    private var finished = false

    init(start: Date) { self.start = start }

    fileprivate func appendLine(_ line: String, isStdErr: Bool) {
        lock.lock()
        (isStdErr ? stderrBuf : stdoutBuf).appendLine(line)
        lock.unlock()
    }

    fileprivate func finish(_ r: ISHShellExecutionResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }   // once 守卫：超时分支也会 signal
        finished = true
        result = r
        lock.unlock()
        done.signal()
    }

    func waitAndCollect(timeout: TimeInterval) -> RunCommandOutcome {
        var outcome = RunCommandOutcome()
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            outcome.timedOut = true
            ISHShellExecutor.killProcessGroup(pid)
            // 给 completion 一点时间把已收到的输出交上来，拿不到就用现有缓冲
            _ = done.wait(timeout: .now() + 1.0)
        }
        // 命令结束 = 整棵树结束（不允许从这里派生常驻进程；guest 里没有 launchd 可以托孤）
        ISHShellExecutor.killProcessGroup(pid)

        lock.lock()
        let r = result
        outcome.stdout = stdoutBuf.text
        outcome.stderr = stderrBuf.text
        lock.unlock()

        if !outcome.timedOut {
            if let r {
                switch r.error {
                case .none:
                    // ⚠️ ISHShellExecutionResult.exitCode 是 **Linux wait status 字**，
                    // 不是退出码：它一路来自 ish 的 exit_hook(task, code)（ISHKernel.m:475-488）。
                    // 直接当退出码用的后果（T2 探针实测）：`exit 3` 报 768（=3<<8），
                    // `kill -TERM $$` 报 exit_code=15 且 ok=true（信号被当成退出码，
                    // 模型会以为命令成功了）。解码方式必须与 macOS 后端逐位一致。
                    let status = Int32(r.exitCode)
                    let termSig = Int(status & 0x7f)
                    if termSig == 0 {
                        outcome.exitCode = Int((status >> 8) & 0xff)
                    } else {
                        outcome.signal = termSig
                    }
                case .timeout:
                    outcome.timedOut = true
                case .cancelled:
                    outcome.signal = Int(SIGKILL)
                case .processCreationFailed, .execFailed:
                    outcome.exitCode = nil          // 调用方报「退出状态未知」
                @unknown default:
                    outcome.exitCode = nil
                }
                // executor 自己的 output/errorOutput 是全量字符串，只在逐行回调没喂到东西时兜底，
                // 否则会把有界压缩过的内容再放大一遍
                if outcome.stdout.isEmpty && !r.output.isEmpty { outcome.stdout = r.output }
                if outcome.stderr.isEmpty && !r.errorOutput.isEmpty { outcome.stderr = r.errorOutput }
            } else {
                outcome.exitCode = nil
            }
        }
        outcome.durationMs = Int(Date().timeIntervalSince(start) * 1000)
        return outcome
    }
}
