#if os(iOS)
import UIKit

@MainActor
final class Page2TouchMenu: NSObject, Page2TouchEventConsumer, UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    weak var touchView: UIView?
    var enabled = false
    var available: () -> Bool = { true }
    var editing = false
    var inset: CGFloat = 0
    var targetAt: (CGPoint) -> Page2DragTarget? = { _ in nil }
    var actions: (UUID) -> UIMenu? = { _ in nil }
    var canBegin: () -> Bool = { true }
    var onBegin: (Page2DragTarget, CGPoint, CGPoint, UIImage?) -> Void = { _, _, _, _ in }
    var onMove: (CGPoint, TimeInterval) -> Void = { _, _ in }
    var onEnd: (UIGestureRecognizer.State, CGPoint) -> Void = { _, _ in }
    var trace: ((String) -> Void)?
    private(set) var tracking = false
    var acceptsTouchEvents: Bool { enabled && available() }
    var touchSourceID: ObjectIdentifier? { candidate?.id }
    var subscribed: Bool { subscription != nil }
    private struct Candidate {
        let id: ObjectIdentifier
        let generation = UUID()
        let start: CGPoint
        let timestamp: TimeInterval
        let target: Page2DragTarget
        var point: CGPoint
        var configured = false
        var dragReadyAt: TimeInterval?
    }
    private var candidate: Candidate?
    private var deadline: DispatchWorkItem?
    private var subscription: UUID?
    private var windowID: ObjectIdentifier?
    private var presentation: String?
    private var displayedAt: TimeInterval?
    private var previewView: UIView?
    private var sourceImage: UIImage?
    private var previewTarget: Page2DragTarget?
    private lazy var context = UIContextMenuInteraction(delegate: self)
    private lazy var dragInteraction = UIDragInteraction(delegate: self)
    private lazy var dropInteraction = UIDropInteraction(delegate: self)

    func attach(to view: UIView) {
        if touchView !== view {
            detach()
            touchView = view
            view.addInteraction(dragInteraction)
            view.addInteraction(dropInteraction)
        }
        synchronize()
    }
    func synchronize() {
        let currentWindow = touchView?.window.map(ObjectIdentifier.init)
        if windowID != currentWindow {
            cancelTouchInput()
            if let subscription { Page2TouchEvents.shared.unsubscribe(subscription) }
            subscription = nil
            windowID = currentWindow
        }
        if enabled, currentWindow != nil {
            if subscription == nil { subscription = Page2TouchEvents.shared.subscribe(self) }
        } else {
            cancelTouchInput()
            if let subscription { Page2TouchEvents.shared.unsubscribe(subscription) }
            subscription = nil
        }
        let showsContext = enabled && available() && !editing && !tracking
        dragInteraction.isEnabled = showsContext
        if showsContext, let view = touchView, context.view !== view {
            view.addInteraction(context)
        } else if !showsContext, context.view != nil {
            context.dismissMenu()
            touchView?.removeInteraction(context)
            presentation = nil; displayedAt = nil
            deadline?.cancel(); deadline = nil
            if candidate == nil { clearPreview() }
        }
    }
    func detach() {
        cancelTouchInput()
        if let subscription { Page2TouchEvents.shared.unsubscribe(subscription) }
        subscription = nil
        context.dismissMenu()
        for interaction in [context as UIInteraction, dragInteraction, dropInteraction] { touchView?.removeInteraction(interaction) }
        touchView = nil
        windowID = nil
    }
    func cancelTouchInput() {
        let point = candidate?.point ?? .zero
        let active = tracking
        clearCandidate()
        if active { onEnd(.cancelled, point) }
    }
    private func clearCandidate() {
        deadline?.cancel(); deadline = nil
        candidate = nil
        tracking = false
        if presentation == nil { clearPreview() }
        if let subscription { Page2TouchEvents.shared.release(subscription) }
    }
    func receiveTouchSamples(_ samples: [Page2TouchSample]) {
        guard enabled, let view = touchView, let window = view.window else { return }
        if let source = candidate {
            guard let sample = samples.first(where: { $0.id == source.id }) else { return }
            let point = view.convert(sample.windowPoint, from: window)
            candidate?.point = point
            if sample.phase == .ended || sample.phase == .cancelled {
                let active = tracking
                trace?("raw end phase=\(sample.phase.rawValue) point=\(point)")
                clearCandidate()
                if active { onEnd(sample.phase == .ended ? .ended : .cancelled, point) }
                return
            }
            if sample.phase == .moved {
                if !tracking, !editing, source.configured,
                   CACurrentMediaTime() >= (source.dragReadyAt ?? 0), sample.timestamp - source.timestamp >= 0.7,
                   hypot(point.x - source.start.x, point.y - source.start.y) > 18 { _ = beginTracking() }
                if tracking { onMove(point, sample.timestamp) }
            }
            return
        }
        guard !tracking, canBegin() else { return }
        let starts = samples.filter { $0.phase == .began && $0.beganInside }.sorted { $0.timestamp < $1.timestamp }
        for sample in starts {
            let point = view.convert(sample.windowPoint, from: window)
            guard let target = targetAt(point) else { continue }
            candidate = Candidate(id: sample.id, start: point, timestamp: sample.timestamp, target: target, point: point)
            sourceImage = nil
            trace?("raw source id=\(sample.id) point=\(point)")
            break
        }
    }
    @discardableResult
    func beginTracking() -> Bool {
        guard !tracking, enabled, available(), canBegin(), let candidate, let view = touchView, let window = view.window,
              window.windowScene?.activationState == .foregroundActive, let subscription, targetAt(candidate.start)?.id == candidate.target.id,
              Page2TouchEvents.shared.claim(candidate.id, window: window, token: subscription) else { return tracking }
        deadline?.cancel(); deadline = nil
        tracking = true
        trace?("raw begin point=\(candidate.point)")
        onBegin(candidate.target, candidate.start, candidate.point, sourceImage)
        context.dismissMenu()
        return true
    }
    private func scheduleHold() {
        deadline?.cancel()
        guard !editing, let candidate, let displayedAt else { return }
        let generation = candidate.generation
        let time = max(candidate.timestamp + 2.8, displayedAt + 2)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.candidate?.generation == generation, self.presentation != nil else { return }
            _ = self.beginTracking()
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, time - CACurrentMediaTime()), execute: work)
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation point: CGPoint) -> UIContextMenuConfiguration? {
        guard enabled, !editing, !tracking, canBegin(), let target = targetAt(point), let menu = actions(target.id) else { return nil }
        let id = UUID().uuidString
        presentation = id
        displayedAt = nil
        previewTarget = target
        if candidate?.target.id == target.id { candidate?.configured = true }
        sourceImage = capture(target.frame.offsetBy(dx: 0, dy: inset))
        previewView = touchView?.resizableSnapshotView(from: target.visibleFrame.offsetBy(dx: 0, dy: inset), afterScreenUpdates: false, withCapInsets: .zero)
        if previewView == nil, let image = capture(target.visibleFrame.offsetBy(dx: 0, dy: inset)) { previewView = UIImageView(image: image) }
        trace?("system menu configured")
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in menu }
    }
    private func preview() -> UITargetedPreview? {
        guard let view = touchView, let target = previewTarget, let previewView else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: previewView.bounds, cornerRadius: min(24, previewView.bounds.width * 0.26))
        let frame = target.visibleFrame.offsetBy(dx: 0, dy: inset)
        return UITargetedPreview(view: previewView, parameters: parameters, target: UIPreviewTarget(container: view, center: CGPoint(x: frame.midX, y: frame.midY)))
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? { preview() }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? { tracking ? nil : preview() }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        guard configuration.identifier as? String == presentation else { return }
        displayedAt = CACurrentMediaTime()
        candidate?.dragReadyAt = CACurrentMediaTime() + 0.18
        trace?("system menu displayed")
        scheduleHold()
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        guard configuration.identifier as? String == presentation else { return }
        presentation = nil; displayedAt = nil
        trace?("system menu ended tracking=\(tracking)")
        deadline?.cancel(); deadline = nil
        if candidate == nil { clearPreview() }
    }
    private func clearPreview() {
        previewView = nil
        previewTarget = nil
        sourceImage = nil
    }
    private func capture(_ frame: CGRect) -> UIImage? {
        guard let view = touchView, frame.width > 0, frame.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: frame.size).image { _ in
            view.drawHierarchy(in: view.bounds.offsetBy(dx: -frame.minX, dy: -frame.minY), afterScreenUpdates: false)
        }
    }
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        trace?("native prepare enabled=\(enabled) editing=\(editing) tracking=\(tracking) candidate=\(candidate != nil) canBegin=\(canBegin())")
        guard enabled, !editing, !tracking, canBegin(), let candidate else { return [] }
        trace?("native drag prepared")
        let item = UIDragItem(itemProvider: NSItemProvider(object: candidate.target.id.uuidString as NSString))
        return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        guard let view = touchView, let target = previewTarget, let previewView else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: previewView.bounds, cornerRadius: min(24, previewView.bounds.width * 0.26))
        let frame = target.visibleFrame.offsetBy(dx: 0, dy: inset)
        return UITargetedDragPreview(view: previewView, parameters: parameters, target: UIDragPreviewTarget(container: view, center: CGPoint(x: frame.midX, y: frame.midY)))
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) { trace?("native drag began"); _ = beginTracking() }
    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool { session.localDragSession != nil && tracking }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal { UIDropProposal(operation: tracking ? .move : .cancel) }
}
#endif
