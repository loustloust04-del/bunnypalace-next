#if PERSONAL_APPS
import Foundation

extension Notification.Name {
    static let tutuSkinUnlock = Notification.Name("tutuSkinUnlock")
    static let tutuSkinPlayUnlockAnimation = Notification.Name("tutuSkinPlayUnlockAnimation")
    static let tutuSkinActivationChanged = Notification.Name("tutuSkinActivationChanged")
    static let tutuSkinSoundChanged = Notification.Name("tutuSkinSoundChanged")
}

enum TutuSkinUnlock {
    static let phrase = "/caelumbunny"
    private static let target = normalize(phrase)

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func matches(_ text: String) -> Bool { normalize(text) == target }

    static func isHidden(_ text: String) -> Bool {
        let normalized = normalize(text)
        return normalized.contains("caelumbunny") || normalized.contains("tutuskin") || normalized.contains("兔兔")
    }

    static func post() {
        NotificationCenter.default.post(name: .tutuSkinUnlock, object: nil)
    }
}
#endif
