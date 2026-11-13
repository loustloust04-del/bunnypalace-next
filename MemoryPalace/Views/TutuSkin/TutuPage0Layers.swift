#if PERSONAL_APPS
#if os(iOS)
import Foundation
import QuartzCore
import Metal
import CoreGraphics

final class TutuPage0Layers {
    let root = CAMetalLayer()
    var onError: ((Error) -> Void)?
    var onReady: (() -> Void)?
    var hasFailed: Bool { resourceState.status == .failed }
    private(set) var metalFrames = 0
    private(set) var skippedFrames = 0
    private var model = TutuPage0Model()
    private var hour = 12.0
    private var glass = false
    private var cardHeight = 609.0
    private var active = false
    private var disposed = false
    private var resources: Resources?
    private let slots = DispatchSemaphore(value: 3)
    private var resourceState = TutuPage0ResourceState()
    private static let preparation = DispatchQueue(label: "tutu.page0.resources", qos: .userInitiated)

    private final class Resources: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: TutuPage0Renderer
        let glass: TutuPage0Glass
        let paperControls: TutuPage0PaperControls
        let scene: MTLTexture
        init(width: Int, height: Int) throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let url = Bundle.main.resourceURL?.appendingPathComponent("TutuSkin/page0") else {
                throw TutuPage0Renderer.Failure.unavailable("Metal device, queue or resources")
            }
            let library = try device.makeDefaultLibrary(bundle: .main)
            self.device = device; self.queue = queue
            renderer = try TutuPage0Renderer(device: device, library: library, resourceURL: url, width: width, height: height)
            glass = try TutuPage0Glass(device: device, library: library, width: width, height: height)
            paperControls = try TutuPage0PaperControls(device: device, library: library, width: width, height: height)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: renderer.width, height: renderer.height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let scene = device.makeTexture(descriptor: descriptor) else {
                throw TutuPage0Renderer.Failure.unavailable("scene texture")
            }
            self.scene = scene
        }
    }

    init() {
        root.isOpaque = true
        root.pixelFormat = .bgra8Unorm
        root.framebufferOnly = false
        root.maximumDrawableCount = 3
        root.masksToBounds = true
        root.contentsGravity = .resize
    }

    func layout(size: CGSize, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.bounds = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        guard size.width > 0, size.height > 0 else { return }
        let dpr = min(scale, 2)
        let width = max(1, Int((size.width * dpr).rounded()))
        let height = max(1, Int((size.height * dpr).rounded()))
        let drawableSize = CGSize(width: width, height: height)
        guard root.drawableSize != drawableSize || resourceState.status == .empty else { return }
        root.drawableSize = drawableSize
        guard let generation = resourceState.beginPreparation() else { return }
        prepareResources(generation: generation)
    }

    func updateEligibility(_ eligible: Bool) {
        guard !disposed, let generation = resourceState.updateEligibility(eligible) else { return }
        prepareResources(generation: generation)
    }

    private func prepareResources(generation: Int) {
        let width = Int(root.drawableSize.width), height = Int(root.drawableSize.height)
        resources = nil
        Self.preparation.async { [weak self] in
            let result = Result { try Resources(width: width, height: height) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.disposed else { return }
                switch result {
                case .success(let resources):
                    guard self.resourceState.completePreparation(generation) else { return }
                    self.resources = resources; self.root.device = resources.device
                    self.onReady?()
                    if self.active { self.draw(self.model) }
                case .failure(let error): self.fail(error, generation: generation)
                }
            }
        }
    }

    func configure(hour: Double, glass: Bool, cardHeight: Double) {
        guard self.hour != hour || self.glass != glass || self.cardHeight != cardHeight else { return }
        self.hour = hour; self.glass = glass; self.cardHeight = cardHeight
        if active { draw(model) }
    }

    func setActive(_ value: Bool) { active = value }

    private func fail(_ error: Error, generation: Int) {
        guard !disposed, resourceState.fail(generation) else { return }
        active = false; resources = nil
        onError?(error)
    }

    func draw(_ model: TutuPage0Model) {
        self.model = model
        guard active, !disposed, let resources else { return }
        guard slots.wait(timeout: .now()) == .success else { skippedFrames += 1; return }
        guard let drawable = root.nextDrawable(), let command = resources.queue.makeCommandBuffer() else { slots.signal(); return }
        do {
            try resources.renderer.encode(commandBuffer: command, target: resources.scene, model: model, hour: hour)
            if glass {
                try resources.glass.encode(commandBuffer: command, scene: resources.scene, target: drawable.texture, tilt: model.tilt, cardHeight: cardHeight)
            } else {
                try resources.paperControls.encode(commandBuffer: command, scene: resources.scene,
                                                   target: drawable.texture, cardHeight: cardHeight)
            }
            let slots = slots
            let generation = resourceState.generation
            command.addCompletedHandler { buffer in
                slots.signal()
                if let error = buffer.error {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.disposed, self.active else { return }
                        self.fail(error, generation: generation)
                    }
                }
            }
            command.present(drawable); command.commit(); metalFrames += 1
        } catch {
            slots.signal(); fail(error, generation: resourceState.generation)
        }
    }

    func dispose() {
        active = false; disposed = true
        resources = nil
        resourceState.dispose()
    }
}
#endif
#endif
