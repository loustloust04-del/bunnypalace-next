#if os(iOS)
import UIKit

final class Page2GestureDriver: NSObject, UIGestureRecognizerDelegate {
    var trace: ((String) -> Void)?
    var excludesTouchAt: (CGPoint) -> Bool = { _ in false }
    var excludesSearchAt: (CGPoint) -> Bool = { _ in false }
    var editing = false
    var library = false
    var enabled = true
    var available: () -> Bool = { true }
    var coordinateInset: CGFloat = 0
    var dockHeight: CGFloat = 0
    var location: Page2DragLocation?
    var isPaging: () -> Bool = { false }
    var isDragging: () -> Bool = { false }
    var pager: () -> UIScrollView? = { nil }
    var setOuterDragLock: (Bool, UUID, UIScrollView) -> Bool = { _, _, _ in false }
    var menuAt: (CGPoint) -> Page2DragTarget? = { _ in nil }
    var menuFor: ((UUID) -> UIMenu?)?
    var onPress: ((UIGestureRecognizer.State, CGPoint) -> Void)?
    var onPan: ((UIGestureRecognizer.State, CGPoint, CGSize, CGSize) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onSecondaryTap: ((CGPoint) -> Void)?
    var onSnapshot: ((UIImage?) -> Void)?
    /// 长按失效排查（粟粟 10-14 Air）：按下那一刻把外层状态拼进 trace，只在 PAGE2_UI_TOUCH_TRACE 开着时求值
    var probeState: (() -> String)?
    private(set) var target: Page2DragTarget?
    private weak var view: UIView?
    private weak var parentScroll: UIScrollView?
    private let primary = Page2PrimaryTouchRecognizer()
    private let search = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let secondary = UITapGestureRecognizer()
    private weak var secondaryPager: UIScrollView?
    private let outerLockID = UUID()
    private weak var lockedOuter: UIScrollView?
    private let menu = Page2TouchMenu()
    private var deliveredBegin = false

    var mayBeginPaging: Bool {
        menu.tracking || primary.touch == nil || primary.dragging || !primary.hasItem || (!editing && primary.elapsed < 0.32)
    }

    func attach(to view: UIView, outerScroll: UIScrollView? = nil) {
        if self.view == nil {
            self.view = view
            primary.coordinateView = view
            primary.trace = { [weak self] in self?.trace?($0) }
            primary.name = "page2.home.primary-touch"
            primary.addTarget(self, action: #selector(primaryChanged))
            primary.onTouchDown = { [weak self] point in
                guard let self else { return }
                self.target = self.menuAt(self.local(point))
                self.primary.editing = self.editing
                self.primary.hasItem = self.target != nil
                self.primary.hasMenu = false
                if self.editing && self.primary.hasItem { self.excludeSourceFromPaging() }
            }
            primary.onSecondaryEnd = { [weak self] in self?.rearmPaging(after: $0) }
            primary.onSecondaryTap = { [weak self] point in
                guard let self, self.isDragging(), self.location?.isLanding != true else { return }
                self.onSecondaryTap?(self.local(point))
            }
            menu.onBegin = { [weak self] target, start, point, image in self?.beginRawDrag(target, start: start, point: point, image: image) }
            menu.onMove = { [weak self] point, eventTime in
                guard let self else { return }
                self.updateRawLocation(point, eventTime: eventTime)
                self.onPress?(.changed, self.local(point))
            }
            menu.onEnd = { [weak self] state, point in
                guard let self else { return }
                if state == .ended { self.updateRawLocation(point) }
                self.onPress?(state, self.local(point))
                self.deliveredBegin = false
                self.synchronize()
            }
            secondary.addTarget(self, action: #selector(secondaryTapped))
            secondary.delegate = self
            secondary.cancelsTouchesInView = false
            search.name = "page2.home.drag-search"
            search.maximumNumberOfTouches = 1
            search.addTarget(self, action: #selector(searchChanged))
            tap.addTarget(self, action: #selector(tapped))
            tap.require(toFail: primary)
            tap.require(toFail: search)
            primary.delegate = self
            for recognizer in [search, tap] {
                recognizer.delegate = self
                recognizer.delaysTouchesBegan = false
                view.addGestureRecognizer(recognizer)
            }
        }
        menu.attach(to: view)
        installPrimary()
        DispatchQueue.main.async { [weak self] in self?.installPrimary() }
        if let outerScroll, outerScroll !== parentScroll {
            restoreOuterScrolling()
            outerScroll.panGestureRecognizer.require(toFail: primary)
            outerScroll.panGestureRecognizer.require(toFail: search)
            parentScroll = outerScroll
        }
        synchronize()
    }

    private func installPrimary() {
        guard let view else { return }
        let surface = view.window ?? view
        if primary.view !== surface { surface.addGestureRecognizer(primary) }
        if secondary.view !== surface { surface.addGestureRecognizer(secondary) }
        if let pager = pager(), secondaryPager !== pager {
            secondary.require(toFail: pager.panGestureRecognizer)
            secondaryPager = pager
        }
        menu.synchronize()
    }
    private func rearmPaging(after touch: UITouch) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isDragging() || self.primary.dragging, let window = self.view?.window else { return }
            var views: [UIView] = [window]
            while let view = views.popLast() {
                views.append(contentsOf: view.subviews)
                guard let scroll = view as? UIScrollView, scroll.panGestureRecognizer.name == "page2.paging",
                      !scroll.isDragging, !scroll.isDecelerating,
                      scroll.panGestureRecognizer.state != .began, scroll.panGestureRecognizer.state != .changed else { continue }
                self.trace?("PAGE rearm state=\(scroll.panGestureRecognizer.state.rawValue) width=\(scroll.bounds.width)")
                scroll.panGestureRecognizer.isEnabled = false
                scroll.panGestureRecognizer.isEnabled = true
            }
        }
    }

    func synchronize() {
        if menu.tracking, deliveredBegin, !isDragging() { menu.cancelTouchInput() }
        menu.enabled = enabled && !library
        menu.available = { [weak self] in self?.available() == true }
        menu.editing = editing
        menu.inset = coordinateInset
        menu.targetAt = { [weak self] in
            guard let self, !self.excludesTouchAt(self.local($0)) else { return nil }
            return self.menuAt(self.local($0))
        }
        menu.actions = { [weak self] in self?.menuFor?($0) }
        menu.canBegin = { [weak self] in self.map { !$0.isPaging() && !$0.isDragging() } ?? false }
        menu.trace = trace
        menu.synchronize()
        primary.isEnabled = enabled && !library && !menu.tracking
        search.isEnabled = enabled && !library && !menu.tracking
        tap.isEnabled = enabled && !library && !menu.tracking
        secondary.isEnabled = enabled && !library
        if menu.tracking, lockedOuter == nil, let parentScroll,
           setOuterDragLock(true, outerLockID, parentScroll) {
            lockedOuter = parentScroll
        } else if !menu.tracking, !isDragging() { restoreOuterScrolling() }
    }
    private func restoreOuterScrolling() {
        if let lockedOuter { setOuterDragLock(false, outerLockID, lockedOuter) }
        lockedOuter = nil
    }
    private func updateRawLocation(_ point: CGPoint, eventTime: TimeInterval? = nil) {
        guard let view, let window = view.window else { return }
        location?.update(local: local(point), window: view.convert(point, to: window), eventTime: eventTime)
    }
    private func beginRawDrag(_ target: Page2DragTarget, start: CGPoint, point: CGPoint, image: UIImage?) {
        self.target = target
        deliveredBegin = true
        onSnapshot?(target.snapshotRequired ? (image ?? capture(target.frame)) : nil)
        updateRawLocation(point)
        editing = true
        excludeSourceFromPaging()
        primary.isEnabled = false
        onPress?(.began, local(start))
        onPress?(.changed, local(point))
        synchronize()
    }
    @objc private func secondaryTapped() {
        guard secondary.state == .ended, menu.tracking, location?.isLanding != true else { return }
        onSecondaryTap?(local(secondary.location(in: view)))
    }

    func detach() {
        onPress = nil
        onPan = nil
        primary.isEnabled = false
        primary.view?.removeGestureRecognizer(primary)
        enabled = false
        view = nil
        menu.detach()
        secondary.view?.removeGestureRecognizer(secondary)
        restoreOuterScrolling()
        location?.cancelLanding()
    }

    func mayReceivePaging(_ touch: UITouch) -> Bool {
        if excludesTouchAt(local(touch.location(in: view))) { return false }
        let nativeSource = Page2TouchEvents.shared.activeSource(in: view?.window)
        if let nativeSource { return ObjectIdentifier(touch) != nativeSource }
        let sourceTouch = view?.window?.gestureRecognizers?.contains(where: { gesture in
            guard let owner = gesture as? Page2PrimaryTouchRecognizer else { return false }
            return owner.dragging && owner.touch === touch
        }) == true
        let allowed: Bool
        if sourceTouch { allowed = false }
        else if touch === primary.touch { allowed = !primary.hasItem || (!editing && !primary.active && !primary.dragging) }
        else if primary.touch == nil && editing { allowed = menuAt(local(touch.location(in: view))) == nil }
        else { allowed = true }
        trace?("PAGE receive=\(allowed) primary=\(touch === primary.touch) point=\(touch.location(in: view)) width=\(pager()?.bounds.width ?? 0)")
        return allowed
    }
    private func excludeSourceFromPaging() {
        guard let scroll = pager() else { return }
        for gesture in scroll.gestureRecognizers ?? [] where gesture.delegate === scroll {
            gesture.isEnabled = false; gesture.isEnabled = true
        }
    }

    @objc private func primaryChanged() {
        guard !menu.tracking, let location, primary.dragging || deliveredBegin else { return }
        let point = local(primary.point)
        location.update(local: point, window: primary.windowPoint)
        if primary.dragging && !deliveredBegin {
            if target != nil {
                if !menu.beginTracking() {
                    menu.cancelTouchInput()
                    primary.isEnabled = false
                    DispatchQueue.main.async { [weak self] in self?.synchronize() }
                }
                return
            }
            deliveredBegin = true
            onSnapshot?(target?.snapshotRequired == true ? target.flatMap { capture($0.frame) } : nil)
            editing = true
            excludeSourceFromPaging()
            onPress?(.began, local(primary.startPoint))
            location.update(local: point, window: primary.windowPoint)
            onPress?(.changed, point)
        } else {
            onPress?(primary.state, point)
        }
        if primary.state == .ended || primary.state == .cancelled || primary.state == .failed { deliveredBegin = false }
        synchronize()
    }

    @objc private func searchChanged() {
        let delta = search.translation(in: view)
        let velocity = search.velocity(in: view)
        onPan?(search.state, local(search.location(in: view)), CGSize(width: delta.x, height: delta.y), CGSize(width: velocity.x, height: velocity.y))
    }
    @objc private func tapped() { if tap.state == .ended && editing && !isDragging() { onTap?(local(tap.location(in: view))) } }
    private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: point.y - coordinateInset) }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let trace, recognizer === primary, primary.touch == nil {
            let point = local(touch.location(in: view))
            let target = menuAt(point)
            trace("PROBE press point=\(point) enabled=\(enabled) library=\(library) editing=\(editing) " +
                  "menu.enabled=\(menu.enabled) accepts=\(menu.acceptsTouchEvents) subscribed=\(menu.subscribed) tracking=\(menu.tracking) " +
                  "paging=\(isPaging()) dragging=\(isDragging()) target=\(target != nil) hasMenu=\(target.flatMap { menuFor?($0.id) } != nil) " +
                  "exclude=\(excludesTouchAt(point)) inView=\(view.map { touch.view?.isDescendant(of: $0) == true } ?? false) " +
                  "touchView=\(touch.view.map { String(describing: type(of: $0)) } ?? "nil") " +
                  "activation=\(view?.window?.windowScene?.activationState.rawValue ?? -9) source=\(Page2TouchEvents.shared.activeSource(in: view?.window) != nil) " +
                  (probeState?() ?? ""))
        }
        guard enabled, !library else { return false }
        if recognizer === secondary {
            guard let view else { return false }
            return menu.tracking && onSecondaryTap != nil && location?.isLanding != true &&
                ObjectIdentifier(touch) != menu.touchSourceID && touch.view?.isDescendant(of: view) == true
        }
        let point = local(touch.location(in: view))
        if excludesTouchAt(point) { return false }
        if recognizer === primary {
            if let window = view?.window {
                let y = touch.location(in: window).y
                if y < window.safeAreaInsets.top || y > window.bounds.height - window.safeAreaInsets.bottom { return false }
            }
            if primary.touch == nil {
                guard let view, touch.view?.isDescendant(of: view) == true else { return false }
                if Page2TouchEvents.shared.activeSource(in: view.window) != nil { return false }
                if !editing, let target = menuAt(point), menuFor?(target.id) != nil { return false }
                if view.window?.gestureRecognizers?.contains(where: { gesture in
                    guard let owner = gesture as? Page2PrimaryTouchRecognizer else { return false }
                    return owner !== primary && owner.dragging
                }) == true { return false }
            }
            trace?("receive primary existing=\(primary.touch != nil) drag=\(isDragging()) paging=\(isPaging()) point=\(point) type=\(touch.type.rawValue) phase=\(touch.phase.rawValue) id=\(ObjectIdentifier(touch))")
            if primary.touch != nil { return isDragging() && location?.isLanding != true }
            if isDragging() || location?.isLanding == true || isPaging() { return false }
        }
        if recognizer === search { return !editing && !isDragging() && !excludesSearchAt(point) }
        if recognizer === tap && (!editing || isDragging()) { return false }
        if editing, let target = menuAt(point) {
            let badge = CGRect(x: target.frame.minX - 19, y: target.frame.minY - 19, width: 44, height: 44)
            if badge.contains(point) { return false }
        } else if recognizer === tap { return false }
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === search {
            let velocity = search.velocity(in: view)
            return !editing && !isDragging() && velocity.y > abs(velocity.x)
        }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if recognizer === primary || other === primary {
            let partner = recognizer === primary ? other : recognizer
            if partner === parentScroll?.panGestureRecognizer || partner === search || partner === tap { return false }
            return partner.name == "page2.paging" && primary.dragging
        }
        return false
    }

    private func capture(_ frame: CGRect) -> UIImage? {
        guard let view, let window = view.window, frame.width > 0, frame.height > 0 else { return nil }
        let rect = view.convert(frame.offsetBy(dx: 0, dy: coordinateInset), to: window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        return UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds.offsetBy(dx: -rect.minX, dy: -rect.minY), afterScreenUpdates: false)
        }
    }
}

#endif
