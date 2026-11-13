#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// Decorative overlay only: the page owns its small, non-cancelling tap recognizer.
struct TutuChatRabbitView: UIViewRepresentable {
    let responding: Bool
    let conversationID: String

    func makeUIView(context: Context) -> TutuChatRabbitHost {
        let view = TutuChatRabbitHost()
        view.update(responding: responding, conversationID: conversationID)
        return view
    }

    func updateUIView(_ view: TutuChatRabbitHost, context: Context) {
        view.update(responding: responding, conversationID: conversationID)
    }

    static func dismantleUIView(_ view: TutuChatRabbitHost, coordinator: ()) { view.tearDown() }
}

final class TutuChatRabbitHost: UIView, UIGestureRecognizerDelegate {
    /// The same scheduler used by Mac harnesses; counts never reset on lifecycle changes.
    let driver = TutuChatRabbitDriver()
    private(set) var sprites: TutuChatRabbitLayers?
    private var responding = false
    private var conversationID: String?
    private var active = false
    private var resetOnAppearance = true
    private var lastFieldOffset: CGFloat?
    private var foreground = UIApplication.shared.applicationState != .background
    private weak var page: UIView?
    private weak var input: UIView?
    private weak var paging: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var geometrySubscription: AnyCancellable?
    private var tap: UITapGestureRecognizer?
    private var disposed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        if let root = Bundle.main.resourceURL?.appendingPathComponent("TutuSkin/chat"),
           let rabbit = UIImage(contentsOfFile: root.appendingPathComponent("rabbit_sheet.png").path)?.cgImage,
           let bloom = UIImage(contentsOfFile: root.appendingPathComponent("china_bloom.png").path)?.cgImage {
            let sprites = TutuChatRabbitLayers(rabbit: rabbit, bloom: bloom)
            self.sprites = sprites
            layer.addSublayer(sprites.root)
        } else {
            print("[TutuChat] rabbit sprite resources unavailable")
        }
        driver.onSample = { [weak self] sample in self?.sprites?.apply(sample) }
        let bridge = KeyboardInsetBridge.shared
        geometrySubscription = Publishers.CombineLatest(bridge.$containerTop, bridge.$fieldOffsetInBar)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged),
                                               name: .tutuSkinActivationChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(responding: Bool, conversationID: String) {
        guard !disposed else { return }
        let changedConversation = self.conversationID != conversationID
        let changedResponding = self.responding != responding
        self.conversationID = conversationID
        self.responding = responding
        if changedConversation { resetOnAppearance = true }
        refresh()
        if active {
            if changedConversation {
                driver.reset(responding: responding)
                resetOnAppearance = false
            }
            else if changedResponding { driver.setResponding(responding) }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    private func bindPage() {
        guard let views = PagingViewController.tutuUnlockSnapshotViews() else { return }
        input = views.input
        if page !== views.page {
            if let tap { page?.removeGestureRecognizer(tap) }
            page = views.page
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            views.page.addGestureRecognizer(recognizer)
            tap = recognizer
        }
        if paging !== PagingViewController.sharedScrollView {
            offsetObservation = nil
            paging = PagingViewController.sharedScrollView
            offsetObservation = paging?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard !disposed else { return }
        bindPage()
        let bridge = KeyboardInsetBridge.shared
        let isChatPage: Bool
        if let paging, paging.bounds.width > 0 {
            // Start of a page departure cancels motion; a completed return resets face zero.
            isChatPage = abs(paging.contentOffset.x - paging.bounds.width) < 0.5
        } else { isChatPage = false }
        let visible = window != nil && foreground && SkinState.shared.active && isChatPage
            && !bridge.chatInputSuppressed && !bridge.barIsPlaceholder
            && bridge.containerTop > 0 && bounds.width > 0 && sprites != nil
        if !isChatPage || window == nil || !SkinState.shared.active { resetOnAppearance = true }
        sprites?.root.isHidden = !visible
        if visible, let page {
            let top = convert(CGPoint(x: 0, y: bridge.inputFieldTop), from: page)
            let oldTop = sprites?.fieldTop ?? top.y
            let animation = active && oldTop != top.y ? geometryAnimation(fieldOffset: bridge.fieldOffsetInBar) : nil
            let carriedOffset = sprites?.root.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            sprites?.root.frame = bounds
            sprites?.layout(width: page.bounds.width, fieldTop: top.y, originX: top.x)
            if let animation {
                animation.keyPath = "transform.translation.y"
                animation.fromValue = oldTop - top.y + carriedOffset
                animation.toValue = 0
                sprites?.root.add(animation, forKey: "tutu.inputGeometry")
            }
            lastFieldOffset = bridge.fieldOffsetInBar
        }
        guard visible != active else { return }
        active = visible
        if visible {
            if resetOnAppearance { driver.reset(responding: responding) }
            else { driver.resume(responding: responding) }
            resetOnAppearance = false
        } else {
            driver.stop()
            sprites?.root.removeAllAnimations()
        }
    }

    /// Copy the existing keyboard carrier's curve (including a spring), never observe the keyboard twice.
    private func geometryAnimation(fieldOffset: CGFloat) -> CABasicAnimation? {
        var ancestor = input
        while let view = ancestor {
            for key in view.layer.animationKeys() ?? [] {
                if let animation = view.layer.animation(forKey: key) as? CABasicAnimation,
                   animation.keyPath == "position" || animation.keyPath == "position.y" {
                    return animation.copy() as? CABasicAnimation
                }
            }
            ancestor = view.superview
        }
        guard let lastFieldOffset, lastFieldOffset != fieldOffset,
              !KeyboardInsetBridge.shared.kbTransitioning else { return nil }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.duration = KeyboardInsetBridge.fieldHeightAnimation
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    @objc private func resignActive() {
        foreground = false
        active = false
        driver.stop()
        sprites?.root.removeAllAnimations()
        sprites?.root.isHidden = true
    }

    @objc private func becomeActive() {
        foreground = true
        // Same mounted chat keeps its face; never replay old taps or deferred ear drops.
        refresh()
    }

    @objc private func skinChanged() { refresh() }

    private func hit(_ recognizer: UIGestureRecognizer) -> TutuChatRabbitLayers.Hit? {
        guard active, TutuChatIntroPresentation.shared.phase.chromeOpacity >= 1,
              let page, let sprites else { return nil }
        let point = recognizer.location(in: page)
        guard point.x > 16, point.x < page.bounds.width - 16 else { return nil }
        return sprites.hit(at: convert(point, from: page))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard active, TutuChatIntroPresentation.shared.phase.chromeOpacity >= 1,
              let page, let sprites else { return false }
        if let input, let touched = touch.view, touched === input || touched.isDescendant(of: input) { return false }
        let point = touch.location(in: page)
        guard point.x > 16, point.x < page.bounds.width - 16 else { return false }
        return sprites.hit(at: convert(point, from: page)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // No failure dependency on scroll pan or edge gestures, and never cancel their touches.
        !(otherGestureRecognizer is UIPanGestureRecognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        switch hit(recognizer) {
        case .rabbit: driver.tapRabbit()
        case .bloom: driver.tapBloom()
        case nil: break
        }
    }

    func tearDown() {
        disposed = true
        active = false
        driver.stop()
        driver.onSample = nil
        sprites?.root.removeAllAnimations()
        sprites?.root.removeFromSuperlayer()
        if let tap { page?.removeGestureRecognizer(tap) }
        tap = nil
        offsetObservation = nil
        geometrySubscription = nil
        NotificationCenter.default.removeObserver(self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif
#endif
