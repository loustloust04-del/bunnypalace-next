#if PERSONAL_APPS
#if os(iOS)
import Foundation
import simd

struct TutuUnlockRope {
    var u, S0, S1, K: SIMD2<Double>
    var A: SIMD2<Double> { TutuUnlockModel.anchor }
}
struct TutuUnlockBunny {
    var origin: SIMD3<Double>
    var R: simd_double3x3
    var mask: Double = 0
    var rig = TutuRabbit.Rig()
}
struct TutuUnlockInput {
    var t: Double
    var typed: Int
    var text = "/caelumbunny"
    var caret, send: Bool
    var press: Double
    var gone: Bool
    func sink(_ index: Int) -> Double { TutuUnlockModel.clamp((t - 2.34 - Double(index) * 0.028) / 0.32, 0, 1) }
}
struct TutuUnlockView {
    var t: Double
    var rope: TutuUnlockRope?
    var bunny: TutuUnlockBunny?
    var wave: Double = -1
    var shake = SIMD2<Double>.zero
    // The source keeps this empty; the host schedules the independent petal system.
    var petals: [SIMD2<Double>] = []
    var spark: Double = 0
    var input: TutuUnlockInput
    var done: Bool
}

/// Direct Double-precision port of unlock-gl.js Unlock; source timing and touch semantics are intentional.
final class TutuUnlockModel {
    static let width = 420.0, height = 912.0
    static let bar = SIMD4<Double>(15.7, 809.3, 404.3, 854.3)
    static let anchor = SIMD2<Double>(252, -70)
    static let scale = 1.9, rabbitScale = 3.3
    static let LR = 430.0, sally = 58 * scale, tail = 12 * scale
    static let yaw = -0.6
    struct Held { var y0, L0: Double }
    var t = 0.0, acc = 0.0
    var ropeOn = false
    var L = LR - 560, vL = 0.0, phi = 0.05, w = 0.0, extra = 0.0
    var tr: Double?
    var held: Held?
    var touched = false, autoAt = 7.3, tilt = 0.0
    var events: [String] = []
    private var firedLand = false, firedDang = false, firedDing = false

    static func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { x < a ? a : (x > b ? b : x) }
    static func sstep(_ a: Double, _ b: Double, _ x: Double) -> Double { let t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t) }
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func rotY(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(columns: (SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c)))
    }
    static func rotZ(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
    }
    static func turn(_ roll: Double, _ yaw: Double, _ pitch: Double) -> simd_double3x3 { rotZ(roll) * (rotY(yaw) * rotZ(pitch)) }
    func reset() {
        t = 0; acc = 0; ropeOn = false; L = Self.LR - 560; vL = 0; phi = 0.05; w = 0; extra = 0
        tr = nil; held = nil; touched = false; autoAt = 7.3; tilt = 0
        firedLand = false; firedDang = false; firedDing = false; events.removeAll(keepingCapacity: true)
    }
    func ropePoints(_ length: Double? = nil) -> TutuUnlockRope {
        let length = length ?? L, u = SIMD2(sin(phi), cos(phi))
        func at(_ d: Double) -> SIMD2<Double> { Self.anchor + u * d }
        return TutuUnlockRope(u: u, S0: at(length), S1: at(length + Self.sally), K: at(length + Self.sally + Self.tail))
    }
    func hangOrigin(_ R: simd_double3x3) -> SIMD3<Double> {
        let r = ropePoints(), off = R * SIMD3(12 * Self.rabbitScale, 13 * Self.rabbitScale, 0)
        return SIMD3(r.S1.x - off.x, -r.S1.y - off.y, -off.z)
    }
    func rabbitMiddle() -> SIMD2<Double> {
        let R = Self.turn(phi, Self.yaw, 0), o = hangOrigin(R), c = R * SIMD3(2 * Self.rabbitScale, 10 * Self.rabbitScale, 0)
        return SIMD2(o.x + c.x, -(o.y + c.y))
    }
    func holding() -> Bool { t >= 5.32 && (tr == nil || ropeOn) }
    func autoPull() -> Double {
        if touched || tr != nil { return 0 }
        let k = t - autoAt
        return k < 0 ? 0 : 75 * Self.sstep(0, 0.6, k) + 4 * sin(k * 22) * Self.sstep(0, 0.2, k)
    }
    func letGo() { if tr != nil { return }; tr = t; held = nil; vL = -180 }
    func tick(_ h: Double) {
        let now = t
        if now >= 2.75 && !ropeOn && tr == nil { ropeOn = true; L = Self.LR - 560; vL = 260 }
        if !firedLand && now >= 5.32 { firedLand = true; vL += 130; w += 0.14; extra = 6 }
        if ropeOn {
            if tr != nil {
                vL -= 3400 * h; L += vL * h
                if Self.anchor.y + L * cos(phi) < -160 { ropeOn = false }
            } else if held == nil {
                let rest = Self.LR + extra + autoPull()
                vL += ((rest - L) * 40 - vL * 7.6) * h; L += vL * h
            }
            if held == nil {
                let g = 980 / (max(L, 60) + 60), rp = Self.clamp(-tilt * 0.6, -0.3, 0.3)
                w += (-g * sin(phi - rp) - 0.35 * w) * h; phi += w * h
            }
        }
        if tr == nil && held == nil && !touched && holding() && now >= autoAt + 0.72 { letGo() }
        if let release = tr {
            if !firedDang && now >= release + 0.16 { firedDang = true; events.append("dang") }
            if !firedDing && now >= release + 2.55 { firedDing = true; events.append("ding") }
        }
        t += h
    }
    func step(_ dt: Double, _ tilt: Double = 0) {
        self.tilt = tilt; acc += Self.clamp(dt, 0, 0.1)
        let h = 1.0 / 120
        while acc >= h { tick(h); acc -= h }
    }
    func simulate(_ time: Double) { reset(); let h = 1.0 / 120; while t + h <= time + 1e-9 { tick(h) }; events.removeAll(keepingCapacity: true) }
    func done() -> Bool { tr.map { t > $0 + 5 } ?? false }
    @discardableResult func grab(_ x: Double, _ y: Double) -> Bool {
        if !holding() || tr != nil || !ropeOn { return false }
        let r = ropePoints(), s = rabbitMiddle()
        func seg(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            let v = b - a, k = Self.clamp(((x - a.x) * v.x + (y - a.y) * v.y) / (v.x * v.x + v.y * v.y), 0, 1)
            return hypot(x - a.x - v.x * k, y - a.y - v.y * k)
        }
        let near = min(seg(r.S0, r.K) - 6 * Self.scale, hypot(x - s.x, y - s.y) - 30)
        if near > 22 { return false }
        held = Held(y0: y, L0: L); touched = true; vL = 0; w = 0
        return true
    }
    func drag(_ x: Double, _ y: Double) {
        guard let held else { return }
        L = Self.clamp(held.L0 + (y - held.y0), Self.LR - 10, Self.LR + 170)
        phi = Self.clamp(atan2(x - Self.anchor.x, y - Self.anchor.y), -0.35, 0.35)
    }
    func release() {
        guard held != nil else { return }
        let pulled = L - (Self.LR + extra); held = nil
        if pulled > 38 { letGo() } else { autoAt = t + 3 }
    }
    func pulling() -> Double { held == nil ? 0 : Self.clamp((L - Self.LR - extra) / 60, 0, 1) }
    func view() -> TutuUnlockView {
        var n = 0
        for i in 0..<12 {
            let x = sin(Double(i) * 127.1 + 311.7) * 43758.5453, hash = x - floor(x)
            if t >= 0.7 + 0.105 * Double(i) + (hash - 0.5) * 0.04 { n = i + 1 }
        }
        let input = TutuUnlockInput(t: t, typed: n, caret: t < 2.22 && Int(floor(t * 2)) % 2 == 0, send: n > 0 && t < 2.44,
                                    press: Self.sstep(2.22, 2.28, t) * (1 - Self.sstep(2.32, 2.44, t)), gone: t > 2.34 + 0.028 * 12 + 0.4)
        var v = TutuUnlockView(t: t, rope: ropeOn ? ropePoints() : nil, bunny: rabbitView(), input: input, done: done())
        if let tr {
            let tw = t - (tr + 0.16); v.wave = tw
            if tw >= 0 && tw < 0.6 { let e = exp(-tw / 0.18); v.shake = SIMD2(sin(tw * 55) * 1.6 * e, cos(tw * 47) * e) }
            let sa = t - (tr + 2.55)
            if sa > 0 && sa < 0.8 { v.spark = sin(Double.pi * Self.clamp(sa / 0.8, 0, 1)) * (1 - sa / 0.8 * 0.4) }
        }
        return v
    }
    func rabbitView() -> TutuUnlockBunny? {
        if t < 3.45 || (tr != nil && !ropeOn) { return nil }
        var b = TutuUnlockBunny(origin: .zero, R: matrix_identity_double3x3)
        if t < 4.82 {
            let s = Self.clamp((t - 3.45) / (3.95 - 3.45), 0, 1), e = s * s * (3 - 2 * s), hop = sin(Double.pi * s)
            let x = Self.mix(132, 150, e), y = Self.bar.y + 62 * (1 - e) - 46 * hop
            b.origin = SIMD3(x, -y, 0); b.R = Self.turn(0, Self.yaw, 0.32 * hop); b.mask = s < 0.62 ? 1 : 0
            let look = Self.sstep(4.05, 4.05 + 0.3, t), crouch = Self.sstep(4.62, 4.82, t)
            let leapW = pow(hop, 1.2) * (s < 1 ? 1 : 0)
            b.rig.weights = SIMD4((1 - leapW) * (1 - crouch), crouch * (1 - leapW), leapW, 0)
            b.rig.head = .init(turn: 0.2 * look, nod: 0.42 * look * (1 - 0.6 * crouch), tilt: 0.1 * look)
            b.rig.ears = .init(flickL: Self.sstep(4.32, 4.32 + 0.06, t) * (1 - Self.sstep(4.32 + 0.12, 4.32 + 0.26, t)), stream: 0.3 * hop)
        } else if t < 5.32 {
            let s = (t - 4.82) / (5.32 - 4.82), e = s * s * (3 - 2 * s), arc = 4 * s * (1 - s)
            let to = hangOrigin(Self.turn(phi, Self.yaw, 0)), from = SIMD3(150, -Self.bar.y, 0)
            b.origin = SIMD3(Self.mix(from.x, to.x, e), Self.mix(from.y, to.y, e) + 70 * arc, Self.mix(from.z, to.z, e))
            b.R = Self.turn(phi * s, Self.yaw, 0.95 * sin(Double.pi * min(1, s * 1.15)))
            let lw = pow(sin(Double.pi * s), 0.7), hw = Self.sstep(0.62, 1, s)
            b.rig.weights = SIMD4(0, max(0, 1 - s * 4), lw * (1 - hw), hw)
            b.rig.ears = .init(stream: 0.45 * sin(Double.pi * s))
        } else {
            b.R = Self.turn(phi, Self.yaw, 0); b.origin = hangOrigin(b.R); b.rig.weights = SIMD4(0, 0, 0, 1)
            let auto = touched ? 0 : Self.sstep(autoAt, autoAt + 0.2, t) * (tr == nil ? 1 : 0)
            b.rig.kick = max(pulling(), auto) * 0.5 * (1 + sin(t * 15))
            b.rig.head = .init(nod: 0.05 * sin(t * 1.3), tilt: 0.06 * sin(t * 0.9))
            b.rig.ears = .init(flickL: 0.12 * max(0, sin(t * 1.7)), phase: t * 30)
            if let tr { let up = Self.sstep(0, 0.12, t - tr); b.rig.ears = .init(stream: up, flutter: 0.12 * up, phase: t * 30); b.rig.kick = 0.7 * up }
        }
        return b
    }
}
#endif
#endif
