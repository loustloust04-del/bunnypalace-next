#if PERSONAL_APPS
#if os(iOS)
import Foundation

/// Literal TutuGL.Crackle controller. All timestamps are monotonic milliseconds.
struct TutuCrackle {
    private(set) var level = 0.0
    private(set) var target = 0.0
    private(set) var stress = 0.0
    private(set) var cracked = false
    var onCrack: (() -> Void)?
    private(set) var breakLevel = 0.0
    private(set) var breakTarget = 0.0
    private(set) var breakStress = 0.0
    private(set) var breaking = false
    private(set) var amount = 0.0
    var enabled = true {
        didSet { if !enabled { suspendInput() } }
    }
    private var motionAmount = 0.0
    private var motionTime: Double?
    private var externalAmount = 0.0
    private var externalTime: Double?
    private struct Point { var x: Double; var y: Double; var time: Double }
    private var points: [Point] = []

    mutating func motion(ax: Double, ay: Double, az: Double, dt: Double? = nil, at time: Double) {
        guard enabled else { return }
        let delta = dt ?? motionTime.map { min(0.1, max(0.004, (time - $0) / 1000)) } ?? (1.0 / 60)
        motionTime = time
        let magnitude = sqrt(ax * ax + ay * ay + az * az)
        let value = magnitude > 11 ? min((magnitude - 11) / 12 + 0.5, 1.5) : 0
        motionAmount += (value - motionAmount) * min(1, delta * 4)
    }

    mutating func point(x: Double, y: Double, at time: Double) {
        guard enabled else { return }
        points.append(Point(x: x, y: y, time: time))
        var expired = 0
        while points.count - expired > 2 && points[expired].time < time - 700 { expired += 1 }
        if expired > 0 { points.removeFirst(expired) }
    }

    mutating func release() { points.removeAll(keepingCapacity: true) }

    mutating func shake(_ value: Double, at time: Double) {
        guard enabled else { return }
        externalAmount = min(1.5, max(0, value))
        externalTime = time
    }

    func scrub(at now: Double) -> Double {
        guard enabled, points.count >= 4 else { return 0 }
        var first = 0
        while first < points.count - 1 && points[first].time < now - 600 { first += 1 }
        let start = first > 0 ? now - 600 : points[0].time
        let span = max(0.2, (now - start) / 1000)
        var path = 0.0, turns = 0.0, sx = 0.0, sy = 0.0
        for index in (first + 1)..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < 0.5 { continue }
            path += distance
            if sx * sx + sy * sy > 36 && dx * sx + dy * sy < 0 {
                turns += 1; sx = dx; sy = dy
            } else { sx += dx; sy += dy }
        }
        let frequency = turns / (2 * span), velocity = path / span
        guard frequency >= 2.5 else { return 0 }
        let acceleration = 9.87 * frequency * velocity
        return acceleration > 25000 ? min((acceleration - 25000) / 40000 + 0.5, 1.5) : 0
    }

    @discardableResult
    mutating func step(dt: Double, at now: Double) -> Double {
        guard enabled else { return level }
        let dt = min(0.25, max(0, dt))
        if motionTime == nil || now - motionTime! > 150 { motionAmount = max(0, motionAmount - dt * 1.5) }
        if externalTime == nil || now - externalTime! > 150 { externalAmount = max(0, externalAmount - dt * 1.5) }
        let value = max(motionAmount, externalAmount, scrub(at: now))
        amount = value
        if value > 0.35 { stress += min(value, 1) * dt }
        else { stress = max(0, stress - 0.35 * dt) }
        if !cracked && stress > 7 {
            cracked = true; target = max(target, 0.07)
            onCrack?()
        }
        if cracked && value > 0.35 { target = min(1, target + 0.035 * min(value, 1) * dt) }
        level += (target - level) * min(1, dt * 2.5)
        if level >= 0.999 {
            level = 1; target = 1
            if value > 0.35 { breakStress += min(value, 1) * dt }
            else if !breaking { breakStress = max(0, breakStress - dt * 0.35) }
            if !breaking && breakStress > 4 { breaking = true; breakTarget = 0.06 }
            if breaking && value > 0.35 { breakTarget = min(1, breakTarget + 0.025 * min(value, 1) * dt) }
            breakLevel += (breakTarget - breakLevel) * min(1, dt * 2.5)
            if breakLevel > 0.999 { breakLevel = 1; breakTarget = 1 }
        }
        return level
    }

    /// Lifecycle/settings gates discard strain, never the damage already sustained.
    mutating func suspendInput() {
        release()
        motionAmount = 0; motionTime = nil
        externalAmount = 0; externalTime = nil
        amount = 0; stress = 0; breakStress = 0
    }

    mutating func set(_ value: Double) {
        let value = min(1, max(0, value))
        cracked = value > 0; target = value; level = value; stress = 0
        breakLevel = 0; breakTarget = 0; breakStress = 0; breaking = false
    }
}
#endif
#endif
