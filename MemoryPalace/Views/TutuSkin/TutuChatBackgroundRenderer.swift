#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Metal

final class TutuChatBackgroundRenderer {
    private struct Uniforms {
        var geometry: SIMD4<Float>
        var silver: SIMD4<Float>
    }
    private let gpu: TutuChatGPU
    private let pipeline: MTLComputePipelineState
    private let tones: [String: MTLTexture]
    private(set) var lastGPUTime = 0.0

    init(gpu: TutuChatGPU) throws {
        self.gpu = gpu
        pipeline = try gpu.pipeline("tutuChatBackground")
        var textures: [String: MTLTexture] = [:]
        for mode in ["day", "dusk", "night"] { textures[mode] = try gpu.image("tone_\(mode).png") }
        tones = textures
    }

    func render(mode: String, scale: CGFloat, size: CGSize) throws -> TutuChatRaster {
        guard let tone = tones[mode] else { throw TutuChatError.image(gpu.resourceURL.appendingPathComponent("tone_\(mode).png")) }
        guard scale.isFinite, scale > 0 else { throw TutuChatError.textureSize }
        let width = try TutuChatGPU.checkedDimension((size.width * scale).rounded(), limit: gpu.maxTextureSize2D)
        let height = try TutuChatGPU.checkedDimension((size.height * scale).rounded(), limit: gpu.maxTextureSize2D)
        let texture = try gpu.texture(width: width, height: height)
        guard let command = gpu.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw TutuChatError.allocation
        }
        let silver: Float = mode == "night" ? 108 : 111
        var uniforms = Uniforms(geometry: SIMD4(Float(scale), mode == "night" ? 0.28 : 0.30, Float(size.width), Float(size.height)),
                                silver: SIMD4(silver / 255, (silver - 4) / 255, (silver - 9) / 255, 0))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0); encoder.setTexture(tone, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let threadWidth = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threadWidth, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth), depth: 1))
        encoder.endEncoding()
        try gpu.complete(command)
        lastGPUTime = command.gpuEndTime - command.gpuStartTime
        return TutuChatRaster(texture: texture, rect: CGRect(origin: .zero, size: size))
    }
}
#endif
#endif
