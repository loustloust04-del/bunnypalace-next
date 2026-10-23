import Foundation
import MachO
import os

// MARK: - 秒连尺子（plan-app-instant-connect §2，harnessRevision 见 ConnectRuler.revision）
// 只加测量、连接控制流未改：日常包常开，只记时间戳 / 计数，不读模型、不写盘，随 connect_report 一起发给 hub。
// 埋点本身有成本（时钟读、unfair lock、metrics 委托回调），量级未测；MP_CONNECT_RULER=0 全关，留给带 / 不带尺子的 A/A 校准。
// 时长一律单调时钟（CLOCK_MONOTONIC_RAW = mach_continuous_time，含睡眠）；墙钟只留做跨端对齐。

enum ConnectClock {
    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

    static func ms(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? Double(b - a) / 1_000_000 : -Double(a - b) / 1_000_000
    }
}

enum ConnectRuler {
    /// 尺子口径每改一次升一版，新旧数据不混比（playbook §3.2）
    static let revision = "connectV2-r2"

    /// MP_CONNECT_RULER=0：所有新埋点都不执行（不读时钟、不加锁、不挂观察者、报告不带新字段）。进程里只读一次
    static let enabled = ProcessInfo.processInfo.environment["MP_CONNECT_RULER"] != "0"

    /// 埋点取时刻：关尺子时不读时钟
    static func stamp() -> UInt64 { enabled ? ConnectClock.nowNs() : 0 }

    static let build: String = {
        #if PERF_BENCH
        return "perf"
        #elseif DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }()

    // MARK: 样本身份（sol R1-2）：同包 / 同开关 / 同设备才能比

    /// 每次进程一个
    static let runId = UUID().uuidString

    /// A 刀开关有效值登记处（plan §3）：每加一刀，在这里登记它进程启动时读到的有效值（如 "A1": "1"）。现在还没有刀
    static func switches() -> [String: String] { [:] }

    /// 本模块所在镜像的 LC_UUID = 实际在跑的是哪个包。Release 是主二进制；Debug 的代码在拆出来的 .debug.dylib，
    /// #dsohandle 指的就是它。只读进程内已映射的 Mach-O 头，不读文件
    static let binaryUUID: String? = imageUUID(#dsohandle)

    static func imageUUID(_ header: UnsafeRawPointer) -> String? {
        let mh = header.loadUnaligned(as: mach_header_64.self)
        guard mh.magic == MH_MAGIC_64 else { return nil }
        var cmd = header.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<mh.ncmds {
            let lc = cmd.loadUnaligned(as: load_command.self)
            if lc.cmd == UInt32(LC_UUID) { return UUID(uuid: cmd.loadUnaligned(as: uuid_command.self).uuid).uuidString }
            guard lc.cmdsize > 0 else { return nil }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        return nil
    }

    static let deviceIdKey = "connectRuler.deviceId"

    /// 匿名稳定设备标识：app 自己生成的随机 UUID，存在 UserDefaults（卸载即换）。不读任何硬件 / 广告标识
    static func deviceId(_ defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: deviceIdKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIdKey)
        return id
    }

    /// 启动来源（sol R1-5），能判断多少算多少：预热 > 推送拉起 > 前台起（图标，也含 URL / 快捷方式）> 后台起且收过 VoIP > 未知。
    /// 依据 LaunchMarks.notes：launch.push / launch.fg / launch.bg（didFinishLaunching）、voipPush（PushKit 收到）
    static func launchSource(notes: [String], prewarm: Bool) -> String {
        if prewarm { return "prewarm" }
        if notes.contains("launch.push") { return "push" }
        if notes.contains("launch.fg") { return "icon" }
        if notes.contains("voipPush") { return "voip" }
        return "unknown"
    }
}

/// 进程内计数（sol R1-5）：每份报告都带当前值，hub 按 runId 取最大值看「开了几段、成功报上来几段」。被杀的进程不在账上
enum ConnectRunCounters {
    struct Snapshot: Equatable { var started = 0, ok = 0, replaced = 0, reportFailed = 0 }
    private static let state = OSAllocatedUnfairLock(initialState: Snapshot())

    /// 返回加完之后的值
    @discardableResult
    static func bump(_ key: WritableKeyPath<Snapshot, Int>) -> Int {
        state.withLock { $0[keyPath: key] += 1; return $0[keyPath: key] }
    }

    static func snapshot() -> Snapshot { state.withLock { $0 } }
}

// MARK: - 冷启动分段时间戳表
/// 不可观察的全局表，写入只追加；同名取第一次。锚点 = AppEntry.main 首行（"entry"），记下当时的墙钟，
/// 进程起点（p_starttime，墙钟）→ 锚点这一段只能用墙钟算，其余分段全是单调时钟。
enum LaunchMarks {
    struct Mark: Equatable { let name: String; let ns: UInt64 }
    struct State {
        var marks: [Mark] = []
        var entryWall: Date?
        var notes: [String] = []   // 启动来源 / 恢复分支之类的事实，去重
    }
    /// 上限：首屏 onAppear 之类可能重复触发，表不无限长
    static let capacity = 64
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func mark(_ name: String) {
        guard ConnectRuler.enabled else { return }
        let ns = ConnectClock.nowNs()
        let wall = name == "entry" ? Date() : nil
        state.withLock { s in
            guard s.marks.count < capacity else { return }
            s.marks.append(Mark(name: name, ns: ns))
            if let wall, s.entryWall == nil { s.entryWall = wall }
        }
    }

    static func note(_ fact: String) {
        guard ConnectRuler.enabled else { return }
        state.withLock { s in
            guard s.notes.count < capacity, !s.notes.contains(fact) else { return }
            s.notes.append(fact)
        }
    }

    static func snapshot() -> State { state.withLock { $0 } }

    /// 各点距 entry 的毫秒（单调）。没有 entry 锚 → nil。connect 点直接用冷启动那段的原始 entryNs（sol R1-9：
    /// 不另打点，免得把建忙段窗口的成本在 connect 段和 mono 段各算一次）
    static func offsets(_ marks: [Mark], connectNs: UInt64? = nil) -> [String: Int]? {
        guard let anchor = marks.first(where: { $0.name == "entry" }) else { return nil }
        var out: [String: Int] = [:]
        for m in marks where out[m.name] == nil {
            out[m.name] = Int(ConnectClock.ms(from: anchor.ns, to: m.ns).rounded())
        }
        if let connectNs { out["connect"] = Int(ConnectClock.ms(from: anchor.ns, to: connectNs).rounded()) }
        return out
    }

    /// A2 起跑线（sol R1-3）：受保护数据闸门（AppEntry.main）和 pending import 处理都过了。顺带记恢复分支
    static func bootstrapEligible(after pending: PendingImportApplier.ApplyResult) {
        guard ConnectRuler.enabled else { return }
        switch pending {
        case .noFlag: break
        case .succeeded: note("rec:pending.succeeded")
        case .versionMismatch: note("rec:pending.versionMismatch")
        case .failedAtStep(let step, _): note("rec:pending.failed." + step.rawValue)
        }
        mark("bootstrapEligible")
    }
}

// MARK: - 探测候选
/// 一轮竞速探测的计时：resume 时刻（主线程写）+ URLSessionTaskMetrics（session 委托队列写）。按候选序号存。
final class ProbeRoundTimings: @unchecked Sendable {
    private struct Slot { var taskId: Int?; var resumeNs: UInt64?; var taskMs: Double? }
    private let lock = OSAllocatedUnfairLock(initialState: [Int: Slot]())

    /// resume 之前登记 task → 候选序号（metrics 在委托队列上，可能比主线程记 resume 先到）
    func register(slot: Int, taskId: Int) {
        lock.withLock { $0[slot, default: Slot()].taskId = taskId }
    }

    /// resume 之后补记时刻（时刻本身是紧贴 resume 调用前取的）
    func noteResume(slot: Int, at ns: UInt64) {
        lock.withLock { $0[slot, default: Slot()].resumeNs = ns }
    }

    /// 委托队列上调：只记 URLSession 任务生命周期（taskInterval = task 创建 → 完成，含创建后未 resume 的那点时间），
    /// 不是纯网络；不碰 URL / 头
    func noteMetrics(taskId: Int, metrics: URLSessionTaskMetrics) {
        noteTask(taskId: taskId, ms: metrics.taskInterval.duration * 1000)
    }

    func noteTask(taskId: Int, ms: Double) {
        lock.withLock { slots in
            guard let slot = slots.first(where: { $0.value.taskId == taskId })?.key else { return }
            slots[slot]?.taskMs = ms
        }
    }

    func resumeNs(slot: Int) -> UInt64? { lock.withLock { $0[slot]?.resumeNs } }
    func taskMs(slot: Int) -> Double? { lock.withLock { $0[slot]?.taskMs } }
}

struct ConnectCandidateRecord {
    let host: String
    let resumeNs: UInt64?
    let callbackNs: UInt64     // 完成回调（session 委托队列）
    let enterNs: UInt64        // 排到主线程、block 开始
    let endNs: UInt64          // 主线程 block 结束
    let won: Bool
    let late: Bool             // 已有候选胜出后才到（多半是被撤的 cancelled）
    var taskMs: Double?        // URLSessionTaskMetrics.taskInterval（task 创建 → 完成的生命周期，墙钟区间）；没收到就缺
    var timings: ProbeRoundTimings?
    var gen = 0                // 这一轮的 probeGeneration
    var slot = 0

    /// 候选 id：「代次.序号」，进程内唯一；最终 WS 的 ws_via 指向它
    var id: String { "\(gen).\(slot)" }

    func json(entryNs: UInt64) -> [String: Any] {
        var o: [String: Any] = [
            "id": id,
            "round": gen,
            "h": host,
            "queue_ms": Int(ConnectClock.ms(from: callbackNs, to: enterNs).rounded()),
            "handle_ms": Int(ConnectClock.ms(from: enterNs, to: endNs).rounded()),
            "won": won,
        ]
        if let resumeNs {
            o["at_ms"] = Int(ConnectClock.ms(from: entryNs, to: resumeNs).rounded())
            o["cb_ms"] = Int(ConnectClock.ms(from: resumeNs, to: callbackNs).rounded())
        }
        if let taskMs { o["task_ms"] = Int(taskMs.rounded()) }
        if late { o["late"] = true }
        return o
    }
}

// MARK: - 连接窗口内主线程忙段（双观察者，playbook §3.2）
/// 纯累加：afterWaiting（order Int.min）开段、beforeWaiting（order Int.max）收段，忙段含布局 + CA 提交。
/// 所有收段 / 汇总都按 deadline 裁剪：deadline 之后的忙不计，过了 deadline 就标 capped（sol R1-8）。
struct BusyAccumulator: Equatable {
    let startNs: UInt64
    let deadlineNs: UInt64
    private(set) var busyNs: UInt64 = 0
    private(set) var blocks50 = 0
    private(set) var maxNs: UInt64 = 0
    private(set) var capped = false
    private var segStart: UInt64
    private var inSegment = true

    /// 窗口从主线程某个忙段中间开始：开段时刻取窗口起点
    init(startNs: UInt64, capNs: UInt64 = ConnectBusyWindow.capNs) {
        self.startNs = startNs
        deadlineNs = startNs &+ capNs
        segStart = startNs
    }

    mutating func open(at ns: UInt64) {
        guard ns < deadlineNs else { capped = true; inSegment = false; return }
        segStart = ns
        inSegment = true
    }

    mutating func close(at ns: UInt64) {
        if ns > deadlineNs { capped = true }
        guard inSegment else { return }
        inSegment = false
        let end = min(ns, deadlineNs)
        add(end > segStart ? end - segStart : 0)
    }

    /// 截至 ns（含进行中的段，裁到 deadline）；windowMs = 实际覆盖的窗口长度
    func summary(at ns: UInt64) -> BusySummary {
        var copy = self
        copy.close(at: ns)
        let end = min(ns, deadlineNs)
        return BusySummary(ms: Double(copy.busyNs) / 1_000_000, blocks50: copy.blocks50, maxMs: Double(copy.maxNs) / 1_000_000,
                           capped: copy.capped, windowMs: Double(end > startNs ? end - startNs : 0) / 1_000_000)
    }

    private mutating func add(_ d: UInt64) {
        busyNs += d
        if d > 50_000_000 { blocks50 += 1 }
        maxNs = max(maxNs, d)
    }
}

struct BusySummary: Equatable {
    let ms: Double
    let blocks50: Int
    let maxMs: Double
    let capped: Bool
    let windowMs: Double
}

/// 只在主线程用：beginEpisode 挂上、uiConnectedAt 摘掉；超过 cap 自己摘（窗口一直连不上时不长挂）。
/// 不复用 PerfHarness.MainBlockMonitor：那套只编进 DEBUG||PERF_BENCH 的 iOS 包、装上不摘，
/// 单槽 splitSink 还被 AirPerfProbe 占着，日常包里要的是「只在这个窗口里开」。
final class ConnectBusyWindow {
    static let capNs: UInt64 = 60_000_000_000
    private var acc: BusyAccumulator
    private var observers: [CFRunLoopObserver] = []
    private var frozen: BusySummary?

    init(startNs: UInt64 = ConnectClock.nowNs()) {
        acc = BusyAccumulator(startNs: startNs)
        let open = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
            guard let self else { return }
            let now = ConnectClock.nowNs()
            self.acc.open(at: now)
            self.freezeIfCapped(at: now)
        }
        let close = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
            guard let self else { return }
            let now = ConnectClock.nowNs()
            self.acc.close(at: now)
            self.freezeIfCapped(at: now)
        }
        observers = [open, close].compactMap { $0 }
        for o in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
    }

    /// 窗口结束（主线程）：收进行中的段、摘观察者
    func finish(at ns: UInt64) -> BusySummary {
        if let frozen { return frozen }
        let s = acc.summary(at: ns)
        frozen = s
        remove()
        return s
    }

    /// 过了 deadline：冻结汇总、摘观察者（物理摘除只能等主线程跑到观察者回调这一刻）
    private func freezeIfCapped(at ns: UInt64) {
        guard acc.capped, frozen == nil else { return }
        frozen = acc.summary(at: ns)
        remove()
    }

    private func remove() {
        for o in observers { CFRunLoopObserverInvalidate(o) }
        observers.removeAll()
    }

    deinit { remove() }
}

// MARK: - 一段连接的尺子数据（主线程读写）

struct ConnectRulerEpisode {
    /// 冷启动那段才有的东西
    struct LaunchInfo {
        var segs: [String: Int]?
        var preMainMs: Double?
        var source: String
        var recovery: [String] = []
    }

    var id = 0                 // 进程内第几段（= started 计数）
    let entryNs: UInt64
    var firstRequestNs: UInt64?
    var firstRequestWall: Date?
    /// 这一段里最后一次 WS resume：attempt = 进程内 WS 尝试序号，gen = 当时的 probeGeneration
    /// via = 最终发起这次 WS 的探测候选 id，单候选直连为 "direct"
    struct WSStamp: Equatable { let attempt: Int; let gen: Int; let via: String; let resumeNs: UInt64 }
    var ws: WSStamp?
    var wsOpenNs: UInt64?
    var wsOpenWall: Date?
    var uiNs: UInt64?          // 主线程进入（didOpen 排到主线程的 block 首行）
    var uiWall: Date?
    var clientInfoNs: UInt64?  // 计划定义的终点：client_info 交给当前 task 发出
    /// didOpen 归属对不上（不是这一段最后那次 WS 尝试 / 代次已变 / task 不是它）的次数；对不上的时间戳一律不记
    var invalid = 0
    var candidates: [ConnectCandidateRecord] = []
    var busy: BusySummary?
    var busyWindow: ConnectBusyWindow?
    var launchFail = false

    /// 候选只留最近 maxCandidates 条（最终赢家一定在最后几轮），更早的丢掉计 droppedCandidates
    static let maxCandidates = 32
    var droppedCandidates = 0

    init(entryNs: UInt64, busyWindow: ConnectBusyWindow? = nil) {
        self.entryNs = entryNs
        self.busyWindow = busyWindow
    }

    /// 连接入口（主线程）：同一个时刻既是 entryNs 也是忙段窗口起点
    static func start() -> ConnectRulerEpisode {
        let ns = ConnectClock.nowNs()
        var ep = ConnectRulerEpisode(entryNs: ns, busyWindow: ConnectBusyWindow(startNs: ns))
        ep.id = ConnectRunCounters.bump(\.started)
        return ep
    }

    mutating func noteRequest(at ns: UInt64, wall: Date) {
        guard firstRequestNs == nil else { return }
        firstRequestNs = ns
        firstRequestWall = wall
    }

    mutating func noteWSResume(attempt: Int, gen: Int, via: String, at ns: UInt64, wall: Date) {
        noteRequest(at: ns, wall: wall)
        ws = WSStamp(attempt: attempt, gen: gen, via: via, resumeNs: ns)
    }

    mutating func noteCandidate(_ c: ConnectCandidateRecord) {
        candidates.append(c)
        if candidates.count > Self.maxCandidates {
            candidates.removeFirst()
            droppedCandidates += 1
        }
    }

    /// didOpen 过了生产的 task === 守卫后调。归属三条都对上才记（task 是最后那次尝试的 task、尝试属于这一段、
    /// 代次没变）；否则只计 invalid——旧 task 的 didOpen 在新一段探测期间也能过 ===（sol R1-4）。连接窗口的忙段到这里收。
    @discardableResult
    mutating func noteOpen(task: ObjectIdentifier, lastTask: ObjectIdentifier?, attempt: Int?, currentGen: Int,
                           wsOpenNs: UInt64, wsOpenWall: Date, uiNs: UInt64, uiWall: Date) -> Bool {
        guard let ws, task == lastTask, attempt == ws.attempt, ws.gen == currentGen, self.uiNs == nil else {
            invalid += 1
            return false
        }
        self.wsOpenNs = wsOpenNs
        self.wsOpenWall = wsOpenWall
        self.uiNs = uiNs
        self.uiWall = uiWall
        if let w = busyWindow { busy = w.finish(at: uiNs) }
        busyWindow = nil
        return true
    }

    /// client_info 交给当前 task 之后调；只认已归属成功的那次打开
    mutating func noteClientInfo(at ns: UInt64) {
        guard uiNs != nil, clientInfoNs == nil else { return }
        clientInfoNs = ns
    }

    /// 报告前把委托队列上晚到的 metrics 填进候选
    mutating func resolveMetrics() {
        for i in candidates.indices where candidates[i].taskMs == nil {
            candidates[i].taskMs = candidates[i].timings?.taskMs(slot: candidates[i].slot)
        }
    }

    /// connect_report 新字段（旧字段由调用方照旧组）。segs / preMainMs 只有冷启动那段给。
    /// finishNs = finishEpisode 开始组报告那一刻（旧 open_at 同一刻），不是报告组好
    func fields(finishNs: UInt64, deviceId: String, launch: LaunchInfo?,
                counts: ConnectRunCounters.Snapshot = ConnectRunCounters.snapshot()) -> [String: Any] {
        let rel: (UInt64?) -> Int? = { ns in ns.map { Int(ConnectClock.ms(from: entryNs, to: $0).rounded()) } }
        let wall: (Date?) -> Int? = { d in d.map { Int($0.timeIntervalSince1970 * 1000) } }
        var o: [String: Any] = [
            "rev": ConnectRuler.revision,
            "build": ConnectRuler.build,
            "run": ConnectRuler.runId,
            "dev": deviceId,
            "sw": ConnectRuler.switches(),
            "ep": id,
            "counts": ["started": counts.started, "ok": counts.ok, "replaced": counts.replaced, "report_failed": counts.reportFailed],
            "finish_ms": rel(finishNs) ?? 0,
            "candidates": candidates.map { $0.json(entryNs: entryNs) },
        ]
        if let v = rel(firstRequestNs) { o["first_req_ms"] = v }
        if let ws {
            o["ws_resume_ms"] = Int(ConnectClock.ms(from: entryNs, to: ws.resumeNs).rounded())
            o["ws_attempt"] = ws.attempt
            o["ws_gen"] = ws.gen
            o["ws_via"] = ws.via
        }
        if let v = rel(wsOpenNs) { o["ws_open_ms"] = v }
        if let v = rel(uiNs) { o["ui_ms"] = v }
        if let v = rel(clientInfoNs) { o["client_info_ms"] = v }
        if invalid > 0 { o["ws_invalid"] = invalid }
        if droppedCandidates > 0 { o["cand_dropped"] = droppedCandidates }
        if let v = wall(firstRequestWall) { o["first_request_at"] = v }
        if let v = wall(wsOpenWall) { o["ws_open_at"] = v }
        if let v = wall(uiWall) { o["ui_connected_at"] = v }
        if let busy {
            o["busy_ms"] = Int(busy.ms.rounded())
            o["busy_n50"] = busy.blocks50
            o["busy_max_ms"] = Int(busy.maxMs.rounded())
            o["busy_window_ms"] = Int(busy.windowMs.rounded())
            if busy.capped { o["busy_capped"] = true }
        }
        if let bin = ConnectRuler.binaryUUID { o["bin"] = bin }
        if let launch {
            o["launch_src"] = launch.source
            o["recovery"] = launch.recovery
            if let segs = launch.segs { o["segs"] = segs }
            if let pre = launch.preMainMs { o["pre_main_ms"] = Int(pre.rounded()) }
        }
        if launchFail { o["launch_fail"] = true }
        return o
    }
}
