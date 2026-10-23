import Foundation

/// 季节混合：i0 → i1 按 w 过渡（0 春 1 夏 2 秋 3 冬），每季后 45% 才开始往下一季走
struct GardenSeasonWeights {
    let i0: Int, i1: Int, w: Double

    init(_ season: Double) {
        let f0 = season.rounded(.down)
        i0 = ((Int(f0) % 4) + 4) % 4
        i1 = (i0 + 1) % 4
        w = GardenMath.smooth(0.55, 1, season - f0)
    }
    func weight(_ k: Int) -> Double { (k == i0 ? 1 - w : 0) + (k == i1 ? w : 0) }
    func key(_ keys: [Double]) -> Double { keys[i0] + (keys[i1] - keys[i0]) * w }
}

struct GardenEnvironment {
    let sw: GardenSeasonWeights
    let p: Double
    let top: GardenRGB, hor: GardenRGB
    let day: Double, night: Double
    let light: SIMD3<Double>
    let sunI: Double
    let sunC: GardenRGB
    let amb: GardenRGB
    let el: Double
    let moonL = SIMD3<Double>(-0.35, 0.55, 0.76)
    let moonI: Double
    let moonC = GardenMath.hex("#cfc4dc")
    let lights: Double
    let nightQ: Double
    let snow: Double
    let bloom: Double
    let leafA: Double

    var isDaylight: Bool { day > 0.5 }

    private static let skyKeys: [(Double, String, String)] = [
        (0, "#25222d", "#38323f"), (4.6, "#2b2735", "#493e4e"), (5.5, "#6b5d74", "#c49aa1"), (6.3, "#cbb3c1", "#f0cfc2"),
        (7.4, "#dfe7e2", "#f6e9dd"), (9, "#e2ebe5", "#f5f2ea"), (15, "#e4ede7", "#f4f1e6"), (16.8, "#eae4dc", "#f5e7d8"),
        (17.6, "#d8b5b6", "#efc9b5"), (18.4, "#907b95", "#d8a199"), (19.4, "#4a4058", "#7d6678"), (20.4, "#2b2735", "#433a4c"),
        (24, "#25222d", "#38323f"),
    ]
    private static let sky: [(h: Double, top: GardenRGB, hor: GardenRGB)] = skyKeys.map { (h: $0.0, top: GardenMath.hex($0.1), hor: GardenMath.hex($0.2)) }

    private static func skyAt(_ solar: Double) -> (GardenRGB, GardenRGB) {
        for k in 0..<(sky.count - 1) {
            let a = sky[k], b = sky[k + 1]
            if solar >= a.h && solar <= b.h {
                let f = GardenMath.smooth(0, 1, (solar - a.h) / (b.h - a.h))
                return (GardenMath.mix(a.top, b.top, f), GardenMath.mix(a.hor, b.hor, f))
            }
        }
        return (sky[0].top, sky[0].hor)
    }

    /// hour 0..<24，season 0 春 1 夏 2 秋 3 冬（可带小数过渡）
    init(hour: Double, season: Double) {
        let mix = GardenMath.mix, hex = GardenMath.hex, clamp = { GardenMath.clamp($0) }, smooth = GardenMath.smooth
        sw = GardenSeasonWeights(season)
        let w = sw.weight
        let rise = 6 - w(1) + w(3), set = 18 + w(1) - w(3)
        p = (hour - rise) / (set - rise)
        let solar: Double
        if p >= 0 && p <= 1 {
            solar = 6 + 12 * p
        } else {
            let hh = hour < rise ? hour + 24 : hour
            solar = (18 + 12 * (hh - set) / (rise + 24 - set)).truncatingRemainder(dividingBy: 24)
        }
        var (t, h) = Self.skyAt(solar)
        day = smooth(-0.05, 0.07, p) * smooth(1.05, 0.93, p)
        t = mix(t, hex("#e3e5e3"), 0.35 * w(3) * day)
        h = mix(h, hex("#ecebe6"), 0.35 * w(3) * day)
        h = mix(h, hex("#f3e6d6"), 0.25 * w(2) * day)
        top = t; hor = h
        let maxEl = 0.85 + 0.2 * w(1) - 0.3 * w(3)
        el = sin(.pi * clamp(p)) * maxEl
        let az = (150 - 200 * clamp(p)) * .pi / 180
        light = SIMD3(cos(az) * cos(el), sin(az) * cos(el), sin(el))
        sunI = clamp(sin(el) * 3.2) * 0.78 * day
        sunC = mix(hex("#f6c0a2"), hex("#fffaf0"), clamp(sin(el) / 0.45))
        night = 1 - day
        let ambK = 0.4 + 0.18 * day * smooth(0.05, 0.6, sin(el)) + 0.1 * night
        amb = mix(t, h, 0.5) * ambK + hex("#4a4258") * (0.6 * night)
        moonI = 0.46 * night
        lights = smooth(0.3, 0.85, night)
        nightQ = clamp(p > 1 ? (hour - set) / (rise + 24 - set) : (hour + 24 - set) / (rise + 24 - set))
        snow = sw.key([0, 0, 0, 1])
        bloom = sw.key([1, 0.7, 0.3, 0])
        leafA = sw.key([0.92, 1, 0.7, 0])
    }

    /// 本地时间 → (hour, season)。季节按年内天数：3/20 前后为春的中点起算，每 91.3 天一季
    static func clock(_ date: Date, calendar: Calendar = .current) -> (hour: Double, season: Double) {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        let doy = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let season = ((doy - 79) / 91.3 + 4).truncatingRemainder(dividingBy: 4)
        return (hour, season)
    }
}
