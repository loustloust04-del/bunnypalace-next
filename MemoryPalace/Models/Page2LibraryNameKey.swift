import Foundation

struct Page2LibraryNameKey: Comparable {
    let latin: String
    let section: Character
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ#")

    init(_ name: String) {
        let translated = name.applyingTransform(.toLatin, reverse: false) ?? name
        latin = translated.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
            .uppercased().components(separatedBy: .whitespacesAndNewlines).joined()
        section = latin.first.flatMap { "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains($0) ? $0 : nil } ?? "#"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.section != rhs.section {
            if lhs.section == "#" { return false }
            if rhs.section == "#" { return true }
            return lhs.section < rhs.section
        }
        let result = lhs.latin.compare(rhs.latin, options: [.numeric], locale: Locale(identifier: "en_US_POSIX"))
        return result == .orderedSame ? lhs.latin < rhs.latin : result == .orderedAscending
    }
}
