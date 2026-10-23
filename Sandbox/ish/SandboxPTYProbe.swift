import Foundation

/// `-sandboxProbe pty`：小电脑多会话 PTY 的集成探针（#045 T2，plan-terminal-t2 §4 / sol 审 #13）。
/// 仓库没有 iOS 单测 target，PTY 的锁 / 引用计数 / 杀树只能在模拟器或真机上真跑。结果写 Documents/sandbox-pty.log，
/// 每项一行 PASS / FAIL，最后一行汇总。
@MainActor
enum SandboxPTYProbe {
    private static var lines: [String] = []
    private static var failures = 0
    private static let start = Date()
    private static var tokenSeq: UInt64 = 0x7000

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var count: Int { lock.lock(); defer { lock.unlock() }; return data.count }
    }

    private final class Session: @unchecked Sendable {
        var ptyId: Int32 = 0
        let capture = Capture()
        var exitStatus: Int32?
    }

    static func run() async {
        log("=== SBX PTY probe ===")
        do {
            _ = try await Task.detached { try SandboxRuntime.ensureReady() }.value
        } catch {
            check(false, "ensureReady：\(error.localizedDescription)")
            finish()
            return
        }
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            ISHKernel.shared.ptyWatchdogStart(withLogPath: dir.appendingPathComponent("sandbox-pty-hang.log").path)
        }
        let rss0 = SandboxRSS.residentMB()
        let pts0 = await ptsCount()
        let scenarios: [(String, () async -> Void)] = [
            ("并发", concurrentSessions),
            ("交互", interactiveEcho),
            ("秒退", quickExit),
            ("resize×读", resizeWhileReading),
            ("杀树", closeKillsIgnoringBackgroundJob),
            ("长行·规范", { await longLine(canonical: true) }),
            ("长行·非规范", { await longLine(canonical: false) }),
            ("刷屏", flood),
            ("并 run_command", concurrentWithRunCommand),
            ("会话 exit", sessionExitsThroughStore),
            ("启动中结束", sessionEndedWhileStarting),
            ("反复开关", openCloseLoop),
        ]
        for (name, body) in scenarios {
            guard await finishes(name: name, within: scenarioTimeout, body) else {
                // 挂住的那个场景收不回来（卡在内核里），后面的也不跑了：先把现场和结果行留下
                check(false, "场景「\(name)」\(Int(scenarioTimeout)) 秒没跑完（挂死），后面的场景跳过；现场见 console / sandbox-pty-hang.log")
                finish()
                return
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        let records = diag("records"), live = diag("live"), zombies = diag("zombies")
        let pts1 = await ptsCount()
        check(records == 0 && live == 0 && zombies == 0 && pts1 == pts0,
              "收尾：表项 \(records) / 活进程 \(live) / 僵尸 \(zombies)，/dev/pts \(pts0)→\(pts1)")
        log("RSS 起点 \(rss0) MB → 终点 \(SandboxRSS.residentMB()) MB")
        finish()
    }

    // MARK: 场景

    /// 4 个会话同时刷输出，互不串线；退出码按令牌认
    private static func concurrentSessions() async {
        var sessions: [(Int, Session)] = []
        for k in 1...4 {
            let script = "i=1; while [ $i -le 200 ]; do echo S\(k)-$i; i=$((i+1)); done; exit 3"
            guard let s = await open(["/bin/sh", "-c", script]) else { check(false, "并发：开不了第 \(k) 个"); return }
            sessions.append((k, s))
        }
        for (k, s) in sessions {
            let ok = await waitUntil(10) { s.exitStatus != nil }
            let text = s.capture.text
            let own = text.components(separatedBy: "\n").filter { $0.hasPrefix("S\(k)-") }.count
            let foreign = (1...4).filter { $0 != k }.contains { text.contains("S\($0)-") }
            check(ok && own == 200 && !foreign && s.exitStatus.map { ($0 >> 8) & 0xff } == 3,
                  "并发 #\(k)：自己 \(own)/200 行，串线=\(foreign)，wait status=\(s.exitStatus.map(String.init) ?? "nil")")
            await close(s)
        }
    }

    private static func interactiveEcho() async {
        guard let s = await open(["/bin/sh", "-l"]) else { check(false, "交互：开不了"); return }
        await write(s, "echo hello-$((1+1))\n")
        let ok = await waitUntil(5) { s.capture.text.contains("hello-2") }
        check(ok, "交互 shell 回显 hello-2")
        await close(s)
    }

    private static func quickExit() async {
        guard let s = await open(["/bin/sh", "-c", "exit 0"]) else { check(false, "秒退：开不了"); return }
        let ok = await waitUntil(5) { s.exitStatus != nil }
        check(ok && s.exitStatus == 0, "秒退的进程也报得出退出（status=\(s.exitStatus.map(String.init) ?? "nil")）")
        await close(s)
    }

    /// 一边让 shell 读输入一边狂改尺寸：resize 不能和 tty_read 的锁顺序打架（sol 实现审 #1）
    private static func resizeWhileReading() async {
        guard let s = await open(["/bin/sh", "-l"]) else { check(false, "resize×读：开不了"); return }
        await write(s, "cat\n")
        let ptyId = s.ptyId
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await withCheckedContinuation { cont in
                    DispatchQueue.global().async {
                        for i in 0..<300 {
                            ISHKernel.shared.ptyResize(ptyId, columns: Int32(60 + i % 40), rows: Int32(20 + i % 10))
                            _ = ISHKernel.shared.ptyWrite(ptyId, bytes: "r\n", length: 2)
                        }
                        cont.resume(returning: true)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        check(finished, "resize×读 300 轮 8 秒内跑完（没死锁）")
        if finished { await close(s) }
    }

    /// 后台 job 忽略 TERM / HUP：结束会话后它也得没了（sol 审 #3）
    private static func closeKillsIgnoringBackgroundJob() async {
        guard let s = await open(["/bin/sh", "-l"]) else { check(false, "杀树：开不了"); return }
        await write(s, "sh -c 'trap \"\" TERM HUP; sleep 1000' &\necho BG=$!\n")
        _ = await waitUntil(5) { s.capture.text.contains("BG=") && s.capture.text.range(of: #"BG=\d+"#, options: .regularExpression) != nil }
        guard let r = s.capture.text.range(of: #"BG=\d+"#, options: .regularExpression),
              let pid = Int(s.capture.text[r].dropFirst(3)) else {
            check(false, "杀树：没拿到后台 pid")
            await close(s)
            return
        }
        await close(s)
        let alive = await shell("kill -0 \(pid) 2>/dev/null && echo ALIVE || echo GONE")
        check(alive.contains("GONE"), "结束会话后忽略 TERM 的后台 job（pid \(pid)）也没了：\(alive.trimmingCharacters(in: .whitespacesAndNewlines))")
        if !alive.contains("GONE") { ISHKernel.shared.ptyDumpNow("杀树 FAIL：pid \(pid) 还活着") }
    }

    /// 8KB 不带换行贴进 cat：规范模式行缓冲只有 4096，写泵该放弃而不是卡死；非规范模式一字不丢
    private static func longLine(canonical: Bool) async {
        guard let s = await open(["/bin/sh", "-l"]) else { check(false, "长行：开不了"); return }
        let file = "/tmp/pty-long-\(canonical ? "canon" : "raw").txt"
        await write(s, (canonical ? "" : "stty -icanon; ") + "cat > \(file)\n")
        try? await Task.sleep(for: .milliseconds(300))
        let outcome = await write(s, String(repeating: "x", count: 8192) + "\n")
        if !canonical {
            try? await Task.sleep(for: .milliseconds(500))
        }
        await close(s)
        if canonical {
            if case .gaveUp = outcome {
                check(true, "规范模式 8KB 无换行：写泵约 3 秒后放弃，不卡死")
            } else {
                check(false, "规范模式 8KB 无换行：期望放弃，实际 \(outcome)")
            }
        } else {
            let size = await shell("wc -c < \(file)").trimmingCharacters(in: .whitespacesAndNewlines)
            check(outcome == .done && size == "8193", "非规范模式 8KB 无换行：泵 \(outcome)，落盘 \(size) 字节")
        }
    }

    /// 刷屏：经 ISHSessionIO 的背压，不丢字节、内存不爆
    private static func flood() async {
        let io = ISHSessionIO()
        var delivered = 0
        io.deliver = { delivered += $0.count }
        let rss0 = SandboxRSS.residentMB()
        tokenSeq += 1
        let token = LocalShellLaunch.token(sequence: tokenSeq)
        let env = LocalShellLaunch.environment(base: ISHShellBackend().environment())
        let ptyId = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            ISHTerminalSessionStore.openQueue.async {
                cont.resume(returning: ISHKernel.shared.openPTY(
                    withArguments: ["/bin/sh", "-c", "yes | head -c 2000000; sleep 1"], environment: env, token: token,
                    columns: 80, rows: 24, output: { io.ingest($0) }, exit: { _ in }))
            }
        }
        guard ptyId > 0 else { check(false, "刷屏：开不了"); return }
        io.started(ptyId: ptyId)
        var peak = rss0
        let deadline = Date().addingTimeInterval(30)
        while delivered < 3_000_000 && Date() < deadline {
            peak = max(peak, SandboxRSS.residentMB())
            try? await Task.sleep(for: .milliseconds(100))
        }
        // tty 会把 \n 转成 \r\n：2,000,000 字节 yes 输出 = 1,000,000 行，至少 3,000,000 字节
        check(delivered >= 3_000_000 && peak - rss0 < 100, "刷屏 2MB：交付 \(delivered) 字节，RSS +\(peak - rss0) MB")
        io.close(completion: nil)
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// AI 的 run_command 和人敲的终端同时跑
    private static func concurrentWithRunCommand() async {
        guard let s = await open(["/bin/sh", "-l"]) else { check(false, "并 run_command：开不了"); return }
        async let cmd = shell("sleep 1; echo RC-DONE")
        await write(s, "echo TYPED-$((3*3))\n")
        let typed = await waitUntil(3) { s.capture.text.contains("TYPED-9") }
        let rc = await cmd
        check(typed && rc.contains("RC-DONE"), "run_command 跑着时终端照常能打字（typed=\(typed)）")
        await close(s)
    }

    /// 走真的 store / 会话 / backend：shell 自己 exit，状态变「已退出」并带退出码
    private static func sessionExitsThroughStore() async {
        let store = ISHTerminalSessionStore.shared
        guard let session = store.open(profileId: "sandbox-pty-probe") else { check(false, "会话：store 开不了"); return }
        session.controller.attachIfNotYet(cols: 80, rows: 24)
        session.controller.sendInput(Data("exit 7\r".utf8))
        let exited = await waitUntil(10) { session.state == .exited(7) }
        check(exited, "会话里 exit 7 → 状态「已退出（7）」（实际 \(session.state)）")
        var closed = false
        session.end { closed = true }
        store.end(session.id)
        _ = await waitUntil(5) { closed }
        check(closed && store.session(session.id) == nil, "已退出的会话能结束并收干净")
    }

    /// 刚开就结束（还在启动）：晚到的启动结果要自己收掉，不留孤儿
    private static func sessionEndedWhileStarting() async {
        let store = ISHTerminalSessionStore.shared
        let before = diag("live")
        guard let session = store.open(profileId: "sandbox-pty-probe") else { check(false, "启动中结束：开不了"); return }
        session.controller.attachIfNotYet(cols: 80, rows: 24)
        var closed = false
        session.end { closed = true }
        store.end(session.id)
        _ = await waitUntil(8) { closed }
        try? await Task.sleep(for: .milliseconds(300))
        let after = diag("live")
        check(closed && after <= before, "启动途中结束：回调到了=\(closed)，带令牌的活进程 \(before)→\(after)")
    }

    /// 反复开关 20 次：pts 号不漏（漏了会 ENOSPC），内存回落
    private static func openCloseLoop() async {
        let rss0 = SandboxRSS.residentMB()
        var failed = 0
        for _ in 0..<20 {
            guard let s = await open(["/bin/sh", "-l"]) else { failed += 1; continue }
            await close(s)
        }
        check(failed == 0, "反复开关 20 次：失败 \(failed) 次，RSS \(rss0)→\(SandboxRSS.residentMB()) MB")
    }

    // MARK: 工具

    /// 单个场景的上限：最慢的刷屏场景自己最多等 30 秒
    private static let scenarioTimeout: Double = 45

    /// 跑 body，超时就不等了（body 卡在内核里收不回来，只能扔下）。不用 task group：group 收尾要等所有子任务。
    /// 现场由 ISHKernel 的看门狗线程留（不靠主线程 / GCD / 任何锁）；这里只负责主线程还活着时把 FAIL 和结果行打出来
    private static func finishes(name: String, within seconds: Double, _ body: @escaping () async -> Void) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
        }
        let once = Once()
        ISHKernel.shared.ptyWatchdogArm(seconds, tag: name)
        let finished = await withCheckedContinuation { cont in
            Task { @MainActor in
                await body()
                if once.fire() { cont.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 5) {
                if once.fire() { cont.resume(returning: false) }
            }
        }
        // 看门狗触发过就算超时，哪怕之后跑完了（不然 47 秒跑完的场景会混成通过）
        let fired = ISHKernel.shared.ptyWatchdogDisarm()
        return finished && !fired
    }

    private static func diag(_ key: String) -> Int {
        ISHKernel.shared.ptyDiagnostics()[key]?.intValue ?? -1
    }

    private static func ptsCount() async -> Int {
        Int(await shell("ls /dev/pts | wc -l").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private static func open(_ args: [String]) async -> Session? {
        tokenSeq += 1
        let token = LocalShellLaunch.token(sequence: tokenSeq)
        let env = LocalShellLaunch.environment(base: ISHShellBackend().environment())
        let s = Session()
        let capture = s.capture
        let ptyId = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            ISHTerminalSessionStore.openQueue.async {
                cont.resume(returning: ISHKernel.shared.openPTY(
                    withArguments: args, environment: env, token: token, columns: 80, rows: 24,
                    output: { capture.append($0) },
                    exit: { status in s.exitStatus = status }))
            }
        }
        guard ptyId > 0 else { log("openPTY 失败 \(ptyId)"); return nil }
        s.ptyId = ptyId
        return s
    }

    @discardableResult
    private static func write(_ s: Session, _ text: String) async -> TerminalInputPump.Outcome {
        let ptyId = s.ptyId
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: TerminalInputPump.drain(
                    Data(text.utf8), again: ISHPTYWriteAgain,
                    write: { buf in ISHKernel.shared.ptyWrite(ptyId, bytes: buf.baseAddress!, length: UInt(buf.count)) },
                    isCancelled: { false }, pause: { usleep(10_000) }))
            }
        }
    }

    private static func close(_ s: Session) async {
        let ptyId = s.ptyId
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                ISHKernel.shared.ptyClose(ptyId)
                cont.resume()
            }
        }
    }

    /// 走 run_command 同一条路（ISHShellExecutor）跑一条，拿 stdout
    private static func shell(_ command: String) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: ISHShellExecutor.executeCommandSync(command, timeout: 10, lineCallback: nil).output)
            }
        }
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(what)")
    }

    private static func finish() {
        log("=== 结果：\(failures == 0 ? "全部通过" : "\(failures) 项失败") ===")
    }

    private static func log(_ line: String) {
        let stamped = String(format: "[+%6.2fs] ", Date().timeIntervalSince(start)) + line
        print("[SBX-PTY] \(stamped)")
        lines.append(stamped)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("sandbox-pty.log"),
                                                         atomically: true, encoding: .utf8)
    }
}
