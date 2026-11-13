#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import ImageIO
import Metal

/// page0-gl.js:241–374. Owns GPU resources, not the model or animation clock.
/// The owner serializes encoding. Command buffers must retain their references;
/// `setBytes` snapshots small uniforms, so several frames may be in flight.
final class TutuPage0Renderer {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): return "Tutu page0: " + message }
        }
    }
    /// Cumulative production-pass captures, not alternative reference algorithms.
    enum Pass: Int, CaseIterable {
        case sky, cloth, shadow, thread, pomander
        var name: String {
            switch self {
            case .sky: return "sky"
            case .cloth: return "cloth"
            case .shadow: return "shadow"
            case .thread: return "thread"
            case .pomander: return "scene"
            }
        }
    }
    private struct Uniforms {
        var uTilt: SIMD2<Float>; var uT: Float; var uDay: Float
        var uDusk: Float; var uDawn: Float; var uNight: Float; var uYs: Float
        var uMoon: SIMD4<Float>
        var uF: Float; var uG: Float; var uFold: Float; var uRoom: Float
        var uSeam: SIMD4<Float>; var uSkyLight: SIMD4<Float>
    }
    private struct SpriteUniforms {
        var q0: SIMD4<Float>; var q1: SIMD4<Float>; var q2: SIMD4<Float>; var q3: SIMD4<Float>
        var uColor: SIMD4<Float>; var modeDepth: SIMD4<Float>
    }
    let width: Int
    let height: Int
    let sampleCount: Int
    private let skyPipeline: MTLRenderPipelineState
    private let clothPipeline: MTLRenderPipelineState
    private let spritePipeline: MTLRenderPipelineState
    private let noDepth: MTLDepthStencilState
    private let clothDepth: MTLDepthStencilState
    private let shadowDepth: MTLDepthStencilState
    private let mesh: MTLBuffer
    private let indices: MTLBuffer
    private let indexCount: Int
    private let velvet: MTLTexture
    private let pomander: MTLTexture
    private let depth: MTLTexture
    private let multisample: MTLTexture?
    private let descriptor = MTLRenderPassDescriptor()

    init(device: MTLDevice, library: MTLLibrary, resourceURL: URL,
         width: Int = 804, height: Int = 1748, sampleCount: Int = 4) throws {
        guard width > 0, height > 0, device.supportsTextureSampleCount(sampleCount) else {
            throw Failure.unavailable("unsupported dimensions or MSAA sample count \(sampleCount)")
        }
        self.width = width; self.height = height; self.sampleCount = sampleCount
        func pipeline(_ vertex: String, _ fragment: String, blend: Bool = false) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw Failure.unavailable("missing shader \(vertex)/\(fragment)")
            }
            p.vertexFunction = v; p.fragmentFunction = f
            p.rasterSampleCount = sampleCount
            p.depthAttachmentPixelFormat = .depth32Float
            let a = p.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            a.isBlendingEnabled = blend
            if blend {
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.rgbBlendOperation = .add
                // Original WebGL alpha:false keeps an opaque drawing buffer.
                a.writeMask = [.red, .green, .blue]
            }
            return try device.makeRenderPipelineState(descriptor: p)
        }
        skyPipeline = try pipeline("tutuPage0SkyVertex", "tutuPage0SkyFragment")
        clothPipeline = try pipeline("tutuPage0ClothVertex", "tutuPage0ClothFragment")
        spritePipeline = try pipeline("tutuPage0SpriteVertex", "tutuPage0SpriteFragment", blend: true)
        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = compare; d.isDepthWriteEnabled = write
            guard let state = device.makeDepthStencilState(descriptor: d) else { throw Failure.unavailable("depth state") }
            return state
        }
        noDepth = try depthState(.always, write: false)
        clothDepth = try depthState(.lessEqual, write: true)
        // Original shadow at GL z=.98 -> depth=.99 only passes where cloth wrote
        // smaller depth; untouched sky remains clearDepth=1 and rejects GREATER.
        shadowDepth = try depthState(.greater, write: false)
        var vertices = [Float](); vertices.reserveCapacity(2 * 151 * 65 * 3)
        var elements = [UInt16](); elements.reserveCapacity(2 * 150 * 64 * 6)
        var base = 0
        for side in [-1.0, 1.0] {
            for r in 0...150 {
                let v = -60 + (874.0 + 120) * Double(r) / 150
                for c in 0...64 {
                    let a = Double(c) / 64
                    vertices.append(Float(1 - pow(1 - a, 2.6)))
                    vertices.append(Float(v)); vertices.append(Float(side))
                }
            }
            for r in 0..<150 {
                for c in 0..<64 {
                    let i0 = base + r * 65 + c, i1 = i0 + 1, i2 = i0 + 65, i3 = i2 + 1
                    elements.append(contentsOf: [UInt16(i0), UInt16(i2), UInt16(i1), UInt16(i1), UInt16(i2), UInt16(i3)])
                }
            }
            base += 151 * 65
        }
        guard let mesh = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride),
              let indices = device.makeBuffer(bytes: elements, length: elements.count * MemoryLayout<UInt16>.stride) else {
            throw Failure.unavailable("cloth mesh allocation")
        }
        self.mesh = mesh; self.indices = indices; indexCount = elements.count
        velvet = try Self.texture(device: device, url: resourceURL.appendingPathComponent("velvet.jpg"))
        pomander = try Self.texture(device: device, url: resourceURL.appendingPathComponent("pomander.png"))
        func attachment(_ format: MTLPixelFormat) throws -> MTLTexture {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            t.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
            t.sampleCount = sampleCount; t.storageMode = .private; t.usage = .renderTarget
            guard let texture = device.makeTexture(descriptor: t) else { throw Failure.unavailable("render attachment") }
            return texture
        }
        depth = try attachment(.depth32Float)
        multisample = sampleCount > 1 ? try attachment(.bgra8Unorm) : nil
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1
        descriptor.depthAttachment.storeAction = .dontCare
    }

    func encode(commandBuffer: MTLCommandBuffer, target: MTLTexture, model: TutuPage0Model, hour: Double) throws {
        try encode(commandBuffer: commandBuffer, target: target, model: model, hour: hour, through: .pomander)
    }

    func encode(commandBuffer: MTLCommandBuffer, target: MTLTexture, model: TutuPage0Model,
                hour: Double, through pass: Pass) throws {
        guard target.width == width, target.height == height, target.pixelFormat == .bgra8Unorm,
              target.sampleCount == 1, target.textureType == .type2D,
              target.device === depth.device else { throw Failure.unavailable("target must be same-device, same-size non-sRGB BGRA8") }
        let w = Self.weights(hour), m = Self.moon(hour)
        let open = min(1, max(0, model.open))
        let f = Self.sstep(0.58, 1, open)
        let mb = m.w * 0.06
        var u = Uniforms(uTilt: SIMD2(Float(model.tilt.x), Float(model.tilt.y)), uT: Float(model.time), uDay: Float(w.x),
                         uDusk: Float(w.y), uDawn: Float(w.z), uNight: Float(w.w),
                         uYs: Float(150 + (1100 - 150) * Self.sstep(0, 0.78, open)), uMoon: SIMD4<Float>(m),
                         uF: Float(f), uG: Float(62 + 420 * pow(open, 1.25)), uFold: Float(3 + 12 * open), uRoom: Float(1 - 0.35 * w.w),
                         uSeam: SIMD4(270, 252, 3, 0),
                         uSkyLight: SIMD4(Float(0.36*w.x + 0.30*w.y + 0.28*w.z + 0.03*w.w + mb),
                                          Float(0.45*w.x + 0.24*w.y + 0.24*w.z + 0.035*w.w + mb),
                                          Float(0.58*w.x + 0.26*w.y + 0.28*w.z + 0.055*w.w + mb*1.2), 0))
        let color = descriptor.colorAttachments[0]!
        color.texture = multisample ?? target
        color.resolveTexture = multisample == nil ? nil : target
        color.storeAction = multisample == nil ? .store : .multisampleResolve
        defer { color.texture = nil; color.resolveTexture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { throw Failure.unavailable("render encoder") }
        defer { encoder.endEncoding() }
        encoder.label = "Tutu page0 SKY/CLOTH/SPR"
        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
        encoder.setDepthStencilState(noDepth)
        encoder.setRenderPipelineState(skyPipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        guard pass.rawValue >= Pass.cloth.rawValue else { return }
        if f < 0.999 {
            encoder.setDepthStencilState(clothDepth)
            encoder.setRenderPipelineState(clothPipeline)
            encoder.setVertexBuffer(mesh, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(velvet, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: indices, indexBufferOffset: 0)
        }
        guard pass.rawValue >= Pass.shadow.rawValue, model.pull.visible else { return }
        let ps = model.pull, k = ps.k
        let ux = sin(ps.phi), uy = cos(ps.phi), nx = uy, ny = -ux
        let bx = ps.A.x + ux * ps.L, by = ps.A.y + uy * ps.L
        func point(_ x: Double, _ y: Double, _ tx: Float, _ ty: Float) -> SIMD4<Float> {
            SIMD4(Float(bx + nx*x + ux*y), Float(by + ny*x + uy*y), tx, ty)
        }
        func draw(_ q0: SIMD4<Float>, _ q1: SIMD4<Float>, _ q2: SIMD4<Float>, _ q3: SIMD4<Float>, mode: Float, color: SIMD4<Float>, z: Float = 0) {
            var s = SpriteUniforms(q0: q0, q1: q1, q2: q2, q3: q3, uColor: color, modeDepth: SIMD4(mode, z, 0, 0))
            encoder.setVertexBytes(&s, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&s, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setRenderPipelineState(spritePipeline)
        encoder.setFragmentTexture(pomander, index: 0)
        let sa = 0.34 * (1 - f) // drawPull takes F, not raw open.
        if sa > 0.01 {
            let cx = bx + ux*23*k + 7, cy = by + uy*23*k + 10, r = 23*k*1.7
            encoder.setDepthStencilState(shadowDepth)
            draw(SIMD4(Float(cx-r),Float(cy-r),0,0), SIMD4(Float(cx+r),Float(cy-r),1,0),
                 SIMD4(Float(cx-r),Float(cy+r),0,1), SIMD4(Float(cx+r),Float(cy+r),1,1),
                 mode: 2, color: SIMD4(0,0,0,Float(sa)), z: 0.98)
        }
        guard pass.rawValue >= Pass.thread.rawValue else { return }
        encoder.setDepthStencilState(noDepth)
        draw(SIMD4(Float(ps.A.x-nx*0.45),Float(ps.A.y-ny*0.45),0,0),
             SIMD4(Float(ps.A.x+nx*0.45),Float(ps.A.y+ny*0.45),1,0),
             point(-0.45,0,0,1), point(0.45,0,1,1), mode: 1, color: SIMD4(0.90,0.87,0.80,0.85))
        guard pass == .pomander else { return }
        let lt = Float(1 - 0.28*w.w)
        draw(point(-30*k,-8*k,0,0), point(30*k,-8*k,1,0), point(-30*k,91*k,0,1), point(30*k,91*k,1,1),
             mode: 0, color: SIMD4(lt,lt,lt*0.98,1))
    }

    private static func sstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x-a)/(b-a))); return t*t*(3-2*t)
    }
    private static func weights(_ h: Double) -> SIMD4<Double> {
        let day = sstep(5.6,7.4,h)*(1-sstep(16.8,18.6,h))
        let dusk = sstep(16.6,18.2,h)*(1-sstep(19,20.2,h))
        let dawn = sstep(4.6,5.6,h)*(1-sstep(6.2,7.4,h))
        let night = min(1,max(0,1-day-dusk-dawn)), sum = day+dusk+dawn+night
        return SIMD4(day/sum,dusk/sum,dawn/sum,night/sum)
    }
    private static func moon(_ h: Double) -> SIMD4<Double> {
        let k = (h-19+24).truncatingRemainder(dividingBy: 24)/10
        if k > 1 { return SIMD4(0,-1,0,0) }
        let x = 78+340*k, y = 860-800*sin(Double.pi*k)
        let ax = (x-201)*1.25/874, ay = (437-y)*1.25/874, rr = hypot(ax,ay)
        let visibility = sstep(0,0.05,k)*(1-sstep(0.95,1,k))
        if rr < 1e-5 { return SIMD4(0,sin(0.80),cos(0.80),visibility) }
        let c = cos(rr), s = sin(rr)/rr
        return SIMD4(ax*s,sin(0.80)*c+cos(0.80)*ay*s,cos(0.80)*c-sin(0.80)*ay*s,visibility)
    }

    private static func texture(device: MTLDevice, url: URL) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = original.copy(colorSpace: space) else { throw Failure.unavailable("decode \(url.path)") }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width*height*4)
        // Preserve straight-alpha PNG bytes (UNPACK_PREMULTIPLY_ALPHA_WEBGL=false)
        // whenever ImageIO exposes RGBA directly; no lossy premultiply round trip.
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.alphaInfo == .last, order != .byteOrder32Little,
           let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            for y in 0..<height {
                rgba.withUnsafeMutableBytes { destination in
                    destination.baseAddress!.advanced(by: y*width*4).copyMemory(from: bytes.advanced(by: y*image.bytesPerRow), byteCount: width*4)
                }
            }
        } else {
            let decoded = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width*4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0,y: 0,width: width,height: height))
                return true
            }
            guard decoded else { throw Failure.unavailable("RGBA decode \(url.path)") }
            for i in stride(from: 0, to: rgba.count, by: 4) {
                let a = Int(rgba[i+3])
                if a > 0 && a < 255 {
                    for c in 0..<3 { rgba[i+c] = UInt8(min(255,(Int(rgba[i+c])*255+a/2)/a)) }
                }
            }
        }
        // WebGL samples the photo's encoded sRGB channel values as ordinary UNORM;
        // neither the texture nor output gets a hardware sRGB transfer function.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable("texture \(url.path)") }
        rgba.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width*4) }
        texture.label = url.lastPathComponent
        return texture
    }
}
#endif
#endif
