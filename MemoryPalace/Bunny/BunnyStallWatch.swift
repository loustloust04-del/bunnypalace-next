import Foundation
import Darwin

// MARK: - [Bunny] 卡死黑匣子（Release 也开）
//
// 用户反馈（11-12）：集成版在任何页面都可能整个卡死，只能划掉重开；系统「分析数据」里没有报告。
// 上游的卡顿探针只在 macOS（HangProbe）或 Debug / PERF_BENCH（AirStallSentinel）里有，Release 的 iOS 包没有记录。
// 这里做一个最小的黑匣子：后台每秒敲一下主线程，连续 4 秒没回应就把「主线程当时停在哪」的调用栈记下来，
// 存到 Application Support/Bunny/stalls.jsonl。下次打开后在 Console 设置里可以复制出来。
// 只记函数名与偏移，不记任何聊天内容。App 被系统挂起时计时器不走，不会误报。
//
// 取栈做法：挂起主线程 → 读寄存器 → 沿帧指针用 vm_read_overwrite 读（读失败只是停，不会崩）→ 立刻恢复；
// 挂起期间不分配内存，符号解析放在恢复之后。

enum BunnyStallWatch {
    private static let queue = DispatchQueue(label: "bunny.stallwatch", qos: .utility)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var mainThread: thread_t = 0
    // 以下只在 queue 上读写
    nonisolated(unsafe) private static var pendingTicks = 0
    nonisolated(unsafe) private static var waiting = false
    nonisolated(unsafe) private static var reported = false

    static let thresholdSeconds = 4

    static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Bunny", isDirectory: true).appendingPathComponent("stalls.jsonl")
    }

    /// 在主线程调用一次（App 启动时）
    static func start() {
        guard timer == nil, Thread.isMainThread else { return }
        mainThread = mach_thread_self()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 8, repeating: 1.0)
        t.setEventHandler { tick() }
        t.resume()
        timer = t
    }

    private static func tick() {
        if !waiting {
            waiting = true
            pendingTicks = 0
            DispatchQueue.main.async {
                queue.async {
                    if reported { append(["event": "recovered", "afterSeconds": pendingTicks]) }
                    waiting = false
                    reported = false
                }
            }
            return
        }
        pendingTicks += 1
        if pendingTicks == thresholdSeconds, !reported {
            reported = true
            let frames = captureMainThread()
            append(["event": "stall", "seconds": thresholdSeconds, "frames": symbolize(frames)])
        }
    }

    // MARK: 取主线程调用栈

    private static func captureMainThread() -> [UInt] {
        var frames = [UInt]()
        #if arch(arm64)
        frames.reserveCapacity(80)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return frames }
        defer { thread_resume(mainThread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return frames }
        let mask: UInt = 0x0000_000F_FFFF_FFFF      // 去掉指针认证位
        frames.append(UInt(state.__pc) & mask)
        frames.append(UInt(state.__lr) & mask)
        var fp = UInt(state.__fp)
        var pair: (UInt, UInt) = (0, 0)
        for _ in 0..<70 {
            guard fp != 0, fp & 0x7 == 0 else { break }
            var got: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &pair) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16,
                                  vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer($0))), &got)
            }
            guard ok == KERN_SUCCESS, got == 16 else { break }
            let ret = pair.1 & mask
            guard ret != 0 else { break }
            frames.append(ret)
            guard pair.0 > fp else { break }          // 栈往高地址回溯，防环
            fp = pair.0
        }
        #endif
        return frames
    }

    private static func symbolize(_ frames: [UInt]) -> [String] {
        frames.map { addr in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0 else { return String(format: "0x%lx", addr) }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let imageOff = info.dli_fbase.map { addr - UInt(bitPattern: $0) } ?? 0
            if let s = info.dli_sname, let sa = info.dli_saddr {
                return "\(image) \(String(cString: s)) +\(addr - UInt(bitPattern: sa)) [0x\(String(imageOff, radix: 16))]"
            }
            return "\(image) [0x\(String(imageOff, radix: 16))]"
        }
    }

    // MARK: 落盘 / 读取

    private static func append(_ fields: [String: Any]) {
        var obj = fields
        obj["ts"] = ISO8601DateFormatter().string(from: Date())
        obj["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let url = logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 300_000 { try? fm.removeItem(at: url) }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data + Data([0x0A]))
        } else {
            try? (data + Data([0x0A])).write(to: url)
        }
    }

    /// 最近 n 条记录的原文（给设置页复制用）
    static func recent(_ n: Int = 6) -> (count: Int, text: String) {
        guard let s = try? String(contentsOf: logURL, encoding: .utf8) else { return (0, "") }
        let lines = s.split(separator: "\n").map(String.init)
        let stalls = lines.filter { $0.contains("\"stall\"") }.count
        return (stalls, lines.suffix(n).joined(separator: "\n"))
    }

    static func clear() { try? FileManager.default.removeItem(at: logURL) }
}
