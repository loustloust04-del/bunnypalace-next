import Foundation

/// `run_command`（plan-离线沙箱 phase1 + phase2 §1.4）：**共享层**——工具定义 / 执行编排 /
/// 输出清洗 / 截断 / 运行中注册表 / 停止，两端同一份代码。
///
/// 真正跑命令的部分抽成 `RunCommandBackend`：
///   - macOS = `MacShellBackend`（posix_spawn `/bin/zsh -c`，**零隔离**，文案不叫「沙箱」）
///   - iOS   = `ISHShellBackend`（app 内 Alpine guest，真隔离，文案可以叫「沙箱」）
/// 第二个后端不许复制这里的任何东西——`clean` / `truncate` / 有界收集 / envelope /
/// 注册表 / cancel 全在共享层（QA 席点名过）。
enum RunCommandTool {
    static let toolName = "run_command"
    static let defaultTimeout = 120
    static let maxTimeout = 600
    static let maxCommandChars = 4000
    /// stdout / stderr 各自上限；超出保留头尾各半（Minis 同款）
    static let outputCap = 15_000

    #if os(macOS)
    static let backend: any RunCommandBackend = MacShellBackend()
    #else
    static let backend: any RunCommandBackend = ISHShellBackend()
    #endif

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: backend.toolDescription,
            properties: [
                "command": ["type": "string", "description": "要执行的命令，≤4000 字符；更长的先 fs_write 成脚本再运行"],
                "timeout_seconds": ["type": "integer", "description": "超时秒数，默认 120，上限 600"],
                "cwd": ["type": "string", "description": backend.cwdParamDescription],
            ],
            required: ["command"]
        )
    }

    // MARK: 运行中登记（停止按钮 + 「运行」面板用）

    @MainActor private static var running: [String: pid_t] = [:]   // conversationId → pgid（iOS = guest 组长 pid）
    @MainActor private static var cancelled: Set<String> = []       // 用户按了停止的对话（区分「命令自己 kill -TERM $$」）

    /// `cancelAssistantTurn` / 面板「停止」调：杀掉该对话正在跑的命令树。
    @MainActor
    static func cancel(conversationId: String) {
        guard let pgid = running.removeValue(forKey: conversationId) else { return }
        cancelled.insert(conversationId)
        RunCommandMonitor.shared.remove(conversationId: conversationId)
        let backend = Self.backend
        DispatchQueue.global(qos: .userInitiated).async { backend.killTree(pgid) }
    }

    // MARK: 执行

    /// `monitorCommand`：「运行」面板登记用的命令文本。参数里换过加密值时传占位版，真值不进注册表（plan-secure-ask §4）
    @MainActor
    static func execute(args: [String: Any], profileId: String, conversationId: String?, monitorCommand: String? = nil) async -> DeviceToolExec {
        guard let command = DeviceToolIO.str(args, "command") else { return DeviceToolIO.fail("missing_param", "缺 command") }
        guard command.count <= maxCommandChars else {
            return DeviceToolIO.fail("invalid_param", "command 超过 \(maxCommandChars) 字符，先 fs_write 成脚本再运行")
        }
        let timeout = min(max(DeviceToolIO.int(args, "timeout_seconds") ?? defaultTimeout, 1), maxTimeout)

        // 后端就绪（iOS = 解压 rootfs + boot guest，首次几百 ms；macOS = no-op）
        do { try await backend.prepare() } catch {
            return DeviceToolIO.fail("not_available", error.localizedDescription)
        }

        let cwd: String
        switch backend.resolveCwd(DeviceToolIO.str(args, "cwd"), profileId: profileId) {
        case .success(let path): cwd = path
        case .failure(let e): return DeviceToolIO.fail("invalid_param", e.message)
        }

        let child: any RunCommandHandle
        do { child = try backend.spawn(command: command, cwd: cwd, env: backend.environment()) } catch {
            return DeviceToolIO.fail("failed", "起不来：\(error.localizedDescription)")
        }
        let key = conversationId ?? UUID().uuidString
        running[key] = child.pid
        RunCommandMonitor.shared.add(RunningCommand(id: child.pid, conversationId: key, command: monitorCommand ?? command, startedAt: child.start))

        let outcome = await Task.detached(priority: .userInitiated) { child.waitAndCollect(timeout: TimeInterval(timeout)) }.value
        #if os(iOS)
        SandboxRSS.markFirstCommandOnce()
        #endif
        running.removeValue(forKey: key)
        RunCommandMonitor.shared.remove(conversationId: key)
        let userStopped = cancelled.remove(key) != nil

        let out = truncate(clean(outcome.stdout))
        let err = truncate(clean(outcome.stderr))
        let tail = "（已收到的输出：stdout=\(out.text.prefix(2000)) stderr=\(err.text.prefix(2000))）"
        if outcome.timedOut {
            return DeviceToolIO.fail("timeout", "命令超过 \(timeout)s 未结束，已终止整棵进程树。\(tail)")
        }
        if userStopped {
            return DeviceToolIO.fail("cancelled", "用户停止了这条命令。\(tail)")
        }
        if let sig = outcome.signal {
            // 不是用户按的停止：命令自己 kill 自己 / 系统杀——如实说信号，别让模型以为用户干预了
            return DeviceToolIO.fail("failed", "命令被信号 \(sig) 终止。\(tail)")
        }
        guard let exitCode = outcome.exitCode else {
            // waitpid 失败（ECHILD：被别处回收）——不用零初始化的 status 谎报 exit 0（kimi 评审打穿 2）
            return DeviceToolIO.fail("failed", "命令退出状态未知（进程已被别处回收）。\(tail)")
        }
        var payload: [String: Any] = [
            "exit_code": exitCode,
            "stdout": out.text,
            "stderr": err.text,
            "duration_ms": outcome.durationMs,
            "truncated": out.truncated || err.truncated,
            "cwd": cwd,
        ]
        if let note = backend.resultNote(profileId: profileId) { payload["note"] = note }
        return DeviceToolIO.ok(payload)
    }

    /// **必须是 `LocalizedError`**：`execute` 里 `prepare()` 失败那条走的是
    /// `error.localizedDescription`（`:65`），裸 `struct: Error` 会退化成
    /// 「…CwdError error 1」，把「沙箱已重置，请重启 app」这类文案整段吃掉（BUG-6）。
    struct CwdError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: 输出清洗

    /// ANSI/VT 转义剥离 + `\r` 进度条折叠（TERM=dumb + NO_COLOR 挡不住的那些）。给模型和 UI 的都是干净文本。
    static func clean(_ s: String) -> String {
        // raw string 里 \u{..} 不转义，正则用 ICU 的 \x1B
        var t = s.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\x1B\][^\x07]*\x07"#, with: "", options: .regularExpression)   // OSC
        // 行内 \r 覆写：只留最后一段
        t = t.replacingOccurrences(of: #"[^\r\n]*\r(?!\n)"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func truncate(_ s: String) -> (text: String, truncated: Bool) {
        guard s.count > outputCap else { return (s, false) }
        let half = outputCap / 2
        // 不报「共 N 字符」——进来的可能已是有界读压缩过的文本，N 会撒谎；真总量在内层标记里
        return ("\(s.prefix(half))\n[…已截断，只保留头尾各 \(half) 字符…]\n\(s.suffix(half))", true)
    }
}

// MARK: - 后端协议（plan §1.4）

/// 一次命令执行的结果。两端同构——iOS 没有真 waitpid，但 timeout / signal / exitCode
/// 三种终局的语义必须和 macOS 一致，否则 envelope 会对模型撒谎。
struct RunCommandOutcome {
    var stdout = ""
    var stderr = ""
    var exitCode: Int?
    var signal: Int?
    var timedOut = false
    var durationMs = 0
}

/// 已经起来的一条命令。`pid` 是「停止」和面板的句柄（macOS = pgid，iOS = guest 组长 pid）。
protocol RunCommandHandle {
    var pid: pid_t { get }
    var start: Date { get }
    /// 阻塞到结束或超时，回收进程树，收集有界输出。**在后台线程调**。
    func waitAndCollect(timeout: TimeInterval) -> RunCommandOutcome
}

/// 平台后端。共享层只认这五个动作 + 两段平台文案。
protocol RunCommandBackend: Sendable {
    /// 工具描述（模型看的），按平台分——iOS 才能叫「沙箱」
    var toolDescription: String { get }
    /// `cwd` 参数的描述
    var cwdParamDescription: String { get }
    /// 起命令前的准备：iOS = 解压 rootfs + boot guest；macOS = no-op
    func prepare() async throws
    /// 传给命令的环境变量（macOS 继承 app env + PATH 前置；iOS 是固定白名单）
    func environment() -> [String: String]
    /// 解析 cwd，返回给后端用的路径字符串
    func resolveCwd(_ raw: String?, profileId: String) -> Result<String, RunCommandTool.CwdError>
    func spawn(command: String, cwd: String, env: [String: String]) throws -> any RunCommandHandle
    /// 杀整棵树（超时 / 用户停止 / 命令结束兜底）
    func killTree(_ pid: pid_t)
    /// 这次调用要额外告诉模型的话（iOS：iCloud 楼层挂不进沙箱）。nil = 没有
    func resultNote(profileId: String) -> String?
}

extension RunCommandBackend {
    func resultNote(profileId: String) -> String? { nil }
}

// MARK: - 「运行」面板数据源（plan §1.7）

struct RunningCommand: Identifiable, Equatable {
    let id: pid_t              // 组长 pid = pgid
    let conversationId: String
    let command: String
    let startedAt: Date
    var firstLine: String { command.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? command }
}

/// 正在跑的命令登记（`RunCommandTool` 起/收时增删）；面板据此拉 `ps`/`lsof` 快照。
@MainActor
@Observable
final class RunCommandMonitor {
    static let shared = RunCommandMonitor()
    private init() {}
    private(set) var running: [RunningCommand] = []

    func add(_ c: RunningCommand) { running.removeAll { $0.conversationId == c.conversationId }; running.append(c) }
    func remove(conversationId: String) { running.removeAll { $0.conversationId == conversationId } }
}

// MARK: - 有界输出收集（两端共用）

/// **有界**缓冲：只留头 `headCap` 字节 + 尾 `tailCap` 字节，中间丢弃计数
/// （`yes` 跑到超时不能把几 GB 吞进 app 内存——QA 席死前的发现）。
/// macOS 后端喂管道读到的 Data，iOS 后端喂 `ISHShellExecutor` 的逐行回调，压缩策略同一份。
final class BoundedOutput {
    static let headCap = 64 * 1024
    static let tailCap = 64 * 1024

    private var head = Data()
    private var tail = Data()          // 最多 tailCap，超出丢最老
    private var dropped = 0
    private var total = 0              // 原始总字节数（标记里报真数，不报压缩后的长度——codex 评审阻塞 5）

    func append(_ chunk: Data) {
        total += chunk.count
        var chunk = chunk
        if head.count < Self.headCap {
            let take = min(Self.headCap - head.count, chunk.count)
            head.append(chunk.prefix(take))
            chunk = chunk.dropFirst(take)
        }
        guard !chunk.isEmpty else { return }
        tail.append(chunk)
        if tail.count > Self.tailCap {
            dropped += tail.count - Self.tailCap
            tail = tail.suffix(Self.tailCap)
        }
    }

    func appendLine(_ line: String) { append(Data((line + "\n").utf8)) }

    var text: String {
        if dropped == 0 { return String(decoding: head + tail, as: UTF8.self) }
        return String(decoding: head, as: UTF8.self) + "\n[…输出共 \(total) 字节，中间已丢弃 \(dropped) 字节…]\n" + String(decoding: tail, as: UTF8.self)
    }
}
