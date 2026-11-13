#if PERSONAL_APPS
#if os(iOS)
import Foundation
import Metal
import CoreGraphics

/// Same fitted 390:844 viewport and clear color as the live M1 container.
final class TutuUnlockCathedralTarget {
    let texture: MTLTexture
    private let scene: MTLTexture
    private let cathedral: TutuCathedralRenderer
    private let composite: MTLRenderPipelineState
    private let viewport: MTLViewport

    init(device: MTLDevice, library: MTLLibrary, resources: URL, width: Int, height: Int, pointSize: CGSize) throws {
        let fittedWidth = floor(min(pointSize.width, pointSize.height * 390 / 844))
        let fittedHeight = floor(min(pointSize.width, pointSize.height * 390 / 844) * 844 / 390)
        let sx = Double(width) / pointSize.width, sy = Double(height) / pointSize.height
        let w = max(1, Int((fittedWidth * sx).rounded())), h = max(1, Int((fittedHeight * sy).rounded()))
        viewport = MTLViewport(originX: (Double(width) - Double(w)) / 2, originY: (Double(height) - Double(h)) / 2,
                               width: Double(w), height: Double(h), znear: 0, zfar: 1)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: d) else { throw TutuUnlockError.allocation }
        self.texture = texture
        d.width = w; d.height = h
        guard let scene = device.makeTexture(descriptor: d) else { throw TutuUnlockError.allocation }
        self.scene = scene
        cathedral = try TutuCathedralRenderer(device: device, library: library, resourceURL: resources.appendingPathComponent("TutuSkin/cathedral"))
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "tutuCathedralUpscaleVertex")
        p.fragmentFunction = library.makeFunction(name: "tutuCathedralUpscaleFragment")
        p.colorAttachments[0].pixelFormat = .bgra8Unorm
        composite = try device.makeRenderPipelineState(descriptor: p)
    }
    func encode(commandBuffer: MTLCommandBuffer, hour: Double) throws {
        try cathedral.encode(commandBuffer: commandBuffer, target: scene, frame: TutuCathedralFrame(hour: hour, tilt: .zero, time: 0, crack: 0, shatter: 0))
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = texture
        p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .store
        p.colorAttachments[0].clearColor = MTLClearColor(red: 12.0 / 255, green: 10.0 / 255, blue: 12.0 / 255, alpha: 1)
        guard let e = commandBuffer.makeRenderCommandEncoder(descriptor: p) else { throw TutuUnlockError.allocation }
        e.setViewport(viewport); e.setRenderPipelineState(composite); e.setFragmentTexture(scene, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }
}
#endif
#endif
