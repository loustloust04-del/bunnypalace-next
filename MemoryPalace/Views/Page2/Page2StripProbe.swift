#if (DEBUG || PERF_BENCH) && os(iOS)
import SwiftUI
import UIKit

@MainActor
enum Page2StripProbe {
    static let enabled = ProcessInfo.processInfo.environment["MP_STRIP_PROBE"] == "1" && !AirPerfProbe.enabled && Page2ArcBench.rounds == 0
    static let withoutBlur = ProcessInfo.processInfo.environment["MP_STRIP_NO_BLUR"] == "1"
    private static let frames = FrameMonitor()
    private static var started: Double?
    private static var busyAtStart: Double = 0
    private static var counts: [String: Int] = [:]
    private static var token = UUID()
    private static var phase = ""
    private static var running = false

    static func run(select: (String) -> Void) async {
        let rounds = Int(ProcessInfo.processInfo.environment["MP_STRIP_BENCH"] ?? "") ?? 0
        guard enabled, rounds > 0, !running else { return }
        running = true
        defer { running = false; finish(); Page2AppShell.shared.setStrip(open: false, animated: false) }
        do {
            while !Page2SceneState.shared.isActive { try await Task.sleep(for: .milliseconds(100)) }
            guard Page2SceneState.shared.stripSceneActive else { return }
            Page2AppShell.shared.setStrip(open: false, animated: false)
            let app = ProcessInfo.processInfo.environment["MP_STRIP_APP"] ?? "memory"
            select(app)
            try await Task.sleep(for: .seconds(3))
            for round in 0..<min(rounds, 100) {
                for open in [true, false] {
                    guard Page2SceneState.shared.isActive, Page2SceneState.shared.stripSceneActive else { return }
                    begin("bench:\(round):\(open ? "open" : "close"):\(app)")
                    let shell = Page2AppShell.shared
                    let from = shell.beginStripDrag()
                    let target: CGFloat = open ? 1 : 0
                    let t0 = CACurrentMediaTime()
                    while true {
                        guard Page2SceneState.shared.isActive, Page2SceneState.shared.stripSceneActive else { return }
                        let t = min((CACurrentMediaTime() - t0) / 0.18, 1)
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) { shell.stripProgress = from + (target - from) * t * 0.75 }
                        if t >= 1 { break }
                        try await Task.sleep(for: .milliseconds(8))
                    }
                    shell.setStrip(open: open)
                    try await Task.sleep(for: .milliseconds(800))
                    finish()
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            if ProcessInfo.processInfo.environment["MP_STRIP_CHECKS"] == "1" { try await checkInterruption() }
            print("STRIP_BENCH done")
        } catch { print("STRIP_BENCH cancelled") }
    }

    private static func checkInterruption() async throws {
        let shell = Page2AppShell.shared
        for delay in [50, 100, 200] {
            guard Page2SceneState.shared.isActive, Page2SceneState.shared.stripSceneActive else { return }
            shell.setStrip(open: false, animated: false)
            _ = shell.beginStripDrag()
            shell.stripProgress = 0.4
            shell.setStrip(open: true)
            let initialContinuous = abs(shell.stripProgress - 0.4) < 0.0001
            try await Task.sleep(for: .milliseconds(delay))
            let before = shell.stripProgress
            let grabbed = shell.beginStripDrag()
            try await Task.sleep(for: .milliseconds(80))
            let held = shell.stripProgress
            shell.setStrip(open: false, animated: false)
            try await Task.sleep(for: .milliseconds(80))
            let cancelled = shell.stripProgress == 0 && !Page2SceneState.shared.stripTransitioning
            let check = Check(delayMs: delay, initialContinuous: initialContinuous,
                              jumpPt: abs(grabbed - before) * Page2StripMetrics.width,
                              stopped: abs(held - grabbed) < 0.0001, cancelled: cancelled,
                              pagingEnabled: PagingViewController.sharedScrollView?.isScrollEnabled ?? false)
            if let data = try? JSONEncoder().encode(check) { print("STRIP_CHECK \(String(decoding: data, as: UTF8.self))") }
        }
    }

    private struct Check: Encodable {
        let delayMs: Int
        let initialContinuous: Bool
        let jumpPt: CGFloat
        let stopped: Bool
        let cancelled: Bool
        let pagingEnabled: Bool
    }

    static func hit(_ name: String) {
        guard enabled, started != nil else { return }
        counts[name, default: 0] += 1
    }

    static func begin(_ name: String) {
        guard enabled else { return }
        finish()
        phase = name
        counts = [:]
        token = UUID()
        let now = CACurrentMediaTime()
        MainBlockMonitor.install(segmentStart: now)
        busyAtStart = MainBlockMonitor.busy(now: now)
        started = now
        frames.start()
    }

    static func finishAfterSettle() {
        guard enabled else { return }
        let expected = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard expected == token else { return }
            finish()
        }
    }

    static func finish() {
        guard enabled, let start = started else { return }
        let end = CACurrentMediaTime()
        frames.stop()
        let gaps = frames.arrivalIntervals.map { $0 * 1000 }.sorted()
        let report = Report(phase: phase, durationMs: (end - start) * 1000,
                            busyMs: max(0, MainBlockMonitor.busy(now: end) - busyAtStart) * 1000,
                            p95GapMs: gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))],
                            maxGapMs: gaps.last ?? 0, over25: gaps.filter { $0 > 25 }.count,
                            over50: gaps.filter { $0 > 50 }.count, frames: gaps.count, counts: counts,
                            blur: !withoutBlur, progress: Page2AppShell.shared.stripProgress,
                            settled: !Page2SceneState.shared.stripTransitioning,
                            settleMs: Page2AppShell.shared.stripMotion.lastSettleDuration * 1000,
                            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                            reduceMotion: UIAccessibility.isReduceMotionEnabled)
        if let data = try? JSONEncoder().encode(report) {
            let line = String(decoding: data, as: UTF8.self)
            print("STRIP_PROBE \(line)")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("page2-strip-probe.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let file = try? FileHandle(forWritingTo: url) {
                try? file.seekToEnd()
                try? file.write(contentsOf: Data((line + "\n").utf8))
                try? file.close()
            }
        }
        started = nil
        token = UUID()
    }

    private struct Report: Encodable {
        let phase: String
        let durationMs: Double
        let busyMs: Double
        let p95GapMs: Double
        let maxGapMs: Double
        let over25: Int
        let over50: Int
        let frames: Int
        let counts: [String: Int]
        let blur: Bool
        let progress: CGFloat
        let settled: Bool
        let settleMs: Double
        let thermalState: Int
        let lowPower: Bool
        let reduceMotion: Bool
    }
}
#endif
