#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import simd

/// Source chat11.js 418–454 and 522–610. Only seeded geometry lives on the CPU;
/// all sampled height, convolution, cut coverage, and lighting live in Metal.
struct TutuChatCardPillow {
    var ellipse: SIMD4<Float>
    var relief: SIMD4<Float>
    var bounds: SIMD4<Int32>
}

struct TutuChatCardCut {
    var radii: SIMD4<Float>
    var cornerX: SIMD4<Float>
    var cornerY: SIMD4<Float>
    var rough: SIMD4<Float>
    var counts: SIMD4<UInt32>
}

struct TutuChatCardBins {
    let offsets: [UInt32]
    let indices: [UInt32]
    let columns: Int

    init(bounds: [SIMD4<Int32>], width: Int, height: Int) {
        columns = (width + 15) / 16
        let rows = (height + 15) / 16
        var cells = [[UInt32]](repeating: [], count: columns * rows)
        for (index, box) in bounds.enumerated() {
            let x0 = max(0, Int(box.x)), y0 = max(0, Int(box.y))
            let x1 = min(width, Int(box.z)), y1 = min(height, Int(box.w))
            guard x1 > x0, y1 > y0 else { continue }
            for y in (y0 / 16)...((y1 - 1) / 16) {
                for x in (x0 / 16)...((x1 - 1) / 16) { cells[y * columns + x].append(UInt32(index)) }
            }
        }
        var starts: [UInt32] = [0], entries: [UInt32] = []
        for cell in cells { entries.append(contentsOf: cell); starts.append(UInt32(entries.count)) }
        offsets = starts; indices = entries
    }
}

struct TutuChatCardTopology {
    let pillows: [TutuChatCardPillow]
    let cut: TutuChatCardCut
    let cutNoise: [Float]
    let fibers: [SIMD4<Float>]
    let cutEdgeOrder: [SIMD4<UInt32>]

    /// JS Math.round is floor(x + .5), including negative half-integers.
    static func round(_ value: Double) -> Int { Int(floor(value + 0.5)) }

    init(size: CGSize, scale: CGFloat, index: Int) {
        let w = Double(size.width), h = Double(size.height), s = Double(scale)
        let width = Self.round(w * s), height = Self.round(h * s)
        // JS selects the nearest cut side in Double before sampling its wander.
        // Float arithmetic can merge distinct distances on corner diagonals and
        // select a different side entirely. Preserve exact Double ordering with
        // monotonic integer keys for each axis, not a per-pixel coverage mask.
        func orderKey(_ value: Double) -> SIMD2<UInt32> {
            let bits = value.bitPattern
            let key = bits & (1 << 63) == 0 ? bits ^ (1 << 63) : ~bits
            return SIMD2(UInt32(key >> 32), UInt32(truncatingIfNeeded: key))
        }
        let cutWidth = width + Self.round(3 * s), cutHeight = height + Self.round(3 * s)
        var edgeOrder: [SIMD4<UInt32>] = []
        edgeOrder.reserveCapacity(cutWidth + cutHeight)
        for (count, extent) in [(cutWidth, w), (cutHeight, h)] {
            for pixel in 0..<count {
                let coordinate = (Double(pixel) + 0.5) / s - 1.5
                let near = orderKey(coordinate), far = orderKey(extent - coordinate)
                edgeOrder.append(SIMD4(near.x, near.y, far.x, far.y))
            }
        }
        cutEdgeOrder = edgeOrder
        var rng = TutuChatRandom(seed: 1000 + index)
        var shapes: [TutuChatCardPillow] = []
        func pillow(_ cx: Double, _ cy: Double, _ a: Double, _ b: Double,
                    _ angle: Double, _ amplitude: Double, _ power: Double = 0.55) {
            let r = max(a, b) + 0.1
            shapes.append(TutuChatCardPillow(ellipse: SIMD4(Float(cx), Float(cy), Float(a), Float(b)),
                relief: SIMD4(Float(cos(angle)), Float(sin(angle)), Float(amplitude), Float(power)),
                bounds: SIMD4(Int32(max(0, Int(floor((cx - r) * s)))), Int32(max(0, Int(floor((cy - r) * s)))),
                              Int32(min(width, Int(ceil((cx + r) * s)) + 1)), Int32(min(height, Int(ceil((cy + r) * s)) + 1)))))
        }
        func rosette(_ cx: Double, _ cy: Double, _ diameter: Double, _ amplitude: Double) {
            let rotation = rng.uniform(0, 2 * .pi)
            for q in 0..<5 {
                let a = rotation + Double(q) * 2 * .pi / 5 + rng.uniform(-0.11, 0.11)
                let distance = diameter * 0.27 * rng.uniform(0.94, 1.06)
                // Keep the JS argument evaluation/RNG order: long axis, short axis, amplitude.
                let long = diameter * 0.25 * rng.uniform(0.9, 1.08)
                let short = diameter * 0.185 * rng.uniform(0.9, 1.1)
                let pressure = amplitude * rng.uniform(0.92, 1.05)
                pillow(cx + cos(a) * distance, cy + sin(a) * distance, long, short, a, pressure)
            }
            let x = cx + rng.uniform(-0.08, 0.08), y = cy + rng.uniform(-0.08, 0.08)
            pillow(x, y, diameter * 0.12, diameter * 0.12, 0, amplitude * 1.18, 0.7)
        }
        let corners = [SIMD2(11.0, 11.0), SIMD2(w - 11, 11), SIMD2(w - 11, h - 11), SIMD2(11, h - 11)]
        for side in 0..<4 {
            let a = corners[side], b = corners[(side + 1) % 4]
            let delta = b - a, length = hypot(delta.x, delta.y), n = max(1, Self.round(length / 8.2))
            let phase = rng.uniform(0, 6.28), nx = -delta.y / length, ny = delta.x / length
            let phase2 = rng.uniform(0, 6.28)
            for q in 0..<n {
                let t = (Double(q) + (q == 0 ? 0 : rng.uniform(-0.05, 0.05))) / Double(n)
                let wobble = 0.22 * sin(Double(q) * 0.9 + phase) + rng.uniform(-0.08, 0.08)
                let pressure = 0.16 * (0.82 + 0.22 * sin(Double(q) * 0.33 + phase2) + rng.uniform(-0.07, 0.07))
                let diameter = 6 * rng.uniform(0.93, 1.07)
                rosette(a.x + delta.x * t + nx * wobble, a.y + delta.y * t + ny * wobble, diameter, pressure)
            }
        }
        pillows = shapes

        // The SAME RNG continues after the border. Neither independent value-noise
        // generators nor the deterministic Sanyu image consume this sequence.
        let perimeter = 2 * (w + h)
        var noise: [Float] = [], counts: [UInt32] = []
        for span in [perimeter / 9, perimeter / 2.5, perimeter / 0.7] {
            let n = max(4, Int(ceil(span)) + 2)
            counts.append(UInt32(n))
            for _ in 0..<n { noise.append(Float(rng.uniform(-1, 1))) }
        }
        var radii = SIMD4<Float>(), cx = SIMD4<Float>(), cy = SIMD4<Float>()
        for i in 0..<4 { radii[i] = Float(rng.uniform(0.2, 0.7)) }
        for i in 0..<4 { cx[i] = Float(rng.uniform(-0.6, 0.6)) }
        for i in 0..<4 { cy[i] = Float(rng.uniform(-0.6, 0.6)) }
        let pr = rng.random(), nr = pr < 0.35 ? 0 : pr < 0.78 ? 1 : 2
        var rough: [(Double, Double)] = []
        for _ in 0..<nr {
            let length = rng.uniform(5, 14), side = rng.integer(4), edgeLength = side % 2 == 1 ? h : w
            if edgeLength < length + 16 { continue }
            let start = (side == 0 ? 0 : side == 1 ? w : side == 2 ? w + h : 2 * w + h) + rng.uniform(8, edgeLength - length - 8)
            rough.append((start, start + length))
        }
        var stretches = SIMD4<Float>()
        for (i, rr) in rough.enumerated() { stretches[i * 2] = Float(rr.0); stretches[i * 2 + 1] = Float(rr.1) }
        cut = TutuChatCardCut(radii: radii, cornerX: cx, cornerY: cy, rough: stretches,
                             counts: SIMD4(counts[0], counts[1], counts[2], UInt32(rough.count)))
        cutNoise = noise
        var samples: [SIMD4<Float>] = []
        for rr in rough {
            let count = Self.round((rr.1 - rr.0) * 1.6)
            for _ in 0..<count {
                let sv = rng.uniform(rr.0, rr.1)
                let point: SIMD4<Double>
                if sv < w { point = SIMD4(sv, 0, 0, -1) }
                else if sv < w + h { point = SIMD4(w, sv - w, 1, 0) }
                else if sv < 2 * w + h { point = SIMD4(w - (sv - w - h), h, 0, 1) }
                else { point = SIMD4(0, h - (sv - 2 * w - h), -1, 0) }
                let length = min(0.55, 0.12 + rng.exponential(0.18))
                let sign = rng.random() < 0.5 ? -1.0 : 1.0
                let angle = atan2(point.w, point.z) + sign * rng.uniform(0.9, 1.35)
                let bx = point.x - point.z * 0.3, by = point.y - point.w * 0.3
                let bend = rng.normal(0, 0.6), segments = max(2, Int(ceil(length / 0.1)))
                for q in 0...segments {
                    let t = Double(q) / Double(segments), a = angle + bend * t
                    let x = (bx + cos(a) * length * t + 1.5) * s - 0.5
                    let y = (by + sin(a) * length * t + 1.5) * s - 0.5
                    samples.append(SIMD4(Float(x), Float(y), Float(0.32 * (1 - 0.65 * t)), 0))
                }
            }
        }
        fibers = samples
    }

    static func noise(width: Int, height: Int, feature: Double, seed: Int) -> (grid: [Float], columns: Int) {
        let columns = Int(floor(Double(width) / feature)) + 3
        let rows = Int(floor(Double(height) / feature)) + 3
        var rng = TutuChatRandom(seed: seed), grid: [Float] = []
        grid.reserveCapacity(columns * rows)
        for _ in 0..<(columns * rows) { grid.append(Float(rng.uniform(-1, 1))) }
        return (grid, columns)
    }

    static func gaussian(_ sigma: Double) -> [Float] {
        let radius = max(1, Int(ceil(3 * sigma)))
        var kernel: [Float] = [], sum = 0.0
        for i in -radius...radius {
            let value = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
            kernel.append(value); sum += Double(value)
        }
        for i in kernel.indices { kernel[i] = Float(Double(kernel[i]) / sum) }
        return kernel
    }
}
#endif
#endif
