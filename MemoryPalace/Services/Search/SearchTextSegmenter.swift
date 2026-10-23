import Foundation

/// S5 全文索引的切词（索引与查询共用同一函数，D1）：
/// NFKC + 大小写折叠 → 汉字、假名前后加空格，让 unicode61 把它们逐字切成单字 token；
/// 拉丁 / 数字沿用 unicode61 的词边界。查询时整段当短语，末 token 走前缀。
enum SearchTextSegmenter {

    static func segment(_ text: String) -> String {
        // Foundation 的 precomposedStringWithCompatibilityMapping 不合成半角浊点（ｶﾞ → カ + U+3099），拆两步才是真 NFKC
        let normalized = text.utf8.allSatisfy { $0 < 0x80 } ? text
            : text.decomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping
        let folded = normalized.lowercased()
        var out = String.UnicodeScalarView()
        out.reserveCapacity(folded.unicodeScalars.count + 16)
        for scalar in folded.unicodeScalars {
            if isSplitScalar(scalar) {
                out.append(" ")
                out.append(scalar)
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// 一个搜索词 → FTS5 MATCH 表达式。整词当短语（汉字逐字相邻 = 连续子串），
    /// 末 token 加 `*` 前缀（拉丁 `swift` 命中 `swiftui`；汉字 token 本来就单字，加不加一样）。
    /// 没有任何 token 字符（纯 emoji / 标点）→ nil，调用方退回旧扫描。
    static func ftsQuery(for word: String) -> String? {
        let segmented = segment(word)
        guard segmented.unicodeScalars.contains(where: isTokenScalar) else { return nil }
        let body = segmented.replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return "\"\(body)\"*"
    }

    /// 与 unicode61 默认 `categories 'L* N* Co'` 一致：字母、数字、私用区是 token 字符，其余都是分隔符
    static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .privateUse:
            return true
        default:
            return false
        }
    }

    private static func isSplitScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x3000 { return false }
        if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) { return true }
        return scalar.properties.isIdeographic
    }
}
