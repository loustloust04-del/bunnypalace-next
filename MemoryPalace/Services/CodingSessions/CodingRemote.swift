#if os(macOS)
import Foundation

/// 会话 key 的唯一构造点（Wake `session_key` / `strip_key_prefix`）：本地 `{agent}:{native}`，远程 `{agent}:{host}:{native}`。
/// 十六家 adapter 的本地两段拼法保留各自字面（它们从不涉及 host）；扫描器分组 / 墓碑、远程装饰器改写、幸存副本反查走这里
enum CodingSessionKey {
    static func make(_ agent: CodingAgent, host: String, nativeId: String) -> String {
        host.isEmpty ? "\(agent.rawValue):\(nativeId)" : "\(agent.rawValue):\(host):\(nativeId)"
    }

    /// key 属于 (agent, host) 实例时回 native id；本地实例拒三段 key（余段带冒号 = 别的 host 的；native id 自身不含冒号）
    static func nativeId(of key: String, agent: CodingAgent, host: String) -> String? {
        let prefix = agent.rawValue + ":"
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        if host.isEmpty { return rest.contains(":") ? nil : String(rest) }
        let hostPrefix = host + ":"
        guard rest.hasPrefix(hostPrefix) else { return nil }
        return String(rest.dropFirst(hostPrefix.count))
    }
}

/// 一台远程主机的配置与同步状态（用户状态 JSON；Wake `remote_hosts` 表）。name 即 ssh 目标（`~/.ssh/config` 的 Host 别名或 user@host）
struct CodingRemoteHost: Codable, Equatable, Sendable {
    var name: String
    var enabled: Bool
    var addedAt: Int64
    /// 上次**成功**同步（ms）；nil = 从未成功过
    var lastSyncAt: Int64?
    var lastSyncError: String?
}

/// 远程主机（N4，Wake `remote.rs`）：**同步到本地缓存，不远程直读**——rsync 把远端 home 下的会话数据按白名单镜像到
/// `<索引库目录>/remotes/<host>/`（保持远端 home 的相对布局），装饰器以各家 `withCustomRoot(缓存/mount)` 挂进 roster，
/// 解析 / 索引 / 搜索对远程零感知。shell out 系统 ssh / rsync：`~/.ssh/config` 的别名、ProxyJump、IdentityAgent 全部继承；
/// `BatchMode=yes` 让 GUI 进程绝不挂在交互认证上（密钥要么在 agent 里，要么明确失败把 stderr 记进状态）。
/// 一次同步 = **先探测再镜像**：openrsync 做发送端时，某个源连父目录都不存在会中止整份文件列表、后面的源静默不传；rsync 家族
/// 只要缺源就整体跳过 --delete——没有哪台机器十六家全装，整张白名单直接喂 rsync 删除就永远不生效（Wake 2026-09-02 实测）。
/// 白名单只含会话数据与侧档，绝不同步凭证；新增 adapter 必须在 `layouts` 补一行（测试卡全家覆盖）
enum CodingRemote {
    /// 一家 agent 在远端 home 下的布局（Wake `RemoteAgentLayout`）
    struct Layout: Sendable {
        let agent: CodingAgent
        /// 缓存内交给 withCustomRoot 的目录（相对缓存根 = 相对远端 home）。必须选「目录**不存在**时整形也落到正确形态」的那一层——
        /// 同步是异步的，实例构造时缓存可能还没落盘
        let mount: String
        /// rsync 白名单源（相对远端 home；目录整树、文件单拉）。SQLite 连 `-wal` 一起拉（数据在 wal 里），`-shm` 是运行时产物不拉。
        /// 字符集限 `[A-Za-z0-9._/-]`——不加引号直接进探测脚本与 rsync 源参数（测试卡）
        let syncPaths: [String]
        /// rsync `--exclude`（按文件名匹配，作用于整次同步）：凭证与本家不读的大索引写在自己这一行
        let exclude: [String]
    }

    /// 十六家远端布局（按 Linux / macOS 默认路径；远端的 CODEX_HOME / XDG 之类 env 覆盖探测不到，不支持）
    static let layouts: [Layout] = [
        Layout(agent: .claudeCode, mount: ".claude/projects", syncPaths: [".claude/projects"], exclude: []),
        // home 形态：sessions / archived_sessions / state_5.sqlite 全相对派生
        Layout(agent: .codex, mount: ".codex",
               syncPaths: [".codex/sessions", ".codex/archived_sessions", ".codex/state_5.sqlite", ".codex/state_5.sqlite-wal"], exclude: []),
        Layout(agent: .qoder, mount: ".qoder/projects", syncPaths: [".qoder/projects"], exclude: []),
        // 目录层：db = <mount>/session-store.db（按文件判据对未同步目录失真）
        Layout(agent: .copilot, mount: ".copilot", syncPaths: [".copilot/session-store.db", ".copilot/session-store.db-wal"], exclude: []),
        Layout(agent: .cursor, mount: ".cursor/projects", syncPaths: [".cursor/projects"], exclude: []),
        // 目录给出 stable + next 两个固定候选
        Layout(agent: .opencode, mount: ".local/share/opencode",
               syncPaths: [".local/share/opencode/opencode.db", ".local/share/opencode/opencode.db-wal",
                           ".local/share/opencode/opencode-next.db", ".local/share/opencode/opencode-next.db-wal"], exclude: []),
        Layout(agent: .kiro, mount: ".kiro/sessions/cli", syncPaths: [".kiro/sessions/cli"], exclude: []),
        // tmp 层：projects.json 由上层派生（.gemini 顶层有凭证，不整树同步）
        Layout(agent: .gemini, mount: ".gemini/tmp", syncPaths: [".gemini/tmp", ".gemini/projects.json"], exclude: []),
        Layout(agent: .pi, mount: ".pi/agent/sessions", syncPaths: [".pi/agent/sessions"], exclude: []),
        Layout(agent: .omp, mount: ".omp/agent/sessions", syncPaths: [".omp/agent/sessions"], exclude: []),
        // sessions 目录名判据 → home = 上层；Grok 自家的搜索索引库量大且不读
        Layout(agent: .grok, mount: ".grok/sessions", syncPaths: [".grok/sessions"], exclude: ["session_search.sqlite*"]),
        Layout(agent: .kimi, mount: ".kimi-code/sessions", syncPaths: [".kimi-code/sessions", ".kimi-code/session_index.jsonl"], exclude: []),
        // 库所在目录层
        Layout(agent: .antigravity, mount: ".gemini/antigravity-cli",
               syncPaths: [".gemini/antigravity-cli/conversation_summaries.db", ".gemini/antigravity-cli/conversation_summaries.db-wal"], exclude: []),
        Layout(agent: .dsh, mount: ".dsh/sessions", syncPaths: [".dsh/sessions"], exclude: []),
        // 库所在目录层：db = <mount>/state.db（profiles 多档案不同步）
        Layout(agent: .hermes, mount: ".hermes", syncPaths: [".hermes/state.db", ".hermes/state.db-wal"], exclude: []),
        // agents/<id>/ 整树；exclude 挡每个 agent 目录里的凭证：auth-profiles.json 与 openclaw-agent.sqlite（库里存着 API key /
        // OAuth token，会话与凭证同库只能整库不拉）——远程 OpenClaw 因此只覆盖旧版 sessions/*.jsonl
        Layout(agent: .openclaw, mount: ".openclaw/agents", syncPaths: [".openclaw/agents"],
               exclude: ["auth-profiles.json", "openclaw-agent.sqlite*"]),
    ]

    /// 白名单全部源，按布局表顺序（探测脚本、rsync 源、缺席清理三处同序）
    static var allSyncPaths: [String] { layouts.flatMap(\.syncPaths) }

    /// host 名合法性：进 key 作中段（不能有 `:`）、直接作 ssh / rsync 目标（不能以 `-` 开头——会被当成选项，是参数注入面）。
    /// 允许 `user@host`、别名、IPv4；IPv6 请在 `~/.ssh/config` 里包一个别名
    static func validHostName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-@".contains($0)) }
    }

    /// 全部远程缓存所在目录：索引库旁边（打开哪个库就用哪个库旁边的缓存，测试的 tmp 库天然隔离）
    static func cacheRoot(indexURL: URL) -> URL {
        indexURL.deletingLastPathComponent().appendingPathComponent("remotes", isDirectory: true)
    }

    static func hostCacheDir(_ cacheRoot: URL, host: String) -> URL {
        cacheRoot.appendingPathComponent(host, isDirectory: true)
    }

    /// 一台主机的整组远程实例：布局表 × 模板 `withCustomRoot(缓存内挂载点)` × 装饰器。模板由 roster 唯一构造点传入（未经位置覆盖），
    /// 产物的数据根 100% 派生自缓存目录
    static func adapters(templates: [CodingSessionAdapter], host: String, cacheRoot: URL) -> [CodingSessionAdapter] {
        let dir = hostCacheDir(cacheRoot, host: host)
        return layouts.compactMap { layout in
            guard let template = templates.first(where: { $0.agent == layout.agent }) else { return nil }
            return CodingRemoteAdapter(inner: template.withCustomRoot(dir.appendingPathComponent(layout.mount, isDirectory: true)), host: host)
        }
    }

    // MARK: - 命令形状（纯函数，测试卡）

    /// ssh 的批处理选项：探测与 rsync 的 `-e` 同一份，认证 / 超时两步一致
    static let sshOptions = ["-oBatchMode=yes", "-oConnectTimeout=10"]

    /// 远端存在性探测的 ssh 参数（不含程序名）。远端命令是一整条 `sh -c '…'`：ssh 交给登录 shell 再解析，单引号串在 fish / csh 里
    /// 同样原样交给 sh；循环体用 if 而非 `&&`，末项缺席不会把退出码带成非零——非零只表示 ssh 本身失败（认证 / 不可达 / 远端无 sh）
    static func probeArguments(host: String) -> [String] {
        let list = allSyncPaths.joined(separator: " ")
        let script = "for p in \(list); do if [ -e \"$p\" ]; then printf \"%s\\n\" \"$p\"; fi; done"
        return sshOptions + [host, "sh -c " + CodingShellQuote.posix(script)]
    }

    /// 探测输出 → 布局表顺序的存在路径。只认与白名单**逐字相等**的行：rc 文件的 echo、MOTD、警告都不能变成 rsync 源
    static func presentPaths(_ stdout: String) -> [String] {
        let lines = Set(stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return allSyncPaths.filter { lines.contains($0) }
    }

    /// 单台的 rsync 参数（不含程序名）。`-R` 让 `host:./<相对路径>` 在目标重建相对布局；`--delete` 只作用于各源树**内部**，
    /// 整棵源消失由 syncHost 的缺席清理负责
    static func rsyncArguments(host: String, dest: URL, paths: [String]) -> [String] {
        ["-az", "-R", "--delete"]
            + layouts.flatMap(\.exclude).map { "--exclude=\($0)" }
            + ["--timeout=120", "-e", "ssh " + sshOptions.joined(separator: " ")]
            + paths.map { "\(host):./\($0)" }
            + [dest.path]
    }

    /// rsync 的错误行是否**全部**是「源不存在」：GNU 报 `link_stat "…" failed: No such file or directory (2)`，openrsync 报
    /// `error: …: (l)stat: No such file or directory`；总结行不算；一行错误都没有的 23 不认（形状未知，当真错误报）
    static func onlyMissingSources(_ stderr: String) -> Bool {
        let errors = stderr.split(whereSeparator: \.isNewline)
            .filter { $0.contains("rsync") && ($0.contains("error") || $0.contains("failed")) }
            .filter { !$0.contains("some files/attrs were not transferred") }
        return !errors.isEmpty && errors.allSatisfy { $0.contains("No such file or directory") }
    }

    /// `<bin> 退出码 N：<stderr 末 3 行>`——ssh / rsync 都把决定性错误留在最后，封顶 500 字防单行巨量输出
    static func exitError(_ bin: String, _ output: Output) -> String {
        let lines = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).suffix(3)
        let tail = String(lines.joined(separator: "; ").prefix(500))
        return output.signaled ? "\(bin) 被信号终止：\(tail)" : "\(bin) 退出码 \(output.status)：\(tail)"
    }

    // MARK: - 同步

    struct Output: Sendable {
        var status: Int32
        var signaled: Bool
        var stdout: String
        var stderr: String
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// 同步指定主机（调用方给「全部启用的」或单台新加的），各台并行（纯网络等待，总耗时 = 最慢一台）。**绝不抛**——
    /// 结果按主机回（nil = 成功），调用方记进状态；失败不动缓存，后续扫描照常消费既有缓存
    static func syncHosts(_ names: [String], cacheRoot: URL,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String?] {
        let results = ResultBox()
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            let name = names[i]
            // 已存进状态的名字也再卡一道：老状态文件可能被未来版本写入过更宽的名字
            let error = validHostName(name)
                ? syncHost(name, dest: hostCacheDir(cacheRoot, host: name), environment: environment)
                : "主机名不合法"
            results.set(name, error)
        }
        return results.values
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String?] = [:]

        func set(_ name: String, _ error: String?) {
            lock.lock()
            storage[name] = .some(error)
            lock.unlock()
        }

        var values: [String: String?] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// 单台一次同步：探测 → 缺席清理 → rsync。探测失败即整体失败、缓存一字不动（不能把「连不上」当「远端空了」）。探测到 rsync
    /// 之间隔着一次握手，远端 agent 恰好退出会删掉 `-wal` 之类，rsync 对命令行源 stat 失败报 23 且整轮跳过 --delete——只含
    /// ENOENT 的 23 重探一轮再镜像（第二轮拿到的源集合已是消失后的），第二轮结果照实报
    static func syncHost(_ host: String, dest: URL, environment: [String: String]) -> String? {
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            return "建不了缓存目录 \(dest.path)：\(error.localizedDescription)"
        }
        var retried = false
        while true {
            let present: [String]
            do {
                let output = try runTool("ssh", installHint: "OpenSSH", arguments: probeArguments(host: host), environment: environment)
                guard output.status == 0, !output.signaled else { return exitError("ssh", output) }
                present = presentPaths(output.stdout)
            } catch {
                return (error as? Failure)?.message ?? error.localizedDescription
            }
            // 远端整个不存在的白名单项（该家卸了、库被清了）：镜像也删——--delete 只管源树内部，整棵源消失只有这里能传播
            for path in allSyncPaths where !present.contains(path) {
                if let error = removeCached(dest.appendingPathComponent(path)) { return error }
            }
            if present.isEmpty { return nil }
            let output: Output
            do {
                output = try runTool("rsync", installHint: "rsync", arguments: rsyncArguments(host: host, dest: dest, paths: present), environment: environment)
            } catch {
                return (error as? Failure)?.message ?? error.localizedDescription
            }
            if output.status == 23, !output.signaled, onlyMissingSources(output.stderr) {
                if retried { return exitError("rsync", output) }
                retried = true
                continue
            }
            // 24 = 传输中源文件消失（agent 正在写，下轮自愈）算成功
            if !output.signaled, output.status == 0 || output.status == 24 { return nil }
            return exitError("rsync", output)
        }
    }

    /// 删缓存里的一个白名单项（目录整树 / 单文件）；不存在即无事，删不掉要报——否则远端已删的会话留在缓存与索引里，面板却显示成功。
    /// lstat 不跟随符号链接；路径穿过普通文件（ENOTDIR）不是「不存在」
    static func removeCached(_ url: URL) -> String? {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            let code = errno
            return code == ENOENT ? nil : "查不了旧缓存 \(url.path)：\(String(cString: strerror(code)))"
        }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        } catch {
            return "删不掉旧缓存 \(url.path)：\(error.localizedDescription)"
        }
    }

    /// 删掉 `remotes/` 下不再对应任何已配置主机的缓存目录。同步中被移除的主机，rsync 取消不了会把刚删的目录写回——每轮同步收工后
    /// 按配置裁决一次，幂等自愈（这棵树只有 MP 自己写）
    static func purgeOrphanCaches(_ cacheRoot: URL, known: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path) else { return }
        for name in names where !known.contains(name) {
            try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(name))
        }
    }

    /// 在注入环境的 PATH 里找工具（Wake `Command::new(bin)` 同语义：GUI 进程的 PATH 通常只有系统目录 → 系统 OpenSSH / openrsync）
    static func which(_ bin: String, environment: [String: String]) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(dir)).appendingPathComponent(bin).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 起一个外部工具：不在 PATH → 安装提示；起不来 → 原因。退出码不在这里裁决，调用方还要看原始 stderr。
    /// stdin 接空设备；stdout / stderr 并发读完（任一管道写满 64 KB 就会与 waitUntilExit 互锁）
    static func runTool(_ bin: String, installHint: String, arguments: [String], environment: [String: String]) throws -> Output {
        guard let path = which(bin, environment: environment) else {
            throw Failure(message: "PATH 里找不到 \(bin)——要同步远程主机需先安装 \(installHint)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw Failure(message: "起不了 \(bin)：\(error.localizedDescription)")
        }
        let stdoutBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal,
                      stdout: String(decoding: stdoutBox.data, as: UTF8.self), stderr: String(decoding: stderrData, as: UTF8.self))
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

/// 远程会话的 adapter 装饰器（Wake `adapters/remote.rs`）：包一个 `withCustomRoot(缓存内挂载点)` 的常规实例，在**每个产出 meta 的出口**
/// （parseSession / parseTranscript / quickMeta / parentLinks）做且只做两件事——key 插入 host 段、`meta.host` 赋值；inner 对远程零感知，
/// mergeQuickMeta 只在两个已改写的 meta 之间搬运。**协议全部成员必须显式实现**：没写的成员会落到协议扩展的默认实现，
/// inner 的覆写（Codex quickMeta、dsh fileRef、Grok parentLinks）就被静默绕过——协议加成员时这里必须跟着补
struct CodingRemoteAdapter: CodingSessionAdapter {
    let inner: CodingSessionAdapter
    let host: String

    var agent: CodingAgent { inner.agent }
    var dataRoots: [URL] { inner.dataRoots }

    func listSessionFiles() -> [CodingSessionFileRef] { inner.listSessionFiles() }

    func fileRef(_ url: URL) -> CodingSessionFileRef? { inner.fileRef(url) }

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? {
        inner.quickMeta(refs)?.mapValues(rewrite)
    }

    func mergeQuickMeta(_ parsed: CodingSessionMeta, _ quick: CodingSessionMeta) -> CodingSessionMeta {
        inner.mergeQuickMeta(parsed, quick)
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        var parsed = try inner.parseSession(ref)
        parsed.meta = rewrite(parsed.meta)
        return parsed
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        var parsed = try inner.parseTranscript(ref)
        parsed.meta = rewrite(parsed.meta)
        return parsed
    }

    func loadSidechain(_ ref: CodingSessionFileRef, id: String) throws -> [CodingMessage] {
        try inner.loadSidechain(ref, id: id)
    }

    /// 远程会话界面禁删；这里如实回缓存内路径（本地副本，不是远端文件）
    func sessionPaths(_ meta: CodingSessionMeta) -> [String] { inner.sessionPaths(meta) }

    func beginScan() { inner.beginScan() }

    var managesParentLinks: Bool { inner.managesParentLinks }

    func parentLinks() -> [(child: String, parent: String)] {
        inner.parentLinks().map { (child: rewriteKey($0.child), parent: rewriteKey($0.parent)) }
    }

    func isParentLinkEvent(_ path: String) -> Bool { inner.isParentLinkEvent(path) }

    /// 远程实例没有自定义位置入口；保持装饰不变量以防误用
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        CodingRemoteAdapter(inner: inner.withCustomRoot(dir), host: host)
    }

    var supportsIndividualRootRemoval: Bool { inner.supportsIndividualRootRemoval }

    func excludingDataRoots(_ roots: [URL]) -> CodingSessionAdapter? {
        inner.excludingDataRoots(roots).map { CodingRemoteAdapter(inner: $0, host: host) }
    }

    /// `agent:native` → `agent:host:native`；inner 产的 key 恒为 `agent:` 前缀，万一不是整串当 native 仍唯一
    private func rewriteKey(_ key: String) -> String {
        let native = key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } ?? key
        return CodingSessionKey.make(agent, host: host, nativeId: native)
    }

    private func rewrite(_ meta: CodingSessionMeta) -> CodingSessionMeta {
        var out = meta
        out.key = rewriteKey(meta.key)
        if !meta.parentKey.isEmpty { out.parentKey = rewriteKey(meta.parentKey) }
        out.host = host
        return out
    }
}
#endif
