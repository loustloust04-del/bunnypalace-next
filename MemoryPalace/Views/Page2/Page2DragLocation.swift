#if os(iOS)
import UIKit

@MainActor
final class Page2DragLocation {
    weak var coordinateView: UIView?
    var coordinateInset: CGFloat = 0
    func windowPoint(for point: CGPoint) -> CGPoint? {
        guard let view = coordinateView, let window = view.window else { return nil }
        return view.convert(CGPoint(x: point.x, y: point.y + coordinateInset), to: window)
    }
    var localPoint: CGPoint = .zero
    private(set) var windowPoint: CGPoint = .zero
    private(set) var eventTime: TimeInterval?
    private var owner: UUID?
    private var handler: (() -> Void)?
    private(set) var isLanding = false
    private(set) var landingID: UUID?
    private(set) var landingScale: CGFloat = 1
    private(set) var absorbing = false
    private var landingCompletion: (() -> Void)?

    func update(local: CGPoint, window: CGPoint, eventTime: TimeInterval? = nil) {
        guard !isLanding else { return }
        localPoint = local
        windowPoint = window
        self.eventTime = eventTime
        handler?()
    }
    func land(at point: CGPoint, scale: CGFloat = 1, absorbing: Bool = false, completion: @escaping () -> Void) {
        guard handler != nil else { completion(); return }
        windowPoint.x += point.x - localPoint.x
        windowPoint.y += point.y - localPoint.y
        localPoint = point
        isLanding = true
        landingScale = scale
        self.absorbing = absorbing
        landingID = UUID()
        landingCompletion = completion
        handler?()
    }
    func completeLanding(owner: UUID, request: UUID) {
        guard self.owner == owner, landingID == request, isLanding else { return }
        let completion = landingCompletion
        landingCompletion = nil
        isLanding = false
        landingID = nil
        completion?()
    }
    func cancelLanding() {
        landingCompletion = nil; isLanding = false; landingID = nil
        landingScale = 1; absorbing = false
    }

    func observe(owner: UUID, handler: @escaping () -> Void) {
        self.owner = owner
        self.handler = handler
        handler()
    }
    func removeObserver(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        handler = nil
    }
}


#endif
