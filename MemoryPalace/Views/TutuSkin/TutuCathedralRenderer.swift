#if PERSONAL_APPS
#if os(iOS)
import Foundation
import Metal
import CoreGraphics
import ImageIO
import simd

struct TutuCathedralFrame {
    var hour: Double = 13
    var tilt: SIMD2<Float> = .zero
    var time: Double = 0
    var crack: Float = 0
    var shatter: Float = 0
}

private struct TutuCathedralUniforms {
    var uTime: Float = 0
    var uRestoring: Float = 0
    var uRestore: Float = 0
    var uCrack: Float = 0
    var uFracturePass: Float = 0
    var uReleasedAt: Float = -1
    var uTilt: SIMD2<Float> = .zero
    var uShatter: Float = 0
    var uPlants: Float = 1
    var uRes = SIMD2<Float>(780, 1688)
    var uS: Float = 6.5
    var uDay: Float = 1
    var uNightSpec: Float = 0.10
    var uK = SIMD3<Float>.zero
    var uKr = SIMD3<Float>.zero
    var uKu = SIMD3<Float>.zero
    var uS2 = SIMD3<Float>.zero
    var uS2r = SIMD3<Float>.zero
    var uS2u = SIMD3<Float>.zero
    var uW3 = SIMD3<Float>.zero
    var uW3r = SIMD3<Float>.zero
    var uW3u = SIMD3<Float>.zero
    var uMoon = SIMD3<Float>.zero
    var uFBox = SIMD4<Float>(-50, 40, 300, 300)
    var uBg = SIMD3<Float>(12 / 255, 10 / 255, 12 / 255)
}

private enum TutuCathedralError: Error {
    case missingShader(String)
    case resource(URL)
    case allocation
    case targetFormat
    case fractureNotReady
}

/// Native, fixed-resolution port of the cathedral WebGL renderer. Call on one serial render thread.
final class TutuCathedralRenderer {
    let device: MTLDevice
    #if TUTU_NATIVE_FRAME && TUTU_OVERDRAW
    /// Measurement metallib only. Caller zeroes three row-major UInt32 planes
    /// (base/glaze/shards), and reads them only after GPU completion. Atomics can
    /// inhibit early depth rejection; these are instrumented fragment invocations,
    /// not production hardware overdraw or per-MSAA-sample counts.
    var overdrawCounter: MTLBuffer?
    #endif
    private let pipeline: MTLRenderPipelineState
    private let uncrackedPipeline: MTLRenderPipelineState
    private let upscalePipeline: MTLRenderPipelineState
    private let staticPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let baseDepthState: MTLDepthStencilState
    private let baseBuffer: MTLBuffer
    private let fracturePreparation: FracturePreparation
    private let pixelFormat: MTLPixelFormat
    private let sampleCount: Int
    private let renderWidth: Int
    private let renderHeight: Int
    private var textures: [MTLTexture] = []
    private var color: MTLTexture?
    private var multisample: MTLTexture?
    private var depth: MTLTexture?
    private let flower = TutuCathedralFlower()
    private var lastE: Double = -1
    private var flowerMipmapsPending = false
    private var staticFields: MTLTexture?
    private var staticFieldsDirty = true
    private var glazeBuffer: MTLBuffer?
    private var shardBuffer: MTLBuffer?
    private var glazeBirths: [Float] = []
    private var pieces: [TutuCathedralPiece] = []
    private var lastBreak: Double = 0
    private var animatingUntil: Double = 0
    private var restoreStart: Double = -1
    private var restorePoseTime: Double = 0
    private let restoreDuration: Double = 2.8
    private var lastTime: Double = 0
    private var lastRestore: Double = 0

    convenience init(device: MTLDevice, library: MTLLibrary, resourceURL: URL, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        try self.init(device: device, library: library, resourceURL: resourceURL, pixelFormat: pixelFormat, renderWidth: 780, renderHeight: 1688)
    }

    #if TUTU_NATIVE_FRAME
    /// Comparison-only; the application initializer always uses the original resolution.
    convenience init(device: MTLDevice, library: MTLLibrary, resourceURL: URL, pixelFormat: MTLPixelFormat = .bgra8Unorm, resolutionScale: Double) throws {
        guard resolutionScale.isFinite, resolutionScale > 0, resolutionScale <= 1 else { throw TutuCathedralError.allocation }
        try self.init(device: device, library: library, resourceURL: resourceURL, pixelFormat: pixelFormat,
                      renderWidth: max(1, Int((780 * resolutionScale).rounded())),
                      renderHeight: max(1, Int((1688 * resolutionScale).rounded())))
    }
    #endif

    private init(device: MTLDevice, library: MTLLibrary, resourceURL: URL, pixelFormat: MTLPixelFormat, renderWidth: Int, renderHeight: Int) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw TutuCathedralError.missingShader(name) }
            return f
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try function("tutuCathedralVertex")
        descriptor.fragmentFunction = try function("tutuCathedralFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = sampleCount
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.depthAttachmentPixelFormat = .invalid
        descriptor.rasterSampleCount = 1
        uncrackedPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let upscale = MTLRenderPipelineDescriptor()
        upscale.vertexFunction = try function("tutuCathedralUpscaleVertex")
        upscale.fragmentFunction = try function("tutuCathedralUpscaleFragment")
        upscale.colorAttachments[0].pixelFormat = pixelFormat
        upscalePipeline = try device.makeRenderPipelineState(descriptor: upscale)
        let fields = MTLRenderPipelineDescriptor()
        fields.vertexFunction = try function("tutuCathedralVertex")
        fields.fragmentFunction = try function("tutuCathedralStaticFragment")
        fields.colorAttachments[0].pixelFormat = .rgba32Float
        staticPipeline = try device.makeRenderPipelineState(descriptor: fields)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw TutuCathedralError.allocation }
        depthState = ds
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = false
        guard let bs = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw TutuCathedralError.allocation }
        baseDepthState = bs
        let base: [Float] = [-1,-1,0,0,0,0,0,0, 1,-1,0,0,0,0,0,0, -1,1,0,0,0,0,0,0,
                             -1,1,0,0,0,0,0,0, 1,-1,0,0,0,0,0,0, 1,1,0,0,0,0,0,0]
        guard let buffer = device.makeBuffer(bytes: base, length: base.count * MemoryLayout<Float>.stride) else { throw TutuCathedralError.allocation }
        baseBuffer = buffer
        let names = ["tA", "tA2", "tB", "tT", "tT2", "tV", "tG", "tP"]
        var images: [CGImage] = []
        for name in names {
            let url = resourceURL.appendingPathComponent(name + (name == "tV" || name == "tG" ? ".jpg" : ".png"))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TutuCathedralError.resource(url) }
            images.append(image)
        }
        fracturePreparation = FracturePreparation(device: device, coverage: images[1], width: renderWidth, height: renderHeight, pixelFormat: pixelFormat, sampleCount: sampleCount)
        // PNG numeric channels are data, not sRGB colors; never use an _srgb texture format.
        for image in images.prefix(7) { textures.append(try Self.texture(device: device, image: image)) }
        textures.append(try Self.texture(device: device, width: 1024, height: 1024, pixels: [UInt8](repeating: 0, count: 1024 * 1024 * 4), mipmapped: true))
        textures.append(try Self.texture(device: device, image: images[7]))
        textures.append(try Self.texture(device: device, width: 1, height: 1, pixels: [0,0,0,255]))
        textures.append(try Self.texture(device: device, width: 1, height: 1, pixels: [255,255,255,255]))
    }

    private static func texture(device: MTLDevice, image: CGImage) throws -> MTLTexture {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { storage -> Bool in
            // The source color space avoids a profile conversion of packed RG height bytes.
            guard let context = CGContext(data: storage.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw TutuCathedralError.allocation }
        return try texture(device: device, width: w, height: h, pixels: pixels)
    }

    private static func texture(device: MTLDevice, width: Int, height: Int, pixels: [UInt8], mipmapped: Bool = false) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipmapped)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw TutuCathedralError.allocation }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return texture
    }

    private struct FractureResources {
        let glaze: MTLBuffer
        let shards: MTLBuffer
        let births: [Float]
        let pieces: [TutuCathedralPiece]
        let breakTexture: MTLTexture
        let lossTexture: MTLTexture
        let multisample: MTLTexture?
        let depth: MTLTexture
    }

    #if TUTU_NATIVE_FRAME
    /// Offline lifecycle probes surround the real geometry/GPU build. A thrown
    /// resourcesBuilt probe injects failure only after those resources exist.
    enum FracturePreparationStage: String, Sendable {
        case buildStarted, resourcesBuilt, callbacksReady, buildFinished, retiredResourcesReleased
    }
    typealias FracturePreparationProbe = @Sendable (FracturePreparationStage, UInt64) throws -> Void
    func setFracturePreparationProbe(_ probe: FracturePreparationProbe?) {
        fracturePreparation.setProbe(probe)
    }
    #endif

    /// The condition owns all cross-thread state. The worker retains this object,
    /// never the renderer; installation and mutable piece poses stay on the render thread.
    private final class FracturePreparation: @unchecked Sendable {
        typealias Completion = @Sendable (Result<Double, Error>) -> Void
        private enum State {
            case idle
            case loading
            case ready(FractureResources, Double)
            case installed(Double)
            case failed(Error)
        }
        private let condition = NSCondition()
        private let worker = DispatchQueue(label: "MemoryPalace.Tutu.fracture-preparation", qos: .utility)
        private let device: MTLDevice
        private let coverage: CGImage
        private var state: State = .idle
        private var generation: UInt64 = 0
        private let width: Int
        private let height: Int
        private let pixelFormat: MTLPixelFormat
        private let sampleCount: Int
        private var completions: [(UInt64, Completion)] = []
        #if TUTU_NATIVE_FRAME
        private var probe: FracturePreparationProbe?
        func setProbe(_ probe: FracturePreparationProbe?) {
            condition.lock()
            self.probe = probe
            condition.unlock()
        }
        private func notify(_ stage: FracturePreparationStage, token: UInt64) throws {
            condition.lock()
            let observer = probe
            condition.unlock()
            try observer?(stage, token)
        }
        #endif

        init(device: MTLDevice, coverage: CGImage, width: Int, height: Int, pixelFormat: MTLPixelFormat, sampleCount: Int) {
            self.device = device
            self.coverage = coverage
            self.width = width; self.height = height
            self.pixelFormat = pixelFormat; self.sampleCount = sampleCount
        }

        func start(completion: Completion? = nil) {
            condition.lock()
            defer { condition.unlock() }
            let token = generation
            switch state {
            case .ready(_, let seconds), .installed(let seconds):
                if let completion {
                    worker.async { self.deliver([completion], result: .success(seconds), token: token) }
                }
            case .failed(let error):
                if let completion {
                    worker.async { self.deliver([completion], result: .failure(error), token: token) }
                }
            case .loading:
                if let completion { completions.append((token, completion)) }
            case .idle:
                state = .loading
                if let completion { completions.append((token, completion)) }
                // Enqueue under the same lock as discard, so a replacement build
                // cannot overtake retirement of the old generation's resources.
                worker.async {
                    autoreleasepool { self.runBuild(token: token) }
                    #if TUTU_NATIVE_FRAME
                    try? self.notify(.buildFinished, token: token)
                    #endif
                }
            }
        }

        private func runBuild(token: UInt64) {
            condition.lock()
            let current = token == generation
            condition.unlock()
            guard current else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let result = Result {
                #if TUTU_NATIVE_FRAME
                try notify(.buildStarted, token: token)
                #endif
                let resources = try build()
                #if TUTU_NATIVE_FRAME
                try notify(.resourcesBuilt, token: token)
                #endif
                return resources
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            condition.lock()
            var callbacks: [Completion] = []
            if token == generation {
                switch result {
                case .success(let resources): state = .ready(resources, seconds)
                case .failure(let error): state = .failed(error)
                }
                callbacks = completions.map { $0.1 }
                completions.removeAll(keepingCapacity: true)
            }
            condition.broadcast()
            condition.unlock()
            #if TUTU_NATIVE_FRAME
            try? notify(.callbacksReady, token: token)
            #endif
            deliver(callbacks, result: result.map { _ in seconds }, token: token)
        }

        private func deliver(_ callbacks: [Completion], result: Result<Double, Error>, token: UInt64) {
            for callback in callbacks {
                condition.lock()
                let current = token == generation
                condition.unlock()
                guard current else { return }
                callback(result)
            }
        }

        private func build() throws -> FractureResources {
            let mesh = try TutuCathedralGeometry.make(coverage: coverage)
            guard let glaze = device.makeBuffer(bytes: mesh.glaze, length: mesh.glaze.count * MemoryLayout<Float>.stride),
                  let shards = device.makeBuffer(bytes: mesh.shards, length: mesh.shards.count * MemoryLayout<Float>.stride) else {
                throw TutuCathedralError.allocation
            }
            var births: [Float] = []
            births.reserveCapacity(mesh.glaze.count / 24)
            for i in stride(from: 5, to: mesh.glaze.count, by: 24) { births.append(mesh.glaze[i]) }
            let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
            target.storageMode = .private; target.usage = .renderTarget
            target.sampleCount = sampleCount
            var multisample: MTLTexture?
            if sampleCount > 1 {
                target.textureType = .type2DMultisample
                guard let texture = device.makeTexture(descriptor: target) else { throw TutuCathedralError.allocation }
                multisample = texture
            }
            target.pixelFormat = .depth32Float
            guard let depth = device.makeTexture(descriptor: target) else { throw TutuCathedralError.allocation }
            return FractureResources(
                glaze: glaze, shards: shards, births: births, pieces: mesh.pieces,
                breakTexture: try TutuCathedralRenderer.texture(device: device, width: 780, height: 1688, pixels: mesh.breakPixels),
                lossTexture: try TutuCathedralRenderer.texture(device: device, width: 780, height: 1688, pixels: mesh.lossPixels),
                multisample: multisample, depth: depth)
        }

        func takeReady() throws -> FractureResources? {
            condition.lock()
            defer { condition.unlock() }
            switch state {
            case .ready(let resources, let seconds):
                state = .installed(seconds)
                return resources
            case .failed(let error): throw error
            default: return nil
            }
        }

        func wait() throws -> Double {
            start()
            condition.lock()
            defer { condition.unlock() }
            while true {
                switch state {
                case .ready(_, let seconds), .installed(let seconds): return seconds
                case .failed(let error): throw error
                case .idle, .loading: condition.wait()
                }
            }
        }

        var isReady: Bool {
            condition.lock()
            defer { condition.unlock() }
            switch state {
            case .ready, .installed, .failed: return true
            case .idle, .loading: return false
            }
        }

        func discard(retiring resources: DeferredRelease) {
            condition.lock()
            let retired = DeferredRelease(state)
            let token = generation
            generation &+= 1
            completions.removeAll(keepingCapacity: true)
            state = .idle
            // This serial queue also owns builds: an in-flight build must finish
            // and drop its local result before retirement and the next build.
            // The last reference to uninstalled geometry is destroyed away from UI work.
            worker.async {
                autoreleasepool {
                    retired.release()
                    resources.release()
                }
                #if TUTU_NATIVE_FRAME
                try? self.notify(.retiredResourcesReleased, token: token)
                #endif
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Thread-safe, nonblocking and idempotent. Completion runs off the main thread;
    /// its success value is the first geometry + GPU resource preparation time in seconds.
    func prewarmFracture(completion: (@Sendable (Result<Double, Error>) -> Void)? = nil) {
        fracturePreparation.start(completion: completion)
    }

    /// Blocking preparation for the offscreen harness only; never call from a UI draw.
    @discardableResult func waitForFracture() throws -> Double {
        try fracturePreparation.wait()
    }

    private func receiveFracture() throws {
        guard glazeBuffer == nil, let resources = try fracturePreparation.takeReady() else { return }
        glazeBuffer = resources.glaze
        shardBuffer = resources.shards
        glazeBirths = resources.births
        if pieces.isEmpty { pieces = resources.pieces }
        if lastBreak == 0 && restoreStart < 0 {
            textures[9] = resources.breakTexture
            textures[10] = resources.lossTexture
        }
        multisample = resources.multisample
        depth = resources.depth
    }

    /// Clear the payload explicitly on the worker: merely capturing ARC references
    /// in an async closure could finish before the caller drops its last local copy.
    private final class DeferredRelease: @unchecked Sendable {
        private var resources: Any?
        init(_ resources: Any) { self.resources = resources }
        func release() { resources = nil }
    }

    /// Check before acquiring a drawable after reclamation. Keep the last frame
    /// visible while prewarmFracture completes; encode must not flash a base-only frame.
    var needsFracturePreparation: Bool {
        glazeBuffer == nil && !pieces.isEmpty && !fracturePreparation.isReady
    }

    func needsFlowerPreparation(hour: Double) -> Bool {
        abs(Self.openness(hour) - lastE) >= 1e-4
    }

    /// Call on the preparation worker before transferring the renderer to its render thread.
    func prepareFlower(hour: Double) throws {
        let e = Self.openness(hour)
        guard abs(e - lastE) >= 1e-4 else { return }
        let pixels = try flower.pixels(openness: e)
        textures[7] = try Self.texture(device: device, width: 1024, height: 1024, pixels: pixels, mipmapped: true)
        lastE = e; flowerMipmapsPending = true; staticFieldsDirty = true
    }

    /// Render-thread operation. Preserve loss/break masks and the small piece pose
    /// records so a later asynchronous deterministic rebuild resumes exactly.
    func releaseTransientResources() {
        let retired = DeferredRelease((glazeBuffer, shardBuffer, glazeBirths, multisample, depth, color))
        glazeBuffer = nil; shardBuffer = nil; glazeBirths = []
        multisample = nil; depth = nil; color = nil
        fracturePreparation.discard(retiring: retired)
    }

    private func visibleGlazeTriangles(crack: Float) -> Int {
        var low = 0, high = glazeBirths.count
        while low < high {
            let middle = low + (high - low) / 2
            if glazeBirths[middle] < crack { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    private func releaseShards(level: Double, time: Double) {
        let reset = level < lastBreak - 0.0001
        if reset { animatingUntil = 0 }
        for i in pieces.indices {
            if reset { pieces[i].releasedAt = -1 }
            if pieces[i].releasedAt < 0 && level >= pieces[i].release {
                pieces[i].releasedAt = time
                animatingUntil = max(animatingUntil, time + 7)
            }
        }
        lastBreak = level
    }

    func encode(commandBuffer: MTLCommandBuffer, target: MTLTexture, frame: TutuCathedralFrame) throws {
        try encode(commandBuffer: commandBuffer, target: target, frame: frame, nextCommandBuffer: nil)
    }

    #if TUTU_NATIVE_FRAME
    /// All buffers must be submitted in returned order to the same command queue.
    /// No renderer mutation or resource reclamation is allowed between encoding
    /// and submission. The ordinary encode path still uses a single render pass.
    func encodeProfiled(target: MTLTexture, frame: TutuCathedralFrame,
                        makeCommandBuffer: @escaping (String) throws -> MTLCommandBuffer) throws -> [(name: String, commandBuffer: MTLCommandBuffer)] {
        var buffers: [(name: String, commandBuffer: MTLCommandBuffer)] = []
        try encode(commandBuffer: nil, target: target, frame: frame) { name in
            let buffer = try makeCommandBuffer(name)
            buffer.label = "cathedral-" + name
            buffers.append((name, buffer))
            return buffer
        }
        return buffers
    }
    #endif

    private func encode(commandBuffer: MTLCommandBuffer?, target: MTLTexture, frame: TutuCathedralFrame,
                        nextCommandBuffer: ((String) throws -> MTLCommandBuffer)?) throws {
        guard target.pixelFormat == pixelFormat else { throw TutuCathedralError.targetFormat }
        #if TUTU_NATIVE_FRAME && TUTU_OVERDRAW
        guard let overdrawCounter,
              overdrawCounter.length >= 3 * renderWidth * renderHeight * MemoryLayout<UInt32>.stride else {
            throw TutuCathedralError.allocation
        }
        #endif
        let hour = frame.hour, time = frame.time
        guard !needsFracturePreparation else { throw TutuCathedralError.fractureNotReady }
        func command(_ name: String) throws -> MTLCommandBuffer {
            if let nextCommandBuffer { return try nextCommandBuffer(name) }
            guard let commandBuffer else { throw TutuCathedralError.allocation }
            return commandBuffer
        }
        try prepareFlower(hour: hour)
        if flowerMipmapsPending {
            guard let blit = try command("flower-mipmaps").makeBlitCommandEncoder() else { throw TutuCathedralError.allocation }
            blit.generateMipmaps(for: textures[7]); blit.endEncoding()
            flowerMipmapsPending = false
        }
        let crack = min(max(frame.crack, 0), 1)
        let shatter = crack >= 0.999 ? min(max(frame.shatter, 0), 1) : 0
        let restoring = restoreStart >= 0 && crack > 0
        let progress = restorationProgress(at: time)
        lastTime = time; lastRestore = progress
        if crack > 0 && glazeBuffer == nil { prewarmFracture() }
        try receiveFracture()
        if glazeBuffer != nil && !restoring { releaseShards(level: Double(shatter), time: time) }
        var u = TutuCathedralUniforms()
        u.uRes = SIMD2(Float(renderWidth), Float(renderHeight))
        u.uTime = Float(restoring ? restorePoseTime : time)
        u.uRestoring = restoring ? 1 : 0; u.uRestore = Float(progress)
        u.uCrack = crack; u.uShatter = restoring ? 1 : shatter; u.uTilt = frame.tilt
        let day = Self.dayWeight(hour)
        u.uDay = Float(day)
        let sun = min(max((hour - 12) / 5, -1), 1) * 0.10 * day
        let tx = Double(frame.tilt.x), ty = Double(frame.tilt.y)
        let k = Self.lightFrame(SIMD3<Double>(-0.42,-0.62,0.66), tx + sun, ty)
        let s = Self.lightFrame(SIMD3<Double>(0.62,-0.30,0.72), tx + sun, ty)
        let w = Self.lightFrame(SIMD3<Double>(0.05,-0.03,0.9985), tx + sun, ty)
        u.uK = SIMD3<Float>(k.0); u.uKr = SIMD3<Float>(k.1); u.uKu = SIMD3<Float>(k.2)
        u.uS2 = SIMD3<Float>(s.0); u.uS2r = SIMD3<Float>(s.1); u.uS2u = SIMD3<Float>(s.2)
        u.uW3 = SIMD3<Float>(w.0); u.uW3r = SIMD3<Float>(w.1); u.uW3u = SIMD3<Float>(w.2)
        var moon = Self.moonAt(hour); moon.x -= tx * 160; moon.y += ty * 160
        u.uMoon = SIMD3<Float>(moon)
        let fractured = crack > 0
        let samples = fractured ? sampleCount : 1
        try prepareTargets(fractured: fractured)
        let direct = target.width == renderWidth && target.height == renderHeight
        let destination = direct ? target : color!
        if staticFields == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: renderWidth, height: renderHeight, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw TutuCathedralError.allocation }
            staticFields = texture; staticFieldsDirty = true
        }
        if staticFieldsDirty {
            let fields = MTLRenderPassDescriptor()
            fields.colorAttachments[0].texture = staticFields
            fields.colorAttachments[0].loadAction = .dontCare; fields.colorAttachments[0].storeAction = .store
            guard let encoder = try command("static-fields").makeRenderCommandEncoder(descriptor: fields) else { throw TutuCathedralError.allocation }
            encoder.setRenderPipelineState(staticPipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<TutuCathedralUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<TutuCathedralUniforms>.stride, index: 0)
            encoder.setVertexBuffer(baseBuffer, offset: 0, index: 1)
            for i in textures.indices { encoder.setFragmentTexture(textures[i], index: i) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 2)
            encoder.endEncoding()
            staticFieldsDirty = false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = samples > 1 ? multisample : destination
        pass.colorAttachments[0].resolveTexture = samples > 1 ? destination : nil
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = samples > 1 ? (nextCommandBuffer == nil ? .multisampleResolve : .storeAndMultisampleResolve) : .store
        if fractured {
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1; pass.depthAttachment.storeAction = nextCommandBuffer == nil ? .dontCare : .store
        }
        var encoder: MTLRenderCommandEncoder
        func beginEncoder(_ name: String) throws -> MTLRenderCommandEncoder {
            guard let encoder = try command(name).makeRenderCommandEncoder(descriptor: pass) else { throw TutuCathedralError.allocation }
            encoder.setRenderPipelineState(fractured ? pipeline : uncrackedPipeline)
            encoder.setCullMode(.none)
            for i in textures.indices { encoder.setFragmentTexture(textures[i], index: i) }
            encoder.setFragmentTexture(staticFields, index: 11)
            return encoder
        }
        encoder = try beginEncoder("base")
        func nextPass(_ name: String) throws {
            guard nextCommandBuffer != nil else { return }
            encoder.endEncoding()
            pass.colorAttachments[0].loadAction = .load
            if fractured { pass.depthAttachment.loadAction = .load }
            encoder = try beginEncoder(name)
        }
        func draw(_ buffer: MTLBuffer, triangles: Int, pass: Float, depth state: MTLDepthStencilState?,
                  firstTriangle: Int = 0, releasedAt: Double = -1) {
            u.uFracturePass = pass
            u.uReleasedAt = Float(releasedAt)
            if let state { encoder.setDepthStencilState(state) }
            encoder.setVertexBytes(&u, length: MemoryLayout<TutuCathedralUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<TutuCathedralUniforms>.stride, index: 0)
            #if TUTU_NATIVE_FRAME && TUTU_OVERDRAW
            encoder.setFragmentBuffer(overdrawCounter, offset: 0, index: 2)
            #endif
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: triangles, baseInstance: firstTriangle)
        }
        draw(baseBuffer, triangles: 2, pass: 0, depth: fractured ? baseDepthState : nil)
        if crack > 0.001, let glaze = glazeBuffer {
            let triangles = visibleGlazeTriangles(crack: crack)
            if triangles > 0 {
                try nextPass("glaze")
                draw(glaze, triangles: triangles, pass: 1, depth: depthState, firstTriangle: 0)
            }
            if (shatter > 0 || restoring), let shards = shardBuffer {
                if pieces.contains(where: { $0.releasedAt >= 0 || restoring }) { try nextPass("shards") }
                for piece in pieces where piece.releasedAt >= 0 || restoring {
                    draw(shards, triangles: piece.count / 3, pass: 2, depth: depthState,
                         firstTriangle: piece.first / 3, releasedAt: piece.releasedAt)
                }
            }
        }
        encoder.endEncoding()
        if !direct {
            let upscale = MTLRenderPassDescriptor()
            upscale.colorAttachments[0].texture = target; upscale.colorAttachments[0].loadAction = .dontCare; upscale.colorAttachments[0].storeAction = .store
            guard let encoder = try command("upscale").makeRenderCommandEncoder(descriptor: upscale) else { throw TutuCathedralError.allocation }
            encoder.setRenderPipelineState(upscalePipeline); encoder.setFragmentTexture(destination, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        }
    }

    private func prepareTargets(fractured: Bool) throws {
        if color != nil && (!fractured || depth != nil) { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: renderWidth, height: renderHeight, mipmapped: false)
        d.storageMode = .private; d.usage = [.renderTarget, .shaderRead]
        if color == nil {
            guard let texture = device.makeTexture(descriptor: d) else { throw TutuCathedralError.allocation }
            color = texture
        }
        guard fractured, depth == nil else { return }
        d.sampleCount = sampleCount
        if sampleCount > 1 {
            d.textureType = .type2DMultisample; d.usage = .renderTarget
            guard let texture = device.makeTexture(descriptor: d) else { throw TutuCathedralError.allocation }
            multisample = texture
        }
        d.pixelFormat = .depth32Float; d.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: d) else { throw TutuCathedralError.allocation }
        depth = texture
    }

    @discardableResult func restore(at time: Double) -> Bool {
        guard restoreStart < 0, glazeBuffer != nil, lastBreak > 0 else { return false }
        restorePoseTime = lastTime; restoreStart = time; animatingUntil = time + restoreDuration
        return true
    }
    func restorationProgress(at time: Double) -> Double {
        guard restoreStart >= 0 else { return 0 }
        let t = min(max((time - restoreStart) / restoreDuration, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
    func cancelRestore() {
        guard restoreStart >= 0 else { return }
        restoreStart = -1; animatingUntil = 0; lastBreak = .infinity
    }
    func isAnimating(at time: Double) -> Bool { time < animatingUntil || (restoreStart >= 0 && lastRestore < 1) }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }
    private static func dayWeight(_ h: Double) -> Double {
        if h >= 7 && h <= 17 { return 1 }
        if h > 17 && h < 19.5 { return 1 - smooth(17, 19.5, h) }
        if h >= 5 && h < 7 { return smooth(5, 7, h) }
        return 0
    }
    private static func openness(_ h: Double) -> Double {
        let t = (h - 12 + 24).truncatingRemainder(dividingBy: 24)
        return t <= 12.5 ? smooth(8.5, 11.5, t) : 1 - smooth(12.5, 14.5, t)
    }
    private static func moonAt(_ h: Double) -> SIMD3<Double> {
        let t = (h - 12 + 24).truncatingRemainder(dividingBy: 24), f = (t - 7) / 11
        if f < 0 || f > 1 { return .zero }
        return SIMD3<Double>(195 - 176 * cos(f * .pi), 650 - 476 * sin(f * .pi), smooth(0, 0.07, f) * (1 - smooth(0.93, 1, f)))
    }
    private static func lightFrame(_ direction: SIMD3<Double>, _ tx: Double, _ ty: Double) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        func rot(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let x = cos(tx) * v.x + sin(tx) * v.z, z = -sin(tx) * v.x + cos(tx) * v.z
            return SIMD3<Double>(x, cos(ty) * v.y - sin(ty) * z, sin(ty) * v.y + cos(ty) * z)
        }
        let c = simd_normalize(rot(direction)), up = rot(SIMD3<Double>(0,-1,0))
        let r = simd_normalize(simd_cross(up, c)), u = simd_normalize(simd_cross(c, r))
        return (c, r, u)
    }
}
#endif
#endif
