#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import UIKit

struct TutuWuScrollView: UIViewRepresentable {
    let running: Bool
    let wallpaper: String
    let onKey: () -> Void
    let onError: (String) -> Void
    func makeUIView(context: Context) -> TutuWuViewport { TutuWuViewport() }
    func updateUIView(_ view: TutuWuViewport, context: Context) {
        view.onKey = onKey
        view.onError = onError
        view.configure(running: running, wallpaper: wallpaper)
    }
    static func dismantleUIView(_ view: TutuWuViewport, coordinator: ()) { view.releaseScene() }
}

private final class TutuWuNativeScroll: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let x = gestureRecognizer.location(in: self).x - bounds.minX - panGestureRecognizer.translation(in: self).x
            guard !TutuEdgePaging.acceptsStart(x: x, width: bounds.width, edge: .left),
                  !TutuEdgePaging.acceptsStart(x: x, width: bounds.width, edge: .right) else { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

final class TutuWuViewport: UIView, UIScrollViewDelegate {
    private static var savedViewport = CGSize.zero
    private let scroll = TutuWuNativeScroll()
    private let content = UIView()
    private var scene: TutuWuScene?
    private lazy var frameDriver = TutuWuFrameDriver(
        makeDisplayLink: { CADisplayLink(target: $0, selector: $1) },
        onFrame: { [weak self] in self?.drawScene() }
    )
    private var running = false
    private var wallpaper = "folds"
    private var lastSize = CGSize.zero
    private var accessiblePieces: [UIView] = []
    private var restoresPosition = true
    private var updatingGeometry = false
    private var lastError: String?
    private var foreground = UIApplication.shared.applicationState == .active
    var onKey: (() -> Void)?
    var onError: ((String) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.alwaysBounceVertical = false
        scroll.isDirectionalLockEnabled = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.isScrollEnabled = false
        clipsToBounds = true
        addSubview(scroll)
        scroll.addSubview(content)
        NotificationCenter.default.addObserver(self, selector: #selector(backgroundScene),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeScene),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private var canRender: Bool {
        running && foreground && window != nil && !isHidden && UIApplication.shared.applicationState == .active
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { suspendScene() }
            else if running { setNeedsLayout() }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { suspendScene() }
        else if running { setNeedsLayout() }
    }

    func configure(running: Bool, wallpaper: String) {
        let changed = self.running != running || self.wallpaper != wallpaper
        self.running = running
        self.wallpaper = wallpaper
        if changed { lastError = nil }
        if !running { suspendScene() }
        else if changed || scene == nil { setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let oldSize = restoresPosition ? Self.savedViewport : lastSize
        let oldOffset = restoresPosition ? TutuWuPosition.shared.offset : scroll.contentOffset.x
        let resized = lastSize != bounds.size
        if resized || restoresPosition {
            updatingGeometry = true
            let oldRange = max(0, 1560 * oldSize.height / 844 - oldSize.width)
            let newRange = max(0, 1560 * bounds.height / 844 - bounds.width)
            let offset: CGFloat
            if oldSize != .zero && oldSize != bounds.size && oldRange > 0 {
                offset = min(max(0, oldOffset / oldRange), 1) * newRange
            } else {
                offset = min(max(0, oldOffset), newRange)
            }
            lastSize = bounds.size
            scroll.frame = bounds
            content.frame = CGRect(x: 0, y: 0, width: 1560 * bounds.height / 844, height: bounds.height)
            scroll.contentSize = content.bounds.size
            scroll.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
            restoresPosition = false
            updatingGeometry = false
            savePosition()
        }
        guard canRender else {
            suspendScene()
            return
        }
        scroll.isScrollEnabled = true
        if scene == nil {
            do {
                guard let root = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
                let created = try TutuWuScene(resourceDirectory: root.appendingPathComponent("TutuSkin/wu"),
                                              displayScale: window?.screen.scale ?? contentScaleFactor)
                created.onError = { [weak self] error in
                    guard let self, self.canRender else { return }
                    self.report(error)
                }
                scene = created
                layer.insertSublayer(created.viewportLayer, below: scroll.layer)
                content.layer.insertSublayer(created.stripLayer, at: 0)
                layer.addSublayer(created.overlayLayer)
                installAccessibility(created.pieces)
            } catch { report(error); return }
        }
        if resized { layoutAccessibility() }
        drawScene()
    }
    private func installAccessibility(_ pieces: [TutuWuPiece]) {
        accessiblePieces.forEach { $0.removeFromSuperview() }
        accessiblePieces = pieces.enumerated().filter { $0.element.visible }.map { index, piece in
            let view: UIView
            if piece.key == "key" {
                let button = UIButton(type: .custom)
                button.addTarget(self, action: #selector(openKey), for: .touchUpInside)
                view = button
                view.accessibilityTraits = .button
            } else {
                view = UIView()
                view.isUserInteractionEnabled = false
                view.accessibilityTraits = .image
            }
            view.isAccessibilityElement = true
            view.accessibilityLabel = piece.label
            view.tag = index
            content.addSubview(view)
            return view
        }
        layoutAccessibility()
    }
    private func layoutAccessibility() {
        guard let scene else { return }
        let scale = bounds.height / 844
        for view in accessiblePieces {
            let rect = scene.pieces[view.tag].frame
            view.frame = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
    }
    @objc private func openKey() {
        guard canRender, scene != nil else { return }
        onKey?()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !updatingGeometry, canRender, scene != nil else { return }
        savePosition()
        frameDriver.request()
    }

    private func savePosition() {
        guard !restoresPosition, lastSize != .zero else { return }
        let maximum = max(0, scroll.contentSize.width - scroll.bounds.width)
        TutuWuPosition.shared.offset = min(max(0, scroll.contentOffset.x), maximum)
        Self.savedViewport = lastSize
    }
    private func drawScene() {
        guard canRender, !updatingGeometry, let scene else { return }
        do {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            try scene.render(viewport: bounds.size, offset: scroll.contentOffset.x, wallpaper: wallpaper)
            lastError = nil
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        let message = "物页资源无法加载：\(error.localizedDescription)"
        guard lastError != message else { return }
        lastError = message
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canRender, self.lastError == message else { return }
            self.onError?(message)
        }
    }
    @objc private func resumeScene() {
        foreground = true
        if running { setNeedsLayout() }
    }

    @objc private func backgroundScene() {
        foreground = false
        suspendScene()
    }

    @objc private func memoryWarning() {
        suspendScene()
        // Still on screen: rebuild through layout so only the current wallpaper is prepared again.
        if canRender { setNeedsLayout() }
    }

    @objc private func suspendScene() {
        frameDriver.stop()
        savePosition()
        let released = scene
        scene = nil
        scroll.isScrollEnabled = false
        // Stop deceleration before releasing images; late scroll callbacks must stay inert.
        let maximum = max(0, scroll.contentSize.width - scroll.bounds.width)
        let offset = min(max(0, scroll.contentOffset.x), maximum)
        scroll.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        released?.releaseResources()
        released?.onError = nil
        released?.viewportLayer.removeFromSuperlayer()
        released?.stripLayer.removeFromSuperlayer()
        released?.overlayLayer.removeFromSuperlayer()
        accessiblePieces.forEach { $0.removeFromSuperview() }
        accessiblePieces.removeAll()
    }

    func releaseScene() {
        running = false
        suspendScene()
        onKey = nil
        onError = nil
    }
}
#endif
#endif