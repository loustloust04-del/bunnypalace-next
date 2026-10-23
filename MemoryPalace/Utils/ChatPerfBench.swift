#if DEBUG && os(iOS)
import UIKit

/// [PERF bench] L1（roadmap-lody-adoptions）：深翻连滚基准——8000pt/s × 20s 定速滚聊天列表，
/// 采 main-run-loop 帧间隔 + TASK_VM_INFO 内存，落盘 Documents/perf-bench.json。
/// 口径对齐 lody 的 ChatPerformanceProbe（metric 同款免责：测 run-loop 交付，不是 GPU presented FPS）。
/// 只在 `--perf-bench` 下由 ContentView 启动；反转列表深翻 = offset 正向（越大越老）。
final class ChatPerfBench: NSObject {
    static var shared: ChatPerfBench?

    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private let requested = CACurrentMediaTime()
    private var started: Double = 0
    private var previous: Double = 0
    private var origin: CGFloat = 0
    private var frames: [[String: Double]] = []
    private var memory: [[String: Double]] = []
    private var nextMemory: Double = 0
    private let baseline = ChatPerfBench.footprint()
    /// MP_PERF_SPEED 环境变量可调（默认 8000 对齐 lody 口径；3000≈真人快速 fling 衰减）
    private let speed: Double = Double(ProcessInfo.processInfo.environment["MP_PERF_SPEED"] ?? "") ?? 8000
    private let duration: Double = 20

    static func startWhenReady() {
        // MP_PERF_NO_AUTOSCROLL=1：只要 3000 条数据不要自动滚（手拖类验证不能和它两个写手）
        guard PerfBenchSeed.isActive, shared == nil,
              ProcessInfo.processInfo.environment["MP_PERF_NO_AUTOSCROLL"] != "1" else { return }
        let bench = ChatPerfBench()
        shared = bench
        let l = CADisplayLink(target: bench, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        bench.link = l
        KBProbe.log("[PERFBENCH] armed, waiting for list")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if scrollView == nil { scrollView = StreamScrollAnchor.AnchorView.chatScrollView }
        guard let sv = scrollView else {
            if now - requested > 90 { fail("list never appeared") }
            return
        }
        if started == 0 {
            // 就位判据：cs>30000 才可能是 3000 条基准对话（kb 取证对话 22 条 ≈5600pt，
            // 首跑两轮就是在它身上白滚的——bench 对话树遍历慢于 5s，门槛防错靶）
            guard now - requested >= 5, sv.contentSize.height > 30000 else {
                if now - requested > 120 { fail("content never settled cs=\(Int(sv.contentSize.height))") }
                return
            }
            origin = sv.contentOffset.y
            started = now
            previous = now
            memory.append(["t": 0, "mib": Self.footprint()])
            KBProbe.log(String(format: "[PERFBENCH] start origin=%.0f cs=%.0f", origin, sv.contentSize.height))
            return
        }
        let elapsed = now - started
        let dt = now - previous
        frames.append(["t": elapsed, "dt": dt, "offset": sv.contentOffset.y, "cs": sv.contentSize.height])
        previous = now
        if elapsed >= nextMemory {
            memory.append(["t": elapsed, "mib": Self.footprint()])
            nextMemory = elapsed + 0.25
        }
        if elapsed >= duration {
            finish(elapsed: elapsed, reason: "duration")
            return
        }
        // 反转列表深翻：offset 正向增大 = 翻向更老历史。列表是窗口化加载（cs 随深翻动态扩张，
        // 首测实录 cs=5602/3000 条），所以用**位置递推**而不是 origin+elapsed：滚到已加载区头部时
        // 钳住等加载扩张（等待期的帧照记——加载 hitch 正是要量的），cs 持续 3s 不再长才算真到头。
        let maxOff = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
        let target = min(sv.contentOffset.y + CGFloat(dt * speed), maxOff)
        if target >= maxOff - 0.5 {
            if lastGrowCS < sv.contentSize.height - 1 {
                lastGrowCS = sv.contentSize.height
                lastGrowAt = now
            } else if now - lastGrowAt > 3 {
                finish(elapsed: elapsed, reason: "reached true end")
                return
            }
        }
        sv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    private var lastGrowCS: CGFloat = 0
    private var lastGrowAt: Double = 0

    private func finish(elapsed: Double, reason: String) {
        defer { stop() }
        guard elapsed > 1, frames.count > 10 else { fail("too short (\(reason))"); return }
        let dts = frames.compactMap { $0["dt"] }.sorted()
        func pct(_ p: Double) -> Double { dts[min(dts.count - 1, Int(Double(dts.count) * p))] * 1000 }
        let fps = Double(frames.count) / elapsed
        let peak = memory.compactMap { $0["mib"] }.max() ?? -1
        let hitch33 = dts.filter { $0 > 0.033 }.count
        let hitch100 = dts.filter { $0 > 0.100 }.count
        let report: [String: Any] = [
            "metric": "CADisplayLink main-run-loop FPS; not GPU presented FPS",
            "configuration": "Debug", "device": UIDevice.current.model,
            "systemVersion": UIDevice.current.systemVersion,
            "seedMessages": PerfBenchSeed.total,
            "seconds": elapsed, "pointsPerSecond": speed, "endReason": reason,
            "fps": fps, "dtP50ms": pct(0.5), "dtP95ms": pct(0.95), "dtP99ms": pct(0.99),
            "hitchOver33ms": hitch33, "hitchOver100ms": hitch100,
            "baselineMiB": baseline, "peakMiB": peak, "endMiB": Self.footprint(),
            "memoryMetric": "TASK_VM_INFO phys_footprint; sampled every 250ms",
            "frames": frames, "memory": memory,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("perf-bench.json")
            try data.write(to: url, options: .atomic)
            KBProbe.log(String(format: "[PERFBENCH] done %@ fps=%.1f p95=%.1fms p99=%.1fms hitch33=%d hitch100=%d peak=%.1fMiB",
                               reason, fps, pct(0.95), pct(0.99), hitch33, hitch100, peak))
        } catch {
            KBProbe.log("[PERFBENCH] report write FAILED: \(error)")
        }
    }

    private func fail(_ why: String) {
        KBProbe.log("[PERFBENCH] failed: \(why)")
        stop()
    }

    private func stop() {
        link?.invalidate(); link = nil
        frames.removeAll(); memory.removeAll()
    }

    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
#endif
