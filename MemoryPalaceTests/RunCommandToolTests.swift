#if os(macOS)
import XCTest
@testable import 记忆花园

/// plan-离线沙箱-phase1 §3：echo / 非零退出 / 超时杀树 / 截断 / 默认 cwd / 权限映射红线。
@MainActor
final class RunCommandToolTests: XCTestCase {
    /// 随机段放最前：楼层目录名只取 profileId 前 8 个字母数字，原来的 `test-run-command-…` 全截成 `testrunc`，
    /// 每条测试都在真实 ~/Documents 里多起一个 `楼层-testrunc-N`（09-09 清掉 617 个）。
    private let profileId = "rc\(UUID().uuidString.prefix(6))-run-command-test"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: profileId).deletingLastPathComponent())
        FileLibraryStore.forgetSlug(profileId: profileId)   // 假楼层映射别留在真实数据里（review-mac-hang-probe）
        super.tearDown()
    }

    private func run(_ args: [String: Any]) async -> [String: Any] {
        let r = await RunCommandTool.execute(args: args, profileId: profileId, conversationId: "conv-test")
        return (try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any]) ?? ["ok": false, "raw": r.text]
    }

    func testEcho() async {
        let r = await run(["command": "echo hi"])
        XCTAssertEqual(r["ok"] as? Bool, true)
        let data = r["data"] as? [String: Any]
        XCTAssertEqual(data?["exit_code"] as? Int, 0)
        XCTAssertEqual(data?["stdout"] as? String, "hi\n")
        XCTAssertEqual(data?["stderr"] as? String, "")
    }

    func testNonZeroExitIsAResultNotAnError() async {
        let r = await run(["command": "echo oops >&2; exit 3"])
        XCTAssertEqual(r["ok"] as? Bool, true, "非零退出码是合法结果")
        let data = r["data"] as? [String: Any]
        XCTAssertEqual(data?["exit_code"] as? Int, 3)
        XCTAssertEqual(data?["stderr"] as? String, "oops\n")
    }

    func testTimeoutKillsWholeTree() async {
        // 用唯一命名的 sh 脚本包 sleep（拷贝 /bin/sleep 会被 AMFI 杀），ps 里按脚本路径精确找自己起的进程
        let marker = "mp-run-command-test-\(Int(Date().timeIntervalSince1970)).sh"
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(marker).path
        try? "sleep 100\n".write(toFile: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: script) }
        let t0 = Date()
        let r = await run(["command": "sh '\(script)' & sh '\(script)' & sh '\(script)'", "timeout_seconds": 1])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? String, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4, "超时后应 ~1.5s 内返回")
        // 树被回收：不该再有本测试起的 sleep（pgrep 按祖先 zsh 的 marker 找不到，改数 sleep 100 的总数变化）
        try? await Task.sleep(nanoseconds: 300_000_000)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid,ppid,command"]
        let pipe = Pipe(); ps.standardOutput = pipe
        try? ps.run()
        // 先读到 EOF 再 wait：ps 输出超过管道缓冲会互等死锁
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let sleeps = out.split(separator: "\n").filter { $0.contains(marker) }
        XCTAssertEqual(sleeps.count, 0, "不应残留本测试起的 sleep：\n\(sleeps.joined(separator: "\n"))")
    }

    func testTruncationKeepsHeadAndTail() async {
        let r = await run(["command": "yes | head -c 40000"])
        let data = r["data"] as? [String: Any]
        XCTAssertEqual(data?["truncated"] as? Bool, true)
        let out = data?["stdout"] as? String ?? ""
        XCTAssertTrue(out.contains("已截断"))
        XCTAssertLessThan(out.count, RunCommandTool.outputCap + 200)
    }

    func testDefaultCwdIsLibraryRootAndContainment() async {
        let r = await run(["command": "pwd"])
        let data = r["data"] as? [String: Any]
        let root = FileLibraryStore.libraryRoot(profileId: profileId).standardizedFileURL.path
        XCTAssertEqual((data?["stdout"] as? String)?.trimmingCharacters(in: .newlines), root)
        XCTAssertEqual(data?["cwd"] as? String, root)

        let escape = await run(["command": "pwd", "cwd": "../.."])
        XCTAssertEqual(escape["ok"] as? Bool, false)
        XCTAssertEqual((escape["error"] as? [String: Any])?["code"] as? String, "invalid_param")

        let absolute = await run(["command": "pwd", "cwd": "/tmp"])
        XCTAssertEqual(absolute["ok"] as? Bool, true, "绝对路径放行")

        // 库内 symlink 指向库外：相对 cwd 不能借它逃出（QA 探针题）
        let link = FileLibraryStore.libraryRoot(profileId: profileId).appendingPathComponent("escape-link")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Users"))
        let viaLink = await run(["command": "pwd", "cwd": "escape-link"])
        try? FileManager.default.removeItem(at: link)
        XCTAssertEqual(viaLink["ok"] as? Bool, false, "symlink 逃逸应被拒")
    }

    func testUnboundedOutputStaysBounded() async {
        // `yes` 无限输出到超时：内存有界（头 64K + 尾 64K），返回及时，stdout 长度不随时长增长
        let t0 = Date()
        let r = await run(["command": "yes", "timeout_seconds": 2])
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? String, "timeout")
        let msg = (r["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertLessThan(msg.count, 6000, "超时消息只带各 2000 字符的输出尾巴")
        // 正常返回路径：300KB 输出 → 中间被丢弃（头 64K + 尾 64K），再被 15000 字符头尾截断
        let big = await run(["command": "yes | head -c 300000"])
        let data = big["data"] as? [String: Any]
        XCTAssertEqual(data?["truncated"] as? Bool, true)
        let out = data?["stdout"] as? String ?? ""
        XCTAssertLessThan(out.count, RunCommandTool.outputCap + 200)
        XCTAssertTrue(out.contains("已截断"), "外层 15000 字符截断标记")
    }

    func testSelfKillIsFailedNotCancelled() async {
        // 命令自己 kill -TERM 自己：不是用户停止，不能报 cancelled 误导模型（kimi 评审）
        let r = await run(["command": "kill -TERM $$"])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? String, "failed")
        let msg = (r["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(msg.contains("信号 15"), msg)
        XCTAssertFalse(msg.contains("用户停止"), msg)
    }

    func testCleanStripsANSIAndCarriageReturns() {
        XCTAssertEqual(RunCommandTool.clean("\u{1B}[0;32mok\u{1B}[0m\n"), "ok\n")
        XCTAssertEqual(RunCommandTool.clean("10%\r50%\r100%\n"), "100%\n")
        XCTAssertEqual(RunCommandTool.clean("a\r\nb"), "a\nb")
    }

    // MARK: 权限红线

    func testShellDomainNeverFallsIntoToolsMaster() {
        XCTAssertEqual(PermissionDomain.forTool(named: "run_command"), .shell)
        XCTAssertEqual(PermissionDomain.shell.defaultLevel, .askOnce)
        XCTAssertTrue(PermissionDomain.toolDomains.contains(.shell))
        XCTAssertTrue(ConfigSchema.allScalarEntries.contains { $0.key == "perm.shell" && !$0.aiWritable }, "perm.shell 必须在 AI 不可写黑名单")
    }

    func testShellGrantDoesNotTravelInBackup() {
        // 全量备份导入剥掉 shell 授权，其他域原样保留（codex 评审阻塞 3）
        XCTAssertEqual(PermissionGrants.strippingDeviceLocal("shell:allow,calendar:allow,clipboard:deny"), "calendar:allow,clipboard:deny")
        XCTAssertEqual(PermissionGrants.strippingDeviceLocal("shell:deny"), "")
        XCTAssertEqual(PermissionGrants.strippingDeviceLocal(nil), "")
        XCTAssertFalse(PermissionGrants(raw: PermissionGrants.strippingDeviceLocal("shell:allow")).isAllowed(.shell))
    }

    // MARK: 「运行」面板（plan §1.7）

    func testMonitorClearedAfterExecute() async {
        _ = await run(["command": "echo hi"])
        XCTAssertTrue(RunCommandMonitor.shared.running.filter { $0.conversationId == "conv-test" }.isEmpty)
    }

    func testMonitorSeesRunningCommandAndStopClearsIt() async {
        let key = "conv-monitor-\(UUID().uuidString.prefix(6))"
        let task = Task { await RunCommandTool.execute(args: ["command": "sleep 30", "timeout_seconds": 20], profileId: profileId, conversationId: key) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let seen = RunCommandMonitor.shared.running.first { $0.conversationId == key }
        XCTAssertEqual(seen?.firstLine, "sleep 30")
        RunCommandTool.cancel(conversationId: key)
        let r = await task.value
        XCTAssertTrue(r.text.contains("用户停止"), r.text)
        XCTAssertNil(RunCommandMonitor.shared.running.first { $0.conversationId == key })
    }

    func testSnapshotParsers() {
        let ps = """
          PID  PGID     ELAPSED COMM
        11 11 00:05 /bin/zsh
        12 11 00:04 /usr/bin/python3
        13 99 01:00 /bin/sleep
        """
        let procs = RunPanelSnapshot.parsePS(ps, pgids: [11])
        XCTAssertEqual(procs.map(\.pid), [11, 12])
        XCTAssertEqual(procs.map(\.comm), ["zsh", "python3"])
        let lsof = """
        COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        python3   12 susu    3u  IPv4 0x1      0t0  TCP *:8765 (LISTEN)
        python3   12 susu    4u  IPv6 0x2      0t0  TCP [::1]:8765 (LISTEN)
        node      15 susu    5u  IPv4 0x3      0t0  TCP 127.0.0.1:3000 (LISTEN)
        """
        let ports = RunPanelSnapshot.parseLSOF(lsof)
        XCTAssertEqual(ports.map(\.port), [3000, 8765], "同进程 IPv4/IPv6 同端口合并成一行")
        XCTAssertEqual(ports.first?.comm, "node")
    }

    func testRegisteredInDispatcher() {
        XCTAssertTrue(DeviceToolDispatcher.handles("run_command"))
        XCTAssertTrue(DeviceToolDispatcher.systemHint.contains("run_command"))
        XCTAssertFalse(DeviceToolDispatcher.systemHint.contains("沙箱"), "macOS 后端零隔离，文案不许叫沙箱")
        XCTAssertFalse(PermissionDomain.shell.summary.contains("沙箱"))
        XCTAssertFalse(RunCommandTool.definition.description.contains("沙箱"))
    }

    // MARK: - T2 双后端（plan §1.4）

    /// 本 target 是 macOS-only（project.yml:291 `platform: macOS`），所以这里跑到的
    /// 一定是 macOS 后端；iOS 后端的同套场景由 `SandboxProbe` 在模拟器/真机上跑
    /// （仓库没有 iOS 单测 target，见 t2-report）。
    func testBackendIsMacOnHost() {
        XCTAssertTrue(RunCommandTool.backend is MacShellBackend)
        XCTAssertFalse(RunCommandTool.backend.toolDescription.contains("沙箱"))
    }

    /// 有界收集是两个后端共用的（macOS 喂管道 Data，iOS 喂逐行回调），
    /// 压缩策略只有这一份实现——这里锚死头尾保留 + 丢弃计数报的是**原始**总量。
    func testBoundedOutputKeepsHeadAndTailAndReportsRealTotal() {
        let b = BoundedOutput()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 32 * 1024)
        for _ in 0..<8 { b.append(chunk) }          // 256 KB > head 64K + tail 64K
        let text = b.text
        XCTAssertTrue(text.contains("输出共 \(8 * 32 * 1024) 字节"), "丢弃标记要报原始总量，不是压缩后长度")
        XCTAssertTrue(text.contains("中间已丢弃"))
        XCTAssertLessThan(text.utf8.count, 200 * 1024, "压缩后不该接近原始大小")
    }

    /// 小于上限时不该出现丢弃标记（免得每条短命令都被加一行噪音）
    func testBoundedOutputNoMarkerWhenSmall() {
        let b = BoundedOutput()
        b.appendLine("hello")
        XCTAssertEqual(b.text, "hello\n")
    }

    /// cwd 语义在协议层：macOS 后端解出的是宿主真实目录
    func testMacBackendResolvesCwdToLibraryRoot() {
        let backend = MacShellBackend()
        switch backend.resolveCwd(nil, profileId: profileId) {
        case .success(let path):
            XCTAssertEqual(path, FileLibraryStore.libraryRoot(profileId: profileId)
                .standardizedFileURL.resolvingSymlinksInPath().path)
        case .failure(let e):
            XCTFail("默认 cwd 应该解成文件库根：\(e.message)")
        }
        if case .success = backend.resolveCwd("../..", profileId: profileId) {
            XCTFail("相对路径逃出库根必须被拒")
        }
    }

    /// BUG-6：`prepare()` 抛的 `CwdError` 在共享层走 `error.localizedDescription`
    /// （`RunCommandTool.swift:65`）。裸 `struct: Error` 会退化成「…CwdError error 1」，
    /// iOS 侧「沙箱已重置，请重启 app」整句被吃掉。锚这条：**存在性(existential)派发下**
    /// 拿到的必须是原文，且原文原样进 envelope。
    func testCwdErrorKeepsMessageThroughLocalizedDescription() {
        let expected = "沙箱已重置，请重启 app"
        let err: any Error = RunCommandTool.CwdError(message: expected)
        XCTAssertEqual(err.localizedDescription, expected, "文案不能退化成 NSError 默认描述")

        let envelope = DeviceToolIO.fail("not_available", err.localizedDescription)
        let json = (try? JSONSerialization.jsonObject(with: Data(envelope.text.utf8))) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "not_available")
        XCTAssertEqual(error?["message"] as? String, expected)
    }

    // MARK: - BUG-4 顶部提示条「显示什么」

    /// 就绪 + 有命令在跑 → 提醒别切走（iOS 切后台命令会原地冻结，这是唯一的事前警告）
    func testBannerWarnsWhileCommandRunning() {
        let c = SandboxBanner.content(phase: .ready, runningCount: 1)
        XCTAssertEqual(c, SandboxBanner.Content(text: "命令在跑，别切走", icon: .running))
    }

    /// 命令跑完自动收；就绪且没命令 = 什么都不显示
    func testBannerHidesWhenNothingRunning() {
        XCTAssertNil(SandboxBanner.content(phase: .ready, runningCount: 0))
        XCTAssertNil(SandboxBanner.content(phase: .idle, runningCount: 0))
    }

    /// 相位提示优先级高于「命令在跑」：沙箱还没起来时命令卡在 prepare 里，
    /// 该说的是「正在准备沙箱…」
    func testPhaseBannerOutranksRunningBanner() {
        XCTAssertEqual(SandboxBanner.content(phase: .installing, runningCount: 3),
                       SandboxBanner.Content(text: "正在准备小电脑…", icon: .progress))
        XCTAssertEqual(SandboxBanner.content(phase: .booting, runningCount: 3),
                       SandboxBanner.Content(text: "正在启动小电脑…", icon: .progress))
        XCTAssertEqual(SandboxBanner.content(phase: .failed("boot 失败"), runningCount: 3),
                       SandboxBanner.Content(text: "小电脑启动失败：boot 失败", icon: .failure))
    }

    /// 非就绪相位就算没提示文案也不冒「命令在跑」（idle = 还没人碰过沙箱）
    func testIdlePhaseNeverShowsRunningBanner() {
        XCTAssertNil(SandboxBanner.content(phase: .idle, runningCount: 2))
    }
}
#endif
