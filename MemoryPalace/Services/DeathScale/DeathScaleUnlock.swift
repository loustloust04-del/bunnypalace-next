#if PERSONAL_APPS
import Foundation

extension Notification.Name {
    static let deathScaleUnlock = Notification.Name("deathScaleUnlock")
}

/// 暗号（plan-death-scale §4.2）：整句比较，大小写 / 重音 / 多余空白都不算数
enum DeathScaleUnlock {
    static let phrase = "/susuos Mort sans sépulture"

    private static let target = normalize(phrase)

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func matches(_ text: String) -> Bool { normalize(text) == target }

    static func post() {
        NotificationCenter.default.post(name: .deathScaleUnlock, object: nil)
    }
}
#endif
