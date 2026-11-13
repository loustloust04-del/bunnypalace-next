#if PERSONAL_APPS
#if os(iOS)
import CoreMotion
import Foundation

@MainActor
final class TutuMotion {
    struct Sample {
        var tilt: SIMD2<Float>
        var unlockTilt: Double
        var acceleration: SIMD3<Double>
        var time: Double
    }
    var onSample: ((Sample) -> Void)?
    private let manager = CMMotionManager()
    private var baseline: SIMD2<Double>?
    private var running = false

    func start() {
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        baseline = nil
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                // DeviceOrientation beta/gamma are rotations about device x/y.
                // CoreMotion pitch/roll are the corresponding radian quantities.
                let angles = SIMD2(motion.attitude.roll, motion.attitude.pitch)
                var base = self.baseline ?? angles
                base += (angles - base) * 0.004
                self.baseline = base
                let delta = angles - base
                let tilt = SIMD2<Float>(Float(min(0.32, max(-0.32, delta.x * 1.2))),
                                        Float(min(0.24, max(-0.24, delta.y))))
                let a = motion.userAcceleration
                self.onSample?(Sample(tilt: tilt,
                                      unlockTilt: min(0.4, max(-0.4, delta.x * 1.2)),
                                      acceleration: SIMD3(a.x, a.y, a.z) * 9.81, time: motion.timestamp))
            }
        }
    }

    func stop() {
        running = false
        manager.stopDeviceMotionUpdates()
        baseline = nil
    }

    deinit { manager.stopDeviceMotionUpdates() }
}
#endif
#endif
