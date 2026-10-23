#if PERSONAL_APPS
import Foundation

/// 界面上的法文 + 时间格式（东八区，精确到秒）
enum DeathScaleText {
    static let sideName: [DeathScale.Side: String] = [.die: "POUR MOURIR", .live: "POUR VIVRE"]
    static let sideSymbol: [DeathScale.Side: String] = [.die: "†", .live: "✿"]
    static let hourSymbol = "☾"

    struct Segment: Equatable {
        var text: String
        var italic = false
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = DeathScaleTime.timeZone
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = DeathScaleTime.timeZone
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = DeathScaleTime.timeZone
        f.dateFormat = "dd.MM.yyyy · HH:mm:ss"
        f.isLenient = false
        return f
    }()

    static func hms(_ date: Date) -> String { clock.string(from: date) }

    /// 读回 `DeathScaleTime.format` 的写法；中点前后空白随意
    static func parse(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "·" || $0.isWhitespace }).map(String.init)
        guard parts.count == 2 else { return nil }
        return full.date(from: parts[0] + " · " + parts[1])
    }

    static func duration(_ seconds: TimeInterval) -> String {
        var s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        s -= h * 3600
        let m = s / 60
        s -= m * 60
        var out = ""
        if h > 0 { out += "\(h) h " }
        if h > 0 || m > 0 { out += (h > 0 ? String(format: "%02d", m) : String(m)) + " min " }
        out += (h > 0 || m > 0 ? String(format: "%02d", s) : String(s)) + " s"
        return out
    }

    /// 账簿里存的时段是 `起 – 止`（止可能是 `…`）；同一天就只写一次日期
    static func span(_ stored: String) -> String {
        let halves = stored.components(separatedBy: " – ")
        guard halves.count == 2, let start = parse(halves[0]) else { return stored }
        guard let end = parse(halves[1]) else { return DeathScaleTime.format(start) + " → …" }
        let tail = day.string(from: start) == day.string(from: end) ? hms(end) : DeathScaleTime.format(end)
        return DeathScaleTime.format(start) + " → " + tail
    }

    static func roman(_ text: String?) -> String {
        guard let text, let w = Int(text) else { return text ?? "" }
        return DeathScaleScene.roman(w)
    }

    static func symbol(_ entry: DeathScale.LedgerEntry) -> String {
        entry.side.flatMap { sideSymbol[$0] } ?? hourSymbol
    }

    static func ledger(_ e: DeathScale.LedgerEntry) -> [Segment] {
        let quoted = "« \(e.text ?? "") »"
        switch e.kind {
        case .add:
            return [Segment(text: "posé", italic: true), Segment(text: " \(quoted) · \(roman(e.to))")]
        case .remove:
            return [Segment(text: "retiré", italic: true), Segment(text: " \(quoted) · \(roman(e.from))")]
        case .weight:
            return [Segment(text: "\(quoted) \(roman(e.from)) → \(roman(e.to))")]
        case .text:
            return [Segment(text: "« \(e.from ?? "") » "), Segment(text: "devient", italic: true), Segment(text: " « \(e.to ?? "") »")]
        case .hourOpen:
            return [Segment(text: "l’heure vient", italic: true), Segment(text: " · \(hms(e.at))")]
        case .hourClose:
            let start = e.from.flatMap(parse), end = e.to.flatMap(parse)
            guard let start, let end else { return [Segment(text: "l’heure passe", italic: true)] }
            return [Segment(text: "l’heure passe", italic: true), Segment(text: " · \(hms(start)) → \(hms(end)) · \(duration(end.timeIntervalSince(start)))")]
        case .hourEdit:
            if let from = e.from {
                return [Segment(text: "l’heure corrigée", italic: true), Segment(text: " · \(span(from)) ⟶ \(span(e.to ?? ""))")]
            }
            return [Segment(text: "l’heure ajoutée", italic: true), Segment(text: " · \(span(e.to ?? ""))")]
        case .hourDelete:
            return [Segment(text: "l’heure effacée", italic: true), Segment(text: " · \(span(e.from ?? ""))")]
        }
    }
}
#endif
