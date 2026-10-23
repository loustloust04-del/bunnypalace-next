#if (DEBUG || PERF_BENCH) && os(iOS)
import CryptoKit
import Foundation
import MachO
import SwiftStreamingMarkdown
import UIKit

/// 真手势被动探针。只缓存 UI 已经读到的标量，不持有 / 遍历产品模型，不发布 Observation。
/// 开关进程内只读一次；调用方先判 enabled，关闭时不构造单例、时钟、观察器或文件。
@MainActor
final class AirPerfProbe: NSObject {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "perfProbeOn")
    static let shared = AirPerfProbe()

    private final class Window {
        let kind: String
        let start: Double
        let context: AirProbeContext
        let counts: [String: Int]
        let timed: (counts: [String: Int], milliseconds: [String: Double])
        let from: Int?
        let target: Int?
        var to: Int?
        var pendingEnd: String?
        var lastFrame: Double
        var lastCallback: Double
        var callbackMaxMs = 0.0
        var frameCount = 0
        var frameMaxMs = 0.0
        var framesOver25 = 0
        var busyMs = 0.0
        var blocksOver50 = 0
        var busyMaxMs = 0.0

        init(kind: String, context: AirProbeContext, from: Int? = nil, target: Int? = nil) {
            self.kind = kind; self.context = context; self.from = from; self.target = target
            start = CACurrentMediaTime(); lastFrame = start; lastCallback = start
            counts = PerfCount.snapshot(); timed = PerfCount.timedSnapshot()
        }
        func frame(_ sample: PerfChatCore.FrameSample) {
            callbackMaxMs = max(callbackMaxMs, (sample.arrival - lastCallback) * 1000)
            lastCallback = sample.arrival
            // 第一个 timestamp 可能在松手前；只统计窗口内的交集，不带入之前的停顿。
            guard sample.timestamp > lastFrame else { return }
            let ms = (sample.timestamp - lastFrame) * 1000
            frameMaxMs = max(frameMaxMs, ms)
            if ms > 25 { framesOver25 += 1 }
            frameCount += 1; lastFrame = sample.timestamp
        }
        func busy(_ block: MainBlockMonitor.Block) {
            let ms = max(0, block.end - max(start, block.start)) * 1000
            busyMs += ms; busyMaxMs = max(busyMaxMs, ms)
            if ms > 50 { blocksOver50 += 1 }
        }
    }

    private var context = AirProbeContext()
    private var paging: Window?
    private var scrolling: Window?
    private weak var chatScroll: UIScrollView?
    private var scrollCancelled = false
    private var started = false
    private lazy var writer = AirProbeWriter()
    private lazy var stallMonitor = AirStallMonitor(writer: writer)
    private var foreground = true
    private var lastBatterySample = -Double.infinity
    private lazy var sampler = ChatV1Sampler { [weak self] sample in
        MainActor.assumeIsolated { self?.frame(sample) }
    }

    func start() {
        guard Self.enabled, !started else { return }
        started = true
        writer.environment(thermalState: ProcessInfo.processInfo.thermalState.rawValue)
        AirProbeRuntime.shared.install(writer)
        sampler.start()
        stallMonitor.setForeground(true, at: CACurrentMediaTime())
        MarkdownPerfProbe.call = { call in PerfCount.hit(call.rawValue) }
        MarkdownPerfProbe.section = { name, body in
            let span = AirProbeSections.enter(name)
            body()
            AirProbeSections.leave(span)
        }
        MainBlockMonitor.observeSplit({ [weak self] block in
            AirProbeRuntime.shared.closedBusy(at: block.end)
            MainActor.assumeIsolated { self?.closedBusySegment(block) }
        }, onOpen: { AirProbeRuntime.shared.openedBusy(at: $0) })
        enableBatterySampling()
        NotificationCenter.default.addObserver(self, selector: #selector(background),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // 这些参数全部来自原 body 的既有读集；没有额外的模型属性或查询。
    func noteList(conversationID: String?, count: Int, bubble: Bool) {
        PerfCount.hit("chatListContentBody")
        context.conversationID = conversationID
        context.pathCount = count
        context.displayMode = bubble ? "bubble" : "article"
        context.listObservedAt = CACurrentMediaTime()
        AirProbeRuntime.shared.publish(context)
    }
    func noteCC(_ value: Bool) {
        context.isCC = value
        context.ccObservedAt = CACurrentMediaTime()
        AirProbeRuntime.shared.publish(context)
    }
    func notePage2(_ id: String) {
        PerfCount.hit("page2ShellBody")
        context.page2App = id
        context.page2ObservedAt = CACurrentMediaTime()
        AirProbeRuntime.shared.publish(context)
    }

    func noteToolBody(_ id: String) {
        PerfCount.hit("page2ToolBody")
        PerfCount.hit("page2ToolBody." + id)
    }

    /// 定时入口不隔离到主线程：文件库既有后台调用保持原执行线程。
    nonisolated static func beginTimed(_ key: String) -> Double? {
        guard enabled else { return nil }
        PerfCount.beginTimed(key)
        return CACurrentMediaTime()
    }
    nonisolated static func endTimed(_ key: String, since start: Double?) {
        guard let start else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        PerfCount.endTimed(key, milliseconds: ms)
    }
    nonisolated static func measure<T>(_ key: String, work: () -> T) -> T {
        guard enabled else { return work() }
        let start = beginTimed(key)
        defer { endTimed(key, since: start) }
        return work()
    }

    func beginPaging(from: Int, to: Int) {
        endPaging(to: from, reason: "interrupted")
        paging = Window(kind: "paging", context: context, from: from, target: to)
        sampler.start()
    }
    func endPaging(to: Int, reason: String) {
        guard let window = paging else { return }
        window.to = to
        if reason == "settled" {
            // 把本轮 UIKit / CA 提交计进落定：由 Int.max beforeWaiting 收口。
            window.pendingEnd = reason
        } else {
            finish(window, reason: reason, now: CACurrentMediaTime(), includeOpenBusy: true)
            paging = nil
        }
    }

    /// 挂在现有 StreamScrollAnchor 找到的内层 UIScrollView 上，不替换 SwiftUI delegate。
    func attachChatScroll(_ scroll: UIScrollView) {
        guard chatScroll !== scroll else { return }
        if let window = scrolling {
            finish(window, reason: "scrollViewReplaced", now: CACurrentMediaTime(), includeOpenBusy: true)
            scrolling = nil
        }
        chatScroll?.panGestureRecognizer.removeTarget(self, action: #selector(chatPan(_:)))
        chatScroll = scroll
        scroll.panGestureRecognizer.addTarget(self, action: #selector(chatPan(_:)))
    }
    @objc private func chatPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            if let window = scrolling {
                finish(window, reason: "interrupted", now: CACurrentMediaTime(), includeOpenBusy: true)
            }
            scrolling = Window(kind: "scroll", context: context)
            scrollCancelled = false
            sampler.start()
        case .cancelled, .failed:
            scrollCancelled = true
        default: break
        }
    }
    private func frame(_ sample: PerfChatCore.FrameSample) {
        AirProbeRuntime.shared.frame(sample)
        paging?.frame(sample)
        scrolling?.frame(sample)
        if let window = scrolling {
            if let scroll = chatScroll, scroll.window != nil {
                // pan ended 回调里 isDecelerating 可能尚未置位，下一帧再判断。
                if !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating {
                    window.pendingEnd = scrollCancelled ? "cancelled" : "settled"
                }
            } else {
                window.pendingEnd = "viewDisappeared"
            }
        }
    }
    private func closedBusySegment(_ block: MainBlockMonitor.Block) {
        paging?.busy(block)
        scrolling?.busy(block)
        if let window = paging, let reason = window.pendingEnd {
            finish(window, reason: reason, now: block.end, includeOpenBusy: false)
            paging = nil
        }
        if let window = scrolling, let reason = window.pendingEnd {
            finish(window, reason: reason, now: block.end, includeOpenBusy: false)
            scrolling = nil
        }
    }
    private func enableBatterySampling() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        lastBatterySample = -Double.infinity
        sampleBatteryIfDue(at: CACurrentMediaTime())
    }
    func sampleBatteryIfDue(at now: Double) {
        guard foreground, now - lastBatterySample >= 1 else { return }
        lastBatterySample = now
        let device = UIDevice.current
        AirProbeRuntime.shared.battery(level: device.batteryLevel, state: device.batteryState.rawValue, at: now)
    }
    @objc private func enterForeground() {
        guard !foreground else { return }
        foreground = true
        let now = CACurrentMediaTime()
        AirProbeRuntime.shared.setForeground(true, at: now)
        enableBatterySampling()
        sampler.start()
        stallMonitor.setForeground(true, at: now)
    }
    @objc private func background() {
        let now = CACurrentMediaTime()
        if let window = paging { finish(window, reason: "background", now: now, includeOpenBusy: true) }
        if let window = scrolling { finish(window, reason: "background", now: now, includeOpenBusy: true) }
        paging = nil; scrolling = nil
        foreground = false
        AirProbeRuntime.shared.setForeground(false, at: now)
        stallMonitor.setForeground(false, at: now)
        sampler.stop()
    }
    private func finish(_ window: Window, reason: String, now: Double, includeOpenBusy: Bool) {
        if includeOpenBusy, let block = MainBlockMonitor.currentSplit(now: now) { window.busy(block) }
        let timed = PerfCount.timedSnapshot()
        var counts = PerfCount.diff(from: window.counts, to: PerfCount.snapshot())
        for (key, value) in PerfCount.diff(from: window.timed.counts, to: timed.counts) { counts[key] = value }
        var deltaMs: [String: Double] = [:]
        for (key, value) in timed.milliseconds { deltaMs[key] = value - (window.timed.milliseconds[key] ?? 0) }
        counts["memoryList"] = (counts["memoryListMain"] ?? 0) + (counts["memoryListBackground"] ?? 0)
        deltaMs["memoryList"] = (deltaMs["memoryListMain"] ?? 0) + (deltaMs["memoryListBackground"] ?? 0)
        let record: [String: Any] = [
            "type": "interaction", "kind": window.kind, "endReason": reason,
            "start": window.start, "end": now, "durationMs": (now - window.start) * 1000,
            "fromPage": window.from as Any? ?? NSNull(), "targetPage": window.target as Any? ?? NSNull(),
            "toPage": window.to as Any? ?? NSNull(),
            "direction": window.from.flatMap { from in window.target.map { $0 > from ? "left" : ($0 < from ? "right" : "return") } } ?? "vertical",
            "frameCount": window.frameCount, "frameMaxMs": window.frameMaxMs,
            "framesOver25ms": window.framesOver25,
            // 结束前最后一段没有下一个 display-link 回调；单列，避免把无帧的长卡顿误报成 0。
            "frameTailMs": max(0, now - window.lastFrame) * 1000,
            "callbackMaxMs": window.callbackMaxMs,
            "callbackTailMs": max(0, now - window.lastCallback) * 1000,
            "mainBusyMs": window.busyMs, "mainBlocksOver50ms": window.blocksOver50,
            "mainBusyMaxMs": window.busyMaxMs, "counterDelta": counts, "timingMs": deltaMs,
            "context": window.context.fields, "contextEnd": context.fields,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue
        ]
        writer.append(record)
    }
}

/// 编码、哈希、建目录、轮转和写盘全部在串行后台队列；文件句柄不跨队列。
final class AirProbeWriter: @unchecked Sendable {
    /// 只给常开哨兵：直属、普通、名字带前缀的 .jsonl，超期或超总量从最旧删（plan-032 §1.6）
    struct Retention { let maxAge: TimeInterval; let maxBytes: Int }

    private let queue = DispatchQueue(label: "com.susu.MemoryPalace.air-probe", qos: .utility)
    private let launch = Date()
    private let launchClock = CACurrentMediaTime()
    private let directoryName: String
    private let prefix: String
    private let retention: Retention?
    private var handle: FileHandle?
    private var bytes = 0
    private var part = 0
    private var environmentRecord: [String: Any] = [:]
    private let limit = 5 * 1024 * 1024
    private var disabled = false

    init(directory: String = "perf-probe", prefix: String = "probe", retention: Retention? = nil) {
        directoryName = directory
        self.prefix = prefix
        self.retention = retention
    }

    private var sessionID: String {
        let stamp = ISO8601DateFormatter().string(from: launch).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(Int(launch.timeIntervalSince1970 * 1000) % 1000)"
    }

    func environment(thermalState: Int, extra: [String: Any] = [:]) {
        queue.async { [self] in
            var system = utsname()
            uname(&system)
            let model = withUnsafeBytes(of: &system.machine) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let info = Bundle.main.infoDictionary ?? [:]
            environmentRecord = [
                "type": "environment", "schemaVersion": 2,
                "launchUnixTime": launch.timeIntervalSince1970, "launchMonotonic": launchClock,
                "appVersion": info["CFBundleShortVersionString"] ?? NSNull(),
                "appBuild": info["CFBundleVersion"] ?? NSNull(),
                "gitCommit": info["GitCommit"] ?? info["GIT_COMMIT"] ?? NSNull(),
                "deviceModel": model, "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "thermalState": thermalState,
                "buildConfig": Self.buildConfig,
                "binaryUUID": Self.codeImageUUID() as Any? ?? NSNull(), "sessionID": sessionID, "part": 0,
                "context": Self.redacted([:]), "contextEnd": Self.redacted([:])
            ]
            environmentRecord.merge(extra) { _, new in new }
            if let retention { prune(retention) }
            write(environmentRecord)
        }
    }

    /// 代码所在镜像的 LC_UUID：Xcode 16 Debug 包代码在 `*.debug.dylib`，主二进制 stub 的 UUID 不随代码变，优先取前者
    private static func codeImageUUID() -> String? {
        var index: UInt32 = 0
        for i in 0..<_dyld_image_count() where _dyld_get_image_name(i).map({ String(cString: $0).hasSuffix(".debug.dylib") }) == true {
            index = i
            break
        }
        guard let header = _dyld_get_image_header(index) else { return nil }
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == UInt32(LC_UUID) {
                return UUID(uuid: cmd.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        return nil
    }

    private func prune(_ retention: Retention) {
        let fm = FileManager.default
        guard let directory = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(directoryName, isDirectory: true),
              let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
        else { return }
        var files: [(url: URL, date: Date, size: Int)] = []
        for url in urls where url.lastPathComponent.hasPrefix(prefix + "-") && url.pathExtension == "jsonl"
            && !url.lastPathComponent.hasPrefix("\(prefix)-\(sessionID)") {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let date = values.contentModificationDate, let size = values.fileSize else { continue }
            files.append((url, date, size))
        }
        files.sort { $0.date < $1.date }
        var total = files.reduce(0) { $0 + $1.size }
        let cutoff = Date().addingTimeInterval(-retention.maxAge)
        for file in files where file.date < cutoff || total > retention.maxBytes {
            if (try? fm.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }
    private static var buildConfig: String {
        #if DEBUG
        return "Debug"
        #else
        return "PERF_BENCH"
        #endif
    }
    func append(_ record: [String: Any]) {
        append(makeRecord: { record })
    }
    func append(makeRecord: @escaping () -> [String: Any]) {
        queue.async { [self] in
            var record = makeRecord()
            for key in ["context", "contextEnd", "contextAtDetection"] {
                if let context = record[key] as? [String: Any] { record[key] = Self.redacted(context) }
            }
            write(record)
        }
    }
    private static func redacted(_ context: [String: Any]) -> [String: Any] {
        var result = context
        let id = result.removeValue(forKey: "conversationID") as? String
        result["conversationHash"] = id.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } as Any? ?? NSNull()
        for key in ["currentPathCount", "displayMode", "isCC", "page2App"] where result[key] == nil { result[key] = NSNull() }
        return result
    }
    private func write(_ record: [String: Any]) {
        guard !disabled else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            if handle == nil || bytes + data.count > limit {
                try handle?.close()
                if handle != nil { part += 1 }
                let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true).appendingPathComponent(directoryName, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let suffix = part == 0 ? "" : "-\(part)"
                let url = directory.appendingPathComponent("\(prefix)-\(sessionID)\(suffix).jsonl")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try FileHandle(forWritingTo: url)
                bytes = Int(try handle!.seekToEnd())
                environmentRecord["part"] = part
                if record["type"] as? String != "environment" {
                    var header = try JSONSerialization.data(withJSONObject: environmentRecord, options: [.sortedKeys])
                    header.append(0x0A)
                    try handle?.write(contentsOf: header); bytes += header.count
                }
            }
            try handle?.write(contentsOf: data)
            bytes += data.count
        } catch {
            // 不在每次手势重试 / 刷屏；不输出错误里的沙盒路径或产品内容。
            disabled = true
            try? handle?.close(); handle = nil
            NSLog("[AirPerfProbe] JSONL write failed (%@); recording stopped for this process", String(describing: type(of: error)))
        }
    }
}
#endif
