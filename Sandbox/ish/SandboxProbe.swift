//
//  SandboxT0Probe.swift
//  离线沙箱 T0 runway 探针（Phase 2 前置）——只回答四个问题，不是产品代码。
//
//  触发：UserDefaults `sandboxT0Probe == true`，或启动参数 `-sandboxT0Probe 1`
//  （启动参数会被 UserDefaults 的 NSArgumentDomain 自动吸收，所以读一处就够）。
//
//  取证：全部写 `Documents/sandbox-t0.log`（文件探针）。这台机器读不到 unified log，
//  别指望 NSLog；同时 print 一份给 simctl / devicectl --console。
//

#if os(iOS) && DEBUG

import Foundation

enum SandboxProbe {

    private static var logName = "sandbox-t0.log"

    /// 触发判定：**先看 ProcessInfo.arguments，再看 UserDefaults**。
    /// devicectl 在真机上把 `-- -sandboxT0Probe 1` 传进来了（arguments 里看得到），
    /// 但 NSArgumentDomain 没吸收它 → UserDefaults.bool 读到 false，探针静默不跑
    /// （T1 真机上实测卡了半小时：app 起来了、App.init 打完 PERF、就是没有 [SBX-T0]）。
    /// 仓库里 `--pop-tuner-probe` 用的就是 ProcessInfo 直读，这条路才是可靠的。
    private static func flagOn(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains("-\(name)")
            || UserDefaults.standard.bool(forKey: name)
    }

    /// `-sandboxProbe <mode>` 的 mode（run_command / boot / baseline）
    private static func probeMode() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-sandboxProbe"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func runIfRequested() {
        // T2：run_command 双后端的 iOS 侧验收。仓库里没有 iOS 单测 target
        // （project.yml 只有 macOS 的 MemoryPalaceTests 和 UI test 的 StickerProbeUITests），
        // 所以这几条用探针跑，envelope 原文落 Documents/sandbox-probe.log。
        // #045 T2：多会话交互 PTY（锁 / 引用计数 / 杀树 / 背压）的真跑验收
        if probeMode() == "pty" {
            Task { @MainActor in await SandboxPTYProbe.run() }
            return
        }
        if probeMode() == "t4" {
            logName = "sandbox-t4.log"
            Task { @MainActor in await t4Probe() }
            return
        }
        if probeMode() == "t3b" {
            logName = "sandbox-t3b.log"
            Task { @MainActor in await t3bProbe() }
            return
        }
        if probeMode() == "mount" {
            logName = "sandbox-mount.log"
            Task { @MainActor in await mountProbe() }
            return
        }
        if probeMode() == "run_command" {
            logName = "sandbox-probe.log"
            Task { @MainActor in await runCommandProbe() }
            return
        }
        // T6a：起一条长命令，专门给顶部提示条（BUG-4）留出截图窗口。
        // 现成的 mode 都是「跑完就完」，没有能停住的窗口；t4 那条要人工配合切后台，不适合截图。
        // T6c ③：askOnce 弹卡「等 35s 再点允许」的验收。走真的 PermissionPromptCenter
        // + 根视图上的 PermissionPromptHost，跟工具循环用的是同一条路（工具循环那层还要
        // 一个能发消息的 provider，模拟器上没有，就从权限闸这一层验）。
        if probeMode() == "askonce" {
            logName = "sandbox-askonce.log"
            Task { @MainActor in await askOnceProbe() }
            return
        }
        if probeMode() == "long_command" {
            logName = "sandbox-long-command.log"
            Task { @MainActor in await longCommandProbe() }
            return
        }
        // 对照组：只量 RSS 曲线，不碰 rootfs/guest。用来把 MP 自己启动期的增长
        // 从 guest 的账上减掉（不做对照，boot 后的 RSS 全是 app 首屏的锅还是 guest 的锅分不清）。
        if flagOn("sandboxT0Baseline") || probeMode() == "baseline" {
            DispatchQueue.global(qos: .userInitiated).async { runBaseline() }
            return
        }
        guard flagOn("sandboxT0Probe") || probeMode() == "boot" else { return }
        // 不阻塞启动：boot 是同步且重的，扔后台队列。
        // 不能延迟起跑——锁屏状态下 devicectl 拉起的 app 很快被挂起/回收，定时器不会触发（实测）。
        DispatchQueue.global(qos: .userInitiated).async { run() }
    }

    /// 对照组：与 run() 同样的时间轴上只采样 RSS，什么都不做
    private static func runBaseline() {
        resetLog()
        log("=== SBX-T0 BASELINE（对照组：不解压不 boot 不跑命令）===")
        log("device: \(deviceLine())")
        var prev = 0.0
        for t in [0.0, 1, 2, 3, 5, 8, 12] {
            if t > prev { Thread.sleep(forTimeInterval: t - prev) }
            prev = t
            log("RSS=\(residentMB()) MB")
        }
        log("=== BASELINE done ===")
    }

    // MARK: - 主流程

    private static func run() {
        resetLog()
        log("=== SBX-T0 probe start \(ISO8601DateFormatter().string(from: Date())) ===")
        log("device: \(deviceLine())")
        log("RSS baseline（未碰 rootfs/guest）: \(residentMB()) MB")
        log("rootfs 已安装? \(RootfsManager.shared.isInstalled)")

        // T1：不再自己解压 + 自己 boot，全部走 RootfsManager + SandboxRuntime 懒启动闸门
        let rssBeforeReady = residentMB()
        let t0 = Date()
        let rootPath: URL
        do {
            rootPath = try SandboxRuntime.ensureReady()
        } catch {
            log("FATAL: SandboxRuntime.ensureReady 失败：\(error.localizedDescription)")
            return
        }
        let readyMs = Date().timeIntervalSince(t0) * 1000
        let rssAfterReady = residentMB()
        log("SandboxRuntime.ensureReady() 耗时 \(String(format: "%.1f", readyMs)) ms（含首启解压）")
        log("rootfs: \(rootPath.path)")
        log("RSS before ensureReady: \(rssBeforeReady) MB / after: \(rssAfterReady) MB / Δ=\(rssAfterReady - rssBeforeReady) MB")
        log("isBooted=\(ISHKernel.shared.isBooted)")

        // 幂等性：再调一次应该是纯早退
        let t1 = Date()
        _ = try? SandboxRuntime.ensureReady()
        log("ensureReady() 第二次（应秒回）耗时 \(String(format: "%.2f", Date().timeIntervalSince(t1) * 1000)) ms")

        // 第一条 guest 命令（含 JIT 冷启动）
        runGuest("uname -a; cat /etc/alpine-release; echo hello", label: "cmd1（冷）")
        // 第二条：热路径耗时对照
        runGuest("echo warm", label: "cmd2（热）")
        // T1 rootfs 配置验证：resolv.conf 是上游漏的那个（fakefsify 之后写 = guest 看不见）
        runGuest("cat /etc/resolv.conf; echo ---; cat /etc/apk/repositories; echo ---; grep -o 'garden' /etc/profile | head -1; echo ---; head -3 /etc/motd; echo ---; grep -c minis /etc/profile /etc/motd || true",
                 label: "cmd3（rootfs 配置验证）")

        let rssAfterCmd = residentMB()
        log("RSS after commands: \(rssAfterCmd) MB / 相对 ensureReady 前 Δ=\(rssAfterCmd - rssBeforeReady) MB")
        Thread.sleep(forTimeInterval: 5)
        let rssSettled = residentMB()
        log("RSS settled(+5s): \(rssSettled) MB / 相对 ensureReady 前 Δ=\(rssSettled - rssBeforeReady) MB")
        log("=== SBX-T0 probe done ===")
    }

    private static func runGuest(_ command: String, label: String) {
        let t = Date()
        let result = ISHShellExecutor.executeCommandSync(command, timeout: 60, lineCallback: nil)
        let ms = Date().timeIntervalSince(t) * 1000
        log("--- \(label): `\(command)` ---")
        log("exit=\(result.exitCode) error=\(result.error.rawValue) pid=\(result.pid) 耗时 \(String(format: "%.1f", ms)) ms")
        log("stdout:\n\(result.output)")
        if !result.errorOutput.isEmpty { log("stderr:\n\(result.errorOutput)") }
    }

    // MARK: - T2：run_command iOS 后端验收

    /// 与 macOS 的 `RunCommandToolTests` 同一套场景，走真正的 `RunCommandTool.execute`
    /// （不是绕过共享层直接调后端——绕过就测不到 envelope / 截断 / 注册表）。
    @MainActor
    private static func runCommandProbe() async {
        resetLog()
        log("=== SBX-T2 run_command 探针 \(ISO8601DateFormatter().string(from: Date())) ===")
        log("device: \(deviceLine())")
        log("后端: \(type(of: RunCommandTool.backend))")

        let pid = "probe-profile"

        await one("echo", args: ["command": "echo hello"], profileId: pid)
        await one("非零退出码", args: ["command": "exit 3"], profileId: pid)
        await one("超时杀树", args: ["command": "sleep 100 & sleep 100", "timeout_seconds": 1], profileId: pid)
        await timeoutKillsSleepers()
        await one("300KB 输出有界", args: ["command": "yes 0123456789012345678901234567890123456789 | head -7500"], profileId: pid)
        await one("自杀信号不算 cancelled", args: ["command": "kill -TERM $$"], profileId: pid)
        await one("cwd 默认 /root", args: ["command": "pwd"], profileId: pid)
        await one("env 白名单", args: ["command": "echo PATH=$PATH; echo HOME=$HOME; echo TERM=$TERM; echo TZ=$TZ; env | wc -l"], profileId: pid)
        await one("heredoc 收尾（subshell 换行坑）", args: ["command": "cat <<'EOF'\nline1\nline2\nEOF"], profileId: pid)

        log("注册表已清空? \(RunCommandMonitor.shared.running.isEmpty)")
        log("=== 探针结束 ===")
    }

    /// T6a：`sleep 20`，中间给截图留窗口。日志里逐秒记 `RunCommandMonitor.running.count`
    /// 和提示条纯函数的判定结果——**截图和日志互为佐证**：截到条 + 日志同一秒说
    /// 「命令在跑，别切走」，才叫真做了（BUG-4 上一版就是 commit message 说做了、树里没有）。
    @MainActor
    private static func longCommandProbe() async {
        resetLog()
        log("=== SBX-T6a 长命令探针（提示条截图窗口）\(ISO8601DateFormatter().string(from: Date())) ===")
        log("device: \(deviceLine())")

        let ticker = Task { @MainActor in
            for i in 0..<30 {
                let n = RunCommandMonitor.shared.running.count
                let banner = SandboxBanner.content(phase: SandboxState.shared.phase, runningCount: n)
                log("t=\(i)s running=\(n) phase=\(SandboxState.shared.phase) banner=\(banner.map { "\($0.icon)｜\($0.text)" } ?? "nil")")
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        await one("sleep 20（截图窗口）", args: ["command": "sleep 20; echo done", "timeout_seconds": 60], profileId: "probe-profile")
        ticker.cancel()

        let after = RunCommandMonitor.shared.running.count
        let bannerAfter = SandboxBanner.content(phase: SandboxState.shared.phase, runningCount: after)
        log("命令结束后 running=\(after) banner=\(bannerAfter.map { "\($0.icon)｜\($0.text)" } ?? "nil")（应为 nil = 自动收）")
        log("=== 探针结束 ===")
    }

    /// T6c ③：弹一张 shell 的 askOnce 卡，等人点。逐秒记还挂不挂着，
    /// 好证明「30s 之后卡还在」（旧逻辑这时候已经自己超时消失了）。
    @MainActor
    private static func askOnceProbe() async {
        resetLog()
        log("=== SBX-T6c askOnce 验收 \(ISO8601DateFormatter().string(from: Date())) ===")
        log("device: \(deviceLine())")
        log("answerTimeout=\(PermissionPromptCenter.answerTimeout)s presentationTimeout=\(PermissionPromptCenter.presentationTimeout)s")

        let ticker = Task { @MainActor in
            for i in 0..<70 {
                let c = PermissionPromptCenter.shared
                log("t=\(i)s pendingRequest=\(c.pendingRequest != nil ? "在" : "没了") 已上屏=\(c.presentedId != nil ? "是" : "否")")
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        let t0 = Date()
        let decision = await PermissionPromptCenter.shared.decide(.shell, detail: "$ echo t6c")
        ticker.cancel()
        let waited = Date().timeIntervalSince(t0)
        log("--- 结果 --- decision=\(decision) 等了 \(String(format: "%.1f", waited))s")
        log(decision == .allowed
            ? "✅ 露脸后才起表：等到 \(String(format: "%.0f", waited))s 点的允许，仍然拿到 allowed（旧逻辑 30s 就 timedOut 了）"
            : "❌ 拿到 \(decision)")
        log("=== 探针结束 ===")
    }

    /// 超时后睡着的进程得真没了（GCD 线程上起跑屏蔽 SIGUSR1，SIGKILL 叫不醒 sleep）。
    /// 超时结果里 output 是空的，pid 只能落文件再读。
    @MainActor
    private static func timeoutKillsSleepers() async {
        let file = "/tmp/rc-probe-sleepers"
        let sync: (String, TimeInterval) async -> ISHShellExecutionResult = { cmd, timeout in
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    cont.resume(returning: ISHShellExecutor.executeCommandSync(cmd, timeout: timeout, lineCallback: nil))
                }
            }
        }
        let r = await sync("rm -f \(file); sleep 100 & echo $! >> \(file); sh -c 'echo $$ >> \(file); exec sleep 100'", 1)
        try? await Task.sleep(for: .seconds(1))
        let alive = await sync("for p in $(cat \(file)); do kill -0 $p 2>/dev/null && echo \"ALIVE $p\" || echo \"GONE $p\"; done", 10).output
        let lines = alive.split(separator: "\n").map(String.init)
        let ok = r.error == .timeout && lines.count == 2 && lines.allSatisfy { $0.hasPrefix("GONE") }
        log("--- 超时后 sleep 真没了 ---")
        log("\(ok ? "PASS" : "FAIL") error=\(r.error.rawValue) \(lines.joined(separator: " / "))")
    }

    @MainActor
    private static func one(_ label: String, args: [String: Any], profileId: String) async {
        let t = Date()
        let r = await RunCommandTool.execute(args: args, profileId: profileId, conversationId: "probe-\(label)")
        let ms = Date().timeIntervalSince(t) * 1000
        log("--- \(label) --- (\(String(format: "%.0f", ms)) ms)")
        log(envelopeText(r))
    }

    /// 把 DeviceToolExec 打成可读原文。用 Mirror 而不是硬编字段名，
    /// 免得 envelope 结构一改探针就悄悄少报东西。
    private static func envelopeText(_ exec: DeviceToolExec) -> String {
        var lines: [String] = []
        for child in Mirror(reflecting: exec).children {
            let name = child.label ?? "?"
            var value = String(describing: child.value)
            if value.count > 1200 { value = value.prefix(600) + "…[探针侧省略 \(value.count - 1200) 字符]…" + value.suffix(600) }
            lines.append("  \(name) = \(value)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - T3a：文件库 mount 五场景

    /// 两个合成楼层，用来验「切楼层不串味」。用合成 id 而不是真楼层，
    /// 免得探针往粟粟的文件库里写垃圾。
    ///
    /// ⚠️ 这两个 id 必须在**前 8 个字母数字字符**上就分开：
    /// `FileLibraryStore.shortId`（:473-476）取的是 `prefix(8)`，而 `floorSlug` 的
    /// 兜底就是 `楼层-<shortId>`——第一版用了 `probe-floor-a` / `probe-floor-b`，
    /// 两个都塌成 `probeflo`，**两个楼层落到同一个宿主目录**，看起来像挂载串味
    /// （实际是文件库那边的哈希碰撞，见 t3a-report「顺带发现」）。
    private static let floorA = "probeAlpha"
    private static let floorB = "probeBravo"

    @MainActor
    private static func mountProbe() async {
        resetLog()
        log("=== SBX-T3a mount 探针 \(ISO8601DateFormatter().string(from: Date())) ===")
        log("device: \(deviceLine())")

        // ---- 场景 5 的前半：**任何本次挂载之前**先看 /mnt/library 里剩了什么 ----
        // boot 里已经跑过 cleanResidue，所以这里应该是空的；上一轮跑完留下的
        // symlink + meta.db 行如果没被清掉，这一条会看见它们。
        do {
            // ⚠️ 必须给**绝对** cwd：resolveCwd 走相对/缺省分支会顺手把楼层挂上，
            // 那样这条检查自己就把 probeAlpha 造出来了（第一版就是这么自欺的）。
            // 绝对路径分支直接返回，不碰 SandboxMount。
            let r = await RunCommandTool.execute(
                args: ["command": "ls -a /mnt/library; echo '--- count ---'; ls /mnt/library | wc -l",
                       "cwd": "/"],
                profileId: floorA, conversationId: "probe-residue")
            log("--- 场景5 重启后残留检查（本次挂载之前）---")
            log(envelopeText(r))
        }

        // ---- 场景 1：宿主写 → guest cat 见 ----
        let rootA = FileLibraryStore.libraryRoot(profileId: floorA)
        let hostNote = rootA.appendingPathComponent("host-written.md")
        try? "宿主写的内容\n".write(to: hostNote, atomically: true, encoding: .utf8)
        await one("场景1 宿主写→guest cat 见", args: ["command": "pwd; cat host-written.md"], profileId: floorA)

        // ---- 场景 2：guest echo > → 宿主 FileLibraryStore.list() 见 ----
        await one("场景2 guest 写", args: ["command": "echo 'guest 写的内容' > guest-written.md; ls"], profileId: floorA)
        let namesA = FileLibraryStore.list(profileId: floorA).map(\.path).sorted()
        log("场景2 宿主 FileLibraryStore.list(\(floorA)) = \(namesA)")
        let guestFile = rootA.appendingPathComponent("guest-written.md")
        log("场景2 宿主直接读回：\((try? String(contentsOf: guestFile, encoding: .utf8)) ?? "<读不到>")")

        // ---- 场景 3：中文文件名双向 ----
        let cjkHost = rootA.appendingPathComponent("宿主的笔记.md")
        try? "中文内容\n".write(to: cjkHost, atomically: true, encoding: .utf8)
        await one("场景3 中文名 guest 读宿主的", args: ["command": "cat 宿主的笔记.md"], profileId: floorA)
        await one("场景3 中文名 guest 写", args: ["command": "echo '来自 guest 的中文' > 来自guest.md; ls"], profileId: floorA)
        let namesCJK = FileLibraryStore.list(profileId: floorA).map(\.path).sorted()
        log("场景3 宿主 list 再看 = \(namesCJK)")
        let cjkGuest = rootA.appendingPathComponent("来自guest.md")
        log("场景3 宿主读 guest 写的中文名文件：\((try? String(contentsOf: cjkGuest, encoding: .utf8)) ?? "<读不到>")")

        // ---- 场景 4：切楼层不串味 ----
        let rootB = FileLibraryStore.libraryRoot(profileId: floorB)
        try? "这是B楼层\n".write(to: rootB.appendingPathComponent("only-in-b.md"), atomically: true, encoding: .utf8)
        await one("场景4 切到 B 楼层", args: ["command": "pwd; ls"], profileId: floorB)
        await one("场景4 /mnt/library 下两个挂载点并存", args: ["command": "ls /mnt/library"], profileId: floorB)
        await one("场景4 回 A 楼层内容没串", args: ["command": "pwd; ls"], profileId: floorA)

        log("本进程挂载表 = \(SandboxMount.currentMounts)")
        log("slug(A)=\(SandboxMount.slug(for: floorA)) slug(B)=\(SandboxMount.slug(for: floorB))")
        log("=== 探针结束（场景5 后半：再跑一次本探针，看开头的残留检查是否为空）===")
    }

    // MARK: - T3b：预热 / change consumer / iCloud / 逃逸

    @MainActor
    private static func t3bProbe() async {
        resetLog()
        log("=== SBX-T3b 探针 \(ISO8601DateFormatter().string(from: Date())) ===")
        log("device: \(deviceLine())")

        await changeConsumerCheck()
        await iCloudBranchCheck()
        await escapeMatrix()

        log("change ring 丢弃计数 = \(SandboxChangeNotifier.droppedCount)")
        log("=== T3b 探针结束 ===")
    }

    // ---- ② change consumer 节流 ----

    @MainActor
    private static func changeConsumerCheck() async {
        log("### ② change consumer 节流")
        let floor = floorA
        _ = SandboxMount.mount(profileId: floor)
        _ = SandboxChangeNotifier.drainCounters()

        var got = 0
        let token = NotificationCenter.default.addObserver(
            forName: .fileLibraryDidChange, object: nil, queue: .main) { _ in got += 1 }

        // 一条命令写 20 个文件：原始事件必然远多于 20，通知应该被合并成极少的几次
        await one("② guest 连写 20 个文件", args: ["command": "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo hi > burst-$i.txt; done; ls burst-*.txt | wc -l"], profileId: floor)
        // 等两个节流窗口，让最后一批 flush 出来
        try? await Task.sleep(nanoseconds: 600_000_000)

        let c = SandboxChangeNotifier.drainCounters()
        log("② 原始事件 \(c.events) 条 → post 通知 \(c.posts) 次；观察者收到 \(got) 次（窗口 \(SandboxChangeNotifier.throttleInterval)s）")
        log("② 判定：\(c.posts > 0 && c.posts < c.events ? "合并生效" : (c.posts == 0 ? "⚠️ 一次都没收到" : "⚠️ 没合并"))")
        NotificationCenter.default.removeObserver(token)
    }

    // ---- ③ iCloud 分支 ----

    @MainActor
    private static func iCloudBranchCheck() async {
        log("### ③ iCloud 分支")
        let key = FileLibraryStore.iCloudEnabledKey
        let original = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        let cloudRoot = FileLibraryStore.iCloudFloorsRoot()
        log("③ iCloudEnabled=\(FileLibraryStore.iCloudEnabled) iCloudFloorsRoot=\(cloudRoot?.path ?? "nil")")

        if FileLibraryStore.iCloudEnabled, cloudRoot != nil {
            await one("③ iCloud 楼层跑命令", args: ["command": "pwd"], profileId: "probeICloud")
            log("③ 期望：cwd=/root 且 envelope 带 note")
        } else {
            log("③ ⚠️ 本机 iCloud 容器不可用（未登录 / 容器未就绪），`.skippedICloud` 分支进不去；")
            log("③    只能确认代码路径的判定条件为 false，**结论维持 PLAUSIBLE**")
            let backend = ISHShellBackend()
            log("③ 直接问后端 resultNote(probeICloud) = \(backend.resultNote(profileId: "probeICloud") ?? "nil")")
            switch SandboxMount.mount(profileId: "probeICloud") {
            case .skippedICloud: log("③ SandboxMount 判定 = skippedICloud")
            case .mounted(let g): log("③ SandboxMount 判定 = mounted(\(g))（说明容器不可用，走了正常挂载）")
            case .refusedSymlinkEscape(let paths): log("③ SandboxMount 判定 = refusedSymlinkEscape(\(paths))")
            case .failed(let m): log("③ SandboxMount 判定 = failed(\(m))")
            }
        }
        UserDefaults.standard.set(original, forKey: key)
        log("③ iCloud 开关已还原为 \(original)")
    }

    // ---- ④ 逃逸矩阵 ----

    @MainActor
    private static func escapeMatrix() async {
        log("### ④ 逃逸矩阵")
        let floor = floorA
        guard case .mounted(let guestPath) = SandboxMount.mount(profileId: floor) else {
            log("④ 挂载失败，跳过"); return
        }
        let hostRoot = FileLibraryStore.libraryRoot(profileId: floor)

        // E1 guest 造 symlink 指向 guest 内的 /etc/passwd
        await one("④E1 ln -s /etc/passwd leak", args: ["command": "ln -sf /etc/passwd leak; cat leak | head -2; echo '--- host ---'"], profileId: floor)
        log("④E1 宿主上 leak 的真实身份：\(hostFileKind(hostRoot.appendingPathComponent("leak")))")

        // E2 guest 造相对 symlink 往上跳
        await one("④E2 ln -s ../../ up", args: ["command": "ln -sf ../../ up; ls up 2>&1 | head -5"], profileId: floor)
        log("④E2 宿主上 up 的真实身份：\(hostFileKind(hostRoot.appendingPathComponent("up")))")

        // E3 硬链接跨挂载点
        // 自带素材：Air 上没跑过 T3a 的 mount 探针，不能依赖 host-written.md 存在
        await one("④E3 硬链接跨挂载点", args: ["command": "echo hardlink-src > e3-src.md; rm -f /root/hardlink; ln e3-src.md /root/hardlink 2>&1; ls -l /root/hardlink 2>&1 | head -2; cat /root/hardlink 2>&1 | head -1"], profileId: floor)

        // E4 相对路径越界
        await one("④E4 ls ../../..", args: ["command": "ls ../../.. 2>&1 | head -8"], profileId: floor)

        // E5 宿主侧在 filesystem/ 下放一个指向 .memorypalace/ 的真 symlink
        let memoryDir = hostRoot.deletingLastPathComponent().appendingPathComponent(".memorypalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try? "记忆树的秘密\n".write(to: memoryDir.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        let linkPath = hostRoot.appendingPathComponent("peek")
        try? FileManager.default.removeItem(at: linkPath)
        try? FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: memoryDir)
        log("④E5 宿主已建真 symlink peek → \(memoryDir.path)")
        await one("④E5 guest 读宿主造的 symlink", args: ["command": "ls -la peek 2>&1 | head -3; echo '--- ls peek/ ---'; ls peek/ 2>&1 | head -5; echo '--- cat ---'; cat peek/secret.md 2>&1 | head -3"], profileId: floor)

        log("④ 挂载点 = \(guestPath)，宿主源 = \(hostRoot.path)")

        // ---- E5 修复复验（T3c ②c）：越界 symlink 在 → 拒挂；删掉 → 挂成功 ----
        log("### ⑤ E5 修复复验")
        let e5Floor = "probeEscape"
        let e5Root = FileLibraryStore.libraryRoot(profileId: e5Floor)
        let e5Outside = e5Root.deletingLastPathComponent().appendingPathComponent(".memorypalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: e5Outside, withIntermediateDirectories: true)
        try? "记忆树的秘密\n".write(to: e5Outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        let e5Link = e5Root.appendingPathComponent("peek")
        try? FileManager.default.removeItem(at: e5Link)
        try? FileManager.default.createSymbolicLink(at: e5Link, withDestinationURL: e5Outside)
        log("⑤ 已在库里放越界 symlink peek → ../.memorypalace")
        log("⑤ escapingSymlinks 扫出 = \(SandboxMount.escapingSymlinks(in: e5Root))")
        switch SandboxMount.mount(profileId: e5Floor) {
        case .refusedSymlinkEscape(let paths): log("⑤ ✅ 挂载被拒，违规路径 = \(paths)")
        case .mounted(let g): log("⑤ ❌ 竟然挂上了：\(g)")
        case .skippedICloud: log("⑤ skippedICloud（意外）")
        case .failed(let m): log("⑤ failed：\(m)")
        }
        let backend = ISHShellBackend()
        log("⑤ resultNote = \(backend.resultNote(profileId: e5Floor) ?? "nil")")
        await one("⑤ 拒挂后 cwd 应回落 /root", args: ["command": "pwd"], profileId: e5Floor)

        // 删掉违规 symlink 后应当能挂上
        try? FileManager.default.removeItem(at: e5Link)
        log("⑤ 删掉 peek 后 escapingSymlinks = \(SandboxMount.escapingSymlinks(in: e5Root))")
        switch SandboxMount.mount(profileId: e5Floor) {
        case .mounted(let g): log("⑤ ✅ 清理后挂载成功：\(g)")
        case .refusedSymlinkEscape(let p): log("⑤ ❌ 仍被拒：\(p)")
        case .skippedICloud: log("⑤ skippedICloud（意外）")
        case .failed(let m): log("⑤ failed：\(m)")
        }
        await one("⑤ 清理后 cwd 应是挂载点", args: ["command": "pwd; ls"], profileId: e5Floor)
    }

    private static func hostFileKind(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "<不存在>" }
        let type = (attrs[.type] as? FileAttributeType)?.rawValue ?? "?"
        let size = (attrs[.size] as? Int) ?? -1
        var extra = ""
        if type == FileAttributeType.typeRegular.rawValue, size < 200,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            extra = " 内容=\(content.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "\(type) size=\(size)\(extra)"
    }

    // MARK: - T4：切后台复现 / 极端输出形状 / RSS 三点

    @MainActor
    private static func t4Probe() async {
        resetLog()
        log("=== SBX-T4 探针 \(ISO8601DateFormatter().string(from: Date())) ===")
        log("device: \(deviceLine())")

        // ---- ④ lineCallback 极端形状 ----
        log("### ④ lineCallback 极端形状（主队列压力）")
        await extremeShape("yes | head -200000", label: "20 万行短行")
        await extremeShape("seq 1 200000", label: "seq 20 万行")

        // ---- ① RSS 三点（此时 boot 已发生，三点都记上了）----
        log("### ① RSS 三点（产品路径）")
        log(SandboxRSS.summary())

        // ---- ③ 切后台 → cancelled 复现 ----
        log("### ③ 切后台复现：起 sleep 90，请在 5 秒内把 app 切后台，40 秒后回前台")
        let started = Date()
        let task = Task { @MainActor in
            await RunCommandTool.execute(args: ["command": "sleep 90; echo finished"],
                                         profileId: floorA, conversationId: "t4-bg")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        log("③ 命令已起，注册表 = \(RunCommandMonitor.shared.running.map(\.conversationId))")
        let r = await task.value
        log("③ 命令返回，总耗时 \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        log(envelopeText(r))
        log("③ 返回后注册表 = \(RunCommandMonitor.shared.running.map(\.conversationId))（应为空）")
        log("③ 注册表已清空? \(RunCommandMonitor.shared.running.isEmpty)")

        log("=== T4 探针结束 ===")
    }

    @MainActor
    private static func extremeShape(_ command: String, label: String) async {
        // 主线程占用：命令跑的同时用一个 1ms 心跳数「本该跳多少次 vs 实际跳了多少次」，
        // 差得多说明主队列被 lineCallback 压住了（ISHShellExecutor 的逐行回调是
        // dispatch_async 到 main 的，200k 行 = 200k 个主队列任务）。
        var beats = 0
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                beats += 1
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let t = Date()
        let r = await RunCommandTool.execute(args: ["command": command, "timeout_seconds": 120],
                                             profileId: floorA, conversationId: "extreme-\(label)")
        let wall = Date().timeIntervalSince(t)
        beat.cancel()
        let expected = Int(wall * 1000)
        let ratio = expected > 0 ? Double(beats) / Double(expected) * 100 : 0
        log("--- ④ \(label): `\(command)` ---")
        log("总耗时 \(String(format: "%.2f", wall)) s；主线程心跳 \(beats)/\(expected) 次（\(String(format: "%.0f", ratio))%，越低说明主队列被压得越狠）")
        log(envelopeText(r))
    }

    // MARK: - 探针基础设施

    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    private static func deviceLine() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #if targetEnvironment(simulator)
        let kind = "simulator"
        #else
        let kind = "device"
        #endif
        return "\(kind) machine=\(machine) iOS=\(ProcessInfo.processInfo.operatingSystemVersionString) mem=\(ProcessInfo.processInfo.physicalMemory / 1_048_576)MB"
    }

    private static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(logName)
    }

    private static func resetLog() {
        probeStart = Date()
        guard let url = logURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    private static var probeStart = Date()

    private static func log(_ line: String) {
        let stamped = String(format: "[+%6.2fs] ", Date().timeIntervalSince(probeStart)) + line
        print("[SBX] \(stamped)")
        guard let url = logURL else { return }
        let payload = stamped + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(payload.utf8))
            try? handle.close()
        } else {
            try? payload.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

#endif
