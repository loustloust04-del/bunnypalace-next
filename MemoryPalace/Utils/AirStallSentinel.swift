#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import QuartzCore
import SwiftStreamingMarkdown
import UIKit

/// 常开卡顿哨兵（docs/plan-032-stall-sentinel.md）：自挂一对 runloop 观察者量「主 runloop 长忙段」，
/// 复用 AirProbeSections 区段标记给长忙段挂候选区段。只读时钟、静态区段名、ProcessInfo 与本进程标志，
/// 不读任何模型 / UI 状态。状态只在主线程碰；编码落盘交 AirProbeWriter 的后台队列。
enum AirStallSentinel {
    /// 进程内读一次：env MP_STALL_SENTINEL=1/0 优先；PERF_BENCH 默认关。
    /// Debug：mask A/A 过关前默认关（`stallSentinelOn` 打开；plan §2、sol R2 #1），过关后改成默认开
    static let enabled: Bool = {
        switch PerfHarness.env["MP_STALL_SENTINEL"] {
        case "1": return true
        case "0": return false
        default:
            #if DEBUG
            return UserDefaults.standard.bool(forKey: "stallSentinelOn")
            #else
            return false
            #endif
        }
    }()

    private struct Section { let name: String; let ms: Double; let depth: Int; let clipped: Bool }
    /// 次数与前台时长同源：次数率只从 exposure 行算，block 行只当详情（plan §1.3）
    /// selfMs = 收段主体耗时（不含分钟冲盘）；lowPowerSeen / thermalMax 跟系统状态通知，段内任一时刻开过 / 到过即记
    private struct Exposure {
        let start: Double
        var busy = 0.0, maxMs = 0.0, selfMs = 0.0
        var passes = 0, over50 = 0, over100 = 0, over250 = 0, over1000 = 0
        var debugger = false, lowPowerSeen: Bool, thermalMax: Int

        init(start: Double) {
            self.start = start
            lowPowerSeen = ProcessInfo.processInfo.isLowPowerModeEnabled
            thermalMax = ProcessInfo.processInfo.thermalState.rawValue
        }
    }

    nonisolated(unsafe) private static var writer: AirProbeWriter?
    /// nil = 没有有效开段（启动首段、后台、刚作废）：收段时直接忽略
    nonisolated(unsafe) private static var passStart: Double?
    nonisolated(unsafe) private static var sections: [Section] = []
    nonisolated(unsafe) private static var droppedSections = 0
    nonisolated(unsafe) private static var exposure: Exposure?

    static func start() {
        guard enabled, writer == nil else { return }
        let writer = AirProbeWriter(directory: "perf-sentinel", prefix: "sentinel",
                                    retention: .init(maxAge: 14 * 86_400, maxBytes: 20 * 1024 * 1024))
        self.writer = writer
        writer.environment(thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                           extra: ["kind": "sentinel", "sentinelSchema": 1, "debuggerAtLaunch": debuggerAttached()])
        writer.append(["type": "launch", "at": CACurrentMediaTime()])
        if MarkdownPerfProbe.section == nil {
            MarkdownPerfProbe.section = { name, body in
                let span = AirProbeSections.enter(name)
                body()
                AirProbeSections.leave(span)
            }
        }
        let open = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            guard exposure != nil else { return }
            passStart = CACurrentMediaTime()
            sections.removeAll(keepingCapacity: true)
            droppedSections = 0
        }
        let close = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            closePass()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), open, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), close, .commonModes)
        let center = NotificationCenter.default
        // 失活 / 进后台立刻作废进行中的段并收曝光：控制中心、系统弹窗期间不计，跨挂起的段永远不收（plan §1.2、sol R2 #2）
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            passStart = nil
            flush(reason: "inactive", now: CACurrentMediaTime(), restart: false)
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            passStart = nil
            flush(reason: "background", now: CACurrentMediaTime(), restart: false)
        }
        center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            if ProcessInfo.processInfo.isLowPowerModeEnabled { exposure?.lowPowerSeen = true }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            if let current = exposure?.thermalMax, thermal > current { exposure?.thermalMax = thermal }
        }
        // 曝光段从 didBecomeActive 起算：启动工作（冷启动另有 launch 线）和后台冷启动都不计
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            passStart = nil
            if exposure == nil { exposure = Exposure(start: CACurrentMediaTime()) }
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            flush(reason: "terminate", now: CACurrentMediaTime(), restart: false)
        }
    }

    /// AirProbeRuntime.pop 解锁后调（主线程）：只留本段 ≥8ms 的已关区段，最多 8 条；inclusive 时长，父子不可相加
    static func closedSection(_ name: String, start: Double, end: Double, depth: Int) {
        guard let passStart else { return }
        let ms = (end - max(start, passStart)) * 1000
        guard ms >= 8 else { return }
        let section = Section(name: name, ms: ms, depth: depth, clipped: start < passStart)
        if sections.count < 8 {
            sections.append(section)
            return
        }
        droppedSections += 1
        if let i = sections.indices.min(by: { sections[$0].ms < sections[$1].ms }), sections[i].ms < ms { sections[i] = section }
    }

    /// 给 #031 翻页不变量等记录用的同一通道：同文件、同身份头；字段只收字符串 / 布尔 / 有限数字，
    /// 不合格整条丢弃（一条编码失败会让 writer 永久停写，sol R2 #7）
    static func append(type: String, fields: [String: Any]) {
        guard let writer else { return }
        for value in fields.values {
            switch value {
            case is String, is Bool: continue
            case let number as Double where number.isFinite: continue
            case is Int: continue
            default: return
            }
        }
        var record = fields
        record["type"] = type
        writer.append(record)
    }

    private static func closePass() {
        guard let start = passStart, var e = exposure else { return }
        passStart = nil
        let now = CACurrentMediaTime()
        let ms = (now - start) * 1000
        e.busy += now - start
        e.passes += 1
        e.maxMs = max(e.maxMs, ms)
        if ms > 50 { e.over50 += 1 }
        if ms > 100 { e.over100 += 1 }
        if ms > 250 { e.over250 += 1 }
        if ms > 1000 { e.over1000 += 1 }
        if ms >= 100 {
            let info = ProcessInfo.processInfo
            let debugger = debuggerAttached()
            let lowPower = info.isLowPowerModeEnabled
            let thermal = info.thermalState.rawValue
            e.debugger = e.debugger || debugger
            writer?.append([
                "type": "block", "start": start, "durationMs": ms,
                "sections": sections.sorted { $0.ms > $1.ms }.map {
                    ["name": $0.name, "ms": $0.ms, "depth": $0.depth, "clipped": $0.clipped] as [String: Any]
                },
                "droppedSections": droppedSections, "thermalState": thermal, "lowPowerMode": lowPower, "debugger": debugger
            ])
        }
        e.selfMs += (CACurrentMediaTime() - now) * 1000
        exposure = e
        if now - e.start >= 60 { flush(reason: "minute", now: now, restart: true) }
    }

    private static func flush(reason: String, now: Double, restart: Bool) {
        guard let e = exposure else { return }
        writer?.append([
            "type": "exposure", "endReason": reason, "start": e.start, "end": now, "fgMs": (now - e.start) * 1000,
            "busyMs": e.busy * 1000, "passes": e.passes, "maxMs": e.maxMs, "selfMs": e.selfMs,
            "over50": e.over50, "over100": e.over100, "over250": e.over250, "over1000": e.over1000,
            "lowPowerMode": e.lowPowerSeen, "thermalMax": e.thermalMax,
            "debugger": e.debugger || debuggerAttached()
        ])
        exposure = restart ? Exposure(start: now) : nil
    }

    private static func debuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}
#endif
