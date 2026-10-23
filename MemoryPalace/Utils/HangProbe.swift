#if os(macOS)
import AppKit
import Darwin

/// 长期卡顿探针（plan-mac-hang-probe §1，09-25 她「动不动就转菊花」）。
/// - 主线程心跳：后台每 100ms 投一个 tick，超过 250ms 没回 = 一次卡顿，记一行
/// - 卡超过 1s，或进程 CPU 连续 10s > 80%（没卡死但一直忙），自动 `/usr/bin/sample` 全线程调用栈落盘；5 分钟最多一份，留最近 20 份
/// - 落盘 `~/Library/Application Support/MemoryPalace/perf/`：`hangs.log` + `sample-*.txt`；不联网
/// - 窗口不在前台时 App Nap 会让 tick 晚到，那段不算卡顿（只看 CPU）
final class HangProbe: @unchecked Sendable {
    static let shared = HangProbe()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/perf", isDirectory: true)
    }
    static var logURL: URL { directory.appendingPathComponent("hangs.log") }

    /// 卡顿时记「当时在哪」：主线程回 tick 时顺手取（卡着的时候主线程取不到）
    @MainActor static var context: () -> String = { "" }

    static let hangThreshold: CFAbsoluteTime = 0.25
    static let sampleHangThreshold: CFAbsoluteTime = 1.0
    static let busyCPU: Double = 0.8
    static let busyDuration: CFAbsoluteTime = 10
    static let sampleCooldown: CFAbsoluteTime = 300
    static let keepSamples = 20

    private let queue = DispatchQueue(label: "mp.hang-probe", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pendingSince: CFAbsoluteTime?
    private var sampledThisHang = false
    private var busySince: CFAbsoluteTime?
    private var lastSampleAt: CFAbsoluteTime = -.infinity
    private var lastCPU: (wall: CFAbsoluteTime, cpu: Double)?
    private var lastCPUCheck: CFAbsoluteTime = 0
    private var cpuNow: Double = 0

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: .milliseconds(100), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            append("start pid=\(getpid())")
        }
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        checkCPU(now)
        if let since = pendingSince {
            let stall = now - since
            if stall >= Self.sampleHangThreshold, !sampledThisHang {
                sampledThisHang = true
                takeSample(reason: String(format: "hang %.1fs", stall), now: now)
            }
            return
        }
        pendingSince = now
        DispatchQueue.main.async { [weak self] in
            let active = NSApp?.isActive ?? false
            let ctx = active ? HangProbe.context() : ""
            self?.queue.async { self?.ack(active: active, context: ctx) }
        }
    }

    private func ack(active: Bool, context: String) {
        guard let since = pendingSince else { return }
        let stall = CFAbsoluteTimeGetCurrent() - since
        pendingSince = nil
        sampledThisHang = false
        guard active, stall >= Self.hangThreshold else { return }
        append(String(format: "hang %.2fs cpu=%.0f%% %@", stall, cpuNow * 100, context))
    }

    /// 进程 CPU（用户 + 系统时间 / 墙钟），每秒算一次
    private func checkCPU(_ now: CFAbsoluteTime) {
        guard now - lastCPUCheck >= 1 else { return }
        lastCPUCheck = now
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        defer { lastCPU = (now, cpu) }
        guard let last = lastCPU, now > last.wall else { return }
        cpuNow = (cpu - last.cpu) / (now - last.wall)
        if cpuNow > Self.busyCPU {
            let start = busySince ?? now
            busySince = start
            if now - start >= Self.busyDuration {
                busySince = nil
                takeSample(reason: String(format: "busy cpu=%.0f%% %.0fs", cpuNow * 100, now - start), now: now)
            }
        } else {
            busySince = nil
        }
    }

    private func takeSample(reason: String, now: CFAbsoluteTime) {
        guard now - lastSampleAt >= Self.sampleCooldown else {
            append("\(reason) (cooldown, no sample)")
            return
        }
        lastSampleAt = now
        let stamp = Self.fileStamp.string(from: Date())
        let file = Self.directory.appendingPathComponent("sample-\(stamp).txt")
        append("\(reason) → \(file.lastPathComponent)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "3", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.queue.async { self?.pruneSamples() } }
        do { try process.run() } catch { append("sample failed: \(error.localizedDescription)") }
    }

    private func pruneSamples() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) else { return }
        let samples = files.filter { $0.lastPathComponent.hasPrefix("sample-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in samples.dropFirst(Self.keepSamples) { try? fm.removeItem(at: old) }
    }

    /// 一行一条；超过 2MB 滚一次（留一份 .old）
    private func append(_ line: String) {
        let text = "\(Self.lineStamp.string(from: Date())) \(line)\n"
        let url = Self.logURL
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 2_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// 别的探针顺手记一笔到同一本日志（她和我都能直接读，os_log 事后读不到）
    func note(_ line: String) {
        queue.async { [self] in append(line) }
    }

    /// 设置页用：最近 n 行（新的在上）
    static func recentLines(_ n: Int = 50) -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(n).reversed().map(String.init))
    }

    private static let lineStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
#endif
