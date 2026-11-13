#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Metal

final class TutuLaceRenderer {
    private let gpu: TutuChatGPU
    private let pipeline: MTLComputePipelineState
    private let ribbon: MTLTexture
    private(set) var lastGPUTime: Double = 0

    init(gpu: TutuChatGPU) throws {
        self.gpu = gpu
        pipeline = try gpu.pipeline("tutuChatLaceScatter")
        ribbon = try gpu.image("ribbon.png")
    }

    struct Geometry {
        let points: [SIMD2<Double>]
        let tangents: [SIMD2<Double>]
        let rect: CGRect
        let width: Int
        let height: Int
    }

    /// Only bounded path geometry is built here; no raster/workset is allocated.
    static func geometry(cards: [CGRect], index: Int, scale: CGFloat, limit: Int) throws -> Geometry? {
        guard scale.isFinite, scale > 0 else { throw TutuChatError.textureSize }
        guard let first = cards.first, let last = cards.last else { return nil }
        guard first.minX.isFinite, first.minY.isFinite, last.maxY.isFinite else { throw TutuChatError.textureSize }
        let bw = 64.0, s = Double(scale)
        // q samples cover all but <0.5pt at the end. Reject impossible heights
        // before walking or storing even the quarter-point path.
        let minimumHeight = (last.maxY - first.minY - 24 - 0.5 + 7) * scale
        if minimumHeight > CGFloat(limit) { throw TutuChatError.textureSize }
        var rng = TutuChatRandom(seed: 40 + index)
        let phase = rng.uniform(0, 6.28), wavelength = rng.uniform(170, 210)
        let y0 = Double(first.minY) + 12, y1 = Double(last.maxY) - 12, span = y1 - y0
        let d = min(90, span * 0.36), wav = span > 200 ? 5.0 : 0.0
        func smoother(_ v: Double) -> Double { let u = min(1, max(0, v)); return u * u * u * (u * (6 * u - 15) + 10) }
        var raw: [SIMD2<Double>] = []
        var y = y0
        while y < y1 {
            let f = min(smoother((y - y0) / d), smoother((y1 - y) / d))
            let x = Double(first.minX) + bw / 2 + 4 - 26 * f + wav * sin(2 * .pi * (y - y0) / wavelength + phase) * f
            raw.append(SIMD2(x, y)); y += 0.25
        }
        guard raw.count > 1 else { return nil }
        var arc = [Double](repeating: 0, count: raw.count)
        for k in 1..<raw.count { let delta = raw[k] - raw[k - 1]; arc[k] = arc[k - 1] + hypot(delta.x, delta.y) }
        var q: [SIMD2<Double>] = [], j = 0, distance = 0.0
        while distance < arc[arc.count - 1] {
            while j < arc.count - 2 && arc[j + 1] < distance { j += 1 }
            let denominator = arc[j + 1] - arc[j], u = (distance - arc[j]) / (denominator == 0 ? 1 : denominator)
            q.append(raw[j] + (raw[j + 1] - raw[j]) * u); distance += 0.25
        }
        guard q.count >= 4 else { return nil }
        var tangents = [SIMD2<Double>](repeating: .zero, count: q.count)
        var xs0 = 1e9, xs1 = -1e9, ys0 = 1e9, ys1 = -1e9
        for k in q.indices {
            let delta = q[min(q.count - 1, k + 1)] - q[max(0, k - 1)], length = hypot(delta.x, delta.y)
            tangents[k] = delta / (length == 0 ? 1 : length)
            xs0 = min(xs0, q[k].x); xs1 = max(xs1, q[k].x); ys0 = min(ys0, q[k].y); ys1 = max(ys1, q[k].y)
        }
        let x0 = xs0 - (bw / 2 + 3), top = ys0 - 3, x1 = xs1 + (bw / 2 + 3), bottom = ys1 + 4
        let width = try TutuChatGPU.checkedDimension(CGFloat(ceil((x1 - x0) * s)), limit: limit)
        let height = try TutuChatGPU.checkedDimension(CGFloat(ceil((bottom - top) * s)), limit: limit)
        let rect = CGRect(x: x0, y: top, width: Double(width) / s, height: Double(height) / s)
        try TutuChatShadowRenderer.preflight(rect: rect, material: .lace, scale: scale, limit: limit)
        return Geometry(points: q, tangents: tangents, rect: rect, width: width, height: height)
    }

    func render(cards: [CGRect], index: Int, scale: CGFloat, prepared: Geometry? = nil) throws -> TutuChatRaster? {
        lastGPUTime = 0
        guard let geometry = try prepared ?? Self.geometry(cards: cards, index: index, scale: scale, limit: gpu.maxTextureSize2D) else { return nil }
        try TutuChatGPU.checkSize(width: geometry.width, height: geometry.height, limit: gpu.maxTextureSize2D)
        try TutuChatShadowRenderer.preflight(rect: geometry.rect, material: .lace, scale: scale, limit: gpu.maxTextureSize2D)
        let q = geometry.points, tangents = geometry.tangents
        let width = geometry.width, height = geometry.height
        let x0 = Double(geometry.rect.minX), top = Double(geometry.rect.minY)
        let bw = 64.0, s = Double(scale), ribK = bw * s / 304
        // Source samples walk forward and overwrite. Resolve the last writer serially, then let Metal read the photo.
        // This is not an inverse mapping: holes, mirrored seams and overlap order remain identical to the source.
        var sourceIndices = [Int32](repeating: -1, count: width * height)
        let rw = ribbon.width, rh = ribbon.height
        let start = Int(floor((225 + (index % 2 != 0 ? 300.0 : 0)) * ribK + 0.5))
        let step = 1 / (2 * s), nu = Int(floor(bw / step + 0.5)), length = Double(q.count - 1) * 0.25
        var sv = 0.0
        while sv < length {
            let fi = sv / 0.25, i0 = min(q.count - 2, Int(fi)), fraction = fi - Double(i0)
            let p = q[i0] + (q[i0 + 1] - q[i0]) * fraction
            let tangent = tangents[i0] + (tangents[i0 + 1] - tangents[i0]) * fraction
            var normal = SIMD2(tangent.y, -tangent.x)
            let magnitude = hypot(normal.x, normal.y); normal /= magnitude == 0 ? 1 : magnitude
            let a = start + Int(floor(sv * s)), tile = Int(floor(Double(a) / Double(rw)))
            var column = a - tile * rw
            if tile % 2 != 0 { column = rw - 1 - column }
            for ui in 0..<nu {
                let u = -bw / 2 + Double(ui) * step, point = p + normal * u
                let ix = Int(floor((point.x - x0) * s)), iy = Int(floor((point.y - top) * s))
                if ix < 0 || iy < 0 || ix >= width || iy >= height { continue }
                let row = rh - 1 - min(rh - 1, Int(floor((u + bw / 2) * s)))
                sourceIndices[iy * width + ix] = Int32(row * rw + column)
            }
            sv += step
        }
        guard let indices = sourceIndices.withUnsafeBytes({ gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let command = gpu.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw TutuChatError.allocation }
        let output = try gpu.texture(width: width, height: height)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(indices, offset: 0, index: 0)
        encoder.setTexture(ribbon, index: 0); encoder.setTexture(output, index: 1)
        let tw = pipeline.threadExecutionWidth, th = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tw))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1)); encoder.endEncoding()
        try gpu.complete(command)
        lastGPUTime = max(0, command.gpuEndTime - command.gpuStartTime)
        return TutuChatRaster(texture: output, rect: geometry.rect)
    }
}
#endif
#endif
