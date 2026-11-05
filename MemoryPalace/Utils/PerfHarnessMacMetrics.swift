#if (DEBUG || PERF_BENCH) && os(macOS)
import Foundation
import Darwin
import QuartzCore


/// Pure state shared by the real beforeWaiting consumer and boundary tests.
struct MacPerfReadyGate {
    enum Decision: Equatable { case waiting, ready(Double), timedOut }
    let deadline: Double
    private(set) var conditionAt: Double?
    private(set) var lastLongEnd: Double?

    func expired(at now: Double) -> Bool { now >= deadline }

    mutating func poll(condition: Bool, at now: Double) {
        if !condition { conditionAt = nil }
        else if conditionAt == nil { conditionAt = now }
    }

    mutating func closedBusy(start: Double, end: Double) {
        if end - start > 0.050 { lastLongEnd = end }
    }

    /// Called ONLY after the Int.max beforeWaiting observer has closed this turn.
    func afterClosedTurn(at now: Double) -> Decision {
        if expired(at: now) { return .timedOut }
        guard let conditionAt else { return .waiting }
        let readyAt = max(conditionAt, lastLongEnd ?? conditionAt)
        return now - readyAt >= 0.500 ? .ready(readyAt) : .waiting
    }
}

/// Failure is an explicit JSON value, never an absent key or a fabricated zero.
enum MacPerfCapture<Value: Encodable>: Encodable {
    case value(Value), failure(String), notApplicable(String)
    private enum CodingKeys: String, CodingKey { case status, value, error, reason }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let value):
            try container.encode("ok", forKey: .status)
            try container.encode(value, forKey: .value)
        case .failure(let error):
            try container.encode("error", forKey: .status)
            try container.encode(error, forKey: .error)
        case .notApplicable(let reason):
            try container.encode("notApplicable", forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }
}

struct MacPerfResource: Encodable {
    let at: Double
    let userCPUSeconds, systemCPUSeconds: Double
    let logicalWriteBytes, diskReadBytes, diskWriteBytes: UInt64
    let footprintBytes, lifetimeMaxFootprintBytes: UInt64
    private static let secondsPerTick: Double? = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 else { return nil }
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    static func read() throws -> Self {
        guard let secondsPerTick else { throw POSIXError(.ENOTSUP) }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // proc_pid_rusage CPU values use Mach ticks, unlike getrusage's timeval.
        return Self(at: CACurrentMediaTime(), userCPUSeconds: Double(usage.ri_user_time) * secondsPerTick,
                    systemCPUSeconds: Double(usage.ri_system_time) * secondsPerTick,
                    logicalWriteBytes: usage.ri_logical_writes, diskReadBytes: usage.ri_diskio_bytesread,
                    diskWriteBytes: usage.ri_diskio_byteswritten, footprintBytes: usage.ri_phys_footprint,
                    lifetimeMaxFootprintBytes: usage.ri_lifetime_max_phys_footprint)
    }
}

struct MacPerfResourceDelta: Encodable {
    let sampledSeconds, cpuPercent, logicalWriteMiBPerHour: Double
    let logicalWriteBytes, diskReadBytes, diskWriteBytes: UInt64

    static func between(_ before: MacPerfCapture<MacPerfResource>, _ after: MacPerfCapture<MacPerfResource>) -> MacPerfCapture<Self> {
        guard case .value(let a) = before, case .value(let b) = after else {
            return .failure("resource delta unavailable because a rusage endpoint failed")
        }
        let elapsed = b.at - a.at
        guard elapsed > 0, b.userCPUSeconds >= a.userCPUSeconds, b.systemCPUSeconds >= a.systemCPUSeconds,
              b.logicalWriteBytes >= a.logicalWriteBytes, b.diskReadBytes >= a.diskReadBytes,
              b.diskWriteBytes >= a.diskWriteBytes else { return .failure("non-monotonic rusage endpoints") }
        let writes = b.logicalWriteBytes - a.logicalWriteBytes
        return .value(Self(sampledSeconds: elapsed,
            cpuPercent: (b.userCPUSeconds - a.userCPUSeconds + b.systemCPUSeconds - a.systemCPUSeconds) / elapsed * 100,
            logicalWriteMiBPerHour: Double(writes) / 1_048_576 / elapsed * 3600,
            logicalWriteBytes: writes, diskReadBytes: b.diskReadBytes - a.diskReadBytes,
            diskWriteBytes: b.diskWriteBytes - a.diskWriteBytes))
    }
}

/// A background timer still samples footprint when the main thread is blocked.
final class MacPerfResourceSampler: @unchecked Sendable {
    struct Result: Encodable {
        let sampledPeakFootprintBytes: MacPerfCapture<UInt64>
        let successfulSamples: Int
        let errors: [String]
        let peakDefinition = "maximum observed current footprint; background 100ms sampling, not kernel lifetime peak"
    }
    private let queue: DispatchQueue
    private var peak: UInt64 = 0
    private var count = 0
    private var errors: [String] = []
    private let timer: DispatchSourceTimer

    init() {
        let queue = DispatchQueue(label: "mac.perf.resources", qos: .utility)
        self.queue = queue
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func sample() {
        let result = Swift.Result { try MacPerfResource.read() }
        switch result {
        case .success(let resource): peak = max(peak, resource.footprintBytes); count += 1
        case .failure(let error):
            let message = String(describing: error)
            if !errors.contains(message) { errors.append(message) }
        }
    }

    func stop() -> Result {
        timer.cancel()
        return queue.sync {
            sample()
            return Result(sampledPeakFootprintBytes: count > 0 ? .value(peak) : .failure("no successful rusage sample"),
                          successfulSamples: count, errors: errors)
        }
    }

    deinit { timer.cancel() }
}
#endif
