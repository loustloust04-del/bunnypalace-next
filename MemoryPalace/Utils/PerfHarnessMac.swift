#if (DEBUG || PERF_BENCH) && os(macOS)
import AppKit
import QuartzCore
import CoreFoundation
import Darwin
import MachO

enum MacPerfCounter: Int, CaseIterable {
    case appInit, contentViewBody, sidebarBody, codingReload, codingListSQL
    case codingDetailParse, codingDetailRevision, warroomBody, mainFetch, prefsWrite
    case terminalFeedBytes, markdownStart, markdownEnd, watcherBatch
    case panelChange, codingOpen, codingSelect, profileSwitch, settingsAppear
}

enum PerfCountMac {
    private static let lock = NSLock()
    private static let requested = ProcessInfo.processInfo.environment["MP_PERF_RUN"] == "1"
    nonisolated(unsafe) private static var counts = Array(repeating: UInt64(0), count: MacPerfCounter.allCases.count)
    private static let names = MacPerfCounter.allCases.map { String(describing: $0) }

    static func hit(_ key: MacPerfCounter, by amount: UInt64 = 1) {
        guard requested, BenchIsolation.active else { return }
        lock.lock()
        counts[key.rawValue] &+= amount
        lock.unlock()
    }

    static func snapshot() -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: UInt64] = Dictionary(minimumCapacity: names.count)
        for index in names.indices { result[names[index]] = counts[index] }
        return result
    }
}

@MainActor enum PerfHarnessMac {
    static let requested = ProcessInfo.processInfo.environment["MP_PERF_RUN"] == "1"
    static var enabled: Bool { requested && BenchIsolation.active }
    static let uiRequested: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["MP_PERF_UI"] == "1" && environment["MP_PERF_SEED"] == "prepared"
            && environment["MP_PERF_RUN"] == nil
    }()
    static var uiEnabled: Bool { uiRequested && BenchIsolation.configuration?.role == "seed" }
    static var streamEnabled: Bool { enabled || uiEnabled }
    private(set) static var processStart: Double?
    static var appInitBody: Double = 0
    static weak var mainWindow: NSWindow?
    private(set) static var frameSequence: UInt64 = 0
    private(set) static var configuration: Configuration?

    struct Configuration: Encodable {
        let runID, sourceSHA: String
        let scenarios: [String]
        let caseName, loadLevel: String
        let fixtureURL: URL

        init(environment: [String: String], isolation: BenchIsolation.Configuration) throws {
            func token(_ value: String?, name: String) throws -> String {
                guard let value, !value.isEmpty, value.utf8.count <= 128,
                      value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                          || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                    throw ConfigurationError.invalid(name)
                }
                return value
            }
            runID = try token(environment["MP_PERF_RUNID"], name: "MP_PERF_RUNID")
            guard let sha = environment["MP_PERF_SOURCE_SHA"], [40, 64].contains(sha.utf8.count),
                  sha.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw ConfigurationError.invalid("MP_PERF_SOURCE_SHA")
            }
            sourceSHA = sha.lowercased()
            let all = (1...9).map { "M\($0)" }
            let selected = environment["MP_PERF_SCENARIOS"].map { $0.components(separatedBy: ",") } ?? all
            guard !selected.isEmpty, Set(selected).count == selected.count,
                  selected.allSatisfy({ all.contains($0) }) else { throw ConfigurationError.invalid("MP_PERF_SCENARIOS") }
            scenarios = selected
            caseName = try token(environment["MP_PERF_CASE"] ?? "all", name: "MP_PERF_CASE")
            let level = environment["MP_PERF_LEVEL"] ?? "L0"
            guard ["L0", "L1a", "L1b", "L1c", "L-term", "background", "L-io", "L2"].contains(level) else {
                throw ConfigurationError.invalid("MP_PERF_LEVEL")
            }
            loadLevel = level
            if let path = environment["MP_PERF_FIXTURE"] {
                guard path.hasPrefix("/") else { throw ConfigurationError.invalid("MP_PERF_FIXTURE") }
                fixtureURL = try isolation.check(URL(fileURLWithPath: path))
            } else {
                fixtureURL = try isolation.check(isolation.root.appendingPathComponent("perf/fixture.json"))
            }
        }
    }

    enum ConfigurationError: Error { case invalid(String) }
    private struct Busy: Encodable { let start, end: Double; var duration: Double { end - start } }
    private struct UIMainThreadSnapshot: Encodable {
        let pid: Int32
        let startedAt, observedThrough, maximumBlockSeconds: Double
        let longBlocks: [Busy]
        let overflow: Bool
    }
    private struct Frame: Encodable { let at, interval: Double }
    private struct ObserverCallback: Encodable { let at: Double; let activity: String; let order: Int }
    private struct EnvironmentSnapshot: Encodable {
        let at: Double
        let thermal: String
        let active, lowPower: Bool
        let visible, key, miniaturized: MacPerfCapture<Bool>
        let occlusion: MacPerfCapture<UInt>
        let display: MacPerfCapture<UInt32>
        let refreshHz: MacPerfCapture<Double>
        let loadAverage: MacPerfCapture<[Double]>
        let logicalCPUs, activeCPUs: Int
        let physicalMemoryBytes: UInt64
        let uptime: Double
    }
    private struct Sample: Encodable {
        let name, kind, outcome: String
        let t0, endedAt: Double
        let deadline: Double
        let readyAt: MacPerfCapture<Double>
        let busySegments: [Busy]
        let busyMode: String
        let callbackIntervals: [Frame]
        let callbackCount: Int
        let gap25, hitch50, busyOver250: Int
        let maximumBusySeconds: MacPerfCapture<Double>
        let countsBefore, countsAfter, countsDelta: [String: UInt64]
        let resourceBefore, resourceAfter: MacPerfCapture<MacPerfResource>
        let resourceDelta: MacPerfCapture<MacPerfResourceDelta>
        let resourceWindow: MacPerfResourceSampler.Result
        let environmentBefore, environmentAfter: EnvironmentSnapshot
        let assertFailures: [String]
    }
    @MainActor private final class Session {
        let name: String
        var start, deadline: Double
        let observing: Bool
        let condition: () -> Bool
        let assertions: () -> [String]
        let continuation: CheckedContinuation<Void, Never>
        let counts = PerfCountMac.snapshot()
        let resource: MacPerfCapture<MacPerfResource>
        let environment: EnvironmentSnapshot
        let sampler = MacPerfResourceSampler()
        let failureOffset = failures.count
        var gate: MacPerfReadyGate
        var busy: [Busy] = []
        var frames: [Frame] = []
        var frameCount = 0
        var lastFrame: Double?
        var conditionViolation = false
        var liveResizeObserved = false
        var timer: DispatchSourceTimer?

        init(name: String, start: Double, duration: Double, observing: Bool,
             condition: @escaping () -> Bool, assertions: @escaping () -> [String],
             continuation: CheckedContinuation<Void, Never>) {
            self.name = name; self.start = start; deadline = start + duration; self.observing = observing
            self.condition = condition; self.assertions = assertions; self.continuation = continuation
            gate = MacPerfReadyGate(deadline: deadline)
            resource = captureResource(); environment = environmentSnapshot()
        }

        func begin(at start: Double, duration: Double) {
            self.start = start
            deadline = start + duration
            gate = MacPerfReadyGate(deadline: deadline)
            lastFrame = lastFrameAt
        }
    }

    private static var started = false
    private static var failures: [String] = []
    private static var samples: [Sample] = []
    private static var session: Session?
    private static var busyStart: Double?
    private static var lowObserver: CFRunLoopObserver?
    private static var highObserver: CFRunLoopObserver?
    private static var observerDescription = ""
    private static var observerOrders: [Int] = []
    private static var observerCallbacks: [ObserverCallback] = []
    private static var displayLink: CADisplayLink?
    private static var displayTarget: DisplayTarget?
    private static weak var displayView: NSView?
    private static var lastFrameAt: Double?
    private static var fixtureBefore: MacPerfCapture<MacPerfFingerprint> = .failure("fixture-before not captured")
    private static var fixtureCaptured = false
    private static var uiMaximumBlockSeconds = 0.0
    private static var uiLongBlocks: [Busy] = []
    private static var uiOverflow = false
    private static var uiLastPublishedAt = -Double.infinity
    private static var uiMetricsURL: URL?
    private static let uiWriter = DispatchQueue(label: "mp.perf-ui-main-thread", qos: .utility)
    private static let uiEncoder = JSONEncoder()

    static func appInit() {
        guard enabled || uiEnabled, !started, let isolation = BenchIsolation.configuration else { return }
        started = true
        appInitBody = CACurrentMediaTime()
        if uiEnabled {
            installObservers()
            publishUIMetrics(at: appInitBody)
            return
        }
        processStart = readProcessStart()
        if processStart == nil { fail("sysctl KERN_PROC_PID p_starttime failed") }
        do { configuration = try Configuration(environment: ProcessInfo.processInfo.environment, isolation: isolation) }
        catch {
            // An invalid identity cannot be turned into a made-up output filename/SHA.
            FileHandle.standardError.write(Data("[mac-perf] invalid configuration: \(error)\n".utf8))
            exit(78)
        }
        do { try MacPerfPreferencesProbe.install { PerfCountMac.hit(.prefsWrite) } }
        catch { fail("NSUserDefaults counter unavailable: \(error)") }
        PerfCountMac.hit(.appInit)
        installObservers()
        Task { @MainActor in await PerfHarnessMacDriver.run() }
    }

    static func attach(view: NSView) {
        guard enabled else { return }
        if let window = view.window { mainWindow = window }
        guard displayView !== view else { return }
        displayLink?.invalidate()
        lastFrameAt = nil
        displayView = view
        let target = DisplayTarget()
        displayTarget = target
        let link = view.displayLink(target: target, selector: #selector(DisplayTarget.frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @MainActor private final class DisplayTarget: NSObject {
        @objc func frame(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            frameSequence &+= 1
            PerfHarnessMacDriver.displayFrame()
            lastFrameAt = now
            if let current = session {
                current.frameCount += 1
                if let previous = current.lastFrame { current.frames.append(Frame(at: now, interval: now - previous)) }
                current.lastFrame = now
                poll(current, at: now)
            }
            // A frame does not mean layout/CA observers later in this turn have finished.
        }
    }

    static func captureFixtureBefore() {
        guard enabled, !fixtureCaptured else { return }
        fixtureCaptured = true
        fixtureBefore = captureFingerprint(label: "before")
    }

    static func measure(_ name: String, t0: Double? = nil, timeout: Double = 10,
                        action: () throws -> Void, condition: @escaping () -> Bool,
                        assertions: @escaping () -> [String]) async {
        guard enabled else { return }
        guard started, configuration != nil else { fail("\(name): appInit was not installed"); return }
        guard session == nil else { fail("\(name): overlapping measurement"); return }
        guard timeout.isFinite, timeout > 0 else { fail("\(name): invalid timeout"); return }
        let start = t0 ?? CACurrentMediaTime()
        guard start.isFinite, start <= CACurrentMediaTime() else { fail("\(name): invalid t0"); return }
        await withCheckedContinuation { continuation in
            let current = Session(name: name, start: start, duration: min(timeout, 10), observing: false,
                                  condition: condition, assertions: assertions, continuation: continuation)
            session = current
            armWallclock(current)
            current.begin(at: t0 ?? CACurrentMediaTime(), duration: min(timeout, 10))
            let actionAt = CACurrentMediaTime()
            if current.gate.expired(at: actionAt) { Self.timeout(current, at: actionAt); return }
            do { try action() }
            catch { fail("\(name): action threw: \(error)"); complete(current, outcome: "actionError", at: CACurrentMediaTime()); return }
            poll(current, at: CACurrentMediaTime())
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    static func observe(_ name: String, duration: Double, condition: @escaping () -> Bool,
                        assertions: @escaping () -> [String]) async {
        guard enabled else { return }
        guard started, configuration != nil, session == nil else { fail("\(name): observation unavailable/overlapping"); return }
        if duration != 600 { fail("\(name): M9 requires the full 600-second window (requested \(duration))") }
        captureFixtureBefore()
        await withCheckedContinuation { continuation in
            let current = Session(name: name, start: CACurrentMediaTime(), duration: 600, observing: true,
                                  condition: condition, assertions: assertions, continuation: continuation)
            session = current
            armWallclock(current)
            current.begin(at: CACurrentMediaTime(), duration: 600)
            poll(current, at: CACurrentMediaTime())
        }
    }

    static func fail(_ reason: String) {
        guard enabled else { return }
        failures.append(reason)
    }

    private static func installObservers() {
        busyStart = appInitBody
        let low = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { observer, _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                busyStart = now
                if observerCallbacks.count < 16 {
                    observerCallbacks.append(ObserverCallback(at: now, activity: "afterWaiting", order: CFRunLoopObserverGetOrder(observer)))
                }
            }
        }
        let high = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { observer, _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if observerCallbacks.count < 16 {
                    observerCallbacks.append(ObserverCallback(at: now, activity: "beforeWaiting", order: CFRunLoopObserverGetOrder(observer)))
                }
                closeTurn(at: now)
            }
        }
        guard let low, let high else { fail("CFRunLoop observer creation failed"); return }
        lowObserver = low; highObserver = high
        observerOrders = [CFRunLoopObserverGetOrder(low), CFRunLoopObserverGetOrder(high)]
        CFRunLoopAddObserver(CFRunLoopGetMain(), low, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), high, .commonModes)
        if let description = CFCopyDescription(CFRunLoopGetMain()) { observerDescription = description as String }
        else { fail("CFRunLoop observer description unavailable") }
    }

    private static func closeTurn(at now: Double) {
        if uiEnabled, let start = busyStart {
            let duration = now - start
            uiMaximumBlockSeconds = max(uiMaximumBlockSeconds, duration)
            if duration > 1 {
                if uiLongBlocks.count < 128 { uiLongBlocks.append(Busy(start: start, end: now)) }
                else { uiOverflow = true }
            }
            publishUIMetrics(at: now)
        }
        if let current = session, let start = busyStart {
            let clipped = max(start, current.start)
            if now > clipped {
                current.busy.append(Busy(start: clipped, end: now))
                current.gate.closedBusy(start: clipped, end: now)
            }
        }
        busyStart = nil
        guard let current = session else { return }
        poll(current, at: now)
        guard session === current, !current.observing else { return }
        switch current.gate.afterClosedTurn(at: now) {
        case .waiting: break
        case .ready(let readyAt): complete(current, outcome: "ready", at: now, readyAt: readyAt)
        case .timedOut: timeout(current, at: now)
        }
    }

    private static func publishUIMetrics(at now: Double) {
        guard now - uiLastPublishedAt >= 1, let isolation = BenchIsolation.configuration else { return }
        uiLastPublishedAt = now
        if uiMetricsURL == nil {
            do { uiMetricsURL = try isolation.check(isolation.root.appendingPathComponent("perf/ui-main-thread.json")) }
            catch { BenchIsolation.fail("UI主线程观察落点无效：\(error)") }
            let directory = uiMetricsURL!.deletingLastPathComponent()
            uiWriter.async {
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                catch { BenchIsolation.fail("UI主线程观察目录不可用：\(error)") }
            }
        }
        guard let url = uiMetricsURL else { return }
        let snapshot = UIMainThreadSnapshot(pid: getpid(), startedAt: appInitBody, observedThrough: now,
            maximumBlockSeconds: uiMaximumBlockSeconds, longBlocks: uiLongBlocks, overflow: uiOverflow)
        let encoder = uiEncoder
        uiWriter.async {
            do { try isolation.writeAtomically(encoder.encode(snapshot), to: url) }
            catch { BenchIsolation.fail("UI主线程观察写入失败：\(error)") }
        }
    }

    private static func armWallclock(_ current: Session) {
        // Not a display-link timeout: obscured/background windows may deliver no frames.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler {
            CFRunLoopWakeUp(CFRunLoopGetMain())
            DispatchQueue.main.async {
                guard session === current else { return }
                poll(current, at: CACurrentMediaTime())
            }
        }
        current.timer = timer
        timer.resume()
    }

    private static func poll(_ current: Session, at now: Double) {
        guard session === current else { return }
        if !current.observing, current.gate.expired(at: now) { timeout(current, at: now); return }
        let resizing = (mainWindow ?? displayView?.window)?.inLiveResize == true
        current.liveResizeObserved = current.liveResizeObserved || resizing
        let valid = current.condition() && !resizing
        current.gate.poll(condition: valid, at: now)
        if current.observing {
            if !valid, !current.conditionViolation {
                current.conditionViolation = true
                fail("\(current.name): observation condition violated")
            }
            if current.gate.expired(at: now) { complete(current, outcome: "observed", at: now) }
        }
    }

    private static func timeout(_ current: Session, at now: Double) {
        fail("\(current.name): absolute deadline exceeded (\(current.deadline - current.start)s)")
        complete(current, outcome: "timeout", at: now)
    }

    private static func complete(_ current: Session, outcome: String, at now: Double, readyAt: Double? = nil) {
        guard session === current else { return }
        current.timer?.cancel(); current.timer = nil
        // Timeouts/actions can finish inside an open busy turn; include its elapsed part.
        if let start = busyStart, now > max(start, current.start) {
            current.busy.append(Busy(start: max(start, current.start), end: now))
        }
        session = nil
        // Snapshot before functional assertions; their queries/writes are not operation work.
        let afterCounts = PerfCountMac.snapshot()
        let afterResource = captureResource()
        let afterEnvironment = environmentSnapshot()
        let windowResource = current.sampler.stop()
        for error in windowResource.errors { fail("\(current.name): rusage sampler: \(error)") }
        for assertion in current.assertions() { fail("\(current.name): \(assertion)") }
        let resourceDelta = MacPerfResourceDelta.between(current.resource, afterResource)
        if case .failure(let reason) = resourceDelta { fail("\(current.name): \(reason)") }
        let delta = afterCounts.map { (key, value) in (key, value &- (current.counts[key] ?? 0)) }
        let reportedBusy = current.liveResizeObserved ? [] : current.busy
        var gap25 = 0, hitch50 = 0, busyOver250 = 0
        var longest: Double?
        for frame in current.frames {
            if frame.interval > 0.025 { gap25 += 1 }
            if frame.interval > 0.050 { hitch50 += 1 }
        }
        for block in reportedBusy {
            if block.duration > 0.250 { busyOver250 += 1 }
            longest = max(longest ?? block.duration, block.duration)
        }
        samples.append(Sample(name: current.name, kind: current.observing ? "observation" : "operation", outcome: outcome,
            t0: current.start, endedAt: now, deadline: current.deadline,
            readyAt: current.observing ? .notApplicable("fixed observation window has no ready endpoint")
                : readyAt.map { .value($0) } ?? .failure("no confirmed ready boundary: \(outcome)"),
            busySegments: reportedBusy, busyMode: current.liveResizeObserved ? "callback-intervals-only-live-resize" : "dual-observer",
            callbackIntervals: current.frames,
            callbackCount: current.frameCount,
            gap25: gap25, hitch50: hitch50, busyOver250: busyOver250,
            maximumBusySeconds: current.liveResizeObserved ? .notApplicable("live resize reports callback intervals only")
                : longest.map { .value($0) } ?? .failure("no busy segment observed"),
            countsBefore: current.counts, countsAfter: afterCounts, countsDelta: Dictionary(uniqueKeysWithValues: delta),
            resourceBefore: current.resource, resourceAfter: afterResource, resourceDelta: resourceDelta,
            resourceWindow: windowResource,
            environmentBefore: current.environment, environmentAfter: afterEnvironment,
            assertFailures: Array(failures.dropFirst(current.failureOffset))))
        current.continuation.resume()
    }

    private static func captureResource() -> MacPerfCapture<MacPerfResource> {
        do { return .value(try MacPerfResource.read()) }
        catch { let reason = "proc_pid_rusage V4: \(error)"; fail(reason); return .failure(reason) }
    }

    private static func captureFingerprint(label: String) -> MacPerfCapture<MacPerfFingerprint> {
        do { return .value(try PerfHarnessMacDriver.fingerprint()) }
        catch { let reason = "fixture \(label): \(error)"; fail(reason); return .failure(reason) }
    }

    private static func readProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        let startTime = info.kp_proc.p_un.__p_starttime
        let wall = Double(startTime.tv_sec) + Double(startTime.tv_usec) / 1_000_000
        let age = Date().timeIntervalSince1970 - wall
        let now = CACurrentMediaTime()
        guard wall > 0, age >= 0, age.isFinite else { return nil }
        return now - age
    }

    private static func environmentSnapshot() -> EnvironmentSnapshot {
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        var load = [Double](repeating: 0, count: 3)
        let loadCount = load.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, Int32($0.count)) }
        let loadResult: MacPerfCapture<[Double]>
        if loadCount == 3 { loadResult = .value(load) }
        else { let reason = "getloadavg failed: \(loadCount)"; fail(reason); loadResult = .failure(reason) }
        let window = mainWindow ?? displayView?.window
        let missing = "main window unavailable"
        var display: MacPerfCapture<UInt32> = .failure(missing)
        var refresh: MacPerfCapture<Double> = .failure(missing)
        if let screen = window?.screen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let id = CGDirectDisplayID(number.uint32Value)
            display = .value(id)
            if let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 { refresh = .value(mode.refreshRate) }
            else { refresh = .failure("display mode does not expose a fixed refresh rate") }
        }
        return EnvironmentSnapshot(at: CACurrentMediaTime(), thermal: thermal, active: NSApp.isActive,
            lowPower: process.isLowPowerModeEnabled,
            visible: window.map { .value($0.isVisible) } ?? .failure(missing),
            key: window.map { .value($0.isKeyWindow) } ?? .failure(missing),
            miniaturized: window.map { .value($0.isMiniaturized) } ?? .failure(missing),
            occlusion: window.map { .value($0.occlusionState.rawValue) } ?? .failure(missing),
            display: display, refreshHz: refresh, loadAverage: loadResult,
            logicalCPUs: process.processorCount, activeCPUs: process.activeProcessorCount,
            physicalMemoryBytes: process.physicalMemory, uptime: process.systemUptime)
    }

    private struct Report: Encodable {
        let `protocol` = "macV1"
        let harnessRevision = "macV1-r1"
        let runID, sourceSHA, buildConfiguration: String
        let mainBinaryUUID: MacPerfCapture<String>
        let configuration: Configuration
        let effectiveSwitches: [String: Bool]
        let processStart: MacPerfCapture<Double>
        let appInitBody: Double
        let observerOrders: [Int]
        let observerDescription: String
        let observerCallbacks: [ObserverCallback]
        let fixtureBefore, fixtureAfter: MacPerfCapture<MacPerfFingerprint>
        let environment: EnvironmentSnapshot
        let driverLoadEvidence: [String: String]
        let samples: [Sample]
        let assertFailures: [String]
        let callbackMeaning = "NSView.displayLink callback intervals, not dropped frames; zero callbacks is not zero hitches; first interval may start before t0"
        let busyMeaning = "afterWaiting Int.min to beforeWaiting Int.max in commonModes; open segment included on timeout"
        let deadlineMeaning = "10s operation deadline, fixed 600s observation; main-thread blockage can delay completion, reported by endedAt versus deadline; resource rates use actual endpoint timestamps"
        let counterMeaning = "mainFetch: instrumented explicit main-thread fetch attempts, not global/implicit faults; codingListSQL: main UI-reader prepares, excluding initialization/exec/worker connections; prefsWrite: outer NSUserDefaults mutator calls, not keys/disk writes, excluding register/volatile/direct CFPreferences/subclass bypass; panelChange: action calls including nesting; markdownStart/End: real tasks including cache hits/cancellation"
    }

    static func finish() -> Never {
        guard enabled, let config = configuration, let isolation = BenchIsolation.configuration else { exit(78) }
        if session != nil { fail("finish called with an active measurement") }
        if !fixtureCaptured { fail("fixture-before was never captured") }
        let after = captureFingerprint(label: "after")
        var switches: [String: Bool] = [:]
        for (key, expected) in isolation.switches {
            if let actual = UserDefaults.standard.object(forKey: key) as? Bool {
                switches[key] = actual
                if actual != expected { fail("effective switch differs from isolated configuration: \(key)") }
            } else { fail("effective switch missing/non-boolean: \(key)") }
        }
        let uuid: MacPerfCapture<String>
        if let actual = binaryUUID() { uuid = .value(actual) }
        else { fail("main binary LC_UUID missing"); uuid = .failure("LC_UUID missing") }
        if displayLink == nil { fail("no real NSView.displayLink was attached") }
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release+PERF_BENCH"
        #endif
        let environment = environmentSnapshot()
        let report = Report(runID: config.runID, sourceSHA: config.sourceSHA, buildConfiguration: build,
            mainBinaryUUID: uuid, configuration: config, effectiveSwitches: switches,
            processStart: processStart.map { .value($0) } ?? .failure("p_starttime unavailable"),
            appInitBody: appInitBody, observerOrders: observerOrders, observerDescription: observerDescription,
            observerCallbacks: observerCallbacks,
            fixtureBefore: fixtureBefore, fixtureAfter: after, environment: environment,
            driverLoadEvidence: PerfHarnessMacDriver.loadEvidence, samples: samples, assertFailures: failures)
        do {
            let directory = try isolation.check(isolation.root.appendingPathComponent("perf", isDirectory: true))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = try isolation.check(directory.appendingPathComponent("run-\(config.runID).json"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try isolation.writeAtomically(encoder.encode(report), to: destination)
        } catch {
            FileHandle.standardError.write(Data("[mac-perf] report write failed: \(error)\n".utf8))
            exit(78)
        }
        exit(0)
    }

    private static func binaryUUID() -> String? {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            guard load.cmdsize >= MemoryLayout<load_command>.size else { return nil }
            if load.cmd == UInt32(LC_UUID), load.cmdsize >= MemoryLayout<uuid_command>.size {
                return UUID(uuid: command.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
#endif
