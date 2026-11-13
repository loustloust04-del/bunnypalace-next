#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import MetalKit

struct TutuChatTextureView: UIViewRepresentable {
    let raster: TutuChatRaster
    var revision: UInt64 = 0
    var isVisible = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: raster.texture.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = false
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        if let previous = context.coordinator.raster,
           previous.texture === raster.texture, context.coordinator.revision == revision,
           context.coordinator.isVisible == isVisible { return }
        context.coordinator.raster = raster
        context.coordinator.revision = revision
        context.coordinator.isVisible = isVisible
        view.drawableSize = CGSize(width: raster.texture.width, height: raster.texture.height)
        guard isVisible else { return }
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.raster = nil
        view.releaseDrawables()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var raster: TutuChatRaster?
        var revision: UInt64 = 0
        var isVisible = true
        private var reportedFailure = false

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            #if DEBUG
            TutuChatDebugCounters.shared.record(.drawEntered)
            #endif
            guard isVisible else {
                #if DEBUG
                TutuChatDebugCounters.shared.record(.drawInvisible)
                #endif
                return
            }
            guard let raster else {
                #if DEBUG
                TutuChatDebugCounters.shared.record(.drawNoRaster)
                #endif
                return
            }
            guard let drawable = view.currentDrawable else {
                #if DEBUG
                TutuChatDebugCounters.shared.record(.drawNoDrawable)
                #endif
                return
            }
            guard let pass = view.currentRenderPassDescriptor else {
                #if DEBUG
                TutuChatDebugCounters.shared.record(.drawNoPass)
                #endif
                return
            }
            do {
                let queue = try TutuChatGPU.commandQueue(device: raster.texture.device)
                guard let pipeline = TutuChatGPU.texturePipeline(device: raster.texture.device),
                      let command = queue.makeCommandBuffer(),
                      let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw TutuChatError.allocation }
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(raster.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
                command.addCompletedHandler { completed in
                    withExtendedLifetime(raster) {}
                    #if DEBUG
                    TutuChatDebugCounters.shared.record(completed.status == .completed ? .textured : .otherError)
                    #endif
                }
                command.present(drawable)
                command.commit()
                reportedFailure = false
            } catch {
                #if DEBUG
                TutuChatDebugCounters.shared.record(.otherError)
                #endif
                if !reportedFailure { print("[TutuChat] texture presentation failed: \(error)"); reportedFailure = true }
            }
        }
    }
}
#endif
#endif
