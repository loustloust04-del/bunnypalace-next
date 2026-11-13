#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics

struct TutuCathedralMesh {
    var glaze: [Float]
    var shards: [Float]
    var pieces: [TutuCathedralPiece]
    /// RGBA, 780 × 1688, with the first row at the top.
    var breakPixels: [UInt8]
    var lossPixels: [UInt8]
}

struct TutuCathedralPiece {
    var first: Int
    var count: Int
    var release: Double
    var releasedAt: Double = -1
}

enum TutuCathedralGeometry {
    static func make(coverage: CGImage) throws -> TutuCathedralMesh {
        try TutuCathedralGeometryBuilder(coverage: coverage).make()
    }
}

private enum TutuCathedralGeometryError: Error {
    case bitmapContext
}

private typealias TutuCathedralPoint = SIMD2<Double>
private typealias TutuCathedralPoint3 = SIMD3<Double>

private struct TutuCathedralPolygon {
    var points: [TutuCathedralPoint]
    var parentID: Int = -1
    var childID: Int = -1
}

private struct TutuCathedralPending {
    var polygon: TutuCathedralPolygon
    var generation: Int
    var parent: Int
    var child: Int
}

private final class TutuCathedralBody {
    var polygon: TutuCathedralPolygon
    var children: [Int] = []
    var fronts: [Range<Int>] = []
    var centre = TutuCathedralPoint.zero
    var seed: Double = 0
    var radius: Double = 0
    var impact: Double = 0
    var role: Double = 0
    var parentIndex: Int = -1
    var id: Int = -1
    var home: TutuCathedralPoint3?
    var hull: [TutuCathedralPoint] = []

    init(_ polygon: TutuCathedralPolygon) {
        self.polygon = polygon
    }
}

private struct TutuCathedralHeapItem {
    var at: Int
    var distance: Double
}

/// The canonical fractureMesh algorithm. Geometry arithmetic stays in Double like
/// JavaScript numbers; only the distance field and the final GPU streams are Float32.
private final class TutuCathedralGeometryBuilder {
    private static let width = 390
    private static let height = 844
    private static let mapWidth = 780
    private static let mapHeight = 1688
    private let coverageImage: CGImage
    private var sourceCoverage: [UInt8]?
    private var randomState: Int64 = 170921
    private var cells: [TutuCathedralPolygon] = []
    private var parents: [TutuCathedralBody] = []
    private var children: [TutuCathedralBody] = []
    private var pixels: [UInt8] = []
    private var distances: [Float] = []
    private var heap: [TutuCathedralHeapItem] = []
    private var farthest: Double = 1
    private var data: [Double] = []
    private var shardData: [Float] = []

    init(coverage: CGImage) {
        coverageImage = coverage
    }

    private func random() -> Double {
        randomState = (randomState * 16807) % 2147483647
        return Double(randomState - 1) / 2147483646
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value < low ? low : (value > high ? high : value)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private func area(_ polygon: TutuCathedralPolygon) -> Double {
        let points = polygon.points
        var result = 0.0
        for j in points.indices {
            let q = points[j], r = points[(j + 1) % points.count]
            result += q.x * r.y - r.x * q.y
        }
        return abs(result) * 0.5
    }

    private func centre(_ polygon: TutuCathedralPolygon) -> TutuCathedralPoint {
        var result = TutuCathedralPoint.zero
        for q in polygon.points { result += q }
        return result / Double(polygon.points.count)
    }

    private func half(_ polygon: TutuCathedralPolygon, _ c: TutuCathedralPoint,
                      _ n: TutuCathedralPoint, _ side: Double) -> TutuCathedralPolygon {
        var out: [TutuCathedralPoint] = []
        let points = polygon.points
        for j in points.indices {
            let a = points[j], b = points[(j + 1) % points.count]
            let da = ((a.x - c.x) * n.x + (a.y - c.y) * n.y) * side
            let db = ((b.x - c.x) * n.x + (b.y - c.y) * n.y) * side
            if da >= 0 { out.append(a) }
            if (da > 0 && db < 0) || (da < 0 && db > 0) {
                let t = da / (da - db)
                out.append(TutuCathedralPoint(lerp(a.x, b.x, t), lerp(a.y, b.y, t)))
            }
        }
        return TutuCathedralPolygon(points: out)
    }

    private func splitCells() {
        let w = Double(Self.width), h = Double(Self.height)
        var pending = [TutuCathedralPending(
            polygon: TutuCathedralPolygon(points: [.zero, .init(w, 0), .init(w, h), .init(0, h)]),
            generation: 0, parent: -1, child: -1)]
        while var piece = pending.popLast() {
            var polygon = piece.polygon
            let c = centre(polygon), mass = area(polygon)
            if piece.generation == 3 {
                piece.parent = parents.count
                parents.append(TutuCathedralBody(polygon))
            }
            if piece.generation == 5 {
                piece.child = children.count
                let child = TutuCathedralBody(polygon)
                child.parentIndex = piece.parent
                children.append(child)
                parents[piece.parent].children.append(piece.child)
            }
            polygon.parentID = piece.parent
            polygon.childID = piece.child
            let targetArea = 100 + 750 * pow(random(), 1.7)
            if (mass < targetArea && piece.generation >= 5) || piece.generation >= 16 {
                cells.append(polygon)
                continue
            }
            var xx = 0.0, yy = 0.0, xy = 0.0
            for q in polygon.points {
                let x = q.x - c.x, y = q.y - c.y
                xx += x * x
                yy += y * y
                xy += x * y
            }
            let axis = 0.5 * atan2(2 * xy, xx - yy)
            var split = false
            for _ in 0..<6 {
                let angle = axis + (random() - 0.5) * 0.85
                let n = TutuCathedralPoint(cos(angle), sin(angle)), span = sqrt(mass)
                let offset = (random() - 0.5) * span * 0.38
                let point = TutuCathedralPoint(c.x + n.x * offset, c.y + n.y * offset)
                let left = half(polygon, point, n, 1), right = half(polygon, point, n, -1)
                if left.points.count < 3 || right.points.count < 3 || min(area(left), area(right)) < mass * 0.20 {
                    continue
                }
                pending.append(TutuCathedralPending(polygon: left, generation: piece.generation + 1,
                                                    parent: piece.parent, child: piece.child))
                pending.append(TutuCathedralPending(polygon: right, generation: piece.generation + 1,
                                                    parent: piece.parent, child: piece.child))
                split = true
                break
            }
            if !split {
                if piece.child < 0 && piece.parent >= 0 {
                    polygon.childID = children.count
                    let child = TutuCathedralBody(polygon)
                    child.parentIndex = piece.parent
                    children.append(child)
                    parents[piece.parent].children.append(polygon.childID)
                }
                cells.append(polygon)
            }
        }
    }

    private func rasterCoverage(width: Int, height: Int) throws -> [UInt8] {
        if sourceCoverage == nil {
            var source = [UInt8](repeating: 0, count: Self.mapWidth * Self.mapHeight * 4)
            try source.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: Self.mapWidth, height: Self.mapHeight,
                                              bitsPerComponent: 8, bytesPerRow: Self.mapWidth * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw TutuCathedralGeometryError.bitmapContext
                }
                // Direct image decoding already returns Canvas's top-to-bottom row order.
                context.setBlendMode(.copy)
                context.draw(coverageImage, in: CGRect(x: 0, y: 0, width: Self.mapWidth, height: Self.mapHeight))
            }
            sourceCoverage = source
        }
        let source = sourceCoverage!
        if width == Self.mapWidth && height == Self.mapHeight { return source }
        var result = [UInt8](repeating: 0, count: width * height * 4)
        // Canvas2D's exact 2:1 drawImage truncates the four bilinear byte samples.
        // CoreGraphics rounds 127.x to 128, changing connectivity and every later RNG draw.
        for y in 0..<height {
            for x in 0..<width {
                let a = (y * 2 * Self.mapWidth + x * 2) * 4
                let b = a + Self.mapWidth * 4
                let destination = (y * width + x) * 4
                for channel in 0..<4 {
                    let sum = UInt16(source[a + channel]) + UInt16(source[a + 4 + channel])
                        + UInt16(source[b + channel]) + UInt16(source[b + 4 + channel])
                    result[destination + channel] = UInt8(sum / 4)
                }
            }
        }
        return result
    }

    private func push(_ at: Int, _ distance: Double) {
        let item = TutuCathedralHeapItem(at: at, distance: distance)
        var j = heap.count
        heap.append(item)
        while j > 0 {
            let parent = (j - 1) >> 1
            if heap[parent].distance <= distance { break }
            heap[j] = heap[parent]
            j = parent
        }
        heap[j] = item
    }

    private func pop() -> TutuCathedralHeapItem {
        let first = heap[0], last = heap.removeLast()
        if !heap.isEmpty {
            var j = 0
            while j * 2 + 1 < heap.count {
                var child = j * 2 + 1
                if child + 1 < heap.count && heap[child + 1].distance < heap[child].distance { child += 1 }
                if heap[child].distance >= last.distance { break }
                heap[j] = heap[child]
                j = child
            }
            heap[j] = last
        }
        return first
    }

    private func propagateArrival() {
        let w = Self.width, h = Self.height
        distances = [Float](repeating: .infinity, count: w * h)
        var origin = 0, closest = Double.infinity
        for y in 0..<h {
            for x in 0..<w {
                let at = y * w + x
                if pixels[at * 4 + 2] < 128 { continue }
                let d = Double((x - 138) * (x - 138) + (y - 130) * (y - 130))
                if d < closest { closest = d; origin = at }
            }
        }
        distances[origin] = 0
        push(origin, 0)
        while !heap.isEmpty {
            let current = pop(), at = current.at, travel = current.distance
            if travel > Double(distances[at]) + 0.001 { continue }
            farthest = max(farthest, travel)
            let x = at % w, y = at / w
            for dy in -1...1 {
                for dx in -1...1 {
                    if (dx == 0 && dy == 0) || x + dx < 0 || x + dx >= w || y + dy < 0 || y + dy >= h { continue }
                    let next = at + dy * w + dx
                    if pixels[next * 4 + 2] < 128 { continue }
                    if dx != 0 && dy != 0 && (pixels[(at + dx) * 4 + 2] < 128 || pixels[(at + dy * w) * 4 + 2] < 128) { continue }
                    let proposed = travel + (dx != 0 && dy != 0 ? sqrt(2) : 1)
                    if proposed + 0.001 < Double(distances[next]) {
                        distances[next] = Float(proposed)
                        push(next, proposed)
                    }
                }
            }
        }
    }

    private func arrival(_ polygon: TutuCathedralPolygon) -> Double {
        let w = Self.width, h = Self.height
        var left = w - 1, right = 0, top = h - 1, bottom = 0
        var nearest = Double.infinity, hasBody = false
        for q in polygon.points {
            left = min(left, Int(floor(q.x)))
            right = max(right, Int(ceil(q.x)))
            top = min(top, Int(floor(q.y)))
            bottom = max(bottom, Int(ceil(q.y)))
        }
        let y0 = max(0, top), y1 = min(h - 1, bottom)
        let x0 = max(0, left), x1 = min(w - 1, right)
        if y0 <= y1 && x0 <= x1 {
            for y in y0...y1 {
                for x in x0...x1 {
                    let at = y * w + x
                    if pixels[at * 4 + 2] >= 128 {
                        hasBody = true
                        nearest = min(nearest, Double(distances[at]))
                    }
                }
            }
        }
        if !hasBody { return -1 }
        return nearest.isFinite ? 0.012 + 0.92 * nearest / farthest : 0.95
    }

    private func curve(_ polygon: TutuCathedralPolygon) -> TutuCathedralPolygon {
        func warp(_ q: TutuCathedralPoint) -> TutuCathedralPoint {
            let edge = min(1, q.x / 10, (Double(Self.width) - q.x) / 10,
                           q.y / 10, (Double(Self.height) - q.y) / 10)
            return TutuCathedralPoint(
                q.x + edge * (1.25 * sin(q.y * 0.12 + q.x * 0.055) + 0.30 * sin(q.y * 0.29)),
                q.y + edge * (1.05 * sin(q.x * 0.13 - q.y * 0.045) + 0.25 * sin(q.x * 0.31)))
        }
        var curved: [TutuCathedralPoint] = []
        for j in polygon.points.indices {
            let a = polygon.points[j], b = polygon.points[(j + 1) % polygon.points.count]
            let steps = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / 4)))
            for k in 0..<steps {
                let t = Double(k) / Double(steps)
                curved.append(warp(TutuCathedralPoint(lerp(a.x, b.x, t), lerp(a.y, b.y, t))))
            }
        }
        return TutuCathedralPolygon(points: curved, parentID: polygon.parentID, childID: polygon.childID)
    }

    private func tri(_ a: TutuCathedralPoint3, _ b: TutuCathedralPoint3, _ c: TutuCathedralPoint3,
                     birth: Double, rough: Double, cavity: Double) {
        let ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z
        let vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z
        let nz = ux * vy - uy * vx
        if abs(nz) < 1e-7 { return }
        let nx = (uy * vz - uz * vy) / nz, ny = (uz * vx - ux * vz) / nz
        appendGlazeVertex(a, nx: nx, ny: ny, birth: birth, rough: rough, cavity: cavity)
        appendGlazeVertex(b, nx: nx, ny: ny, birth: birth, rough: rough, cavity: cavity)
        appendGlazeVertex(c, nx: nx, ny: ny, birth: birth, rough: rough, cavity: cavity)
    }

    private func appendGlazeVertex(_ q: TutuCathedralPoint3, nx: Double, ny: Double,
                                   birth: Double, rough: Double, cavity: Double) {
        data.append(q.x / Double(Self.width) * 2 - 1)
        data.append(1 - q.y / Double(Self.height) * 2)
        data.append(nx)
        data.append(ny)
        data.append(q.z)
        data.append(birth)
        data.append(rough)
        data.append(cavity)
    }

    private func buildGlaze() {
        for polygon in cells {
            let birth = arrival(polygon)
            if birth < 0 { continue }
            let c = centre(polygon)
            var radius = Double.infinity
            for j in polygon.points.indices {
                let a = polygon.points[j], b = polygon.points[(j + 1) % polygon.points.count]
                let dx = b.x - a.x, dy = b.y - a.y
                radius = min(radius, abs(dx * (c.y - a.y) - dy * (c.x - a.x)) / max(hypot(dx, dy), 1e-6))
            }
            let depth = 0.12 + random() * 0.15
            let bevel = min(0.50 + random() * 0.44, radius * 0.22)
            var lip: [TutuCathedralPoint3] = [], floor: [TutuCathedralPoint3] = [], top: [TutuCathedralPoint3] = []
            let size = sqrt(area(polygon))
            let sx = (random() - 0.5) * 0.10, sy = (random() - 0.5) * 0.10
            let rough = 0.16 + random() * 0.14
            for q in polygon.points {
                let inset = min(0.42, bevel / max(radius, 0.1))
                let r = TutuCathedralPoint(lerp(q.x, c.x, inset), lerp(q.y, c.y, inset))
                let f = min(0.10, 0.025 / max(radius, 0.1))
                floor.append(TutuCathedralPoint3(q.x, q.y, -depth))
                lip.append(TutuCathedralPoint3(lerp(q.x, c.x, f), lerp(q.y, c.y, f), -depth))
                let height = 0.08 + clamp((r.x - c.x) * sx + (r.y - c.y) * sy, -0.15, 0.15)
                top.append(TutuCathedralPoint3(r.x, r.y, height))
            }
            let crown = TutuCathedralPoint3(c.x, c.y, 0.10 + min(size * 0.002, 0.07))
            let frontStart = data.count
            for j in polygon.points.indices {
                let next = (j + 1) % polygon.points.count
                tri(crown, top[j], top[next], birth: birth, rough: rough, cavity: 0)
                tri(top[j], lip[j], lip[next], birth: birth, rough: 0.10, cavity: 0.35)
                tri(top[j], lip[next], top[next], birth: birth, rough: 0.10, cavity: 0.35)
                tri(lip[j], floor[j], floor[next], birth: birth, rough: 0.62, cavity: 1)
                tri(lip[j], floor[next], lip[next], birth: birth, rough: 0.62, cavity: 1)
            }
            if polygon.childID >= 0 { children[polygon.childID].fronts.append(frontStart..<data.count) }
        }
    }

    private func radiusOf(_ polygon: TutuCathedralPolygon, _ c: TutuCathedralPoint) -> Double {
        var radius = 0.0
        for q in polygon.points { radius = max(radius, hypot(q.x - c.x, q.y - c.y)) }
        return radius
    }

    private func inside(_ q: TutuCathedralPoint, _ polygon: TutuCathedralPolygon) -> Bool {
        var yes = false, j = polygon.points.count - 1
        for i in polygon.points.indices {
            let a = polygon.points[i], b = polygon.points[j]
            if (a.y > q.y) != (b.y > q.y) && q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x {
                yes.toggle()
            }
            j = i
        }
        return yes
    }

    private func contactTime(_ parent: TutuCathedralBody) -> Double {
        var support: [TutuCathedralPoint] = []
        let c = parent.centre, seed = parent.seed, spin = (seed * 17.37).truncatingRemainder(dividingBy: 1)
        for y in stride(from: 0, to: Self.height, by: 4) {
            for x in stride(from: 0, to: Self.width, by: 4) {
                if pixels[(y * Self.width + x) * 4 + 2] >= 128 && inside(TutuCathedralPoint(Double(x), Double(y)), parent.polygon) {
                    support.append(TutuCathedralPoint(Double(x) - c.x, Double(y) - c.y))
                }
            }
        }
        if support.isEmpty { return 2 }
        func bottom(_ t: Double) -> Double {
            let angles = TutuCathedralPoint3((0.35 + spin * 0.35) * t, (seed - 0.5) * 0.70 * t, (spin - 0.5) * 0.40 * t)
            let cy = c.y + (-8 - 10 * spin) * t + 130 * t * t
            var maxY = -Double.infinity
            let ax = sin(angles.z) * cos(angles.y)
            let ay = sin(angles.z) * sin(angles.y) * sin(angles.x) + cos(angles.z) * cos(angles.x)
            for q in support { maxY = max(maxY, cy + q.x * ax + q.y * ay) }
            return maxY
        }
        if bottom(0) >= 816 { return -0.45 }
        var lo = 0.0, hi = 0.04
        while hi < 5 && bottom(hi) < 816 { lo = hi; hi += 0.04 }
        for _ in 0..<14 {
            let mid = (lo + hi) * 0.5
            if bottom(mid) < 816 { lo = mid } else { hi = mid }
        }
        return hi
    }

    private func convexHull(_ polygon: TutuCathedralPolygon) -> [TutuCathedralPoint] {
        let points = polygon.points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: TutuCathedralPoint, _ b: TutuCathedralPoint, _ c: TutuCathedralPoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lo: [TutuCathedralPoint] = [], hi: [TutuCathedralPoint] = []
        for p in points {
            while lo.count > 1 && cross(lo[lo.count - 2], lo[lo.count - 1], p) <= 0 { lo.removeLast() }
            lo.append(p)
        }
        for p in points.reversed() {
            while hi.count > 1 && cross(hi[hi.count - 2], hi[hi.count - 1], p) <= 0 { hi.removeLast() }
            hi.append(p)
        }
        lo.removeLast()
        hi.removeLast()
        lo.append(contentsOf: hi)
        return lo
    }

    private func posePolygon(_ body: TutuCathedralBody) -> [TutuCathedralPoint] {
        let home = body.home!, c = cos(home.z), s = sin(home.z)
        return body.hull.map { q in
            let x = q.x - body.centre.x, y = q.y - body.centre.y
            return TutuCathedralPoint(home.x + c * x - s * y, home.y + s * x + c * y)
        }
    }

    private func separatingAxis(_ a: [TutuCathedralPoint], _ b: [TutuCathedralPoint]) -> (gap: Double, normal: TutuCathedralPoint) {
        var best = -Double.infinity, normal = TutuCathedralPoint(1, 0)
        for polygon in [a, b] {
            for i in polygon.indices {
                let p = polygon[i], q = polygon[(i + 1) % polygon.count]
                let dx = q.x - p.x, dy = q.y - p.y, length = hypot(dx, dy)
                if length < 1e-7 { continue }
                let nx = -dy / length, ny = dx / length
                var amin = Double.infinity, amax = -Double.infinity
                var bmin = Double.infinity, bmax = -Double.infinity
                for v in a { let d = v.x * nx + v.y * ny; amin = min(amin, d); amax = max(amax, d) }
                for v in b { let d = v.x * nx + v.y * ny; bmin = min(bmin, d); bmax = max(bmax, d) }
                let ab = bmin - amax, ba = amin - bmax, gap = max(ab, ba)
                if gap > best {
                    best = gap
                    normal = ab >= ba ? TutuCathedralPoint(nx, ny) : TutuCathedralPoint(-nx, -ny)
                }
            }
        }
        return (best, normal)
    }

    private func arrangeBodies(_ bodies: [TutuCathedralBody], owners: [UInt8], coverage: [UInt8], loss: [UInt8]) {
        var fitFactor = 1.0
        for _ in 0..<4 {
            for b in bodies {
                b.hull = convexHull(b.polygon)
                b.home = TutuCathedralPoint3(
                    b.centre.x + ((b.centre.x - 195) * 0.012 + (b.seed - 0.5) * 1.2) * fitFactor,
                    b.centre.y + ((b.centre.y - 413.5) * 0.012 + ((b.seed * 19.17).truncatingRemainder(dividingBy: 1) - 0.5) * 1.2) * fitFactor,
                    ((b.seed * 11.73).truncatingRemainder(dividingBy: 1) - 0.5) * 0.014 * fitFactor)
            }
            for _ in 0..<160 {
                var correction = 0.0
                for i in bodies.indices {
                    for j in (i + 1)..<bodies.count {
                        let a = bodies[i], b = bodies[j]
                        if hypot(a.home!.x - b.home!.x, a.home!.y - b.home!.y) > a.radius + b.radius + 6 { continue }
                        let axis = separatingAxis(posePolygon(a), posePolygon(b))
                        let wanted = (0.8 + 1.9 * (a.seed * 7.13 + b.seed * 13.71).truncatingRemainder(dividingBy: 1)) * fitFactor
                        let d = wanted - axis.gap
                        if d <= 0.0005 { continue }
                        correction = max(correction, d)
                        a.home!.x -= axis.normal.x * d * 0.501
                        a.home!.y -= axis.normal.y * d * 0.501
                        b.home!.x += axis.normal.x * d * 0.501
                        b.home!.y += axis.normal.y * d * 0.501
                    }
                }
                if correction < 0.002 { break }
            }
            var bounds = SIMD4<Double>(.infinity, .infinity, -.infinity, -.infinity)
            var lookup: [Int: (body: TutuCathedralBody, c: Double, s: Double)] = [:]
            for b in bodies { lookup[b.id + 1] = (b, cos(b.home!.z), sin(b.home!.z)) }
            for py in stride(from: 0, to: Self.mapHeight, by: 2) {
                for px in stride(from: 0, to: Self.mapWidth, by: 2) {
                    let at = py * Self.mapWidth + px
                    guard let entry = lookup[Int(owners[at])], coverage[at * 4 + 2] >= 128, loss[at * 4] >= 128 else { continue }
                    let b = entry.body
                    let x = (Double(px) + 0.5) / 2 - b.centre.x, y = (Double(py) + 0.5) / 2 - b.centre.y
                    let tx = b.home!.x + entry.c * x - entry.s * y
                    let ty = b.home!.y + entry.s * x + entry.c * y
                    bounds.x = min(bounds.x, tx); bounds.y = min(bounds.y, ty)
                    bounds.z = max(bounds.z, tx); bounds.w = max(bounds.w, ty)
                }
            }
            if bounds.z - bounds.x <= Double(Self.width) - 4 && bounds.w - bounds.y <= Double(Self.height) - 4 {
                let shiftX = clamp(0, 2 - bounds.x, Double(Self.width) - 2 - bounds.z)
                let shiftY = clamp(0, 2 - bounds.y, Double(Self.height) - 2 - bounds.w)
                for b in bodies { b.home!.x += shiftX; b.home!.y += shiftY }
                break
            }
            fitFactor *= 0.8
        }
    }

    private func rasterOwners(_ bodies: [TutuCathedralBody]) -> [UInt8] {
        let w = Self.mapWidth, h = Self.mapHeight
        var owners = [UInt8](repeating: 0, count: w * h)
        for child in bodies {
            let poly = child.polygon.points
            var lo = h - 1, hi = 0
            for q in poly { lo = min(lo, Int(floor(q.y * 2))); hi = max(hi, Int(ceil(q.y * 2))) }
            let y0 = max(0, lo), y1 = min(h - 1, hi)
            if y0 > y1 { continue }
            for y in y0...y1 {
                let sy = (Double(y) + 0.5) / 2
                var crossings: [Double] = []
                var j = poly.count - 1
                for i in poly.indices {
                    let a = poly[j], b = poly[i]
                    if (a.y > sy) != (b.y > sy) {
                        crossings.append(2 * (a.x + (sy - a.y) * (b.x - a.x) / (b.y - a.y)))
                    }
                    j = i
                }
                crossings.sort()
                for k in stride(from: 0, to: crossings.count - 1, by: 2) {
                    let x0 = max(0, Int(ceil(crossings[k] - 0.5)))
                    let x1 = min(w - 1, Int(floor(crossings[k + 1] - 0.5)))
                    if x0 <= x1 { for x in x0...x1 { owners[y * w + x] = UInt8(truncatingIfNeeded: child.id + 1) } }
                }
            }
        }
        return owners
    }

    private func makeLoss(owners: [UInt8], coverage: [UInt8]) -> [UInt8] {
        let w = Self.mapWidth, h = Self.mapHeight, count = owners.count
        var seen = [UInt8](repeating: 0, count: count)
        var queue = [Int](repeating: 0, count: count)
        var loss = [UInt8](repeating: 255, count: count * 4)
        // Four-connected porcelain components inside each newly cut child body.
        for i in 0..<count {
            if seen[i] != 0 || owners[i] == 0 || coverage[i * 4 + 2] < 128 { continue }
            let owner = owners[i]
            var head = 0, tail = 1
            queue[0] = i; seen[i] = 1
            var minX = w, maxX = 0, minY = h, maxY = 0, touchesCut = false
            while head < tail {
                let at = queue[head], x = at % w, y = at / w
                head += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for direction in 0..<4 {
                    let n: Int
                    switch direction {
                    case 0: n = x > 0 ? at - 1 : -1
                    case 1: n = x < w - 1 ? at + 1 : -1
                    case 2: n = y > 0 ? at - w : -1
                    default: n = y < h - 1 ? at + w : -1
                    }
                    if n < 0 { continue }
                    if owners[n] != owner { touchesCut = true; continue }
                    if coverage[n * 4 + 2] < 128 { continue }
                    if seen[n] == 0 { seen[n] = 1; queue[tail] = n; tail += 1 }
                }
            }
            let area = Double(tail) / 4
            let width = Double(maxX + 1 - minX) / 2, height = Double(maxY + 1 - minY) / 2
            if touchesCut && area < 38 && max(width, height) < 22 {
                for k in 0..<tail { loss[queue[k] * 4] = 0 }
            }
        }
        // Opening by the radius-three disk exposes fragile neck projections. Only
        // bounded candidate components that touch a new cut are actually removed.
        var kernel: [SIMD2<Int>] = []
        var core = [UInt8](repeating: 0, count: count)
        var candidate = [UInt8](repeating: 0, count: count)
        for dy in -3...3 { for dx in -3...3 { if dx * dx + dy * dy <= 9 { kernel.append(SIMD2(dx, dy)) } } }
        for y in 3..<(h - 3) {
            for x in 3..<(w - 3) {
                let at = y * w + x, id = owners[at]
                if id == 0 || coverage[at * 4 + 2] < 128 { continue }
                var solid = true
                for k in kernel {
                    let n = at + k.y * w + k.x
                    if owners[n] != id || coverage[n * 4 + 2] < 128 { solid = false; break }
                }
                if solid { core[at] = 1 }
            }
        }
        for y in 3..<(h - 3) {
            for x in 3..<(w - 3) {
                let at = y * w + x, id = owners[at]
                if id == 0 || coverage[at * 4 + 2] < 128 || loss[at * 4] == 0 { continue }
                var retained = false
                for k in kernel {
                    let n = at + k.y * w + k.x
                    if core[n] != 0 && owners[n] == id { retained = true; break }
                }
                if !retained { candidate[at] = 1 }
            }
        }
        for i in 0..<count {
            if candidate[i] != 1 { continue }
            let id = owners[i]
            var head = 0, tail = 1
            queue[0] = i; candidate[i] = 2
            var minX = w, maxX = 0, minY = h, maxY = 0, touch = false
            while head < tail {
                let at = queue[head], x = at % w, y = at / w
                head += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                // Intentionally the same linear-index neighbours as the JS neck pass.
                for direction in 0..<4 {
                    let n: Int
                    switch direction {
                    case 0: n = at - 1
                    case 1: n = at + 1
                    case 2: n = at - w
                    default: n = at + w
                    }
                    if n < 0 || n >= count { continue }
                    if owners[n] != id { touch = true }
                    if candidate[n] == 1 && owners[n] == id { candidate[n] = 2; queue[tail] = n; tail += 1 }
                }
            }
            let area = Double(tail) / 4, length = Double(max(maxX - minX + 1, maxY - minY + 1)) / 2
            if touch && area >= 2 && area <= 38 && length >= 3 && length < 18 {
                for k in 0..<tail { loss[queue[k] * 4] = 0 }
            }
        }
        return loss
    }

    private func solidTri(_ a: TutuCathedralPoint3, _ b: TutuCathedralPoint3, _ c: TutuCathedralPoint3,
                          body: TutuCathedralBody, normal: TutuCathedralPoint3, rough: Double,
                          slope: TutuCathedralPoint = .zero, cavity: Double = 0) {
        appendSolidVertex(a, body: body, normal: normal, rough: rough, slope: slope, cavity: cavity)
        appendSolidVertex(b, body: body, normal: normal, rough: rough, slope: slope, cavity: cavity)
        appendSolidVertex(c, body: body, normal: normal, rough: rough, slope: slope, cavity: cavity)
    }

    private func appendSolidVertex(_ q: TutuCathedralPoint3, body: TutuCathedralBody,
                                   normal: TutuCathedralPoint3, rough: Double,
                                   slope: TutuCathedralPoint, cavity: Double) {
        let home = body.home!, parent = body.role == 0 ? body : parents[body.parentIndex]
        shardData.append(Float(q.x / Double(Self.width) * 2 - 1))
        shardData.append(Float(1 - q.y / Double(Self.height) * 2))
        shardData.append(Float(slope.x))
        shardData.append(Float(slope.y))
        shardData.append(Float(q.z))
        shardData.append(0)
        shardData.append(Float(rough))
        shardData.append(Float(cavity))
        shardData.append(Float(body.centre.x))
        shardData.append(Float(body.centre.y))
        shardData.append(-1)
        shardData.append(Float(body.seed))
        shardData.append(Float(normal.x))
        shardData.append(Float(normal.y))
        shardData.append(Float(normal.z))
        shardData.append(Float(parent.centre.x))
        shardData.append(Float(parent.centre.y))
        shardData.append(Float(parent.seed))
        shardData.append(Float(parent.impact))
        shardData.append(Float(body.role))
        shardData.append(Float(body.radius))
        shardData.append(Float(home.x))
        shardData.append(Float(home.y))
        shardData.append(Float(home.z))
    }

    private func buildSolid(_ body: TutuCathedralBody, fronts: [Range<Int>]) {
        if body.home == nil { body.home = TutuCathedralPoint3(body.centre.x, body.centre.y, 0) }
        for range in fronts {
            for i in stride(from: range.lowerBound, to: range.upperBound, by: 24) {
                let a = TutuCathedralPoint3((data[i] + 1) * Double(Self.width) / 2,
                                            (1 - data[i + 1]) * Double(Self.height) / 2, data[i + 4])
                let b = TutuCathedralPoint3((data[i + 8] + 1) * Double(Self.width) / 2,
                                            (1 - data[i + 9]) * Double(Self.height) / 2, data[i + 12])
                let c = TutuCathedralPoint3((data[i + 16] + 1) * Double(Self.width) / 2,
                                            (1 - data[i + 17]) * Double(Self.height) / 2, data[i + 20])
                solidTri(a, b, c, body: body, normal: .zero, rough: data[i + 6],
                         slope: TutuCathedralPoint(data[i + 2], data[i + 3]), cavity: data[i + 7])
            }
        }
        let poly = body.polygon.points, thickness = 3.2
        let back = TutuCathedralPoint3(body.centre.x, body.centre.y, -thickness)
        for j in poly.indices {
            let a = poly[j], b = poly[(j + 1) % poly.count]
            let ab = TutuCathedralPoint3(a.x, a.y, -thickness), bb = TutuCathedralPoint3(b.x, b.y, -thickness)
            let af = TutuCathedralPoint3(a.x, a.y, 0), bf = TutuCathedralPoint3(b.x, b.y, 0)
            let edgeLength = hypot(b.x - a.x, b.y - a.y), edge = edgeLength == 0 ? 1 : edgeLength
            let normal = TutuCathedralPoint3((b.y - a.y) / edge, -(b.x - a.x) / edge, 0)
            if body.role > 0 { solidTri(back, bb, ab, body: body, normal: TutuCathedralPoint3(0, 0, -1), rough: 0.72) }
            solidTri(af, ab, bb, body: body, normal: normal, rough: 0.68)
            solidTri(af, bb, bf, body: body, normal: normal, rough: 0.68)
        }
    }

    func make() throws -> TutuCathedralMesh {
        splitCells()
        pixels = try rasterCoverage(width: Self.width, height: Self.height)
        propagateArrival()
        cells = cells.map(curve)
        for parent in parents { parent.polygon = curve(parent.polygon) }
        for child in children { child.polygon = curve(child.polygon) }
        data.reserveCapacity(cells.reduce(0) { $0 + $1.points.count * 120 })
        buildGlaze()
        // Preserve stable JS sort order for equal arrival times.
        let ordered = parents.enumerated().compactMap { index, parent -> (Int, TutuCathedralBody, Double)? in
            let birth = arrival(parent.polygon)
            return birth >= 0 ? (index, parent, birth) : nil
        }.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }
        var activeChildren: [TutuCathedralBody] = []
        for (parentIndex, parent, _) in ordered {
            parent.centre = centre(parent.polygon)
            parent.seed = random()
            parent.radius = radiusOf(parent.polygon, parent.centre)
            parent.impact = contactTime(parent)
            parent.parentIndex = parentIndex
            parent.role = 0
            for id in parent.children {
                let child = children[id]
                if child.fronts.isEmpty { continue }
                child.centre = centre(child.polygon)
                child.radius = radiusOf(child.polygon, child.centre)
                child.seed = random()
                child.parentIndex = parentIndex
                child.role = 1
                child.id = id
                activeChildren.append(child)
            }
        }
        let owners = rasterOwners(activeChildren)
        let coverage = try rasterCoverage(width: Self.mapWidth, height: Self.mapHeight)
        let loss = makeLoss(owners: owners, coverage: coverage)
        arrangeBodies(activeChildren, owners: owners, coverage: coverage, loss: loss)
        let wallVertices = parents.reduce(0) { $0 + $1.polygon.points.count * 6 }
            + activeChildren.reduce(0) { $0 + $1.polygon.points.count * 9 }
        shardData.reserveCapacity((data.count / 8 + wallVertices) * 24)
        var breakPixels = [UInt8](repeating: 0, count: Self.mapWidth * Self.mapHeight * 4)
        var pieces: [TutuCathedralPiece] = []
        try breakPixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: Self.mapWidth, height: Self.mapHeight,
                                          bitsPerComponent: 8, bytesPerRow: Self.mapWidth * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw TutuCathedralGeometryError.bitmapContext
            }
            context.translateBy(x: 0, y: CGFloat(Self.mapHeight))
            context.scaleBy(x: 2, y: -2)
            context.setShouldAntialias(true)
            for (index, entry) in ordered.enumerated() {
                let parent = entry.1
                let release = ((0.045 + Double(index) / Double(max(1, ordered.count - 1)) * 0.91) * 65535).rounded() / 65535
                let code = Int((release * 65535).rounded()), first = shardData.count / 24
                context.setFillColor(red: CGFloat(code >> 8) / 255, green: CGFloat(code & 255) / 255, blue: 1, alpha: 1)
                context.beginPath()
                for (i, q) in parent.polygon.points.enumerated() {
                    if i == 0 { context.move(to: CGPoint(x: q.x, y: q.y)) }
                    else { context.addLine(to: CGPoint(x: q.x, y: q.y)) }
                }
                context.closePath()
                context.fillPath()
                buildSolid(parent, fronts: [])
                for id in parent.children {
                    let child = children[id]
                    if !child.fronts.isEmpty { buildSolid(child, fronts: child.fronts) }
                }
                pieces.append(TutuCathedralPiece(first: first, count: shardData.count / 24 - first, release: release))
            }
        }
        // Canvas getImageData returns straight RGBA, unlike the bitmap context.
        for i in stride(from: 0, to: breakPixels.count, by: 4) {
            let alpha = Int(breakPixels[i + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 {
                    breakPixels[i + channel] = UInt8(min(255, (Int(breakPixels[i + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        // Sort only the finished GPU stream: shard fronts above still address the
        // canonical unsorted Double data, and no RNG draw or vertex value changes.
        // Compare Float32 births exactly as face.w does, with original triangle
        // order as the explicit tie-breaker even when Double births round equal.
        let triangles = (0..<(data.count / 24)).sorted {
            let a = Float(data[$0 * 24 + 5]), b = Float(data[$1 * 24 + 5])
            return a == b ? $0 < $1 : a < b
        }
        var glaze: [Float] = []
        glaze.reserveCapacity(data.count)
        for triangle in triangles {
            let start = triangle * 24
            for i in start..<(start + 24) { glaze.append(Float(data[i])) }
        }
        return TutuCathedralMesh(glaze: glaze, shards: shardData,
                                  pieces: pieces, breakPixels: breakPixels, lossPixels: loss)
    }
}
#endif
#endif
