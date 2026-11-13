#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import QuartzCore
import Metal
import zlib

struct TutuWuDiagnostics {
    var generation: UInt64 = 0
    var ready = false
    var submitted = 0
    var completed = 0
    var dropped = 0
    // Declarations, not measurements: the production path has no readback or wait call at all.
    let readbacks = 0
    let waits = 0
    var cacheBuilds = 0
    var cacheCount = 0
    var peakCacheCount = 0
    var cacheBytes = 0
    var gpuMedianSeconds = 0.0
    var gpuP95Seconds = 0.0
    var lastGPUSeconds = 0.0
    var readyGeneration: UInt64?
    var readyWallpaper: String?
    var readyViewport: CGSize?
}

/// Only the serial preparation/submission queue touches Metal encoders or acquires drawables.
final class TutuWuRenderer {
    struct Uniforms {
        var lamp, candle, pile, ground, sheen, spec, glint, canvas: SIMD4<Float>
        var viewport: SIMD4<Float> = .zero
    }
    struct Lighting {
        let lights: [MTLTexture]
        let regions: [SIMD4<Float>]
        let lamp: MTLTexture
        var allocatedSize: Int { lights.reduce(lamp.allocatedSize) { $0 + $1.allocatedSize } }
    }
    fileprivate final class Allocation {
        let released: () -> Void
        init(released: @escaping () -> Void) { self.released = released }
        deinit { released() }
    }
    final class Cache {
        let generation: UInt64
        let viewport: CGSize
        let material, normals, candle: MTLTexture
        let lighting: Lighting
        let images: [String: CGImage]
        let imageBytes: Int
        var uniforms: Uniforms
        fileprivate let allocation: Allocation
        var allocatedSize: Int { material.allocatedSize + normals.allocatedSize + candle.allocatedSize }
        fileprivate init(generation: UInt64, viewport: CGSize, material: MTLTexture, normals: MTLTexture, candle: MTLTexture, lighting: Lighting, images: [String: CGImage], uniforms: Uniforms, allocation: Allocation) {
            self.generation = generation; self.viewport = viewport
            self.material = material; self.normals = normals; self.candle = candle
            self.lighting = lighting
            self.images = images; self.imageBytes = images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            self.uniforms = uniforms; self.allocation = allocation
        }
        func activated(generation: UInt64) -> Cache {
            Cache(generation: generation, viewport: viewport, material: material, normals: normals, candle: candle, lighting: lighting, images: images, uniforms: uniforms, allocation: allocation)
        }
    }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let preparePipeline: MTLComputePipelineState
    private let wallPipeline: MTLRenderPipelineState
    private let lightPipeline: MTLRenderPipelineState
    private let inflight = DispatchSemaphore(value: 3)
    private let lock = NSLock()
    private var statistics = TutuWuDiagnostics()
    // Bounded histogram: 0.1 ms buckets, including an overflow bucket. No frame-sized arrays.
    private var gpuHistogram = [Int](repeating: 0, count: 1001)
    private var gpuSamples = 0
    var onDiagnostics: ((TutuWuDiagnostics) -> Void)?
    var onCacheReleased: (() -> Void)?
    private var allocations: [UUID: (bytes: Int, lightingID: ObjectIdentifier, lightingBytes: Int)] = [:]
    var cacheCount: Int { lock.lock(); defer { lock.unlock() }; return statistics.cacheCount }
    private var presentationObserver: ((Double, UInt64) -> Void)?
    private var completionObserver: ((Double, UInt64) -> Void)?
    var onError: ((Error, UInt64) -> Void)?
    var captureNextFrame: ((MTLTexture, MTLTexture, MTLCommandBuffer) -> Void)?
    var captureGeneration: UInt64 = 0

    func setPresentationObserver(_ observer: ((Double, UInt64) -> Void)?) {
        lock.lock(); presentationObserver = observer; lock.unlock()
    }

    func setCompletionObserver(_ observer: ((Double, UInt64) -> Void)?) {
        lock.lock(); completionObserver = observer; lock.unlock()
    }

    init(library: MTLLibrary?) throws {
        guard let device = library?.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = library ?? device.makeDefaultLibrary(),
              let prepare = library.makeFunction(name: "tutuWuPrepare"),
              let vertex = library.makeFunction(name: "tutuWuVertex"),
              let wall = library.makeFunction(name: "tutuWuViewport"),
              let light = library.makeFunction(name: "tutuWuLight") else { throw TutuWuError.metal("wall pipeline") }
        self.device = device; self.queue = queue
        preparePipeline = try device.makeComputePipelineState(function: prepare)
        func pipeline(_ fragment: MTLFunction) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        wallPipeline = try pipeline(wall); lightPipeline = try pipeline(light)
    }

    func configure(_ wall: CAMetalLayer, _ light: CAMetalLayer, viewport: CGSize, displayScale: CGFloat) {
        for (layer, scale) in [(wall, displayScale), (light, CGFloat(2))] {
            layer.device = device; layer.pixelFormat = .bgra8Unorm
            // The acceptance host temporarily disables framebufferOnly for its own capture blit.
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
            layer.drawableSize = CGSize(width: max(1, (viewport.width * scale).rounded()), height: max(1, (viewport.height * scale).rounded()))
            layer.contentsScale = scale
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        wall.isOpaque = true; light.isOpaque = false
    }

    func beginGeneration(_ generation: UInt64) {
        lock.lock(); statistics.generation = generation; statistics.ready = false; lock.unlock()
    }

    func markReady(_ generation: UInt64, wallpaper: String, viewport: CGSize) {
        lock.lock()
        guard statistics.generation == generation else { lock.unlock(); return }
        statistics.ready = true
        statistics.readyGeneration = generation; statistics.readyWallpaper = wallpaper; statistics.readyViewport = viewport
        let snapshot = statistics; lock.unlock(); onDiagnostics?(snapshot)
    }

    private func allocation(bytes: Int, lighting: Lighting) -> Allocation {
        let id = UUID()
        lock.lock()
        allocations[id] = (bytes, ObjectIdentifier(lighting.lamp), lighting.allocatedSize)
        statistics.cacheBuilds += 1
        statistics.cacheCount = allocations.count
        statistics.peakCacheCount = max(statistics.peakCacheCount, allocations.count)
        statistics.cacheBytes = allocatedCacheBytes()
        lock.unlock()
        return Allocation { [self] in
            lock.lock()
            allocations.removeValue(forKey: id)
            statistics.cacheCount = allocations.count
            statistics.cacheBytes = allocatedCacheBytes()
            let snapshot = statistics
            lock.unlock()
            onDiagnostics?(snapshot)
            onCacheReleased?()
        }
    }

    private func allocatedCacheBytes() -> Int {
        var bytes = 0
        var firstLighting: ObjectIdentifier?
        for allocation in allocations.values {
            bytes += allocation.bytes
            if allocation.lightingID != firstLighting {
                bytes += allocation.lightingBytes
                firstLighting = allocation.lightingID
            }
        }
        return bytes
    }

    private func current(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return statistics.generation == generation
    }

    @discardableResult
    func prepare(assets: TutuWuAssets, wallpaper: String, viewport: CGSize, generation: UInt64, lighting: Lighting, completion: @escaping (Result<Cache, Error>) -> Void) throws -> Cache {
        guard let paper = assets.manifest.papers[wallpaper] else { throw TutuWuError.resource(wallpaper) }
        // Sub-predicted framebuffer bytes preserve all four normal-map channels.
        let compressed = try Data(contentsOf: assets.directory.appendingPathComponent("wall-\(wallpaper).rgba.sub.zlib"), options: .mappedIfSafe)
        let alignment = device.minimumLinearTextureAlignment(for: .rgba8Unorm)
        let stride = (2340 * 4 + alignment - 1) / alignment * alignment
        guard let buffer = device.makeBuffer(length: stride * 1266, options: .storageModeShared) else { throw TutuWuError.metal("material staging") }
        let bytes = buffer.contents().bindMemory(to: UInt8.self, capacity: stride * 1266)
        var size = uLongf(2340 * 1266 * 4)
        let status = compressed.withUnsafeBytes { input in
            uncompress(bytes, &size, input.bindMemory(to: Bytef.self).baseAddress, uLong(compressed.count))
        }
        guard status == Z_OK, size == uLongf(2340 * 1266 * 4) else { throw TutuWuError.resource("wall material decode") }
        let rowBytes = 2340 * 4
        for y in 0..<1266 {
            let start = y * rowBytes
            for x in 4..<rowBytes { bytes[start + x] = bytes[start + x] &+ bytes[start + x - 4] }
        }
        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ usage: MTLTextureUsage) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = usage; d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw TutuWuError.metal("cache texture") }; return t
        }
        for y in (0..<1266).reversed() {
            memmove(buffer.contents().advanced(by: y * stride), buffer.contents().advanced(by: y * rowBytes), rowBytes)
        }
        // iOS Simulator rejects linear textures on non-private buffers ("Linear texture can only be
        // created on buffers with MTLStorageModePrivate"); copy the staging bytes into a private
        // texture with a blit instead, so every platform takes the same path.
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2340, height: 1266, mipmapped: false)
        sourceDescriptor.storageMode = .private; sourceDescriptor.usage = .shaderRead
        guard let source = device.makeTexture(descriptor: sourceDescriptor) else { throw TutuWuError.metal("material staging texture") }
        let scale = viewport.height / 844
        let width = max(1, Int((1560 * scale * 1.5).rounded())), height = max(1, Int((viewport.height * 1.5).rounded()))
        let material = try texture(.rgba16Float, width, height, [.shaderRead, .shaderWrite])
        let normals = try texture(.rgba16Float, width, height, [.shaderRead, .shaderWrite])
        let candleTexture = try texture(.rgba16Float, width, height, [.shaderRead, .shaderWrite])
        func vector(_ a: [Float], _ w: Float = 0) -> SIMD4<Float> { SIMD4(a[0], a[1], a[2], w) }
        let candle = assets.manifest.candle
        var uniforms = Uniforms(lamp: SIMD4(0, Float(140 + 25 * sin(1.0)), 600, 0), candle: SIMD4(Float(candle.x), Float(candle.y), 120, 0), pile: vector(paper.pile), ground: vector(paper.ground), sheen: vector(paper.sheen), spec: vector(paper.spec), glint: vector(paper.glint, paper.shin), canvas: SIMD4(Float(width), Float(height), Float((1560 * scale * 2).rounded()), Float((viewport.height * 2).rounded())))
        let allocation = allocation(bytes: material.allocatedSize + normals.allocatedSize + candleTexture.allocatedSize, lighting: lighting)
        let cache = Cache(generation: generation, viewport: viewport, material: material, normals: normals, candle: candleTexture, lighting: lighting, images: assets.images, uniforms: uniforms, allocation: allocation)
        guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { throw TutuWuError.metal("cache encoder") }
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: stride, sourceBytesPerImage: stride * 1266,
                  sourceSize: MTLSize(width: 2340, height: 1266, depth: 1),
                  to: source, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        guard let encoder = command.makeComputeCommandEncoder() else { throw TutuWuError.metal("cache encoder") }
        encoder.setComputePipelineState(preparePipeline)
        encoder.setTexture(source, index: 0); encoder.setTexture(material, index: 1); encoder.setTexture(normals, index: 2); encoder.setTexture(candleTexture, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let tw = preparePipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: max(1, min(8, preparePipeline.maxTotalThreadsPerThreadgroup / tw)), depth: 1))
        encoder.endEncoding()
        // Staging buffer and source texture live only until this command buffer completes;
        // neither is retained by the cache.
        command.addCompletedHandler { [source, buffer] command in
            _ = source; _ = buffer
            if let error = command.error { completion(.failure(error)) } else { completion(.success(cache)) }
        }
        command.commit()
        lock.lock(); let snapshot = statistics; lock.unlock()
        onDiagnostics?(snapshot)
        return cache
    }

    func lightTexture(_ image: CGImage, mask: Bool = false, crop: Bool = true) throws -> (MTLTexture, SIMD4<Float>) {
        let width = image.width, height = image.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        return try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TutuWuError.resource("light upload") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = raw.bindMemory(to: UInt8.self)
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            if crop {
                for y in 0..<height { for x in 0..<width where bytes[y * rowBytes + x * 4 + 3] != 0 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                } }
            } else { x0 = 0; y0 = 0; x1 = width - 1; y1 = height - 1 }
            if x1 < x0 { x0 = 0; y0 = 0; x1 = 0; y1 = 0 }
            // Zero texels outside the crop are supplied by clamp_to_zero, including the filter border.
            let w = x1 - x0 + 1, h = y1 - y0 + 1
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: mask ? .r8Unorm : .rgba8Unorm, width: w, height: h, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw TutuWuError.metal("light cache") }
            if mask {
                var alpha = [UInt8](repeating: 0, count: w * h)
                for y in 0..<h { for x in 0..<w { alpha[y * w + x] = bytes[(y + y0) * rowBytes + (x + x0) * 4 + 3] } }
                alpha.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
            } else {
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!.advanced(by: y0 * rowBytes + x0 * 4), bytesPerRow: rowBytes)
            }
            return (texture, SIMD4(Float(x0), Float(y0), Float(w), Float(h)))
        }
    }

    /// Called on the submission queue. Never waits for a GPU slot, nor performs a readback.
    @discardableResult
    func render(cache: Cache, offset: CGFloat, wall: CAMetalLayer, light: CAMetalLayer) -> Bool {
        guard current(cache.generation) else { return false }
        guard inflight.wait(timeout: .now()) == .success else { drop(cache.generation); return false }
        guard let wallDrawable = wall.nextDrawable(), let lightDrawable = light.nextDrawable() else {
            inflight.signal(); drop(cache.generation); return false
        }
        guard current(cache.generation) else { inflight.signal(); return false }
        guard let command = queue.makeCommandBuffer() else { inflight.signal(); onError?(TutuWuError.metal("frame command"), cache.generation); return false }
        var u = cache.uniforms
        let scale = cache.viewport.height / 844
        u.lamp.x = Float((offset + cache.viewport.width / 2) / scale)
        u.viewport = SIMD4(Float(cache.viewport.width), Float(cache.viewport.height), Float(offset), Float(cache.lighting.lights.count))
        func encode(_ drawable: CAMetalDrawable, _ pipeline: MTLRenderPipelineState) -> Bool {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(cache.material, index: 0); encoder.setFragmentTexture(cache.normals, index: 1); encoder.setFragmentTexture(cache.candle, index: 2)
            encoder.setFragmentTexture(cache.lighting.lamp, index: 3)
            for (index, texture) in cache.lighting.lights.enumerated() { encoder.setFragmentTexture(texture, index: 4 + index) }
            cache.lighting.regions.withUnsafeBytes { raw in
                encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
            }
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
            return true
        }
        guard encode(wallDrawable, wallPipeline), encode(lightDrawable, lightPipeline) else {
            inflight.signal(); onError?(TutuWuError.metal("frame encoder"), cache.generation); return false
        }
        let capture = captureGeneration == cache.generation ? captureNextFrame : nil
        captureNextFrame = nil
        capture?(wallDrawable.texture, lightDrawable.texture, command)
        lock.lock(); let completed = completionObserver; lock.unlock()
        #if !targetEnvironment(simulator)
        lock.lock(); let presented = presentationObserver; lock.unlock()
        if let presented {
            wallDrawable.addPresentedHandler { [self] drawable in
                guard current(cache.generation) else { return }
                presented(drawable.presentedTime, cache.generation)
            }
        }
        #endif
        lock.lock(); statistics.submitted += 1; lock.unlock()
        command.addCompletedHandler { [self, cache] command in
            inflight.signal()
            guard current(cache.generation) else { return }
            if let error = command.error { onError?(error, cache.generation); return }
            lock.lock()
            guard statistics.generation == cache.generation else { lock.unlock(); return }
            // Present only after completion AND generation validation. A released renderer's
            // delayed GPU command cannot later replace the new generation's on-screen frame.
            wallDrawable.present(); lightDrawable.present()
            statistics.completed += 1
            let seconds = max(0, command.gpuEndTime - command.gpuStartTime)
            statistics.lastGPUSeconds = seconds
            let bucket = min(1000, Int(seconds * 10_000))
            gpuHistogram[bucket] += 1; gpuSamples += 1
            var total = 0; var medianFound = false
            for i in gpuHistogram.indices {
                total += gpuHistogram[i]
                if !medianFound && total >= (gpuSamples + 1) / 2 { statistics.gpuMedianSeconds = (Double(i) + 0.5) / 10_000; medianFound = true }
                if total >= Int(ceil(Double(gpuSamples) * 0.95)) { statistics.gpuP95Seconds = (Double(i) + 0.5) / 10_000; break }
            }
            let snapshot = statistics; lock.unlock(); onDiagnostics?(snapshot)
            completed?(seconds, cache.generation)
        }
        command.commit()
        return true
    }

    private func drop(_ generation: UInt64) {
        lock.lock(); guard statistics.generation == generation else { lock.unlock(); return }
        statistics.dropped += 1; let snapshot = statistics; lock.unlock(); onDiagnostics?(snapshot)
    }
}
#endif
#endif
