#if PERSONAL_APPS
#if os(iOS)
import Foundation
import Metal
import CoreGraphics
import ImageIO
import simd

private struct TutuUnlockUniforms {
    var rect = SIMD4<Float>(0, 0, 420, 912)
    var view = SIMD4<Float>(0, 0, 1, 1)
    var flags = SIMD4<Float>(0, 0, 3.3, 0.24)
    var fx = SIMD4<Float>(1.9, -1, 0, 1)
    var pet = SIMD4<Float>.zero
    var misc = SIMD4<Float>.zero
    var shake = SIMD2<Float>.zero
    var mask = SIMD2<Float>.zero
    var c = SIMD2<Float>(252, -180)
    var padding = SIMD2<Float>.zero
    var a = SIMD3<Float>.zero
    var s0 = SIMD3<Float>.zero
    var s1 = SIMD3<Float>.zero
    var knot = SIMD3<Float>.zero
    var bp = SIMD3<Float>.zero
    var spark = SIMD3<Float>.zero
    var bri = matrix_identity_float3x3
    var hr = matrix_identity_float3x3
}
private struct TutuUnlockSpriteUniforms {
    var affine: SIMD4<Float>
    var geometry: SIMD4<Float>
    var color: SIMD4<Float>
}

enum TutuUnlockError: LocalizedError {
    case allocation, shader(String), image(URL), targetFormat, inputLayout
    var errorDescription: String? {
        switch self {
        case .allocation: return "解锁动画的 Metal 资源未能分配"
        case .shader(let name): return "解锁着色器缺失：\(name)"
        case .image(let url): return "解锁贴图无法读取：\(url.lastPathComponent)"
        case .targetFormat: return "解锁画布格式不匹配"
        case .inputLayout: return "解锁动画的输入框尚未完成布局"
        }
    }
}

/// The source's independent 60 Hz petal clock; Unlock itself stays at 120 Hz.
final class TutuUnlockScene {
    let model = TutuUnlockModel()
    let petals: TutuPetals
    private var petalIndex = 0
    private var sprites: [TutuPetals.DrawSprite] = []
    var reduceMotion = false {
        didSet {
            if reduceMotion {
                petals.reset()
                sprites.removeAll(keepingCapacity: true)
            }
        }
    }
    static let emissions: [SIMD3<Double>] = (0..<9).map { k in
        let x = sin((Double(k) + 3.1) * 127.1 + 311.7) * 43758.5453
        return SIMD3(0.45 + Double(k) * 0.17, 50 + 320 * (x - floor(x)), -40)
    }
    init(floor: @escaping (Double) -> Double? = { x in x >= 15.7 && x <= 404.3 ? 809.3 : 912 }) {
        petals = TutuPetals(seed: 1, floor: floor)
        sprites.reserveCapacity(9)
    }
    func reset(startTime: Double = 0) {
        model.reset()
        petals.reset()
        petalIndex = 0
        sprites.removeAll(keepingCapacity: true)
        if startTime > 0 { simulate(startTime) }
    }
    func view() -> TutuUnlockView {
        var result = model.view()
        if reduceMotion { result.shake = .zero }
        return result
    }
    func step(_ dt: Double, tilt: Double) {
        stepPetals(dt, at: model.t)
        model.step(dt, tilt)
    }
    private func stepPetals(_ dt: Double, at time: Double) {
        guard !reduceMotion, let release = model.tr else { return }
        while petalIndex < Self.emissions.count && time >= release + Self.emissions[petalIndex].x {
            let e = Self.emissions[petalIndex]
            petals.emit(x: e.y, y: e.z)
            petalIndex += 1
        }
        if petalIndex > 0 { petals.step(min(dt, 0.1)) }
    }
    func simulate(_ time: Double) {
        model.simulate(time)
        petals.reset(); petalIndex = 0; sprites.removeAll(keepingCapacity: true)
        guard !reduceMotion, var c = model.tr else { return }
        let h = 1.0 / 60
        while c + h <= model.t + 1e-9 {
            stepPetals(h, at: c)
            if petalIndex > 0 { petals.drawSprites(into: &sprites) }
            c += h
        }
        stepPetals(0, at: model.t)
    }
    func drawSprites() -> [TutuPetals.DrawSprite] {
        guard !reduceMotion else { return [] }
        petals.drawSprites(into: &sprites)
        return sprites
    }
}

/// Original BG / SPARK / PETAL passes with offline-baked OBJ composition.
final class TutuUnlockRenderer {
    let device: MTLDevice
    let pixelFormat: MTLPixelFormat
    private let background: MTLRenderPipelineState
    private let baked: TutuUnlockBaked
    private let spark: MTLRenderPipelineState
    private let petal: MTLRenderPipelineState
    private let sprite: MTLRenderPipelineState
    private let before: MTLTexture
    private var after: MTLTexture
    private var petalTextures: [[MTLTexture]] = []
    private var lieTextures: [[MTLTexture]] = []
    private let bladeLength: Double
    var bakedStatistics: TutuUnlockBaked.Statistics { baked.statistics }

    init(device: MTLDevice, library: MTLLibrary, resourceURL: URL,
         before: MTLTexture, after: MTLTexture, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device; self.pixelFormat = pixelFormat; self.before = before; self.after = after
        func pipeline(_ vertex: String, _ fragment: String, blend: Bool, premultiplied: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else { throw TutuUnlockError.shader(fragment) }
            d.vertexFunction = v; d.fragmentFunction = f
            let c = d.colorAttachments[0]!
            c.pixelFormat = pixelFormat; c.isBlendingEnabled = blend
            c.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            // The original WebGL default framebuffer has alpha:false.
            c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            return try device.makeRenderPipelineState(descriptor: d)
        }
        background = try pipeline("tutuUnlockVertex", "tutuUnlockBackground", blend: false)
        baked = try TutuUnlockBaked(device: device, library: library, resourceURL: resourceURL, pixelFormat: pixelFormat)
        spark = try pipeline("tutuUnlockVertex", "tutuUnlockSpark", blend: true)
        petal = try pipeline("tutuUnlockPetalVertex", "tutuUnlockPetal", blend: true)
        sprite = try pipeline("tutuUnlockSpriteVertex", "tutuUnlockSpriteFragment", blend: true, premultiplied: true)
        let manifest = try JSONDecoder().decode(TutuPetals.SpriteManifest.self,
            from: Data(contentsOf: resourceURL.appendingPathComponent(TutuPetals.SpriteManifest.resourcePath)))
        bladeLength = manifest.hi_len
        for lying in [false, true] {
            var textures: [[MTLTexture]] = []
            for index in 0..<(lying ? manifest.lie.count : manifest.petals.count) {
                var sides: [MTLTexture] = []
                for side in 0..<2 {
                    let url = resourceURL.appendingPathComponent(manifest.resourcePath(index: index, side: side, lying: lying))
                    sides.append(try Self.texture(device: device, url: url))
                }
                textures.append(sides)
            }
            if lying { lieTextures = textures } else { petalTextures = textures }
        }
    }

    func setAfter(_ texture: MTLTexture) { after = texture }

    static func texture(device: MTLDevice, url: URL) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TutuUnlockError.image(url) }
        return try texture(device: device, image: image)
    }
    static func texture(device: MTLDevice, image: CGImage) throws -> MTLTexture {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw TutuUnlockError.allocation }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.storageMode = .shared; d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { throw TutuUnlockError.allocation }
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return texture
    }

    /// Select from the fully resident ASTC bank; resource construction performs all uploads off-main.
    func prepareBaked(view: TutuUnlockView) throws { try baked.prepare(view: view) }
    /// The carried model rig no longer contains the idle kick, so preserve it at release.
    func captureBakedRelease(time: Double, kick: Double) { baked.captureRelease(time: time, kick: kick) }
    func cancelBakedPreparation() { baked.cancel() }
    func bakedReady(view: TutuUnlockView) throws -> Bool { try baked.isReady(view: view) }

    /// Encode on the same buffer as M1's after-image producer; never submit out of order.
    func encode(commandBuffer: MTLCommandBuffer, target: MTLTexture, view v: TutuUnlockView,
                petals: [TutuPetals.DrawSprite] = [], pixelsPerPoint: Float? = nil) throws {
        guard target.pixelFormat == pixelFormat else { throw TutuUnlockError.targetFormat }
        try baked.requireReady(view: v)
        baked.retainPrepared(until: commandBuffer)
        let e = try encoder(commandBuffer, target: target, load: .dontCare)
        try encodeDraws(e, target: target, view: v, petals: petals, pixelsPerPoint: pixelsPerPoint)
        e.endEncoding()
    }

    #if TUTU_NATIVE_FRAME
    /// Caller prepares the exact view off the render path, then commits these buffers in order.
    func encodeProfiled(target: MTLTexture, view v: TutuUnlockView, petals: [TutuPetals.DrawSprite] = [],
                        pixelsPerPoint: Float? = nil,
                        makeCommandBuffer: (String) throws -> MTLCommandBuffer) throws -> [MTLCommandBuffer] {
        guard target.pixelFormat == pixelFormat else { throw TutuUnlockError.targetFormat }
        try baked.requireReady(view: v)
        var buffers: [MTLCommandBuffer] = []
        func pass(_ name: String, _ stage: Int, _ load: MTLLoadAction) throws {
            let buffer = try makeCommandBuffer(name)
            if stage == 1 { baked.retainPrepared(until: buffer) }
            let e = try encoder(buffer, target: target, load: load)
            e.label = name
            try encodeDraws(e, target: target, view: v, petals: petals, pixelsPerPoint: pixelsPerPoint, stage: stage)
            e.endEncoding()
            buffers.append(buffer)
        }
        try pass("unlock.background", 0, .dontCare)
        if v.rope != nil || v.bunny != nil { try pass("unlock.objects", 1, .load) }
        if v.spark > 0.01 { try pass("unlock.spark", 2, .load) }
        if !petals.isEmpty { try pass("unlock.petals", 3, .load) }
        return buffers
    }

    #endif

    private func encoder(_ buffer: MTLCommandBuffer, target: MTLTexture, load: MTLLoadAction) throws -> MTLRenderCommandEncoder {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let e = buffer.makeRenderCommandEncoder(descriptor: pass) else { throw TutuUnlockError.allocation }
        e.setCullMode(.none)
        return e
    }


    private func encodeDraws(_ e: MTLRenderCommandEncoder, target: MTLTexture, view v: TutuUnlockView,
                             petals: [TutuPetals.DrawSprite], pixelsPerPoint: Float?, stage: Int? = nil) throws {
        var u = TutuUnlockUniforms()
        u.view.w = pixelsPerPoint ?? Float(target.width) / 420
        u.fx.y = Float(v.wave); u.shake = SIMD2<Float>(v.shake)
        func draw(_ pipeline: MTLRenderPipelineState) {
            e.setRenderPipelineState(pipeline)
            e.setVertexBytes(&u, length: MemoryLayout<TutuUnlockUniforms>.stride, index: 0)
            e.setFragmentBytes(&u, length: MemoryLayout<TutuUnlockUniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        e.setFragmentTexture(before, index: 0); e.setFragmentTexture(after, index: 1)
        if stage == nil || stage == 0 { draw(background) }
        if (stage == nil || stage == 1) && (v.rope != nil || v.bunny != nil) {
            try baked.encode(e, view: v)
        }
        if (stage == nil || stage == 2) && v.spark > 0.01 {
            u.rect = SIMD4(212, -20, 292, 60); u.spark = SIMD3(252, 10, Float(v.spark))
            draw(spark)
        }
        // v4's separate canvas is above the sparkle and input canvas.
        guard stage == nil || stage == 3 else { return }
        e.setRenderPipelineState(sprite)
        for p in petals {
            let texture = (p.isLying ? lieTextures : petalTextures)[p.spriteIndex][p.side]
            let scale = p.size / bladeLength
            var s = TutuUnlockSpriteUniforms(affine: SIMD4<Float>(p.affine),
                geometry: SIMD4(Float(p.x), Float(p.y), Float(Double(texture.width) * scale), Float(Double(texture.height) * scale)),
                color: SIMD4(Float((p.tint.x * 255).rounded() / 255), Float((p.tint.y * 255).rounded() / 255), Float((p.tint.z * 255).rounded() / 255), Float(p.alpha)))
            e.setVertexBytes(&s, length: MemoryLayout<TutuUnlockSpriteUniforms>.stride, index: 0)
            e.setFragmentBytes(&s, length: MemoryLayout<TutuUnlockSpriteUniforms>.stride, index: 0)
            e.setFragmentTexture(texture, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }
}
#endif
#endif
