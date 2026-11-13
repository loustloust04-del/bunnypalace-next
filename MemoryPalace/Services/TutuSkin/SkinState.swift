#if PERSONAL_APPS
import Foundation
import Observation

@Observable
final class SkinState {
    static let shared = SkinState(defaults: .standard)

    enum TimeOfDay: String, CaseIterable, Identifiable {
        case now, day, dusk, night
        var id: String { rawValue }
        var title: String {
            switch self {
            case .now: "此刻"
            case .day: "白天"
            case .dusk: "傍晚"
            case .night: "夜里"
            }
        }
    }

    enum Page0Style: String, CaseIterable, Identifiable {
        case paper, glass
        var id: String { rawValue }
        var title: String {
            switch self {
            case .paper: "纸"
            case .glass: "液态玻璃（试做）"
            }
        }
    }

    #if os(iOS)
    enum WuWallpaper: String, CaseIterable, Identifiable {
        case plain, folds, crushed, damask, emboss
        var id: String { rawValue }
        var title: String {
            switch self {
            case .plain: "素绒"
            case .folds: "褶绒"
            case .crushed: "碎绒"
            case .damask: "烂花"
            case .emboss: "压花"
            }
        }
    }
    var wuWallpaper: WuWallpaper {
        didSet { defaults.set(wuWallpaper.rawValue, forKey: Self.prefix + "wuWallpaper") }
    }
    #endif

    @ObservationIgnored private let defaults: UserDefaults
    private static let prefix = "tutuSkin."

    var unlocked: Bool {
        didSet {
            guard oldValue != unlocked else { return }
            defaults.set(unlocked, forKey: Self.prefix + "unlocked")
            activationChanged(from: oldValue && enabled)
        }
    }
    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Self.prefix + "enabled")
            activationChanged(from: unlocked && oldValue)
        }
    }
    var timeOfDay: TimeOfDay {
        didSet { defaults.set(timeOfDay.rawValue, forKey: Self.prefix + "timeOfDay") }
    }
    var page0Style: Page0Style {
        didSet { defaults.set(page0Style.rawValue, forKey: Self.prefix + "page0Style") }
    }
    var sound: Bool {
        didSet {
            defaults.set(sound, forKey: Self.prefix + "sound")
            #if os(iOS)
            NotificationCenter.default.post(name: .tutuSkinSoundChanged, object: nil)
            #endif
        }
    }
    var crackOnShake: Bool {
        didSet { defaults.set(crackOnShake, forKey: Self.prefix + "crackOnShake") }
    }

    var active: Bool {
        #if os(iOS)
        unlocked && enabled
        #else
        false
        #endif
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        unlocked = defaults.bool(forKey: Self.prefix + "unlocked")
        enabled = defaults.bool(forKey: Self.prefix + "enabled")
        timeOfDay = defaults.string(forKey: Self.prefix + "timeOfDay").flatMap(TimeOfDay.init(rawValue:)) ?? .now
        page0Style = defaults.string(forKey: Self.prefix + "page0Style").flatMap(Page0Style.init(rawValue:)) ?? .paper
        sound = defaults.object(forKey: Self.prefix + "sound") as? Bool ?? true
        crackOnShake = defaults.object(forKey: Self.prefix + "crackOnShake") as? Bool ?? true
        #if os(iOS)
        wuWallpaper = defaults.string(forKey: Self.prefix + "wuWallpaper").flatMap(WuWallpaper.init(rawValue:)) ?? .folds
        TutuUnlockBaked.activationChanged(active: active)
        #endif
    }

    func unlock() {
        unlocked = true
        enabled = true
        replayUnlockAnimation()
    }

    func replayUnlockAnimation() {
        print("[TutuSkin] play unlock animation requested")
        NotificationCenter.default.post(name: .tutuSkinPlayUnlockAnimation, object: nil)
    }

    #if os(iOS)
    func page0IsOpen(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard defaults.string(forKey: Self.prefix + "page0Day") == Self.page0DayKey(at: date, calendar: calendar) else {
            defaults.removeObject(forKey: Self.prefix + "page0Open")
            defaults.removeObject(forKey: Self.prefix + "page0Day")
            return false
        }
        return defaults.bool(forKey: Self.prefix + "page0Open")
    }

    func setPage0Open(_ open: Bool, at date: Date = Date(), calendar: Calendar = .current) {
        defaults.set(open, forKey: Self.prefix + "page0Open")
        defaults.set(Self.page0DayKey(at: date, calendar: calendar), forKey: Self.prefix + "page0Day")
    }

    static func page0DayKey(at date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-5 * 3600))
        return "\(day.year!)-\(day.month!)-\(day.day!)"
    }

    static func nextPage0Reset(after date: Date, calendar: Calendar = .current) -> Date {
        // dayKey subtracts five absolute hours before reading the local date, including DST.
        let shifted = date.addingTimeInterval(-5 * 3600)
        let midnight = calendar.startOfDay(for: shifted)
        return calendar.date(byAdding: .day, value: 1, to: midnight)!.addingTimeInterval(5 * 3600)
    }
    #endif

    func reset() {
        timeOfDay = .now
        sound = true
        crackOnShake = true
        for key in ["timeOfDay", "sound", "crackOnShake"] {
            defaults.removeObject(forKey: Self.prefix + key)
        }
        #if os(iOS)
        for key in ["page0Open", "page0Day"] {
            defaults.removeObject(forKey: Self.prefix + key)
        }
        NotificationCenter.default.post(name: Notification.Name("tutuPage0Reset"), object: nil)
        #endif
    }

    private func activationChanged(from previous: Bool) {
        guard previous != active else { return }
        #if os(iOS)
        TutuUnlockBaked.activationChanged(active: active)
        #endif
        NotificationCenter.default.post(name: .tutuSkinActivationChanged, object: nil)
    }
}
#endif
