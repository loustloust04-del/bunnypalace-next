#if PERSONAL_APPS
#if os(iOS)
import Foundation

/// Direct Double-precision port of petals.js 2.0. No UI, clock, or texture ownership.
/// `step` is the source's manual-step API, not its requestAnimationFrame accumulator.
/// Source behavior intentionally retained: a horizontally crossed raised floor can be missed
/// when previous y is already below it; max starts retirement rather than capping list length.
/// `reset` recreates the source's create(seed) state (source clear() does not rewind its RNG).
/// Unlock uses hi textures with manifest hi_len=300; page textures use page_len=128.
/// Texture dimensions must be decoded from the image, not assumed to equal the blade length.
final class TutuPetals {
    struct Options {
        var size = SIMD2<Double>(12, 19)
        var fall = 1.0, vt = 150.0
        var swing = SIMD2<Double>(55, 95), swingRate = SIMD2<Double>(1.5, 2.3)
        var sway = 1.0, tumble = 0.3, drag = 0.3, turb = 1.0, wind = 0.0, gustDecay = 1.6
        var gravity = SIMD2<Double>(0, 1)
        var pile = true, pileStep = 0.07, pileMax = 0.5
        var restFlat = SIMD2<Double>(0.12, 0.26)
        var restLife = 20.0, restVar = 0.3, fadeTime = 2.5
        var crowd = SIMD3<Double>(40, 5, 14)
        var liftGust = 70.0, hang = 0.2, fadeIn = 0.25
        var max = 160, spriteCount = 14, lieCount = 4
        var reduced = false, stopMotion = false
        var fps = 12.0, jitter = 0.5, lightDepth = 120.0
        var facing = SIMD2<Double>(0.86, 0.14)
        var ambient = SIMD3<Double>(0.97, 0.97, 0.96)
        var dark = SIMD3<Double>(0.8, 0.79, 0.77), warm = SIMD3<Double>(1, 0.97, 0.93)
        // Default source bounds for a 420 × 912, scale=1 world. Hosts may update these.
        var bounds = SIMD4<Double>(-60, -200, 480, 972)
    }

    struct Emission {
        var vx = 0.0, vy = 0.0, sv = 12.0
        var size: SIMD2<Double>?, tumble: Double?, hang: Double?
        var from: SIMD2<Double>?
        var width = 0.0, height = 0.0, radius = 0.0
    }

    struct Landing {
        var t: Double = 0
        var r0: Double, f0: Double, y0: Double, r1: Double, f1: Double, yaw1: Double
    }

    // Reference objects are intentional: a step never copies the particle array, and landing's
    // crowd pass mutates the same objects as the original JS list.
    final class Petal {
        var id = 0
        var x = 0.0, y = 0.0, px = 0.0, py = 0.0
        var wx = 0.0, wy = 0.0, vx = 0.0, vy = 0.0, uy = 0.0
        var size = 0.0, spr = 0, lie = 0, flip = 1
        var tumbling = false
        var vt = 0.0, ph = 0.0, w = 0.0, A = 0.0, rot0 = 0.0, rock = 0.0
        var th = 0.0, spin = 0.0, th0 = 0.0, yaw = 0.0, yawV = 0.0
        var n = SIMD4<Double>.zero, n4 = 0.0
        var rot = 0.0, flat = 1.0, edge = false, state = 0, sw = 0.0
        var t = 0.0, hang = 0.0, rest = 0.0, a = 1.0, life = 0.0, fade = 0.0
        var land: Landing?, pile: String?, on: String?
    }

    struct DrawSprite {
        var id: Int
        var x: Double, y: Double, alpha: Double, size: Double
        var side: Int, spriteIndex: Int, isLying: Bool
        /// Canvas ordering a,b,c,d. Multiply by size / manifest blade length at draw time.
        var affine: SIMD4<Double>
        var tint: SIMD3<Double>
    }

    /// Paths come from the shipped manifest, never from a second filename table.
    struct SpriteManifest: Decodable {
        struct Entry: Decodable { var front: String; var back: String }
        var hi_len: Double, page_len: Double
        var petals: [Entry], lie: [Entry]
        static let resourcePath = "TutuSkin/petals/sprites.json"
        func resourcePath(index: Int, side: Int, lying: Bool, highResolution: Bool = true) -> String {
            let entry = lying ? lie[index] : petals[index]
            return "TutuSkin/petals/\(highResolution ? "hi" : "page")/\(side == 0 ? entry.front : entry.back)"
        }
    }

    var options: Options
    var floor: (Double) -> Double?
    var light: SIMD3<Double>?
    var tint: ((Double, Double, SIMD3<Double>, Petal) -> SIMD3<Double>)?
    private(set) var petals: [Petal] = []
    private(set) var time = 0.0, gustX = 0.0, gustY = 0.0
    private(set) var randomState: UInt32
    private var nextID = 0
    private var piles: [String: Double] = [:]
    private static let tau = Double.pi * 2

    init(seed: UInt32 = 1, floor: @escaping (Double) -> Double?, options: Options = Options()) {
        self.floor = floor; self.options = options; randomState = seed == 0 ? 1 : seed
        petals.reserveCapacity(options.max)
    }

    func reset(seed: UInt32 = 1) {
        petals.removeAll(keepingCapacity: true); piles.removeAll(keepingCapacity: true)
        randomState = seed == 0 ? 1 : seed; nextID = 0; time = 0; gustX = 0; gustY = 0
    }

    private func random() -> Double {
        randomState &+= 0x6d2b79f5
        var t = (randomState ^ (randomState >> 15)) &* (1 | randomState)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296
    }
    private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }
    private func jsRound(_ x: Double) -> Double { Foundation.floor(x + 0.5) }

    func emit(x: Double, y: Double, count: Int = 1, emission e: Emission = Emission()) {
        var k = count
        if options.reduced {
            k = count <= 1 ? (random() < 0.35 ? 1 : 0) : max(random() < 0.5 ? 1 : 0, Int(jsRound(Double(count) * 0.2)))
        }
        guard k > 0 else { return }
        for _ in 0..<k {
            var px = x, py = y
            if e.width != 0 || e.height != 0 {
                px += e.width * (random() - 0.5); py += e.height * (random() - 0.5)
            } else if e.radius != 0 {
                let a = random() * Self.tau, r = e.radius * sqrt(random())
                px += cos(a) * r; py += sin(a) * r
            }
            make(px, py, e)
        }
    }

    private func make(_ x: Double, _ y: Double, _ e: Emission) {
        let o = options, sz = e.size ?? o.size, p = Petal()
        p.tumbling = !o.reduced && random() < (e.tumble ?? o.tumble)
        nextID += 1; p.id = nextID; p.x = x; p.px = x; p.y = y; p.py = y
        p.wx = e.vx + (random() - 0.5) * 2 * e.sv
        p.wy = e.vy + (random() - 0.5) * 2 * e.sv * 0.6
        p.size = sz.x + (sz.y - sz.x) * random()
        p.spr = Int(Foundation.floor(random() * Double(o.spriteCount)))
        p.lie = Int(Foundation.floor(random() * 4)) // Retained overwritten draw from JS: affects the RNG stream.
        p.flip = random() < 0.5 ? 1 : -1
        p.vt = o.vt * (0.85 + 0.3 * random())
        p.ph = random() * Self.tau; p.w = o.swingRate.x + (o.swingRate.y - o.swingRate.x) * random()
        p.A = (o.swing.x + (o.swing.y - o.swing.x) * random()) * (o.reduced ? 0.6 : 1)
        p.rot0 = (random() - 0.5) * 0.6; p.rock = 0.7 + 0.5 * random()
        p.spin = (random() < 0.5 ? -1 : 1) * (1.9 + 1.9 * random())
        p.th0 = (random() < 0.5 ? 0.62 : Double.pi - 0.62) + (random() - 0.5) * 0.3
        p.yaw = random() * Self.tau; p.yawV = (random() - 0.5) * 4
        p.n = SIMD4(random() * Self.tau, random() * Self.tau, random() * Self.tau, 0.6 + random() * 0.7)
        p.n4 = 1.3 + random() * 1.1
        p.sw = 4 + 9 * random(); p.hang = e.hang ?? o.hang
        p.life = o.restLife * (1 + (random() - 0.5) * 2 * o.restVar)
        p.lie = o.lieCount > 0 ? Int(Foundation.floor(random() * Double(o.lieCount))) : 0
        p.th = p.tumbling ? random() * Self.tau : p.th0; p.flat = cos(p.th)
        if let from = e.from {
            let dx = from.x - x, dy = from.y - y
            p.yaw = 0; p.yawV *= 0.5
            p.rot = p.flat >= 0 ? atan2(-dx, dy) : atan2(dx, -dy); p.rot0 = p.rot * 0.3
        } else { pose(p, 0) }
        if petals.count >= o.max { retire() }
        petals.append(p)
    }

    private func retire() {
        var best: Petal?
        for p in petals where p.state == 2 { if best == nil || p.rest > best!.rest { best = p } }
        if let p = best ?? petals.first(where: { $0.state != 3 }) { p.state = 3; p.fade = 0 }
    }

    private func pose(_ p: Petal, _ dt: Double) {
        let o = options
        p.yaw += p.yawV * (0.6 + 0.4 * sin(time * 0.3 + p.n.z)) * dt
        if dt > 0 && !o.reduced && o.tumble > 0 {
            p.sw -= dt
            if p.sw <= 0 {
                p.tumbling.toggle()
                p.sw = p.tumbling ? 1.2 + 2.5 * random() : 5 + 10 * random() * (1.2 - o.tumble)
                if !p.tumbling {
                    let base = cos(p.th) >= 0 ? 0.62 : Double.pi - 0.62
                    p.th0 = base + Self.tau * jsRound((p.th - base) / Self.tau)
                }
            }
        }
        if p.tumbling {
            p.th += p.spin * dt
            p.rot += ((p.rot0 + 0.25 * sin(p.ph * 0.7)) - p.rot) * min(1, dt * 3)
        } else {
            let c = cos(p.ph), s = sin(p.ph), up = cos(p.th0) >= 0 ? 1.0 : -1.0, ac = abs(c)
            p.rot += ((p.rot0 + p.rock * c * 0.85 * o.sway) - p.rot) * min(1, dt * 7)
            let want = p.th0 + up * (0.85 * ac - 0.62 * (1 - ac) + 0.2 * s)
            p.th += (want - p.th) * min(1, dt * 8)
        }
        p.flat = cos(p.th)
    }

    private func swingVel(_ p: Petal, _ dt: Double) -> SIMD2<Double> {
        var ux: Double, uy: Double
        if p.tumbling {
            let broad = 1 - abs(cos(p.th))
            ux = 0.22 * p.vt * (p.spin < 0 ? -1 : p.spin > 0 ? 1 : 0) * (0.6 + 0.4 * broad) + 8 * sin(p.ph)
            uy = p.vt * (0.5 + 0.2 * (1 - broad)); p.ph += 1.1 * dt
        } else {
            let c = cos(p.ph), sn = sin(p.ph)
            p.ph += p.w * (1 + 0.14 * sin(time * 0.53 + p.n.y)) * dt
            ux = p.A * (0.7 + 0.3 * sin(time * 0.41 + p.n.x)) * c * options.sway
            let want = p.vt * (0.58 - 0.75 * sn * (c < 0 ? -1 : 1))
            p.uy += (want - p.uy) * min(1, dt / 0.12); uy = p.uy
        }
        return SIMD2(ux, uy * options.fall)
    }

    private func surfaceBelow(_ p: Petal) -> (Double, String)? {
        guard let fy = floor(p.x) else { return nil }
        let key = "f\(Int(Foundation.floor(p.x / 7)))"
        let y = fy - p.size * 0.08 - (options.pile ? piles[key, default: 0] : 0)
        return y.isFinite && p.py <= y + 0.5 && p.y >= y ? (y, key) : nil
    }

    private func land(_ p: Petal, _ hit: (Double, String)) {
        let o = options
        p.y = hit.0; p.state = 1; p.rest = 0; p.vx = 0; p.vy = 0; p.wx = 0; p.wy = 0
        let side = p.flat >= 0 ? 1.0 : -1.0
        let f1 = o.lieCount > 0 ? side * (0.06 + 0.06 * random()) : side * (o.restFlat.x + (o.restFlat.y - o.restFlat.x) * random())
        var yaw1 = p.yaw
        let sy = sin(yaw1)
        if abs(sy) < 0.75 { yaw1 = (sy >= 0 ? 1 : -1) * (Double.pi / 2 - 0.7 * random() * (random() < 0.5 ? 1 : -1)) }
        p.land = Landing(r0: p.rot, f0: p.flat, y0: p.yaw, r1: (random() - 0.5) * 0.12, f1: f1, yaw1: yaw1)
        p.on = hit.1
        if o.pile { p.pile = hit.1; piles[hit.1] = min(p.size * o.pileMax, piles[hit.1, default: 0] + p.size * o.pileStep) }
        var n = 0
        for q in petals where q !== p && q.state >= 1 && q.state <= 2 && abs(q.x - p.x) < o.crowd.x && abs(q.y - p.y) < o.crowd.x { n += 1 }
        if Double(n + 1) >= o.crowd.y {
            p.life = min(p.life, o.crowd.z)
            for q in petals where q.state == 2 && abs(q.x - p.x) < o.crowd.x && abs(q.y - p.y) < o.crowd.x { q.life = min(q.life, max(q.rest + 2, o.crowd.z)) }
        }
    }

    func step(_ dt: Double) {
        guard dt > 0 else { return }
        let n = min(240, Int(ceil(dt * 60 - 1e-6)))
        guard n > 0 else { return } // JS also executes zero iterations for sub-epsilon dt.
        for _ in 0..<n { step1(dt / Double(n)) }
    }

    private func step1(_ dt: Double) {
        time += dt
        let o = options, gd = exp(-dt / o.gustDecay)
        gustX *= gd; gustY *= gd
        let gl0 = hypot(o.gravity.x, o.gravity.y), gl = gl0 == 0 ? 1 : gl0
        let ga = atan2(o.gravity.x / gl, o.gravity.y / gl), cg = cos(ga), sgn = sin(ga)
        let kd = 1 - exp(-dt / o.drag)
        for i in petals.indices.reversed() {
            let p = petals[i]; p.t += dt
            if p.state == 0 {
                if p.hang > 0 { p.hang -= dt; continue }
                let u = swingVel(p, dt), ax = u.x * cg + u.y * sgn, ay = -u.x * sgn + u.y * cg
                let tt = time * p.n.w, tu = time * p.n4
                let nx = (9 * sin(tt + p.n.x) + 5 * sin(tu * 1.7 + p.n.y)) * o.turb
                let ny = 5 * sin(tu + p.n.z) * o.turb
                p.wx += (o.wind + gustX + nx - p.wx) * kd; p.wy += (gustY + ny - p.wy) * kd
                p.vx = p.wx + ax; p.vy = p.wy + ay; p.px = p.x; p.py = p.y
                p.x += p.vx * dt; p.y += p.vy * dt; pose(p, dt)
                if let hit = surfaceBelow(p) { land(p, hit) }
                else if p.y > o.bounds.w + 80 || p.x < o.bounds.x - 260 || p.x > o.bounds.z + 260 { petals.remove(at: i); continue }
            } else {
                if p.state == 1, var L = p.land {
                    L.t += dt; p.land = L
                    let u = clamp(L.t / 0.42, 0, 1), e = 1 - (1 - u) * (1 - u) * (1 - u)
                    p.rot = L.r0 + (L.r1 - L.r0) * e; p.flat = L.f0 + (L.f1 - L.f0) * e; p.yaw = L.y0 + (L.yaw1 - L.y0) * e
                    if u >= 1 { p.state = 2 }
                }
                p.rest += dt
                if p.state == 2 && p.rest > p.life { p.state = 3; p.fade = 0 }
                if p.state == 3 {
                    p.fade += dt; p.a = clamp(1 - p.fade / o.fadeTime, 0, 1)
                    if p.a <= 0 { unpile(p); petals.remove(at: i); continue }
                }
                if p.state == 2 && abs(gustX) > o.liftGust && random() < dt * 2.2 * (abs(gustX) / o.liftGust - 0.6) {
                    unpile(p); airborne(p)
                    p.wx = gustX * (0.4 + 0.4 * random()); p.wy = -(18 + 30 * random()); p.py = p.y - 1; p.y -= 1
                }
            }
        }
    }

    private func unpile(_ p: Petal) {
        if let key = p.pile, options.pile {
            let h = piles[key, default: 0] - p.size * options.pileStep
            if h > 0.01 { piles[key] = h } else { piles.removeValue(forKey: key) }
        }
        p.pile = nil
    }
    private func airborne(_ p: Petal) {
        p.state = 0; p.on = nil; p.hang = 0
        p.th0 = p.flat >= 0 ? 0.62 : Double.pi - 0.62; p.th = p.th0; p.flat = cos(p.th)
        p.tumbling = false; p.ph = random() * Self.tau
    }
    func gust(_ vx: Double, _ vy: Double = 0) { gustX += vx; gustY += vy }
    func release(where predicate: ((Petal) -> Bool)? = nil) {
        for p in petals where (p.state == 1 || p.state == 2) && (predicate?(p) ?? true) {
            unpile(p); airborne(p); p.wx = 0; p.wy = 0; p.py = p.y
        }
    }

    private func normal(_ p: Petal) -> SIMD3<Double> {
        let f = clamp(abs(p.flat), 0, 1), s = sqrt(1 - f * f)
        return SIMD3(sin(p.rot) * s, -cos(p.rot) * s, f)
    }
    private func tintOf(_ p: Petal) -> SIMD3<Double> {
        let o = options
        if let tint {
            let m = tint(p.x, p.y, normal(p), p)
            return SIMD3(jsRound(clamp(m.x, 0, 1) * 24) / 24, jsRound(clamp(m.y, 0, 1) * 24) / 24, jsRound(clamp(m.z, 0, 1) * 24) / 24)
        }
        guard let L = light else { return o.ambient }
        let dx = L.x - p.x, dy = L.y - p.y, d = hypot(dx, dy), reach = clamp(1.25 - d / 760, 0.22, 1)
        let n = normal(p), dz = o.lightDepth, dl0 = sqrt(dx * dx + dy * dy + dz * dz), dl = dl0 == 0 ? 1 : dl0
        let lam = max(0, (n.x * dx + n.y * dy + n.z * dz) / dl)
        let t = jsRound(clamp(reach * clamp(L.z, 0.6, 1.1), 0, 1) * 9) / 9
        let k = jsRound((o.facing.x + o.facing.y * lam) * 20) / 20
        return (o.dark + (o.warm - o.dark) * t) * k
    }

    func drawSprites() -> [DrawSprite] {
        var out: [DrawSprite] = []; drawSprites(into: &out); return out
    }
    /// Renderer-owned reusable storage avoids per-frame arrays. Like JS draw(), this updates edge hysteresis.
    func drawSprites(into out: inout [DrawSprite], frameIndex: Int? = nil) {
        out.removeAll(keepingCapacity: true); out.reserveCapacity(petals.count)
        let o = options, F = o.reduced ? -1 : (frameIndex ?? (o.stopMotion ? Int(Foundation.floor(time * o.fps)) : -1))
        for p in petals {
            if p.state == 0 && p.hang > 0 && F < 0 && p.t < 0.001 { continue }
            let sg = p.flat < 0 ? -1.0 : 1.0, af = abs(p.flat)
            if o.lieCount > 0 {
                if p.edge && af > 0.23 { p.edge = false }
                else if !p.edge && af < 0.17 { p.edge = true }
            }
            let lying = o.lieCount > 0 && p.edge, f = sg * max(af, 0.16)
            var rot = p.rot, x = p.x, y = p.y
            if F >= 0 && o.jitter != 0 {
                let ph = Double(F % 3)
                func hash(_ n: Double) -> Double { let v = sin(n * 12.9898 + 78.233) * 43758.5453; return v - Foundation.floor(v) }
                x += (hash(Double(p.id) * 31.7 + ph * 7.3) - 0.5) * o.jitter
                y += (hash(Double(p.id) * 17.1 + ph * 3.9 + 2) - 0.5) * o.jitter
                rot += (hash(Double(p.id) * 11.3 + ph * 5.1 + 4) - 0.5) * 0.05
            }
            let cr = cos(rot), sr = sin(rot), cy = cos(p.yaw), sy = sin(p.yaw), flip = Double(p.flip)
            let b11 = cy * flip, b12 = -sy, b21 = f * sy * flip, b22 = f * cy
            let M = SIMD4(cr * b11 - sr * b21, sr * b11 + cr * b21, cr * b12 - sr * b22, sr * b12 + cr * b22)
            var sx = -sy * flip
            if abs(sx) < 0.4 { sx = sx < 0 ? -0.4 : 0.4 }
            let C = SIMD4(cr * sx, sr * sx, -sr, cr)
            let u = clamp(p.t / o.fadeIn, 0, 1), grow = F < 0 && p.state == 0 ? u * u * (3 - 2 * u) : 1
            out.append(DrawSprite(id: p.id, x: x, y: y, alpha: p.a * grow, size: p.size * (0.85 + 0.15 * grow), side: sg > 0 ? 0 : 1, spriteIndex: lying ? p.lie : p.spr, isLying: lying, affine: lying ? C : M, tint: tintOf(p)))
        }
    }
}
#endif
#endif
