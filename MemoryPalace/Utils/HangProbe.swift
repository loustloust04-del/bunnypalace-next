#if os(macOS)
import AppKit
import Darwin

/// 长期卡顿探针（plan-mac-hang-probe §1，09-25 她「动不动就转菊花」）。
/// - 主线程心跳：后台每 100ms 投一个 tick，超过 250ms 没回 = 一次卡顿，记一行
/// - 卡超过 500ms，或进程 CPU 连续 10s > 80%，自动 sample；5 分钟最多一份，留最近 20 份
/// - 落盘 `~/Library/Application Support/MemoryPalace/perf/`：`hangs.log` + `sample-*.txt`；不联网
/// - 后台也记心跳往返时长；active=0 时包含 App Nap / 调度延迟，不等同系统 hang
final class HangProbe: @unchecked Sendable {
    static let shared = HangProbe()
    static let stanchEnabled = UserDefaults.standard.object(forKey: "mp.stanch.H1") as? Bool ?? true
    private static let testProcess = ProcessInfo.processInfo.environment["MP_TEST_HOST"] == "1"
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    private static var isTestHost: Bool { TestHostIsolation.active || testProcess }
    private static let identity: String = {
        let origin = Bundle.main.bundleURL.pathComponents.first { $0.hasPrefix("MemoryPalace-") } ?? "installed"
        return "pid=\(getpid()) bin=\(ConnectRuler.binaryUUID ?? "unknown") build=\(ConnectRuler.build) origin=\(origin)"
    }()

    static var directory: URL {
        AppPaths.checked(AppPaths.applicationSupport
            .appendingPathComponent("MemoryPalace/perf", isDirectory: true))
    }
    static var logURL: URL { AppPaths.checked(directory.appendingPathComponent("hangs.log")) }

    /// 卡顿时记「当时在哪」：主线程回 tick 时顺手取（卡着的时候主线程取不到）
    @MainActor static var context: () -> String = { "" }
    @MainActor static var terminalOutputBytes: UInt64 = 0
    @MainActor private static var previousTerminalBytes: UInt64 = 0
    @MainActor private static var previousTerminalTime: UInt64?

    @MainActor static func terminalBytesPerSecond() -> UInt64 {
        let now = ConnectClock.nowNs()
        let previous = previousTerminalTime
        let bytes = terminalOutputBytes &- previousTerminalBytes
        defer { previousTerminalTime = now; previousTerminalBytes = terminalOutputBytes }
        guard let previous, now > previous else { return 0 }
        return UInt64(Double(bytes) * 1_000_000_000 / Double(now - previous))
    }

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
    private let logDirectory: URL
    private let stanch: Bool
    #if PERF_BENCH
    private var forceBenchSample = false

    static func canForceBenchSample(request: String?, role: String?, active: Bool, testHost: Bool) -> Bool {
        request == "1" && role == "seed" && active && !testHost
    }

    private struct BenchSelfSampleResult: Encodable {
        let `protocol` = "macSelfSampleV1"
        let targetPID: Int32
        let samplerPID: Int32?
        let status: Int32?
        let termination: String
        let file: String
        let bytes: UInt64?
        let error: String?
    }
    #endif

    init(directory: URL = HangProbe.directory, stanchEnabled: Bool = HangProbe.stanchEnabled) {
        logDirectory = directory
        stanch = stanchEnabled
    }

    var isRunning: Bool { queue.sync { timer != nil } }

    private func clock() -> CFAbsoluteTime {
        stanch ? Double(ConnectClock.nowNs()) / 1_000_000_000 : CFAbsoluteTimeGetCurrent()
    }

    func start() {
        guard !Self.isTestHost else { return }
        queue.async { [self] in
            guard timer == nil else { return }
            try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: .milliseconds(100), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            append("start pid=\(getpid())")
            #if PERF_BENCH
            if Self.canForceBenchSample(request: ProcessInfo.processInfo.environment["MP_PERF_FORCE_SAMPLE"],
                                        role: BenchIsolation.configuration?.role,
                                        active: BenchIsolation.active, testHost: Self.isTestHost) {
                forceBenchSample = true
                takeSample(reason: "bench forced self sample", now: clock())
            }
            #endif
        }
    }

    func tick() {
        let now = clock()
        checkCPU(now)
        if let since = pendingSince {
            let stall = now - since
            if stall >= (stanch ? 0.5 : Self.sampleHangThreshold), !sampledThisHang {
                sampledThisHang = true
                takeSample(reason: String(format: "hang %.1fs%@", stall, stanch ? " lowerBound=1" : ""), now: now)
            }
            return
        }
        pendingSince = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let finishedAt = stanch ? clock() : nil
            let active = NSApp?.isActive ?? false
            let ctx = (active || stanch) ? HangProbe.context() : ""
            queue.async { self.ack(finishedAt: finishedAt, active: active, context: ctx) }
        }
    }

    private func ack(finishedAt: CFAbsoluteTime?, active: Bool, context: String) {
        guard let since = pendingSince else { return }
        let stall = (finishedAt ?? clock()) - since
        pendingSince = nil
        sampledThisHang = false
        recordHang(duration: stall, active: active, context: context)
    }

    func recordHang(duration: CFAbsoluteTime, active: Bool, context: String) {
        guard (stanch || active), duration >= Self.hangThreshold else { return }
        let state = stanch ? " active=\(active ? 1 : 0)" : ""
        append(String(format: "hang %.2fs cpu=%.0f%%%@ %@", duration, cpuNow * 100, state, context))
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
        let file = AppPaths.checked(logDirectory.appendingPathComponent("sample-\(stamp).txt"))
        append("\(reason) → \(file.lastPathComponent)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "3", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        #if PERF_BENCH
        let forced = forceBenchSample
        forceBenchSample = false
        #endif
        process.terminationHandler = { [weak self] completed in
            self?.queue.async {
                #if PERF_BENCH
                if forced {
                    self?.recordBenchSample(file: file, pid: completed.processIdentifier,
                        status: completed.terminationStatus,
                        termination: completed.terminationReason == .exit ? "exit" : "signal", error: nil)
                }
                #endif
                self?.pruneSamples()
            }
        }
        do { try process.run() } catch {
            append("sample failed: \(error.localizedDescription)")
            #if PERF_BENCH
            if forced { recordBenchSample(file: file, pid: nil, status: nil, termination: "launchError", error: error.localizedDescription) }
            #endif
        }
    }

    #if PERF_BENCH
    private func recordBenchSample(file: URL, pid: Int32?, status: Int32?, termination: String, error: String?) {
        guard let isolation = BenchIsolation.configuration, isolation.role == "seed" else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber
        let result = BenchSelfSampleResult(targetPID: getpid(), samplerPID: pid, status: status,
            termination: termination, file: file.path, bytes: size?.uint64Value,
            error: error ?? (size == nil ? "sample file missing" : nil))
        do {
            let path = try isolation.check(isolation.root.appendingPathComponent("perf/forced-self-sample.json"))
            try isolation.writeAtomically(JSONEncoder().encode(result), to: path)
        } catch {
            FileHandle.standardError.write(Data("[perfbench] self-sample result write failed: \(error)\n".utf8))
            exit(78)
        }
    }
    #endif

    private func pruneSamples() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else { return }
        let samples = files.filter { $0.lastPathComponent.hasPrefix("sample-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in samples.dropFirst(Self.keepSamples) { try? fm.removeItem(at: old) }
    }

    /// 一行一条；超过 2MB 滚一次（留一份 .old）
    private func append(_ line: String) {
        let metadata = stanch ? "\(Self.identity) " : ""
        let text = "\(Self.lineStamp.string(from: Date())) \(metadata)\(line)\n"
        let url = AppPaths.checked(logDirectory.appendingPathComponent("hangs.log"))
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 2_000_000 {
            let old = AppPaths.checked(url.deletingPathExtension().appendingPathExtension("old.log"))
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
        guard !Self.isTestHost else { return }
        queue.async { [self] in append(line) }
    }

    enum ObservationKind: String, Sendable {
        case heartbeat, triggerLowerBound, cpuWindow

        var title: String {
            switch self {
            case .heartbeat: return "心跳响应"
            case .triggerLowerBound: return "采样触发下界"
            case .cpuWindow: return "CPU检测窗口"
            }
        }
    }

    struct SummaryGroup: Identifiable, Sendable {
        let id: String
        let date: String
        let package: String
        let context: String
        let kind: ObservationKind
        var count = 0
        var maximumSeconds: Double = 0

        mutating func include(_ seconds: Double) {
            count += 1
            maximumSeconds = max(maximumSeconds, seconds)
        }
    }

    struct Summary: Sendable {
        let groups: [SummaryGroup]
        let error: String?
    }

    static func summarize(_ lines: [String]) -> [SummaryGroup] {
        var groups: [String: SummaryGroup] = [:]
        for line in lines {
            let tokens = line.split(separator: " ")
            guard tokens.count > 3, tokens[0].count == 10, tokens[1].count == 8 else { continue }
            let event = tokens[2].hasPrefix("pid=") ? 6 : 2
            guard tokens.indices.contains(event), tokens[event] == "hang" || tokens[event] == "busy",
                  let durationToken = tokens[(event + 1)...].first(where: { $0.hasSuffix("s") }),
                  let seconds = Double(durationToken.dropLast()), seconds.isFinite, seconds >= 0 else { continue }
            let fields = Dictionary(tokens.compactMap { token -> (String, String)? in
                let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { _, last in last })
            let kind: ObservationKind = tokens[event] == "busy" ? .cpuWindow
                : (fields["lowerBound"] == "1" || tokens.contains("→") || line.contains("(cooldown, no sample)"))
                    ? .triggerLowerBound : .heartbeat
            let package = fields["bin"].flatMap { $0 == "unknown" ? nil : $0 }
                .map { "bin=\($0) build=\(fields["build"] ?? "?") origin=\(fields["origin"] ?? "?")" } ?? "身份未知"
            let context = ["active", "code", "detailLoaded", "tool", "toolIds"].map {
                "\($0)=\(fields[$0] ?? "?")"
            }.joined(separator: " ")
            let date = String(tokens[0])
            let key = [date, package, context, kind.rawValue].joined(separator: "|")
            groups[key, default: SummaryGroup(id: key, date: date, package: package,
                context: context, kind: kind)].include(seconds)
        }
        return groups.values.sorted {
            $0.date != $1.date ? $0.date > $1.date
                : $0.maximumSeconds != $1.maximumSeconds ? $0.maximumSeconds > $1.maximumSeconds : $0.id < $1.id
        }
    }

    func recentSummary() async -> Summary {
        return await Task.detached(priority: .utility) {
            do {
                let url = AppPaths.checked(self.logDirectory.appendingPathComponent("hangs.log"))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                let start = end > 131_072 ? end - 131_072 : 0
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: Int(end - start)) ?? Data()
                var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                if start > 0 { lines.removeFirst() }
                if !lines.isEmpty { lines.removeLast() } // 只收完整换行的记录，不把写到一半的尾行当观测。
                return Summary(groups: Self.summarize(lines.suffix(50).map(String.init)), error: nil)
            } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
                return Summary(groups: [], error: nil)
            } catch {
                return Summary(groups: [], error: error.localizedDescription)
            }
        }.value
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
