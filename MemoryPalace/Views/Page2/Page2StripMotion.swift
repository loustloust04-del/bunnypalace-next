#if os(iOS)
import SwiftUI
import UIKit

@MainActor
@Observable
final class Page2StripMotion: NSObject {
    private(set) var progress: CGFloat = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var start: Double = 0
    @ObservationIgnored private var from: CGFloat = 0
    @ObservationIgnored private var target: CGFloat = 0
    @ObservationIgnored private var initialVelocity: CGFloat = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var animationGeneration = 0
    @ObservationIgnored private let spring = Spring(response: 0.36, dampingRatio: 0.86)
    @ObservationIgnored private var presentations: [UUID: (CGFloat) -> Void] = [:]
    @ObservationIgnored private(set) var lastSettleDuration: Double = 0

    func addPresentation(_ update: @escaping (CGFloat) -> Void) -> UUID {
        let id = UUID()
        presentations[id] = update
        return id
    }

    func removePresentation(_ id: UUID) { presentations[id] = nil }

    func beginDrag() -> CGFloat {
        stop()
        Page2SceneState.shared.stripTransitioning = true
        Page2StripPan.shared.setPagingLocked(true)
        return progress
    }

    func drag(to value: CGFloat) {
        publish(value)
    }

    func setOpen(_ open: Bool, animated: Bool, velocity: CGFloat = 0) {
        stop()
        target = open ? 1 : 0
        start = CACurrentMediaTime()
        Page2SceneState.shared.stripOpen = open
        guard animated, !UIAccessibility.isReduceMotionEnabled, abs(progress - target) > 0.0001 else {
            finish()
            return
        }
        Page2SceneState.shared.stripTransitioning = true
        Page2StripPan.shared.setPagingLocked(true)
        from = progress
        initialVelocity = min(max(velocity, -8), 8)
        animationGeneration = generation
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ sender: CADisplayLink) {
        guard sender === link, animationGeneration == generation else { return }
        if UIAccessibility.isReduceMotionEnabled { finish(); return }
        let elapsed = CACurrentMediaTime() - start
        let distance = target - from
        let value = from + spring.value(target: distance, initialVelocity: initialVelocity, time: elapsed)
        let velocity = spring.velocity(target: distance, initialVelocity: initialVelocity, time: elapsed)
        if elapsed >= 1 || (target == 0 && value <= 0) || (abs(value - target) < 0.0005 && abs(velocity) < 0.005) {
            finish()
        } else {
            publish(value)
        }
    }

    private func publish(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = min(max(value, 0), 1.2)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for update in Array(presentations.values) { update(progress) }
            CATransaction.commit()
        }
    }

    private func stop() {
        generation += 1
        link?.invalidate()
        link = nil
    }

    private func finish() {
        lastSettleDuration = max(0, CACurrentMediaTime() - start)
        stop()
        publish(target)
        Page2SceneState.shared.stripTransitioning = false
        Page2StripPan.shared.setPagingLocked(target > 0)
    }
}
#endif
