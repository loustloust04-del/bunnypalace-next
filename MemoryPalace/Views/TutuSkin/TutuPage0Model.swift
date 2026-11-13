#if PERSONAL_APPS
#if os(iOS)
import Foundation

struct TutuPage0Vector: Equatable, Codable {
    var x: Double
    var y: Double
    init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
}

private func page0Clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(high, max(low, value))
}

/// A direct translation of page0-gl.js:379–428. Coordinates remain 402 × 874 design points.
struct TutuPage0Pull {
    var A = TutuPage0Vector(283, -8)
    var k = 0.62
    var Lr = 72.0
    var L = -130.0
    var vL = 0.0
    var phi = 0.02
    var w = 0.0
    var held: TutuPage0Vector?
    var t = 0.0
    var shown = false

    mutating func show(instant: Bool = false) {
        guard !shown else { return }
        shown = true
        if instant { L = Lr; vL = 0 }
        else { L = -70; vL = 60; w = 0.12 }
    }
    mutating func hide() { shown = false; held = nil }
    var visible: Bool { L > -110 }
    var vis: Bool { visible }
    var ball: TutuPage0Vector {
        let d = L + 23 * k
        return .init(A.x + sin(phi) * d, A.y + cos(phi) * d)
    }
    func hit(x: Double, y: Double) -> Bool {
        guard shown, L >= Lr * 0.6 else { return false }
        let b = ball
        var best = 1e9
        for i in 0...6 {
            let s = Double(i) / 6 * 62 * k
            best = min(best, hypot(x - b.x - sin(phi) * s, y - b.y - cos(phi) * s))
        }
        return best < 24
    }
    mutating func grab(x: Double, y: Double) {
        let b = ball
        held = .init(x - b.x, y - b.y); w = 0; vL = 0
    }
    mutating func drag(x: Double, y: Double) {
        guard let held else { return }
        let vx = x - held.x - A.x, vy = y - held.y - A.y
        let d = max(20, hypot(vx, vy))
        L = page0Clamp(d - 23 * k, Lr * 0.7, Lr + 170)
        phi = page0Clamp(atan2(vx, vy), -0.9, 0.9)
    }
    var amount: Double { held == nil ? 0 : page0Clamp((L - Lr) / 150, 0, 1) }
    mutating func release() -> Bool {
        guard held != nil else { return false }
        let pulled = L - Lr
        held = nil
        return pulled > 46
    }
    mutating func kick(_ velocity: Double) { w += velocity }
    mutating func step(dt: Double, tilt: Double) {
        let dt = page0Clamp(dt, 0, 0.05)
        t += dt
        guard held == nil else { return }
        if shown { vL += ((Lr - L) * 170 - vL * 12) * dt }
        else { vL += ((-130 - L) * 140 - vL * 15) * dt }
        L += vL * dt
        let rest = page0Clamp(-tilt * 0.9, -0.45, 0.45) + 0.03 * sin(t * 0.7)
        let g = 980 / (L + 30)
        w += (-g * sin(phi - rest) - 1.4 * w) * dt
        phi += w * dt
    }
}

/// Both a CA presentation snapshot and the analytic steady response. `w` is the
/// Euler backward-difference velocity; `phiVelocity` is the continuous curve derivative.
struct TutuPage0Presentation {
    var open = 0.0
    var tilt = TutuPage0Vector()
    var tiltVelocity = TutuPage0Vector()
    var L = 0.0
    var vL = 0.0
    var phi = 0.0
    var w = 0.0
    var phiVelocity = 0.0
    var time = 0.0
}

/// Discrete 60 Hz transfer functions, not the continuous oscillator approximation.
/// Only sin(phi-rest) is linearized; the host runner measures that approximation
/// against the unmodified JavaScript nonlinear integrator, retaining every sample.
struct TutuPage0SteadyState {
    var idle: Bool
    var target: TutuPage0Vector
    var shown: Bool
    init(idle: Bool, target: TutuPage0Vector = .init(), shown: Bool = true) {
        self.idle = idle; self.target = target; self.shown = shown
    }

    private struct Harmonic {
        var sine: Double
        var cosine: Double = 0
        func value(_ frequency: Double, _ time: Double) -> Double {
            sine * sin(frequency * time) + cosine * cos(frequency * time)
        }
        func derivative(_ frequency: Double, _ time: Double) -> Double {
            frequency * (sine * cos(frequency * time) - cosine * sin(frequency * time))
        }
        func divided(real: Double, imaginary: Double, scale: Double) -> Self {
            let denominator = real * real + imaginary * imaginary
            return .init(sine: scale * (sine * real + cosine * imaginary) / denominator,
                         cosine: scale * (cosine * real - sine * imaginary) / denominator)
        }
    }
    private func filtered(_ harmonic: Harmonic, frequency: Double) -> Harmonic {
        let phase = frequency / 60
        return harmonic.divided(real: 1 - 0.9 * cos(phase), imaginary: 0.9 * sin(phase), scale: 0.1)
    }
    private func oscillator(_ rest: Harmonic, frequency: Double) -> Harmonic {
        let h = 1.0 / 60, g = 980.0 / 102, phase = frequency * h
        let a = 2 - 1.4 * h - g * h * h, b = 1 - 1.4 * h
        return rest.divided(real: 1 - a * cos(phase) + b * cos(2 * phase),
                            imaginary: a * sin(phase) - b * sin(2 * phase), scale: g * h * h)
    }
    func sampleComponents(at time: Double) -> (swing: TutuPage0Presentation, driftX: TutuPage0Presentation, driftY: TutuPage0Presentation) {
        func component(_ frequency: Double, tiltX: Harmonic = .init(sine: 0),
                       tiltY: Harmonic = .init(sine: 0), rest: Harmonic) -> TutuPage0Presentation {
            let phi = shown ? oscillator(rest, frequency: frequency) : Harmonic(sine: 0)
            var result = TutuPage0Presentation()
            result.time = time
            result.tilt = .init(tiltX.value(frequency, time), tiltY.value(frequency, time))
            result.tiltVelocity = .init(tiltX.derivative(frequency, time), tiltY.derivative(frequency, time))
            result.phi = phi.value(frequency, time)
            result.phiVelocity = phi.derivative(frequency, time)
            result.w = (result.phi - phi.value(frequency, time - 1.0 / 60)) * 60
            return result
        }
        let x = filtered(.init(sine: idle ? 0.07 : 0), frequency: 0.31)
        let y = filtered(.init(sine: idle ? 0.045 * cos(1.2) : 0,
                               cosine: idle ? 0.045 * sin(1.2) : 0), frequency: 0.2)
        return (component(0.7, rest: .init(sine: 0.03)),
                component(0.31, tiltX: x, rest: .init(sine: -0.9 * x.sine, cosine: -0.9 * x.cosine)),
                component(0.2, tiltY: y, rest: .init(sine: 0)))
    }
    func sample(at time: Double) -> TutuPage0Presentation {
        let c = sampleComponents(at: time)
        var result = TutuPage0Presentation()
        result.open = shown ? 1 : 0; result.L = shown ? 72 : -130; result.time = time
        result.tilt = idle ? .init() : target
        result.phi = shown && !idle ? page0Clamp(-target.x * 0.9, -0.45, 0.45) : 0
        func add(_ value: TutuPage0Presentation) {
            result.tilt.x += value.tilt.x; result.tilt.y += value.tilt.y
            result.tiltVelocity.x += value.tiltVelocity.x; result.tiltVelocity.y += value.tiltVelocity.y
            result.phi += value.phi; result.w += value.w; result.phiVelocity += value.phiVelocity
        }
        add(c.swing); add(c.driftX); add(c.driftY)
        return result
    }
}

struct TutuPage0Model {
    var open: Double
    var openTarget: Double
    var tilt = TutuPage0Vector()
    var target = TutuPage0Vector()
    var pull = TutuPage0Pull()
    var time: Double { pull.t }
    private var clothStart: Double?
    private var accumulated = 0.0
    private var convergedDuration = 0.0
    init(open: Bool = false) {
        self.open = open ? 1 : 0; openTarget = self.open
        if open { pull.show(instant: true) }
    }
    mutating func setOpen(_ value: Bool) {
        openTarget = value ? 1 : 0
        if !value { pull.hide() }
        convergedDuration = 0
    }
    mutating func beginCloth() { clothStart = openTarget < 0.5 ? openTarget : nil }
    mutating func dragCloth(dy: Double, height: Double) {
        guard let clothStart, height > 0 else { return }
        openTarget = page0Clamp(clothStart + dy / height * 1.25, 0, 1)
        open = openTarget
    }
    mutating func endCloth() {
        guard clothStart != nil else { return }
        clothStart = nil; setOpen(open > 0.38)
    }
    mutating func beginPull(at point: TutuPage0Vector) -> Bool {
        guard pull.hit(x: point.x, y: point.y) else { return false }
        pull.grab(x: point.x, y: point.y); return true
    }
    mutating func dragPull(to point: TutuPage0Vector) {
        pull.drag(x: point.x, y: point.y)
        if pull.held != nil { open = 1 - pull.amount * 0.6 }
    }
    mutating func endPull() { if pull.release() { setOpen(false) } }
    mutating func step(dt: Double, idle: Bool) {
        let dt = page0Clamp(dt, 0, 0.05)
        if idle {
            target = .init(0.07 * sin((time + dt) * 0.31), 0.045 * sin((time + dt) * 0.2 + 1.2))
        }
        let filter = 1 - pow(0.9, 60 * dt)
        tilt.x += (target.x - tilt.x) * filter; tilt.y += (target.y - tilt.y) * filter
        pull.step(dt: dt, tilt: tilt.x)
        if openTarget == 1, open > 0.97, !pull.shown { pull.show() }
        if clothStart == nil, pull.held == nil { open += (openTarget - open) * (1 - pow(0.925, 60 * dt)) }
        if abs(openTarget - open) < 0.0005 { open = openTarget }
    }
    /// Retains fractional time instead of changing the Euler step at low refresh rates.
    mutating func advance(dt: Double, idle: Bool) {
        accumulated += max(0, dt)
        let h = 1.0 / 60
        while accumulated + 1e-12 >= h {
            step(dt: h, idle: idle); accumulated -= h
        }
    }
    mutating func resume(from state: TutuPage0Presentation) {
        open = state.open; tilt = state.tilt
        pull.L = state.L; pull.vL = state.vL; pull.phi = state.phi
        pull.w = state.phiVelocity; pull.t = state.time
        accumulated = 0; convergedDuration = 0
    }
    mutating func isConverged(to steady: TutuPage0SteadyState, dt: Double) -> Bool {
        let s = steady.sample(at: time)
        // Farthest visible tassel point, rather than just the ball centre.
        let radius = pull.Lr + (23 + 62) * pull.k
        let angleReady = !pull.shown || (abs(pull.phi - s.phi) * radius < 0.05 && abs(pull.w - s.w) * radius < 0.05)
        let ready = clothStart == nil && pull.held == nil && open == openTarget
            && abs(pull.L - s.L) < 0.01 && abs(pull.vL) < 0.02 && angleReady
            && abs(tilt.x - s.tilt.x) < 0.0001 && abs(tilt.y - s.tilt.y) < 0.0001
        convergedDuration = ready ? convergedDuration + max(0, dt) : 0
        return convergedDuration >= 0.5
    }
}

/// Pure gesture arbitration. UIKit owns scroll pinning; this type never mutates a list.
struct TutuPage0Arbitration {
    enum Route: Equatable { case rejected, pending, list, cloth, pull, background }
    private(set) var route: Route = .rejected
    var consumesTap: Bool { route == .pull }
    private(set) var startOffset = 0.0
    private(set) var handoffY: Double?
    private var start = TutuPage0Vector()
    private var isRow = false
    private var canOpen = false
    mutating func begin(at point: TutuPage0Vector, width: Double, allowed: Bool,
                        openTarget: Double, pullHit: Bool, isRow: Bool, scrollOffset: Double) -> Route {
        start = point; startOffset = scrollOffset; handoffY = nil
        self.isRow = isRow; canOpen = openTarget < 0.5
        guard allowed, point.x > 16, point.x < width - 16 else { route = .rejected; return route }
        if pullHit { route = .pull }
        else if !canOpen && isRow { route = .rejected }
        else { route = .pending }
        return route
    }
    mutating func move(to point: TutuPage0Vector, scrollOffset: Double, allowed: Bool) -> Route {
        guard allowed else { route = .rejected; return route }
        guard route != .rejected, route != .pull else { return route }
        let dx = point.x - start.x, dy = point.y - start.y
        if route == .pending {
            guard max(abs(dx), abs(dy)) >= 4 else { return route }
            if abs(dx) >= abs(dy) { route = isRow ? .rejected : .background; return route }
            route = canOpen ? .list : .background
        }
        if route == .list, canOpen, dy > 0, scrollOffset <= 0 {
            // At-top initial touch counts all displacement; a scrolling list hands off
            // only at the position at which this same finger actually reaches its top.
            handoffY = startOffset <= 0 ? start.y : point.y
            route = .cloth
        }
        return route
    }
    func clothDisplacement(at point: TutuPage0Vector) -> Double { handoffY.map { point.y - $0 } ?? 0 }
    var pinnedScrollOffset: Double? {
        switch route {
        case .pull: return startOffset
        case .cloth: return 0
        default: return nil
        }
    }
    mutating func finish() { route = .rejected; handoffY = nil }
}
#endif
#endif
