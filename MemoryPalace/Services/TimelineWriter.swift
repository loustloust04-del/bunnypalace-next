import Foundation

/// A4 主调写手（plan-memory-c2c3-v2 第 7 段 + rev5 §3）：只喂一天的 A2 标题清单 + 日期，不带人设；
/// 只交 `{"headline":"≤40 字","topics":["1–3 个话题词"]}`。topics 坏了只丢 topics，主调照收
enum TimelineWriter {

    struct Draft: Equatable {
        var headline: String
        var topics: [String]
    }

    static let maxTopics = 3
    static let topicMaxChars = 16

    // MARK: - 提示词

    static let systemPrompt = """
    这是一天的聊天话题列表（每行一段聊天的标题，按时间先后）。用一句话概括这一天整体是什么样的，不超过 \(TimelineStore.headlineLimit) 字；再挑 1–3 个这一天的话题词（几个字的名词或短语）。
    只写发生了什么，不写感受和评价；不写技术报错、重试；不出现「用户」「AI」「助手」「人类」这类称呼。
    只输出一个 JSON，不加别的字：{"headline":"那一句话","topics":["话题词"]}
    """

    static func userContent(date: String, titles: [String]) -> String {
        ([date] + titles).joined(separator: "\n")
    }

    // MARK: - 解析

    /// 纯函数：主调拿得到 → Draft（超 40 字截到 40 字、记日志）；拿不到 → nil。
    /// 先按 JSON 读；JSON 坏了按字面捞 "headline"；整个没给 JSON（本机小模型常这样）就把第一行当主调
    static func parse(_ raw: String) -> Draft? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = t.range(of: "<think>") {
            guard let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) else { return nil }
            t = (String(t[..<open.lowerBound]) + String(t[close.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headline: String?
        var topicsRaw: Any?
        if let object = FragmentPool.strictObjectText(t),
           let dict = (try? JSONSerialization.jsonObject(with: Data(object.utf8))) as? [String: Any] {
            headline = dict["headline"] as? String
            topicsRaw = dict["topics"]
        } else if t.contains("\"headline\"") {
            headline = captured(#""headline"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: t).flatMap(unescaped)
            topicsRaw = captured(#""topics"\s*:\s*(\[[^\]]*\])"#, in: t).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        } else if !t.contains("{") {
            headline = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        } else {
            headline = nil
        }
        guard var h = headline.map(clean), !h.isEmpty else { return nil }
        if h.count > TimelineStore.headlineLimit {
            CacheDiagLog.shared.log("📝 时间轴: 主调 \(h.count) 字，截到 \(TimelineStore.headlineLimit) 字")
            h = String(h.prefix(TimelineStore.headlineLimit))
        }
        return Draft(headline: h, topics: topics(topicsRaw))
    }

    /// 话题词：只收字符串数组里的、去空、去重、每个不超过 topicMaxChars 字，最多 3 个；不是数组 = 丢掉，主调不受影响
    static func topics(_ raw: Any?) -> [String] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else {
            CacheDiagLog.shared.log("📝 时间轴: topics 不是数组，只丢 topics")
            return []
        }
        var out: [String] = []
        for case let s as String in list {
            let w = clean(s)
            guard !w.isEmpty, w.count <= topicMaxChars, !out.contains(w) else { continue }
            out.append(w)
        }
        if out.count > maxTopics { CacheDiagLog.shared.log("📝 时间轴: topics 给了 \(out.count) 个，留前 \(maxTopics) 个") }
        return Array(out.prefix(maxTopics))
    }

    private static func clean(_ s: String) -> String {
        var t = SessionSummaryStore.oneLine(s)
        for (a, b) in [("\"", "\""), ("「", "」"), ("“", "”"), ("'", "'")] where t.count >= 2 && t.hasPrefix(a) && t.hasSuffix(b) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func captured(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func unescaped(_ s: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data("\"\(s)\"".utf8), options: .fragmentsAllowed)) as? String ?? s
    }

    // MARK: - 执行

    /// 调一次（不重写：一天一次调用）。nil = 预算闸 / 开关 / 空输出跳过；主调拿不到抛 `.format`
    static func write(date: String, titles: [String], caller: SessionSegmentWriter.Caller) async throws -> Draft? {
        guard let raw = try await caller(systemPrompt, userContent(date: date, titles: titles)) else { return nil }
        guard let draft = parse(raw) else {
            CacheDiagLog.shared.log("📝 时间轴: ❌ \(date) 没拿到主调，不存")
            throw MemoryWriterError.format("没拿到主调")
        }
        return draft
    }
}

// MARK: - 骨架（代码拼，零模型）

/// 读已经落盘的 A2 段（正式段 + 尾段），按段内主线消息的时间把它列到碰到的每一个记忆日（A2 段本身不拆、不改）；
/// 没压成 A2 的那截列「（N 条，没压缩）」；老收尾段 / 第 0 段盖的消息不列（那几天留老条目）。
/// 段自带的待续（`SessionSegment.pending`）顺手收出来，交给待续本子（不调模型）
enum TimelineSkeleton {
    struct Message: Equatable {
        let id: String
        let date: Date?
    }

    struct Window {
        let conversationId: String
        let title: String
        /// 主线 user / assistant，按时间
        let messages: [Message]
        /// sessions/ 里这个窗口的 A2（没有 = nil）
        let summary: SessionSummary?
        /// sessions/ 读不了 / 格式对不上（`loadStrict` 抛了）：这个窗口碰到的日子一律不拼，原样留着
        var summaryError: String? = nil
    }

    /// 读窗口的结果：error 非空 = 整体没读全（对话列表 / 消息取不出），这一趟一天都不拼
    struct Source {
        var windows: [Window]
        var error: String? = nil
    }

    struct Day: Equatable {
        var items: [TimelineDayRecord.Item] = []
        /// 喂主调的 A2 标题（按时间先后，去重）
        var titles: [String] = []
        /// 在当前分支上找不到范围的段（标题）：按段自己的起止时间列、没有指针
        var unresolved: [String] = []
        /// 这天碰到、但 A2 读不了的窗口（窗口名）：这天不拼
        var failed: [String] = []
    }

    /// A2 段：正式段 + 尾段（尾段后来被整段重写，下次拼那天自然更新）；老收尾段 / 第 0 段不算
    static func isA2(_ seg: SessionSegment) -> Bool {
        seg.kind == .rolling || (seg.kind == .closeout && seg.isTail)
    }

    private struct Piece {
        var kind: TimelineDayRecord.Item.Kind
        var titles: [String]
        var label: String
        var first: Int?
        var last: Int?
        var start: Date
        var end: Date
        var from: String?
        var to: String?
        var continued: Bool
    }

    /// 纯函数（可测）：days = 要拼的记忆日（yyyy-MM-dd）
    static func build(_ windows: [Window], days: Set<String>, calendar: Calendar = .current) -> [String: Day] {
        var out: [String: Day] = [:]
        var pieces: [String: [String: [Piece]]] = [:]
        var titlesOf: [String: String] = [:]
        for w in windows {
            titlesOf[w.conversationId] = w.title
            let ids = w.messages.map(\.id), dates = w.messages.map(\.date)
            // 每条消息归哪天（没时间的跟着前后的走）
            var dayOf = [String?](repeating: nil, count: ids.count)
            for r in MemoryDay.split(dates, calendar: calendar) {
                let key = dates[r].lazy.compactMap { $0 }.first.map { MemoryDay.key($0, calendar: calendar) }
                for i in r { dayOf[i] = key }
            }
            let touched = Set(dayOf.compactMap { $0 }).intersection(days)
            if w.summaryError != nil {
                for d in touched { out[d, default: Day()].failed.append(w.title.isEmpty ? String(w.conversationId.prefix(8)) : w.title) }
                continue
            }
            let segs = w.summary?.segments ?? []
            var legacy = IndexSet(), a2 = IndexSet()
            for seg in segs where seg.kind == .legacy || (seg.kind == .closeout && !seg.isTail) {
                if let r = MemoryMigration.span(seg, ids: ids, dates: dates) { legacy.insert(integersIn: r) }
            }
            for seg in segs where isA2(seg) {
                guard let r = MemoryMigration.span(seg, ids: ids, dates: dates) else {
                    for (k, day) in dayKeys(from: seg.start, to: seg.end, calendar: calendar).enumerated() where days.contains(day) {
                        guard let lo = MemoryDay.date(ofKey: day, calendar: calendar).map({ MemoryDay.boundary(of: $0, calendar: calendar) }),
                              let next = calendar.date(byAdding: .day, value: 1, to: lo) else { continue }
                        pieces[day, default: [:]][w.conversationId, default: []].append(
                            Piece(kind: .segment, titles: [seg.title], label: seg.title, first: nil, last: nil,
                                  start: whole(max(seg.start, lo)), end: whole(min(seg.end, next.addingTimeInterval(-1))),
                                  from: nil, to: nil, continued: k > 0))
                        out[day, default: Day()].unresolved.append(seg.title)
                    }
                    continue
                }
                a2.insert(integersIn: r)
                for (k, part) in split(r, dates: dates, calendar: calendar).enumerated() {
                    guard let p = piece(part, dates: dates, calendar: calendar), days.contains(p.day) else { continue }
                    pieces[p.day, default: [:]][w.conversationId, default: []].append(
                        Piece(kind: .segment, titles: [seg.title], label: seg.title, first: part.lowerBound, last: part.upperBound - 1,
                              start: p.start, end: p.end, from: ids[part.lowerBound], to: ids[part.upperBound - 1], continued: k > 0))
                }
            }
            let short = ids.count <= MemoryMigration.shortWindowMax && !segs.contains(where: isA2)
            let uncovered = IndexSet(integersIn: 0..<ids.count).subtracting(a2).subtracting(legacy)
            for run in uncovered.rangeView {
                for part in split(run.lowerBound..<run.upperBound, dates: dates, calendar: calendar) {
                    guard let p = piece(part, dates: dates, calendar: calendar), days.contains(p.day) else { continue }
                    pieces[p.day, default: [:]][w.conversationId, default: []].append(
                        Piece(kind: short ? .short : .uncompressed, titles: [], label: "（\(part.count) 条，没压缩）",
                              first: part.lowerBound, last: part.upperBound - 1, start: p.start, end: p.end,
                              from: ids[part.lowerBound], to: ids[part.upperBound - 1], continued: false))
                }
            }
        }
        for (day, byWindow) in pieces {
            var d = out[day] ?? Day()
            var titled: [(start: Date, conv: String, titles: [String])] = []
            for (conv, list) in byWindow {
                for p in merged(list, calendar: calendar) {
                    d.items.append(TimelineDayRecord.Item(kind: p.kind, conversationId: conv, window: titlesOf[conv] ?? "",
                                                          title: p.label, start: p.start, end: p.end, from: p.from, to: p.to,
                                                          continued: p.continued))
                    if p.kind == .segment { titled.append((p.start, conv, p.titles)) }
                }
            }
            d.items.sort { ($0.start, $0.conversationId) < ($1.start, $1.conversationId) }
            for t in titled.sorted(by: { ($0.start, $0.conv) < ($1.start, $1.conv) }).flatMap(\.titles) where !t.isEmpty && !d.titles.contains(t) {
                d.titles.append(t)
            }
            out[day] = d
        }
        return out
    }

    /// 同一窗口、下标连着、同一时段的 A2 段合成一项（不跨时段、不把两个窗口合一）
    private static func merged(_ list: [Piece], calendar: Calendar) -> [Piece] {
        var out: [Piece] = []
        for p in list.sorted(by: { ($0.first ?? Int.max, $0.start) < ($1.first ?? Int.max, $1.start) }) {
            if var prev = out.last, prev.kind == .segment, p.kind == .segment, let pl = prev.last, let pf = p.first, pl + 1 == pf,
               TimelinePeriod.of(prev.start, calendar: calendar) == TimelinePeriod.of(p.start, calendar: calendar) {
                prev.titles += p.titles
                prev.label = prev.titles.joined(separator: "；")
                prev.last = p.last
                prev.end = p.end
                prev.to = p.to
                out[out.count - 1] = prev
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// 一截下标按记忆日切（没时间的消息跟着前后的走）
    private static func split(_ r: Range<Int>, dates: [Date?], calendar: Calendar) -> [Range<Int>] {
        MemoryDay.split(Array(dates[r]), calendar: calendar).map { (r.lowerBound + $0.lowerBound)..<(r.lowerBound + $0.upperBound) }
    }

    private static func piece(_ r: Range<Int>, dates: [Date?], calendar: Calendar) -> (day: String, start: Date, end: Date)? {
        let known = dates[r].compactMap { $0 }
        guard let first = known.first, let last = known.last else { return nil }
        return (MemoryDay.key(first, calendar: calendar), whole(first), whole(last))
    }

    /// 文件里的时间只到秒：拼的时候就取整，读回来才比得上
    private static func whole(_ d: Date) -> Date {
        Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
    }

    /// start 到 end 碰到的记忆日
    static func dayKeys(from start: Date, to end: Date, calendar: Calendar = .current) -> [String] {
        let first = MemoryDay.dayStart(start, calendar: calendar), last = MemoryDay.dayStart(max(start, end), calendar: calendar)
        var out: [String] = []
        var d = first
        while d <= last {
            out.append(MemoryDay.key(MemoryDay.boundary(of: d, calendar: calendar), calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
