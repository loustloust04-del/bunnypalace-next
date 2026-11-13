#if PERSONAL_APPS
#if os(iOS)
import Foundation
import simd

/// rabbit.js POSES/blend/rig, with Double calculations and Float uniform conversion only at the boundary.
enum TutuRabbit {
    struct Ears {
        var flickL: Double = 0, flickR: Double = 0, stream: Double = 0, flutter: Double = 0, phase: Double = 0
    }
    struct Head { var turn: Double = 0, nod: Double = 0, tilt: Double = 0 }
    struct Rig {
        var weights = SIMD4<Double>(1, 0, 0, 0)
        var ears = Ears()
        var head = Head()
        var kick: Double = 0
    }
    struct Uniforms {
        var R = Array(repeating: SIMD4<Float>.zero, count: 27)
        var H = matrix_identity_float3x3
        fileprivate var pose = Pose(joints: Array(repeating: .zero, count: 11), head: .zero, headRot: .zero, base: .zero, back: 0, splay: 0, turn: 0)
    }
    struct Pose {
        var joints: [SIMD4<Double>]
        var head, headRot, base: SIMD3<Double>
        var back, splay, turn: Double
    }
    // rest, crouch, leap, hang; joint order is the original KEYS order.
    static let poses: [Pose] = [
        Pose(joints: [SIMD4(2.4, 4.5, 0, 3.1), SIMD4(-3, 5.2, 0, 2.95), SIMD4(-7.6, 6.4, 0, 3.4), SIMD4(2.6, 5.4, 0, 3.2), SIMD4(4.4, 8.4, 0, 3), SIMD4(3, 3.2, 1.85, 1.85), SIMD4(10.2, 1.72, 2.35, 1.6), SIMD4(-6.9, 3.7, 2.45, 1), SIMD4(-4.9, 1.05, 2.55, 0), SIMD4(-10, 7.6, 0, 1.75), SIMD4(-10.9, 10.2, 0, 1.15)], head: SIMD3(5.6, 10.6, 0), headRot: SIMD3(0, 0.06, 0), base: SIMD3(-1, 4, 1.25), back: 0.16, splay: 0.32, turn: 0.5),
        Pose(joints: [SIMD4(2.4, 3.6, 0, 3.1), SIMD4(-3, 4.3, 0, 2.95), SIMD4(-7.4, 5.3, 0, 3.4), SIMD4(2.6, 4.4, 0, 3.2), SIMD4(4.6, 7, 0, 3), SIMD4(3, 2.7, 1.85, 1.85), SIMD4(9.6, 1.72, 2.35, 1.6), SIMD4(-6.6, 3.2, 2.45, 1), SIMD4(-4.6, 1.05, 2.55, 0), SIMD4(-9.8, 6.4, 0, 1.75), SIMD4(-10.8, 8.8, 0, 1.15)], head: SIMD3(6, 9, 0), headRot: SIMD3(0, -0.06, 0), base: SIMD3(-1, 4, 1.25), back: 0.85, splay: 0.22, turn: 0.4),
        Pose(joints: [SIMD4(3, 6.4, 0, 3.05), SIMD4(-2.6, 7, 0, 2.9), SIMD4(-7.6, 7.6, 0, 3.25), SIMD4(3.2, 7.2, 0, 3.15), SIMD4(5.2, 9.8, 0, 2.95), SIMD4(3.6, 5, 1.85, 1.65), SIMD4(11.4, 5.6, 2.1, 1.45), SIMD4(-7.6, 6, 2.45, 0.9), SIMD4(-13.6, 3.6, 2.4, 0), SIMD4(-10.4, 8.8, 0, 1.7), SIMD4(-11.8, 10.6, 0, 1.12)], head: SIMD3(6.8, 12.2, 0), headRot: SIMD3(0, 0.05, 0), base: SIMD3(-1, 4, 1.25), back: 1.1, splay: 0.16, turn: 0.3),
        Pose(joints: [SIMD4(1.6, 11.2, 0, 3), SIMD4(-0.6, 7.4, 0, 2.9), SIMD4(-2, 4, 0, 3.3), SIMD4(1.7, 12.2, 0, 2.95), SIMD4(1.9, 15, 0, 2.8), SIMD4(2.6, 10.4, 2.05, 1.8), SIMD4(7.9, 12.4, 1.9, 1.55), SIMD4(-1.7, 3, 2.45, 0.95), SIMD4(-0.5, -1.2, 2.3, 0), SIMD4(-4.8, 4.2, 0, 1.7), SIMD4(-6.6, 5.6, 0, 1.12)], head: SIMD3(1.9, 18.4, 0), headRot: SIMD3(0, 0.6, 0), base: SIMD3(-1, 4, 1.25), back: -0.08, splay: 0.36, turn: 0.45)
    ]
    static func blend(_ weights: SIMD4<Double>, into p: inout Pose) {
        var total = 0.0
        for i in 0..<4 where weights[i] > 0 { total += weights[i] }
        if total == 0 { total = 1 }
        for k in 0..<11 { p.joints[k] = .zero }
        p.head = .zero; p.headRot = .zero; p.base = .zero
        p.back = 0; p.splay = 0; p.turn = 0
        for i in 0..<4 where weights[i] > 0 {
            let w = weights[i] / total, source = poses[i]
            for k in 0..<11 { p.joints[k] += source.joints[k] * w }
            p.head += source.head * w; p.headRot += source.headRot * w; p.base += source.base * w
            p.back += source.back * w; p.splay += source.splay * w; p.turn += source.turn * w
        }
    }
    private static func rx(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, c, s), SIMD3(0, -s, c)))
    }
    private static func norm(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = hypot(hypot(v.x, v.y), v.z)
        return v / (length == 0 ? 1 : length)
    }
    static func rig(_ opts: Rig, into uniforms: inout Uniforms) {
        blend(opts.weights, into: &uniforms.pose)
        let p = uniforms.pose, ex = opts.ears, hx = opts.head, kick = opts.kick
        func xyz(_ v: SIMD4<Double>) -> SIMD3<Double> { SIMD3(v.x, v.y, v.z) }
        func put(_ i: Int, _ v: SIMD4<Double>) { uniforms.R[i] = SIMD4<Float>(v) }
        func put3(_ i: Int, _ v: SIMD3<Double>, _ radius: Double = 0) { put(i, SIMD4(v.x, v.y, v.z, radius)) }
        func mir(_ v: SIMD4<Double>) -> SIMD4<Double> { SIMD4(v.x, v.y, -v.z, v.w) }
        for i in 0..<5 { put(i, p.joints[i]) }
        put(5, p.joints[5]); put(6, p.joints[6]); put(7, mir(p.joints[5])); put(8, mir(p.joints[6]))
        var hpL = p.joints[8], hpR = mir(p.joints[8])
        if kick != 0 { hpL = SIMD4(hpL.x, hpL.y - 1.6 * kick, hpL.z, 0); hpR = SIMD4(hpR.x - kick, hpR.y - 2.4 * kick, hpR.z, 0) }
        put(9, p.joints[7]); put(10, hpL); put(11, mir(p.joints[7])); put(12, hpR)
        put(13, p.joints[9]); put(14, p.joints[10]); put3(15, p.head)
        let h = TutuUnlockModel.rotY(p.headRot.x + hx.turn) * (TutuUnlockModel.rotZ(p.headRot.y + hx.nod) * rx(p.headRot.z + hx.tilt))
        for k in 0..<2 {
            let side = k == 0 ? 1.0 : -1.0, flick = k == 0 ? ex.flickL : ex.flickR, st = ex.stream
            let back = p.back + st * 0.65 - flick * 0.5
            let splay = p.splay * (1 - 0.6 * st) + flick * 0.12 + ex.flutter * sin(ex.phase + Double(k) * 1.7)
            let dd = norm(rx(side * splay) * (TutuUnlockModel.rotZ(back) * SIMD3(0, 1, 0)))
            var front = norm(SIMD3(cos(p.turn), 0, side * sin(p.turn)))
            front = norm(front + dd * -simd_dot(front, dd))
            put3(16 + k * 3, SIMD3(p.base.x, p.base.y, side * p.base.z)); put3(17 + k * 3, dd); put3(18 + k * 3, front)
        }
        let n0 = p.joints[3], n1 = p.joints[4], delta = xyz(n1) - xyz(n0), axis = norm(delta)
        let rc = xyz(n0) + axis * (0.45 * hypot(hypot(delta.x, delta.y), delta.z))
        let rr = n0.w + (n1.w - n0.w) * 0.45 + 0.1
        put3(22, rc, rr); put3(23, axis, 0.3)
        var fw = SIMD3<Double>(1, -0.35, 0); fw = norm(fw + axis * -simd_dot(fw, axis))
        let bc = rc + fw * (rr + 0.2)
        put3(24, bc, 1); put3(25, fw)
        put3(26, bc + axis * -0.95 + fw * 0.25, 0.66)
        uniforms.H = simd_float3x3(columns: (SIMD3<Float>(h.columns.0), SIMD3<Float>(h.columns.1), SIMD3<Float>(h.columns.2)))
    }
}
#endif
#endif
