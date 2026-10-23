#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import QuartzCore

/// 只有现有 UI 提供的标量；主线程发布值副本，后台不访问产品模型。
struct AirProbeContext: Sendable {
    var conversationID: String?
    var pathCount: Int?
    var displayMode: String?
    var isCC: Bool?
    var page2App = "unknown"
    var listObservedAt: Double?
    var ccObservedAt: Double?
    var page2ObservedAt: Double?

    var fields: [String: Any] {
        ["conversationID": conversationID as Any? ?? NSNull(),
         "currentPathCount": pathCount as Any? ?? NSNull(), "displayMode": displayMode as Any? ?? NSNull(),
         "isCC": isCC as Any? ?? NSNull(), "page2App": page2App,
         "listObservedAt": listObservedAt as Any? ?? NSNull(), "ccObservedAt": ccObservedAt as Any? ?? NSNull(),
         "page2ObservedAt": page2ObservedAt as Any? ?? NSNull()]
    }
}

struct AirProbeSection: Equatable, Sendable {
    let name: String
    let start: Double
    var fields: [String: Any] { ["name": name, "start": start] }
}

/// 仅用于同步函数 / 同步闭包，不能跨 await；线程迁移后不把旧区段挂到新线程。
struct AirProbeSpan: Sendable {
    let section: AirProbeSection
    let parents: [AirProbeSection]
    let isMainThread: Bool
}

enum AirProbeSections {
    /// 入口门：重量版探针或常开哨兵任一开着就记区段（plan-032 §1.5）
    static let enabled = AirPerfProbe.enabled || AirStallSentinel.enabled

    private final class Stack: NSObject { var values: [AirProbeSection] = [] }
    private static let threadKey = "com.susu.MemoryPalace.air-probe.sections"
    private static var threadStack: Stack {
        if let stack = Thread.current.threadDictionary[threadKey] as? Stack { return stack }
        let stack = Stack()
        Thread.current.threadDictionary[threadKey] = stack
        return stack
    }

    static func enter(_ name: StaticString) -> AirProbeSpan {
        let section = AirProbeSection(name: String(describing: name), start: CACurrentMediaTime())
        if Thread.isMainThread {
            return AirProbeRuntime.shared.push(section)
        }
        let stack = threadStack
        let span = AirProbeSpan(section: section, parents: stack.values, isMainThread: false)
        stack.values.append(section)
        return span
    }
    static func leave(_ span: AirProbeSpan) {
        if span.isMainThread {
            AirProbeRuntime.shared.pop(span.section)
        } else {
            let stack = threadStack
            if stack.values.last == span.section { stack.values.removeLast() }
        }
    }
}

/// 锁内只复制标量 / 短栈，不调用产品函数、文件 API、编码或回调。主线程卡在文件系统时后台仍可取快照。
final class AirProbeRuntime: @unchecked Sendable {
    static let shared = AirProbeRuntime()
    private let lock = NSLock()
    private var writer: AirProbeWriter?
    private var context = AirProbeContext()
    private var sections: [AirProbeSection] = []
    private var foreground = true
    private var batteryLevel: Float = -1
    private var batteryState = 0
    private var batteryObservedAt: Double?
    private var busyTotal = 0.0
    private var busyStart: Double?
    private var lastFrame: Double?
    private var frameMaxMs = 0.0
    private var frameCount = 0
    // iOS ubiquity 根的通常前缀；若系统返回其他根，再用既有 primeICloudContainer 结果补齐。
    private var cloudPrefixes = ["/private/var/mobile/Library/Mobile Documents/", "/var/mobile/Library/Mobile Documents/"]

    struct Snapshot: Sendable {
        let context: AirProbeContext
        let sections: [AirProbeSection]
        let foreground: Bool
        let batteryLevel: Float
        let batteryState: Int
        let batteryObservedAt: Double?
        let busyTotal: Double
        let frameMaxMs: Double
        let frameCount: Int
        let lastFrame: Double?
    }

    func install(_ writer: AirProbeWriter) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer
    }
    func publish(_ value: AirProbeContext) {
        lock.lock(); defer { lock.unlock() }
        context = value
    }
    func push(_ section: AirProbeSection) -> AirProbeSpan {
        lock.lock(); defer { lock.unlock() }
        let span = AirProbeSpan(section: section, parents: sections, isMainThread: true)
        sections.append(section)
        return span
    }
    func pop(_ section: AirProbeSection) {
        lock.lock()
        if sections.last == section { sections.removeLast() }
        let depth = sections.count
        lock.unlock()
        // 锁外回调（本类锁内不调外部函数）；pop 只在主线程
        if AirStallSentinel.enabled {
            AirStallSentinel.closedSection(section.name, start: section.start, end: CACurrentMediaTime(), depth: depth)
        }
    }
    func setForeground(_ value: Bool, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        foreground = value
        if let start = busyStart { busyTotal += max(0, now - start) }
        busyStart = value ? now : nil
        lastFrame = nil; frameMaxMs = 0; frameCount = 0
    }
    func battery(level: Float, state: Int, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        batteryLevel = level; batteryState = state; batteryObservedAt = now
    }
    func openedBusy(at now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard foreground else { return }
        if let start = busyStart { busyTotal += max(0, now - start) }
        busyStart = now
    }
    func closedBusy(at now: Double) {
        lock.lock(); defer { lock.unlock() }
        if let start = busyStart { busyTotal += max(0, now - start) }
        busyStart = nil
    }
    func frame(_ sample: PerfChatCore.FrameSample) {
        lock.lock(); defer { lock.unlock() }
        if let lastFrame { frameMaxMs = max(frameMaxMs, (sample.timestamp - lastFrame) * 1000) }
        lastFrame = sample.timestamp; frameCount += 1
    }
    func snapshot(at now: Double, resetFrames: Bool = false) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let snapshot = Snapshot(context: context, sections: sections, foreground: foreground,
                                batteryLevel: batteryLevel, batteryState: batteryState, batteryObservedAt: batteryObservedAt,
                                busyTotal: busyTotal + (busyStart.map { max(0, now - $0) } ?? 0),
                                frameMaxMs: frameMaxMs, frameCount: frameCount, lastFrame: lastFrame)
        if resetFrames { frameMaxMs = 0; frameCount = 0 }
        return snapshot
    }
    func noteCloudRoot(_ url: URL) {
        // 只转换现成 URL 的路径文本，不 standardizedFileURL、不查 resourceValues、不调用 ubiquity API。
        let path = url.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        lock.lock(); defer { lock.unlock() }
        if !cloudPrefixes.contains(prefix) { cloudPrefixes.append(prefix) }
    }
    func finishedFileCall(_ span: AirProbeSpan, root: URL?, count: Int) {
        let end = CACurrentMediaTime()
        AirProbeSections.leave(span)
        guard AirPerfProbe.enabled else { return }
        let path = root?.path
        lock.lock()
        let inCloud = path.map { path in cloudPrefixes.contains { path.hasPrefix($0) || path + "/" == $0 } }
        let writer = self.writer
        let context = self.context
        lock.unlock()
        // 只把 Bool / 计数 / 固定区段名入队；根目录、文件名、楼层 ID 都不输出。
        writer?.append(makeRecord: {
            ["type": "fileCall", "operation": span.section.name,
             "start": span.section.start, "end": end, "durationMs": (end - span.section.start) * 1000,
             "caller": span.parents.last?.name ?? "unmarked", "callerStack": span.parents.map(\.fields),
             "isMainThread": span.isMainThread, "returnedFileCount": count,
             "rootInICloud": inCloud as Any? ?? NSNull(), "rootCheck": "pathPrefix",
             "context": context.fields]
        })
    }
    /// #026：分段计时，每次都记（不只卡顿时采样）——卡顿里的大段能拆到具体哪一步
    func finishedSection(_ span: AirProbeSpan) {
        let end = CACurrentMediaTime()
        AirProbeSections.leave(span)
        guard AirPerfProbe.enabled else { return }
        lock.lock()
        let writer = self.writer
        let context = self.context
        lock.unlock()
        writer?.append(makeRecord: {
            ["type": "sectionTiming", "operation": span.section.name,
             "start": span.section.start, "end": end, "durationMs": (end - span.section.start) * 1000,
             "caller": span.parents.last?.name ?? "unmarked", "callerStack": span.parents.map(\.fields),
             "isMainThread": span.isMainThread, "context": context.fields]
        })
    }
}
#endif

/// #026 发送链路分段计时：探针包（DEBUG / PERF_BENCH 的 iOS，且探针开着）记一条 sectionTiming，其余直接执行
enum AirTimedSection {
    @inline(__always) @discardableResult
    static func run<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        guard AirProbeSections.enabled else { return try body() }
        let span = AirProbeSections.enter(name)
        defer { AirProbeRuntime.shared.finishedSection(span) }
        #endif
        return try body()
    }
}
