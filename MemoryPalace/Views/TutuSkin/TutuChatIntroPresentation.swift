#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import UIKit
import MetalKit
import Observation

struct TutuChatCathedralCapture: @unchecked Sendable {
    let texture: MTLTexture
    let rect: CGRect
    let pageSize: CGSize
    let hour: Double
}

private final class TutuChatIntroResources: @unchecked Sendable {
    static let worker = DispatchQueue(label: "TutuChat.intro", qos: .userInitiated)
    let renderer: TutuChatIntroRenderer
    let queue: MTLCommandQueue
    let final: TutuChatRaster
    let size: CGSize
    init(capture: TutuChatCathedralCapture, mode: String) throws {
        let device = capture.texture.device
        guard let library = device.makeDefaultLibrary(),
              let root = Bundle.main.resourceURL?.appendingPathComponent("TutuSkin/chat") else { throw TutuChatError.allocation }
        let gpu = try TutuChatGPU(device: device, library: library, resourceURL: root)
        queue = gpu.queue; size = capture.pageSize
        let scale = CGFloat(capture.texture.width) / capture.rect.width
        let width = try TutuChatGPU.checkedDimension((size.width * scale).rounded(), limit: gpu.maxTextureSize2D)
        let height = try TutuChatGPU.checkedDimension((size.height * scale).rounded(), limit: gpu.maxTextureSize2D)
        let cath = try gpu.texture(width: width, height: height, format: .bgra8Unorm, storage: .private)
        guard let pipeline = TutuChatGPU.texturePipeline(device: device), let command = queue.makeCommandBuffer() else { throw TutuChatError.allocation }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = cath
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(12.0 / 255, 10.0 / 255, 12.0 / 255, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw TutuChatError.allocation }
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: capture.rect.minX * scale, originY: capture.rect.minY * scale,
            width: capture.rect.width * scale, height: capture.rect.height * scale, znear: 0, zfar: 1))
        encoder.setFragmentTexture(capture.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        try gpu.complete(command)
        let tone = try gpu.image("tone_\(mode).png")
        renderer = try TutuChatIntroRenderer(device: device, library: library, cath: cath, tone: tone, mode: mode)
        final = try TutuChatBackgroundRenderer(gpu: gpu).render(mode: mode, scale: scale, size: size)
    }
    static func dispose(_ value: TutuChatIntroResources?) {
        guard let value else { return }
        worker.async { DispatchQueue.main.sync {}; withExtendedLifetime(value) {} }
    }
}

@MainActor @Observable
final class TutuChatIntroPresentation: NSObject {
    static let shared = TutuChatIntroPresentation()
    private(set) var preparing = false
    private(set) var active = false
    private(set) var conversationID: String?
    private(set) var elapsed = TutuChatIntroPhase.duration
    private(set) var finalRaster: TutuChatRaster?
    private var resources: TutuChatIntroResources?
    private var generation = UUID()
    private var sentAt = 0.0
    private var mode = "day"
    private let pagingOwner = UUID()
    private weak var lockedScroll: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private weak var capturedPage: UIView?
    private var capturedPageSize: CGSize?
    private var pageBoundsObservation: NSKeyValueObservation?
    private var chromeCover: UIView?
    private var ending: DispatchWorkItem?
    private let surface = MTKView(frame: .zero, device: nil)
    private let bootstrapDelegate = TutuChatIntroSurface.Coordinator()
    private let frames = TutuChatAnimationDriver()
    private var firstFrameInFlight = false
    var phase: TutuChatIntroPhase { TutuChatIntroPhase(elapsed: elapsed) }

    private override init() {
        super.init()
        surface.colorPixelFormat = .bgra8Unorm; surface.framebufferOnly = true
        surface.isUserInteractionEnabled = false; surface.isOpaque = true
        surface.preferredFramesPerSecond = 60; surface.isPaused = true
        frames.onFrame = { [weak self] _ in self?.surface.draw() }
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(activationChanged), name: .tutuSkinActivationChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(navigationChanged), name: .conversationNavigationRequested, object: nil)
    }
    @discardableResult
    func start(conversationID: String, at time: Double) -> Bool {
        guard SkinState.shared.active, !active, !TutuUnlockPlayback.shared.active else { return false }
        let token = UUID()
        generation = token; self.conversationID = conversationID
        sentAt = time; elapsed = 0; mode = TutuChatStyle.mode; finalRaster = nil
        preparing = true; active = true
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.active else { return }
                self.finish(interrupted: false)
            }
        }
        ending = end
        guard captureChrome() else {
            fail(TutuChatError.allocation)
            return false
        }
        guard TutuMetalView.captureForChat(completion: { [weak self] result in
            guard let self, self.generation == token, self.active else { return }
            switch result {
            case .failure(let error): self.fail(error)
            case .success(let capture):
                guard self.capturedPageSize == capture.pageSize else {
                    self.finish(interrupted: true); return
                }
                self.cancelIfPageSizeChanged()
                guard self.active else { return }
                let mode = self.mode
                TutuChatIntroResources.worker.async {
                    guard !end.isCancelled else { return }
                    let result = Result { try TutuChatIntroResources(capture: capture, mode: mode) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token, self.active else {
                            if case .success(let value) = result { TutuChatIntroResources.dispose(value) }
                            return
                        }
                        switch result {
                        case .success(let value):
                            self.cancelIfPageSizeChanged()
                            guard self.active else {
                                TutuChatIntroResources.dispose(value); return
                            }
                            self.resources = value; self.finalRaster = value.final
                            if !self.prepareSurface() { self.fail(TutuChatError.allocation) }
                        case .failure(let error): self.fail(error)
                        }
                    }
                }
            }
        }) else {
            finish(interrupted: false); return false
        }
        lockedScroll = PagingViewController.sharedScrollView
        if let scroll = lockedScroll {
            PagingViewController.setPage2DragLocked(true, owner: pagingOwner, scrollView: scroll)
            offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                guard abs(scroll.contentOffset.x - scroll.bounds.width) < 0.5 else {
                    self?.finish(interrupted: true); return
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, TutuChatIntroPhase.duration - (CACurrentMediaTime() - time)),
                                      execute: end)
        return true
    }
    func matches(_ id: String?) -> Bool { active && conversationID == id }
    func conversationChanged(_ id: String?) {
        if active && id != conversationID { finish(interrupted: true) }
    }
    func modeChanged() { if active, TutuChatStyle.mode != mode { finish(interrupted: true) } }
    private func cancelIfPageSizeChanged() {
        if active, let capturedPageSize, capturedPage?.bounds.size != capturedPageSize {
            finish(interrupted: true)
        }
    }
    private func captureChrome() -> Bool {
        guard let views = PagingViewController.tutuUnlockSnapshotViews(),
              let snapshot = views.page.snapshotView(afterScreenUpdates: false) else { return false }
        // Match captureForChat's page bounds, not the keyboard-sensitive SwiftUI background.
        capturedPage = views.page
        capturedPageSize = views.page.bounds.size
        pageBoundsObservation = views.page.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.cancelIfPageSizeChanged() }
        }
        let cover = UIView(frame: views.page.convert(views.page.bounds, to: views.snapshot))
        cover.isUserInteractionEnabled = false
        cover.clipsToBounds = true
        snapshot.frame = cover.bounds
        cover.addSubview(snapshot)
        let path = UIBezierPath(rect: CGRect(x: 0, y: 0, width: cover.bounds.width,
                                             height: 122 * cover.bounds.width / 420))
        func includeRestore(_ view: UIView) {
            if view.accessibilityLabel == "复原大教堂碎片", !view.isHidden {
                path.append(UIBezierPath(rect: view.convert(view.bounds, to: views.page)))
                return
            }
            for child in view.subviews { includeRestore(child) }
        }
        includeRestore(views.page)
        let mask = CAShapeLayer()
        mask.frame = cover.bounds; mask.path = path.cgPath
        cover.layer.mask = mask
        views.snapshot.addSubview(cover)
        chromeCover = cover
        return true
    }
    private func prepareSurface() -> Bool {
        guard let page = capturedPage, let resources else { return false }
        surface.device = resources.final.texture.device
        surface.frame = page.bounds; surface.alpha = 0
        surface.delegate = bootstrapDelegate
        page.insertSubview(surface, at: 0)
        firstFrameInFlight = false
        frames.run(until: sentAt + TutuChatIntroPhase.duration)
        return true
    }
    fileprivate func attachSurface(to delegate: TutuChatIntroSurface.Coordinator) -> MTKView {
        surface.delegate = delegate
        return surface
    }
    func finish(interrupted: Bool) {
        ending?.cancel(); ending = nil
        frames.stop()
        generation = UUID(); preparing = false; active = false; elapsed = TutuChatIntroPhase.duration
        if interrupted { TutuChatAnimationTimeline.shared.settleAll() }
        else { TutuChatAnimationTimeline.shared.finishIntro() }
        if let scroll = lockedScroll { PagingViewController.setPage2DragLocked(false, owner: pagingOwner, scrollView: scroll) }
        lockedScroll = nil; offsetObservation = nil
        pageBoundsObservation = nil; capturedPage = nil; capturedPageSize = nil
        chromeCover?.removeFromSuperview(); chromeCover = nil
        firstFrameInFlight = false
        surface.isPaused = true
        if surface.delegate === bootstrapDelegate {
            surface.delegate = nil; surface.removeFromSuperview()
            surface.releaseDrawables(); surface.device = nil
        }
        let retired = resources; resources = nil
        TutuChatIntroResources.dispose(retired)
    }
    func finalBackground(mode: String, scale: CGFloat, size: CGSize) -> TutuChatRaster? {
        guard self.mode == mode, let raster = finalRaster, raster.rect.size == size,
              raster.texture.width == Int(ceil(size.width * scale)),
              raster.texture.height == Int(ceil(size.height * scale)) else { return nil }
        return raster
    }
    func releaseFinalRaster() { if !active { finalRaster = nil } }
    private func fail(_ error: Error) {
        print("[TutuChat] intro: \(error)")
        finish(interrupted: true)
    }
    @objc private func background() { if active { finish(interrupted: true) } }
    @objc private func activationChanged() {
        if !SkinState.shared.active { finish(interrupted: true); finalRaster = nil }
    }
    @objc private func navigationChanged() { if active { finish(interrupted: true) } }

    fileprivate func draw(in view: MTKView) {
        guard active, let resources, !firstFrameInFlight else {
            view.isPaused = true; return
        }
        let time = max(0, CACurrentMediaTime() - sentAt)
        if time >= TutuChatIntroPhase.duration {
            view.isPaused = true; finish(interrupted: false); return
        }
        guard let drawable = view.currentDrawable, let command = resources.queue.makeCommandBuffer() else { return }
        do {
            try resources.renderer.encode(commandBuffer: command, target: drawable.texture, elapsed: time, pointSize: resources.size)
            let token = generation
            let firstFrame = preparing
            if firstFrame { firstFrameInFlight = true; frames.stop() }
            command.addCompletedHandler { [weak self] command in
                withExtendedLifetime(resources) {}
                guard firstFrame || command.status != .completed else { return }
                DispatchQueue.main.async {
                    guard let self, self.active, self.generation == token else { return }
                    guard command.status == .completed else {
                        self.fail(command.error ?? TutuChatError.command("进场 GPU 命令未完成")); return
                    }
                    if self.preparing {
                        self.firstFrameInFlight = false
                        self.surface.alpha = 1; self.preparing = false
                        self.frames.run(until: self.sentAt + TutuChatIntroPhase.duration)
                    }
                }
            }
            command.present(drawable); command.commit()
            elapsed = time
            if phase.chromeOpacity >= 1 {
                chromeCover?.removeFromSuperview(); chromeCover = nil
            } else { chromeCover?.alpha = 1 - phase.chromeOpacity }
        } catch { view.isPaused = true; fail(error) }
    }
}

/// Stage paper fade: above the scrolling cards, below the multiply lamp and shell.
struct TutuChatTopFade: View {
    private static let paper = Color(red: 21 / 255, green: 17 / 255, blue: 15 / 255)
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: Self.paper, location: 0),
                .init(color: Self.paper, location: 99 / 122),
                .init(color: Self.paper.opacity(0.82), location: 104 / 122),
                .init(color: Self.paper.opacity(0.45), location: 110 / 122),
                .init(color: Self.paper.opacity(0.14), location: 116 / 122),
                .init(color: Self.paper.opacity(0), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 122)
            Spacer(minLength: 0)
        }
        .opacity(TutuChatIntroPresentation.shared.phase.shadeOpacity)
        .allowsHitTesting(false)
    }
}

struct TutuChatIntroShades: View {
    private static let stageScale: CGFloat = 912.0 / 844
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(stops: [
                    .init(color: Color(red: 10 / 255, green: 8 / 255, blue: 7 / 255).opacity(0.82), location: 0),
                    .init(color: Color(red: 10 / 255, green: 8 / 255, blue: 7 / 255).opacity(0.55), location: 0.7),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom).frame(height: 122 / Self.stageScale)
                Spacer(minLength: 0)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(red: 10 / 255, green: 8 / 255, blue: 7 / 255).opacity(0.5), location: 0.4),
                    .init(color: Color(red: 10 / 255, green: 8 / 255, blue: 7 / 255).opacity(0.7), location: 1)
                ], startPoint: .top, endPoint: .bottom).frame(height: 119 / Self.stageScale)
            }
        }
        .opacity(TutuChatIntroPresentation.shared.phase.shadeOpacity)
        .allowsHitTesting(false)
    }
}

struct TutuChatIntroSurface: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        TutuChatIntroPresentation.shared.attachSurface(to: context.coordinator)
    }
    func updateUIView(_ view: MTKView, context: Context) {
        view.isPaused = true
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        guard view.delegate === coordinator else { return }
        view.isPaused = true; view.delegate = nil; view.releaseDrawables()
        view.device = nil
    }
    final class Coordinator: NSObject, MTKViewDelegate {
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) { TutuChatIntroPresentation.shared.draw(in: view) }
    }
}

struct TutuChatLifecycle: ViewModifier {
    let viewModel: ConversationViewModel
    @Environment(\.scenePhase) private var scenePhase
    private var responseFailed: Bool {
        guard let node = viewModel.currentPath.last else { return false }
        if case .text(let text)? = ChatDisplaySnapshot.segments(of: node)?.last,
           ChatSystemMessage.split(text, legacy: node.usesLegacyErrorMarker).error != nil { return true }
        return ChatSystemMessage.split(node.content, legacy: node.usesLegacyErrorMarker).error != nil
    }
    func body(content: Content) -> some View {
        if SkinState.shared.active { lifecycle(content) } else { content }
    }
    private func lifecycle(_ content: Content) -> some View {
        content
            .onAppear {
                TutuChatAnimationTimeline.shared.mount(conversationID: viewModel.selectedConversation?.id,
                    existingIDs: viewModel.currentPath.map(\.id))
            }
            .onChange(of: viewModel.selectedConversation?.id) { _, id in
                TutuChatIntroPresentation.shared.conversationChanged(id)
                TutuChatAnimationTimeline.shared.leave()
                TutuChatAnimationTimeline.shared.mount(conversationID: id, existingIDs: viewModel.currentPath.map(\.id))
            }
            .onChange(of: viewModel.currentPath.last?.id) { _, id in
                guard let id, let conversationID = viewModel.selectedConversation?.id,
                      viewModel.isNodeStreaming(nodeId: id, conversationId: conversationID) else { return }
                TutuChatAnimationTimeline.shared.allowAssistant(id: id, at: CACurrentMediaTime())
            }
            .onChange(of: viewModel.isCurrentConvResponding) { _, responding in
                if !responding, responseFailed {
                    TutuChatIntroPresentation.shared.finish(interrupted: true)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { TutuChatAnimationTimeline.shared.settleAll() }
            }
            .onDisappear {
                TutuChatIntroPresentation.shared.finish(interrupted: true)
                TutuChatAnimationTimeline.shared.leave()
            }
    }
}
#endif
#endif
