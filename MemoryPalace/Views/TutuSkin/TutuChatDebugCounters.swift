#if PERSONAL_APPS
#if os(iOS)
#if DEBUG
import Foundation
import SwiftUI
import os.log

/// Debug-only numeric counters. Node identities stay inside the visibility dictionary.
final class TutuChatDebugCounters: ObservableObject, @unchecked Sendable {
    static let shared = TutuChatDebugCounters()

    enum Event {
        case enqueued, coalesced, cancelled, workerCompleted
        case frameReady, textured, sizeError, otherError
        case drawEntered, drawInvisible, drawNoRaster, drawNoDrawable, drawNoPass
    }

    @Published private(set) var text = "0 0 0 0 0\n0 0 0 0 0 0 0 0\n0 0 0 0 0"

    private struct Counts: Equatable {
        var enqueued: UInt64 = 0
        var coalesced: UInt64 = 0
        var cancelled: UInt64 = 0
        var workerCompleted: UInt64 = 0
        var frameReady: UInt64 = 0
        var textured: UInt64 = 0
        var sizeError: UInt64 = 0
        var otherError: UInt64 = 0
        var drawEntered: UInt64 = 0
        var drawInvisible: UInt64 = 0
        var drawNoRaster: UInt64 = 0
        var drawNoDrawable: UInt64 = 0
        var drawNoPass: UInt64 = 0
    }

    private struct Row {
        let visibleSince: UInt64
        var hasFrame: Bool
    }

    private struct Snapshot: Equatable {
        var visible = 0
        var card = 0
        var stale = 0
        var maxTextureSize = 0
        var screens = 0
        var counts = Counts()

        var text: String {
            "\(visible) \(card) \(stale) \(maxTextureSize) \(screens)\n"
                + "\(counts.enqueued) \(counts.coalesced) \(counts.cancelled) \(counts.workerCompleted) "
                + "\(counts.frameReady) \(counts.textured) \(counts.sizeError) \(counts.otherError)\n"
                + "\(counts.drawEntered) \(counts.drawInvisible) \(counts.drawNoRaster) \(counts.drawNoDrawable) \(counts.drawNoPass)"
        }
    }

    private static let log = OSLog(subsystem: "MemoryPalace.Tutu", category: "ChatCounters")
    private static let snapshotInterval: UInt64 = 1_000_000_000
    private static let staleInterval: UInt64 = 2_000_000_000
    // Published observers run synchronously and may reenter a counter API.
    private let lock = NSRecursiveLock()
    private var active = false
    private var rows: [String: Row] = [:]
    private var counts = Counts()
    private var maxTextureSize = 0
    private var screens = 0
    private var lastSnapshot = Snapshot()
    private var lastSnapshotAt: UInt64?
    private var scheduled: DispatchWorkItem?
    private var generation: UInt64 = 0

    /// Inactive events, including workers finishing after disappearance, are discarded.
    func record(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        switch event {
        case .enqueued: counts.enqueued &+= 1
        case .coalesced: counts.coalesced &+= 1
        case .cancelled: counts.cancelled &+= 1
        case .workerCompleted: counts.workerCompleted &+= 1
        case .frameReady: counts.frameReady &+= 1
        case .textured: counts.textured &+= 1
        case .sizeError: counts.sizeError &+= 1
        case .otherError: counts.otherError &+= 1
        case .drawEntered: counts.drawEntered &+= 1
        case .drawInvisible: counts.drawInvisible &+= 1
        case .drawNoRaster: counts.drawNoRaster &+= 1
        case .drawNoDrawable: counts.drawNoDrawable &+= 1
        case .drawNoPass: counts.drawNoPass &+= 1
        }
        scheduleChangeLocked()
    }

    /// Frame changes preserve the start of this uninterrupted visible lifetime.
    func row(nodeID: String, visible: Bool, hasFrame: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !visible {
            guard rows.removeValue(forKey: nodeID) != nil else { return }
        } else if var row = rows[nodeID] {
            guard row.hasFrame != hasFrame else { return }
            row.hasFrame = hasFrame
            rows[nodeID] = row
        } else {
            rows[nodeID] = Row(visibleSince: DispatchTime.now().uptimeNanoseconds, hasFrame: hasFrame)
        }
        scheduleChangeLocked()
    }

    /// Configuration and rows may arrive before the strip appears; nil keeps the current value.
    func configure(maxTextureSize: Int? = nil, screens: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        if let maxTextureSize, self.maxTextureSize != maxTextureSize {
            self.maxTextureSize = maxTextureSize
            changed = true
        }
        if let screens, self.screens != screens {
            self.screens = screens
            changed = true
        }
        if changed { scheduleChangeLocked() }
    }

    func clearRows() {
        lock.lock(); defer { lock.unlock() }
        guard !rows.isEmpty else { return }
        rows.removeAll(keepingCapacity: true)
        scheduleChangeLocked()
    }

    func setActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        if active {
            guard !self.active else { return }
            self.active = true
            scheduleChangeLocked()
        } else {
            self.active = false
            generation &+= 1
            scheduled?.cancel()
            scheduled = nil
            rows.removeAll(keepingCapacity: true)
            counts = Counts()
        }
    }

    /// Existing work also absorbs new events, so a burst allocates no per-event main-queue tasks.
    private func scheduleChangeLocked() {
        guard active, scheduled == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = lastSnapshotAt.map { max(now, $0 + Self.snapshotInterval) } ?? now
        scheduleLocked(at: deadline)
    }

    private func scheduleLocked(at deadline: UInt64) {
        guard active, scheduled == nil else { return }
        generation &+= 1
        let token = generation
        let work = DispatchWorkItem { [weak self] in self?.wake(token: token) }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: work)
    }

    private func wake(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard active, generation == token, scheduled != nil else { return }
        scheduled = nil
        let now = DispatchTime.now().uptimeNanoseconds
        var snapshot = Snapshot()
        snapshot.visible = rows.count
        snapshot.maxTextureSize = maxTextureSize
        snapshot.screens = screens
        snapshot.counts = counts
        var nextThreshold: UInt64?
        for row in rows.values {
            if row.hasFrame {
                snapshot.card += 1
            } else {
                let threshold = row.visibleSince + Self.staleInterval
                if now >= threshold {
                    snapshot.stale += 1
                } else {
                    nextThreshold = min(nextThreshold ?? threshold, threshold)
                }
            }
        }
        lastSnapshotAt = now
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            let numericText = snapshot.text
            text = numericText
            os_log(.debug, log: Self.log, "%{public}@", numericText)
        }
        // Past thresholds are not scheduled again: a stable stale row produces zero further wakes.
        if active, generation == token, let nextThreshold {
            scheduleLocked(at: max(nextThreshold, now + Self.snapshotInterval))
        }
    }
}

/// Only this leaf view observes the published string; message/card parents remain unsubscribed.
struct TutuChatDebugCounterStrip: View {
    @ObservedObject private var counters = TutuChatDebugCounters.shared

    var body: some View {
        Text(counters.text)
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.65))
            .fixedSize(horizontal: true, vertical: true)
            .allowsHitTesting(false)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .onAppear { counters.setActive(true) }
            .onDisappear { counters.setActive(false) }
    }
}
#endif
#endif
#endif
