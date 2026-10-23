#if os(iOS)
import SwiftUI
import UIKit

/// 只在图层上退开，避免 scaleEffect/offset 每帧改变子 hosting 的安全区与布局。
/// 内容和环境变化仍正常提交 rootView；进度发布后同步更新图层几何。
struct Page2StripSurface<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let motion: Page2StripMotion
    let close: () -> Void
    let content: Content

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: Page2HostedContent(content: content, environment: environment), motion: motion, close: close)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        #if DEBUG || PERF_BENCH
        Page2StripProbe.hit("stripSurfaceRootAssign")
        #endif
        withTransaction(context.transaction) {
            controller.host.rootView = Page2HostedContent(content: content, environment: environment)
        }
        controller.closeView.close = close
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        if let id = controller.presentationID { controller.motion.removePresentation(id) }
        controller.presentationID = nil
        controller.blur.tearDown()
    }

    final class Controller: UIViewController {
        let host: UIHostingController<Page2HostedContent<Content>>
        let surface = UIView()
        let blur = Page2StripBlurView(effect: nil)
        let closeView = Page2StripCloseView()
        let motion: Page2StripMotion
        var presentationID: UUID?

        init(content: Page2HostedContent<Content>, motion: Page2StripMotion, close: @escaping () -> Void) {
            host = UIHostingController(rootView: content)
            self.motion = motion
            closeView.close = close
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func loadView() { view = Page2StripPassthroughView() }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            surface.backgroundColor = .clear
            // 满屏停靠时不加内层遮罩；跨页圆角交给分页前景容器。
            // 只有竖栏退开的内屏需要自己的圆角，黑色 Backdrop 不参与。
            surface.layer.cornerCurve = .continuous
            surface.layer.masksToBounds = false
            view.addSubview(surface)
            // 对齐原外壳 ignoresSafeArea 的全屏逻辑画布；子应用仍使用自己的 UIKit 安全区。
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            addChild(host)
            surface.addSubview(host.view)
            host.didMove(toParent: self)
            blur.isUserInteractionEnabled = false
            surface.addSubview(blur)
            surface.addSubview(closeView)
            closeView.addGestureRecognizer(UITapGestureRecognizer(target: closeView, action: #selector(Page2StripCloseView.tapped)))
            presentationID = motion.addPresentation { [weak self] progress in self?.apply(progress) }
            // 首次挂载延后读取，避免把 motion 进度纳入 representable 的 Observation 依赖。
            Task { @MainActor [weak self] in
                guard let self, self.presentationID != nil else { return }
                self.apply(self.motion.progress)
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // 不给已变换的 UIView 写 frame；逻辑 bounds/center 始终是全屏尺寸。
            let bounds = CGRect(origin: .zero, size: view.bounds.size)
            if surface.bounds != bounds { surface.bounds = bounds }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            if surface.center != center { surface.center = center }
            if host.view.frame != bounds { host.view.frame = bounds }
            blur.frame = bounds
            closeView.frame = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer.cornerRadius = Page2DisplayCorner.radius(for: view)
            CATransaction.commit()
        }

        private func apply(_ progress: CGFloat) {
            let p = min(max(progress, 0), 1.2)
            let scale = 1 - (1 - Page2StripMetrics.appScale) * p
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: -Page2StripMetrics.width * p, y: 0))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let clips = p > 0
            if surface.layer.masksToBounds != clips { surface.layer.masksToBounds = clips }
            surface.layer.setAffineTransform(transform)
            blur.apply(fraction: Page2StripMetrics.blur * min(p, 1))
            CATransaction.commit()
            host.view.accessibilityElementsHidden = p > 0.01
            closeView.isUserInteractionEnabled = p > 0.01
            closeView.isAccessibilityElement = p > 0.01
            closeView.accessibilityElementsHidden = p <= 0.01
        }
    }
}

/// 退开后露出的右侧空区交还后面的竖条，不由透明容器拦截。
final class Page2StripPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

final class Page2StripCloseView: UIView {
    var close: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        accessibilityLabel = "收起应用切换栏"
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { nil }
    @objc func tapped() { close?() }
    override func accessibilityActivate() -> Bool { close?(); return true }
}

final class Page2StripBlurView: UIVisualEffectView {
    private var animator: UIViewPropertyAnimator?

    func apply(fraction: CGFloat) {
        #if DEBUG || PERF_BENCH
        if Page2StripProbe.withoutBlur { isHidden = true; return }
        #endif
        guard fraction > 0 else { alpha = 0; isHidden = true; return }
        isHidden = false
        alpha = Page2StripMetrics.blurOpacity * min(fraction / Page2StripMetrics.blur, 1)
        if animator == nil {
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [unowned self] in
                self.effect = UIBlurEffect(style: .regular)
            }
            animator.pausesOnCompletion = true
            animator.startAnimation()
            animator.pauseAnimation()
            self.animator = animator
        }
        animator?.fractionComplete = min(fraction, 1)
    }

    func tearDown() {
        guard let animator else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .start)
        self.animator = nil
        effect = nil
    }
}
#endif
