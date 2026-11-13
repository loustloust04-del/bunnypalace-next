import Foundation
import NaturalLanguage

/// Durable identity: display names are deliberately not part of the key.
public struct RecallSourceRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case page, card, fragment }
    public let profileId: String
    public var conversationId: String = ""
    public let kind: Kind
    public let path: String
    public let version: String

    public init(profileId: String, conversationId: String = "", kind: Kind, path: String, version: String) {
        self.profileId = profileId
        self.conversationId = conversationId
        self.kind = kind
        self.path = path
        self.version = version
    }
}
/// System word segmentation, not a topic/entity/synonym vocabulary.
public enum RecallLexical {
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    public static func tokens(_ text: String, tuning: RecallTuning) -> Set<String> {
        let text = normalized(text)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let han = letters.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
            if letters.count >= (han ? tuning.minimumHanTermLength : tuning.minimumLatinTermLength) { result.insert(token) }
            return true
        }
        return result
    }

    public static func meaningfulLength(_ text: String) -> Int {
        normalized(text).unicodeScalars.lazy.filter {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
            default: false
            }
        }.count
    }

    /// 时间指示语法
    /// 封闭类时间指示语是回溯语言操作符，不是主题词表；只参与回溯语法，
    /// 不参与候选相关性、保持或解冻。后缀约束避免把“昨天气球”当成回溯请求。
    public static func retrospective(_ text: String) -> Bool {
        let text = normalized(text)
        if explicitSource(text) { return true }
        if text.range(of: #"(?:刚才|刚刚|今早|昨天|前天|去年|上周[一二三四五六日天]?|上个月|昨晚)(?:呢|的|说|发生|聊|做|记|\s|[?？]|$)"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"(?:还)?记得(?:吗|不|我|你|我们|之前|以前)|(?:之前|以前|上次|当时|过去).*(?:说|聊|提|记|问|发生|怎样|什么|呢)|(?:我|你|我们).*(?:说过|提过|聊过)|(?:what|when|where|do you remember).*(?:said|before|last|remember)|(?:remember|recall)\s+(?:when|what|our|the)"#, options: .regularExpression) != nil { return true }
        // Validate calendar dates rather than allowing arbitrary digit-shaped strings through.
        let pattern = #"(?<!\d)(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})(?:日)?(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).contains { match in
            let values = (1...3).compactMap { Int(ns.substring(with: match.range(at: $0))) }
            guard values.count == 3 else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: values[0], month: values[1], day: values[2])
            guard let date = calendar.date(from: components) else { return false }
            let actual = calendar.dateComponents([.year, .month, .day], from: date)
            return actual.year == values[0] && actual.month == values[1] && actual.day == values[2]
        }
    }

    /// One parser supplies both the short-input gate and exact source targeting.
    /// Prefix boundaries prevent “网页:” or “resource:” from impersonating a source operator.
    private static let sourceReferencePattern = try! NSRegularExpression(
        pattern: #"\[\[([^\]\n]+)\]\]|(?<![\p{L}\p{N}_/])(?:memory/wiki/([^\s\[\]，。！？；、,!?;]+)\.md(?=$|[\s\[\]，。！？；、,!?;])|(?:source|来源|页|fragment|碎片):\s*([^\s\[\]，。！？；、,!?;]+))"#
    )

    private static func sourceReferences(in text: String) -> [String] {
        let text = normalized(text)
        let ns = text as NSString
        return sourceReferencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound })
                .map { ns.substring(with: match.range(at: $0)) }
        }
    }

    public static func explicitSource(_ text: String) -> Bool {
        !sourceReferences(in: text).isEmpty
    }

    public static func names(_ identities: [String], in text: String, tuning: RecallTuning) -> Bool {
        guard !identities.isEmpty else { return false }
        let text = normalized(text)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var starts = Set<String.Index>()
        var ends = Set<String.Index>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.insert(range.lowerBound)
            ends.insert(range.upperBound)
            return true
        }
        var joinedNames: [Range<String.Index>]?
        func nameRanges() -> [Range<String.Index>] {
            if let joinedNames { return joinedNames }
            let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
            tagger.string = text
            var ranges: [Range<String.Index>] = []
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameTypeOrLexicalClass,
                                 options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
                if (tag == .personalName || tag == .placeName || tag == .organizationName),
                   starts.contains(range.lowerBound), ends.contains(range.upperBound) { ranges.append(range) }
                return true
            }
            joinedNames = ranges
            return ranges
        }
        return identities.contains { identity in
            let identity = normalized(identity).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identity.isEmpty else { return false }
            // Latin identities require word boundaries: “art” must not match “party”.
            if identity.unicodeScalars.allSatisfy({ $0.isASCII }) {
                let escaped = NSRegularExpression.escapedPattern(for: identity)
                return text.range(of: "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])", options: .regularExpression) != nil
            }
            let hanCount = identity.unicodeScalars.lazy.filter {
                CharacterSet.letters.contains($0)
                    && ((0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value))
            }.count
            guard hanCount == 0 || hanCount >= tuning.minimumHanTermLength else { return false }
            var remaining = text.startIndex..<text.endIndex
            while let range = text.range(of: identity, range: remaining) {
                if starts.contains(range.lowerBound), ends.contains(range.upperBound) {
                    // 分词会拆开复合名（山田／屋）；系统合名范围内部不算独立身份。
                    if !nameRanges().contains(where: { $0 != range && $0.overlaps(range) }) { return true }
                }
                remaining = range.upperBound..<text.endIndex
            }
            return false
        }
    }

    public static func targets(_ source: RecallSourceRef, in text: String) -> Bool {
        sourceReferences(in: text).contains(normalized(source.path))
    }
}
