import Foundation

public struct CatalogSearchPart: Equatable, Sendable {
    public var text: String
    public var isBody: Bool

    public init(text: String, isBody: Bool) {
        self.text = text
        self.isBody = isBody
    }
}

/// A 线文件的只读候选与全文入口；只读指定楼层根目录，不碰 SwiftData，不做关键词匹配或排序打分。
/// candidates 同步读盘，调用方负责放在后台，并按数据库中的窗口可见性过滤。
public enum CatalogALineReader {
    public enum Layer: String { case a4 = "A4", a3 = "A3", a2 = "A2" }

    public struct Hit: Equatable {
        public var layer: Layer
        /// nil = A4 一天一条（按日期引用，不属于哪个窗口）
        public var conversationId: String?
        /// 窗口标题（A4 一天一条 = 空）
        public var title: String
        public var start: Date
        public var end: Date
        /// 归哪天（05:00 日界）
        public var day: String
        /// A2 段号（有改造前累计摘要时它是第 0 段，没有就从 1 数）
        public var segment: Int?
        /// A2 盖的消息 [from, to)
        public var messages: Range<Int>?
        /// 展示与正文边界同源；标题、章节标签不计入原料。
        public var parts: [CatalogSearchPart]
        /// 旧格式是哪种；nil = 新格式
        public var old: String?
        public var keywords: [String] = []

        public var text: String { parts.map(\.text).joined() }
        public var bodyText: String { parts.filter(\.isBody).map(\.text).joined() }

        public init(layer: Layer, conversationId: String? = nil, title: String, start: Date, end: Date, day: String, segment: Int? = nil, messages: Range<Int>? = nil, parts: [CatalogSearchPart], old: String? = nil, keywords: [String] = []) {
            self.layer = layer
            self.conversationId = conversationId
            self.title = title
            self.start = start
            self.end = end
            self.day = day
            self.segment = segment
            self.messages = messages
            self.parts = parts
            self.old = old
            self.keywords = keywords
        }
    }

    public struct Result: Equatable {
        public var terms: [String]
        public var hits: [Hit]
        /// 检索适配层给出的各层命中总数
        public var found: [Layer: Int]
        public var truncated = false

        public func given(_ layer: Layer) -> Int { hits.filter { $0.layer == layer }.count }

        public init(terms: [String], hits: [Hit], found: [Layer: Int], truncated: Bool = false) {
            self.terms = terms
            self.hits = hits
            self.found = found
            self.truncated = truncated
        }
    }

    public struct Segment: Equatable {
        public var number: Int
        public var segment: SessionSegment

        public var old: String? { CatalogALineReader.oldKind(segment) }
        public var messages: Range<Int> { segment.from..<max(segment.from, segment.to) }
        public var parts: [CatalogSearchPart] { CatalogALineReader.segmentParts(segment) }
        public var text: String { CatalogALineReader.segmentText(segment) }

        public init(number: Int, segment: SessionSegment) {
            self.number = number
            self.segment = segment
        }
    }

    public struct Window: Equatable {
        public var conversationId: String
        public var title: String
        public var a3: SessionSegment?
        /// windows/ 里认不成 A3 的旧窗口总结（v4-1 抄本）里 A2 没有的那几段
        public var oldA3: [SessionSegment]
        public var segments: [Segment]

        public init(conversationId: String, title: String, a3: SessionSegment? = nil, oldA3: [SessionSegment], segments: [Segment]) {
            self.conversationId = conversationId
            self.title = title
            self.a3 = a3
            self.oldA3 = oldA3
            self.segments = segments
        }
    }

    public struct SegmentRead: Equatable {
        public var conversationId: String
        public var title: String
        public var segment: Segment
        public var count: Int

        public init(conversationId: String, title: String, segment: Segment, count: Int) {
            self.conversationId = conversationId
            self.title = title
            self.segment = segment
            self.count = count
        }
    }

    public static let gistLength = 40

    // MARK: - 入口

    public static func readWindow(_ conversationId: String, memoryRoot: URL, cancel: CatalogCancel = CatalogCancel()) async -> Window? {
        await cancel.withTaskCancellation {
            await Task.detached(priority: .utility) {
                window(conversationId, memoryRoot: memoryRoot, cancel: cancel)
            }.value
        }
    }

    public static func readSegment(_ conversationId: String, number: Int, memoryRoot: URL, cancel: CatalogCancel = CatalogCancel()) async -> SegmentRead? {
        await cancel.withTaskCancellation {
            await Task.detached(priority: .utility) {
                guard let w = window(conversationId, memoryRoot: memoryRoot, cancel: cancel),
                      !cancel.isCancelled, let s = w.segments.first(where: { $0.number == number }) else { return nil }
                return SegmentRead(conversationId: w.conversationId, title: w.title, segment: s, count: w.segments.count)
            }.value
        }
    }

    // MARK: - 候选

    /// conversationIds = 看得见的窗口（nil = 都看得见）：A4 一天一条里只列看得见的窗口那几项
    public static func candidates(in range: DateInterval? = nil, memoryRoot root: URL, conversationIds: Set<String>? = nil,
                           cancel: CatalogCancel? = nil) -> [Hit] {
        guard cancel?.isCancelled != true else { return [] }
        let timeline = TimelineStore.dir(root: root)
        var entries: [TimelineEntry] = []
        var days: [TimelineDayRecord] = []
        for month in TimelineStore.months(in: timeline) {
            guard cancel?.isCancelled != true else { return [] }
            let m = TimelineStore.month(month, in: timeline)
            entries += m.entries
            days += m.days
        }
        guard cancel?.isCancelled != true else { return [] }
        let windows = SessionSummaryStore.all(in: WindowSummaryStore.dir(root: root), cancel: cancel)
        let contexts = a2Sources(root, cancel: cancel)
        guard cancel?.isCancelled != true else { return [] }
        var titles: [String: String] = [:]
        for e in entries where !e.title.isEmpty { titles[e.conversationId] = e.title }
        for item in days.flatMap(\.items) where !item.window.isEmpty { titles[item.conversationId] = item.window }
        for s in windows + Array(contexts.values) where !s.title.isEmpty { titles[s.conversationId] = s.title }

        let dayHits = days.compactMap { d -> Hit? in
            guard cancel?.isCancelled != true, let span = daySpan(d.date), overlaps(span.start, span.end, range) else { return nil }
            let parts = dayParts(d, visible: conversationIds)
            guard !parts.isEmpty else { return nil }
            return Hit(layer: .a4, conversationId: nil, title: "", start: span.start, end: span.end, day: d.date, parts: parts, old: nil)
        }
        // 老条目原样留着（c2c3-v2 第 7 段）：这天有新主调就只用新的；待续迁完以后按本子（三态、现在的字），没迁完才读老字段
        let headlined = Set(days.filter { $0.headline != nil }.map(\.date))
        let pendingURL = PendingStore.fileURL(root: root)
        let book = PendingStore.isLegacyDone(pendingURL) ? PendingStore.load(profileId: "", floorMemoryRoot: root, memoryRoot: root) : nil
        let oldHits = entries.filter { overlaps($0.start, $0.end, range) && !headlined.contains($0.dayKey) }.flatMap { e -> [Hit] in
            guard cancel?.isCancelled != true else { return [] }
            return a4Lines(e, book: book).map { parts in
                Hit(layer: .a4, conversationId: e.conversationId, title: e.title, start: e.start, end: e.end, day: e.dayKey,
                    parts: parts, old: e.day == nil ? "老时间轴大段" : "一天 × 一窗口的老时间轴")
            }
        }
        let a4 = (dayHits + oldHits).sorted {
            ($0.day, $0.end, $0.conversationId ?? "", $0.start) > ($1.day, $1.end, $1.conversationId ?? "", $1.start)
        }
        guard cancel?.isCancelled != true else { return [] }

        let a3Candidates = windows.compactMap { w -> Hit? in
            guard cancel?.isCancelled != true else { return nil }
            let (segments, old) = a3Segments(w, context: contexts[w.conversationId])
            let relevant = segments.filter { overlaps($0.start, $0.end, range) }
            guard let start = relevant.map(\.start).min(), let end = relevant.map(\.end).max() else { return nil }
            var parts: [CatalogSearchPart] = []
            for segment in relevant {
                if cancel?.isCancelled == true { break }
                if !parts.isEmpty { parts.append(CatalogSearchPart(text: "\n\n", isBody: false)) }
                parts += segmentParts(segment)
            }
            return Hit(layer: .a3, conversationId: w.conversationId, title: titles[w.conversationId] ?? "", start: start, end: end,
                       day: MemoryDay.key(start), parts: parts, old: old, keywords: relevant.flatMap(\.keywords))
        }
        guard cancel?.isCancelled != true else { return [] }
        let a3 = a3Candidates.sorted { ($0.end, $0.conversationId ?? "") > ($1.end, $1.conversationId ?? "") }

        let a2Candidates = contexts.values.flatMap { s -> [Hit] in
            guard cancel?.isCancelled != true else { return [] }
            return numbered(s.segments).compactMap { seg -> Hit? in
                guard cancel?.isCancelled != true else { return nil }
                guard overlaps(seg.segment.start, seg.segment.end, range) else { return nil }
                return Hit(layer: .a2, conversationId: s.conversationId, title: titles[s.conversationId] ?? "", start: seg.segment.start,
                           end: seg.segment.end, day: MemoryDay.key(seg.segment.start), segment: seg.number, messages: seg.messages,
                           parts: seg.parts, old: seg.old, keywords: seg.segment.keywords)
            }
        }
        guard cancel?.isCancelled != true else { return [] }
        let a2 = a2Candidates.sorted { ($0.end, $0.conversationId ?? "", $0.segment ?? 0) > ($1.end, $1.conversationId ?? "", $1.segment ?? 0) }

        guard cancel?.isCancelled != true else { return [] }
        return a4 + a3 + a2
    }

    /// 记忆日那一天：05:00 到次日 05:00
    private static func daySpan(_ date: String) -> DateInterval? {
        guard let d = MemoryDay.date(ofKey: date) else { return nil }
        let start = MemoryDay.boundary(of: d)
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: d) else { return nil }
        return DateInterval(start: start, end: MemoryDay.boundary(of: next))
    }

    /// A4 一天一条：主调、话题词、各项（时段 · 时间段《窗口》标题）——和时间轴页、注入同一套字。
    /// 有看不见的窗口（c2c3-v2 第 7 段 astra #5）：主调 / 话题是整天写的，不给，只给看得见的那几项；一项都看不见就整天不给
    public static func dayParts(_ d: TimelineDayRecord, visible: Set<String>?) -> [CatalogSearchPart] {
        let items = d.items.filter { visible?.contains($0.conversationId) ?? true }
        guard !items.isEmpty else { return [] }
        let whole = items.count == d.items.count
        var parts: [CatalogSearchPart] = []
        func line(_ label: String?, _ body: String) {
            if !parts.isEmpty { parts.append(CatalogSearchPart(text: "\n", isBody: false)) }
            if let label { parts.append(CatalogSearchPart(text: label, isBody: false)) }
            parts.append(CatalogSearchPart(text: body, isBody: true))
        }
        if whole, let h = d.headline { line(nil, h) }
        if whole, !d.topics.isEmpty { line("话题：", d.topics.joined(separator: "、")) }
        for item in items.sorted(by: { $0.start < $1.start }) {
            line("\(item.period().label) · ", TimelineStore.itemText(item))
        }
        return parts
    }

    /// A4 老条目的条目行：话题行（老格式整段按行）+ 待续（book = 迁完了的本子：这条搬进去的、还没做完的，按现在的字；nil = 没迁完，读老字段）
    public static func a4Lines(_ e: TimelineEntry, book: [PendingItem]?) -> [[CatalogSearchPart]] {
        let body = (e.day == nil ? e.text.components(separatedBy: "\n") : e.topics)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pending = book.map { PendingStore.items(from: e, in: $0).filter { $0.state == .open }.map(\.text) } ?? TimelineStore.pendingItems(e.pending)
        return body.map { [CatalogSearchPart(text: $0, isBody: true)] }
            + pending.map {
                [CatalogSearchPart(text: "待续：", isBody: false), CatalogSearchPart(text: $0, isBody: true)]
            }
    }

    /// A3 的相关段：v5 = 那一段；v4-1 抄本 = 抄本里 A2 没有的那几段
    private static func a3Segments(_ w: SessionSummary, context: SessionSummary?) -> ([SessionSegment], String?) {
        if let a3 = WindowSummaryReader.a3(w) { return ([a3], nil) }
        let a2 = context?.segments ?? []
        return (w.segments.filter { seg in !a2.contains { $0.story == seg.story && $0.title == seg.title } }, "v4-1 窗口总结抄本")
    }

    /// 每个窗口的 A2：sessions/；没有就第一代老摘要当第 0 段
    private static func a2Sources(_ root: URL, cancel: CatalogCancel? = nil) -> [String: SessionSummary] {
        var out: [String: SessionSummary] = [:]
        for s in SessionSummaryStore.all(in: SessionSummaryStore.dir(root: root), cancel: cancel) {
            guard cancel?.isCancelled != true else { return [:] }
            out[s.conversationId] = s
        }
        guard cancel?.isCancelled != true else { return [:] }
        for id in SummaryFileStore.conversationIds(in: root) where out[id] == nil {
            guard cancel?.isCancelled != true else { return [:] }
            if let seed = firstGen(id, root: root) { out[id] = seed }
        }
        return out
    }

    private static func firstGen(_ conversationId: String, root: URL) -> SessionSummary? {
        (try? SummaryFileStore.loadStrict(conversationId: conversationId, memoryRoot: root))
            .flatMap { SessionSummaryStore.legacySeed(from: $0, conversationId: conversationId) }
    }

    // MARK: - 读

    private static func window(_ conversationId: String, memoryRoot root: URL, cancel: CatalogCancel) -> Window? {
        guard !cancel.isCancelled else { return nil }
        let w = WindowSummaryStore.load(conversationId: conversationId, in: root)
        guard !cancel.isCancelled else { return nil }
        var s = SessionSummaryStore.load(conversationId: conversationId, in: SessionSummaryStore.dir(root: root))
        guard !cancel.isCancelled else { return nil }
        if s == nil { s = firstGen(conversationId, root: root) }
        guard !cancel.isCancelled else { return nil }
        guard let id = w?.conversationId ?? s?.conversationId else { return nil }
        let a3 = w.flatMap(WindowSummaryReader.a3)
        let oldA3 = w.map { a3 == nil ? a3Segments($0, context: s).0 : [] } ?? []
        let title = [w?.title, s?.title].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return Window(conversationId: id, title: title, a3: a3, oldA3: oldA3, segments: numbered(s?.segments ?? []))
    }

    /// 段号：按 `WindowSummaryReader.ordered` 排（改造前累计摘要打头），有它就它是第 0 段，没有从 1 数
    public static func numbered(_ segments: [SessionSegment]) -> [Segment] {
        let ordered = WindowSummaryReader.ordered(segments.filter { $0.kind != .window })
        let base = ordered.first?.kind == .legacy ? 0 : 1
        return ordered.enumerated().map { Segment(number: $0.offset + base, segment: $0.element) }
    }

    public static func oldKind(_ seg: SessionSegment) -> String? {
        if seg.kind == .legacy { return "改造前累计摘要" }
        if seg.kind == .closeout, !seg.isTail { return "老收尾段" }
        return nil
    }

    public static func segmentParts(_ segment: SessionSegment, includeTitle: Bool = true) -> [CatalogSearchPart] {
        var parts = includeTitle ? [CatalogSearchPart(text: "\(segment.title)\n", isBody: false)] : []
        if segment.kind == .legacy {
            parts.append(CatalogSearchPart(text: segment.story, isBody: true))
            return parts
        }
        parts.append(CatalogSearchPart(text: segment.format >= 2 && segment.kind == .window ? "【走向】" : "【经过】", isBody: false))
        parts.append(CatalogSearchPart(text: segment.story, isBody: true))
        if !segment.quotes.isEmpty {
            parts.append(CatalogSearchPart(text: "\n【原话】", isBody: false))
            parts.append(CatalogSearchPart(text: segment.quotes, isBody: true))
        }
        // 段里的【待续】不给（c2c3-v2 第 7 段）：待续只有待续本子一份
        return parts
    }

    public static func segmentText(_ segment: SessionSegment) -> String {
        var text = segmentParts(segment).map(\.text).joined()
        if !segment.keywords.isEmpty { text += "\n【关键词】" + segment.keywords.joined(separator: "，") }
        return text
    }

    // MARK: - 日期范围

    private static func overlaps(_ start: Date, _ end: Date, _ range: DateInterval?) -> Bool {
        guard let range else { return true }
        guard range.start < range.end else { return false }
        // 第一代累计摘要只有更新时间，作为一个时间点读；有时长的段按半开区间相交。
        if end <= start { return start >= range.start && start < range.end }
        return start < range.end && end > range.start
    }

    // MARK: - 给模型看的纯文本

    public static func conv(_ id: String?) -> String { id.map { "conv \($0.prefix(8))" } ?? "" }

    public static func oldTagText(_ old: String?) -> String { old.map { "（旧·\($0)）" } ?? "" }

    public static func messagesLabel(_ r: Range<Int>) -> String { "消息 \(r.lowerBound)..<\(r.upperBound)" }

    public static func spanText(_ start: Date, _ end: Date) -> String {
        SessionSummaryStore.timeRange(SessionSegment(kind: .rolling, title: "", start: start, end: end, from: 0, to: 0,
                                                     lastNodeId: nil, story: "", quotes: "", pending: ""))
    }
}

extension CatalogALineReader {
    /// 段目录里那「一句」：经过的第一句，最多 gistLength 字
    public static func gist(_ seg: SessionSegment) -> String { gistParts(seg).map(\.text).joined() }

    public static func gistParts(_ seg: SessionSegment) -> [CatalogSearchPart] {
        let story = seg.story.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = story.split(whereSeparator: { "。！？\n".contains($0) }).first.map(String.init) ?? story
        var parts = [CatalogSearchPart(text: String(first.prefix(gistLength)), isBody: true)]
        if first.count > gistLength { parts.append(CatalogSearchPart(text: "…", isBody: false)) }
        return parts
    }
}
