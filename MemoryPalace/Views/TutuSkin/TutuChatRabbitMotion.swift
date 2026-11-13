#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import QuartzCore

/// chat11.js RAB/BLOOM, paint's ear table and fxDraw; no UIKit or persisted state.
struct TutuChatRabbitMotion {
    struct Sample: Equatable {
        let face: Int
        let earFrame: Int
        /// Source phone-space points, rounded as CSS translateY(toFixed(2)).
        let hop: Double
        /// CSS degrees, rounded as rotate(toFixed(2)).
        let bloomDegrees: Double
        let activeAnimation: Bool
        /// Absolute monotonic time. Only the delayed ear release needs a sleeping wake.
        let nextWake: TimeInterval?
    }

    private(set) var face = 0
    private(set) var responding = false
    private var raisedAt: TimeInterval?
    private var finishedAt: TimeInterval?
    private var tapAt: TimeInterval?
    private var swayAt: TimeInterval?
    private var settledEar = 0
    private static let downFrames = [7, 4, 3, 2, 1, 0]
    private static let highTapFrames = [8, 8, 7, 8, 7, 7]
    private static let lowTapFrames = [2, 3, 3, 2, 1, 0]

    mutating func setResponding(_ value: Bool, at time: TimeInterval) {
        guard responding != value else { return }
        responding = value
        if value {
            raisedAt = time
            finishedAt = nil
        } else {
            finishedAt = time
        }
    }

    mutating func tapRabbit(at time: TimeInterval) {
        face = (face + 1) % 3
        tapAt = time
        swayAt = time
    }

    mutating func tapBloom(at time: TimeInterval) { swayAt = time }

    /// Foreground/resume has no historical playback. Does not change the current face.
    mutating func settle(responding value: Bool, at time: TimeInterval) {
        responding = value
        settledEar = value ? 7 : 0
        raisedAt = nil
        finishedAt = nil
        tapAt = nil
        swayAt = nil
    }

    func sample(at time: TimeInterval) -> Sample {
        let up = raisedAt.map { (time - $0) / 0.55 }
        let down = finishedAt.map { (time - ($0 + 0.9)) / 0.5 }
        var ear = settledEar
        if let up, up >= 0 { ear = min(7, Int(floor(up * 8))) }
        if let down, down >= 0 {
            ear = down < 1 ? Self.downFrames[min(5, Int(floor(down * 6)))] : 0
        }
        let ht = tapAt.map { time - $0 } ?? -1
        let sw = swayAt.map { time - $0 } ?? -1
        let hop = ht >= 0 && ht < 0.32 ? -5 * sin(.pi * ht / 0.32) : 0
        if ht >= 0 && ht < 0.42 {
            let k = min(5, Int(floor(ht / 0.07)))
            ear = ear >= 6 ? Self.highTapFrames[k] : min(7, ear + Self.lowTapFrames[k])
        }
        let ws = sw >= 0 && sw < 1.7 ? 7 * exp(-sw * 2.6) * sin(sw * 9.5) : 0
        // kick deliberately keeps the original .45/1.75 tails, not just visible motion.
        let tapBusy = ht >= 0 && ht < 0.45
        let swayBusy = sw >= 0 && sw < 1.75
        let beforeDown = down.map { $0 < 0 } ?? true
        let upBusy = up.map { $0 >= 0 && $0 < 1 && beforeDown } ?? false
        let downBusy = down.map { $0 >= 0 && $0 < 1 } ?? false
        let wake = finishedAt.flatMap { time < $0 + 0.9 ? $0 + 0.9 : nil }
        return Sample(face: face, earFrame: ear,
                      hop: (hop * 100).rounded() / 100,
                      bloomDegrees: ((9 + ws) * 100).rounded() / 100,
                      activeAnimation: tapBusy || swayBusy || upBusy || downBusy,
                      nextWake: wake)
    }
}

/// Actual production scheduler, also runnable by the stripped Mac offscreen harness.
/// Active ticks share the chat clock; delayed ear release owns one cancellable wake.
@MainActor
final class TutuChatRabbitDriver {
    private(set) var motion = TutuChatRabbitMotion()
    private(set) var sampleCount: UInt64 = 0
    private(set) var frameCallbackCount: UInt64 = 0
    private(set) var wakeCount: UInt64 = 0
    private(set) var pendingWake: TimeInterval?
    private(set) var running = false
    var onSample: ((TutuChatRabbitMotion.Sample) -> Void)?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var work: DispatchWorkItem?
    private var generation: UInt64 = 0
    private let frames = TutuChatAnimationDriver()

    init() {
        frames.onFrame = { [weak self] _ in
            guard let self, self.running else { return }
            self.frameCallbackCount &+= 1
            self.drawAndSchedule()
        }
    }

    func reset(responding: Bool) {
        cancel()
        motion = TutuChatRabbitMotion()
        motion.settle(responding: responding, at: now())
        running = true
        drawAndSchedule()
    }

    func setResponding(_ value: Bool) {
        guard running else { return }
        motion.setResponding(value, at: now())
        drawAndSchedule()
    }

    func tapRabbit() {
        guard running else { return }
        motion.tapRabbit(at: now())
        drawAndSchedule()
    }

    func tapBloom() {
        guard running else { return }
        motion.tapBloom(at: now())
        drawAndSchedule()
    }

    func resume(responding: Bool) {
        cancel()
        motion.settle(responding: responding, at: now())
        running = true
        drawAndSchedule()
    }

    func stop() { cancel(); running = false }

    private func cancel() {
        generation &+= 1
        frames.stop()
        work?.cancel()
        work = nil
        pendingWake = nil
    }

    private func drawAndSchedule() {
        generation &+= 1
        work?.cancel(); work = nil; pendingWake = nil
        guard running else { return }
        let time = now(), sample = motion.sample(at: time)
        sampleCount &+= 1
        onSample?(sample)
        guard running else { return }
        if sample.activeAnimation {
            pendingWake = time + 1 / 60
            frames.run(until: .infinity)
            return
        }
        frames.stop()
        guard let deadline = sample.nextWake else { return }
        pendingWake = deadline
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == token else { return }
                self.work = nil; self.pendingWake = nil
                self.wakeCount &+= 1
                self.drawAndSchedule()
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - time), execute: item)
    }

    deinit { work?.cancel() }
}

/// UIKit-free sprite compositor shared by the app and Mac CALayer offscreen comparisons.
final class TutuChatRabbitLayers {
    let root = CALayer()
    let rabbit = CALayer()
    let bloom = CALayer()
    private let bloomImage = CALayer()
    private(set) var scale: CGFloat = 1
    private(set) var fieldTop: CGFloat = 0
    private(set) var originX: CGFloat = 0
    private var lastSample = TutuChatRabbitMotion().sample(at: 0)

    init(rabbit image: CGImage, bloom flower: CGImage) {
        rabbit.contents = image
        rabbit.contentsGravity = .resize
        bloomImage.contents = flower
        bloomImage.contentsGravity = .resize
        bloom.addSublayer(bloomImage)
        bloom.anchorPoint = CGPoint(x: 0.5, y: 0.92)
        root.addSublayer(bloom)
        root.addSublayer(rabbit)
    }

    func layout(width: CGFloat, fieldTop: CGFloat, originX: CGFloat = 0) {
        scale = width / 420
        self.fieldTop = fieldTop
        self.originX = originX
        apply(lastSample)
    }

    func apply(_ sample: TutuChatRabbitMotion.Sample) {
        lastSample = sample
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rabbit.bounds = CGRect(x: 0, y: 0, width: 120 * scale, height: 120 * scale)
        rabbit.position = CGPoint(x: originX + 350 * scale,
                                  y: fieldTop + (12.7 - 93.6 + 60 + sample.hop) * scale)
        rabbit.contentsRect = CGRect(x: Double(sample.earFrame) / 9, y: Double(sample.face) / 3,
                                     width: 1.0 / 9, height: 1.0 / 3)
        let h = 35.0 * 114 / 120
        bloom.bounds = CGRect(x: 0, y: 0, width: 35 * scale, height: h * scale)
        // CSS backgrounds snap their paint rect before DPR/transform; the layout box and pivot do not snap.
        let sourceTop = fieldTop / scale - 9.8 - h / 2
        let paintTop = floor(sourceTop + 0.5)
        bloomImage.frame = CGRect(x: 0, y: (paintTop - sourceTop) * scale, width: 35 * scale,
                                  height: (floor(sourceTop + h + 0.5) - paintTop) * scale)
        bloom.position = CGPoint(x: originX + 303.5 * scale,
                                 y: fieldTop + (-9.8 + h * 0.42) * scale)
        bloom.setAffineTransform(CGAffineTransform(rotationAngle: sample.bloomDegrees * .pi / 180))
        CATransaction.commit()
    }

    enum Hit { case rabbit, bloom }

    func hit(at point: CGPoint) -> Hit? {
        let rabbitHit = CGRect(x: originX + 323 * scale, y: fieldTop - 71.3 * scale,
                               width: 84 * scale, height: 72 * scale)
        if rabbitHit.contains(point) { return .rabbit }
        let local = bloom.convert(point, from: root)
        return bloom.bounds.contains(local) ? .bloom : nil
    }
}
#endif
#endif
