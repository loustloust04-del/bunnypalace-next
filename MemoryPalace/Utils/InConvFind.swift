import SwiftUI

/// 对话内查找（plan-chat-find）的纯逻辑层：解析 + 后台过滤。不碰 SwiftData，快照由 VM 在主线程取
enum InConvFind {
    /// 一条命中（按路径从旧到新排）。列表模式要的片段 / 日期后台一起算好
    struct Hit: Identifiable, Equatable, Sendable {
        let id: String
        let isUser: Bool
        let excerpt: String
        let date: Date?
    }

    struct Item: Sendable {
        let id: String
        let isUser: Bool
        let content: String
        let date: Date?
    }

    struct Result: Sendable {
        let hits: [Hit]
        let terms: [String]
        let note: String?
    }

    /// 普通词（多词 AND）+ `by:我` / `by:助手`（中文冒号也认）；其他条件一律报不支持
    static func parse(_ raw: String) -> (words: [String], author: MacSearchFilters.Author, note: String?) {
        let text = raw.replacingOccurrences(of: #"(^|\s)([A-Za-z][A-Za-z_-]*)："#, with: "$1$2:", options: .regularExpression)
        for t in MacSearchQuery.lex(text).tokens where !t.quoted {
            guard let m = t.value.firstMatch(of: /^([a-zA-Z][a-zA-Z_-]*):(.*)$/),
                  t.value.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) == nil else { continue }
            if String(m.1).lowercased() != "by" { return ([], .all, "对话内只支持 by:") }
        }
        let parsed = MacSearchQuery.parse(text)
        if let error = parsed.errors.first { return ([], .all, error) }
        return (parsed.words, parsed.filters.author, nil)
    }

    /// 对话内查找的高亮底色（薄荷，禁黄）
    static var highlightColor: Color { Theme.branchIndicator.opacity(0.45) }

    /// 纯 Text 用：按 MacSearchQuery.hitRanges 同一套规则（不分大小写 / 全半角）给命中的词上底色
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        for r in MacSearchQuery.hitRanges(in: text, words: terms) {
            guard let lower = AttributedString.Index(r.lowerBound, within: attributed),
                  let upper = AttributedString.Index(r.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = highlightColor
        }
        return attributed
    }

    /// 搜清洗后的正文（和气泡显示同一份 ContentCleaner 缓存键），避免「计数有、看不见」
    static func run(_ raw: String, items: [Item]) -> Result {
        let q = parse(raw)
        if let note = q.note { return Result(hits: [], terms: [], note: note) }
        guard !q.words.isEmpty || q.author != .all else { return Result(hits: [], terms: [], note: nil) }
        var hits: [Hit] = []
        for item in items {
            if q.author == .me && !item.isUser { continue }
            if q.author == .assistant && item.isUser { continue }
            // 思考链在气泡里是折叠的，和气泡同口径剥掉（CardFlowView / BubbleModeRow 都是 clean → extractThinking）
            let text = ContentCleaner.visibleText(item.content, isUser: item.isUser, cacheKey: "\(item.id)_\(item.content.count)")
            guard q.words.allSatisfy({ MacSearchQuery.contains(text, $0) }) else { continue }
            hits.append(Hit(id: item.id, isUser: item.isUser,
                            excerpt: MacSearchQuery.excerpt(text, words: q.words), date: item.date))
        }
        return Result(hits: hits, terms: q.words, note: nil)
    }
}
