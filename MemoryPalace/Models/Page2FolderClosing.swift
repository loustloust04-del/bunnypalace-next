import Foundation

enum Page2FolderClosing {
    static let duration = 0.48
    static let rate = 18.44
    static func remaining(_ phase: Double) -> Double {
        guard phase.isFinite, phase > 0 else { return 1 }
        guard phase < 1 else { return 0 }
        let time = phase * duration
        let end = (1 + rate * duration) * exp(-rate * duration)
        let value = (1 + rate * time) * exp(-rate * time)
        return (value - end) / (1 - end)
    }
    static func titleOpacity(_ phase: Double) -> Double {
        let t = min(1, max(0, phase * duration / 0.16))
        return 1 - t * t * (3 - 2 * t)
    }
}
