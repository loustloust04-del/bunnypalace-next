#if (DEBUG || PERF_BENCH) && os(iOS)
import Darwin
import Foundation
import QuartzCore

/// 50ms 后台节拍，至多一个未应答 ping；编码/落盘在另一条队列，不让文件写入阻塞哨兵。
final class AirStallMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.susu.MemoryPalace.air-stall", qos: .userInitiated)
    private let writer: AirProbeWriter
    private var timer: DispatchSourceTimer?
    private let ackLock = NSLock()
    private var acknowledgement: (id: Int, time: Double, snapshot: AirProbeRuntime.Snapshot)?
    private var sequence = 0
    private var pending: Pending?
    private var lastEnvironment: (time: Double, cpu: Double?, busy: Double)?
    private var lastTick: Double?
    private var maxTickGapMs = 0.0

    private struct SectionSample {
        let at: Double
        let stack: [AirProbeSection]
        var fields: [String: Any] { ["at": at, "stack": stack.map(\.fields)] }
    }
    private struct Pending {
        let id: Int
        let start: Double
        let context: AirProbeContext
        var samples: [SectionSample] = []
        var droppedSamples = 0
        var detectionContext: AirProbeContext?
        var sectionAtDetection: String?
        var lastWritten: Double?
    }

    init(writer: AirProbeWriter) { self.writer = writer }

    func setForeground(_ foreground: Bool, at time: Double) {
        queue.async { [self] in
            if !foreground {
                if let ack = takeAcknowledgement(), ack.time <= time, pending?.id == ack.id {
                    finishPending(at: ack.time, reason: "responsive", snapshot: ack.snapshot)
                }
                finishPending(at: time, reason: "background")
                timer?.cancel(); timer = nil
                lastEnvironment = nil; lastTick = nil
                return
            }
            guard timer == nil else { return }
            let now = CACurrentMediaTime()
            let snapshot = AirProbeRuntime.shared.snapshot(at: now, resetFrames: true)
            lastEnvironment = (now, Self.cpuSeconds(), snapshot.busyTotal)
            maxTickGapMs = 0; lastTick = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let snapshot = AirProbeRuntime.shared.snapshot(at: now)
        guard snapshot.foreground else { return }
        if let lastTick { maxTickGapMs = max(maxTickGapMs, (now - lastTick) * 1000) }
        lastTick = now
        defer { sampleEnvironment(at: now) }
        if let ack = takeAcknowledgement(), pending?.id == ack.id { finishPending(at: ack.time, reason: "responsive", snapshot: ack.snapshot) }
        if var pending {
            if pending.samples.last?.stack != snapshot.sections {
                if pending.samples.count < 64 {
                    pending.samples.append(SectionSample(at: now, stack: snapshot.sections))
                } else { pending.droppedSamples += 1 }
            }
            if now - pending.start > 0.250 {
                if pending.detectionContext == nil {
                    pending.detectionContext = snapshot.context
                    pending.sectionAtDetection = snapshot.sections.last?.name ?? "unmarked"
                }
                // 先留现场，后补完整时长；遭 watchdog 杀时最后一条 ongoing 是已观察到的时长下界。
                if pending.lastWritten == nil || now - pending.lastWritten! >= 1 {
                    emit(pending, at: now, phase: "ongoing", reason: "unresponsive", snapshot: snapshot)
                    pending.lastWritten = now
                }
            }
            self.pending = pending
            return
        }
        sequence += 1
        let id = sequence
        let sent = CACurrentMediaTime()
        let atSend = AirProbeRuntime.shared.snapshot(at: sent)
        pending = Pending(id: id, start: sent, context: atSend.context,
                          samples: [SectionSample(at: sent, stack: atSend.sections)])
        DispatchQueue.main.async { [weak self] in
            // 时间戳必须在主线程应答时取，不能把后台 ack 排队时间算进 stall。
            let acknowledgedAt = CACurrentMediaTime()
            guard let self else { return }
            let snapshot = AirProbeRuntime.shared.snapshot(at: acknowledgedAt)
            self.ackLock.lock()
            self.acknowledgement = (id, acknowledgedAt, snapshot)
            self.ackLock.unlock()
            AirPerfProbe.shared.sampleBatteryIfDue(at: acknowledgedAt)
        }
    }

    private func takeAcknowledgement() -> (id: Int, time: Double, snapshot: AirProbeRuntime.Snapshot)? {
        ackLock.lock(); defer { ackLock.unlock() }
        defer { acknowledgement = nil }
        return acknowledgement
    }

    private func finishPending(at now: Double, reason: String, snapshot: AirProbeRuntime.Snapshot? = nil) {
        guard let pending else { return }
        if now - pending.start > 0.250 {
            emit(pending, at: now, phase: reason == "responsive" ? "ended" : "censored", reason: reason,
                 snapshot: snapshot ?? AirProbeRuntime.shared.snapshot(at: now))
        }
        self.pending = nil
    }
    private func emit(_ pending: Pending, at now: Double, phase: String, reason: String, snapshot: AirProbeRuntime.Snapshot) {
        // 若后台也被饿住，可能没能在 250ms 时取样；只用应答前已有样本，不拿恢复后的区段冒充现场。
        let section = pending.sectionAtDetection ?? pending.samples.last?.stack.last?.name ?? "unmarked"
        writer.append([
            "type": "stall", "stallID": pending.id, "phase": phase, "endReason": reason,
            "start": pending.start, "end": now, "durationMs": max(0, now - pending.start) * 1000,
            "section": section, "sectionSamples": pending.samples.map(\.fields),
            "droppedSectionSamples": pending.droppedSamples,
            "context": pending.context.fields, "contextEnd": snapshot.context.fields,
            "contextAtDetection": (pending.detectionContext ?? pending.context).fields,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "isLowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "monitorMaxTickGapMs": maxTickGapMs
        ])
    }
    private func sampleEnvironment(at now: Double) {
        guard let previous = lastEnvironment, now - previous.time >= 1 else { return }
        let snapshot = AirProbeRuntime.shared.snapshot(at: now, resetFrames: true)
        let cpu = Self.cpuSeconds()
        let interval = now - previous.time
        let cpuPercent = cpu.flatMap { current in previous.cpu.map { max(0, current - $0) / interval * 100 } }
        let busy = min(interval, max(0, snapshot.busyTotal - previous.busy))
        let footprint = PerfHarness.footprintMiB()
        writer.append([
            "type": "environmentSample", "start": previous.time, "end": now, "intervalMs": interval * 1000,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "isLowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "batteryLevel": snapshot.batteryLevel >= 0 ? Double(snapshot.batteryLevel) as Any : NSNull(),
            "batteryState": snapshot.batteryState, "batteryObservedAt": snapshot.batteryObservedAt as Any? ?? NSNull(),
            "cpuPercent": cpuPercent as Any? ?? NSNull(), "cpuMetric": "rusage(user+system);100%=one-core",
            "footprintMiB": footprint >= 0 ? footprint as Any : NSNull(),
            "mainBusyMs": busy * 1000, "mainBusyRatio": busy / interval,
            "frameMaxMs": snapshot.frameMaxMs, "frameCount": snapshot.frameCount,
            "framePendingGapMs": snapshot.lastFrame.map { max(0, now - $0) * 1000 } as Any? ?? NSNull(),
            "monitorMaxTickGapMs": maxTickGapMs, "mainSections": snapshot.sections.map(\.fields),
            "context": snapshot.context.fields
        ])
        maxTickGapMs = 0
        lastEnvironment = (now, cpu, snapshot.busyTotal)
    }
    private static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
