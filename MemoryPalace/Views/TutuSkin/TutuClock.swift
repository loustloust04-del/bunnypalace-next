#if PERSONAL_APPS
#if os(iOS)
import Foundation

/// The three authored cathedral/intro endpoints, or the actual local wall clock.
enum TutuClock {
    static func hour(for timeOfDay: SkinState.TimeOfDay, at date: Date = Date(), calendar: Calendar = .current) -> Double {
        switch timeOfDay {
        case .day: return 13
        case .dusk: return 18.6
        case .night: return 23.6
        case .now:
            let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
            return Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
                + Double(components.second ?? 0) / 3600 + Double(components.nanosecond ?? 0) / 3_600_000_000_000
        }
    }
}
#endif
#endif
