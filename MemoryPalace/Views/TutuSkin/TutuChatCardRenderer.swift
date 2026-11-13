#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Metal
import simd

fileprivate struct TutuChatCardUniforms {
    var size = SIMD4<UInt32>()
    var region = SIMD4<UInt32>()
    var geometry = SIMD4<Float>()
    var motif = SIMD4<Float>()
    var control = SIMD4<UInt32>()
    var paper = SIMD4<Float>()
    var tiles = SIMD4<UInt32>()
}

fileprivate struct TutuChatCardRegion {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var empty: Bool { x1 <= x0 || y1 <= y0 }
    var rect: CGRect { CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
    init(width: Int, height: Int) { x0 = 0; y0 = 0; x1 = width; y1 = height }
    init(_ rect: CGRect, width: Int, height: Int) {
        x0 = max(0, min(width, Int(floor(rect.minX)))); y0 = max(0, min(height, Int(floor(rect.minY))))
        x1 = max(x0, min(width, Int(ceil(rect.maxX)))); y1 = max(y0, min(height, Int(ceil(rect.maxY))))
    }
    func expanded(x: Int, y: Int, width: Int, height: Int) -> Self {
        var result = self
        result.x0 = max(0, x0 - x); result.y0 = max(0, y0 - y)
        result.x1 = min(width, x1 + x); result.y1 = min(height, y1 + y)
        return result
    }
    func union(_ other: Self) -> Self {
        if empty { return other }; if other.empty { return self }
        var result = self
        result.x0 = min(x0, other.x0); result.y0 = min(y0, other.y0)
        result.x1 = max(x1, other.x1); result.y1 = max(y1, other.y1)
        return result
    }
}

/// Worker-thread-only renderer. The one-shot and streaming paths deliberately use
/// the same workset and the same pass sequence, including output quantization.
final class TutuCardRenderer {
    fileprivate let gpu: TutuChatGPU
    fileprivate let paper: MTLTexture
    fileprivate let sanyu: MTLTexture
    private let pipelines: [String: MTLComputePipelineState]
    private(set) var lastGPUTime: Double = 0

    init(gpu: TutuChatGPU) throws {
        self.gpu = gpu
        paper = try gpu.image("paper.jpg"); sanyu = try gpu.image("sanyu.png")
        var states: [String: MTLComputePipelineState] = [:]
        for suffix in ["Border", "Noise", "Gaussian", "Motif", "Paper", "Warp", "Height", "Shade", "CutGeometry", "CutColor"] {
            let name = "tutuChatCard" + suffix
            states[name] = try gpu.pipeline(name)
        }
        pipelines = states
    }

    @discardableResult
    static func preflight(size: CGSize, scale: CGFloat, gpu: TutuChatGPU,
                          origin: CGPoint = .zero) throws -> CGRect {
        guard scale.isFinite, scale > 0 else { throw TutuChatError.textureSize }
        let limit = gpu.maxTextureSize2D
        let width = try TutuChatGPU.checkedDimension(floor(size.width * scale + 0.5), limit: limit)
        let height = try TutuChatGPU.checkedDimension(floor(size.height * scale + 0.5), limit: limit)
        let margin = try TutuChatGPU.checkedDimension(floor(3 * scale + 0.5), limit: limit)
        try TutuChatGPU.checkSize(width: width + margin, height: height + margin, limit: limit)
        let rect = CGRect(x: -1.5, y: -1.5, width: CGFloat(width + margin) / scale, height: CGFloat(height + margin) / scale)
        try TutuChatShadowRenderer.preflight(rect: rect, origin: origin, material: .card, scale: scale, limit: limit)
        return rect
    }

    func render(layout: TutuChatCardLayout, index: Int, scale: CGFloat) throws -> TutuChatRaster {
        let state = try stream(index: index, scale: scale)
        let raster = try state.update(layout: layout)
        lastGPUTime = state.lastGPUTime
        return raster
    }

    func stream(index: Int, scale: CGFloat) throws -> TutuCardStream {
        TutuCardStream(renderer: self, index: index, scale: scale)
    }

    fileprivate func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        if values.isEmpty { return try buffer(bytes: MemoryLayout<T>.stride) }
        let result = values.withUnsafeBytes { bytes in
            gpu.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let result else { throw TutuChatError.allocation }
        return result
    }

    fileprivate func buffer(bytes: Int) throws -> MTLBuffer {
        guard let result = gpu.device.makeBuffer(length: max(4, bytes), options: .storageModeShared) else { throw TutuChatError.allocation }
        return result
    }

    fileprivate func command(_ label: String) throws -> MTLCommandBuffer {
        guard let command = gpu.queue.makeCommandBuffer() else { throw TutuChatError.allocation }
        command.label = label
        return command
    }

    fileprivate func encode(_ command: MTLCommandBuffer, _ name: String, uniforms: TutuChatCardUniforms,
                            region: TutuChatCardRegion, bind: (MTLComputeCommandEncoder) -> Void) throws {
        TutuChatRenderTrace.emit("card.encode.begin", name)
        defer { TutuChatRenderTrace.emit("card.encode.end", name) }
        guard !region.empty else { return }
        guard let pipeline = pipelines[name], let encoder = try gpu.computeEncoder(command, label: name) else { throw TutuChatError.allocation }
        encoder.label = name
        encoder.setComputePipelineState(pipeline)
        var u = uniforms
        u.region = SIMD4(UInt32(region.x0), UInt32(region.y0), UInt32(region.x1 - region.x0), UInt32(region.y1 - region.y0))
        encoder.setBytes(&u, length: MemoryLayout<TutuChatCardUniforms>.stride, index: 0)
        bind(encoder)
        let width = pipeline.threadExecutionWidth
        let height = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / width))
        encoder.dispatchThreads(MTLSize(width: region.x1 - region.x0, height: region.y1 - region.y0, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
    }

    fileprivate func complete(_ command: MTLCommandBuffer) throws -> Double {
        try gpu.complete(command)
        return max(0, command.gpuEndTime - command.gpuStartTime)
    }
}

/// Persistent raw mask, immutable border/base, intermediate convolution fields,
/// and final texture. Same-size updates never allocate another card workset.
final class TutuCardStream {
    private let renderer: TutuCardRenderer
    private let index: Int
    private let scale: CGFloat
    private var workset: TutuChatCardWorkset?
    private var previous: TutuChatCardLayout?
    private(set) var lastGPUTime: Double = 0
    private(set) var lastDirtyRect: CGRect?
    private(set) var fullRenderCount = 0

    fileprivate init(renderer: TutuCardRenderer, index: Int, scale: CGFloat) {
        self.renderer = renderer; self.index = index; self.scale = scale
    }

    func update(layout: TutuChatCardLayout) throws -> TutuChatRaster {
        lastGPUTime = 0; lastDirtyRect = nil
        let rebuilt = workset == nil || previous?.size != layout.size
        if rebuilt {
            let replacement = try TutuChatCardWorkset(renderer: renderer, layout: layout, index: index, scale: scale)
            workset = replacement; lastGPUTime = replacement.initialGPUTime
        }
        guard let state = workset else { throw TutuChatError.allocation }
        let rawDirty = try state.mask.update(glyphs: layout.glyphs, offsetY: layout.textOffset)
        let motifChanged = !rebuilt && previous?.motif != layout.motif
        if rebuilt || rawDirty != nil || motifChanged {
            let result = try state.update(layout: layout, rawDirty: rawDirty, previousMotif: previous?.motif,
                                          motifChanged: motifChanged, full: rebuilt)
            lastGPUTime += result.time; lastDirtyRect = result.dirty
            if rebuilt { fullRenderCount += 1 }
        }
        // right and hasAction are layout/hero-selection metadata, not a second
        // renderer-side layout rule. All glyph fields (including isAction) belong
        // to mask identity; ACT_INK == INK in the original default palette.
        previous = layout
        return state.raster
    }
}

private final class TutuChatCardWorkset {
    let mask: TutuChatTypeMask
    let raster: TutuChatRaster
    private(set) var initialGPUTime: Double = 0
    private let renderer: TutuCardRenderer
    private let width: Int, height: Int, cutWidth: Int, cutHeight: Int
    private let scale: CGFloat
    private let border: MTLBuffer, base: MTLBuffer, raw: MTLBuffer
    private let warped: MTLBuffer, warpHorizontal: MTLBuffer, alpha: MTLBuffer
    private let impressionHorizontal: MTLBuffer, impression: MTLBuffer, heightField: MTLBuffer
    private let paper: MTLBuffer, color: MTLBuffer, cut: MTLBuffer
    private let noise: [MTLBuffer]
    private let warpKernel: MTLBuffer, impressionKernel: MTLBuffer
    private let warpRadius: Int, impressionRadius: Int
    private var uniforms: TutuChatCardUniforms

    init(renderer: TutuCardRenderer, layout: TutuChatCardLayout, index: Int, scale: CGFloat) throws {
        try TutuCardRenderer.preflight(size: layout.size, scale: scale, gpu: renderer.gpu)
        guard scale > 0, layout.size.width > 0, layout.size.height > 0 else { throw TutuChatError.command("卡片尺寸必须为正数") }
        self.renderer = renderer; self.scale = scale
        width = TutuChatCardTopology.round(Double(layout.size.width * scale))
        height = TutuChatCardTopology.round(Double(layout.size.height * scale))
        guard width >= 2, height >= 2 else { throw TutuChatError.command("卡片采样尺寸不足") }
        cutWidth = width + TutuChatCardTopology.round(Double(3 * scale))
        cutHeight = height + TutuChatCardTopology.round(Double(3 * scale))
        mask = try TutuChatTypeMask(size: layout.size, scale: scale)
        let texture = try renderer.gpu.texture(width: cutWidth, height: cutHeight)
        raster = TutuChatRaster(texture: texture, rect: CGRect(x: -1.5, y: -1.5,
            width: CGFloat(cutWidth) / scale, height: CGFloat(cutHeight) / scale))
        let bytes = width * height * MemoryLayout<Float>.stride
        border = try renderer.buffer(bytes: bytes); base = try renderer.buffer(bytes: bytes); raw = try renderer.buffer(bytes: bytes)
        warped = try renderer.buffer(bytes: bytes); warpHorizontal = try renderer.buffer(bytes: bytes); alpha = try renderer.buffer(bytes: bytes)
        impressionHorizontal = try renderer.buffer(bytes: bytes); impression = try renderer.buffer(bytes: bytes); heightField = try renderer.buffer(bytes: bytes)
        paper = try renderer.buffer(bytes: bytes * 4); color = try renderer.buffer(bytes: bytes * 4)
        cut = try renderer.buffer(bytes: cutWidth * cutHeight * MemoryLayout<SIMD4<Float>>.stride)
        var fields: [MTLBuffer] = []
        for _ in 0..<6 { fields.append(try renderer.buffer(bytes: bytes)) }
        noise = fields
        let wk = TutuChatCardTopology.gaussian(0.12 * Double(scale)), ik = TutuChatCardTopology.gaussian(0.25 * Double(scale))
        warpRadius = (wk.count - 1) / 2; impressionRadius = (ik.count - 1) / 2
        warpKernel = try renderer.buffer(wk); impressionKernel = try renderer.buffer(ik)
        var u = TutuChatCardUniforms()
        u.size = SIMD4(UInt32(width), UInt32(height), UInt32(cutWidth), UInt32(cutHeight))
        u.geometry = SIMD4(Float(layout.size.width), Float(layout.size.height), Float(scale), 1.5)
        u.paper.z = Float((index * 137 * 3) % renderer.paper.width)
        u.paper.w = Float((index * 211 * 3) % renderer.paper.height)
        if let m = layout.motif { u.motif = SIMD4(Float(m.minX), Float(m.minY), Float(m.maxX), Float(m.maxY)); u.control.w = 1 }
        uniforms = u

        let topology = TutuChatCardTopology(size: layout.size, scale: scale, index: index)
        let pillows = try renderer.buffer(topology.pillows)
        let bins = TutuChatCardBins(bounds: topology.pillows.map(\.bounds), width: width, height: height)
        let offsets = try renderer.buffer(bins.offsets), indices = try renderer.buffer(bins.indices)
        let borderRaw = try renderer.buffer(bytes: bytes), borderHorizontal = try renderer.buffer(bytes: bytes)
        let borderWeights = TutuChatCardTopology.gaussian(0.22 * Double(scale))
        let borderKernel = try renderer.buffer(borderWeights)
        let command = try renderer.command("tutu.chat.card.base")
        let all = TutuChatCardRegion(width: width, height: height)
        u.tiles.x = UInt32(bins.columns)
        try renderer.encode(command, "tutuChatCardBorder", uniforms: u, region: all) { e in
            e.setBuffer(pillows, offset: 0, index: 1); e.setBuffer(offsets, offset: 0, index: 2)
            e.setBuffer(indices, offset: 0, index: 3); e.setBuffer(borderRaw, offset: 0, index: 4)
        }
        u.control.x = UInt32((borderWeights.count - 1) / 2); u.control.y = 0; u.control.z = 0
        try renderer.encode(command, "tutuChatCardGaussian", uniforms: u, region: all) { e in
            e.setBuffer(borderRaw, offset: 0, index: 1); e.setBuffer(borderHorizontal, offset: 0, index: 2)
            e.setBuffer(borderKernel, offset: 0, index: 3); e.setBuffer(noise[2], offset: 0, index: 4)
        }
        u.control.y = 1
        try renderer.encode(command, "tutuChatCardGaussian", uniforms: u, region: all) { e in
            e.setBuffer(borderHorizontal, offset: 0, index: 1); e.setBuffer(border, offset: 0, index: 2)
            e.setBuffer(borderKernel, offset: 0, index: 3); e.setBuffer(noise[2], offset: 0, index: 4)
        }
        try renderer.encode(command, "tutuChatCardMotif", uniforms: u, region: all) { e in
            e.setBuffer(border, offset: 0, index: 1); e.setBuffer(base, offset: 0, index: 2); e.setTexture(renderer.sanyu, index: 0)
        }
        let features = [0.5, 0.5, 5.0, 22.0, 3.0, 3.5], seeds = [50, 51, 52, 60, 70, 80]
        for n in 0..<6 {
            let field = TutuChatCardTopology.noise(width: width, height: height, feature: features[n] * Double(scale), seed: seeds[n] + index)
            let grid = try renderer.buffer(field.grid)
            var nu = u; nu.paper.x = Float(features[n] * Double(scale)); nu.tiles.y = UInt32(field.columns)
            try renderer.encode(command, "tutuChatCardNoise", uniforms: nu, region: all) { e in
                e.setBuffer(grid, offset: 0, index: 1); e.setBuffer(noise[n], offset: 0, index: 2)
            }
        }
        try renderer.encode(command, "tutuChatCardPaper", uniforms: u, region: all) { e in
            e.setBuffer(paper, offset: 0, index: 1); e.setTexture(renderer.paper, index: 0)
        }
        let cutTopology = try renderer.buffer([topology.cut]), cutNoise = try renderer.buffer(topology.cutNoise)
        let cutEdgeOrder = try renderer.buffer(topology.cutEdgeOrder)
        let fibers = try renderer.buffer(topology.fibers)
        let fiberBounds = topology.fibers.map { f in
            SIMD4<Int32>(Int32(floor(f.x)), Int32(floor(f.y)), Int32(floor(f.x)) + 2, Int32(floor(f.y)) + 2)
        }
        let fiberBins = TutuChatCardBins(bounds: fiberBounds, width: cutWidth, height: cutHeight)
        let fiberOffsets = try renderer.buffer(fiberBins.offsets), fiberIndices = try renderer.buffer(fiberBins.indices)
        u.tiles.x = UInt32(fiberBins.columns)
        try renderer.encode(command, "tutuChatCardCutGeometry", uniforms: u, region: TutuChatCardRegion(width: cutWidth, height: cutHeight)) { e in
            e.setBuffer(cutTopology, offset: 0, index: 1); e.setBuffer(cutNoise, offset: 0, index: 2)
            e.setBuffer(fibers, offset: 0, index: 3); e.setBuffer(fiberOffsets, offset: 0, index: 4)
            e.setBuffer(fiberIndices, offset: 0, index: 5); e.setBuffer(cut, offset: 0, index: 6)
            e.setBuffer(cutEdgeOrder, offset: 0, index: 7)
        }
        initialGPUTime = try renderer.complete(command)

        // Source mean is accumulated from unrounded l, but variance reads the
        // Float32 lum array. This ordered Double reduction preserves that detail
        // and is performed once per geometry, never once per streamed glyph.
        let pixels = paper.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let count = width * height
        var mean = 0.0, square = 0.0
        for i in 0..<count { mean += (Double(pixels[i].x) + Double(pixels[i].y) + Double(pixels[i].z)) / 3 }
        mean /= Double(count)
        for i in 0..<count { let delta = Double(pixels[i].w) - mean; square += delta * delta }
        uniforms.paper.x = Float(mean); uniforms.paper.y = Float(sqrt(square / Double(count)) + 1e-6)
    }

    private func motifRegion(_ motif: CGRect?) -> TutuChatCardRegion? {
        guard let motif else { return nil }
        let sc = min(motif.width / 112, motif.height / 52)
        guard sc > 0 else { return nil }
        let hw = CGFloat(renderer.sanyu.width) / 3 / 2 * sc, hh = CGFloat(renderer.sanyu.height) / 3 / 2 * sc
        return TutuChatCardRegion(CGRect(x: (motif.midX - hw) * scale, y: (motif.midY - hh) * scale,
            width: hw * 2 * scale, height: hh * 2 * scale), width: width, height: height)
            .expanded(x: 1, y: 1, width: width, height: height)
    }

    func update(layout: TutuChatCardLayout, rawDirty: CGRect?, previousMotif: CGRect?,
                motifChanged: Bool, full: Bool) throws -> (time: Double, dirty: CGRect) {
        let all = TutuChatCardRegion(width: width, height: height)
        let empty = TutuChatCardRegion(.zero, width: width, height: height)
        let changed = full ? all : rawDirty.map { TutuChatCardRegion($0, width: width, height: height) } ?? empty
        if !changed.empty {
            TutuChatRenderTrace.emit("mask.shared-copy.begin")
            defer { TutuChatRenderTrace.emit("mask.shared-copy.end") }
            mask.alpha.withUnsafeBytes { source in
                let stride = MemoryLayout<Float>.stride
                for y in changed.y0..<changed.y1 {
                    let offset = (y * width + changed.x0) * stride
                    raw.contents().advanced(by: offset).copyMemory(from: source.baseAddress!.advanced(by: offset), byteCount: (changed.x1 - changed.x0) * stride)
                }
            }
        }
        let command = try renderer.command(full ? "tutu.chat.card.full" : "tutu.chat.card.dirty")
        var heightDirty = empty
        if !changed.empty {
            let warpHalo = Int(ceil(0.1 * Double(scale))) + 1
            let warpDirty = full ? all : changed.expanded(x: warpHalo, y: warpHalo, width: width, height: height)
            try renderer.encode(command, "tutuChatCardWarp", uniforms: uniforms, region: warpDirty) { e in
                e.setBuffer(raw, offset: 0, index: 1); e.setBuffer(noise[0], offset: 0, index: 2)
                e.setBuffer(noise[1], offset: 0, index: 3); e.setBuffer(warped, offset: 0, index: 4)
            }
            let warpH = full ? all : warpDirty.expanded(x: warpRadius, y: 0, width: width, height: height)
            let alphaDirty = full ? all : warpH.expanded(x: 0, y: warpRadius, width: width, height: height)
            try gaussian(command, input: warped, output: warpHorizontal, kernel: warpKernel, radius: warpRadius, vertical: false, threshold: false, region: warpH)
            try gaussian(command, input: warpHorizontal, output: alpha, kernel: warpKernel, radius: warpRadius, vertical: true, threshold: true, region: alphaDirty)
            let impressionH = full ? all : alphaDirty.expanded(x: impressionRadius, y: 0, width: width, height: height)
            heightDirty = full ? all : impressionH.expanded(x: 0, y: impressionRadius, width: width, height: height)
            try gaussian(command, input: alpha, output: impressionHorizontal, kernel: impressionKernel, radius: impressionRadius, vertical: false, threshold: false, region: impressionH)
            try gaussian(command, input: impressionHorizontal, output: impression, kernel: impressionKernel, radius: impressionRadius, vertical: true, threshold: false, region: heightDirty)
        }
        if motifChanged {
            let old = motifRegion(previousMotif) ?? empty, new = motifRegion(layout.motif) ?? empty
            let motifDirty = old.union(new)
            uniforms.control.w = layout.motif == nil ? 0 : 1
            if let m = layout.motif { uniforms.motif = SIMD4(Float(m.minX), Float(m.minY), Float(m.maxX), Float(m.maxY)) }
            try renderer.encode(command, "tutuChatCardMotif", uniforms: uniforms, region: motifDirty) { e in
                e.setBuffer(border, offset: 0, index: 1); e.setBuffer(base, offset: 0, index: 2); e.setTexture(renderer.sanyu, index: 0)
            }
            heightDirty = heightDirty.union(motifDirty)
        }
        // Recompute from immutable base, NEVER from already bitten/inked pixels.
        try renderer.encode(command, "tutuChatCardHeight", uniforms: uniforms, region: heightDirty) { e in
            e.setBuffer(base, offset: 0, index: 1); e.setBuffer(impression, offset: 0, index: 2)
            e.setBuffer(noise[3], offset: 0, index: 3); e.setBuffer(noise[4], offset: 0, index: 4); e.setBuffer(heightField, offset: 0, index: 5)
        }
        let shadeDirty = full ? all : heightDirty.expanded(x: 1, y: 1, width: width, height: height)
        try renderer.encode(command, "tutuChatCardShade", uniforms: uniforms, region: shadeDirty) { e in
            e.setBuffer(heightField, offset: 0, index: 1); e.setBuffer(alpha, offset: 0, index: 2)
            e.setBuffer(noise[5], offset: 0, index: 3); e.setBuffer(paper, offset: 0, index: 4); e.setBuffer(color, offset: 0, index: 5)
        }
        var outputDirty = TutuChatCardRegion(width: cutWidth, height: cutHeight)
        if !full {
            let offset = TutuChatCardTopology.round(1.5 * Double(scale))
            outputDirty.x0 = shadeDirty.x0 == 0 ? 0 : min(cutWidth, shadeDirty.x0 + offset)
            outputDirty.y0 = shadeDirty.y0 == 0 ? 0 : min(cutHeight, shadeDirty.y0 + offset)
            outputDirty.x1 = shadeDirty.x1 == width ? cutWidth : min(cutWidth, shadeDirty.x1 + offset)
            outputDirty.y1 = shadeDirty.y1 == height ? cutHeight : min(cutHeight, shadeDirty.y1 + offset)
        }
        try renderer.encode(command, "tutuChatCardCutColor", uniforms: uniforms, region: outputDirty) { e in
            e.setBuffer(color, offset: 0, index: 1); e.setBuffer(cut, offset: 0, index: 2); e.setTexture(raster.texture, index: 0)
        }
        return (try renderer.complete(command), outputDirty.rect)
    }

    private func gaussian(_ command: MTLCommandBuffer, input: MTLBuffer, output: MTLBuffer, kernel: MTLBuffer,
                          radius: Int, vertical: Bool, threshold: Bool, region: TutuChatCardRegion) throws {
        var u = uniforms
        u.control.x = UInt32(radius); u.control.y = vertical ? 1 : 0; u.control.z = threshold ? 1 : 0
        try renderer.encode(command, "tutuChatCardGaussian", uniforms: u, region: region) { e in
            e.setBuffer(input, offset: 0, index: 1); e.setBuffer(output, offset: 0, index: 2)
            e.setBuffer(kernel, offset: 0, index: 3); e.setBuffer(noise[2], offset: 0, index: 4)
        }
    }
}
#endif
#endif
