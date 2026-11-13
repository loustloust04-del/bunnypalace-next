#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import MetalKit
import QuartzCore
import UIKit
import simd
import os.signpost

private let tutuCathedralHostLog = OSLog(subsystem: "MemoryPalace.Tutu", category: "CathedralHost")

/// Prepared and finally released on one worker; renderer mutation after handoff is main-only.
private final class TutuCathedralResources: @unchecked Sendable {
    static let worker = DispatchQueue(label: "MemoryPalace.Tutu.cathedral-resources", qos: .userInitiated)
    let device: MTLDevice
    let queue: MTLCommandQueue
    let renderer: TutuCathedralRenderer

    init(hour: Double) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let queue = device.makeCommandQueue(),
              let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "TutuCathedral", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法准备大教堂 Metal 资源"])
        }
        self.device = device
        self.queue = queue
        renderer = try TutuCathedralRenderer(device: device, library: library,
            resourceURL: resources.appendingPathComponent("TutuSkin/cathedral", isDirectory: true))
        try renderer.prepareFlower(hour: hour)
    }

    static func dispose(_ resources: TutuCathedralResources?) {
        guard let resources else { return }
        worker.async {
            // The current main call must drop its other references before our final release.
            DispatchQueue.main.sync {}
            withExtendedLifetime(resources) {}
        }
    }
}

private final class TutuCompletedFrameStore: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let drawable: CAMetalDrawable
        let hour: Double
        let sequence: UInt64
    }
    private let condition = NSCondition()
    private var current: Snapshot?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pending = 0
    private var cancelled = false
    private var failure: Error?

    // Freeze submission before waiting; buffer completion also exists in Simulator.
    func register(_ drawable: CAMetalDrawable, hour: Double, buffer: MTLCommandBuffer) {
        condition.lock()
        sequence &+= 1; pending += 1; cancelled = false
        let token = generation
        let snapshot = Snapshot(drawable: drawable, hour: hour, sequence: sequence)
        condition.unlock()
        buffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard token == self.generation else { return }
            if let error = buffer.error { self.failure = error }
            else if snapshot.sequence >= (self.current?.sequence ?? 0) { self.current = snapshot }
            self.pending -= 1; self.condition.broadcast()
        }
    }
    func wait() throws -> Snapshot {
        condition.lock(); defer { condition.unlock() }
        while pending > 0 && !cancelled && failure == nil { condition.wait() }
        if let failure { throw failure }
        guard !cancelled, let current else { throw TutuChatError.command("大教堂没有可捕获的显示帧") }
        return current
    }
    func cancel() {
        condition.lock(); defer { condition.unlock() }
        generation &+= 1; current = nil; pending = 0; cancelled = true; failure = nil
        condition.broadcast()
    }
}

/// Lives in the empty conversation scene; paging observation stays out of ContentView.
struct TutuMetalView: View {
    var active: Bool
    var preferredFramesPerSecond: Int = 60
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false


    @MainActor
    static func captureForChat(completion: @escaping (Result<TutuChatCathedralCapture, Error>) -> Void) -> Bool {
        TutuMetalSurface.Coordinator.captureForChat(completion: completion)
    }
    var body: some View {
        Color.clear
            .background {
                TutuMetalSurface(active: active && appeared && scenePhase == .active
                                 && !Page0Stage.shared.isOnScreen && !Page2SceneState.shared.isActive,
                                 unlocking: TutuUnlockPlayback.shared.active,
                                 chatIntroActive: TutuChatIntroPresentation.shared.active,
                                 preferredFramesPerSecond: preferredFramesPerSecond,
                                 timeOfDay: SkinState.shared.timeOfDay,
                                 crackOnShake: SkinState.shared.crackOnShake,
                                 reduceMotion: reduceMotion)
                    .ignoresSafeArea()
                    .id(TutuUnlockPlayback.shared.generation)
            }
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
    }
}

private struct TutuMetalSurface: UIViewRepresentable {
    var active: Bool
    var unlocking: Bool
    var chatIntroActive: Bool
    var preferredFramesPerSecond: Int
    var timeOfDay: SkinState.TimeOfDay
    var crackOnShake: Bool
    var reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TutuMetalContainer {
        let signpost = OSSignpostID(log: tutuCathedralHostLog)
        os_signpost(.begin, log: tutuCathedralHostLog, name: "TutuCathedralInstall", signpostID: signpost, "phase=host")
        defer { os_signpost(.end, log: tutuCathedralHostLog, name: "TutuCathedralInstall", signpostID: signpost) }
        let view = TutuMetalContainer()
        context.coordinator.timeOfDay = timeOfDay
        context.coordinator.install(in: view)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: TutuMetalContainer, context: Context) {
        let coordinator = context.coordinator
        if !chatIntroActive { coordinator.releaseChatCapture() }
        let unlockChanged = coordinator.unlocking != unlocking
        coordinator.unlocking = unlocking
        if unlockChanged && !unlocking { coordinator.resumeAfterUnlock() }
        let changed = coordinator.timeOfDay != timeOfDay || coordinator.reduceMotion != reduceMotion
            || coordinator.crackle.enabled != crackOnShake
        coordinator.requestedActive = active
        coordinator.timeOfDay = timeOfDay
        coordinator.reduceMotion = reduceMotion
        coordinator.crackle.enabled = crackOnShake
        view.metal.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        coordinator.updateRunning()
        if changed || unlockChanged { coordinator.invalidateFrame() }
    }

    static func dismantleUIView(_ view: TutuMetalContainer, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        private static weak var runningOwner: Coordinator?
        private static weak var bakedActivationOwner: Coordinator?
        fileprivate var requestedActive = false
        fileprivate var timeOfDay: SkinState.TimeOfDay = .now
        fileprivate var reduceMotion = false
        fileprivate var crackle = TutuCrackle()
        private weak var container: TutuMetalContainer?
        private let motion = TutuMotion()
        private var renderer: TutuCathedralRenderer?
        private var commandQueue: MTLCommandQueue?
        private var resources: TutuCathedralResources?
        private var revealingFirstFrame = false
        private var running = false
        fileprivate var unlocking = false
        private var foreground = UIApplication.shared.applicationState == .active
        private let timeOrigin = CACurrentMediaTime()
        private var shownAt: Double?
        private var firstVisibleTime: Double?
        private var previousTime: Double?
        private var lastInput = -Double.infinity
        private var target = SIMD2<Float>.zero
        private var acceptedPhysicalTilt = SIMD2<Float>.zero
        private var tilt = SIMD2<Float>.zero
        private var dragOrigin = CGPoint.zero
        private var dragTarget = SIMD2<Float>.zero
        private var dragging = false
        private var restoring = false
        private var tornDown = false
        private var lastFrame: TutuCathedralFrame?
        private var wakeTimer: Timer?
        private var fracturePrewarming = false
        private var fracturePreparationGeneration: UInt64 = 0
        private var bakedActivationRequested = false
        private var flowerPreparing = false
        private var releaseWhenFlowerReady = false
        private var capturingChat = false
        private let presentation = TutuCompletedFrameStore()

        static func captureForChat(completion: @escaping (Result<TutuChatCathedralCapture, Error>) -> Void) -> Bool {
            guard let owner = runningOwner, !owner.unlocking, !owner.capturingChat,
                  let container = owner.container, let window = container.window,
                  let views = PagingViewController.tutuUnlockSnapshotViews(),
                  let queue = owner.commandQueue, let resources = owner.resources else { return false }
            let presentation = owner.presentation
            let pixels = container.metal.drawableSize
            let rect = container.metal.convert(container.metal.bounds, to: views.page)
            let pageSize = views.page.bounds.size
            guard pixels.width > 0, pixels.height > 0, window.bounds.width > 0 else { return false }
            owner.capturingChat = true
            container.metal.isPaused = true
            owner.motion.stop()
            owner.wakeTimer?.invalidate(); owner.wakeTimer = nil
            owner.running = false
            TutuCathedralResources.worker.async {
                let result = Result<TutuChatCathedralCapture, Error> {
                    let shown = try presentation.wait()
                    let source = shown.drawable.texture
                    guard source.width == Int(pixels.width), source.height == Int(pixels.height) else {
                        throw TutuChatError.command("大教堂快照尺寸已改变")
                    }
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                        width: Int(pixels.width), height: Int(pixels.height), mipmapped: false)
                    descriptor.storageMode = .private
                    descriptor.usage = .shaderRead
                    guard let texture = resources.device.makeTexture(descriptor: descriptor),
                          let buffer = queue.makeCommandBuffer(),
                          let encoder = buffer.makeBlitCommandEncoder() else { throw TutuChatError.allocation }
                    encoder.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                                 sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                                 to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                    encoder.endEncoding()
                    buffer.commit(); buffer.waitUntilCompleted()
                    if let error = buffer.error { throw error }
                    return TutuChatCathedralCapture(texture: texture, rect: rect, pageSize: pageSize, hour: shown.hour)
                }
                withExtendedLifetime(resources) {}
                DispatchQueue.main.async { completion(result) }
            }
            return true
        }
        fileprivate func releaseChatCapture() {
            guard capturingChat else { return }
            capturingChat = false
            presentation.cancel()
        }

        func install(in view: TutuMetalContainer) {
            container = view
            view.onVisibilityChanged = { [weak self] in self?.updateRunning() }
            view.restoreButton.addTarget(self, action: #selector(restorePieces), for: .touchUpInside)
            view.metal.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "复原", target: self, selector: #selector(accessibilityRestore(_:)))]
            let pan = TutuScrubGesture(target: self, action: #selector(drag(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.samples = { [weak self] touch, event in self?.feed(touch: touch, event: event) }
            pan.released = { [weak self] in self?.crackle.release() }
            view.addGestureRecognizer(pan)
            NotificationCenter.default.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(becomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            let hour = TutuUnlockPlayback.shared.handoffHour ?? TutuClock.hour(for: timeOfDay)
            TutuCathedralResources.worker.async { [weak self] in
                let result = Result { try TutuCathedralResources(hour: hour) }
                DispatchQueue.main.async {
                    let signpost = OSSignpostID(log: tutuCathedralHostLog)
                    os_signpost(.begin, log: tutuCathedralHostLog, name: "TutuCathedralInstall", signpostID: signpost, "phase=attach")
                    defer { os_signpost(.end, log: tutuCathedralHostLog, name: "TutuCathedralInstall", signpostID: signpost) }
                    guard let self, !self.tornDown, let container = self.container else {
                        if case .success(let resources) = result { TutuCathedralResources.dispose(resources) }
                        return
                    }
                    switch result {
                    case .success(let resources):
                        self.resources = resources
                        self.renderer = resources.renderer
                        self.commandQueue = resources.queue
                        container.metal.device = resources.device
                        container.metal.delegate = self
                        self.updateRunning()
                    case .failure(let error): self.fail(error)
                    }
                }
            }
            motion.onSample = { [weak self] sample in
                guard let self, self.running, !self.restoring, !self.unlocking else { return }
                // 0.002 in the mapped/clamped tilt space is 0.625% of x's
                // 0.32 range and 0.833% of y's 0.24 range (~0.1° physical).
                // Compare accepted sensor input, never the automatic light target:
                // sub-threshold samples neither extend the idle deadline nor wake.
                let change = abs(sample.tilt - self.acceptedPhysicalTilt)
                let physicalChanged = !self.dragging && max(change.x, change.y) >= 0.002
                if physicalChanged {
                    self.acceptedPhysicalTilt = sample.tilt
                    self.target = sample.tilt
                    self.lastInput = sample.time
                }
                self.crackle.enabled = SkinState.shared.crackOnShake
                self.crackle.motion(ax: sample.acceleration.x, ay: sample.acceleration.y,
                                    az: sample.acceleration.z, at: sample.time * 1000)
                if physicalChanged || simd_length(sample.acceleration) > 11 || self.crackle.amount > 0.00001 {
                    self.wake()
                }
            }
        }

        fileprivate func updateRunning() {
            guard !tornDown, !capturingChat, let container else { return }
            let visible = container.window.map { !container.isHidden && container.alpha > 0
                && container.convert(container.bounds, to: $0).intersects($0.bounds) } ?? false
            bakedActivationRequested = SkinState.shared.active && requestedActive && foreground && visible
            updateBakedActivation()
            let shouldRun = requestedActive && foreground && visible && renderer != nil
            guard shouldRun != running else { return }
            if shouldRun {
                if let other = Self.runningOwner, other !== self { other.stop() }
                Self.runningOwner = self
                running = true
                shownAt = CACurrentMediaTime()
                previousTime = nil
                lastFrame = nil
                acceptedPhysicalTilt = .zero
                motion.start()
                wake()
            } else { stop() }
        }

        private func updateBakedActivation() {
            if bakedActivationRequested && !tornDown {
                Self.bakedActivationOwner = self
                TutuUnlockBaked.activationChanged(active: true)
            } else if Self.bakedActivationOwner === self {
                Self.bakedActivationOwner = nil
                TutuUnlockBaked.activationChanged(active: false)
            }
        }

        private func invalidateFracturePreparation() {
            fracturePreparationGeneration &+= 1
            fracturePrewarming = false
        }

        private func stop() {
            if !bakedActivationRequested || tornDown { updateBakedActivation() }
            invalidateFracturePreparation()
            running = false
            capturingChat = false
            container?.metal.isPaused = true
            motion.stop()
            presentation.cancel()
            wakeTimer?.invalidate()
            wakeTimer = nil
            crackle.suspendInput()
            dragging = false
            previousTime = nil
            if flowerPreparing { releaseWhenFlowerReady = true }
            else { renderer?.releaseTransientResources() }
            if Self.runningOwner === self { Self.runningOwner = nil }
        }

        func dismantle() {
            let signpost = OSSignpostID(log: tutuCathedralHostLog)
            os_signpost(.begin, log: tutuCathedralHostLog, name: "TutuCathedralDismantle", signpostID: signpost)
            defer { os_signpost(.end, log: tutuCathedralHostLog, name: "TutuCathedralDismantle", signpostID: signpost) }
            tornDown = true
            stop()
            NotificationCenter.default.removeObserver(self)
            motion.onSample = nil
            container?.onVisibilityChanged = nil
            container?.metal.delegate = nil
            container?.metal.accessibilityCustomActions = nil
            container?.gestureRecognizers?.forEach { container?.removeGestureRecognizer($0) }
            renderer = nil
            commandQueue = nil
            container = nil
            let retired = resources
            resources = nil
            TutuCathedralResources.dispose(retired)
        }

        @objc private func resignActive() { foreground = false; updateRunning() }
        @objc private func becomeActive() { foreground = true; updateRunning() }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidateFrame() }

        fileprivate func invalidateFrame() {
            lastFrame = nil
            refreshRestoreButton()
            wake()
        }

        private func wake() {
            guard running else { return }
            wakeTimer?.invalidate()
            wakeTimer = nil
            if container?.metal.isPaused == true { previousTime = CACurrentMediaTime() }
            container?.metal.isPaused = false
        }

        private static func tiltKey(_ value: SIMD2<Float>) -> SIMD2<Int> {
            SIMD2(Int((Double(value.x) * 10000).rounded()), Int((Double(value.y) * 10000).rounded()))
        }

        private static func samePresentation(_ a: TutuCathedralFrame, _ b: TutuCathedralFrame) -> Bool {
            (a.hour * 1000).rounded() == (b.hour * 1000).rounded()
                && tiltKey(a.tilt) == tiltKey(b.tilt)
                && (Double(a.crack) * 10000).rounded() == (Double(b.crack) * 10000).rounded()
                && (Double(a.shatter) * 10000).rounded() == (Double(b.shatter) * 10000).rounded()
        }

        private func refreshRestoreButton() {
            guard !flowerPreparing, let button = container?.restoreButton else { return }
            let restored = (renderer?.restorationProgress(at: CACurrentMediaTime() - timeOrigin) ?? 0) >= 1
            let title = restored ? "已复原" : restoring ? "复原中" : "复原"
            if button.title(for: .normal) != title { button.setTitle(title, for: .normal) }
            button.isHidden = crackle.breakLevel <= 0
            button.isEnabled = crackle.breakLevel > 0 && !restoring && !restored
        }

        private func pauseIfIdle(now: Double, frame: TutuCathedralFrame, automaticLight: Bool) {
            guard let renderer, let container else { return }
            let strain = !restoring && renderer.restorationProgress(at: frame.time) < 1
                && crackle.enabled && (crackle.amount > 0.00001 || crackle.stress > 0 || crackle.breakStress > 0
                    || abs(crackle.level - crackle.target) > 0.00001
                    || abs(crackle.breakLevel - crackle.breakTarget) > 0.00001)
            guard !automaticLight, Self.tiltKey(target) == Self.tiltKey(tilt),
                  !dragging, !strain, !renderer.isAnimating(at: frame.time) else { return }
            container.metal.isPaused = true
            previousTime = nil
            var delay = Double.infinity
            if timeOfDay == .now {
                delay = max(0.02, ((frame.hour * 1000).rounded() + 0.5 - frame.hour * 1000) * 3.6)
            }
            if !reduceMotion {
                let lightAt = max((shownAt ?? now) + 2.5, lastInput + 4)
                delay = min(delay, max(0.02, lightAt - now))
            }
            guard delay.isFinite else { return }
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
            wakeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        fileprivate func resumeAfterUnlock() {
            shownAt = CACurrentMediaTime(); firstVisibleTime = nil; previousTime = nil
            lastInput = -Double.infinity; target = .zero; tilt = .zero; dragging = false; lastFrame = nil
            if running { motion.start() }
        }

        private func revealFirstFrame(after buffer: MTLCommandBuffer) {
            guard container?.metal.alpha == 0, !revealingFirstFrame else { return }
            revealingFirstFrame = true
            buffer.addCompletedHandler { [weak self] buffer in
                DispatchQueue.main.async {
                    guard let self, !self.tornDown else { return }
                    if let error = buffer.error { self.fail(error); return }
                    guard let container = self.container else { return }
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                        container.metal.alpha = 1
                    }
                }
            }
        }

        private func drawUnlockHandoff(in view: MTKView, renderer: TutuCathedralRenderer, queue: MTLCommandQueue) {
            if prepareFractureIfNeeded(renderer) { return }
            guard let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
            let generation = TutuUnlockPlayback.shared.generation
            let rendererID = ObjectIdentifier(renderer)
            let frame = TutuCathedralFrame(hour: TutuUnlockPlayback.shared.handoffHour ?? TutuClock.hour(for: timeOfDay))
            do {
                try renderer.encode(commandBuffer: buffer, target: drawable.texture, frame: frame)
                presentation.register(drawable, hour: frame.hour, buffer: buffer)
                buffer.present(drawable)
                buffer.addCompletedHandler { [weak self] buffer in
                    DispatchQueue.main.async {
                        guard let self, !self.tornDown, self.running, self.unlocking,
                              self.renderer.map(ObjectIdentifier.init) == rendererID,
                              TutuUnlockPlayback.shared.generation == generation, TutuUnlockPlayback.shared.active else { return }
                        if let error = buffer.error { TutuUnlockPlayback.shared.handoffFailure = error }
                        else { TutuUnlockPlayback.shared.cathedralReady = true }
                    }
                }
                revealFirstFrame(after: buffer)
                buffer.commit()
                lastFrame = frame; view.isPaused = true; previousTime = nil; motion.stop()
            } catch { fail(error) }
        }

        /// Return true while the renderer belongs exclusively to its preparation worker.
        private func prepareFlowerIfNeeded(hour: Double) -> Bool {
            guard !flowerPreparing else { return true }
            guard let renderer, renderer.needsFlowerPreparation(hour: hour) else { return false }
            flowerPreparing = true
            container?.metal.isPaused = true
            TutuCathedralResources.worker.async { [weak self] in
                let result = Result { try renderer.prepareFlower(hour: hour) }
                DispatchQueue.main.async {
                    guard let self, !self.tornDown else { return }
                    self.flowerPreparing = false
                    if self.releaseWhenFlowerReady {
                        self.releaseWhenFlowerReady = false
                        renderer.releaseTransientResources()
                        self.invalidateFracturePreparation()
                    }
                    switch result {
                    case .success: self.invalidateFrame()
                    case .failure(let error): self.fail(error)
                    }
                }
            }
            return true
        }

        private func requestFracturePreparation(_ renderer: TutuCathedralRenderer) {
            guard !fracturePrewarming else { return }
            fracturePrewarming = true
            let generation = fracturePreparationGeneration
            let rendererID = ObjectIdentifier(renderer)
            renderer.prewarmFracture { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, !self.tornDown, self.running,
                          self.fracturePreparationGeneration == generation,
                          self.renderer.map(ObjectIdentifier.init) == rendererID else { return }
                    switch result {
                    case .success: self.invalidateFrame()
                    case .failure(let error): self.fail(error)
                    }
                }
            }
        }

        private func prepareFractureIfNeeded(_ renderer: TutuCathedralRenderer) -> Bool {
            guard renderer.needsFracturePreparation else { return false }
            container?.metal.isPaused = true
            previousTime = nil
            requestFracturePreparation(renderer)
            return true
        }

        func draw(in view: MTKView) {
            guard running, let renderer, let queue = commandQueue else { return }
            let hour = TutuUnlockPlayback.shared.handoffHour ?? TutuClock.hour(for: timeOfDay)
            if prepareFlowerIfNeeded(hour: hour) { return }
            if unlocking { drawUnlockHandoff(in: view, renderer: renderer, queue: queue); return }
            let now = CACurrentMediaTime()
            if prepareFractureIfNeeded(renderer) { return }
            let sceneTime = now - timeOrigin
            let dt = previousTime.map { now - $0 } ?? 0
            previousTime = now
            crackle.enabled = SkinState.shared.crackOnShake
            let restored = renderer.restorationProgress(at: sceneTime) >= 1
            let releaseRestoredResources = restoring && restored
            if !restoring && !restored { crackle.step(dt: dt, at: now * 1000) }
            if crackle.stress > 0 { requestFracturePreparation(renderer) }
            let elapsed = now - (firstVisibleTime ?? now)
            let visibleElapsed = now - (shownAt ?? now)
            let automaticLight = visibleElapsed >= 2.5 && !dragging && now - lastInput > 4 && !reduceMotion
            if visibleElapsed >= 2.5 {
                if automaticLight {
                    let k = min(1, max(0, (visibleElapsed - 2.5) / 4))
                    let ramp = k * k * (3 - 2 * k)
                    target = SIMD2(Float(ramp * 0.075 * sin(elapsed * 0.33)),
                                   Float(ramp * 0.05 * sin(elapsed * 0.21 + 1.2)))
                }
            }
            tilt += (target - tilt) * 0.10
            let frame = TutuCathedralFrame(hour: hour, tilt: tilt,
                time: sceneTime, crack: Float(crackle.level), shatter: Float(crackle.breakLevel))
            let changed = lastFrame.map { !Self.samePresentation($0, frame) } ?? true
            if changed || renderer.isAnimating(at: sceneTime) {
                guard let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
                do {
                    try renderer.encode(commandBuffer: buffer, target: drawable.texture, frame: frame)
                    presentation.register(drawable, hour: frame.hour, buffer: buffer)
                    buffer.present(drawable)
                    revealFirstFrame(after: buffer)
                    buffer.commit()
                    lastFrame = frame
                    if firstVisibleTime == nil { firstVisibleTime = now; shownAt = now }
                    TutuUnlockPlayback.shared.handoffHour = nil
                } catch { fail(error); return }
            }
            if releaseRestoredResources {
                restoring = false
                crackle.suspendInput()
                renderer.releaseTransientResources()
                invalidateFracturePreparation()
            }
            refreshRestoreButton()
            pauseIfIdle(now: now, frame: frame, automaticLight: automaticLight)
        }

        @objc private func restorePieces() {
            guard running, !flowerPreparing, !restoring, crackle.breakLevel > 0,
                  renderer?.restore(at: CACurrentMediaTime() - timeOrigin) == true else { return }
            restoring = true
            crackle.suspendInput()
            refreshRestoreButton()
            wake()
        }

        @objc private func accessibilityRestore(_ action: UIAccessibilityCustomAction) -> Bool {
            let wasRestoring = restoring
            restorePieces()
            return !wasRestoring && restoring
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard running, let container, touch.view !== container.restoreButton else { return false }
            let point = touch.location(in: container.window)
            guard let window = container.window else { return false }
            // Leave the whole edge-start stream to the existing paging recognizers.
            return point.x > 16 && point.x < window.bounds.width - 16
        }

        @objc private func drag(_ pan: TutuScrubGesture) {
            guard running, let container else { return }
            let point = pan.location(in: container)
            switch pan.state {
            case .began:
                dragging = true; dragOrigin = point; dragTarget = target
            case .changed:
                target.x = min(0.30, max(-0.30, dragTarget.x + Float((point.x - dragOrigin.x) / max(1, container.metal.bounds.width)) * 0.55))
                target.y = min(0.22, max(-0.22, dragTarget.y + Float((point.y - dragOrigin.y) / max(1, container.metal.bounds.height)) * 0.45))
            case .ended, .cancelled, .failed:
                dragging = false; crackle.release()
            default: break
            }
            lastInput = CACurrentMediaTime()
            wake()
        }

        private func feed(touch: UITouch, event: UIEvent) {
            guard running, !restoring, let container else { return }
            crackle.enabled = SkinState.shared.crackOnShake
            let samples = event.coalescedTouches(for: touch) ?? [touch]
            for sample in samples {
                let point = sample.location(in: container)
                crackle.point(x: Double(point.x), y: Double(point.y), at: sample.timestamp * 1000)
            }
            wake()
        }

        private func fail(_ error: Error) {
            if TutuUnlockPlayback.shared.active { TutuUnlockPlayback.shared.handoffFailure = error }
            stop()
            renderer = nil
            let retired = resources
            resources = nil
            commandQueue = nil
            TutuCathedralResources.dispose(retired)
            container?.showFailure("瓷片没有载入：\(error.localizedDescription)")
        }

    }
}

private final class TutuMetalContainer: UIView {
    let metal = MTKView(frame: .zero)
    let restoreButton = UIButton(type: .system)
    var onVisibilityChanged: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 12.0 / 255, green: 10.0 / 255, blue: 12.0 / 255, alpha: 1)
        metal.colorPixelFormat = .bgra8Unorm
        metal.framebufferOnly = false
        metal.isPaused = true
        metal.alpha = 0
        metal.enableSetNeedsDisplay = false
        metal.isUserInteractionEnabled = false
        metal.isAccessibilityElement = true
        metal.accessibilityLabel = "骨瓷大教堂"
        addSubview(metal)
        restoreButton.setTitle("复原", for: .normal)
        restoreButton.titleLabel?.font = .systemFont(ofSize: 12)
        restoreButton.tintColor = UIColor(red: 0.82, green: 0.79, blue: 0.73, alpha: 1)
        restoreButton.backgroundColor = UIColor(white: 0.08, alpha: 0.65)
        restoreButton.layer.cornerRadius = 16
        restoreButton.accessibilityLabel = "复原大教堂碎片"
        restoreButton.isHidden = true
        addSubview(restoreButton)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fittedWidth = min(bounds.width, bounds.height * 390 / 844)
        let size = CGSize(width: floor(fittedWidth), height: floor(fittedWidth * 844 / 390))
        metal.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                             width: size.width, height: size.height)
        restoreButton.frame = CGRect(x: bounds.midX - 40, y: max(safeAreaInsets.top, bounds.height * 0.78), width: 80, height: 32)
        onVisibilityChanged?()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); onVisibilityChanged?() }

    func showFailure(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = restoreButton.tintColor
        label.font = .systemFont(ofSize: 13)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
    }
}

/// UIPan keeps native gesture arbitration; raw coalesced samples retain scrub timing.
private final class TutuScrubGesture: UIPanGestureRecognizer {
    var samples: ((UITouch, UIEvent) -> Void)?
    var released: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first { samples?(touch, event) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let touch = touches.first { samples?(touch, event) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event); released?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event); released?()
    }
    override func reset() { super.reset(); released?() }
}
#endif
#endif
