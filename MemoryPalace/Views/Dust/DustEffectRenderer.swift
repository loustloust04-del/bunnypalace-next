// 按 docs/spec-dust-cleanroom.md 净室实现（#007）
import CoreGraphics
import Metal

/// 删除消息「散成灰」的渲染器：每条截图按格子切成颗粒，位置在顶点着色器里按时间闭式算
/// （DustEffect.metal），CPU 每帧只推进时钟。iOS 覆盖层（MessageDust）和 mac 离屏 harness / 测试共用。
final class DustEffectRenderer {
    /// 一条从加入到被移除的时长。约束：duration ≥ kSweep + kSweepJitter + 最长寿命（DustEffect.metal 的节奏常数：
    /// 0.45 + 0.08 + 0.75 = 1.28 s 时每颗都已透明），留余量保证移除前最后一帧全透明。改那边的常数要同步这里
    static let duration: Float = 1.4
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    /// 一条最多多少颗：截图大了格子变粗（保持正方形）
    static let maxParticles = 240_000

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }

    private struct Item {
        let frame: CGRect
        let texture: MTLTexture
        let cols: Int
        let rows: Int
        let seed: UInt32
        var time: Float = 0
    }

    /// 与 DustEffect.metal 的 AshDustUniforms 对齐
    private struct Uniforms {
        var viewport: SIMD2<Float>
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var cell: SIMD2<Float>
        var cols: UInt32
        var rows: UInt32
        var seed: UInt32
        var time: Float
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "ashDustVertex"),
              let fragment = library.makeFunction(name: "ashDustFragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        let color = desc.colorAttachments[0]!
        color.pixelFormat = Self.pixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one                     // 预乘 alpha 叠加
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc),
              let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
    }

    /// 截图在覆盖层里的位置（点）+ 截图本身（任意倍率；8 位 sRGB 或 16 位浮点扩展 sRGB 都行）
    @discardableResult
    func add(frame: CGRect, image: CGImage) -> Bool {
        guard let grid = Self.grid(for: frame.size), let texture = makeTexture(image) else { return false }
        items.append(Item(frame: frame, texture: texture, cols: grid.cols, rows: grid.rows,
                          seed: UInt32.random(in: .min ... .max)))
        return true
    }

    func encodeStep(into commandBuffer: MTLCommandBuffer, deltaTime: Float) {
        // 位置是时间的闭式函数，GPU 不用预先算什么；这里只推进时钟、收掉走完的
        let dt = max(deltaTime, 0)
        for i in items.indices { items[i].time += dt }
        items.removeAll { $0.time >= Self.duration }
    }

    func encodeDraw(into encoder: MTLRenderCommandEncoder, viewport: CGSize) {
        guard !items.isEmpty, viewport.width > 0, viewport.height > 0 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for item in items {
            var u = Uniforms(
                viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
                origin: SIMD2(Float(item.frame.minX), Float(item.frame.minY)),
                size: SIMD2(Float(item.frame.width), Float(item.frame.height)),
                cell: SIMD2(Float(item.frame.width) / Float(item.cols), Float(item.frame.height) / Float(item.rows)),
                cols: UInt32(item.cols), rows: UInt32(item.rows), seed: item.seed, time: item.time)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(item.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: item.cols * item.rows)
        }
    }

    /// 颗粒网格：默认 1pt 一颗；总数超上限时把格子放大（正方形，宽高比不变）。空尺寸 / 非有限返回 nil
    static func grid(for size: CGSize) -> (cols: Int, rows: Int)? {
        let w = Double(size.width), h = Double(size.height)
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 1e6, h <= 1e6 else { return nil }   // 上限防极端长宽比算格子时 Int 溢出
        var cell = max(1, (w * h / Double(maxParticles)).squareRoot())
        while true {
            let cols = max(1, Int((w / cell).rounded(.up)))
            let rows = max(1, Int((h / cell).rounded(.up)))
            if cols * rows <= maxParticles { return (cols, rows) }
            cell *= 1.01                                      // ceil 多出来的一圈，放大一点再试
        }
    }

    /// 截图转成 8 位 RGBA 预乘贴图。MTKTextureLoader 吃不了 16 位浮点扩展 sRGB，统一过一道 CGContext：
    /// 广色域分量在这里被收回 sRGB（覆盖层本身是 8 位，留着也画不出来）
    private func makeTexture(_ image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        // 位图第 0 行是图的顶边，正好对上贴图 v = 0
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        return texture
    }
}
