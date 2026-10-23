import Foundation

/// 全局搜索（⌘K）的纯逻辑层：类型表、筛选、Query 语法、打分排序、日期文案。
/// 逐条照 `~/Downloads/mint-workspace-global-search.html` 的 JS（SEARCH_TYPES / OPTIONS / lexSearch /
/// parseSearchQuery / serializeSearch / runSearch / dateLabel / resultExcerpt）移植，不碰任何存储。
/// 偏离原型的只有两处：多一个 `coding`（编程会话，mac 独有），`in:workspace` 的文案叫「当前楼层」。
enum MacSearchKind: String, CaseIterable, Identifiable, Sendable {
    case chat, file, branch, sticker, assistant, worldbook, memory
    case health, library, twitter, note, coding

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "对话"
        case .file: "文件"
        case .branch: "分支"
        case .sticker: "贴纸"
        case .assistant: "助手模板"
        case .worldbook: "世界书"
        case .memory: "记忆"
        case .health: "健康"
        case .library: "书房"
        case .twitter: "推特"
        case .note: "便笺"
        case .coding: "编程会话"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .file: "doc.text"
        case .branch: "arrow.triangle.branch"
        case .sticker: "paintpalette"
        case .assistant: "person"
        case .worldbook: "books.vertical"
        case .memory: "brain"
        case .health: "heart"
        case .library: "book"
        case .twitter: "bird"
        case .note: "note.text"
        case .coding: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 原型有、但这边还没有数据源的类型：chip 保留，结果区说明「暂不支持」
    var isSupported: Bool { self != .note }
}

struct MacSearchFilters: Equatable, Sendable {
    enum Location: String, CaseIterable, Sendable { case all, workspace, current }
    enum Match: String, CaseIterable, Sendable { case any, title, content }
    enum Author: String, CaseIterable, Sendable { case all, me, assistant }
    enum Sort: String, CaseIterable, Sendable { case relevance, recent, oldest, az, za }

    var location: Location = .all
    var types: [MacSearchKind] = []
    var match: Match = .any
    /// all / today / custom / `<n>d`（原型 within: 允许任意天数）
    var period: String = "all"
    var after: String = ""
    var before: String = ""
    var author: Author = .all
    var sort: Sort = .relevance
    var extensions: [String] = []
    var starred = false

    static let periodOptions: [(String, String)] = [
        ("all", "全部"), ("today", "今天"), ("7d", "7 天"), ("30d", "30 天"), ("90d", "90 天"), ("custom", "自定义"),
    ]
    static let extensionOptions = ["md", "css", "txt", "json", "svg", "html", "pdf"]

    static func label(_ location: Location) -> String {
        switch location {
        case .all: "全局"
        case .workspace: "当前楼层"
        case .current: "当前对话"
        }
    }

    static func label(_ match: Match) -> String {
        switch match {
        case .any: "标题 + 内容"
        case .title: "仅标题"
        case .content: "仅内容"
        }
    }

    static func label(_ author: Author) -> String {
        switch author {
        case .all: "全部"
        case .me: "你"
        case .assistant: "助手"
        }
    }

    static func label(_ sort: Sort) -> String {
        switch sort {
        case .relevance: "相关度"
        case .recent: "最近"
        case .oldest: "最早"
        case .az: "A → Z"
        case .za: "Z → A"
        }
    }

    enum Key: String { case location, types, match, period, author, sort, extensions, starred }

    /// 原型 `activeSearchConditions()`：每个生效中的筛选一颗可移除的 chip
    var activeConditions: [(key: Key, label: String)] {
        var items: [(Key, String)] = []
        if location != .all { items.append((.location, Self.label(location))) }
        if !types.isEmpty { items.append((.types, types.map(\.label).joined(separator: "、"))) }
        if match != .any { items.append((.match, Self.label(match))) }
        if period != "all" && period != "custom" {
            items.append((.period, period == "today" ? "今天" : "近 \(Int(period.dropLast()) ?? 0) 天"))
        }
        if !after.isEmpty || !before.isEmpty {
            items.append((.period, "\(after.isEmpty ? "不限" : after) → \(before.isEmpty ? "不限" : before)"))
        }
        if author != .all { items.append((.author, "角色：" + Self.label(author))) }
        if !extensions.isEmpty { items.append((.extensions, extensions.map { "." + $0 }.joined(separator: " / "))) }
        if starred { items.append((.starred, "仅收藏")) }
        if sort != .relevance { items.append((.sort, Self.label(sort))) }
        return items
    }

    mutating func clear(_ key: Key) {
        let empty = MacSearchFilters()
        switch key {
        case .location: location = empty.location
        case .types: types = []
        case .match: match = empty.match
        case .period: period = "all"; after = ""; before = ""
        case .author: author = empty.author
        case .sort: sort = empty.sort
        case .extensions: extensions = []
        case .starred: starred = false
        }
    }

    /// 结果区右上角那行：「全局 · 全部类型 · 标题 + 内容」
    var scopeCaption: String {
        let typeCaption = types.isEmpty ? "全部类型" : types.map(\.label).joined(separator: " / ")
        return "\(Self.label(location)) · \(typeCaption) · \(Self.label(match))"
    }

    /// 原型 `validateSearchFilters`
    var validationErrors: [String] {
        var errors: [String] = []
        if !after.isEmpty && !MacSearchQuery.dateIsValid(after) { errors.append("起始日期应为有效的 YYYY-MM-DD。") }
        if !before.isEmpty && !MacSearchQuery.dateIsValid(before) { errors.append("结束日期应为有效的 YYYY-MM-DD。") }
        if !after.isEmpty && !before.isEmpty && after > before { errors.append("起始日期不能晚于结束日期。两个边界都包含当天。") }
        return errors
    }

    /// 原型 `dateBounds`：within 从今天零点往回数 n-1 天；after/before 都含当天
    func dateBounds(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date>? {
        var from = Date.distantPast
        var to = Date.distantFuture
        var bounded = false
        if period != "all" && period != "custom" {
            let days = period == "today" ? 1 : (Int(period.dropLast()) ?? 1)
            let start = calendar.startOfDay(for: now)
            from = calendar.date(byAdding: .day, value: -(days - 1), to: start) ?? start
            to = now
            bounded = true
        }
        if let a = MacSearchQuery.calendarDate(after, calendar: calendar) { from = a; bounded = true }
        if let b = MacSearchQuery.calendarDate(before, calendar: calendar),
           let next = calendar.date(byAdding: .day, value: 1, to: b) {
            to = next.addingTimeInterval(-0.001)
            bounded = true
        }
        guard bounded, from <= to else { return bounded ? from...from : nil }
        return from...to
    }
}

struct MacSearchParsed: Equatable {
    var words: [String]
    var filters: MacSearchFilters
    var errors: [String]
    var isValid: Bool { errors.isEmpty }
}

enum MacSearchQuery {
    static let keys = ["type", "in", "match", "by", "within", "after", "before", "ext", "sort", "is"]
    static let examples = ["薄荷 type:memory", "布局 type:file ext:md", "type:chat by:me within:7d"]

    private static let typeAlias: [String: String] = {
        var alias: [String: String] = [
        "chats": "chat", "files": "file", "branches": "branch", "stickers": "sticker", "template": "assistant",
        "templates": "assistant", "assistants": "assistant", "worldbooks": "worldbook", "memories": "memory",
        "notes": "note", "codes": "coding", "对话": "chat", "文件": "file", "分支": "branch", "贴纸": "sticker",
        "助手": "assistant", "助手模板": "assistant", "世界书": "worldbook", "记忆": "memory", "便笺": "note",
        "编程": "coding", "编程会话": "coding", "聊天": "chat",
        "健康": "health", "用药": "health", "meds": "health",
        "book": "library", "books": "library", "reading": "library", "audiobook": "library", "audiobooks": "library",
        "书房": "library", "书": "library", "读书": "library", "阅读": "library", "有声书": "library",
        "tweet": "twitter", "tweets": "twitter", "推特": "twitter", "推文": "twitter",
        ]
        return alias
    }()

    struct Token: Equatable { var value: String; var quoted: Bool }

    /// 原型 `lexSearch`：空白分词，双引号成短语，`\"` / `\\` 转义，最多 120 个
    static func lex(_ raw: String) -> (tokens: [Token], errors: [String]) {
        var tokens: [Token] = []
        var errors: [String] = []
        var value = ""
        var active = false
        var inQuote = false
        var wholeQuote = false
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "\\" {
                value.append(chars[i + 1]); active = true; i += 2; continue
            }
            if ch == "\"" {
                if !active { wholeQuote = true }
                active = true; inQuote.toggle(); i += 1; continue
            }
            if ch.isWhitespace && !inQuote {
                if active { tokens.append(Token(value: value, quoted: wholeQuote)); value = ""; active = false; wholeQuote = false }
                i += 1; continue
            }
            value.append(ch); active = true; i += 1
        }
        if active { tokens.append(Token(value: value, quoted: wholeQuote)) }
        if inQuote { errors.append("引号还没有闭合。短语请写成 \"quiet workspace\"。") }
        if tokens.count > 120 { errors.append("这条查询太长了，请保留不超过 120 个关键词或条件。") }
        return (Array(tokens.prefix(120)), errors)
    }

    static func quote(_ word: String) -> String {
        guard word.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "\"" || $0 == "\\" }) else { return word }
        return "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func dateIsValid(_ raw: String) -> Bool { calendarDate(raw) != nil }

    static func calendarDate(_ raw: String, calendar: Calendar = .current) -> Date? {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
        return date
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 原型 `parseSearchQuery`
    static func parse(_ raw: String) -> MacSearchParsed {
        let lexed = lex(raw)
        var errors = lexed.errors
        var f = MacSearchFilters()
        var words: [String] = []
        var seen = Set<String>()
        for t in lexed.tokens {
            let clause = t.quoted ? nil : t.value.firstMatch(of: /^([a-zA-Z][a-zA-Z_-]*):(.*)$/)
            guard let clause, t.value.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) == nil else {
                if !t.value.isEmpty { words.append(t.value) }
                continue
            }
            let key = String(clause.1).lowercased()
            let value = String(clause.2)
            let v = value.lowercased()
            guard keys.contains(key) else { errors.append("暂不支持 \(key):。可用条件：\(keys.joined(separator: "、"))。"); continue }
            guard !seen.contains(key) else { errors.append("\(key): 重复了。类型或格式的多个值请用逗号连接。"); continue }
            seen.insert(key)
            guard !value.isEmpty else { errors.append("\(key): 后面还需要一个值。"); continue }
            func invalid(_ hint: String) { errors.append("\(key):\(value) 无效；\(hint)。") }
            switch key {
            case "type":
                var values: [String] = []
                for x in v.split(separator: ",").map(String.init) {
                    let mapped = typeAlias[x] ?? x
                    if !values.contains(mapped) { values.append(mapped) }
                }
                if values.contains(where: { $0 != "all" && MacSearchKind(rawValue: $0) == nil }) {
                    invalid("使用 chat、file、branch、sticker、assistant、worldbook、memory、health、library、twitter、note、coding 或 all")
                } else {
                    f.types = values.contains("all") ? [] : values.compactMap(MacSearchKind.init(rawValue:))
                }
            case "in":
                let alias = ["global": "all", "project": "workspace", "floor": "workspace", "楼层": "workspace", "chat": "current"]
                if let loc = MacSearchFilters.Location(rawValue: alias[v] ?? v) { f.location = loc } else { invalid("使用 all、workspace 或 current") }
            case "match":
                let alias = ["all": "any", "both": "any", "body": "content"]
                if let m = MacSearchFilters.Match(rawValue: alias[v] ?? v) { f.match = m } else { invalid("使用 any、title 或 content") }
            case "by":
                let alias = ["user": "me", "you": "me", "ai": "assistant", "你": "me", "我": "me", "助手": "assistant"]
                if let a = MacSearchFilters.Author(rawValue: alias[v] ?? v) { f.author = a } else { invalid("使用 all、me 或 assistant") }
            case "within":
                if v == "today" {
                    f.period = "today"
                } else if v.hasSuffix("d"), let n = Int(v.dropLast()), (1...36500).contains(n), v.dropLast().allSatisfy(\.isNumber) {
                    f.period = "\(n)d"
                } else {
                    invalid("使用 today 或 7d 这样的天数")
                }
            case "after", "before":
                if !dateIsValid(value) { invalid("使用有效的 YYYY-MM-DD 日期") } else if key == "after" { f.after = value } else { f.before = value }
            case "ext":
                var values: [String] = []
                for x in v.split(separator: ",").map({ String($0.hasPrefix(".") ? $0.dropFirst() : $0) }) where !values.contains(x) {
                    values.append(x)
                }
                if values.contains(where: { $0.range(of: #"^[a-z0-9][a-z0-9_+-]{0,15}$"#, options: .regularExpression) == nil }) {
                    invalid("使用 md、pdf 或 md,pdf 这样的扩展名")
                } else {
                    f.extensions = values.contains("all") ? [] : values
                }
            case "sort":
                let alias = ["newest": "recent", "a-z": "az", "z-a": "za"]
                if let s = MacSearchFilters.Sort(rawValue: alias[v] ?? v) { f.sort = s } else { invalid("使用 relevance、recent、oldest、az 或 za") }
            case "is":
                if v != "starred" && v != "all" { invalid("使用 starred 或 all") } else { f.starred = v == "starred" }
            default:
                break
            }
        }
        if (!f.after.isEmpty || !f.before.isEmpty) && f.period != "all" {
            errors.append("within: 与 after:/before: 不能同时使用。请保留一种时间范围。")
        }
        if !f.after.isEmpty || !f.before.isEmpty { f.period = "custom" }
        errors.append(contentsOf: f.validationErrors)
        return MacSearchParsed(words: words, filters: f, errors: errors)
    }

    /// 原型 `serializeSearch`：筛选 ⇄ Query 文本共用一套条件
    static func serialize(words: [String], filters f: MacSearchFilters) -> String {
        var clauses = words.filter { !$0.isEmpty }.map(quote)
        if f.location != .all { clauses.append("in:\(f.location.rawValue)") }
        if !f.types.isEmpty { clauses.append("type:" + f.types.map(\.rawValue).joined(separator: ",")) }
        if f.match != .any { clauses.append("match:\(f.match.rawValue)") }
        if f.author != .all { clauses.append("by:\(f.author.rawValue)") }
        if f.period != "all" && f.period != "custom" { clauses.append("within:\(f.period)") }
        if !f.after.isEmpty { clauses.append("after:\(f.after)") }
        if !f.before.isEmpty { clauses.append("before:\(f.before)") }
        if !f.extensions.isEmpty { clauses.append("ext:" + f.extensions.joined(separator: ",")) }
        if f.starred { clauses.append("is:starred") }
        if f.sort != .relevance { clauses.append("sort:\(f.sort.rawValue)") }
        return clauses.joined(separator: " ")
    }

    // MARK: - 匹配 / 打分 / 排序（原型 runSearch）

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .widthInsensitive]) != nil
    }

    /// 每个词都要命中：match=title 只看标题、content 只看正文、any 两边任一
    static func matches(title: String, body: String, words: [String], match: MacSearchFilters.Match) -> Bool {
        words.allSatisfy { w in
            switch match {
            case .title: contains(title, w)
            case .content: contains(body, w)
            case .any: contains(title, w) || contains(body, w)
            }
        }
    }

    /// 标题命中每词 +3，正文命中每词 +2
    static func score(title: String, body: String, words: [String]) -> Int {
        words.reduce(0) { $0 + (contains(title, $1) ? 3 : 0) + (contains(body, $1) ? 2 : 0) }
    }

    private static let collator: (String, String) -> ComparisonResult = { a, b in
        a.compare(b, options: [.caseInsensitive, .numeric], range: nil, locale: Locale(identifier: "zh-CN"))
    }

    /// `items` 里每项给出 (id, title, updated, score)；返回排好序的下标
    static func order<T>(_ items: [T], sort: MacSearchFilters.Sort, hasWords: Bool,
                         id: (T) -> String, title: (T) -> String, updated: (T) -> Date?, score: (T) -> Int) -> [T] {
        items.sorted { a, b in
            let ua = updated(a) ?? .distantPast
            let ub = updated(b) ?? .distantPast
            switch sort {
            case .az, .za:
                let r = collator(title(a), title(b))
                if r != .orderedSame { return sort == .az ? r == .orderedAscending : r == .orderedDescending }
                return id(a) < id(b)
            case .oldest:
                if ua != ub { return ua < ub }
                return id(a) < id(b)
            case .relevance, .recent:
                if sort == .relevance && hasWords && score(a) != score(b) { return score(a) > score(b) }
                if ua != ub { return ua > ub }
                return id(a) < id(b)
            }
        }
    }

    /// 文本里所有词的命中区间（不重叠、从左到右；同一位置取最长的词），高亮上色由各端自己做
    static func hitRanges(in text: String, words: [String]) -> [Range<String.Index>] {
        let terms = Array(Set(words.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
        guard !terms.isEmpty else { return [] }
        var cursor = text.startIndex
        var ranges: [Range<String.Index>] = []
        while cursor < text.endIndex {
            var best: Range<String.Index>?
            for t in terms {
                if let r = text.range(of: t, options: [.caseInsensitive, .widthInsensitive], range: cursor..<text.endIndex),
                   best == nil || r.lowerBound < best!.lowerBound {
                    best = r
                }
            }
            guard let hit = best, !hit.isEmpty else { break }
            ranges.append(hit)
            cursor = hit.upperBound
        }
        return ranges
    }

    /// 原型 `resultExcerpt`：命中处往前留 17 字，截 130 字
    static func excerpt(_ body: String, words: [String]) -> String {
        let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var first: String.Index?
        for w in words {
            if let r = text.range(of: w, options: [.caseInsensitive, .widthInsensitive]) {
                if first == nil || r.lowerBound < first! { first = r.lowerBound }
            }
        }
        let offset = first.map { max(0, text.distance(from: text.startIndex, to: $0) - 17) } ?? 0
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: 130, limitedBy: text.endIndex) ?? text.endIndex
        return (offset > 0 ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")
    }

    /// 原型 `dateLabel`：刚刚 / 今天 / 昨天 / M月D日 / 跨年带年份
    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: now)
        if date >= start { return now.timeIntervalSince(date) < 600 ? "刚刚" : "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: start), date >= yesterday { return "昨天" }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = calendar.component(.year, from: now) != c.year ? "\(c.year ?? 0)/" : ""
        return "\(year)\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}
