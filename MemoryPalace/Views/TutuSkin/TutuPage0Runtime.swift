#if PERSONAL_APPS
#if os(iOS)
import Foundation
import QuartzCore

protocol TutuPage0FrameClock: AnyObject {
    var isRunning: Bool { get }
    var framesPerSecond: Int { get set }
    func start(_ callback: @escaping (Double) -> Void)
    func stop()
}

/// Shared with the host smoke test: only an explicit lifecycle retry or a new
/// size may leave failed state; stale resource/GPU completions cannot do so.
struct TutuPage0ResourceState {
    enum Status { case empty, preparing, ready, failed, disposed }
    private(set) var status = Status.empty
    private(set) var generation = 0
    private var wasEligible = false

    mutating func beginPreparation() -> Int? {
        guard status != .disposed else { return nil }
        generation += 1; status = .preparing
        return generation
    }

    mutating func retryPreparation() -> Int? {
        guard status == .failed else { return nil }
        return beginPreparation()
    }

    mutating func updateEligibility(_ eligible: Bool) -> Int? {
        let entered = eligible && !wasEligible
        wasEligible = eligible
        return entered ? retryPreparation() : nil
    }

    mutating func completePreparation(_ generation: Int) -> Bool {
        guard self.generation == generation, status == .preparing else { return false }
        status = .ready
        return true
    }

    mutating func fail(_ generation: Int) -> Bool {
        guard self.generation == generation, status == .preparing || status == .ready else { return false }
        status = .failed
        return true
    }

    mutating func dispose() {
        generation += 1; status = .disposed
    }
}

final class TutuPage0Runtime {
    struct Counts {
        var callbacks = 0
        var physicsSteps = 0
        var frameRequests = 0
    }
    var model = TutuPage0Model()
    var beforeFrame: (() -> Void)?
    var isInteracting = false {
        didSet { if isInteracting { clock.framesPerSecond = 60 } }
    }
    private(set) var isRunning = false
    private(set) var idle = false
    private(set) var counts = Counts()
    private let clock: TutuPage0FrameClock
    private let draw: (TutuPage0Model) -> Void
    private var idleTimer: Timer?
    private var previousFrame: Double?
    private var lastInput = 0.0
    private var lastTouchInput = 0.0
    private var touchTransient = false

    init(clock: TutuPage0FrameClock, draw: @escaping (TutuPage0Model) -> Void) {
        self.clock = clock; self.draw = draw
    }

    func start(open: Bool) {
        guard !isRunning else { return }
        isRunning = true; idle = false; isInteracting = false; touchTransient = false
        model = TutuPage0Model(open: open)
        lastInput = CACurrentMediaTime()
        draw(model); counts.frameRequests += 1
        armIdle(); wake()
    }

    func stop() {
        isRunning = false; isInteracting = false
        clock.stop(); previousFrame = nil
        idleTimer?.invalidate(); idleTimer = nil
    }

    func receiveInput() {
        lastInput = CACurrentMediaTime(); idle = false; touchTransient = true
        lastTouchInput = lastInput
        armIdle(); wake()
    }

    func receiveTilt(_ target: TutuPage0Vector) {
        lastInput = CACurrentMediaTime(); idle = false
        model.target = target
        armIdle()
    }

    func wake() {
        guard isRunning else { return }
        clock.framesPerSecond = isInteracting || touchTransient ? 60 : 30
        guard !clock.isRunning else { return }
        previousFrame = CACurrentMediaTime()
        clock.start { [weak self] timestamp in self?.frame(timestamp) }
    }

    private func armIdle() {
        idleTimer?.invalidate()
        guard isRunning else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, 4 - (CACurrentMediaTime() - lastInput)), repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.idleTimer = nil
            if self.isInteracting { self.lastInput = CACurrentMediaTime(); self.armIdle(); return }
            self.idle = true
        }
    }

    private func frame(_ timestamp: Double) {
        guard isRunning else { return }
        counts.callbacks += 1
        let dt = max(0, timestamp - (previousFrame ?? timestamp))
        previousFrame = timestamp
        beforeFrame?()
        let oldTime = model.time
        model.advance(dt: dt, idle: idle)
        counts.physicsSteps += Int(((model.time - oldTime) * 60).rounded())
        draw(model); counts.frameRequests += 1
        guard isRunning else { return }
        if touchTransient && !isInteracting {
            let steady = TutuPage0SteadyState(idle: idle, target: model.target, shown: model.pull.shown)
            if timestamp - lastTouchInput >= 4 || model.isConverged(to: steady, dt: dt) { touchTransient = false }
        }
        clock.framesPerSecond = isInteracting || touchTransient ? 60 : 30
    }
}
#endif
#endif
