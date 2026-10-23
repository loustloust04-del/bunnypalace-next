#if (PERF_BENCH || DEBUG) && os(iOS)
import Foundation
import SwiftData
import SwiftUI
import UIKit
import os
import MachO

/// perf-flash 测量台（plan-perf-flash M2，astra R1 修订）。计时口径 = Release + `PERF_BENCH` 编译条件。
/// 进程角色由 env 决定，互斥：
/// - `MP_PERF_SEED=1|bulk`：准备进程——记下原楼层、建/切测试楼层、补种，写结果后退出（不进基线）
/// - `MP_PERF_RESTORE=1`：收尾进程——切回记下的原楼层后退出
/// - `MP_PERF_RUN=1`：测量进程——**不切楼层**，入口断言已在测试楼层；跑完 S1–S4 写
///   `Documents/perf/run-<MP_PERF_RUNID>.json` 后 exit(0)
/// 都不设时除计数自增外零行为。
enum PerfHarness {
    static let env = ProcessInfo.processInfo.environment
    static let isActive = env["MP_PERF_RUN"] == "1"
    static let seedMode = env["MP_PERF_SEED"]
    static let restoreRequested = env["MP_PERF_RESTORE"] == "1"
    static let shotMode = env["MP_PERF_SHOT"] == "1"
    /// 被动模式：真手指（XCUITest 坐标拖动）翻页，从 willEndDragging 起算
    static let observeMode = env["MP_PERF_OBSERVE"] == "1"
    static let variant = env["MP_PERF_VARIANT"] ?? "A"
    /// 只跑部分场景（录 trace 用）：cold,open,flip；缺省全跑
    static let scenarios = Set((env["MP_PERF_SCENARIOS"] ?? "cold,open,flip").split(separator: ",").map(String.init))
    /// 录 trace 时给 xctrace attach 留时间：冷启动样本记完后再等几秒才开始后续场景
    static let startDelay = Double(env["MP_PERF_DELAY"] ?? "") ?? 0
    static let runId = env["MP_PERF_RUNID"] ?? "\(Int(Date().timeIntervalSince1970))-\(variant)"
    static let profileId = "perf-bench-profile"
    static let convA = "perf-flash-conv-A"
    static let convB = "perf-flash-conv-B"
    static let originalProfileKey = "perfFlashOriginalProfileId"
    static let signposter = OSSignposter(subsystem: "com.susu.MemoryPalace.perf", category: .pointsOfInterest)
    static var anyRole: Bool { isActive || observeMode || seedMode != nil || restoreRequested }
    /// 严格测量角色（chatV1，plan-chat-list-perf-p0 §2 / §3）：env 两条进程启动即可判，钩子在 prepare 之前也生效（只会更严）；
    /// 第三条「启动楼层 = bench」由 Driver 入口断言，不满足写失败退出、不测。非观察：插入点首句读它，不改任何订阅
    static let strictMeasure = isActive && env["MP_PERF_PROTOCOL"] == "chatV1"
    /// 静默网络（R4 K-01 / C-03）：chatV1 下测量 / seed / restore 三种进程都不连 CC hub / MCP / agora / models.dev——
    /// seed / restore 也会带她的 token 起连生产 hub（本仓铁律：严禁测试流量）。Router 陷阱仍只看 strictMeasure
    static let quietNetwork = (isActive || seedMode != nil || restoreRequested) && env["MP_PERF_PROTOCOL"] == "chatV1"
    /// 外发自测（MP_PERF_TEST_OUTBOUND=1）经真实 Router 入口要一个 ProviderManager 实参；陷阱在 provider 查找之前，不读任何凭据
    @MainActor static weak var providers: ProviderManager?
    /// 纵切 6：S5 调真实 sendMessage 要楼层与 preset（同 CardFlowView 发送：currentProfile + preset(byId: presetId)）
    @MainActor static weak var profiles: ProfileManager?
    @MainActor static weak var presets: PresetManager?
    /// 纵切 6 反作弊测试钩子（只在严格测量角色下生效）：`MP_PERF_TEST_STREAM_BLANK=1` 流式期间正文快照恒空（不显示字）；
    /// `MP_PERF_TEST_DROP_FINISH_JUMP=1` 收尾导航写的 scrollToNodeId 不被列表消费
    static let testBlankStream = strictMeasure && env["MP_PERF_TEST_STREAM_BLANK"] == "1"
    static let testDropFinishJump = strictMeasure && env["MP_PERF_TEST_DROP_FINISH_JUMP"] == "1"
    /// R7 C-01 反例：`MP_PERF_TEST_STREAM_STALL=<N>` 流式正文快照只取原文前 N 字（渲染停在中途、供给继续）→ 未收敛 / 晚到必须判出
    static let testStallStream: Int? = strictMeasure ? env["MP_PERF_TEST_STREAM_STALL"].flatMap(Int.init) : nil
    /// restore 进程的判定失败（找不到原楼层 / 切换没落地），Driver 写进 JSON
    @MainActor static var restoreFailure: String?
    /// seed 进程覆盖前的恢复键（R4 C-01 证据，chatV1 seed JSON 带出）
    @MainActor static var seedKeyBefore: String?
    /// R4 C-02：L / D / S 只在 chatV1 seed 里种。MP_PERF_TEST_SEED_AS_LEGACY = 自测：网络仍静默，种植判定按 legacy 走
    static var seedProtocol: String? { env["MP_PERF_TEST_SEED_AS_LEGACY"] == "1" ? nil : env["MP_PERF_PROTOCOL"] }

    /// launchV2 下在 xctrace os_signpost 轨道打点（首启测量：开屏阶段 / 欢迎页出现）
    static func mark(_ name: String) {
        guard env["MP_PERF_LAUNCH_V2"] == "1" else { return }
        signposter.emitEvent("mark", "\(name, privacy: .public)")
    }

    /// 进程启动时刻（p_starttime 墙钟锚定到 CACurrentMediaTime 单调钟）；读失败时标失败，不伪造
    nonisolated(unsafe) static var processStart: Double = 0
    nonisolated(unsafe) static var processStartOK = false
    /// App.init 函数体首行（在 @State 属性初始化之后，不是 main）
    nonisolated(unsafe) static var appInitBody: Double = 0
    nonisolated(unsafe) static var container: ModelContainer?
    nonisolated(unsafe) static var profileAtLaunch = ""
    /// 异步 markdown 排版在途数（>3000 字消息走异步，首屏要等它们落地才算能用）
    nonisolated(unsafe) static var markdownPending = 0
    /// chatV1 操作请求 ID（plan-chat-list-perf-p0 §4.1）：测量台单调分配，异步回调在调度 / 构造时捕获；非观察
    nonisolated(unsafe) static var currentReqId = 0
    /// R5 C-08 测试钩子：`MP_PERF_TEST_APPLY_DELAY_MS` 让测量台点名的那个请求（testDelayApplyReq）后台建树后再睡这么久，
    /// 强制它迟到；只在严格测量角色的 A→B→A 冒烟里点名，其余请求不受影响
    static let testApplyDelayMs = strictMeasure ? Double(env["MP_PERF_TEST_APPLY_DELAY_MS"] ?? "") ?? 0 : 0
    nonisolated(unsafe) static var testDelayApplyReq = -1

    @MainActor static weak var paging: PagingViewController?
    @MainActor static weak var viewModel: ConversationViewModel?
    @MainActor static var modelContext: ModelContext?
    @MainActor static var openFromList: ((Conversation) -> Void)?
    @MainActor static var listRegistration: (vc: String, epoch: Int, layout: Int, profile: String)?
    @MainActor static func registerList(_ signal: LaunchPageSignal?, profile: String, open: @escaping (Conversation) -> Void) {
        guard let owner = signal?.state.owner ?? paging else { return }
        let state = owner.launchReadiness
        guard state.valid, state.profile == profile else { return }
        if let signal, signal.epoch != state.epoch { return }
        let epoch = state.epoch
        owner.perfListAction = open // 所有权随 VC；全局入口只 weak 持有 VC，不挂住旧 Sidebar/VM/context。
        listRegistration = (state.vcID, epoch, state.layoutGeneration, state.profile)
        openFromList = { [weak owner] conversation in
            guard let owner else { return }
            let state = owner.launchReadiness
            guard state.valid, state.epoch == epoch, paging === owner,
                  listRegistration?.vc == state.vcID, listRegistration?.layout == state.layoutGeneration,
                  !state.enabled || state.isPrepared(0), conversation.profileId == state.profile else { return }
            owner.perfListAction?(conversation)
        }
    }
    @MainActor static func refreshListRegistration(_ state: LaunchReadiness) {
        guard let registration = listRegistration, registration.vc == state.vcID,
              registration.epoch == state.epoch, registration.profile == state.profile else { return }
        listRegistration = (state.vcID, state.epoch, state.layoutGeneration, state.profile)
    }
    @MainActor static var dragFrames: FrameMonitor?
    @MainActor static func noteDragBegan(state: LaunchReadiness, from: Int) {
        if observeMode {
            dragFrames?.stop()
            let frames = FrameMonitor(); frames.start(); dragFrames = frames
        }
        LaunchTrace.event("dragBegan", state: state, fields: ["from": from, "source": isActive ? "syntheticDelegate" : "recognition"])
    }
    @MainActor static weak var inputField: UITextView?
    /// 开对话就绪：目标当前节点的气泡已建（反转列表先建最新，旧行随后继续建，不能只看「最后一个」）
    @MainActor static var watchBubbleId: String?
    @MainActor static var watchedBubbleMade = false
    /// 真手指松手（PagingViewController.scrollViewWillEndDragging，目标页 ≠ 当前页）
    @MainActor static func noteFingerRelease(from: Int, to: Int) {
        LaunchTrace.event("fingerRelease", fields: ["from": from, "to": to])
        guard observeMode else { return }
        let t0 = CACurrentMediaTime()   // 回调现场取 T0，不等 Task 调度（astra R2 M8）
        Task { @MainActor in await Driver.fingerFlip(from: from, to: to, t0: t0) }
    }

    @MainActor static func noteBubble(_ id: String) {
        PerfCount.hit("bubbleMake")
        if id == watchBubbleId { watchedBubbleMade = true }
    }

    /// App.init 首行调用
    @MainActor static func appInit() {
        if thermalProbe { writeThermalProbe() }
        appInitBody = CACurrentMediaTime()
        if !processStartOK, let wall = processStartWallClock() {
            processStart = appInitBody - (Date().timeIntervalSince1970 - wall)
            processStartOK = true
        } else if !processStartOK {
            processStart = appInitBody
        }
        LaunchTrace.event("appInitBody")
        if strictMeasure { URLProtocol.registerClass(PerfOutboundTrap.self) }
        MainBlockMonitor.install(segmentStart: processStart)
        guard anyRole else { return }
        Task { @MainActor in await Driver.run() }
    }

    /// thermal 门探针（plan-chat-list-perf-p0 §14-57）：runner 在每个 chatV1 测量进程前起它读一次 thermalState——
    /// App.init 首行写 JSON 即退，不建 ModelContainer、不碰楼层 / 网络。`MP_PERF_TEST_THERMAL_STATE` = 自测（假报一个状态）
    static let thermalProbe = env["MP_PERF_THERMAL"] == "1"

    static func thermalName(_ s: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch s {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func writeThermalProbe() {
        let real = thermalName()
        let report: [String: Any] = ["runId": runId, "role": "thermal", "thermal": env["MP_PERF_TEST_THERMAL_STATE"] ?? real,
                                     "thermalReal": real, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                                     "testOverride": env["MP_PERF_TEST_THERMAL_STATE"] != nil]
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            let dir = docs.appendingPathComponent("perf", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // R7-12：之前的探针 JSON runner 都已读过，删掉不再累积（只动 perf 目录里 run-thermal- 前缀的文件）
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("run-thermal-") && name != "run-\(runId).json" {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
            try? data.write(to: dir.appendingPathComponent("run-\(runId).json"), options: .atomic)
        }
        exit(0)
    }

    /// App.init 建好 ProfileManager 后调用
    @MainActor static func prepare(pm: ProfileManager) {
        container = pm.container
        if strictMeasure { profiles = pm }
        if seedMode != nil {
            // R4 C-01：不在 bench 就用当前楼层覆盖恢复键（旧键可能陈旧）。MP_PERF_TEST_STALE_KEY = 自测：先造一个陈旧键
            let current = pm.currentProfile.id
            if let stale = env["MP_PERF_TEST_STALE_KEY"], quietNetwork, current != profileId {
                UserDefaults.standard.set(stale, forKey: originalProfileKey)
            }
            seedKeyBefore = UserDefaults.standard.string(forKey: originalProfileKey)
            if let key = PerfChatCore.seedOriginalKey(saved: seedKeyBefore, current: current, bench: profileId) {
                UserDefaults.standard.set(key, forKey: originalProfileKey)
            }
            if let bench = pm.profiles.first(where: { $0.id == profileId }) {
                if pm.currentProfile.id != profileId { pm.switchTo(bench) }
            } else {
                pm.addProfile(Profile(id: profileId, name: "[PERF] 基准楼层", emoji: "📊",
                    description: "性能测量专用，整层可删", userName: "你", assistantName: "助手",
                    systemPrompt: "", preferredModel: "", createdAt: Date()))
            }
            PerfSeed.injectIfNeeded(container: pm.container)
        } else if restoreRequested {
            // §3.3 restore 严格化：找不到原楼层 → 明确失败、不切、不删键；切换后核落地才删键
            let saved = UserDefaults.standard.string(forKey: originalProfileKey)
            let lookup = env["MP_PERF_TEST_RESTORE_MISSING"] == "1" ? "perf-test-missing-profile" : saved
            switch PerfChatCore.floorRestore(saved: lookup, current: pm.currentProfile.id,
                                             profiles: pm.profiles.map(\.id), bench: profileId) {
            case .switchTo(let id):
                if let target = pm.profiles.first(where: { $0.id == id }) { pm.switchTo(target) }
                if pm.currentProfile.id == id {
                    UserDefaults.standard.removeObject(forKey: originalProfileKey)
                } else {
                    restoreFailure = "restore: switch to \(id) did not land (on \(pm.currentProfile.id))"
                }
            case .stay:
                UserDefaults.standard.removeObject(forKey: originalProfileKey)
            case .fail(let reason):
                restoreFailure = reason
            }
        }
        profileAtLaunch = pm.currentProfile.id
        if LaunchTrace.enabled, isActive {
            LaunchTrace.fixtureBefore = LaunchTrace.measure("fixture.before") { PerfSeed.fingerprint(ModelContext(pm.container)) }
        }
    }

    static func processStartWallClock() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : -1
    }
}

// MARK: - launchV2：主线程内存事件；finishRun 才序列化。所有时间均为 CACurrentMediaTime。
@MainActor
enum LaunchTrace {
    static let enabled = PerfHarness.env["MP_PERF_LAUNCH_V2"] == "1"
    /// 仅探针减负，不改变生产路径；0 分别恢复事件线性检索 / 尾窗持续探测。
    static let indexedEventTimes = PerfHarness.env["MP_LAUNCH_TRACE_TIME_CACHE"] != "0"
    static let quietTailPolling = PerfHarness.env["MP_LAUNCH_TAIL_QUIET_PROBE"] != "0"
    static let scenario = PerfHarness.env["MP_PERF_LAUNCH_SCENARIO"] ?? "launch-only"
    static let mountSequence: [Int]? = {
        guard enabled, let value = PerfHarness.env["MP_PERF_MOUNT_SEQUENCE"] else { return nil }
        switch value {
        case "0": return [0]
        case "2": return [2]
        case "0,2": return [0, 2]
        case "2,0": return [2, 0]
        default: return nil
        }
    }()
    private(set) static var events: [[String: Any]] = []
    private struct EventTimeKey: Hashable {
        let name: String
        let vc: String
        let profile: String
        let generation: Int
        let layout: Int
    }
    private static var firstEventTimes: [String: Double] = [:]
    private static var firstScopedEventTimes: [EventTimeKey: Double] = [:]
    static var spanStack: [Int] = []
    static var nextSpan = 0
    static var fixtureBefore: [String: Int] = [:]
    static var memory: [[String: Any]] = []
    static let frames = FrameMonitor()
    static var thermalStart: Int?
    static var lowPowerStart: Bool?
    static var chatStableToken: String?
    static var chatConditionAt: Double?
    static var page2Target: String?
    static var appearance: [String: Any] = [:]
    static var phaseMetrics: [String: Any] = [:]

    private struct Interval {
        let name: StaticString
        let signpost: OSSignpostIntervalState
        let vc: String?
        let epoch: Int?
        var revision: Int?
    }
    private static var intervals: [String: Interval] = [:]
    private static var startedIntervals: Set<String> = []

    private static func beginInterval(_ name: StaticString, key: String, owner: LaunchReadiness? = nil,
                                      revision: Int? = nil) {
        guard enabled, startedIntervals.insert(key).inserted else { return }
        intervals[key] = Interval(name: name,
            signpost: PerfHarness.signposter.beginInterval(name, id: PerfHarness.signposter.makeSignpostID()),
            vc: owner?.vcID, epoch: owner?.epoch, revision: revision)
        // 无 Driver 的手工录制也要收口；正常路径在本地事件或 Driver 超时处更早结束。
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
            endInterval(key, reason: "timeout")
        }
    }

    private static func endInterval(_ key: String, reason: String) {
        guard let interval = intervals.removeValue(forKey: key) else { return }
        PerfHarness.signposter.endInterval(interval.name, interval.signpost, "end=\(reason, privacy: .public)")
    }

    static func finishIntervals(reason: String) {
        for key in Array(intervals.keys) { endInterval(key, reason: reason) }
    }

    private static func signpostEvent(_ name: String, state: LaunchReadiness, page: Int?, fields: [String: Any]) {
        if name == "chatStructuralReady" { endInterval("launchBlock", reason: name) }
        if name == "vcInvalidated" || name == "vcRegistered" {
            for (key, interval) in intervals where interval.vc == state.vcID
                && (name == "vcInvalidated" || interval.epoch != state.epoch) {
                endInterval(key, reason: name)
            }
        }
        guard let page, page == 0 || page == 2 else { return }
        let key = "mountP\(page)/\(state.vcID)/\(state.epoch)"
        if name == "rootAssignBegin", fields["real"] as? Bool == true {
            // 事件在 rootAssigned 自增 revision 之前；后续 root 更新仍属于这次首建。
            if intervals[key] != nil { intervals[key]?.revision = state.revision(page) + 1 }
            else {
                beginInterval(page == 0 ? "mountP0" : "mountP2", key: key,
                              owner: state, revision: state.revision(page) + 1)
            }
        } else if name == (mountSequence == nil ? "rootLayout" : "pagePrepared"),
                  intervals[key]?.revision == state.revision(page) {
            // eager 切到首次 HC 布局；诊断挂载切到本地 ready，不包含 ReadyGate 的 500ms 安静窗。
            endInterval(key, reason: name)
        } else if name == "diagnosticMountEnd" {
            endInterval(key, reason: fields["failed"] as? Bool == true ? "timeout" : name)
        }
    }

    static func start() {
        guard enabled else { return }
        beginInterval("launchBlock", key: "launchBlock")
        beginInterval("appInit", key: "appInit")
        let now = CACurrentMediaTime()
        if let wall = PerfHarness.processStartWallClock() {
            PerfHarness.processStart = now - (Date().timeIntervalSince1970 - wall)
            PerfHarness.processStartOK = true
        } else { PerfHarness.processStart = now }
        event("processStart", at: PerfHarness.processStart, fields: ["valid": PerfHarness.processStartOK, "clockBridge": "sysctl-wall-to-monotonic"])
        event("appPropertiesBegin")
        thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        lowPowerStart = ProcessInfo.processInfo.isLowPowerModeEnabled
        MainBlockMonitor.install(segmentStart: now)
        event("mainMonitorStarted", fields: ["segmentAnchor": now])
        frames.samplesLaunchMemory = true
        frames.start() // App 属性 / 任何 HC 构造之前开始，首回调延迟独立记录。
        sampleMemory("appPropertiesBegin")
    }

    static func event(_ name: String, at: Double? = nil, fields: [String: Any] = [:]) {
        guard enabled else { return }
        if name == "appInitEnd" { endInterval("appInit", reason: name) }
        if PerfHarness.isActive, scenario == "launch-only", mountSequence == nil {
            // 在真实尾窗锚点现场 begin，不能等 Driver 轮询后再给过去的时间补 signpost。
            if name == "splashRemoved" || (name == "chatStructuralConfirmed" && time("splashShown") == nil)
                || name == "tailStart" {
                beginInterval("launchTail", key: "launchTail")
            } else if name == "tailEnd" { endInterval("launchTail", reason: name) }
        }
        var record = fields
        record["name"] = name
        let timestamp = at ?? CACurrentMediaTime()
        record["t"] = timestamp
        // 后台解码/音频排程回传的是实际媒体时钟，可能早于 main 最近的事件。
        // 保留测量台的单调序要求；相同时刻按登记顺序，通常路径仍是 O(1) append。
        if let last = events.last?["t"] as? Double, timestamp < last {
            let index = events.firstIndex { ($0["t"] as? Double ?? 0) > timestamp } ?? events.endIndex
            events.insert(record, at: index)
        } else { events.append(record) }
        if indexedEventTimes {
            // 常规事件保留首次登记值；后台回填使用独立事件名，不覆盖既有时间。
            if firstEventTimes[name] == nil { firstEventTimes[name] = timestamp }
            if let vc = record["vc"] as? String, let profile = record["profile"] as? String,
               let generation = record["generation"] as? Int, let layout = record["layoutGeneration"] as? Int {
                let key = EventTimeKey(name: name, vc: vc, profile: profile, generation: generation, layout: layout)
                if firstScopedEventTimes[key] == nil { firstScopedEventTimes[key] = timestamp }
            }
        }
    }
    static func event(_ name: String, state: LaunchReadiness, page: Int? = nil, at: Double? = nil, fields: [String: Any] = [:]) {
        guard enabled else { return }
        signpostEvent(name, state: state, page: page, fields: fields)
        var record = fields
        record["scene"] = state.sceneID as Any? ?? NSNull()
        if record["reason"] == nil { record["reason"] = "localCallback" }
        record["vc"] = state.vcID; record["profile"] = state.profile
        record["generation"] = state.epoch; record["layoutGeneration"] = state.layoutGeneration
        record["page"] = page ?? -1
        if let page { record["rootRevision"] = state.revision(page) }
        record["covered"] = LaunchSplash.hasCover
        event(name, at: at, fields: record)
    }
    @discardableResult static func begin(_ name: String, fields: [String: Any] = [:]) -> Int {
        guard enabled else { return -1 }
        nextSpan += 1
        var record = fields
        record["span"] = nextSpan; record["parent"] = spanStack.last ?? 0
        record["durationKind"] = "inclusive"
        event(name + ".begin", fields: record)
        spanStack.append(nextSpan)
        return nextSpan
    }
    static func end(_ name: String, _ span: Int, fields: [String: Any] = [:]) {
        guard enabled, span >= 0 else { return }
        var record = fields; record["span"] = span
        event(name + ".end", fields: record)
        if spanStack.last == span { spanStack.removeLast() }
    }
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let span = begin(name)
        defer { end(name, span) }
        return try work()
    }
    /// 后台工作完成后在 main 登记真实时间；不把异步区间压进主线程嵌套 spanStack。
    static func recordBackgroundSpan(_ name: String, began: Double, ended: Double, fields: [String: Any] = [:]) {
        guard enabled else { return }
        nextSpan += 1
        var record = fields
        record["span"] = nextSpan; record["parent"] = 0
        record["durationKind"] = "background"; record["thread"] = "background"
        event(name + ".begin", at: began, fields: record)
        event(name + ".end", at: ended, fields: record)
    }
    static func sampleMemory(_ stage: String) {
        guard enabled else { return }
        let value = PerfHarness.footprintMiB()
        memory.append(["t": CACurrentMediaTime(), "stage": stage, "MiB": value >= 0 ? value as Any : NSNull()])
    }
    static func spanSummary() -> [[String: Any]] {
        var starts: [Int: [String: Any]] = [:]
        var completed: [(id: Int, parent: Int, name: String, duration: Double)] = []
        for event in events {
            guard let name = event["name"] as? String, let id = event["span"] as? Int,
                  let t = event["t"] as? Double else { continue }
            if name.hasSuffix(".begin") { starts[id] = event }
            else if name.hasSuffix(".end"), let start = starts[id], let begin = start["t"] as? Double {
                completed.append((id, start["parent"] as? Int ?? 0, String(name.dropLast(4)), t - begin))
            }
        }
        return completed.map { span in
            let children = completed.filter { $0.parent == span.id }.reduce(0) { $0 + $1.duration }
            return ["span": span.id, "parent": span.parent, "name": span.name,
                    "inclusiveMs": span.duration * 1000, "exclusiveMs": max(0, span.duration - children) * 1000]
        }
    }
    static func time(_ name: String) -> Double? {
        if indexedEventTimes { return firstEventTimes[name] }
        return events.first { $0["name"] as? String == name }?["t"] as? Double
    }
    static func time(_ name: String, state: LaunchReadiness) -> Double? {
        if indexedEventTimes {
            return firstScopedEventTimes[EventTimeKey(name: name, vc: state.vcID, profile: state.profile,
                                                     generation: state.epoch, layout: state.layoutGeneration)]
        }
        return events.first { $0["name"] as? String == name && $0["vc"] as? String == state.vcID
            && $0["profile"] as? String == state.profile && $0["generation"] as? Int == state.epoch
            && $0["layoutGeneration"] as? Int == state.layoutGeneration }?["t"] as? Double
    }
    static func identity(_ object: AnyObject?) -> Any { object.map { String(describing: ObjectIdentifier($0)) } as Any? ?? NSNull() }
}

/// 在真实 HC 内读取两层环境的实际结果；只记实例身份/缺失，不读凭据。
struct LaunchEnvironmentAudit: ViewModifier {
    @Environment(\.launchPageSignal) private var signal
    @Environment(\.modelContext) private var context
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(ProviderManager.self) private var providers: ProviderManager?
    @Environment(PresetManager.self) private var presets: PresetManager?
    @Environment(ThemeManager.self) private var theme: ThemeManager?
    @Environment(GlobalWorldBookManager.self) private var worldBook: GlobalWorldBookManager?
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    func body(content: Content) -> some View {
        content.onAppear {
            guard LaunchTrace.enabled, let signal, signal.epoch == signal.state.epoch,
                  signal.revision == signal.state.revision(signal.page) else { return }
            LaunchTrace.event("environment", state: signal.state, page: signal.page, fields: [
                "modelContext": LaunchTrace.identity(context), "profileManager": LaunchTrace.identity(profiles),
                "providerManager": LaunchTrace.identity(providers), "presetManager": LaunchTrace.identity(presets),
                "themeManager": LaunchTrace.identity(theme), "worldBookManager": LaunchTrace.identity(worldBook),
                "rightPanelToolManager": LaunchTrace.identity(tools), "actualProfile": profiles?.currentProfile.id ?? "missing",
                "containerMatches": context.container === PerfHarness.container,
            ])
        }
    }
}

// MARK: - 计数（纯自增，不 print，不碰 Observation）

enum PerfCount {
    nonisolated(unsafe) private static var values: [String: Int] = [:]
    static func hit(_ key: String) { values[key, default: 0] += 1 }
    static func snapshot() -> [String: Int] { values }

    // Air 被动探针的定时入口可能来自文件库后台调用；独立锁不改变现有主线程计数口径。
    private static let timingLock = NSLock()
    nonisolated(unsafe) private static var timedCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var timedMilliseconds: [String: Double] = [:]
    static func beginTimed(_ key: String) {
        timingLock.lock()
        timedCounts[key, default: 0] += 1
        timingLock.unlock()
    }
    static func endTimed(_ key: String, milliseconds: Double) {
        timingLock.lock()
        timedMilliseconds[key, default: 0] += milliseconds
        timingLock.unlock()
    }
    static func timedSnapshot() -> (counts: [String: Int], milliseconds: [String: Double]) {
        timingLock.lock()
        defer { timingLock.unlock() }
        return (timedCounts, timedMilliseconds)
    }
    static func diff(from a: [String: Int], to b: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in b where v - (a[k] ?? 0) != 0 { out[k] = v - (a[k] ?? 0) }
        return out
    }
}

// MARK: - 主线程 runloop 长忙段（afterWaiting → beforeWaiting，commonModes 含 UITracking）
// 测的是 app 主线程墙钟忙段，不是 CPU 时间，也不含 render server / GPU。

enum MainBlockMonitor {
    struct Block { let start: Double; let end: Double }
    nonisolated(unsafe) static var blocks: [Block] = []
    nonisolated(unsafe) static var segments: [Block] = []
    nonisolated(unsafe) static var busyTotal: Double = 0
    nonisolated(unsafe) static var firstIdle: Double = 0
    nonisolated(unsafe) private static var segStart: Double = 0
    nonisolated(unsafe) private static var inSegment = false
    nonisolated(unsafe) private static var observer: CFRunLoopObserver?
    /// 逐段忙区间只在 launchV2 与 chatV1 严格测量下记（窗口 busy 在 occurrence 结束时一次算，plan-chat-list-perf-p0 §4.3）
    static let recordsSegments = PerfHarness.env["MP_PERF_LAUNCH_V2"] == "1" || PerfHarness.strictMeasure

    static func install(segmentStart: Double) {
        guard observer == nil else { return }
        segStart = segmentStart
        inSegment = true
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let obs = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                segStart = now
                inSegment = true
            } else if inSegment {
                let d = now - segStart
                busyTotal += d
                if recordsSegments { segments.append(Block(start: segStart, end: now)) }
                if d > 0.05 { blocks.append(Block(start: segStart, end: now)) }
                if firstIdle == 0 { firstIdle = now }
                inSegment = false
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
        if PerfHarness.strictMeasure { installSplit(segmentStart: segmentStart) }
    }

    // R5 C-01（对照实验确认，plan §14-49）：严格测量下并挂第二套——afterWaiting 用 order Int.min 开段、
    // beforeWaiting 用 order Int.max 收段，排在 UIKit / CA 提交观察者（1999000–2001000）与自动释放池（2147483647）之后，
    // 忙段含布局 + CA 提交。chatV1 的窗口 / busy / 块全走这一套；上面 order 0 那一个是 legacy / launchV2 的口径，不改，
    // chatV1 里只作对照（evidence.busyOrder0）
    nonisolated(unsafe) static var splitSegments: [Block] = []
    nonisolated(unsafe) static var splitBlocks: [Block] = []
    nonisolated(unsafe) private static var splitStart: Double = 0
    nonisolated(unsafe) private static var splitIn = false
    nonisolated(unsafe) private static var splitObservers: [CFRunLoopObserver] = []

    /// Air 复用同一对观察者；日常采样只发当前段，不增长严格测量的数组。
    nonisolated(unsafe) private static var splitSink: ((Block) -> Void)?
    nonisolated(unsafe) private static var splitOpenSink: ((Double) -> Void)?
    static func observeSplit(_ sink: @escaping (Block) -> Void, onOpen: ((Double) -> Void)? = nil) {
        splitSink = sink
        splitOpenSink = onOpen
        installSplit(segmentStart: CACurrentMediaTime())
        if splitIn { onOpen?(splitStart) }
    }
    static func currentSplit(now: Double) -> Block? {
        splitIn ? Block(start: splitStart, end: now) : nil
    }

    private static func installSplit(segmentStart: Double) {
        guard splitObservers.isEmpty else { return }
        splitStart = segmentStart
        splitIn = true
        let open = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            splitStart = CACurrentMediaTime()
            splitIn = true
            splitOpenSink?(splitStart)
        }
        let close = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            guard splitIn else { return }
            let now = CACurrentMediaTime()
            let block = Block(start: splitStart, end: now)
            if PerfHarness.strictMeasure {
                splitSegments.append(block)
                if now - splitStart > 0.05 { splitBlocks.append(block) }
            }
            splitIn = false
            splitSink?(block)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), open, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), close, .commonModes)
        splitObservers = [open, close].compactMap { $0 }
    }

    static func splitIntervals(now: Double) -> [PerfChatCore.Interval] {
        var out = splitSegments.map { PerfChatCore.Interval(start: $0.start, end: $0.end) }
        if splitIn { out.append(PerfChatCore.Interval(start: splitStart, end: now)) }
        return out
    }

    /// split 口径的 lastBlockEnd（语义同 order 0 那个）
    static func splitLastBlockEnd(after t0: Double, now: Double) -> Double? {
        if splitIn, now - splitStart > 0.05 { return now }
        guard let b = splitBlocks.last, b.end > t0 else { return nil }
        return b.end
    }

    /// 截至 now 的忙时累计（含进行中的段）
    static func busy(now: Double) -> Double { busyTotal + (inSegment ? now - segStart : 0) }

    /// 已收段 + 进行中段（截至 now），给 PerfChatCore 的窗口切分用
    static func segmentIntervals(now: Double) -> [PerfChatCore.Interval] {
        var out = segments.map { PerfChatCore.Interval(start: $0.start, end: $0.end) }
        if inSegment { out.append(PerfChatCore.Interval(start: segStart, end: now)) }
        return out
    }

    static func busy(from t0: Double, to t1: Double) -> Double {
        let finished = segments.reduce(0.0) { $0 + max(0, min($1.end, t1) - max($1.start, t0)) }
        return finished + (inSegment ? max(0, t1 - max(segStart, t0)) : 0)
    }

    /// t0 之后最后一个 >50ms 块的结束时刻；进行中的段已超 50ms 则视为「此刻仍在块里」
    static func lastBlockEnd(after t0: Double, now: Double) -> Double? {
        if inSegment, now - segStart > 0.05 { return now }
        guard let b = blocks.last, b.end > t0 else { return nil }
        return b.end
    }

    static func launchBlocks(from t0: Double, to t1: Double) -> [[String: Any]] {
        var candidates = blocks
        if inSegment, t1 - segStart > 0.05 { candidates.append(Block(start: segStart, end: t1)) }
        return candidates.filter { $0.end > t0 && $0.start < t1 }.map {
            ["start": $0.start, "end": $0.end, "ms": ($0.end - $0.start) * 1000,
             "overlapMs": max(0, min($0.end, t1) - max($0.start, t0)) * 1000]
        }
    }

    static func blocks(from t0: Double, to t1: Double) -> [Double] {
        blocks.filter { $0.end > t0 && $0.start < t1 }.map { (($0.end - $0.start) * 1000).rounded() }
    }
}

// MARK: - 帧回调间隔（CADisplayLink 回调间隙，不等于 GPU 掉帧）

final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: Double = 0
    var samplesLaunchMemory = false
    private var memoryAt: Double = 0
    private(set) var intervals: [Double] = []
    private(set) var ends: [Double] = []
    private(set) var startedAt: Double = 0
    private(set) var arrivals: [Double] = []
    var firstCallbackDelay: Double? { arrivals.first.map { $0 - startedAt } }
    var arrivalIntervals: [Double] {
        zip([startedAt] + arrivals, arrivals).map { pair in pair.1 - pair.0 }
    }
    var worstArrivalEnd: Double? {
        let gaps = arrivalIntervals
        return gaps.indices.max { gaps[$0] < gaps[$1] }.map { arrivals[$0] }
    }
    var report: [String: Any] {
        ["startedAt": startedAt, "firstCallbackDelayMs": firstCallbackDelay.map { $0 * 1000 } as Any? ?? NSNull(),
         "arrivalTimes": arrivals, "timestampGapsMs": intervals.map { $0 * 1000 }, "timestampEnds": ends,
         "worstTimestampGapMs": intervals.max().map { $0 * 1000 } as Any? ?? NSNull(),
         "worstTimestampGapEnd": worstGapEnd as Any? ?? NSNull(),
         "worstArrivalGapMs": arrivalIntervals.max().map { $0 * 1000 } as Any? ?? NSNull(),
         "worstArrivalEnd": worstArrivalEnd as Any? ?? NSNull()]
    }

    func windowReport(from start: Double, to end: Double) -> [String: Any] {
        let starts = [startedAt] + arrivals
        let gaps = arrivals.indices.filter { arrivals[$0] > start && starts[$0] < end }
        let worst = gaps.max { arrivals[$0] - starts[$0] < arrivals[$1] - starts[$1] }
        return ["start": start, "end": end, "busyMs": MainBlockMonitor.busy(from: start, to: end) * 1000,
                "longBlocks": MainBlockMonitor.launchBlocks(from: start, to: end),
                "worstArrivalGapMs": worst.map { (arrivals[$0] - starts[$0]) * 1000 } as Any? ?? NSNull(),
                "worstGapStart": worst.map { starts[$0] } as Any? ?? NSNull(),
                "worstGapEnd": worst.map { arrivals[$0] } as Any? ?? NSNull()]
    }

    /// 最大间隔结束时刻（CADisplayLink 时间戳，与 CACurrentMediaTime 同基准）
    var worstGapEnd: Double? { intervals.indices.max { intervals[$0] < intervals[$1] }.map { ends[$0] } }

    @MainActor func start() {
        stop()
        startedAt = CACurrentMediaTime()
        arrivals = []
        intervals = []
        ends = []
        last = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @MainActor func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        arrivals.append(now)
        if samplesLaunchMemory, now - memoryAt >= 0.1 {
            memoryAt = now
            MainActor.assumeIsolated { LaunchTrace.sampleMemory("sampled") }
        }
        if last > 0 { intervals.append(l.timestamp - last); ends.append(l.timestamp) }
        last = l.timestamp
    }
}

// MARK: - 就绪门：业务条件**持续**成立 + 之后 500ms 无 >50ms 块（条件失效即重置）

@MainActor
final class ReadyGate: NSObject {
    struct Result { let ready: Double; let condAt: Double; let confirmed: Double; let failed: Bool }
    private let t0: Double
    private let condition: () -> Bool
    private let timeout: Double
    private var condAt: Double?
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Result, Never>?

    private init(t0: Double, timeout: Double, condition: @escaping () -> Bool) {
        self.t0 = t0
        self.timeout = timeout
        self.condition = condition
    }

    static func wait(t0: Double, timeout: Double = 15, _ condition: @escaping () -> Bool) async -> Result {
        let gate = ReadyGate(t0: t0, timeout: timeout, condition: condition)
        return await withCheckedContinuation { c in
            gate.continuation = c
            let l = CADisplayLink(target: gate, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            gate.link = l
        }
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        // 绝对截止先查：条件一直成立但安静窗总被 >50ms 块打断时也要超时（astra R2 M5）
        if now - t0 > timeout {
            finish(Result(ready: now, condAt: condAt ?? now, confirmed: now, failed: true))
            return
        }
        if condition() {
            if condAt == nil { condAt = now }
        } else {
            condAt = nil
        }
        if let c = condAt {
            let ready = max(c, MainBlockMonitor.lastBlockEnd(after: t0, now: now) ?? 0)
            if now - ready >= 0.5 { finish(Result(ready: ready, condAt: c, confirmed: now, failed: false)) }
        }
    }

    private func finish(_ r: Result) {
        link?.invalidate()
        link = nil
        continuation?.resume(returning: r)
        continuation = nil
    }
}

// MARK: - 驱动器

@MainActor
enum Driver {
    private static var samples: [[String: Any]] = []
    private static var failures: [String] = []

    static func run() async {
        if PerfHarness.seedMode != nil {
            if PerfHarness.seedMode == "bulk", let container = PerfHarness.container {
                let t = CACurrentMediaTime()
                await Task.detached(priority: .userInitiated) { PerfSeed.injectBulkIfNeeded(container: container) }.value
                samples.append(["op": "bulkSeed", "ms": ms(CACurrentMediaTime() - t)])
            }
            if PerfHarness.profileAtLaunch != PerfHarness.profileId { failures.append("seed: not on bench profile") }
            else if let container = PerfHarness.container, PerfChatCore.seedsChatV1Fixture(protocol: PerfHarness.seedProtocol) { chatV1Seed(container) }
            finishRun()
            return
        }
        if PerfHarness.restoreRequested {
            if let reason = PerfHarness.restoreFailure { failures.append(reason) }
            if PerfHarness.profileAtLaunch == PerfHarness.profileId { failures.append("restore: still on bench profile") }
            finishRun()
            return
        }
        if PerfHarness.observeMode {
            // 被动：等 16 次真手指翻页（XCUITest 驱动），120s 兜底
            let deadline = CACurrentMediaTime() + 120
            while fingerCount < 16, CACurrentMediaTime() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if fingerCount < 16 { failures.append("observe: only \(fingerCount) finger flips") }
            finishRun()
            return
        }
        guard PerfHarness.profileAtLaunch == PerfHarness.profileId else {
            failures.append("measure: launched on \(PerfHarness.profileAtLaunch), not bench profile (run MP_PERF_SEED first)")
            finishRun()
            return
        }
        if !PerfHarness.processStartOK { failures.append("coldStart: p_starttime unavailable") }

        if LaunchTrace.enabled {
            await launchScenario()
            finishRun()
            return
        }
        await coldStart()
        if PerfHarness.strictMeasure {
            await chatV1Run()
            finishRun()
            return
        }

        guard let ctx = PerfHarness.modelContext,
              let a = fetchConv(PerfHarness.convA, ctx), let b = fetchConv(PerfHarness.convB, ctx) else {
            failures.append("targets missing (seed with MP_PERF_SEED=1)")
            finishRun()
            return
        }

        if PerfHarness.shotMode {
            await Shots.capture(a: a)
            finishRun()
            return
        }

        if PerfHarness.startDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(PerfHarness.startDelay * 1_000_000_000)) }
        if PerfHarness.scenarios.contains("open") { await openScenarios(a: a, b: b) }
        if PerfHarness.scenarios.contains("flip") {
            // S4 翻页：1→0→1→2→1 × 4（合成驱动，标 synthetic）
            if PerfHarness.paging?.perfSettledPage != 1 { await flip(to: 1, recordAs: nil) }
            for _ in 0..<4 {
                for target in [0, 1, 2, 1] { await flip(to: target, recordAs: "pageFlip") }
            }
        }
        finishRun()
    }

    /// 新场景每次由 host 启动一个新进程；首访绝不经过 legacy coldStart 的 4s 尾窗。
    private static func launchScenario() async {
        defer { LaunchTrace.finishIntervals(reason: "launchScenarioEnd") }
        let allowed = ["launch-only", "launch-first0", "launch-first2", "launch-mount", "launch-mounted-first0", "launch-mounted-first2"]
        if !allowed.contains(LaunchTrace.scenario) { failures.append("launchV2: invalid scenario") }
        if !["eager", "covered"].contains(LaunchSplash.requestedPolicy) { failures.append("launchV2: invalid prewarm policy") }
        if LaunchSplash.requestedPolicy == "covered", PerfHarness.env["MP_PERF_L4", default: "off"] != "off" {
            failures.append("launchV2: covered conflicts with MP_PERF_L4")
        }
        if PerfHarness.env["MP_PERF_MOUNT_SEQUENCE"] != nil, LaunchTrace.mountSequence == nil {
            failures.append("launchV2: invalid mount sequence")
        }
        let mountedFirst = LaunchTrace.scenario.hasPrefix("launch-mounted-first")
        if (LaunchTrace.mountSequence != nil) != (LaunchTrace.scenario == "launch-mount" || mountedFirst) {
            failures.append("launchV2: mount sequence requires a diagnostic mount scenario")
        }
        if mountedFirst, let target = Int(String(LaunchTrace.scenario.suffix(1))), LaunchTrace.mountSequence?.contains(target) != true {
            failures.append("launchV2: residual first target must be in mount sequence")
        }
        if PerfHarness.startDelay != 0 { failures.append("launchV2: MP_PERF_DELAY would warm the first visit") }
        if LaunchTrace.mountSequence != nil, LaunchSplash.requestedPolicy == "covered" {
            failures.append("launchV2: diagnostic mount requires eager gate")
        }
        guard failures.isEmpty else { return }
        let t0 = PerfHarness.processStart
        let ready = await launchWait(timeout: 30) {
            let chat = updateLaunchChatConfirmation()
            let shown = LaunchTrace.time("splashShown") != nil
            let confirmed = PerfHarness.paging.map { LaunchTrace.time("chatStructuralConfirmed", state: $0.launchReadiness) != nil } ?? false
            // 有罩的即时首访只等 removed，不能为了 500ms 稳定确认偷偷把目标再暖一会儿。
            return LaunchSplash.isFinished && (shown || (chat && confirmed))
        }
        if !ready {
            failures.append("launchV2: chat/splash timeout")
            LaunchTrace.finishIntervals(reason: "launchTimeout")
        }
        if LaunchSplash.finishReason == "deadline" { failures.append("launchV2: splash deadline") }
        guard let paging = PerfHarness.paging else { failures.append("launchV2: no paging VC"); return }
        let state = paging.launchReadiness
        LaunchTrace.sampleMemory("launchRelease")
        if state.isPrepared(1), LaunchTrace.time("chatStructuralReady", state: state) != nil {
            LaunchTrace.event("visualChatReady", state: state, fields: ["definition": "max(chatStructuralReady,splashRemoved);application-proxy"])
        } else {
            LaunchTrace.event("visualChatUnavailableAtRelease", state: state)
            failures.append("launchV2: chat not structurally ready at splash release")
        }
        if let sequence = LaunchTrace.mountSequence {
            for page in sequence {
                let begin = CACurrentMediaTime()
                let frames = FrameMonitor(); frames.start() // 必须先于同步 root 赋值
                LaunchTrace.event("diagnosticMountBegin", state: state, page: page)
                paging.perfMountOnly(page)
                let gate = await ReadyGate.wait(t0: begin) { state.isPrepared(page) }
                frames.stop()
                if gate.failed { failures.append("launchV2: mount page \(page) timeout") }
                samples.append(["op": "mountOnly\(page)", "page": page, "ordinal": samples.count + 1,
                    "readyMs": ms(gate.ready - begin), "busyMs": ms(MainBlockMonitor.busy(from: begin, to: gate.confirmed)),
                    "worstGapMs": ms(frames.arrivalIntervals.max() ?? 0), "frameMonitor": frames.report,
                    "failed": gate.failed, "pendingPages": paging.perfPendingPages,
                    "blocksMs": MainBlockMonitor.blocks(from: begin, to: gate.confirmed)])
                LaunchTrace.event("diagnosticMountEnd", state: state, page: page, fields: ["failed": gate.failed])
            }
            let unrequested = Set([0, 2]).subtracting(sequence)
            if !unrequested.isSubset(of: Set(paging.perfPendingPages)) { failures.append("launchV2: diagnostic mounted an unrequested page") }
            if mountedFirst, let target = Int(String(LaunchTrace.scenario.suffix(1))) { await launchFirstVisit(to: target) }
        } else if LaunchTrace.scenario == "launch-first0" || LaunchTrace.scenario == "launch-first2" {
            // 上面的等待期间不访问列表/对话，不等尾窗；下一条同步语句就开始目标首访。
            await launchFirstVisit(to: LaunchTrace.scenario == "launch-first0" ? 0 : 2)
        } else {
            let tailStart = LaunchTrace.time("splashRemoved") ?? LaunchTrace.time("chatStructuralConfirmed", state: state) ?? CACurrentMediaTime()
            LaunchTrace.event("tailStart", fields: ["anchor": tailStart])
            _ = await launchWait(timeout: 4.1) {
                // 只停止已完成历史端点的重复探测，不缓存生产 isPrepared / UIKit 命中结果。
                // 缺页、未稳定、VC/profile/layout 换代时继续原探测；尾窗长度/帧监测不变。
                if !LaunchTrace.quietTailPolling || !launchTailConfirmationRecorded() {
                    _ = updateLaunchChatConfirmation()
                }
                return CACurrentMediaTime() >= tailStart + 4
            }
            LaunchTrace.event("tailEnd")
        }
        state.check()
        if LaunchTrace.mountSequence == nil, !state.required { failures.append("launchV2: ordinary launch requires narrow three-page content") }
        if LaunchTrace.time("chatStructuralConfirmed", state: state) == nil {
            failures.append("launchV2: chat stability unconfirmed; immediate first visit was not delayed")
        }
        LaunchTrace.sampleMemory("launchEnd")
        LaunchTrace.event("launchEnd", state: state)
        LaunchTrace.frames.stop()
        let end = CACurrentMediaTime()
        func endpoint(_ name: String) -> Any {
            let scoped = ["chatStructuralReady", "chatStructuralConfirmed", "allRequiredPagesPrepared"].contains(name)
            let time = scoped ? LaunchTrace.time(name, state: state) : LaunchTrace.time(name)
            return time.map { ms($0 - t0) } as Any? ?? NSNull()
        }
        let removed = LaunchTrace.time("splashRemoved")
        let lift = LaunchTrace.time("liftStart")
        let tail = LaunchTrace.events.first { $0["name"] as? String == "tailStart" }?["anchor"] as? Double
        let chat = LaunchTrace.time("chatStructuralReady", state: state)
        let visual = chat.map { max($0, removed ?? $0) }
        if let chat { LaunchTrace.phaseMetrics["chat"] = LaunchTrace.frames.windowReport(from: t0, to: chat) }
        if let chat, let lift { LaunchTrace.phaseMetrics["covered"] = LaunchTrace.frames.windowReport(from: chat, to: max(chat, lift)) }
        if let lift, let removed { LaunchTrace.phaseMetrics["lift"] = LaunchTrace.frames.windowReport(from: lift, to: removed) }
        if let tail { LaunchTrace.phaseMetrics["tail"] = LaunchTrace.frames.windowReport(from: tail, to: tail + 4) }
        let launch: [String: Any] = ["op": "launch", "failed": !failures.isEmpty,
            "chatStructuralReadyMs": endpoint("chatStructuralReady"), "chatConfirmedMs": endpoint("chatStructuralConfirmed"),
            "allPreparedMs": endpoint("allRequiredPagesPrepared"), "splashShownMs": endpoint("splashShown"),
            "liftStartMs": endpoint("liftStart"), "removedMs": endpoint("splashRemoved"),
            "visualChatReadyMs": visual.map { ms($0 - t0) } as Any? ?? NSNull(),
            "busyMs": ms(MainBlockMonitor.busy(from: t0, to: visual ?? end)),
            "coveredBusyMs": lift.flatMap { stop in chat.map { ms(MainBlockMonitor.busy(from: $0, to: stop)) } } as Any? ?? NSNull(),
            "liftBusyMs": lift.flatMap { start in removed.map { ms(MainBlockMonitor.busy(from: start, to: $0)) } } as Any? ?? NSNull(),
            "tailBusyMs": tail.map { ms(MainBlockMonitor.busy(from: $0, to: $0 + 4)) } as Any? ?? NSNull(),
            "worstGapMs": LaunchTrace.frames.arrivalIntervals.max().map { ms($0) } as Any? ?? NSNull(),
            "blocksMs": MainBlockMonitor.blocks(from: t0, to: end)]
        samples.insert(launch, at: 0)
    }

    private static func launchTailConfirmationRecorded() -> Bool {
        guard let state = PerfHarness.paging?.launchReadiness, state.valid else { return false }
        return LaunchTrace.time("chatStructuralConfirmed", state: state) != nil
            && LaunchTrace.time("allRequiredPagesPrepared", state: state) != nil
    }

    private static func updateLaunchChatConfirmation() -> Bool {
        guard let p = PerfHarness.paging else { return false }
        p.launchReadiness.check()
        let state = p.launchReadiness
        let token = "\(state.vcID)/\(state.epoch)/\(state.layoutGeneration)"
        let chat = p.perfSettledPage == 1 && state.isPrepared(1) && PerfHarness.viewModel?.isDraftConversation == true
        let now = CACurrentMediaTime()
        if chat {
            if LaunchTrace.chatStableToken != token {
                LaunchTrace.chatStableToken = token; LaunchTrace.chatConditionAt = now
            }
            let since = max(LaunchTrace.chatConditionAt ?? now, MainBlockMonitor.lastBlockEnd(after: PerfHarness.processStart, now: now) ?? PerfHarness.processStart)
            if now - since >= 0.5, LaunchTrace.time("chatStructuralConfirmed", state: state) == nil {
                LaunchTrace.event("chatStructuralConfirmed", state: state, page: 1)
            }
        } else { LaunchTrace.chatStableToken = nil; LaunchTrace.chatConditionAt = nil }
        return chat
    }

    private static func launchWait(timeout: Double, condition: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            if CACurrentMediaTime() >= deadline { return false }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                NextFrame.run { continuation.resume() }
            }
        }
        return true
    }

    private static func launchFirstVisit(to page: Int) async {
        guard let p = PerfHarness.paging else { failures.append("launchV2: lost paging"); return }
        let state = p.launchReadiness
        let epoch = state.epoch, layout = state.layoutGeneration
        let frames = FrameMonitor(); frames.start()
        let begin = CACurrentMediaTime()
        let mountedBefore = state.realRoots.contains(page)
        LaunchTrace.event("firstVisitBegin", state: state, page: page, at: begin, fields: ["to": page, "ordinal": 1, "source": "syntheticTouchDown", "mountedBefore": mountedBefore])
        await p.perfDrive(to: page, duration: 0.3)
        let settled = CACurrentMediaTime()
        let gate = await ReadyGate.wait(t0: begin) {
            state.check()
            return PerfHarness.paging === p && state.valid && state.epoch == epoch && state.layoutGeneration == layout
                && p.perfSettledPage == page && state.isPrepared(page) && p.perfPageHitReady(page)
        }
        frames.stop()
        if gate.failed { failures.append("launchV2: firstTo\(page) timeout/stale generation") }
        LaunchTrace.event(gate.failed ? "firstVisitTimeout" : "firstVisitReady", state: state, page: page)
        LaunchTrace.sampleMemory("firstVisitEnd")
        samples.append(["op": "firstTo\(page)", "from": 1, "to": page, "ordinal": 1, "source": "syntheticTouchDown",
            "readyMs": ms(gate.ready - begin), "busyMs": ms(MainBlockMonitor.busy(from: begin, to: gate.confirmed)),
            "animBusyMs": ms(MainBlockMonitor.busy(from: begin, to: settled)),
            "worstGapMs": frames.arrivalIntervals.max().map { ms($0) } as Any? ?? NSNull(),
            "frameMonitor": frames.report, "blocksMs": MainBlockMonitor.blocks(from: begin, to: gate.confirmed),
            "phaseMetrics": frames.windowReport(from: begin, to: gate.confirmed),
            "mountedBefore": mountedBefore, "failed": gate.failed,
            "vc": state.vcID, "profile": state.profile, "generation": epoch, "layoutGeneration": layout])
        // 行为真值仍交 UI 专项：这里只验证已注册的同代次列表动作及目标内容/外层命中。
        if page == 0 {
            if PerfHarness.listRegistration?.vc != state.vcID || PerfHarness.listRegistration?.epoch != state.epoch || PerfHarness.listRegistration?.layout != state.layoutGeneration {
                failures.append("launchV2: list action stale or missing")
            }
        }
    }

    private static func openScenarios(a: Conversation, b: Conversation) async {
        // S2 冷开（本进程首开，固定 B）→ S3 热开 A/B 交替 → S3b 同 id 重进（单列，不混入换对话成绩）
        await flip(to: 0, recordAs: nil)
        await openConversation(b, name: "openConvCold")
        for conv in [a, b, a, b, a, b] {
            await flip(to: 0, recordAs: nil)
            await openConversation(conv, name: "openConvWarm")
        }
        for _ in 0..<2 {
            await flip(to: 0, recordAs: nil)
            await openConversation(b, name: "openConvSame")
        }
    }

    // S1：进程启动 → 聊天页草稿可输入（输入框在 window、命中测试落在输入框上、可成为第一响应者）
    private static func coldStart() async {
        let t0 = PerfHarness.processStart
        let s0 = PerfCount.snapshot()
        let b0 = MainBlockMonitor.busy(now: t0)
        let gate = await ReadyGate.wait(t0: t0, timeout: 30) {
            guard let p = PerfHarness.paging, let vm = PerfHarness.viewModel,
                  let field = PerfHarness.inputField, let window = field.window else { return false }
            let center = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: window)
            let hit = window.hitTest(center, with: nil)
            return p.perfSettledPage == 1 && vm.isDraftConversation && field.canBecomeFirstResponder
                && (hit === field || hit?.isDescendant(of: field) == true)
        }
        await record("coldStart", t0: t0, gate: gate, counts0: s0, busy0: b0, tail: 4.0, extra: [
            "appInitBodyMs": ms(PerfHarness.appInitBody - t0),
            "firstIdleMs": ms(MainBlockMonitor.firstIdle - t0),
            "prewarm": PerfHarness.env["ActivePrewarm"] ?? "0",
        ])
        if gate.failed { failures.append("coldStart: ready gate timeout") }
    }

    private static var fingerCount = 0

    static func fingerFlip(from: Int, to: Int, t0: Double) async {
        guard let p = PerfHarness.paging else { return }
        let frames = FrameMonitor()
        let dragFrames = PerfHarness.dragFrames
        PerfHarness.dragFrames = nil
        let s0 = PerfCount.snapshot()
        let b0 = MainBlockMonitor.busy(now: t0)
        frames.start()
        let gate = await ReadyGate.wait(t0: t0) { p.perfSettledPage == to }
        frames.stop()
        let iv = frames.intervals
        dragFrames?.stop()
        await record("pageFlipFinger", t0: t0, gate: gate, counts0: s0, busy0: b0, tail: 1.5, extra: [
            "from": from, "to": to, "frames": iv.count, "frameMonitor": frames.report,
            "dragFrameMonitor": dragFrames?.report as Any? ?? NSNull(),
            "gaps25": iv.filter { $0 > 0.025 }.count, "gaps50": iv.filter { $0 > 0.05 }.count,
            "worstGapMs": ms(iv.max() ?? 0),
            "worstGapEndMs": frames.worstGapEnd.map { ms($0 - t0) } ?? -1,
        ])
        if gate.failed { failures.append("finger \(from)->\(to): ready gate timeout") }
        fingerCount += 1
    }

    private static func openConversation(_ conv: Conversation, name: String) async {
        guard let open = PerfHarness.openFromList else { failures.append("\(name): openFromList not registered"); return }
        let expectedPath = conv.id == PerfHarness.convA ? PerfSeed.pathA : PerfSeed.pathB
        let targetNode = conv.currentNodeId
        let state = PerfHarness.signposter.beginInterval("openConv")
        let s0 = PerfCount.snapshot()
        let t0 = CACurrentMediaTime()
        let b0 = MainBlockMonitor.busy(now: t0)
        PerfHarness.watchBubbleId = targetNode
        PerfHarness.watchedBubbleMade = false
        open(conv)
        let gate = await ReadyGate.wait(t0: t0) {
            guard let vm = PerfHarness.viewModel, let p = PerfHarness.paging else { return false }
            return vm.selectedConversation?.id == conv.id && !vm.isLoading && vm.currentPath.last?.id == targetNode
                && PerfHarness.watchedBubbleMade && PerfHarness.markdownPending == 0 && p.perfSettledPage == 1
        }
        PerfHarness.signposter.endInterval("openConv", state)
        await record(name, t0: t0, gate: gate, counts0: s0, busy0: b0, tail: 1.5, extra: ["conv": conv.id])
        if gate.failed { failures.append("\(name) \(conv.id): ready gate timeout") }
        let path = PerfHarness.viewModel?.currentPath.map(\.id) ?? []
        if path != expectedPath { failures.append("\(name) \(conv.id): path mismatch (\(path.count) vs \(expectedPath.count))") }
    }

    /// 合成翻页：T0 = 松手（此刻走 willEndDragging 的收键盘判定），300ms ease-out 位移动画即「减速」，
    /// 到位后走 didEndDecelerating → finishPaging 真路径
    /// 本进程已经翻到过的页（冷启动落在 1）；第一次翻到某页单列 firstTo<N>——L4 延迟挂载的成本落点
    private static var visitedPages: Set<Int> = [1]

    private static func flip(to page: Int, recordAs requested: String?) async {
        guard let p = PerfHarness.paging else { failures.append("flip: paging not registered"); return }
        let from = p.perfSettledPage
        guard from != page else { return }
        let name = visitedPages.contains(page) ? requested : "firstTo\(page)"
        visitedPages.insert(page)
        let frames = FrameMonitor()
        let state = PerfHarness.signposter.beginInterval("pageFlip")
        let s0 = PerfCount.snapshot()
        let t0 = CACurrentMediaTime()
        let b0 = MainBlockMonitor.busy(now: t0)
        frames.start()
        await p.perfDrive(to: page, duration: 0.3)
        let tSettle = CACurrentMediaTime()
        let animBusy = MainBlockMonitor.busy(now: tSettle) - b0
        // 落定段单独打区间，Time Profiler 按它切（astra R3 M1：1→0 落定回退取证）
        let settleState = page == 0 ? PerfHarness.signposter.beginInterval("settleTo0") : PerfHarness.signposter.beginInterval("settle")
        let gate = await ReadyGate.wait(t0: t0) { p.perfSettledPage == page }
        PerfHarness.signposter.endInterval(page == 0 ? "settleTo0" : "settle", settleState)
        frames.stop()
        PerfHarness.signposter.endInterval("pageFlip", state)
        let iv = frames.intervals
        await record(name ?? "flipSetup", t0: t0, gate: gate, counts0: s0, busy0: b0, tail: 1.5, keep: name != nil, extra: [
            "from": from, "to": page, "frameMonitor": frames.report,
            "settleMs": ms(tSettle - t0),
            "animBusyMs": ms(animBusy),
            "frames": iv.count,
            "gaps25": iv.filter { $0 > 0.025 }.count,
            "gaps50": iv.filter { $0 > 0.05 }.count,
            "worstGapMs": ms(iv.max() ?? 0),
            "worstGapEndMs": frames.worstGapEnd.map { ms($0 - t0) } ?? -1,
        ])
        if gate.failed { failures.append("flip \(from)->\(page): ready gate timeout") }
    }

    /// 就绪确认后再观察固定尾窗（页码点 1.1s 淡出、键盘 1s 保险、索引 3s 启动等延迟工作），
    /// 尾窗忙时单列，计数取 t0 → 尾窗结束
    private static func record(_ name: String, t0: Double, gate: ReadyGate.Result, counts0: [String: Int],
                               busy0: Double, tail: Double, keep: Bool = true, extra: [String: Any]) async {
        let busyToConfirm = MainBlockMonitor.busy(now: gate.confirmed) - busy0
        let remaining = gate.confirmed + tail - CACurrentMediaTime()
        if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        let end = CACurrentMediaTime()
        guard keep else { return }
        var s: [String: Any] = [
            "op": name,
            "readyMs": ms(gate.ready - t0),
            "condMs": ms(gate.condAt - t0),
            "failed": gate.failed,
            "busyMs": ms(busyToConfirm),
            "tailBusyMs": ms(MainBlockMonitor.busy(now: end) - busy0 - busyToConfirm),
            "blocksMs": MainBlockMonitor.blocks(from: t0, to: end),
            "counts": PerfCount.diff(from: counts0, to: PerfCount.snapshot()),
            "footprintMiB": PerfHarness.footprintMiB(),
        ]
        for (k, v) in extra { s[k] = v }
        samples.append(s)
    }

    private static var finishing = false

    private static func finishRun() {
        guard !finishing else { return }
        finishing = true
        LaunchTrace.finishIntervals(reason: "finishRun") // 含 fixture/参数失败、seed/restore 等提前退出。
        if PerfHarness.strictMeasure { chatV1Finish() }
        let ctx = PerfHarness.modelContext ?? PerfHarness.container.map { ModelContext($0) }
        let nodes = (try? ctx?.fetchCount(FetchDescriptor<MessageNode>())) ?? -1
        let convs = (try? ctx?.fetchCount(FetchDescriptor<Conversation>())) ?? -1
        let info = Bundle.main.infoDictionary ?? [:]
        let defaults = UserDefaults.standard
        var report: [String: Any] = [
            "runId": PerfHarness.runId,
            "variant": PerfHarness.variant,
            "role": PerfHarness.isActive || PerfHarness.observeMode ? "measure" : (PerfHarness.seedMode != nil ? "seed" : "restore"),
            "build": info["CFBundleVersion"] ?? "-",
            "binaryUUID": Self.mainBinaryUUID(),
            "deviceModel": Self.deviceModel(),
            "osVersion": UIDevice.current.systemVersion,
            "config": {
                #if DEBUG
                return "Debug"
                #else
                return "Release+PERF_BENCH"
                #endif
            }(),
            "pinnedKeys": pinnedKeys(defaults),
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "storeNodes": nodes, "storeConvs": convs,
            "profileAtLaunch": PerfHarness.profileAtLaunch,
            "fixture": PerfSeed.fingerprint(ctx),
            "appearance": [
                "chatBubbleMode": defaults.bool(forKey: "chatBubbleMode"),
                "style": PerfHarness.paging?.view.window?.traitCollection.userInterfaceStyle.rawValue ?? -1,
            ],
            "samples": samples,
            "failures": failures,
        ]
        if LaunchTrace.enabled, PerfHarness.isActive {
            LaunchTrace.frames.stop()
            report["protocol"] = "launchV2"
            report["scenario"] = LaunchTrace.scenario
            let launchReport: [String: Any] = [
                "harnessRevision": "launchV2-r1", "probeRevision": "lp0929-r3",
                "sourceSHA": PerfHarness.env["MP_PERF_SOURCE_SHA"] as Any? ?? NSNull(),
                "clock": "CACurrentMediaTime", "events": LaunchTrace.events, "spans": LaunchTrace.spanSummary(),
                "phaseMetrics": LaunchTrace.phaseMetrics, "frameMonitor": LaunchTrace.frames.report,
                "flags": ["launchV2": "1", "prewarmRequested": LaunchSplash.requestedPolicy,
                          "prewarmEffective": PerfHarness.paging?.perfLaunchPolicy ?? "missing",
                          "l4": PerfHarness.env["MP_PERF_L4"] ?? "off",
                          "mountSequence": PerfHarness.env["MP_PERF_MOUNT_SEQUENCE"] ?? "off",
                          "splashRequested": PerfHarness.env["MP_SPLASH"] ?? "default",
                          "perfSplash": PerfHarness.env["MP_PERF_SPLASH"] ?? "0",
                          "fontDirect": FontManager.launchDirectBundledFonts ? "1" : "0",
                          "pushProjection": PushIdentityWriter.launchProjectedFetch ? "1" : "0",
                          "traceTimeCache": LaunchTrace.indexedEventTimes ? "1" : "0",
                          "tailQuietProbe": LaunchTrace.quietTailPolling ? "1" : "0",
                          "activePrewarm": PerfHarness.env["ActivePrewarm"] ?? "absent"],
                "splash": ["shown": LaunchTrace.time("splashShown") != nil, "reason": LaunchSplash.finishReason,
                           "animationRevision": LaunchSplash.animationRevision, "animScale": LaunchSplash.Timing.animScale,
                           "bakedArtwork": LaunchSplash.usesBakedArtwork, "reduceMotion": LaunchSplash.reduceMotion,
                           "minimumSeconds": LaunchSplash.Timing.minimum, "liftSeconds": LaunchSplash.Timing.lift,
                           "deadlineSeconds": LaunchSplash.Timing.deadline],
                "thermalStart": LaunchTrace.thermalStart as Any? ?? NSNull(), "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
                "lowPowerStart": LaunchTrace.lowPowerStart as Any? ?? NSNull(), "lowPowerEnd": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "fixtureBefore": LaunchTrace.fixtureBefore, "fixtureAfter": PerfSeed.fingerprint(ctx),
                "memorySamples": LaunchTrace.memory,
                "sampledPeakMiB": LaunchTrace.memory.compactMap { $0["MiB"] as? Double }.max() as Any? ?? NSNull(),
                "appearance": LaunchTrace.appearance,
                "page2": ["openApps": Page2AppShell.shared.stack.openApps, "restored": Page2AppShell.shared.restored,
                          "target": LaunchTrace.page2Target as Any? ?? NSNull()],
            ]
            report["launchV2"] = launchReport
        }
        if PerfHarness.restoreRequested {
            report["restoredTo"] = PerfHarness.profileAtLaunch
            report["originalProfileKeyAfter"] = defaults.string(forKey: PerfHarness.originalProfileKey) as Any? ?? NSNull()
        }
        if let seed = chatV1SeedReport { report["chatV1Fixture"] = seed }
        if PerfHarness.quietNetwork, !PerfHarness.strictMeasure { report["suppressed"] = PerfGuardrails.suppressed }   // R4 K-01：seed / restore 的静默网络证据
        if PerfHarness.quietNetwork, PerfHarness.seedMode != nil {   // R4 C-01 / C-02 证据（只在 chatV1 seed，legacy seed JSON 不变）
            report["originalProfileKeyBefore"] = PerfHarness.seedKeyBefore as Any? ?? NSNull()
            report["originalProfileKeyAfter"] = defaults.string(forKey: PerfHarness.originalProfileKey) as Any? ?? NSNull()
            report["chatV1Seeded"] = chatV1SeedReport != nil
            // §14-47 / §14-62：runner seed 后另拉 plist 核 lastProfileId == bench；这里是进程退出前自己读到的值
            report["lastProfileIdAfter"] = defaults.string(forKey: "lastProfileId") as Any? ?? NSNull()
        }
        if PerfHarness.strictMeasure { chatV1Decorate(&report) }
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dir = docs.appendingPathComponent("perf", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("run-\(PerfHarness.runId).json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
        }
        exit(0)
    }

    /// §8.2 钉死键：有效值 / 来源（参数域里有没有）/ 参数域与持久域原值及类型（持久域按 bundle id 直读，绕开参数域）
    private static func pinnedKeys(_ defaults: UserDefaults) -> [String: Any] {
        let argument = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let persistent = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        func typed(_ v: Any?) -> [String: Any] {
            guard let v else { return ["value": NSNull(), "type": "absent"] }
            if let n = v as? NSNumber { return ["value": n, "type": CFGetTypeID(n) == CFBooleanGetTypeID() ? "Bool" : "Number"] }
            if let s = v as? String { return ["value": s, "type": "String"] }
            return ["value": String(describing: v), "type": String(describing: Swift.type(of: v))]
        }
        func digestData(_ v: Any?) -> Any? { (v as? Data).map(PerfChatCore.dataPin) ?? v }
        var out: [String: Any] = [:]
        // M1（chatV1-r9）：模式键 + 显示钉死键；appStorage = 产品读法（@AppStorage 按声明类型）实读
        for (key, type) in PerfChatCore.pinnedKeys {
            let effective: Any, appStorage: Any
            switch type {
            case .bool:
                effective = defaults.bool(forKey: key)
                appStorage = AppStorage(wrappedValue: false, key).wrappedValue
            case .double:
                effective = defaults.double(forKey: key)
                appStorage = AppStorage(wrappedValue: -1.0, key).wrappedValue
            case .string, .theme:
                effective = defaults.string(forKey: key) ?? NSNull()
                appStorage = AppStorage(wrappedValue: "", key).wrappedValue
            case .data:
                effective = defaults.data(forKey: key).map(PerfChatCore.dataPin) ?? NSNull()
                appStorage = NSNull()
            }
            out[key] = [
                "effective": effective,
                "appStorage": appStorage,
                "source": argument[key] != nil ? "argument" : (persistent[key] != nil ? "persistent" : "default"),
                "argument": typed(digestData(argument[key])),
                "persistent": typed(digestData(persistent[key])),
            ]
        }
        out["themeResolved"] = ThemeManager.shared.selectedThemeId
        return out
    }

    private static func fetchConv(_ id: String, _ ctx: ModelContext) -> Conversation? {
        try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
    }

    static func ms(_ s: Double) -> Double { (s * 10_000).rounded() / 10 }
}

// MARK: - 视觉回归截图（MP_PERF_SHOT=1）——app 内快照只作辅助，系统截图 / 录屏为视觉真值

@MainActor
enum Shots {
    static func capture(a: Conversation) async {
        await shoot("page1-draft")
        await driveAndShoot(0, "page0")
        await driveAndShoot(2, "page2")
        await driveAndShoot(0, nil)
        PerfHarness.openFromList?(a)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await shoot("page1-convA")
    }

    private static func driveAndShoot(_ page: Int, _ name: String?) async {
        guard let p = PerfHarness.paging else { return }
        await p.perfDrive(to: page, duration: 0.3)
        try? await Task.sleep(nanoseconds: 2_000_000_000)   // 等页码点 1.1s + 0.4s 淡出走完
        if let name { await shoot(name) }
    }

    private static func shoot(_ name: String) async {
        guard let window = PerfHarness.paging?.view.window else { return }
        var ok = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            ok = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard ok, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = image.pngData() else { return }
        let dir = docs.appendingPathComponent("perf/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(name)-\(PerfHarness.variant).png"), options: .atomic)
    }
}

// MARK: - 测试数据（只写测试楼层，准备进程里跑，测量进程只读）

enum PerfSeed {
    static let markerKey = "perfFlashSeedDone_v1"
    static let longMarkerKey = "perfFlashSeedLong_v2"
    static let lenA = 60
    static let lenB = 300
    static let listCount = 150
    static let forks = [100, 200]
    /// B 当前主线倒数第 3 条（首屏可见）是 >3000 字长文：文章模式整条走异步 markdown 排版（进 B 的必需异步集，§7.1）；
    /// 气泡模式按空行拆成小块、都同步
    static let longNodeIndex = lenB - 3
    static var pathA: [String] { (0..<lenA).map { "\(PerfHarness.convA)-\($0)" } }
    static var pathB: [String] { (0..<lenB).map { "\(PerfHarness.convB)-\($0)" } }

    static func injectIfNeeded(container: ModelContainer) {
        let ctx = ModelContext(container)
        if !UserDefaults.standard.bool(forKey: markerKey) {
            let pid = PerfHarness.profileId
            let now = Date()
            for i in 0..<listCount {
                let cid = "perf-flash-list-\(i)"
                let n = 2 + i % 5
                let t = now.addingTimeInterval(Double(-i) * 3600)
                insertLinear(ctx, convId: cid, count: n, pid: pid, base: t)
                let conv = Conversation(id: cid, title: "列表样本 \(i)：\(sampleTitle(i))", createTime: t, updateTime: t,
                    currentNodeId: "\(cid)-\(n - 1)", provider: "api", profileId: pid)
                conv.nodeCount = n
                ctx.insert(conv)
            }
            insertLinear(ctx, convId: PerfHarness.convA, count: lenA, pid: pid, base: now)
            let a = Conversation(id: PerfHarness.convA, title: "[PERF] 目标对话 A（60）", createTime: now, updateTime: now,
                currentNodeId: "\(PerfHarness.convA)-\(lenA - 1)", provider: "api", profileId: pid)
            a.nodeCount = lenA
            ctx.insert(a)
            let total = insertBranched(ctx, pid: pid, base: now)
            let b = Conversation(id: PerfHarness.convB, title: "[PERF] 目标对话 B（300 + 分支）", createTime: now, updateTime: now,
                currentNodeId: "\(PerfHarness.convB)-\(lenB - 1)", provider: "api", profileId: pid)
            b.nodeCount = total
            ctx.insert(b)
            do {
                try ctx.save()
                UserDefaults.standard.set(true, forKey: markerKey)
            } catch {
                NSLog("[PERF seed] FAILED: \(error)")
                return
            }
        }
        if !UserDefaults.standard.bool(forKey: longMarkerKey) {
            let id = "\(PerfHarness.convB)-\(longNodeIndex)"
            if let node = try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id })).first {
                node.content = longMarkdown()
                if (try? ctx.save()) != nil { UserDefaults.standard.set(true, forKey: longMarkerKey) }
            }
        }
    }

    static let bulkMarkerKey = "perfFlashBulkDone_v1"
    static let bulkConvs = 1500
    static let bulkNodesPerConv = 130

    /// 大库补种：模拟 Air 那种体量（~1700 对话 / ~20 万节点），冷启动的整表 count / 全量 fetch 才有真实成本
    static func injectBulkIfNeeded(container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: bulkMarkerKey) else { return }
        let pid = PerfHarness.profileId
        let now = Date()
        for batch in stride(from: 0, to: bulkConvs, by: 25) {
            let ctx = ModelContext(container)
            ctx.autosaveEnabled = false
            for i in batch..<min(batch + 25, bulkConvs) {
                let cid = "perf-flash-bulk-\(i)"
                let base = now.addingTimeInterval(Double(-(i + 200)) * 3600)
                insertLinear(ctx, convId: cid, count: bulkNodesPerConv, pid: pid, base: base)
                let conv = Conversation(id: cid, title: "大库样本 \(i)：\(sampleTitle(i))", createTime: base, updateTime: base,
                    currentNodeId: "\(cid)-\(bulkNodesPerConv - 1)", provider: "api", profileId: pid)
                conv.nodeCount = bulkNodesPerConv
                ctx.insert(conv)
            }
            do { try ctx.save() } catch { NSLog("[PERF bulk seed] FAILED at \(batch): \(error)"); return }
        }
        UserDefaults.standard.set(true, forKey: bulkMarkerKey)
    }

    /// 测前测后都记：目标对话节点数、长文长度、列表条数——漂移即数据被测量本身改了
    static func fingerprint(_ ctx: ModelContext?) -> [String: Int] {
        guard let ctx else { return [:] }
        let a = PerfHarness.convA, b = PerfHarness.convB, pid = PerfHarness.profileId
        let longId = "\(b)-\(longNodeIndex)"
        return [
            "nodesA": (try? ctx.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == a }))) ?? -1,
            "nodesB": (try? ctx.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == b }))) ?? -1,
            "benchConvs": (try? ctx.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid }))) ?? -1,
            "longChars": (try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == longId })).first?.content.count) ?? -1,
        ]
    }

    private static func body(_ i: Int) -> String { PerfChatCore.Fixture.body(i) }

    static func longMarkdown() -> String {
        var s = "## 长文样本（>3000 字，走异步排版）\n\n"
        for k in 0..<24 {
            s += "### 第 \(k + 1) 节\n\n第 \(k + 1) 节正文：这一段用来模拟一条很长的回复，包含 **加粗**、*斜体*、`代码` 和一个列表。"
            s += "它的目的是让首屏里有一条超过同步排版阈值的消息，打开对话时必须等它异步排好版才算真的能用。\n\n"
            s += "- 要点 \(k)-1：打开对话的首屏\n- 要点 \(k)-2：长文异步排版\n\n"
        }
        return s
    }

    private static func sampleTitle(_ i: Int) -> String {
        ["周末计划", "读书笔记", "代码评审", "旅行清单", "晚饭吃什么", "工作复盘", "随手记"][i % 7]
    }

    private static func insertLinear(_ ctx: ModelContext, convId: String, count: Int, pid: String, base: Date) {
        for i in 0..<count {
            ctx.insert(MessageNode(id: "\(convId)-\(i)", role: i % 2 == 0 ? "user" : "assistant", content: body(i),
                contentType: "text", createTime: base.addingTimeInterval(Double(i - count) * 30),
                parentId: i == 0 ? nil : "\(convId)-\(i - 1)",
                childrenIds: i == count - 1 ? [] : ["\(convId)-\(i + 1)"],
                conversationId: convId, profileId: pid))
        }
    }

    /// B 主线 0..<300；在 100、200 两处各挂一条 5 节点旁支（旁支首节点是主线节点的第二个孩子）
    private static func insertBranched(_ ctx: ModelContext, pid: String, base: Date) -> Int {
        let cid = PerfHarness.convB
        for i in 0..<lenB {
            var children = i == lenB - 1 ? [] : ["\(cid)-\(i + 1)"]
            if forks.contains(i) { children.append("\(cid)-side\(i)-0") }
            ctx.insert(MessageNode(id: "\(cid)-\(i)", role: i % 2 == 0 ? "user" : "assistant", content: body(i),
                contentType: "text", createTime: base.addingTimeInterval(Double(i - lenB) * 30),
                parentId: i == 0 ? nil : "\(cid)-\(i - 1)", childrenIds: children,
                conversationId: cid, profileId: pid))
        }
        for f in forks {
            for j in 0..<5 {
                let id = "\(cid)-side\(f)-\(j)"
                let parent = j == 0 ? "\(cid)-\(f)" : "\(cid)-side\(f)-\(j - 1)"
                ctx.insert(MessageNode(id: id, role: (f + 1 + j) % 2 == 0 ? "user" : "assistant",
                    content: "旁支 \(f)-\(j)：另一种说法。", contentType: "text",
                    createTime: base.addingTimeInterval(Double(f + j - lenB) * 30 + 5), parentId: parent,
                    childrenIds: j == 4 ? [] : ["\(cid)-side\(f)-\(j + 1)"], conversationId: cid, profileId: pid))
            }
        }
        return lenB + forks.count * 5
    }
}
extension Driver {
    /// utsname 机型码（iPhone14,7 之类），跨设备看板分栏用（perf-watch F4）
    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// 主可执行文件的 LC_UUID：host 端 `dwarfdump --uuid` 对账，证明装上去的就是这个包（astra R4 M2-1）
    static func mainBinaryUUID() -> String {
        guard let header = _dyld_get_image_header(0) else { return "-" }
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == UInt32(LC_UUID) {
                let u = cmd.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: u).uuidString
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        return "-"
    }
}

// MARK: - 纵切 3 · 测量角色封闭条件（plan-chat-list-perf-p0 §3.1 / §3.2）

/// 声明抑制计数 + 意外外发记账。钩子可能在任意线程（URLProtocol、非隔离 Router、后台 Task），状态一律上锁
enum PerfGuardrails {
    static let trapErrorDomain = "PerfOutboundTrap"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var suppressedCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var outboundLog: [String] = []
    nonisolated(unsafe) private static var holdAbort = false

    /// 声明的抑制：预期发生、不算失败，进运行级 `suppressed[name]`
    static func suppress(_ name: String) {
        lock.lock(); suppressedCounts[name, default: 0] += 1; lock.unlock()
    }

    static var suppressed: [String: Int] { lock.lock(); defer { lock.unlock() }; return suppressedCounts }
    static var outbound: [String] { lock.lock(); defer { lock.unlock() }; return outboundLog }
    static func setHoldAbort(_ hold: Bool) { lock.lock(); holdAbort = hold; lock.unlock() }

    /// 意外外发 = 正确性 / 安全失败：记下并立即停轮（外发自测期间只记不停）。detail 只写凭据 id / host，不写路径与 query
    static func tripOutbound(_ kind: String, _ detail: String) {
        lock.lock(); outboundLog.append("\(kind) \(detail)"); let hold = holdAbort; lock.unlock()
        guard !hold else { return }
        Task { @MainActor in Driver.abortForSafety() }
    }
}

/// 严格角色兜底陷阱：`URLProtocol.registerClass` 全局注册（appInit）。覆盖面实测见 plan §3.1；
/// WebSocket 任务、WKWebView、进程外服务本来就拦不到
final class PerfOutboundTrap: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard PerfHarness.strictMeasure, let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        PerfGuardrails.tripOutbound("urlSession", request.url?.host ?? "?")
        client?.urlProtocol(self, didFailWithError: NSError(domain: PerfGuardrails.trapErrorDomain, code: 1,
            userInfo: [NSLocalizedDescriptionKey: "[PERF] 严格测量角色拦下外发"]))
    }

    override func stopLoading() {}
}

// MARK: - 纵切 3 · 楼层防呆（§3.3，Release+PERF_BENCH 可编）

/// 无任何测量角色的正常启动落在 bench 楼层 → 切回记下的原楼层并清键（等同一次 restore）；
/// 键缺 / 原楼层不在才退到第一个非 bench 楼层（保键留证）。Debug 下旧 guardNormalLaunch 先跑，行为不变
@MainActor
enum PerfFloorGuard {
    static func run(pm: ProfileManager) {
        guard !PerfHarness.anyRole else { return }
        #if DEBUG
        guard !PerfBenchSeed.isActive, !StreamSmokeSeed.isActive else { return }
        #endif
        // §14-91：测量轮进行中不动楼层。thermal 探针在 App.init 首行 exit，SpringBoard 当作启动失败、随即不带 env
        // 重拉一个前台进程（mask syslog 实证）；这个无角色进程若照常切回原楼层，下一个测量进程就起在原楼层、整轮停。
        // 判据：Documents/perf 下 60s 内有 JSON 落盘（seed / 测量 / 探针进程收尾都写）；她正常打开不会撞上这个窗口
        if let age = recentPerfWriteAge(), age < 60 {
            NSLog("[PERF floor guard] perf round active (last JSON \(Int(age))s ago) → leave floor as is")
            return
        }
        let saved = UserDefaults.standard.string(forKey: PerfHarness.originalProfileKey)
        let decision = PerfChatCore.floorGuard(saved: saved, current: pm.currentProfile.id,
                                               profiles: pm.profiles.map(\.id), bench: PerfHarness.profileId)
        ChatV1Fixture.cleanupStray(ModelContext(pm.container), scanNodes: decision != nil)
        guard let decision, let target = pm.profiles.first(where: { $0.id == decision.target }) else { return }
        pm.switchTo(target)
        if decision.clearKey, pm.currentProfile.id == decision.target {
            UserDefaults.standard.removeObject(forKey: PerfHarness.originalProfileKey)
        }
        NSLog("[PERF floor guard] normal launch on bench profile → \(decision.target) (clearKey=\(decision.clearKey))")
    }

    /// Documents/perf 下最新一个 JSON 距今秒数（没有目录 / 文件 = nil）
    private static func recentPerfWriteAge() -> TimeInterval? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("perf", isDirectory: true),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "json" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        return newest.map { Date().timeIntervalSince($0) }
    }
}

// MARK: - 纵切 3 · chatV1 fixture（§7）：写入 / fetch / 清理一律限定 (bench profileId, conversationId)，不全量 fetch MessageNode

@MainActor
enum ChatV1Fixture {
    typealias Core = PerfChatCore
    static let sentinel = "perfFlashSeedChatV1_v1"
    /// 整轮基线：首次 seed 写入 {digest, 各对话规范摘要}，之后 seed / 测量进程都与它比。
    /// v2（R4 C-09）：指纹加发送四字段，规范串变了，旧 v1 基线不再比对
    static let baselineKey = "perfFlashChatV1Fingerprint_v2"
    /// A / B 指纹不含 branchSelectionData（§14-21：③b 首开 B 可能补写选择表）
    static let branchSelectionExcluded: Set<String> = ["A", "B"]
    /// 指纹覆盖 legacy A / B（内容不动）+ 新 L / D / S
    static let convs: [(key: String, id: String)] = [("A", PerfHarness.convA), ("B", PerfHarness.convB)]
        + Core.Fixture.all.map { ($0.key, $0.convId) }

    static func records(_ ctx: ModelContext, _ cid: String) -> (nodes: [Core.NodeRecord], conv: Core.ConvRecord?) {
        let pid = PerfHarness.profileId
        let nodes = (try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == pid && $0.conversationId == cid }))) ?? []
        let conv = (try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId == pid })))?.first
        return (nodes.map { Core.NodeRecord(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds, content: $0.content, role: $0.role) },
                conv.map(record))
    }

    static func record(_ c: Conversation) -> Core.ConvRecord {
        Core.ConvRecord(currentNodeId: c.currentNodeId, updateTime: c.updateTime, nodeCount: c.nodeCount,
                        unreadCount: c.unreadCount, title: c.title, memoryEnabled: c.memoryEnabled,
                        branchSelectionData: c.branchSelectionData, selectedModelId: c.selectedModelId,
                        draftText: c.draftText, permGrantsRaw: c.permGrantsRaw)
    }

    struct Snapshot {
        var perConv: [String: Core.ConvFingerprint] = [:]
        var missing: [String] = []
        var benchConvs = -1
        var digest: String { missing.isEmpty ? Core.fixtureDigest(perConv, benchConvs: benchConvs) : "fx-missing-" + missing.joined(separator: ",") }
        var convDigests: [String: String] { perConv.mapValues { String(Core.fnv1a64($0.canonical), radix: 16) } }
        var report: [String: Any] {
            var out: [String: Any] = [:]
            for (key, fp) in perConv {
                out[key] = ["storedNodes": fp.storedNodes, "nodeCount": fp.nodeCount, "currentNodeId": fp.currentNodeId ?? "-",
                            "title": fp.title, "memoryEnabled": fp.memoryEnabled, "unreadCount": fp.unreadCount,
                            "digest": String(Core.fnv1a64(fp.canonical), radix: 16)] as [String: Any]
            }
            return ["perConv": out, "missing": missing, "benchConvs": benchConvs, "digest": digest]
        }
    }

    /// 新 ModelContext 只读已落盘状态
    static func snapshot(_ container: ModelContainer, keys: Set<String>? = nil) -> Snapshot {
        let ctx = ModelContext(container)
        let pid = PerfHarness.profileId
        var s = Snapshot()
        s.benchConvs = (try? ctx.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid }))) ?? -1
        for c in convs where keys?.contains(c.key) ?? true {
            let r = records(ctx, c.id)
            if let conv = r.conv {
                s.perConv[c.key] = Core.ConvFingerprint(nodes: r.nodes, conv: conv, includeBranchSelection: !branchSelectionExcluded.contains(c.key))
            } else { s.missing.append(c.key) }
        }
        return s
    }

    /// 与整轮基线比：返回不一致的对话 key（基线缺 = nil）
    static func baselineDiff(_ snap: Snapshot) -> [String]? {
        guard let base = UserDefaults.standard.dictionary(forKey: baselineKey) as? [String: String] else { return nil }
        let now = snap.convDigests
        return convs.map(\.key).filter { base[$0] != now[$0] } + (base["digest"] == snap.digest ? [] : ["digest"])
    }

    /// seed 进程：清误写 → 补种（sentinel）→ S 复原 → 与生成器逐项核 L / D / S → A / B 前后不变 → 基线（首次写入，之后比对）
    static func seed(_ container: ModelContainer) -> (report: [String: Any], failures: [String]) {
        var failures: [String] = []
        var report: [String: Any] = ["strayRemoved": cleanupStray(ModelContext(container), scanNodes: true)]
        let ab0 = snapshot(container, keys: ["A", "B"])
        // R4 C-10：sentinel 为真且 L / D / S 都在才跳过；缺的重插并清基线重记（bench 楼层整层删过也能自愈）。
        // MP_PERF_TEST_FIXTURE_MISSING=L,D,S = 自测：把这些 key 当缺失，走真实重插路径（不删楼层）
        let simulated = Set((PerfHarness.env["MP_PERF_TEST_FIXTURE_MISSING"] ?? "").split(separator: ",").map(String.init))
        // R14（fixture 升 r10）：生成器改了内容的对话（除流式会改写、另有复原的 S）当缺失重插，基线随之重记
        let pre = snapshot(container, keys: Set(Core.Fixture.all.map(\.key)))
        let stale = Set(Core.Fixture.all.filter { $0.key != "S" }.compactMap { spec in
            pre.perConv[spec.key].flatMap { $0.diff(Core.Fixture.fingerprint(spec)).isEmpty ? nil : spec.key }
        })
        if !stale.isEmpty { report["staleReinserted"] = stale.sorted() }
        let present = Set(pre.perConv.keys).subtracting(simulated).subtracting(stale)
        let plan = Core.fixtureInsertPlan(sentinel: UserDefaults.standard.bool(forKey: sentinel), present: present)
        report["injected"] = !plan.insert.isEmpty
        report["inserted"] = plan.insert
        if !simulated.isEmpty { report["testSimulatedMissing"] = simulated.sorted() }
        do {
            for spec in Core.Fixture.all where plan.insert.contains(spec.key) {
                try clear(spec, container)
                try insert(spec, container)
            }
            if plan.resetBaseline { UserDefaults.standard.removeObject(forKey: baselineKey) }
            UserDefaults.standard.set(true, forKey: sentinel)
        } catch {
            failures.append("chatV1 seed: insert failed \(error)")
        }
        let restore = restoreS(container)
        report["restoreS"] = restore.report
        if let f = restore.failure { failures.append(f) }
        let snap = snapshot(container)
        for spec in Core.Fixture.all {
            guard let fp = snap.perConv[spec.key] else { failures.append("chatV1 seed: \(spec.key) missing"); continue }
            let diff = fp.diff(Core.Fixture.fingerprint(spec))
            if !diff.isEmpty { failures.append("chatV1 seed: \(spec.key) differs from generator (\(diff.joined(separator: ",")))") }
        }
        for key in ["A", "B"] where ab0.perConv[key] != snap.perConv[key] {
            failures.append("chatV1 seed: \(key) fingerprint changed during seed")
        }
        let ctx = ModelContext(container)
        let pid = PerfHarness.profileId
        var longs: [String: [String]] = [:]
        for spec in Core.Fixture.all where !spec.longIndices.isEmpty {
            longs[spec.key] = spec.longIndices.map { i in
                let id = Core.Fixture.nodeId(spec, i)
                let node = (try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id && $0.profileId == pid })))?.first
                return node.map { "\(i):\($0.role):\($0.content.count)" } ?? "\(i):missing"
            }
        }
        report["longNodes"] = longs
        report["abUnchanged"] = ab0.perConv["A"] == snap.perConv["A"] && ab0.perConv["B"] == snap.perConv["B"]
        report["fixture"] = snap.report
        if let diff = baselineDiff(snap) {
            report["baseline"] = diff.isEmpty ? "match" : "drift"
            if !diff.isEmpty { failures.append("chatV1 seed: fixture drifted from baseline (\(diff.joined(separator: ",")))") }
        } else if snap.missing.isEmpty, failures.isEmpty {
            UserDefaults.standard.set(snap.convDigests.merging(["digest": snap.digest]) { a, _ in a }, forKey: baselineKey)
            report["baseline"] = "recorded"
        }
        return (report, failures)
    }

    /// 重插前清掉同 id 的残留（只按 (bench, convId)）：对话行删了、节点还在，或自测把在场的当缺失
    private static func clear(_ spec: Core.Fixture.Spec, _ container: ModelContainer) throws {
        let pid = PerfHarness.profileId, cid = spec.convId
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        try ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == pid && $0.conversationId == cid })).forEach { ctx.delete($0) }
        try ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId == pid })).forEach { ctx.delete($0) }
        if ctx.hasChanges { try ctx.save() }
    }

    private static func insert(_ spec: Core.Fixture.Spec, _ container: ModelContainer) throws {
        let pid = PerfHarness.profileId
        let nodes = Core.Fixture.nodes(spec)
        for start in stride(from: 0, to: nodes.count, by: 500) {
            let ctx = ModelContext(container)
            ctx.autosaveEnabled = false
            for i in start..<min(start + 500, nodes.count) {
                let n = nodes[i]
                ctx.insert(MessageNode(id: n.id, role: n.role, content: n.content, contentType: "text",
                    createTime: Core.Fixture.createTime(spec, i), parentId: n.parentId, childrenIds: n.childrenIds,
                    conversationId: spec.convId, profileId: pid))
            }
            try ctx.save()
        }
        let c = Core.Fixture.conv(spec)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let conv = Conversation(id: spec.convId, title: c.title, createTime: Core.Fixture.baseDate, updateTime: c.updateTime,
                                currentNodeId: c.currentNodeId ?? "", provider: "api", profileId: pid)
        conv.nodeCount = c.nodeCount
        conv.unreadCount = c.unreadCount
        conv.memoryEnabled = c.memoryEnabled
        conv.branchSelectionData = c.branchSelectionData
        conv.selectedModelId = c.selectedModelId
        conv.draftText = c.draftText
        conv.permGrantsRaw = c.permGrantsRaw
        ctx.insert(conv)
        try ctx.save()
    }

    /// §7.3 S 复原（测量进程唯一的写库）：按 (bench, S) fetch → PerfChatCore.restorePlan → 删游离、改回种子字段 → 保存 →
    /// 新 ModelContext 重读，整份指纹 == 种子。种子节点缺 = fixture 损坏，不在复原里重建
    static func restoreS(_ container: ModelContainer) -> (report: [String: Any], failure: String?) {
        let spec = Core.Fixture.S, pid = PerfHarness.profileId, cid = spec.convId
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let nodes = (try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == pid && $0.conversationId == cid }))) ?? []
        guard let conv = (try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId == pid })))?.first else {
            return (["found": false], "restoreS: conversation S missing on bench profile")
        }
        let seedNodes = Core.Fixture.nodes(spec), seedConv = Core.Fixture.conv(spec)
        let plan = Core.restorePlan(seedNodes: seedNodes, seedConv: seedConv,
            nodes: nodes.map { Core.NodeRecord(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds, content: $0.content, role: $0.role) },
            conv: record(conv))
        var report: [String: Any] = ["deleted": plan.deleteIds, "nodeFixes": plan.nodeFixes.mapValues { $0.map(\.rawValue).sorted() },
                                     "convFields": plan.convFields.map(\.rawValue).sorted(), "noop": plan.isNoop]
        // R7-11：删之前记被删节点的落库内容摘要（turn 节点：助手 == 脚本终稿、user == 发送原文，由 chatV1Finish 对账）
        let doomedIds = Set(plan.deleteIds)
        report["deletedDigests"] = Dictionary(uniqueKeysWithValues: nodes.filter { doomedIds.contains($0.id) }.map { ($0.id, String(format: "%016llx", Core.fnv1a64($0.content))) })
        guard plan.missingSeedIds.isEmpty else {
            report["missingSeed"] = plan.missingSeedIds
            return (report, "restoreS: seed nodes missing (\(plan.missingSeedIds.count)), fixture corrupt")
        }
        if !plan.isNoop {
            let seedById = Dictionary(uniqueKeysWithValues: seedNodes.map { ($0.id, $0) })
            let doomed = Set(plan.deleteIds)
            for node in nodes {
                if doomed.contains(node.id) { ctx.delete(node); continue }
                guard let fix = plan.nodeFixes[node.id], let s = seedById[node.id] else { continue }
                if fix.contains(.parentId) { node.parentId = s.parentId }
                if fix.contains(.childrenIds) { node.childrenIds = s.childrenIds }
                if fix.contains(.content) { node.content = s.content }
            }
            for field in plan.convFields {
                switch field {
                case .currentNodeId: conv.currentNodeId = seedConv.currentNodeId ?? ""
                case .updateTime: conv.updateTime = seedConv.updateTime
                case .nodeCount: conv.nodeCount = seedConv.nodeCount
                case .unreadCount: conv.unreadCount = seedConv.unreadCount
                case .title: conv.title = seedConv.title
                case .memoryEnabled: conv.memoryEnabled = seedConv.memoryEnabled
                case .branchSelectionData: conv.branchSelectionData = seedConv.branchSelectionData
                case .selectedModelId: conv.selectedModelId = seedConv.selectedModelId
                case .draftText: conv.draftText = seedConv.draftText
                case .permGrantsRaw: conv.permGrantsRaw = seedConv.permGrantsRaw
                }
            }
            do { try ctx.save() } catch { return (report, "restoreS: save failed \(error)") }
        }
        let fresh = records(ModelContext(container), cid)
        guard let freshConv = fresh.conv else { return (report, "restoreS: S vanished after restore") }
        let diff = Core.ConvFingerprint(nodes: fresh.nodes, conv: freshConv).diff(Core.Fixture.fingerprint(spec))
        report["verified"] = diff.isEmpty
        return diff.isEmpty ? (report, nil) : (report, "restoreS: fingerprint != seed after restore (\(diff.joined(separator: ",")))")
    }

    /// fixture 对话在 bench 之外楼层的误写（K-12）。对话按唯一 id 查，便宜，每次正常启动都做；
    /// 节点只能按 conversationId 扫（索引首列是 profileId，`!=` 用不上），只在 seed 与防呆触发时扫
    @discardableResult
    static func cleanupStray(_ ctx: ModelContext, scanNodes: Bool) -> Int {
        let pid = PerfHarness.profileId
        var removed = 0
        for c in convs {
            let cid = c.id
            let strayConvs = (try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId != pid }))) ?? []
            strayConvs.forEach { ctx.delete($0) }
            removed += strayConvs.count
            guard Core.scanStrayNodes(forced: scanNodes, strayConvs: strayConvs.count) else { continue }   // R4 C-06：删到对话就连节点一起扫
            let strayNodes = (try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == cid && $0.profileId != pid }))) ?? []
            strayNodes.forEach { ctx.delete($0) }
            removed += strayNodes.count
        }
        if removed > 0 {
            try? ctx.save()
            NSLog("[PERF fixture] removed \(removed) stray rows of perf fixture conversations from non-bench profiles")
        }
        return removed
    }
}

// MARK: - 纵切 3 · chatV1 严格测量进程：S 复原 / 自测钩子 / 报告

extension Driver {
    static var chatV1SeedReport: [String: Any]?
    private static var chatV1Failures: [[String: Any]] = []
    static var chatV1Extra: [String: Any] = [:]

    /// occ 非 nil = 该 occurrence 的失败（分析器按 (class, occ) 对账 occurrence status）
    static func chatFail(_ kind: PerfChatCore.FailureKind, _ detail: String, occ: Int? = nil) {
        var f: [String: Any] = ["class": kind.failureClass.rawValue, "code": kind.rawValue, "detail": detail]
        if let occ { f["occ"] = occ }
        chatV1Failures.append(f)
    }

    /// 意外外发：立即写 JSON 退出（§3、§4.6 外发立即停轮）
    static func abortForSafety() { finishRun() }

    static func chatV1Seed(_ container: ModelContainer) {
        let t = CACurrentMediaTime()
        let r = ChatV1Fixture.seed(container)
        var report = r.report
        report["ms"] = ms(CACurrentMediaTime() - t)
        chatV1SeedReport = report
        failures += r.failures
    }

    /// 已过入口断言（启动楼层 = bench）与 coldStart setup
    static func chatV1Run() async {
        guard let container = PerfHarness.container else { chatFail(.probeMissing, "no model container"); return }
        let before = ChatV1Fixture.restoreS(container)   // 上次崩溃 / 超时遗留先修再测（§7.3）
        chatV1Extra["restoreSBefore"] = before.report
        if let f = before.failure { chatFail(.restoreFailed, f); return }
        if PerfHarness.env["MP_PERF_TEST_RESTORE"] == "1" { restoreSelfTest(container); return }
        if PerfHarness.env["MP_PERF_TEST_OUTBOUND"] == "1" { await outboundSelfTest(); return }
        if PerfHarness.env["MP_PERF_SCENARIOS"] == "indexProbe" { await indexProbe(); return }
        await ChatV1Load.run(op: PerfHarness.env["MP_PERF_SCENARIOS"] ?? "-")
    }

    /// M5 索引门探针（runner index_wait 起，不进分母）：等 SearchIndexer 离开 idle / building（最多 90s），
    /// 读 docCount，隔 3s 再读一次；读数写 chatV1.indexProbe 后照常 finishRun
    private static func indexProbe() async {
        let t0 = CACurrentMediaTime()
        func status() -> String {
            switch SearchIndexer.shared.state.status {
            case .idle: return "idle"
            case .building: return "building"
            case .ready: return "ready"
            case .failed: return "failed"
            }
        }
        while ["idle", "building"].contains(status()), CACurrentMediaTime() - t0 < 90 {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let first = SearchIndexer.shared.state.docCount
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        chatV1Extra["indexProbe"] = ["status": status(), "docCount": first, "docCount2": SearchIndexer.shared.state.docCount,
                                     "waitedMs": ms(CACurrentMediaTime() - t0)] as [String: Any]
    }

    /// finishRun 开头：S 复原（结束后那次）+ 整轮 fixture 指纹对基线。外发停轮也走这里
    static func chatV1Finish() {
        chatV1Extra["mainContextPending"] = PerfHarness.modelContext?.hasChanges ?? false
        guard PerfHarness.profileAtLaunch == PerfHarness.profileId, let container = PerfHarness.container else { return }
        let after = ChatV1Fixture.restoreS(container)
        chatV1Extra["restoreSAfter"] = after.report
        if let f = after.failure { chatFail(.restoreFailed, f) }
        // R7-11：turn 节点落库内容（onComplete 写终稿 + save）对账，不只靠「删到了 2 个节点」间接证明
        let deleted = after.report["deletedDigests"] as? [String: String] ?? [:]
        for (id, want) in ChatV1Turn.persistExpect where deleted[id] != String(format: "%016llx", want) {
            chatFail(.contentMismatch, "persisted node \(id) digest \(deleted[id] ?? "missing") != expected \(String(format: "%016llx", want))", occ: 1)
        }
        let snap = ChatV1Fixture.snapshot(container)
        chatV1Extra["fixture"] = snap.report
        chatV1Extra["fixtureFingerprint"] = snap.digest
        if let diff = ChatV1Fixture.baselineDiff(snap) {
            if !diff.isEmpty { chatFail(.crossConversationWrite, "fixture drifted from seed baseline: \(diff.joined(separator: ","))") }
        } else {
            chatFail(.fixtureCorrupt, "no chatV1 fixture baseline (run MP_PERF_SEED first)")
        }
    }

    static func chatV1Decorate(_ report: inout [String: Any]) {
        for o in PerfGuardrails.outbound { chatFail(.unexpectedOutbound, o) }
        let legacy = (report["failures"] as? [String]) ?? []
        let mapped = legacy.map { f -> [String: Any] in
            f.hasPrefix("coldStart") ? ["class": "instrument", "code": "setup", "detail": f] : ["class": "correctness", "code": "harness", "detail": f]
        }
        report["failures"] = mapped + chatV1Failures
        report["protocol"] = "chatV1"
        var payload: [String: Any] = ["protocolVersion": "chatV1", "harnessRevision": "chatV1-r10",
                                      "op": PerfHarness.env["MP_PERF_SCENARIOS"] ?? "-", "buildConfig": report["config"] ?? "-",
                                      "suppressed": PerfGuardrails.suppressed, "outboundTrap": "URLProtocol.registerClass"]
        for (k, v) in chatV1Extra { payload[k] = v }
        report["chatV1"] = payload
    }

    /// 3.5 自测：往 S 塞游离节点并改 currentNodeId / nodeCount / updateTime → 复原后指纹 == 种子；再跑一次应无改动（幂等）
    private static func restoreSelfTest(_ container: ModelContainer) {
        let spec = PerfChatCore.Fixture.S, pid = PerfHarness.profileId, cid = spec.convId
        let last = PerfChatCore.Fixture.nodeId(spec, spec.count - 1)
        let strayId = "\(cid)-perf-test-stray"
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        ctx.insert(MessageNode(id: strayId, role: "user", content: "perf restore self-test stray", contentType: "text",
            createTime: Date(), parentId: last, childrenIds: [], conversationId: cid, profileId: pid))
        (try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == last && $0.profileId == pid })))?.first?.childrenIds.append(strayId)
        if let conv = (try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId == pid })))?.first {
            conv.currentNodeId = strayId
            conv.nodeCount += 1
            conv.updateTime = Date()
            // R4 C-09：发送还会写的四个字段一并弄脏
            conv.branchSelectionData = Data("{\"perf\":\"test\"}".utf8)
            conv.selectedModelId = "perf-test/stray-model"
            conv.draftText = "perf restore self-test draft"
            conv.permGrantsRaw = "perf-test:allow"
        }
        do { try ctx.save() } catch { chatFail(.probeMissing, "restore test: dirty save failed \(error)"); return }
        let dirty = ChatV1Fixture.snapshot(container, keys: ["S"]).perConv["S"]?.diff(PerfChatCore.Fixture.fingerprint(spec)) ?? ["missing"]
        let first = ChatV1Fixture.restoreS(container)
        let second = ChatV1Fixture.restoreS(container)
        chatV1Extra["restoreTest"] = ["dirtyDiff": dirty, "first": first.report, "second": second.report] as [String: Any]
        if dirty.isEmpty { chatFail(.restoreFailed, "restore test: injection did not dirty S") }
        if let f = first.failure { chatFail(.restoreFailed, "restore test first pass: \(f)") }
        if let f = second.failure { chatFail(.restoreFailed, "restore test second pass: \(f)") }
        if second.report["noop"] as? Bool != true { chatFail(.restoreFailed, "restore test: second pass not a no-op") }
    }

    /// 3.1 自测：只打 https://perf-trap.invalid/…（RFC 6761 不可解析）、不带任何凭据；Router 用假凭据 id，
    /// 陷阱在 provider 查找之前，providerManager 里的真实凭据不被读。按设计以正确性失败（unexpectedOutbound）退出
    private static func outboundSelfTest() async {
        PerfGuardrails.setHoldAbort(true)
        var result: [String: Any] = [:]
        result["shared"] = await trapProbe(URLSession.shared, "shared")
        let def = URLSession(configuration: .default)
        result["defaultConfig"] = await trapProbe(def, "default")
        def.invalidateAndCancel()
        let eph = URLSession(configuration: .ephemeral)
        result["ephemeralConfig"] = await trapProbe(eph, "ephemeral")
        eph.invalidateAndCancel()
        PerfGuardrails.setHoldAbort(false)
        chatV1Extra["outboundTest"] = result
        guard let providers = PerfHarness.providers, let router = PerfHarness.viewModel?.providerRouter else {
            chatFail(.probeMissing, "outbound test: providerManager / router not registered")
            return
        }
        var routerError: String?
        router.sendStreaming(model: ProviderModel(credentialId: "perf-trap-fake", modelId: "perf-trap", name: "perf-trap"),
                             messages: [(role: "user", content: "perf-trap")], systemPrompt: nil, providerManager: providers,
                             onToken: { _ in }, onComplete: { _, _ in }, onError: { routerError = $0 })
        result["routerOnError"] = routerError ?? "-"   // 陷阱同步回 onError；停轮在下一个主线程回合
        chatV1Extra["outboundTest"] = result
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        chatFail(.probeMissing, "outbound test: router trap did not stop the run")
    }

    private static func trapProbe(_ session: URLSession, _ label: String) async -> [String: Any] {
        guard let url = URL(string: "https://perf-trap.invalid/\(label)") else { return [:] }
        let before = PerfGuardrails.outbound.count
        let t = CACurrentMediaTime()
        var out: [String: Any] = [:]
        do {
            _ = try await session.data(for: URLRequest(url: url, timeoutInterval: 5))
            out["result"] = "loaded"
        } catch {
            let ns = error as NSError
            out["errorDomain"] = ns.domain
            out["errorCode"] = ns.code
        }
        out["trapped"] = PerfGuardrails.outbound.count > before
        out["ms"] = ms(CACurrentMediaTime() - t)
        return out
    }
}
#endif
