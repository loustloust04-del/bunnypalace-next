import Foundation

/// Cleans ChatGPT's internal annotation markers from message content.
/// ChatGPT uses Unicode Private Use Area characters (U+E200–U+E206) as delimiters
/// for inline citations, entity annotations, navigation lists, etc.
enum ContentCleaner {

    /// Cache cleaned results to avoid repeated regex work on re-renders
    private static let cache = NSCache<NSString, NSString>()

    /// Clean all ChatGPT annotation artifacts from text
    /// - Parameter cached: false = 不读不写缓存（S5 索引回填一次扫几万条，别把缓存冲掉）
    static func clean(_ text: String, cacheKey: String? = nil, cached useCache: Bool = true) -> String {
        // Check cache first
        let key = (cacheKey ?? String(text.hashValue)) as NSString
        if useCache, let cached = cache.object(forKey: key) {
            return cached as String
        }

        // Fast path: skip cleaning if no PUA characters or annotation markers present
        let hasPUA = text.unicodeScalars.contains(where: { $0.value >= 0xE200 && $0.value <= 0xE206 })
        let hasDagger = text.contains("†")
        let hasTurnRef = text.contains("【turn")
        if !hasPUA && !hasDagger && !hasTurnRef {
            if useCache { cache.setObject(text as NSString, forKey: key) }
            return text
        }

        var result = text

        // 1. Entity annotations → extract just the name
        if hasPUA {
            result = replaceEntities(in: result)
            result = stripPUABlocks(in: result)
            // Clean stray PUA characters
            for scalar in ["\u{E200}", "\u{E201}", "\u{E202}", "\u{E203}", "\u{E204}", "\u{E205}", "\u{E206}"] {
                result = result.replacingOccurrences(of: scalar, with: "")
            }
        }

        // 2. Remove dagger file-line references: 【23†L216-L220】
        if hasDagger {
            result = result.replacingOccurrences(
                of: "【\\d+†[^】]*】",
                with: "",
                options: .regularExpression
            )
        }

        // 3. Remove fullwidth-bracket turn references: 【turn0finance2】
        if hasTurnRef {
            result = result.replacingOccurrences(
                of: "【turn\\d+\\w+\\d+】",
                with: "",
                options: .regularExpression
            )
        }

        if useCache { cache.setObject(result as NSString, forKey: key) }
        return result
    }

    /// 看得见的文字：清洗后，非 user 再剥思考链（气泡折叠思考链）。对话内查找与 S5 全文索引同一口径
    static func visibleText(_ content: String, isUser: Bool, cacheKey: String? = nil, cached: Bool = true) -> String {
        let cleaned = clean(content, cacheKey: cacheKey, cached: cached)
        return isUser ? cleaned : extractThinking(from: cleaned).content
    }

    // MARK: - Entity Handling

    /// \u{E200}entity\u{E202}["category","Name","desc"]\u{E201} → Name
    private static func replaceEntities(in text: String) -> String {
        let open = "\u{E200}"
        let close = "\u{E201}"
        let sep = "\u{E202}"
        let prefix = "\(open)entity\(sep)"

        var result = text
        while let startRange = result.range(of: prefix) {
            guard let endRange = result.range(of: close, range: startRange.upperBound..<result.endIndex) else {
                break
            }
            let payload = String(result[startRange.upperBound..<endRange.lowerBound])
            let name = extractEntityName(from: payload)
            result.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: name)
        }
        return result
    }

    /// Parse ["category","Name","disambiguation"] → "Name"
    private static func extractEntityName(from payload: String) -> String {
        if let data = payload.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
           arr.count >= 2, let name = arr[1] as? String {
            return name
        }
        if let data = "[\(payload)]".data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
           arr.count >= 2, let name = arr[1] as? String {
            return name
        }
        return payload.replacingOccurrences(of: "\"", with: "")
    }

    // MARK: - Thinking Block Extraction

    struct ThinkingResult {
        let content: String    // Main content with thinking blocks removed
        let thinking: String?  // Extracted thinking text (nil if none)
    }

    /// Match [thinking]...[/thinking] (case insensitive, multiline)
    private static let thinkingRegex = try? NSRegularExpression(
        pattern: "\\[thinking\\]([\\s\\S]*?)\\[/thinking\\]", options: [.caseInsensitive])

    /// Extract [thinking]...[/thinking] blocks from Claude responses
    static func extractThinking(from text: String) -> ThinkingResult {
        // perf-flash O4：没有开标签就不可能匹配，直接返回；正则只编一次
        guard text.range(of: "[thinking]", options: .caseInsensitive) != nil, let regex = thinkingRegex else {
            return ThinkingResult(content: text, thinking: nil)
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        // Collect all thinking blocks
        var thinkingParts: [String] = []
        for match in matches {
            if match.numberOfRanges >= 2 {
                let thinkRange = match.range(at: 1)
                thinkingParts.append(nsText.substring(with: thinkRange).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // Remove thinking blocks from main content
        var cleaned = text
        for match in matches.reversed() {
            let range = Range(match.range, in: cleaned)!
            cleaned.removeSubrange(range)
        }
        // [Bunny patch BP-002] 流式中开了 [thinking] 还没收尾：尾巴当作进行中的思考，标签不原样露在气泡里
        if let open = cleaned.range(of: "[thinking]", options: .caseInsensitive) {
            let tail = cleaned[open.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { thinkingParts.append(tail) }
            cleaned = String(cleaned[..<open.lowerBound])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let thinking = thinkingParts.joined(separator: "\n\n")
        return ThinkingResult(content: cleaned, thinking: thinking.isEmpty ? nil : thinking)
    }

    // MARK: - PUA Block Removal

    /// Remove all PUA-wrapped blocks: \u{E200}...\u{E201}
    private static func stripPUABlocks(in text: String) -> String {
        let open = "\u{E200}"
        let close = "\u{E201}"

        var result = text
        while let startRange = result.range(of: open) {
            guard let endRange = result.range(of: close, range: startRange.upperBound..<result.endIndex) else {
                result.removeSubrange(startRange)
                break
            }
            result.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
        }
        return result
    }
}
