#if PERSONAL_APPS
#if os(iOS)
import Foundation
import Metal
import simd
import MetalPerformanceShaders

/// v4 drawGlass: quarter-size downsample, four separable blur passes, then the complete glass layout.
/// One instance is encoded serially on one command queue; all scratch textures are allocated once.
final class TutuPage0Glass {
    private struct Uniforms {
        var panel: SIMD4<Float>
        var lightAndPixel: SIMD4<Float>
    }
    private let width: Int
    private let height: Int
    private let smallA: MTLTexture
    private let smallB: MTLTexture
    private let down: MTLRenderPipelineState
    private let blur: MTLRenderPipelineState
    private let glass: MTLRenderPipelineState
    private let pass = MTLRenderPassDescriptor()

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TutuPage0Glass", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    init(device: MTLDevice, library: MTLLibrary, width: Int = 804, height: Int = 1748) throws {
        guard width > 0, height > 0 else { throw Self.failure("Invalid glass dimensions") }
        self.width = width
        self.height = height
        func texture() throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: max(1, Int((Double(width) / 4).rounded())),
                height: max(1, Int((Double(height) / 4).rounded())), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw Self.failure("Cannot allocate glass blur texture")
            }
            return texture
        }
        smallA = try texture()
        smallB = try texture()
        func pipeline(_ name: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "tutuPage0GlassVertex")
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                throw Self.failure("Missing shader: \(name)")
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        down = try pipeline("tutuPage0GlassDown")
        blur = try pipeline("tutuPage0GlassBlur")
        glass = try pipeline("tutuPage0GlassFragment")
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
    }

    func encode(commandBuffer: MTLCommandBuffer, scene: MTLTexture, target: MTLTexture,
                tilt: TutuPage0Vector, cardHeight: Double = 609) throws {
        guard scene !== target, scene.width == width, scene.height == height,
              target.width == width, target.height == height,
              scene.pixelFormat == .bgra8Unorm, target.pixelFormat == .bgra8Unorm,
              scene.sampleCount == 1, target.sampleCount == 1,
              tilt.x.isFinite, tilt.y.isFinite, cardHeight.isFinite, cardHeight > 36 else {
            throw Self.failure("Glass requires distinct, matching single-sample BGRA8 textures and finite layout inputs")
        }
        func encoder(_ destination: MTLTexture, _ pipeline: MTLRenderPipelineState,
                     _ source: MTLTexture) throws -> MTLRenderCommandEncoder {
            pass.colorAttachments[0].texture = destination
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw Self.failure("Cannot create glass render encoder")
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            return encoder
        }
        var direction = SIMD2<Float>(1 / Float(width), 1 / Float(height))
        let downEncoder = try encoder(smallA, down, scene)
        downEncoder.label = "page0 glass downsample"
        downEncoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        downEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        downEncoder.endEncoding()
        for iteration in 0..<2 {
            let spread: Float = iteration == 0 ? 0.8 : 1.0
            for axis in 0..<2 {
                let input = axis == 0 ? smallA : smallB
                let output = axis == 0 ? smallB : smallA
                direction = axis == 0 ? SIMD2(spread / Float(smallA.width), 0) : SIMD2(0, spread / Float(smallA.height))
                let blurEncoder = try encoder(output, blur, input)
                blurEncoder.label = "page0 glass separable blur"
                blurEncoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                blurEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                blurEncoder.endEncoding()
            }
        }
        let lx = Float(-0.6 + tilt.x * 2.2), ly = Float(-0.8 + tilt.y * 1.8)
        let magnitude = sqrt(lx * lx + ly * ly)
        guard magnitude > 0 else { throw Self.failure("Undefined glass light direction") }
        var uniforms = Uniforms(panel: SIMD4(20, 166, 382, Float(166 + cardHeight)),
            lightAndPixel: SIMD4(lx / magnitude, ly / magnitude, Float(width) / 402, 0))
        let composite = try encoder(target, glass, scene)
        composite.label = "page0 complete v4 glass"
        composite.setFragmentTexture(smallA, index: 1)
        composite.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        composite.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        composite.endEncoding()
    }
}

/// Paper CSS controls only: no text, icons, card, or system chrome.
/// All filters, scratch textures and pass descriptors are prepared once. Like
/// TutuPage0Glass, encode calls must be serial on a single command queue.
final class TutuPage0PaperControls {
    private struct Uniforms {
        var shape: SIMD4<Float>
        var pixels: SIMD4<Float>
    }
    private let width: Int
    private let height: Int
    private let blur14: MPSImageGaussianBlur
    private let blur16: MPSImageGaussianBlur
    private let blurred14: MTLTexture
    private let blurred16: MTLTexture
    private let shadows: [MTLTexture]
    private let composite: MTLRenderPipelineState
    private let lowerBackdrop: MTLTexture
    private let paperBackdrop: MTLRenderPipelineState
    private let pass = MTLRenderPassDescriptor()

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TutuPage0PaperControls", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    init(device: MTLDevice, library: MTLLibrary, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw Self.failure("Invalid paper control dimensions") }
        self.width = width
        self.height = height
        let scale = Float(width) / 402
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = usage
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw Self.failure("Cannot allocate paper control texture")
            }
            return texture
        }
        func pipeline(_ name: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "tutuPage0GlassVertex")
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = format
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                throw Self.failure("Missing shader: \(name)")
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        // CSS blur() uses its argument as Gaussian standard deviation.
        let upperBlur = MPSImageGaussianBlur(device: device, sigma: 14 * scale)
        let lowerBlur = MPSImageGaussianBlur(device: device, sigma: 16 * scale)
        upperBlur.edgeMode = .clamp
        lowerBlur.edgeMode = .clamp
        func clip(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> MTLRegion {
            let sx = Double(width) / 402, sy = Double(height) / 874
            // Include the half-pixel coverage fringe and linear sampler's
            // neighboring texels; do not crop the full source/kernel support.
            let x = max(0, Int(floor(left * sx)) - 1)
            let y = max(0, Int(floor(top * sy)) - 1)
            let endX = min(width, Int(ceil(right * sx)) + 1)
            let endY = min(height, Int(ceil(bottom * sy)) + 1)
            return MTLRegionMake2D(x, y, endX - x, endY - y)
        }
        upperBlur.clipRect = clip(338, 70, 382, 114)
        lowerBlur.clipRect = clip(20, 788, 382, 832)
        // MPS offset is the source position corresponding to clipRect.origin,
        // not an additional translation. Preserve identity scene coordinates.
        upperBlur.offset = MPSOffset(x: upperBlur.clipRect.origin.x, y: upperBlur.clipRect.origin.y, z: 0)
        lowerBlur.offset = MPSOffset(x: lowerBlur.clipRect.origin.x, y: lowerBlur.clipRect.origin.y, z: 0)
        blur14 = upperBlur
        blur16 = lowerBlur
        blurred14 = try texture(.bgra8Unorm, [.shaderRead, .shaderWrite])
        blurred16 = try texture(.bgra8Unorm, [.shaderRead, .shaderWrite])
        composite = try pipeline("tutuPage0PaperControlsFragment", .bgra8Unorm)
        lowerBackdrop = try texture(.bgra8Unorm, [.renderTarget, .shaderRead])
        paperBackdrop = try pipeline("tutuPage0PaperBackdropFragment", .bgra8Unorm)
        let maskPipeline = try pipeline("tutuPage0PaperShadowMask", .r8Unorm)
        let mask = try texture(.r8Unorm, [.renderTarget, .shaderRead])
        let shadowTextures = try (0..<3).map { _ in
            try texture(.r8Unorm, [.shaderRead, .shaderWrite])
        }
        shadows = shadowTextures
        // CSS box-shadow blur radius is twice the Gaussian standard deviation.
        // These static masks can be filtered once, rather than every scene frame.
        let shadow9 = MPSImageGaussianBlur(device: device, sigma: 9 * scale)
        let shadow10 = MPSImageGaussianBlur(device: device, sigma: 10 * scale)
        shadow9.edgeMode = .zero
        shadow10.edgeMode = .zero
        guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer() else {
            throw Self.failure("Cannot prepare paper control shadows")
        }
        let shapes: [SIMD4<Float>] = [
            SIMD4(360, 98, 0, 22), SIMD4(174, 818, 132, 22), SIMD4(360, 818, 0, 22)
        ]
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        for index in shapes.indices {
            pass.colorAttachments[0].texture = mask
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw Self.failure("Cannot create paper shadow encoder")
            }
            var uniforms = Uniforms(shape: shapes[index],
                pixels: SIMD4(Float(width), Float(height), 0, 0))
            encoder.label = "page0 static CSS paper shadow mask"
            encoder.setRenderPipelineState(maskPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            (index == 0 ? shadow9 : shadow10).encode(commandBuffer: command,
                sourceTexture: mask, destinationTexture: shadowTextures[index])
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        guard command.status == .completed else { throw Self.failure("Incomplete paper shadow initialization") }
        pass.colorAttachments[0].texture = nil
    }

    func encode(commandBuffer: MTLCommandBuffer, scene: MTLTexture, target: MTLTexture,
                cardHeight: Double = 609) throws {
        guard scene !== target, scene.width == width, scene.height == height,
              target.width == width, target.height == height,
              scene.pixelFormat == .bgra8Unorm, target.pixelFormat == .bgra8Unorm,
              scene.sampleCount == 1, target.sampleCount == 1,
              cardHeight.isFinite, cardHeight > 0 else {
            throw Self.failure("Paper controls require distinct, matching single-sample BGRA8 textures")
        }
        // The CSS card precedes search/gear but follows plus. Reproduce its
        // opaque paper only in the lower controls' backdrop-filter input.
        // Actual foreground card/text still belong to SwiftUI.
        var uniforms = Uniforms(shape: SIMD4(Float(cardHeight), 0, 0, 0),
            pixels: SIMD4(Float(width), Float(height), 0, 0))
        pass.colorAttachments[0].texture = lowerBackdrop
        guard let backdrop = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw Self.failure("Cannot create paper backdrop encoder")
        }
        backdrop.label = "page0 lower controls CSS paper backdrop"
        backdrop.setRenderPipelineState(paperBackdrop)
        backdrop.setFragmentTexture(scene, index: 0)
        backdrop.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        backdrop.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        backdrop.endEncoding()
        blur14.encode(commandBuffer: commandBuffer, sourceTexture: scene, destinationTexture: blurred14)
        blur16.encode(commandBuffer: commandBuffer, sourceTexture: lowerBackdrop, destinationTexture: blurred16)
        pass.colorAttachments[0].texture = target
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw Self.failure("Cannot create paper control compositor")
        }
        uniforms.shape = .zero
        encoder.label = "page0 CSS paper controls"
        encoder.setRenderPipelineState(composite)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentTexture(blurred14, index: 1)
        encoder.setFragmentTexture(blurred16, index: 2)
        for index in shadows.indices { encoder.setFragmentTexture(shadows[index], index: 3 + index) }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
#endif
#endif
