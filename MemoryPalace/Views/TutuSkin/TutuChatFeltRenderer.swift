#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Metal

/// Serial contour/RNG work preserves the source ordering; height, thread and light are computed on the GPU.
final class TutuFeltRenderer {
    private let gpu: TutuChatGPU
    private let materialPipeline: MTLComputePipelineState
    private let shadowPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState
    private let finishPipeline: MTLComputePipelineState
    private let fibre: MTLBuffer
    private let fibreSize: Int
    private(set) var lastGPUTime: Double = 0

    private struct Uniforms {
        var width: UInt32; var height: UInt32; var fibreSize: UInt32; var binsWide: UInt32
        var kf: Float; var scale: Float; var toy: UInt32; var tox: UInt32
    }
    private struct BlurUniforms { var width: UInt32; var height: UInt32; var radius: UInt32; var vertical: UInt32 }
    private struct Shape {
        var w: Double; var h: Double; var ears: Bool; var tail: Bool; var emoji: Bool
        var ex: Double { emoji ? w / 2 : min(min(15, h / 2) + 15, w * 0.3) }
        var ew: Double { emoji ? 14 : 12.4 }
        var el: Double { emoji ? 22 : 20 }
        var x0: Double { ex - ew - 1.5 }; var x1: Double { ex + ew + 1.5 }
        var y0: Double { 3.5 - el - 1.5 }; var y1: Double { 11 }
    }

    init(gpu: TutuChatGPU) throws {
        self.gpu = gpu
        materialPipeline = try gpu.pipeline("tutuChatFeltMaterial")
        shadowPipeline = try gpu.pipeline("tutuChatFeltShadow")
        blurPipeline = try gpu.pipeline("tutuChatFeltBlur")
        finishPipeline = try gpu.pipeline("tutuChatFeltFinish")
        let source = try TutuChatPixels(url: gpu.resourceURL.appendingPathComponent("fibre.png"))
        let fw = source.width, n = fw * 2
        var values = [Float](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n {
            let tx = Double(x) * 0.5, ty = Double(y) * 0.5
            let x0 = Int(tx), y0 = Int(ty), x1 = (x0 + 1) % fw, y1 = (y0 + 1) % fw
            let fx = tx - Double(x0), fy = ty - Double(y0)
            let a = Double(source.rgba[(y0 * fw + x0) * 4]), b = Double(source.rgba[(y0 * fw + x1) * 4])
            let c = Double(source.rgba[(y1 * fw + x0) * 4]), d = Double(source.rgba[(y1 * fw + x1) * 4])
            values[y * n + x] = Float(((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy - 128) / 40)
        } }
        guard let buffer = values.withUnsafeBytes({ gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { throw TutuChatError.allocation }
        fibre = buffer; fibreSize = n
    }

    @discardableResult
    static func preflight(size: CGSize, ears: Bool, tail: Bool, emoji: Bool, scale: CGFloat,
                          gpu: TutuChatGPU, origin: CGPoint = .zero) throws -> (width: Int, height: Int) {
        guard scale.isFinite, scale > 0, size.width > 0, size.height > 0 else { throw TutuChatError.textureSize }
        let limit = gpu.maxTextureSize2D
        let top: CGFloat = ears ? (emoji ? 25 : 23) : 6
        let right: CGFloat = tail && !emoji ? 14 : 6
        var width = try TutuChatGPU.checkedDimension(ceil((size.width + 6 + right) * 2 * scale), limit: limit)
        var height = try TutuChatGPU.checkedDimension(ceil((size.height + top + 6) * 2 * scale), limit: limit)
        width += width & 1; height += height & 1
        // KF=2S buffers are bounded too, not just the half-resolution output.
        try TutuChatGPU.checkSize(width: width, height: height, limit: limit)
        let rect = CGRect(x: -6, y: -top, width: CGFloat(width / 2) / scale, height: CGFloat(height / 2) / scale)
        try TutuChatShadowRenderer.preflight(rect: rect, origin: origin, material: .felt, scale: scale, limit: limit)
        return (width, height)
    }

    func render(size: CGSize, ears: Bool, tail: Bool, emoji: Bool, index: Int, scale: CGFloat) throws -> TutuChatRaster {
        let dimensions = try Self.preflight(size: size, ears: ears, tail: tail, emoji: emoji, scale: scale, gpu: gpu)
        let f = Shape(w: Double(size.width), h: Double(size.height), ears: ears, tail: tail, emoji: emoji)
        let kf = Double(scale) * 2, left = 6.0, top = ears ? (emoji ? 25.0 : 23.0) : 6.0
        let width = dimensions.width, height = dimensions.height
        let count = width * height, wc = width / 2, hc = height / 2, kc = kf / 2
        var coarse = [Float](repeating: 0, count: wc * hc)
        for y in 0..<hc { for x in 0..<wc { coarse[y * wc + x] = Float(Self.sdf((Double(x) + 0.5) / kc - left, (Double(y) + 0.5) / kc - top, f, true)) } }
        let ex0 = ears ? max(0, Int(floor((f.x0 + left) * kf))) : 0
        let ex1 = ears ? min(width, Int(ceil((f.x1 + left) * kf))) : 0
        let ey0 = ears ? max(0, Int(floor((f.y0 + top) * kf))) : 0
        let ey1 = ears ? min(height, Int(ceil((f.y1 + top) * kf))) : 0
        var sdf = [Float](repeating: 0, count: count), noslit = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            let yc = Self.clamp(Double(y) / 2 - 0.25, 0, Double(hc) - 1.001), y0 = Int(yc), fy = yc - Double(y0)
            for x in 0..<width {
                let k = y * width + x
                let value: Double, ns: Double
                if y >= ey0 && y < ey1 && x >= ex0 && x < ex1 {
                    let px = (Double(x) + 0.5) / kf - left, py = (Double(y) + 0.5) / kf - top
                    value = Self.sdf(px, py, f, true); ns = Self.sdf(px, py, f, false)
                } else {
                    let xc = Self.clamp(Double(x) / 2 - 0.25, 0, Double(wc) - 1.001), x0 = Int(xc), fx = xc - Double(x0), p = y0 * wc + x0
                    value = (Double(coarse[p]) * (1 - fx) + Double(coarse[p + 1]) * fx) * (1 - fy) + (Double(coarse[p + wc]) * (1 - fx) + Double(coarse[p + wc + 1]) * fx) * fy
                    ns = value
                }
                sdf[k] = Float(value); noslit[k] = ns < 0 ? 1 : 0
            }
        }
        var rng = TutuChatRandom(seed: 300 + index)
        let loops = Self.insetLoops(noslit, width, height, 3.3, kf)
        var points: [SIMD2<Float>] = [], lengths: [Float] = [], bounds: [SIMD4<Int32>] = []
        let binsWide = (width + 15) / 16, binsHigh = (height + 15) / 16
        var bins = [[UInt32]](repeating: [], count: binsWide * binsHigh)
        for loop in loops {
            let n0 = loop.count
            var acc = [Double](repeating: 0, count: n0 + 1)
            for q in 1...n0 { let a = loop[q - 1], b = loop[q % n0]; acc[q] = acc[q - 1] + hypot(b.x - a.x, b.y - a.y) }
            func at(_ length: Double) -> CGPoint {
                if length <= 0 || length >= acc[n0] { return loop[0] }
                var lo = 0, hi = n0
                while hi - lo > 1 { let mid = (lo + hi) / 2; if acc[mid] <= length { lo = mid } else { hi = mid } }
                let denominator = acc[lo + 1] - acc[lo], t = (length - acc[lo]) / (denominator == 0 ? 1 : denominator)
                let a = loop[lo], b = loop[(lo + 1) % n0]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            let length = acc[n0] / kf, n = max(3, Int(floor(length / 5.9 + 0.5))), pitch = length / Double(n)
            for si in 0..<n {
                let a0 = (Double(si) * pitch + rng.uniform(-0.3, 0.3)) * kf
                let a1 = a0 + 3.6 * rng.uniform(0.86, 1.1) * kf
                var pts = (0..<16).map { at(a0 + (a1 - a0) * Double($0) / 15) }
                let tx = pts[15].x - pts[0].x, ty = pts[15].y - pts[0].y, tl = hypot(tx, ty) + 1e-9
                let off = rng.uniform(-0.18, 0.18) * kf, tilt = rng.uniform(-0.12, 0.12) * kf
                var bx0 = 1e9, by0 = 1e9, bx1 = -1e9, by1 = -1e9
                for q in 0..<16 {
                    let offset = off + tilt * (-1 + 2 * Double(q) / 15)
                    pts[q].x += -ty / tl * offset; pts[q].y += tx / tl * offset
                    bx0 = min(bx0, pts[q].x); by0 = min(by0, pts[q].y); bx1 = max(bx1, pts[q].x); by1 = max(by1, pts[q].y)
                }
                let i0 = max(0, Int(floor(by0 - 3))), i1 = min(height, Int(floor(by1 + 3)) + 1)
                let j0 = max(0, Int(floor(bx0 - 3))), j1 = min(width, Int(floor(bx1 + 3)) + 1)
                let ordinal = UInt32(lengths.count)
                points.append(contentsOf: pts.map { SIMD2(Float($0.x), Float($0.y)) }); lengths.append(Float((a1 - a0) / kf))
                bounds.append(SIMD4(Int32(j0), Int32(i0), Int32(j1), Int32(i1)))
                if i1 > i0 && j1 > j0 { for by in (i0 / 16)...((i1 - 1) / 16) { for bx in (j0 / 16)...((j1 - 1) / 16) { bins[by * binsWide + bx].append(ordinal) } } }
            }
        }
        var offsets: [UInt32] = [0], references: [UInt32] = []
        for bin in bins { references.append(contentsOf: bin); offsets.append(UInt32(references.count)) }
        // Keep Float32 accumulation after each splat, in exactly the source's hair/sample order.
        var fuzz = [Float](repeating: 0, count: count), band: [Int] = []
        for k in 0..<count where sdf[k] < 0.18 && sdf[k] > -0.18 { band.append(k) }
        if !band.isEmpty {
            let hairs = Int(floor(Double(band.count) / (0.36 * kf) * 7.5))
            for _ in 0..<hairs {
                let idx = band[rng.integer(band.count)], py = idx / width, px = idx - py * width
                let gradient = Self.gradient(sdf, width, height, px, py), nl = hypot(gradient.x, gradient.y) + 1e-9
                let nx = gradient.x / nl, ny = gradient.y / nl
                let fy = Double(py) + rng.random(), fx = Double(px) + rng.random()
                let onTail = tail && hypot(fx / kf - left - (f.w + 1.2), fy / kf - top - f.h * 0.66) < 7.5
                let base = atan2(ny, nx) + rng.normal(0, 0.62), inside = rng.uniform(0.15, 0.85) * kf
                var hx = fx - nx * inside, hy = fy - ny * inside
                var length = Self.clamp((0.35 + rng.exponential(0.75)) * (onTail ? 1.7 : 1), 0.3, 3.4) * kf
                if rng.random() < 0.02 { length = rng.uniform(2.5, 4.5) * kf }
                let bend = rng.normal(0, 0.8), m = max(2, Int(ceil(length / 0.35))), ds = length / Double(m - 1)
                let dc = cos(bend / Double(m - 1)), dsn = sin(bend / Double(m - 1))
                var ux = cos(base), uy = sin(base)
                Self.splat(&fuzz, width, height, hx, hy, 0.55)
                for q in 1..<m {
                    let ux2 = ux * dc - uy * dsn; uy = ux * dsn + uy * dc; ux = ux2
                    hx += ux * ds; hy += uy * ds
                    Self.splat(&fuzz, width, height, hx, hy, 0.55 * (1 - 0.55 * Double(q) / Double(m - 1)))
                }
            }
        }
        let sdfBuffer = try buffer(sdf), fuzzBuffer = try buffer(fuzz), pointBuffer = try buffer(points)
        let lengthBuffer = try buffer(lengths), boundsBuffer = try buffer(bounds), offsetBuffer = try buffer(offsets), referenceBuffer = try buffer(references)
        let material = try emptyBuffer(count * MemoryLayout<SIMD4<Float>>.stride), coverage = try emptyBuffer(count * MemoryLayout<SIMD2<Float>>.stride)
        let shadow = try emptyBuffer(wc * hc * 4), temporary = try emptyBuffer(wc * hc * 4), blurred = try emptyBuffer(wc * hc * 4)
        let kernel = Self.gaussian(0.32 * kf / 2), kernelBuffer = try buffer(kernel)
        let output = try gpu.texture(width: wc, height: hc)
        guard let command = gpu.queue.makeCommandBuffer() else { throw TutuChatError.allocation }
        var u = Uniforms(width: UInt32(width), height: UInt32(height), fibreSize: UInt32(fibreSize), binsWide: UInt32(binsWide), kf: Float(kf), scale: Float(scale), toy: UInt32((index * 131) % fibreSize), tox: UInt32((index * 197) % fibreSize))
        try encode(command, materialPipeline, width, height) { encoder in
            for (i, b) in [sdfBuffer, fibre, pointBuffer, lengthBuffer, boundsBuffer, offsetBuffer, referenceBuffer, material, coverage].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 9)
        }
        try encode(command, shadowPipeline, wc, hc) { encoder in
            encoder.setBuffer(coverage, offset: 0, index: 0); encoder.setBuffer(shadow, offset: 0, index: 1)
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        }
        for axis in 0..<2 {
            var blur = BlurUniforms(width: UInt32(wc), height: UInt32(hc), radius: UInt32(kernel.count / 2), vertical: UInt32(axis))
            try encode(command, blurPipeline, wc, hc) { encoder in
                encoder.setBuffer(axis == 0 ? shadow : temporary, offset: 0, index: 0); encoder.setBuffer(axis == 0 ? temporary : blurred, offset: 0, index: 1)
                encoder.setBuffer(kernelBuffer, offset: 0, index: 2); encoder.setBytes(&blur, length: MemoryLayout<BlurUniforms>.stride, index: 3)
            }
        }
        try encode(command, finishPipeline, wc, hc) { encoder in
            for (i, b) in [sdfBuffer, fuzzBuffer, material, coverage, blurred].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 5); encoder.setTexture(output, index: 0)
        }
        try gpu.complete(command)
        lastGPUTime = max(0, command.gpuEndTime - command.gpuStartTime)
        return TutuChatRaster(texture: output, rect: CGRect(x: -left, y: -top, width: Double(wc) / Double(scale), height: Double(hc) / Double(scale)))
    }

    private func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        if values.isEmpty { return try emptyBuffer(MemoryLayout<T>.stride) }
        guard let result = values.withUnsafeBytes({ gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { throw TutuChatError.allocation }
        return result
    }
    private func emptyBuffer(_ bytes: Int) throws -> MTLBuffer {
        guard let result = gpu.device.makeBuffer(length: max(1, bytes), options: .storageModeShared) else { throw TutuChatError.allocation }; return result
    }
    private func encode(_ command: MTLCommandBuffer, _ pipeline: MTLComputePipelineState, _ width: Int, _ height: Int, bindings: (MTLComputeCommandEncoder) -> Void) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw TutuChatError.allocation }
        encoder.setComputePipelineState(pipeline); bindings(encoder)
        let tw = pipeline.threadExecutionWidth, th = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tw))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1)); encoder.endEncoding()
    }
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    private static func smoothMin(_ a: Double, _ b: Double, _ k: Double) -> Double { let h = clamp(0.5 + 0.5 * (b - a) / k, 0, 1); return b * (1 - h) + a * h - k * h * (1 - h) }
    private static func box(_ x: Double, _ y: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ radius: Double = 0) -> Double {
        let qx = abs(x - (x0 + x1) / 2) - ((x1 - x0) / 2 - radius), qy = abs(y - (y0 + y1) / 2) - ((y1 - y0) / 2 - radius)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    }
    private static func sdf(_ x: Double, _ y: Double, _ f: Shape, _ slit: Bool) -> Double {
        var d: Double
        if f.emoji { let ax = f.w / 2, ay = f.h / 2, u = (x - ax) / ax, v = (y - ay) / ay * (y > ay ? 0.97 : 1.03); d = (hypot(u, v) - 1) * min(ax, ay) }
        else { d = box(x, y, 0, 0, f.w, f.h, min(15, f.h / 2)) }
        if f.ears {
            let bx = x < f.x0 ? f.x0 - x : (x > f.x1 ? x - f.x1 : 0), by = y < f.y0 ? f.y0 - y : (y > f.y1 ? y - f.y1 : 0)
            if hypot(bx, by) < d + 3 {
                let angle = 2.0 * Double.pi / 180, c = cos(angle), s = sin(angle), ry = 5.5
                let xr = f.ex + (x - f.ex) * c + (y - ry) * s, yr = ry - (x - f.ex) * s + (y - ry) * c
                let r = f.ew / 2, tip = 3.5 - f.el, root = 8.5
                func cap(_ cx: Double, _ yRoot: Double, _ radius: Double) -> Double { hypot(xr - cx, yr - clamp(yr, tip + radius, yRoot)) - radius }
                let a = cap(f.ex - r - 0.31, root, r), b = cap(f.ex + r + 0.31, root + 0.4, r * 0.97)
                let join = slit ? tip + f.el * 0.62 : tip + r * 1.15
                d = smoothMin(d, min(min(a, b), box(xr, yr, f.ex - r, join, f.ex + r, root)), 3)
            }
        }
        if f.tail && !f.emoji { let tx = x - (f.w + 1.2), ty = y - f.h * 0.66; if tx > -12 { d = smoothMin(d, hypot(tx, ty) - 5.4, 3) } }
        return d
    }
    private static func gradient(_ a: [Float], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> CGPoint {
        let xa = max(0, x - 1), xb = min(w - 1, x + 1), ya = max(0, y - 1), yb = min(h - 1, y + 1)
        return CGPoint(x: (Double(a[y * w + xb]) - Double(a[y * w + xa])) / Double(xb - xa), y: (Double(a[yb * w + x]) - Double(a[ya * w + x])) / Double(yb - ya))
    }
    private static func splat(_ a: inout [Float], _ w: Int, _ h: Int, _ x: Double, _ y: Double, _ weight: Double) {
        let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - Double(x0), fy = y - Double(y0)
        for dy in 0...1 { let yy = y0 + dy; if yy < 0 || yy >= h { continue }; for dx in 0...1 { let xx = x0 + dx; if xx >= 0 && xx < w { let p = yy * w + xx; a[p] = Float(Double(a[p]) + weight * (dx == 0 ? 1 - fx : fx) * (dy == 0 ? 1 - fy : fy)) } } }
    }
    private static func gaussian(_ sigma: Double) -> [Float] {
        let r = max(1, Int(ceil(3 * sigma)))
        var kernel = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = kernel.reduce(0.0) { $0 + Double($1) }
        for i in kernel.indices { kernel[i] = Float(Double(kernel[i]) / sum) }; return kernel
    }
    private static func blur(_ a: [Float], _ w: Int, _ h: Int, _ sigma: Double) -> [Float] {
        if sigma <= 0 { return a }
        let kernel = gaussian(sigma), r = kernel.count / 2
        var tmp = [Float](repeating: 0, count: a.count), out = tmp
        for y in 0..<h { for x in 0..<w { var acc = 0.0; for j in -r...r { acc += Double(kernel[j + r]) * Double(a[y * w + min(w - 1, max(0, x + j))]) }; tmp[y * w + x] = Float(acc) } }
        for y in 0..<h { for x in 0..<w { var acc = 0.0; for j in -r...r { acc += Double(kernel[j + r]) * Double(tmp[min(h - 1, max(0, y + j)) * w + x]) }; out[y * w + x] = Float(acc) } }
        return out
    }
    private static func edt(_ f: inout [Float], _ w: Int, _ h: Int) {
        let n = max(w, h)
        var d = [Double](repeating: 0, count: n), v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1), g = [Double](repeating: 0, count: n)
        func pass(_ length: Int) {
            var k = 0; v[0] = 0; z[0] = -1e30; z[1] = 1e30
            if length > 1 { for q in 1..<length {
                var s = ((g[q] + Double(q * q)) - (g[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
                while s <= z[k] { k -= 1; s = ((g[q] + Double(q * q)) - (g[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k]) }
                k += 1; v[k] = q; z[k] = s; z[k + 1] = 1e30
            } }
            k = 0
            for q in 0..<length { while z[k + 1] < Double(q) { k += 1 }; d[q] = Double((q - v[k]) * (q - v[k])) + g[v[k]] }
        }
        for x in 0..<w { for y in 0..<h { g[y] = Double(f[y * w + x]) }; pass(h); for y in 0..<h { f[y * w + x] = Float(d[y]) } }
        for y in 0..<h { for x in 0..<w { g[x] = Double(f[y * w + x]) }; pass(w); for x in 0..<w { f[y * w + x] = Float(d[x]) } }
    }
    private static func insetLoops(_ shape: [UInt8], _ w: Int, _ h: Int, _ radius: Double, _ kf: Double) -> [[CGPoint]] {
        let wc = w / 2, hc = h / 2
        var field = [Float](repeating: 0, count: wc * hc)
        for y in 0..<hc { for x in 0..<wc { let p = 2 * y * w + 2 * x; let sum = Int(shape[p]) + Int(shape[p + 1]) + Int(shape[p + w]) + Int(shape[p + w + 1]); field[y * wc + x] = sum >= 2 ? 1e20 : 0 } }
        edt(&field, wc, hc)
        let rr = radius * kf / 2 * radius * kf / 2
        for k in field.indices { field[k] = Double(field[k]) > rr ? 1 : 0 }
        field = blur(field, wc, hc, 0.25 * kf / 2)
        for k in field.indices { field[k] = -field[k] }
        return levelLoops(field, wc, hc, -0.5).map { $0.map { CGPoint(x: $0.x * 2 + 0.5, y: $0.y * 2 + 0.5) } }
    }
    private static func levelLoops(_ field: [Float], _ w: Int, _ h: Int, _ iso: Double) -> [[CGPoint]] {
        // Ordered adjacency keys match JavaScript Map insertion order; dictionary iteration would change the RNG sequence.
        var points: [Int: CGPoint] = [:], adjacency: [Int: [Int]] = [:], order: [Int] = []
        func point(_ id: Int, _ x: Double, _ y: Double) -> Int { points[id] = CGPoint(x: x, y: y); return id }
        func link(_ p: Int, _ q: Int) {
            if adjacency[p] == nil { adjacency[p] = []; order.append(p) }; adjacency[p]!.append(q)
            if adjacency[q] == nil { adjacency[q] = []; order.append(q) }; adjacency[q]!.append(p)
        }
        for j in 0..<(h - 1) { for i in 0..<(w - 1) {
            let a = Double(field[j * w + i]) - iso, b = Double(field[j * w + i + 1]) - iso
            let c = Double(field[(j + 1) * w + i + 1]) - iso, d = Double(field[(j + 1) * w + i]) - iso
            let cs = (a < 0 ? 8 : 0) | (b < 0 ? 4 : 0) | (c < 0 ? 2 : 0) | (d < 0 ? 1 : 0)
            if cs == 0 || cs == 15 { continue }
            let t = (a < 0) != (b < 0) ? point((j * w + i) * 2, Double(i) + a / (a - b), Double(j)) : -1
            let r = (b < 0) != (c < 0) ? point((j * w + i + 1) * 2 + 1, Double(i + 1), Double(j) + b / (b - c)) : -1
            let bottom = (d < 0) != (c < 0) ? point(((j + 1) * w + i) * 2, Double(i) + d / (d - c), Double(j + 1)) : -1
            let l = (a < 0) != (d < 0) ? point((j * w + i) * 2 + 1, Double(i), Double(j) + a / (a - d)) : -1
            let edges = [t, r, bottom, l].filter { $0 >= 0 }
            if edges.count == 2 { link(edges[0], edges[1]) }
            else if edges.count == 4 { let mid = (a + b + c + d) / 4; if (mid < 0) == (cs == 5) { link(l, t); link(bottom, r) } else { link(t, r); link(l, bottom) } }
        } }
        var seen = Set<Int>(), loops: [[CGPoint]] = []
        for start in order where !seen.contains(start) {
            var loop: [CGPoint] = [], previous = -1, current = start
            while current >= 0 && !seen.contains(current) {
                seen.insert(current); loop.append(points[current]!)
                var next = -1
                for neighbor in adjacency[current]! where neighbor != previous && !seen.contains(neighbor) { next = neighbor; break }
                previous = current; current = next
            }
            if loop.count > 12 { loops.append(loop) }
        }
        return loops
    }
}
#endif
#endif
