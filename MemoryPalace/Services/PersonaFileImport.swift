import Foundation

enum PersonaFileImport {
    enum ImportError: LocalizedError {
        case notUTF8
        case empty

        var errorDescription: String? {
            switch self {
            case .notUTF8: return "不是 UTF-8 文本"
            case .empty: return "文件是空的"
            }
        }
    }

    static func text(from data: Data) throws -> String {
        guard let decoded = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }
        var text = decoded[...]
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else { throw ImportError.empty }
        let start = text[..<first].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        let end = text[last...].firstIndex(where: \.isNewline) ?? text.endIndex
        return String(text[start..<end])
    }
}
