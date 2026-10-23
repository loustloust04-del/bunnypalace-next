import Foundation

// MARK: - Resolved Entry (扫描命中的世界书条目)

struct ResolvedEntry {
    let content: String                                  // 宏替换后的注入内容
    let position: WorldBookEntry.InsertionPosition
    let depth: Int                                       // atDepth 用
    let insertionOrder: Int
    let role: String                                     // "system" | "user" | "assistant"
    let tokenCount: Int
    let isConstant: Bool                                 // 蓝灯常驻（稳定）vs 关键词触发（每轮可变）
}

// MARK: - World Book Scanner

struct WorldBookScanner {

    static let defaultScanDepth = 10

    /// 扫描世界书，返回命中的条目（已按 insertionOrder 排序，全部注入不截断）
    static func scan(
        worldBooks: [WorldBook],
        recentMessages: [String],
        profile: Profile,
        globalEntries: [WorldBookEntry] = []
    ) -> [ResolvedEntry] {

        // 1. 收集所有 enabled 条目（楼层世界书 + 全局世界书）；整本关掉的楼层书不参与（⑥）
        let floorEntries = worldBooks.filter(\.isEnabled).flatMap { $0.entries }
        let allEntries = (floorEntries + globalEntries).filter { $0.isEnabled && $0.position != .unsupported }
        guard !allEntries.isEmpty else { return [] }

        // 2. 分 constant / keyword 两组
        let constantEntries = allEntries.filter { $0.isConstant }
        let keywordEntries = allEntries.filter { !$0.isConstant }

        // 3. 关键词匹配
        var matchedEntries: [WorldBookEntry] = constantEntries

        if !keywordEntries.isEmpty {
            for entry in keywordEntries {
                let depth = max(0, entry.scanDepth ?? defaultScanDepth)
                let scanMessages = recentMessages.suffix(depth)
                let scanText = scanMessages.joined(separator: "\n")

                if matchesKeywords(entry: entry, text: scanText) {
                    matchedEntries.append(entry)
                }
            }
        }

        // 4. probability 过滤
        matchedEntries = matchedEntries.filter { entry in
            entry.useProbability == false || entry.probability >= 100 || Int.random(in: 1...100) <= entry.probability
        }

        // 5. 按 insertionOrder 排序
        matchedEntries.sort { $0.insertionOrder < $1.insertionOrder }

        // 6. 宏替换 + 构造 ResolvedEntry（不截断，全部注入）
        return matchedEntries.map { entry in
            let replaced = applyMacros(entry.content, profile: profile)
            return ResolvedEntry(
                content: replaced,
                position: entry.position,
                depth: entry.depth ?? 4,
                insertionOrder: entry.insertionOrder,
                role: "system",
                tokenCount: estimateTokens(replaced),
                isConstant: entry.isConstant
            )
        }
    }

    /// ⑥ 注入上限：先条数后 token。输入是 scan 的结果（已按 insertionOrder 排好），按这个顺序留前 maxEntries 条，
    /// 再按 token 预算逐条放（放不下的跳过，后面更小的还能进）；两个都是 0 = 不限，原样返回。
    static func limited(_ resolved: [ResolvedEntry], maxEntries: Int, tokenBudget: Int) -> [ResolvedEntry] {
        var kept = maxEntries > 0 ? Array(resolved.prefix(maxEntries)) : resolved
        if tokenBudget > 0 {
            var used = 0
            kept = kept.filter { entry in
                guard used + entry.tokenCount <= tokenBudget else { return false }
                used += entry.tokenCount
                return true
            }
        }
        return kept
    }

    // MARK: - Keyword Matching

    private static func matchesKeywords(entry: WorldBookEntry, text: String) -> Bool {
        guard !entry.keys.isEmpty else { return false }

        let compareText = entry.caseSensitive ? text : text.lowercased()

        // 主关键词：OR 逻辑，命中任一即可
        let primaryHit = entry.keys.contains { key in
            let compareKey = entry.caseSensitive ? key : key.lowercased()
            guard !compareKey.isEmpty else { return false }
            if entry.matchWholeWords {
                return matchWholeWord(compareKey, in: compareText)
            } else {
                return compareText.contains(compareKey)
            }
        }

        guard primaryHit else { return false }

        // 没有次关键词 → 直接通过
        if entry.selectiveEnabled == false || entry.secondaryKeys.isEmpty { return true }

        // 次关键词匹配
        let secondaryMatches = entry.secondaryKeys.map { key -> Bool in
            let compareKey = entry.caseSensitive ? key : key.lowercased()
            guard !compareKey.isEmpty else { return false }
            if entry.matchWholeWords {
                return matchWholeWord(compareKey, in: compareText)
            } else {
                return compareText.contains(compareKey)
            }
        }

        let anyMatch = secondaryMatches.contains(true)
        let allMatch = !secondaryMatches.contains(false)

        switch entry.selectiveLogic {
        case .andAny:  return anyMatch          // 至少一个次词命中
        case .andAll:  return allMatch          // 全部次词命中
        case .notAny:  return !anyMatch         // 无次词命中
        case .notAll:  return !allMatch         // 非全部次词命中
        }
    }

    /// 全词匹配：用 \b word boundary
    private static func matchWholeWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Helpers

    private static func applyMacros(_ text: String, profile: Profile) -> String {
        MacroExpander.expand(text, userName: profile.userName, charName: profile.assistantName)
    }

    /// 粗算 token（和 Memory.estimateTokens 同一算法）
    private static func estimateTokens(_ text: String) -> Int {
        var count = 0
        for char in text {
            if char.isASCII {
                if char == " " { count += 1 }
            } else {
                count += 2
            }
        }
        return max(count, 1)
    }
}
