#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import MetalKit

private final class TutuChatShadowWork: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private let worker = DispatchQueue(label: "TutuChat.falling-shadow", qos: .userInitiated)
    private var gpu: TutuChatGPU?
    private var renderer: TutuChatShadowRenderer?
    private var animation: TutuChatShadowRenderer.Animation?
    private var sourceSize: CGSize?
    private var sourceScale: CGFloat = 0
    func cancel() {
        lock.lock(); generation += 1; lock.unlock()
        worker.async { self.animation = nil; self.renderer = nil; self.gpu = nil; self.sourceSize = nil }
    }
    func render(raster: TutuChatRaster, scale: CGFloat, lift: CGFloat,
                completion: @escaping (Result<TutuChatRaster, Error>) -> Void) {
        lock.lock(); let token = generation; lock.unlock()
        worker.async {
            self.lock.lock(); let valid = token == self.generation; self.lock.unlock()
            guard valid else { return }
            let result = Result<TutuChatRaster, Error> {
                let gpu: TutuChatGPU
                if let prepared = self.gpu { gpu = prepared }
                else {
                    guard let library = raster.texture.device.makeDefaultLibrary(),
                          let root = Bundle.main.resourceURL?.appendingPathComponent("TutuSkin/chat") else { throw TutuChatError.allocation }
                    gpu = try TutuChatGPU(device: raster.texture.device, library: library, resourceURL: root)
                    self.gpu = gpu
                    self.renderer = try TutuChatShadowRenderer(gpu: gpu)
                }
                if self.animation == nil || self.sourceSize != raster.rect.size || self.sourceScale != scale {
                    guard let renderer = self.renderer else { throw TutuChatError.allocation }
                    self.animation = try TutuChatShadowRenderer.Animation(renderer: renderer, raster: raster, scale: scale)
                    self.sourceSize = raster.rect.size; self.sourceScale = scale
                }
                guard let animation = self.animation, let command = gpu.queue.makeCommandBuffer() else { throw TutuChatError.allocation }
                let output = try animation.encode(command: command, lift: lift)
                try gpu.complete(command)
                return output
            }
            DispatchQueue.main.async {
                self.lock.lock(); let valid = token == self.generation; self.lock.unlock()
                if valid { completion(result) }
            }
        }
    }
}

@MainActor private final class TutuChatFallingShadowModel: ObservableObject {
    @Published var raster: TutuChatRaster?
    @Published var revision: UInt64 = 0
    private let work = TutuChatShadowWork()
    private var pending: (TutuChatRaster, CGFloat, CGFloat)?
    private var rendering = false
    @Published private(set) var failed = false
    func load(_ raster: TutuChatRaster, scale: CGFloat, lift: CGFloat) {
        guard !failed else { return }
        pending = (raster, scale, lift)
        draw()
    }
    private func draw() {
        guard !rendering, let request = pending else { return }
        pending = nil; rendering = true
        work.render(raster: request.0, scale: request.1, lift: request.2) { [weak self] result in
            guard let self else { return }
            self.rendering = false
            switch result {
            case .success(let raster):
                self.raster = raster; self.revision &+= 1
                self.draw()
            case .failure(let error):
                print("[TutuChat] falling shadow: \(error)")
                self.pending = nil; self.raster = nil; self.failed = true
                self.work.cancel()
            }
        }
    }
    func stop() { pending = nil; rendering = false; raster = nil; work.cancel() }
}

struct TutuChatFallingShadow: View {
    let nodeID: String
    let source: TutuChatRaster
    let fallback: TutuChatRaster?
    let lift: CGFloat
    @Environment(\.displayScale) private var scale
    @StateObject private var model = TutuChatFallingShadowModel()
    var body: some View {
        Group {
            if let raster = model.raster ?? fallback {
                TutuChatTextureView(raster: raster, revision: model.revision)
                    .frame(width: raster.rect.width, height: raster.rect.height)
                    .offset(x: raster.rect.minX, y: raster.rect.minY)
            }
        }
        .onAppear { model.load(source, scale: scale, lift: lift) }
        .onChange(of: lift) { _, lift in model.load(source, scale: scale, lift: lift) }
        .onChange(of: source.rect) { _, _ in model.load(source, scale: scale, lift: lift) }
        .onChange(of: model.failed) { _, failed in
            if failed {
                TutuChatAnimationTimeline.shared.settle(nodeID: nodeID)
                if TutuChatIntroPresentation.shared.active { TutuChatIntroPresentation.shared.finish(interrupted: true) }
            }
        }
        .onDisappear { model.stop() }
        .allowsHitTesting(false)
    }
}
#endif
#endif
