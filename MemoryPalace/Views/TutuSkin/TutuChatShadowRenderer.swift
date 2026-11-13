#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Metal

enum TutuChatMaterial {
    case card, felt, lace
}

/// Produces only the two-filter chain's black, straight-alpha background.
/// The caller places the original raster over this result, using each raster's rect,
/// and retains this shadow while the source shape (not its printed text) is unchanged.
final class TutuChatShadowRenderer {
    private struct Gaussian {
        let radius: Int
        let weights: MTLBuffer
    }

    private struct BlurUniforms {
        var geometry: SIMD4<Int32> // source origin in output pixels, radius, channel
        var direction: SIMD4<Int32>
        var sampling: SIMD4<Float>
    }

    private struct ShadowUniforms {
        var geometry: SIMD4<Float> // source origin, shadow translation in pixels
        var opacity: SIMD4<Float>
        var sampling: SIMD4<Float>
    }

    private struct Settings {
        let farOffset: CGPoint
        let farSigma: CGFloat
        let farAlpha: Float
        let nearOffset: CGPoint
        let nearSigma: CGFloat
        let nearAlpha: Float

        init(material: TutuChatMaterial, lift: CGFloat = 0) {
            switch material {
            case .card:
                farOffset = Self.cast(1.8 + 6.5 * Double(lift))
                farSigma = floor((2.2 + 3 * lift) * 100 + 0.5) / 100; farAlpha = 0.5
                nearOffset = Self.cast(0.45); nearSigma = 0.7
                nearAlpha = Float(floor(0.34 * (1 - lift) * 100 + 0.5) / 100)
            case .felt:
                farOffset = Self.cast(2.6); farSigma = 1.6; farAlpha = 0.6
                nearOffset = .zero; nearSigma = 0.8; nearAlpha = 0.5
            case .lace:
                farOffset = CGPoint(x: 0.5, y: 0.7); farSigma = 0.9; farAlpha = 0.6
                nearOffset = .zero; nearSigma = 0.5; nearAlpha = 0.45
            }
        }

        private static func cast(_ thickness: Double) -> CGPoint {
            // chat11.js f2 is applied in point space before the device-scale mapping.
            let x = floor((0.48 / 0.62 * thickness) * 100 + 0.5) / 100
            let y = floor(thickness * 100 + 0.5) / 100
            return CGPoint(x: x, y: y)
        }
    }

    private let gpu: TutuChatGPU
    private let blurPipeline: MTLComputePipelineState
    private let firstFilterPipeline: MTLComputePipelineState
    private let behindPipeline: MTLComputePipelineState
    private var gaussians: [Float: Gaussian] = [:]
    private(set) var lastGPUTime = 0.0

    init(gpu: TutuChatGPU) throws {
        self.gpu = gpu
        blurPipeline = try gpu.pipeline("tutuChatShadowBlur")
        firstFilterPipeline = try gpu.pipeline("tutuChatShadowFirstFilter")
        behindPipeline = try gpu.pipeline("tutuChatShadowBehind")
    }

    struct Geometry {
        let bounds: CGRect
        let paintedWidth: Int
        let paintedHeight: Int
        let farOffset: CGPoint
        let nearOffset: CGPoint
    }

    /// Pure geometry shared by whole-message preflight and the actual filter chain.
    static func checkedGeometry(size: CGSize, material: TutuChatMaterial, scale: CGFloat,
                                maxTextureSize: Int, lift: CGFloat = 0) throws -> Geometry {
        guard scale.isFinite, scale > 0 else { throw TutuChatError.textureSize }
        let width = try TutuChatGPU.checkedDimension((size.width * scale).rounded(), limit: maxTextureSize)
        let height = try TutuChatGPU.checkedDimension((size.height * scale).rounded(), limit: maxTextureSize)
        let settings = Settings(material: material, lift: lift)
        let farOffset = CGPoint(x: floor(settings.farOffset.x * scale), y: floor(settings.farOffset.y * scale))
        let nearOffset = CGPoint(x: floor(settings.nearOffset.x * scale), y: floor(settings.nearOffset.y * scale))
        let farSigma = Float(settings.farSigma * scale), nearSigma = Float(settings.nearSigma * scale)
        guard farSigma.isFinite, nearSigma.isFinite,
              farSigma <= Float(maxTextureSize), nearSigma <= Float(maxTextureSize) else { throw TutuChatError.textureSize }
        let source = CGRect(x: 0, y: 0, width: width, height: height)
        let far = shadowBounds(source, offset: farOffset, radius: gaussianRadius(farSigma))
        let near = shadowBounds(source.union(far), offset: nearOffset, radius: gaussianRadius(nearSigma))
        let bounds = source.union(far).union(near)
        _ = try TutuChatGPU.checkedDimension(bounds.width, limit: maxTextureSize)
        _ = try TutuChatGPU.checkedDimension(bounds.height, limit: maxTextureSize)
        return Geometry(bounds: bounds, paintedWidth: width, paintedHeight: height,
                        farOffset: farOffset, nearOffset: nearOffset)
    }

    static func preflight(rect: CGRect, origin: CGPoint = .zero, material: TutuChatMaterial,
                          scale: CGFloat, limit: Int) throws {
        // The compositor snaps both CSS edges before the device-scale mapping.
        let painted = TutuChatConversationLayout.canvasPaintRect(rect.offsetBy(dx: origin.x, dy: origin.y))
        _ = try checkedGeometry(size: painted.size, material: material, scale: scale, maxTextureSize: limit)
        // Direct renderer clients may use the unsnapped raster instead.
        _ = try checkedGeometry(size: rect.size, material: material, scale: scale, maxTextureSize: limit)
    }

    private static func gaussianRadius(_ sigma: Float) -> Int {
        sigma <= 0.03 ? 0 : Int(ceil(3 * sigma))
    }

    /// Must be called on the shared rendering worker: completion waits for the GPU,
    /// so no partially written texture can be published to a view or the cache.
    func render(raster: TutuChatRaster, material: TutuChatMaterial, scale: CGFloat, lift: CGFloat = 0) throws -> TutuChatRaster {
        let geometry = try Self.checkedGeometry(size: raster.rect.size, material: material, scale: scale,
                                               maxTextureSize: gpu.maxTextureSize2D, lift: lift)
        let settings = Settings(material: material, lift: lift)
        let far = try gaussian(sigma: Float(settings.farSigma * scale))
        let near = try gaussian(sigma: Float(settings.nearSigma * scale))
        let farOffset = geometry.farOffset, nearOffset = geometry.nearOffset
        let paintedWidth = geometry.paintedWidth, paintedHeight = geometry.paintedHeight
        let sampling = SIMD2(Float(raster.texture.width) / Float(paintedWidth),
                             Float(raster.texture.height) / Float(paintedHeight))
        let bounds = geometry.bounds
        let width = Int(bounds.width), height = Int(bounds.height)
        let origin = SIMD2<Int32>(Int32(-bounds.minX), Int32(-bounds.minY))
        let horizontal = try gpu.texture(width: width, height: height, format: .r32Float, storage: .private)
        let vertical = try gpu.texture(width: width, height: height, format: .r32Float, storage: .private)
        // Red retains F; green retains B = A + F*(1-A). Both remain unquantized
        // until the final RGBA8 output, rather than losing faint edge coverage per pass.
        let firstFilter = try gpu.texture(width: width, height: height, format: .rg32Float, storage: .private)
        let output = try gpu.texture(width: width, height: height)
        guard let command = gpu.queue.makeCommandBuffer() else { throw TutuChatError.allocation }
        command.label = "Tutu chat two-stage drop shadow"

        try encodeBlur(command: command, input: raster.texture, output: horizontal,
                       gaussian: far, origin: origin, channel: 3, horizontal: true, sampling: sampling)
        try encodeBlur(command: command, input: horizontal, output: vertical,
                       gaussian: far, origin: .zero, channel: 0, horizontal: false)
        var farUniforms = ShadowUniforms(
            geometry: SIMD4(Float(origin.x), Float(origin.y), Float(farOffset.x), Float(farOffset.y)),
            opacity: SIMD4(settings.farAlpha, 0, 0, 0), sampling: SIMD4(sampling.x, sampling.y, 0, 0))
        try encodeShadow(command: command, pipeline: firstFilterPipeline,
                         input: raster.texture, blurred: vertical, output: firstFilter, uniforms: &farUniforms)

        // The second CSS drop-shadow sees the entire first filter, not just A.
        try encodeBlur(command: command, input: firstFilter, output: horizontal,
                       gaussian: near, origin: .zero, channel: 1, horizontal: true)
        try encodeBlur(command: command, input: horizontal, output: vertical,
                       gaussian: near, origin: .zero, channel: 0, horizontal: false)
        var nearUniforms = ShadowUniforms(
            geometry: SIMD4(0, 0, Float(nearOffset.x), Float(nearOffset.y)),
            opacity: SIMD4(settings.nearAlpha, 0, 0, 0), sampling: SIMD4(1, 1, 0, 0))
        try encodeShadow(command: command, pipeline: behindPipeline,
                         input: firstFilter, blurred: vertical, output: output, uniforms: &nearUniforms)
        try gpu.complete(command)
        lastGPUTime = command.gpuEndTime - command.gpuStartTime
        return TutuChatRaster(texture: output,
                              rect: CGRect(x: raster.rect.minX + bounds.minX / scale,
                                           y: raster.rect.minY + bounds.minY / scale,
                                           width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }

    private func gaussian(sigma: Float) throws -> Gaussian {
        if let cached = gaussians[sigma] { return cached }
        // Skia's CSS-filter boundary: SigmaToRadius = ceil(3*sigma), with
        // transparent/decal outside the input. This is not JS gblur's repeated edge.
        // https://github.com/google/skia/blob/main/src/core/SkBlurEngine.h
        // https://github.com/google/skia/blob/main/src/effects/imagefilters/SkBlurImageFilter.cpp
        let radius = Self.gaussianRadius(sigma)
        var weights = [Float](repeating: 1, count: 2 * radius + 1)
        if radius > 0 {
            var sum: Float = 0
            for index in weights.indices {
                let distance = Float(index - radius)
                let weight = exp(-0.5 * distance * distance / (sigma * sigma))
                weights[index] = weight
                sum += weight
            }
            for index in weights.indices { weights[index] /= sum }
        }
        guard let buffer = weights.withUnsafeBytes({ bytes in
            gpu.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { throw TutuChatError.allocation }
        let gaussian = Gaussian(radius: radius, weights: buffer)
        gaussians[sigma] = gaussian
        return gaussian
    }

    private static func shadowBounds(_ input: CGRect, offset: CGPoint, radius: Int) -> CGRect {
        // Chromium floors the CSS-filter translation to integer device pixels.
        // Each filter still expands by its own finite Gaussian support.
        input.insetBy(dx: -CGFloat(radius), dy: -CGFloat(radius))
            .offsetBy(dx: offset.x, dy: offset.y).integral
    }

    private func encodeBlur(command: MTLCommandBuffer, input: MTLTexture, output: MTLTexture,
                            gaussian: Gaussian, origin: SIMD2<Int32>, channel: Int32,
                            horizontal: Bool, sampling: SIMD2<Float> = SIMD2(repeating: 1),
                            extent: SIMD2<Int32> = .zero) throws {
        guard let encoder = try gpu.computeEncoder(command, label: horizontal ? "shadow.blur.horizontal" : "shadow.blur.vertical") else { throw TutuChatError.allocation }
        encoder.setComputePipelineState(blurPipeline)
        encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
        var uniforms = BlurUniforms(geometry: SIMD4(origin.x, origin.y, Int32(gaussian.radius), channel),
                                    direction: SIMD4(horizontal ? 1 : 0, horizontal ? 0 : 1, extent.x, extent.y),
                                    sampling: SIMD4(sampling.x, sampling.y, 0, 0))
        encoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        encoder.setBuffer(gaussian.weights, offset: 0, index: 1)
        dispatch(encoder: encoder, pipeline: blurPipeline, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    private func encodeShadow(command: MTLCommandBuffer, pipeline: MTLComputePipelineState,
                              input: MTLTexture, blurred: MTLTexture, output: MTLTexture,
                              uniforms: inout ShadowUniforms, extent: SIMD2<Int32> = .zero) throws {
        guard let encoder = try gpu.computeEncoder(command, label: "shadow.composite") else { throw TutuChatError.allocation }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(blurred, index: 1)
        encoder.setTexture(output, index: 2)
        uniforms.opacity.y = Float(extent.x); uniforms.opacity.z = Float(extent.y)
        encoder.setBytes(&uniforms, length: MemoryLayout<ShadowUniforms>.stride, index: 0)
        dispatch(encoder: encoder, pipeline: pipeline, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                          width: Int, height: Int) {
        let threads = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threads,
                                    height: max(1, pipeline.maxTotalThreadsPerThreadgroup / threads), depth: 1))
    }

    /// A falling card reuses the maximum-lift scratch, output and Gaussian storage.
    /// Only the kernel weights/uniforms change; no animation frame allocates a texture.
    final class Animation {
        private let renderer: TutuChatShadowRenderer
        private let raster: TutuChatRaster
        private let scale: CGFloat
        private let geometry: Geometry
        private let horizontal: MTLTexture
        private let vertical: MTLTexture
        private let first: MTLTexture
        private let output: MTLTexture
        private let weights: MTLBuffer
        private let near: Gaussian
        init(renderer: TutuChatShadowRenderer, raster: TutuChatRaster, scale: CGFloat) throws {
            self.renderer = renderer; self.raster = raster; self.scale = scale
            let gpu = renderer.gpu
            geometry = try TutuChatShadowRenderer.checkedGeometry(size: raster.rect.size, material: .card,
                scale: scale, maxTextureSize: gpu.maxTextureSize2D, lift: 1)
            let width = Int(geometry.bounds.width), height = Int(geometry.bounds.height)
            horizontal = try gpu.texture(width: width, height: height, format: .r32Float, storage: .private)
            vertical = try gpu.texture(width: width, height: height, format: .r32Float, storage: .private)
            first = try gpu.texture(width: width, height: height, format: .rg32Float, storage: .private)
            output = try gpu.texture(width: width, height: height)
            let capacity = 2 * TutuChatShadowRenderer.gaussianRadius(Float(5.2 * scale)) + 1
            guard let weights = gpu.device.makeBuffer(length: capacity * MemoryLayout<Float>.stride, options: .storageModeShared) else { throw TutuChatError.allocation }
            self.weights = weights
            near = try renderer.gaussian(sigma: Float(0.7 * scale))
        }
        func encode(command: MTLCommandBuffer, lift: CGFloat) throws -> TutuChatRaster {
            let settings = Settings(material: .card, lift: lift)
            let current = try TutuChatShadowRenderer.checkedGeometry(size: raster.rect.size, material: .card,
                scale: scale, maxTextureSize: renderer.gpu.maxTextureSize2D, lift: lift)
            let extent = SIMD2<Int32>(Int32(current.bounds.width), Int32(current.bounds.height))
            let sigma = Float(settings.farSigma * scale)
            let radius = TutuChatShadowRenderer.gaussianRadius(sigma)
            let values = weights.contents().bindMemory(to: Float.self, capacity: weights.length / MemoryLayout<Float>.stride)
            var sum: Float = 0
            for index in 0..<(2 * radius + 1) {
                let distance = Float(index - radius)
                let value = exp(-0.5 * distance * distance / (sigma * sigma))
                values[index] = value; sum += value
            }
            for index in 0..<(2 * radius + 1) { values[index] /= sum }
            let far = Gaussian(radius: radius, weights: weights)
            let origin = SIMD2<Int32>(Int32(-current.bounds.minX), Int32(-current.bounds.minY))
            let sampling = SIMD2(Float(raster.texture.width) / Float(geometry.paintedWidth),
                                 Float(raster.texture.height) / Float(geometry.paintedHeight))
            try renderer.encodeBlur(command: command, input: raster.texture, output: horizontal,
                gaussian: far, origin: origin, channel: 3, horizontal: true, sampling: sampling, extent: extent)
            try renderer.encodeBlur(command: command, input: horizontal, output: vertical,
                gaussian: far, origin: .zero, channel: 0, horizontal: false, extent: extent)
            var uniforms = ShadowUniforms(
                geometry: SIMD4(Float(origin.x), Float(origin.y),
                    Float(floor(settings.farOffset.x * scale)), Float(floor(settings.farOffset.y * scale))),
                opacity: SIMD4(settings.farAlpha, 0, 0, 0), sampling: SIMD4(sampling.x, sampling.y, 0, 0))
            try renderer.encodeShadow(command: command, pipeline: renderer.firstFilterPipeline,
                input: raster.texture, blurred: vertical, output: first, uniforms: &uniforms, extent: extent)
            try renderer.encodeBlur(command: command, input: first, output: horizontal,
                gaussian: near, origin: .zero, channel: 1, horizontal: true, extent: extent)
            try renderer.encodeBlur(command: command, input: horizontal, output: vertical,
                gaussian: near, origin: .zero, channel: 0, horizontal: false, extent: extent)
            uniforms = ShadowUniforms(
                geometry: SIMD4(0, 0, Float(floor(settings.nearOffset.x * scale)), Float(floor(settings.nearOffset.y * scale))),
                opacity: SIMD4(settings.nearAlpha, 0, 0, 0), sampling: SIMD4(1, 1, 0, 0))
            try renderer.encodeShadow(command: command, pipeline: renderer.behindPipeline,
                input: first, blurred: vertical, output: output, uniforms: &uniforms, extent: extent)
            return TutuChatRaster(texture: output, rect: CGRect(
                x: raster.rect.minX + current.bounds.minX / scale, y: raster.rect.minY + current.bounds.minY / scale,
                width: geometry.bounds.width / scale, height: geometry.bounds.height / scale))
        }
    }
}
#endif
#endif
