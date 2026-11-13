#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import UIKit

struct TutuPage0Background: View {
    @Environment(\.scenePhase) private var scenePhase
    var cardHeight = 609.0
    var body: some View {
        GeometryReader { geometry in
            TutuPage0Surface(active: SkinState.shared.active && Page0Stage.shared.isOnScreen && scenePhase == .active,
                             hour: TutuClock.hour(for: SkinState.shared.timeOfDay),
                             glass: SkinState.shared.page0Style == .glass, cardHeight: cardHeight)
                .frame(width: geometry.size.width, height: geometry.size.width * 874 / 402, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

private struct TutuPage0Surface: UIViewRepresentable {
    var active: Bool
    var hour: Double
    var glass: Bool
    var cardHeight: Double
    func makeUIView(context: Context) -> TutuPage0Canvas { TutuPage0Canvas() }
    func updateUIView(_ view: TutuPage0Canvas, context: Context) -> Void {
        view.configure(active: active, hour: hour, glass: glass, cardHeight: cardHeight)
    }
    static func dismantleUIView(_ view: TutuPage0Canvas, coordinator: ()) { view.dispose() }
}

/// Observes its page0 hosting ancestor, never the window or the paging container.
/// The canvas itself is transparent to hit testing; the real Sidebar stays intact.
private final class TutuPage0Canvas: UIView, UIGestureRecognizerDelegate {
    private let artwork: TutuPage0Layers
    private let motion = TutuMotion()
    private let runtime: TutuPage0Runtime
    private var model: TutuPage0Model {
        get { runtime.model }
        set { runtime.model = newValue }
    }
    private var arbitration = TutuPage0Arbitration()
    private weak var gestureHost: UIView?
    private weak var scroll: UIScrollView?
    private var savedBounces: Bool?
    private weak var savedRefresh: UIRefreshControl?
    private var savedRefreshEnabled: Bool?
    private var pan: TutuPage0Pan?
    private var pullTap: UITapGestureRecognizer?
    private var dayTimer: Timer?, hourTimer: Timer?
    private var requestedActive = false
    private let errorLabel = UILabel()
    private var running: Bool { runtime.isRunning }
    private var foreground = UIApplication.shared.applicationState == .active
    private var disposed = false
    private var acceptedTilt = TutuPage0Vector()
    private var startTarget = TutuPage0Vector()
    private var startPoint = TutuPage0Vector()
    private var touchTime = 0.0
    private var grabbedPull = false
    private var grabbedCloth = false
    private var hour = 12.0
    private var cardHeight = 609.0

    init() {
        let artwork = TutuPage0Layers()
        self.artwork = artwork
        runtime = TutuPage0Runtime(clock: TutuPage0DisplayClock(), draw: artwork.draw)
        super.init(frame: .zero)
        isOpaque = false
        layer.addSublayer(artwork.root)
        errorLabel.textColor = .white; errorLabel.numberOfLines = 0
        errorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        errorLabel.isHidden = true
        addSubview(errorLabel)
        runtime.beforeFrame = { [weak self] in
            guard let self, self.runtime.isInteracting else { return }
            self.updateDrag()
        }
        artwork.onError = { [weak self] error in
            guard let self, !self.disposed else { return }
            self.stop()
            self.errorLabel.text = error.localizedDescription
            self.errorLabel.isHidden = false
        }
        artwork.onReady = { [weak self] in
            guard let self, !self.disposed else { return }
            self.errorLabel.isHidden = true
            self.updateRunning()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(permissionChanged), name: Notification.Name("tutuPage0InputChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetDay), name: Notification.Name("tutuPage0Reset"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resign), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: UIApplication.significantTimeChangeNotification, object: nil)
        motion.onSample = { [weak self] sample in
            guard let self, self.running, self.pan?.state != .began, self.pan?.state != .changed else { return }
            let target = TutuPage0Vector(Double(sample.tilt.x), Double(sample.tilt.y))
            guard max(abs(target.x - self.acceptedTilt.x), abs(target.y - self.acceptedTilt.y)) >= 0.002 else { return }
            self.acceptedTilt = target
            self.runtime.receiveTilt(target)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    func configure(active: Bool, hour: Double, glass: Bool, cardHeight: Double) {
        requestedActive = active
        self.hour = hour; self.cardHeight = cardHeight
        artwork.configure(hour: hour, glass: glass, cardHeight: cardHeight)
        updateRunning()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { artwork.updateEligibility(false); stop(); uninstallGesture() }
        else {
            installGesture()
            // SwiftUI can finish building the responder chain after didMoveToWindow.
            DispatchQueue.main.async { [weak self] in self?.installGesture(); self?.updateRunning() }
            updateRunning()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        errorLabel.frame = bounds.insetBy(dx: 24, dy: 80)
        guard artwork.root.bounds.size != bounds.size else { return }
        finishGesture()
        artwork.root.position = CGPoint(x: bounds.midX, y: bounds.midY)
        artwork.layout(size: bounds.size, scale: window?.screen.scale ?? traitCollection.displayScale)
        artwork.draw(model)
        installGesture(); updateRunning()
        if running { wake() }
    }
    private func installGesture() {
        guard window != nil, !disposed else { return }
        var responder: UIResponder? = next
        var host: UIView?
        while let current = responder {
            if let controller = current as? UIViewController {
                // The first controller is Sidebar's page hosting controller.
                // Never climb through the pager to the app/window host.
                guard !(controller is PagingViewController),
                      !controller.children.contains(where: { $0 is PagingViewController }) else { return }
                host = controller.view; break
            }
            responder = current.next
        }
        guard let host, !(host is UIWindow), host !== self, host.bounds.width <= bounds.width + 2 else { return }
        if gestureHost === host { return }
        uninstallGesture()
        let recognizer = TutuPage0Pan(target: self, action: #selector(drag(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false; recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        host.addGestureRecognizer(recognizer)
        let tap = UITapGestureRecognizer()
        tap.cancelsTouchesInView = true
        tap.require(toFail: recognizer)
        tap.delegate = self
        host.addGestureRecognizer(tap)
        pullTap = tap
        gestureHost = host; pan = recognizer
    }
    private func uninstallGesture() {
        finishGesture()
        if let pan { gestureHost?.removeGestureRecognizer(pan) }
        if let pullTap { gestureHost?.removeGestureRecognizer(pullTap) }
        pan = nil; pullTap = nil; gestureHost = nil
    }
    func dispose() {
        guard !disposed else { return }
        disposed = true; stop(); uninstallGesture(); artwork.dispose()
        NotificationCenter.default.removeObserver(self)
        motion.onSample = nil
    }
    private var allowed: Bool { running && PagingViewController.tutuPage0InputAllowed }
    private func updateRunning() {
        guard !disposed else { return }
        let shouldRun = requestedActive && foreground && window != nil && bounds.width > 0 && PagingViewController.tutuPage0InputAllowed
        artwork.updateEligibility(shouldRun)
        guard shouldRun, !artwork.hasFailed else {
            if running { stop() }
            return
        }
        guard !running else { return }
        acceptedTilt = .init()
        artwork.setActive(true)
        runtime.start(open: SkinState.shared.page0IsOpen())
        guard running else { return }
        motion.start(); armDay(); armHour()
    }
    private func stop() {
        finishGesture()
        runtime.stop()
        artwork.setActive(false)
        for timer in [dayTimer, hourTimer] { timer?.invalidate() }
        dayTimer = nil; hourTimer = nil
        motion.stop()
    }
    @objc private func permissionChanged() { updateRunning() }
    @objc private func resign() { foreground = false; updateRunning() }
    @objc private func resume() { foreground = true; updateRunning() }
    @objc private func resetDay() {
        finishGesture(persist: false)
        model.setOpen(false)
        if running { wake(); armDay() } else { artwork.draw(model) }
    }
    @objc private func clockChanged() {
        if !SkinState.shared.page0IsOpen() && model.openTarget != 0 { resetDay() }
        refreshHour(); if running { armDay(); armHour() }
    }
    private func armDay() {
        dayTimer?.invalidate()
        guard running else { return }
        let delay = max(0.05, SkinState.nextPage0Reset(after: Date()).timeIntervalSinceNow)
        dayTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockChanged() }
        }
    }
    private func refreshHour() {
        hour = TutuClock.hour(for: SkinState.shared.timeOfDay)
        artwork.configure(hour: hour, glass: SkinState.shared.page0Style == .glass, cardHeight: cardHeight)
    }
    private func armHour() {
        hourTimer?.invalidate()
        guard running, SkinState.shared.timeOfDay == .now else { return }
        let calendar = Calendar.current
        let now = Date()
        let next = calendar.nextDate(after: now, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        hourTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHour(); self?.armHour() }
        }
    }
    private func receiveInput() { runtime.receiveInput() }
    private func wake() { runtime.wake() }

    private func point(_ point: CGPoint) -> TutuPage0Vector { .init(Double(point.x), Double(point.y)) }
    private func designPoint(_ point: TutuPage0Vector) -> TutuPage0Vector {
        .init(point.x * 402 / max(1, Double(bounds.width)), point.y * 874 / max(1, Double(bounds.height)))
    }
    private var scrollOffset: Double { scroll.map { Double($0.contentOffset.y + $0.adjustedContentInset.top) } ?? 0 }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard allowed, bounds.contains(touch.location(in: self)) else { return false }
        let hitPull = model.pull
        let location = point(touch.location(in: self))
        let hitPoint = designPoint(location)
        let hit = hitPull.hit(x: hitPoint.x, y: hitPoint.y)
        if recognizer === pullTap {
            var tapArbitration = TutuPage0Arbitration()
            _ = tapArbitration.begin(at: location, width: Double(bounds.width), allowed: allowed,
                                     openTarget: model.openTarget, pullHit: hit, isRow: true, scrollOffset: 0)
            return tapArbitration.consumesTap
        }
        var view = touch.view
        var touchedControl = false
        scroll = nil
        while let current = view, current !== gestureHost {
            if current is UIControl { touchedControl = true }
            if let candidate = current as? UIScrollView, candidate.contentSize.height > candidate.bounds.height || candidate.alwaysBounceVertical {
                scroll = candidate; break
            }
            view = current.superview
        }
        if touchedControl && scroll == nil && !hit { return false }
        startPoint = location; startTarget = model.target; touchTime = CACurrentMediaTime()
        let route = arbitration.begin(at: location, width: Double(bounds.width), allowed: allowed,
                                      openTarget: model.openTarget, pullHit: hit, isRow: scroll != nil || touchedControl,
                                      scrollOffset: scrollOffset)
        return route != .rejected
    }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === pullTap { return allowed }
        guard allowed, let pan = recognizer as? UIPanGestureRecognizer, CACurrentMediaTime() - touchTime < 0.35 else { return false }
        let location = point(pan.location(in: self))
        let route = arbitration.move(to: location, scrollOffset: scrollOffset, allowed: allowed)
        return route != .rejected && route != .pending
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && other === scroll?.panGestureRecognizer
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pullTap && other !== pan
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            runtime.isInteracting = true
            receiveInput()
            startTarget = model.target
            if arbitration.route == .pull { grabbedPull = model.beginPull(at: designPoint(startPoint)) }
            updateDrag()
        case .changed: updateDrag()
        case .ended, .cancelled, .failed: finishGesture()
        default: break
        }
    }
    private func updateDrag() {
        guard allowed, let pan else { return }
        let location = point(pan.location(in: self))
        let route = arbitration.move(to: location, scrollOffset: scrollOffset, allowed: allowed)
        if let offset = arbitration.pinnedScrollOffset {
            pinScroll()
            scroll?.setContentOffset(CGPoint(x: scroll?.contentOffset.x ?? 0,
                                            y: CGFloat(offset) - (scroll?.adjustedContentInset.top ?? 0)), animated: false)
        }
        if route == .pull, grabbedPull { model.dragPull(to: designPoint(location)) }
        if route == .cloth {
            if !grabbedCloth { model.beginCloth(); grabbedCloth = true }
            model.dragCloth(dy: arbitration.clothDisplacement(at: location), height: Double(bounds.height))
        }
        if route == .cloth || route == .background {
            model.target.x = min(0.3, max(-0.3, startTarget.x + (location.x - startPoint.x) / max(1, Double(bounds.width)) * 0.6))
        }
    }
    private func pinScroll() {
        guard let scroll, savedBounces == nil else { return }
        savedBounces = scroll.bounces; scroll.bounces = false
        if let refresh = scroll.refreshControl {
            savedRefresh = refresh; savedRefreshEnabled = refresh.isEnabled; refresh.isEnabled = false
        }
    }
    private func finishGesture(persist: Bool = true) {
        let changed = grabbedPull || grabbedCloth
        let wasInteracting = runtime.isInteracting
        runtime.isInteracting = false
        if grabbedPull { model.endPull() }
        if grabbedCloth { model.endCloth() }
        if changed, persist { SkinState.shared.setPage0Open(model.openTarget == 1) }
        if let savedBounces { scroll?.bounces = savedBounces }
        if let enabled = savedRefreshEnabled { savedRefresh?.isEnabled = enabled }
        savedBounces = nil; savedRefreshEnabled = nil; savedRefresh = nil
        grabbedPull = false; grabbedCloth = false; scroll = nil; arbitration.finish()
        if pan?.state == .began || pan?.state == .changed { pan?.isEnabled = false; pan?.isEnabled = true }
        if changed || wasInteracting, running { receiveInput() }
    }
}

private final class TutuPage0DisplayClock: NSObject, TutuPage0FrameClock {
    private var display: CADisplayLink?
    private var callback: ((Double) -> Void)?
    var isRunning: Bool { display != nil }
    var framesPerSecond = 60 {
        didSet {
            guard oldValue != framesPerSecond else { return }
            display?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(framesPerSecond), maximum: Float(framesPerSecond), preferred: Float(framesPerSecond))
        }
    }
    func start(_ callback: @escaping (Double) -> Void) {
        guard display == nil else { return }
        self.callback = callback
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(framesPerSecond), maximum: Float(framesPerSecond), preferred: Float(framesPerSecond))
        link.add(to: .main, forMode: .common); display = link
    }
    func stop() { display?.invalidate(); display = nil; callback = nil }
    @objc private func frame(_ link: CADisplayLink) { callback?(link.timestamp) }
}

private final class TutuPage0Pan: UIPanGestureRecognizer {
    // Never cancel a row tap, context-menu recognizer, swipe, or the list pan.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
#endif
