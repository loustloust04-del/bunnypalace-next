#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import UIKit
import MetalKit
import Observation
import os.signpost

private let tutuUnlockHostLog = OSLog(subsystem: "MemoryPalace.Tutu", category: "UnlockHost")

private final class TutuUnlockResources: @unchecked Sendable {
    static let worker = DispatchQueue(label: "MemoryPalace.Tutu.unlock-resources", qos: .userInitiated)
    let device: MTLDevice
    let queue: MTLCommandQueue
    let renderer: TutuUnlockRenderer

    init(image: CGImage, size: CGSize, scale: CGFloat, hour: Double) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
              let queue = device.makeCommandQueue(), let resources = Bundle.main.resourceURL,
              let buffer = queue.makeCommandBuffer() else { throw TutuUnlockError.allocation }
        self.device = device
        self.queue = queue
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let after = try TutuUnlockCathedralTarget(device: device, library: library, resources: resources,
                                                width: width, height: height, pointSize: size)
        try after.encode(commandBuffer: buffer, hour: hour)
        let before = try TutuUnlockRenderer.texture(device: device, image: image)
        renderer = try TutuUnlockRenderer(device: device, library: library, resourceURL: resources,
                                         before: before, after: after.texture)
        let initialScene = TutuUnlockScene()
        initialScene.reset(startTime: 2.22 - 0.04)
        try renderer.prepareBaked(view: initialScene.view())
        buffer.commit()
        // Same queue: the after frame finishes before the first overlay command buffer samples it.
        // Wait only on this worker, retaining the temporary cathedral until encoding completes.
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw error }
    }

    static func dispose(_ resources: TutuUnlockResources?) {
        guard let resources else { return }
        worker.async {
            // No main caller waits on this queue; wait for its stack's references to retire.
            DispatchQueue.main.sync {}
            withExtendedLifetime(resources) {}
        }
    }
}

@Observable @MainActor
final class TutuUnlockPlayback {
    static let shared = TutuUnlockPlayback()
    var active = false
    var generation = UUID()
    var handoffHour: Double?
    var cathedralReady = false
    var handoffFailure: Error?
}

/// A UIKit overlay owned by the existing notification hook, not ContentView.body.
@MainActor
final class TutuUnlockPresentation: NSObject, MTKViewDelegate {
    static let shared = TutuUnlockPresentation()
    private let pagingOwner = UUID()
    private weak var lockedScrollView: UIScrollView?
    private weak var window: UIWindow?
    private var overlay: TutuUnlockOverlay?
    private var renderer: TutuUnlockRenderer?
    private var queue: MTLCommandQueue?
    private var scene: TutuUnlockScene?
    private let motion = TutuMotion()
    private let bell = TutuBell()
    private var last: Double?
    private var tilt = 0.0, targetTilt = 0.0
    private var preparedSnapshot: CGImage?
    private var inputFrame = CGRect.zero
    private var inputFont = UIFont.systemFont(ofSize: 17)
    private var inputColor = UIColor.label
    private var foreground = UIApplication.shared.applicationState == .active
    private var observersInstalled = false
    private var inFlight = false
    private var resources: TutuUnlockResources?
    private var preparationToken: UUID?
    private var playbackSize: CGSize?
    private var snapshotSize: CGSize?

    func unlock() {
        guard !TutuUnlockPlayback.shared.active else { return }
        do { try capture() } catch { showFailure(error); return }
        SkinState.shared.unlock()
        // SkinState posts replay synchronously; the existing hook calls play().
    }

    func play(prepareConversation: @escaping () -> Void) {
        let signpost = OSSignpostID(log: tutuUnlockHostLog)
        os_signpost(.begin, log: tutuUnlockHostLog, name: "TutuUnlockPlay", signpostID: signpost, "phase=cover")
        defer { os_signpost(.end, log: tutuUnlockHostLog, name: "TutuUnlockPlay", signpostID: signpost) }
        guard !TutuUnlockPlayback.shared.active else { return }
        do {
            if preparedSnapshot == nil || snapshotSize != window?.bounds.size { try capture() }
            guard let image = preparedSnapshot, let window else { throw TutuUnlockError.allocation }
            let size = window.bounds.size, scale = window.screen.scale
            let hour = TutuClock.hour(for: SkinState.shared.timeOfDay)
            let generation = UUID()
            preparationToken = generation
            playbackSize = size
            let view = TutuUnlockOverlay(frame: window.bounds, snapshot: image)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.input.frameInWindow = inputFrame; view.input.font = inputFont; view.input.ink = inputColor
            let scene = TutuUnlockScene()
            scene.reduceMotion = UIAccessibility.isReduceMotionEnabled
            scene.reset(startTime: 2.22 - 0.04)
            view.input.state = scene.view().input
            self.scene = scene
            self.overlay = view
            self.last = nil; tilt = 0; targetTilt = 0; self.inFlight = false
            view.onBegan = { [weak self] p in self?.scene?.model.grab(Double(p.x), Double(p.y)) ?? false }
            view.onMoved = { [weak self] p in self?.scene?.model.drag(Double(p.x), Double(p.y)) }
            view.onEnded = { [weak self] in self?.releaseHeldBunny() }
            view.onLayout = { [weak self] in self?.cancelIfSizeChanged() }
            TutuUnlockPlayback.shared.generation = generation
            TutuUnlockPlayback.shared.handoffHour = hour
            TutuUnlockPlayback.shared.cathedralReady = false
            TutuUnlockPlayback.shared.handoffFailure = nil
            TutuUnlockPlayback.shared.active = true
            lockedScrollView = PagingViewController.sharedScrollView
            if let scroll = lockedScrollView { PagingViewController.setPage2DragLocked(true, owner: pagingOwner, scrollView: scroll) }
            window.addSubview(view)
            window.endEditing(true)
            installObservers()
            prepareConversation()
            preparedSnapshot = nil
            motion.onSample = { [weak self] sample in self?.targetTilt = sample.unlockTilt }
            TutuUnlockResources.worker.async { [weak self] in
                let result = Result { try TutuUnlockResources(image: image, size: size, scale: scale, hour: hour) }
                DispatchQueue.main.async {
                    let signpost = OSSignpostID(log: tutuUnlockHostLog)
                    os_signpost(.begin, log: tutuUnlockHostLog, name: "TutuUnlockPlay", signpostID: signpost, "phase=attach")
                    defer { os_signpost(.end, log: tutuUnlockHostLog, name: "TutuUnlockPlay", signpostID: signpost) }
                    self?.cancelIfSizeChanged()
                    guard let self, self.preparationToken == generation,
                          TutuUnlockPlayback.shared.active, TutuUnlockPlayback.shared.generation == generation,
                          let overlay = self.overlay else {
                        if case .success(let resources) = result { TutuUnlockResources.dispose(resources) }
                        return
                    }
                    switch result {
                    case .success(let resources):
                        self.resources = resources
                        self.renderer = resources.renderer
                        self.queue = resources.queue
                        overlay.metal.device = resources.device
                        overlay.metal.delegate = self
                        self.updateRunning()
                    case .failure(let error): self.finish(); self.showFailure(error)
                    }
                }
            }
        } catch {
            preparedSnapshot = nil
            finish()
            showFailure(error)
        }
    }

    private func capture() throws {
        guard let views = PagingViewController.tutuUnlockSnapshotViews(prepare: true), let window = views.page.window else { throw TutuUnlockError.allocation }
        self.window = window
        let page = views.snapshot, input = views.input
        KeyboardInsetBridge.shared.sendDismissUntil = CACurrentMediaTime() + 1
        UIView.performWithoutAnimation { window.endEditing(true); page.layoutIfNeeded() }
        inputFrame = input.convert(input.bounds, to: window)
        func inputField(_ root: UIView) -> UITextView? {
            if let field = root as? UITextView { return field }
            for child in root.subviews { if let field = inputField(child) { return field } }
            return nil
        }
        let field = inputField(input)
        let wasHidden = field?.isHidden
        if let field {
            inputFrame = field.convert(field.bounds, to: window)
            inputFont = field.font ?? .systemFont(ofSize: 17)
            inputColor = (field.textColor ?? .label).resolvedColor(with: field.traitCollection)
            field.isHidden = true
        }
        defer { if let wasHidden { field?.isHidden = wasHidden } }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale; format.opaque = true
        let frame = page.convert(page.bounds, to: window)
        var drawn = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
            UIColor.systemBackground.setFill(); context.fill(window.bounds)
            context.cgContext.translateBy(x: frame.minX, y: frame.minY)
            drawn = page.drawHierarchy(in: page.bounds, afterScreenUpdates: true)
        }
        guard drawn, let cg = image.cgImage else { throw TutuUnlockError.allocation }
        preparedSnapshot = cg
        snapshotSize = window.bounds.size
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(self, selector: #selector(resign), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(activationChanged), name: .tutuSkinActivationChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reducedMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(navigateAway), name: .conversationNavigationRequested, object: nil)
    }
    @objc private func resign() { foreground = false; overlay?.cancelDrag(); releaseHeldBunny(); updateRunning() }
    @objc private func resume() { foreground = true; updateRunning() }
    @objc private func activationChanged() { if !SkinState.shared.active { finish() } }
    @objc private func navigateAway() { finish() }
    @objc private func reducedMotionChanged() { scene?.reduceMotion = UIAccessibility.isReduceMotionEnabled }
    private func cancelIfSizeChanged() {
        if let playbackSize, window?.bounds.size != playbackSize { finish() }
    }
    private func updateRunning() {
        cancelIfSizeChanged()
        let running = foreground && TutuUnlockPlayback.shared.active && renderer != nil
        overlay?.metal.isPaused = !running
        last = nil
        if running {
            motion.start()
            bell.enabled = SkinState.shared.sound
            if bell.enabled { do { try bell.prepare() } catch { print("[TutuUnlock] audio: \(error)") } }
        } else { motion.stop(); bell.stop() }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        cancelIfSizeChanged()
    }
    private func configurePetalFloor() throws {
        guard let scene, let window, let views = PagingViewController.tutuUnlockSnapshotViews() else { throw TutuUnlockError.inputLayout }
        let bridge = KeyboardInsetBridge.shared
        let y = views.page.convert(CGPoint(x: 0, y: bridge.containerTop + bridge.fieldOffsetInBar), to: window).y
        guard y > 0, y < window.bounds.height else { throw TutuUnlockError.inputLayout }
        let floor = Double(y / window.bounds.height * 912), bar = TutuUnlockModel.bar
        scene.petals.floor = { x in x >= bar.x && x <= bar.z ? floor : 912 }
    }
    private func releaseHeldBunny() {
        guard let model = scene?.model, model.tr == nil else { return }
        let kick = model.rabbitView()?.rig.kick ?? 0
        model.release()
        if let release = model.tr { renderer?.captureBakedRelease(time: release, kick: kick) }
    }

    func draw(in view: MTKView) {
        cancelIfSizeChanged()
        if let error = TutuUnlockPlayback.shared.handoffFailure { finish(); showFailure(error); return }
        guard foreground, !inFlight, let scene, let renderer, let queue else { return }
        let now = CACurrentMediaTime(), dt = last.map { now - $0 } ?? 0
        last = now
        tilt += (targetTilt - tilt) * 0.08
        let wasReleased = scene.model.tr != nil
        scene.step(dt, tilt: tilt)
        if !wasReleased, let release = scene.model.tr {
            // Only the model's automatic release happens inside step; recover its idle kick at tick time.
            let auto = TutuUnlockModel.sstep(scene.model.autoAt, scene.model.autoAt + 0.2, release)
            let kick = auto * 0.5 * (1 + sin(release * 15))
            renderer.captureBakedRelease(time: release, kick: kick)
        }
        bell.enabled = SkinState.shared.sound
        for event in scene.model.events {
            if event == "dang" && !scene.reduceMotion {
                do { try configurePetalFloor() } catch { finish(); showFailure(error); return }
            }
            bell.play(event: event)
        }
        scene.model.events.removeAll(keepingCapacity: true)
        let state = scene.view()
        overlay?.input.state = state.input
        // All frames are resident before attach; display callbacks only select samples.
        do {
            try renderer.prepareBaked(view: state)
            drawPrepared(in: view, state: state, scene: scene, renderer: renderer, queue: queue)
        } catch { finish(); showFailure(error) }
    }

    private func drawPrepared(in view: MTKView, state: TutuUnlockView, scene: TutuUnlockScene,
                              renderer: TutuUnlockRenderer, queue: MTLCommandQueue) {
        cancelIfSizeChanged()
        guard foreground, TutuUnlockPlayback.shared.active,
              let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else {
            inFlight = false; last = nil
            return
        }
        do {
            try renderer.encode(commandBuffer: buffer, target: drawable.texture, view: state, petals: scene.drawSprites())
            buffer.present(drawable)
            let generation = TutuUnlockPlayback.shared.generation
            inFlight = true
            buffer.addCompletedHandler { [weak self] buffer in
                DispatchQueue.main.async {
                    guard let self, self.preparationToken == generation,
                          TutuUnlockPlayback.shared.active,
                          TutuUnlockPlayback.shared.generation == generation else { return }
                    self.cancelIfSizeChanged()
                    guard self.preparationToken == generation else { return }
                    self.inFlight = false
                    self.overlay?.didPresentFrame()
                    if let error = buffer.error { self.finish(); self.showFailure(error) }
                    else if state.done && TutuUnlockPlayback.shared.cathedralReady { self.finish(completed: true) }
                }
            }
            buffer.commit()
        } catch { finish(); showFailure(error) }
    }
    func finish(completed: Bool = false) {
        let signpost = OSSignpostID(log: tutuUnlockHostLog)
        os_signpost(.begin, log: tutuUnlockHostLog, name: "TutuUnlockDismantle", signpostID: signpost)
        defer { os_signpost(.end, log: tutuUnlockHostLog, name: "TutuUnlockDismantle", signpostID: signpost) }
        preparationToken = nil
        playbackSize = nil
        overlay?.metal.isPaused = true; overlay?.metal.delegate = nil
        overlay?.removeFromSuperview(); overlay = nil
        renderer?.cancelBakedPreparation()
        scene = nil; renderer = nil; queue = nil; preparedSnapshot = nil
        let retired = resources
        resources = nil
        TutuUnlockResources.dispose(retired)
        motion.stop(); motion.onSample = nil
        if !completed { bell.stop(); TutuUnlockPlayback.shared.handoffHour = nil }
        last = nil
        if let scroll = lockedScrollView { PagingViewController.setPage2DragLocked(false, owner: pagingOwner, scrollView: scroll) }
        lockedScrollView = nil
        TutuUnlockPlayback.shared.active = false
        TutuUnlockPlayback.shared.cathedralReady = false
        TutuUnlockPlayback.shared.handoffFailure = nil
        if observersInstalled { NotificationCenter.default.removeObserver(self); observersInstalled = false }
    }
    private func showFailure(_ error: Error) {
        print("[TutuUnlock] \(error.localizedDescription)")
        guard let root = window?.rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        let alert = UIAlertController(title: "解锁动画未能播放", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter.present(alert, animated: true)
    }
}

private final class TutuUnlockOverlay: UIView {
    let metal: MTKView
    let input = TutuUnlockInputOverlay()
    private let before = UIImageView()
    var onBegan: ((CGPoint) -> Bool)?
    var onMoved: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?
    var onLayout: (() -> Void)?
    private var finger: UITouch?
    init(frame: CGRect, snapshot: CGImage) {
        metal = MTKView(frame: .zero, device: nil)
        super.init(frame: frame)
        backgroundColor = .black
        before.frame = bounds; before.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        before.image = UIImage(cgImage: snapshot)
        addSubview(before)
        metal.alpha = 0
        metal.frame = bounds; metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metal.colorPixelFormat = .bgra8Unorm; metal.framebufferOnly = true
        metal.preferredFramesPerSecond = 60; metal.isPaused = true; metal.isUserInteractionEnabled = false
        addSubview(metal)
        input.frame = bounds; input.autoresizingMask = [.flexibleWidth, .flexibleHeight]; input.isUserInteractionEnabled = false
        addSubview(input)
        accessibilityViewIsModal = true
        isAccessibilityElement = true
        accessibilityLabel = "解锁兔兔皮肤；小兔抓住握把后，向下拉再松手，也可以等待自动拉绳"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    func didPresentFrame() { metal.alpha = 1; before.removeFromSuperview() }
    func cancelDrag() { if finger != nil { onEnded?(); finger = nil } }
    private func point(_ t: UITouch) -> CGPoint { let p = t.location(in: self); return CGPoint(x: p.x / bounds.width * 420, y: p.y / bounds.height * 912) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard finger == nil, let t = touches.first, onBegan?(point(t)) == true else { return }
        finger = t
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let finger, touches.contains(finger) { onMoved?(point(finger)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let finger, touches.contains(finger) { onEnded?(); self.finger = nil }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
}

private final class TutuUnlockInputOverlay: UIView {
    var state: TutuUnlockInput? {
        didSet { if state?.gone != true || oldValue?.gone != true { setNeedsDisplay() } }
    }
    var frameInWindow = CGRect.zero
    var font = UIFont.systemFont(ofSize: 17) { didSet { prepareGlyphs() } }
    var ink = UIColor.label { didSet { prepareGlyphs() } }
    private var glyphs: [(text: NSAttributedString, width: CGFloat)] = []
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = false; backgroundColor = .clear
        prepareGlyphs()
    }
    private func prepareGlyphs() {
        glyphs = TutuSkinUnlock.phrase.map {
            let text = NSAttributedString(string: String($0), attributes: [.font: font, .foregroundColor: ink])
            return (text, text.size().width)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let state, !state.gone, state.typed > 0, let context = UIGraphicsGetCurrentContext() else { return }
        var x = frameInWindow.minX + 5
        let y = frameInWindow.midY - font.lineHeight / 2
        context.saveGState()
        for i in 0..<min(state.typed, glyphs.count) {
            let e = state.sink(i), glyph = glyphs[i]
            context.setAlpha(1 - e)
            glyph.text.draw(at: CGPoint(x: x, y: y + 11 * e * e))
            x += glyph.width
        }
        context.restoreGState()
    }
}
#endif
#endif
