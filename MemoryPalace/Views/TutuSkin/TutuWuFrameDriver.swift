#if PERSONAL_APPS
#if os(iOS)
import Foundation
import QuartzCore

final class TutuWuFrameDriver {
    private final class Target: NSObject {
        weak var owner: TutuWuFrameDriver?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }

    private let target = Target()
    private let makeDisplayLink: (Any, Selector) -> CADisplayLink
    private let onFrame: () -> Void
    private var link: CADisplayLink?
    private(set) var callbackCount = 0

    init(makeDisplayLink: @escaping (Any, Selector) -> CADisplayLink, onFrame: @escaping () -> Void) {
        self.makeDisplayLink = makeDisplayLink
        self.onFrame = onFrame
        target.owner = self
    }

    func request() {
        if link == nil {
            let created = makeDisplayLink(target, #selector(Target.tick(_:)))
            created.isPaused = true
            created.add(to: .main, forMode: .common)
            link = created
        }
        link?.isPaused = false
    }

    private func tick(_ link: CADisplayLink) {
        link.isPaused = true
        callbackCount += 1
        onFrame()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    deinit { link?.invalidate() }
}
#endif
#endif
