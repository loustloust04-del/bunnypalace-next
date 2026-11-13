#if PERSONAL_APPS
#if os(iOS)
import Foundation

@MainActor
final class TutuChatAnimationDriver {
    var onFrame: ((Double) -> Void)?
    private var timer: DispatchSourceTimer?
    private var deadline = -Double.infinity
    private var generation: UInt64 = 0
    private(set) var frameCount = 0
    var isScheduled: Bool { timer != nil }

    func run(until deadline: Double) {
        self.deadline = max(self.deadline, deadline)
        guard timer == nil, ProcessInfo.processInfo.systemUptime < self.deadline else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        let token = generation
        source.schedule(deadline: .now() + 1.0 / 60, repeating: 1.0 / 60)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.timer != nil else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.frameCount += 1; self.onFrame?(now)
                if now >= self.deadline { self.stop() }
            }
        }
        timer = source
        source.resume()
    }
    func stop() {
        generation &+= 1
        timer?.cancel(); timer = nil; deadline = -.infinity
    }
    deinit { timer?.cancel() }
}
#endif
#endif
