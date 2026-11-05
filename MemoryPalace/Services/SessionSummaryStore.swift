import Foundation

/// 第三刀：窗口摘要的一段。压缩段 = 超窗时压出去的那截；收尾段 = 关窗时把没压到的尾巴补上；
/// 老段 = 改造前那份累计摘要，原样当第 0 段接上（plan-memory-fix-3 ①②）。
struct SessionSegment: Equatable {
    enum Kind: String { case rolling, closeout, legacy }

    var kind: Kind
    var title: String
    var start: Date
    var end: Date
    /// 覆盖的消息下标 [from, to)，按主线 user / assistant 计；to = 写完后的位置
    var from: Int
    var to: Int
    /// 覆盖的最后一条消息 id——水位线的可靠锚（切过分支下标会漂，id 不会）；老段没有
    var lastNodeId: String?
    var story: String
    var quotes: String
    var pending: String
    /// v5 D1：A2 的尾段（kind = .closeout，老版本读到当收尾段不注入）：每次收尾整段重写，被正式压缩后换成正式段。
    /// 文件里多一个 `tail=1`，老文件没有 = false
    var isTail = false
    /// 写这段的 A2 格式版本（c2c3-v2 第 7 段）：0 = 没标（以前写的）；`currentFormat` = 现在的写法（又写【待续】、由 A4 搬进待续本子）。
    /// 文件里多一个 `w=1`。三代搬迁靠它分「老式带待续的段」和「新写的带待续的段」
    var format = 0

    static let currentFormat = 1
}

/// 一个对话一份：上下文摘要在 memory/sessions/（只剩压缩段和改造前的第 0 段，老收尾段在重新生成前还留着），
/// 窗口总结在 memory/windows/（v4-1，每次收尾整份重写），文件格式相同：{convId前8}-{标题slug}.md
struct SessionSummary: Equatable {
    var conversationId: String
    var title: String
    /// 历史窗口锚定用：压缩到第几条（含义同旧 ContextSummary.coveredCount，只跟压缩段走，收尾段不推它）
    var compressedCount: Int
    var segments: [SessionSegment]
    var updatedAt: Date
    /// 窗口总结写到哪条消息（只有 windows/ 的文件有）：收尾队列用它判断这个窗口有没有新消息
    var closedThrough: String? = nil

    /// 总结到哪了（压缩段 + 收尾段 + 老段，取最后一段）
    var summarizedTo: Int { segments.last?.to ?? 0 }
}

enum SessionSummaryStore {
    static let folder = "sessions"

    // MARK: - 路径（命名照 SummaryFileStore：前 8 位是锚，标题是可读糖，改名跟随）

    /// 读路径只拼路径不建目录（组 prompt 在主线程读，见 MainThreadIOBudgetTests）；save 才建
    private static func dir(profileId: String) -> URL {
        dir(root: FileLibraryStore.memoryRoot(profileId: profileId))
    }

    static func dir(root: URL) -> URL {
        root.appendingPathComponent(folder, isDirectory: true)
    }

    private static func slugify(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        for ch in t {
            if "/\\:*?\"<>|#".contains(ch) || ch.isNewline || ch.isWhitespace { out.append("-") } else { out.append(ch) }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        if out.count > 24 { out = String(out.prefix(24)) }
        return out.isEmpty ? "untitled" : out
    }

    private static func existingFile(conversationId: String, in d: URL) -> URL? {
        let prefix = String(conversationId.prefix(8)) + "-"
        MainThreadIO.note(.enumerate, "SessionSummaryStore.existingFile")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        return names.first { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }.map { d.appendingPathComponent($0) }
    }

    /// 这个楼层所有窗口的那份文件（窗口总结格列表用），一次枚举 + 逐个读；后台调
    static func all(profileId: String) -> [SessionSummary] {
        all(in: dir(profileId: profileId))
    }

    static func all(in d: URL, cancel: CatalogCancel? = nil) -> [SessionSummary] {
        guard cancel?.isCancelled != true else { return [] }
        MainThreadIO.note(.enumerate, "SessionSummaryStore.all")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        var summaries: [SessionSummary] = []
        for name in names where name.hasSuffix(".md") {
            guard cancel?.isCancelled != true else { return [] }
            MainThreadIO.note(.read, "SessionSummaryStore.all")
            guard let raw = try? String(contentsOf: d.appendingPathComponent(name), encoding: .utf8) else { continue }
            guard cancel?.isCancelled != true else { return [] }
            if let summary = parse(raw) { summaries.append(summary) }
        }
        return summaries
    }

    // MARK: - 存取

    static func load(conversationId: String, profileId: String) -> SessionSummary? {
        load(conversationId: conversationId, in: dir(profileId: profileId))
    }

    static func load(conversationId: String, in d: URL) -> SessionSummary? {
        guard let url = existingFile(conversationId: conversationId, in: d) else { return nil }
        MainThreadIO.note(.read, "SessionSummaryStore.load")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(raw)
    }

    /// 严格读（三代搬迁 astra #9）：nil = 真没有；文件在但读不了 / 格式对不上就抛，不当「没有」
    static func loadStrict(conversationId: String, in d: URL) throws -> SessionSummary? {
        guard let url = try MemoryReadError.existingFile(prefix: String(conversationId.prefix(8)) + "-", in: d) else { return nil }
        return try parseStrict(MemoryReadError.read(url), path: url.path)
    }

    /// 段头机读注释的行数要和读出来的段数一样；只有头、一段都没有 = nil（没东西可丢）
    static func parseStrict(_ raw: String, path: String) throws -> SessionSummary? {
        let segLines = raw.components(separatedBy: "\n").filter { $0.hasPrefix("<!-- seg ") }.count
        guard let s = parse(raw) else {
            if segLines == 0, raw.contains("conversationId:") { return nil }
            throw MemoryReadError.corrupt(path)
        }
        if s.segments.count == segLines { return s }
        // 窄口修复（10-16）：唯一的毛病是段标题断成了几行（老写手把带换行的标题写进了「## 」行）→ 并回一行再读；别的形状照旧判坏
        if let fixed = repairSpilledTitles(raw), let r = parse(fixed), r.segments.count == segLines { return r }
        throw MemoryReadError.corrupt(path)
    }

    /// 断开的标题最多夹几行、并起来最多几个字：只认兜底标题（≤15 字）断开的那种，夹得多 / 长的不是这个病
    static let spilledTitleMaxLines = 6
    static let spilledTitleMaxChars = 40

    /// 段头必须是 render 写出来的真时间头（10-16 astra #1）：「## MM-dd HH:mm–HH:mm · 」，跨日终点带日期；标题整个掉到下一行的「 ·」结尾也认
    private static let segmentHeadingPattern = #"^## \d{2}-\d{2} \d{2}:\d{2}–(\d{2}-\d{2} )?\d{2}:\d{2} ·( |$)"#

    /// 夹行是正文不是标题：带【…】层标记、代码围栏、「## 」、HTML 注释的一律不修（正文里的格式示例长这样）
    private static func looksLikeBody(_ line: String) -> Bool {
        line.range(of: "【[^】]*】", options: .regularExpression) != nil || line.hasPrefix("```") || line.hasPrefix("~~~") || line.hasPrefix("## ") || line.contains("<!--")
    }

    /// 纯函数：每个上面不是「## 」行的「<!-- seg 」行，往上找最近的「## 」行；它得是真时间头，中间夹的全是普通文字（不是正文标记）、
    /// 不超过 spilledTitleMaxLines 行、并起来不超过 spilledTitleMaxChars 字 → 并进那行标题。有一处不是这个形状就返回 nil（不修）
    static func repairSpilledTitles(_ raw: String) -> String? {
        var lines = raw.components(separatedBy: "\n")
        var changed = false
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            guard lines[i].hasPrefix("<!-- seg "), i == 0 || !lines[i - 1].hasPrefix("## ") else { continue }
            var h = i - 1
            while h >= 0, !lines[h].hasPrefix("## "), !lines[h].hasPrefix("<!-- seg ") { h -= 1 }
            // 段头的样子是「## 时间 · 标题」：正文里自己带的「## 」小标题、格式示例不算
            guard h >= 0, lines[h].range(of: segmentHeadingPattern, options: .regularExpression) != nil, i - h - 1 <= spilledTitleMaxLines else { return nil }
            let spill = lines[(h + 1)..<i].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !spill.contains(where: looksLikeBody), spill.joined().count <= spilledTitleMaxChars else { return nil }
            lines[h] = ([lines[h].trimmingCharacters(in: .whitespaces)] + spill).joined(separator: " ")
            lines.removeSubrange((h + 1)..<i)
            i = h + 1
            changed = true
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    static func save(_ s: SessionSummary, profileId: String) throws {
        try save(s, in: dir(profileId: profileId))
    }

    static func save(_ s: SessionSummary, in d: URL) throws {
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let desired = d.appendingPathComponent("\(s.conversationId.prefix(8))-\(slugify(s.title)).md")
        if let existing = existingFile(conversationId: s.conversationId, in: d),
           existing.lastPathComponent != desired.lastPathComponent {
            try? FileManager.default.moveItem(at: existing, to: desired)
        }
        let target = existingFile(conversationId: s.conversationId, in: d) ?? desired
        try Data(render(s).utf8).write(to: target, options: .atomic)
    }

    /// 这个窗口那份文件在哪（没有 = nil）
    static func fileURL(conversationId: String, in d: URL) -> URL? {
        existingFile(conversationId: conversationId, in: d)
    }

    static func clear(conversationId: String, profileId: String) {
        guard let url = existingFile(conversationId: conversationId, in: dir(profileId: profileId)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 已有窗口摘要就读它；没有但有改造前的累计摘要 → 把它当第 0 段（老文件不动）；都没有 → 空的
    static func loadOrSeed(conversationId: String, profileId: String, title: String) -> SessionSummary {
        if let s = load(conversationId: conversationId, profileId: profileId) { return s }
        if var s = legacySeed(conversationId: conversationId, profileId: profileId) {
            s.title = title
            return s
        }
        return SessionSummary(conversationId: conversationId, title: title, compressedCount: 0, segments: [], updatedAt: Date())
    }

    /// 改造前的累计摘要当第 0 段（没有 = nil）；重新生成时 sessions/ 里还没有这个窗口的文件也走它
    static func legacySeed(conversationId: String, profileId: String) -> SessionSummary? {
        SummaryFileStore.load(conversationId: conversationId, profileId: profileId).flatMap { legacySeed(from: $0, conversationId: conversationId) }
    }

    static func legacySeed(from legacy: ContextSummary, conversationId: String) -> SessionSummary? {
        guard legacy.coveredCount > 0 else { return nil }
        return SessionSummary(conversationId: conversationId, title: "", compressedCount: legacy.coveredCount,
                              segments: [SessionSegment(kind: .legacy, title: "改造前的累计摘要", start: legacy.updatedAt, end: legacy.updatedAt,
                                                        from: 0, to: legacy.coveredCount, lastNodeId: nil,
                                                        story: legacy.summary, quotes: "", pending: "")],
                              updatedAt: Date())
    }

    // MARK: - 水位线

    /// 下一段从路径的第几条开始：先按最后一段的 lastNodeId 在路径里找（找到 = 它后面那条），
    /// 找不到（老段 / 切过分支）退回最后一段的 to，夹在路径长度内
    static func resumeIndex(_ s: SessionSummary, pathIds: [String]) -> Int {
        guard let last = s.segments.last else { return 0 }
        if let id = last.lastNodeId, let i = pathIds.firstIndex(of: id) { return i + 1 }
        return min(last.to, pathIds.count)
    }

    // MARK: - 注入 / recall 文本

    static func timeRange(_ seg: SessionSegment) -> String {
        let day = DateFormatter(); day.dateFormat = "MM-dd HH:mm"
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let sameDay = Calendar.current.isDate(seg.start, inSameDayAs: seg.end)
        return "\(day.string(from: seg.start))–\(sameDay ? hm.string(from: seg.end) : day.string(from: seg.end))"
    }

    /// 给模型看的一段（注入 / recall / A3 重压输入）：经过 + 原话。段里的【待续】不拼——待续只有待续本子一份（`PendingStore`），
    /// 段里那份只给 A4 搬进本子（c2c3-v2 第 7 段）
    static func segmentText(_ seg: SessionSegment) -> String {
        guard seg.kind != .legacy else { return seg.story }
        var parts = ["【经过】\(seg.story)"]
        if !seg.quotes.isEmpty { parts.append("【原话】\(seg.quotes)") }
        return parts.joined(separator: "\n")
    }

    /// 存盘的一段：比 `segmentText` 多【待续】（原样留在文件里，A4 从这里搬）
    private static func fileText(_ seg: SessionSegment) -> String {
        guard seg.kind != .legacy, !seg.pending.isEmpty else { return segmentText(seg) }
        return segmentText(seg) + "\n【待续】\(seg.pending)"
    }

    /// 纯函数（v4-1 §六）：当前窗口注哪几段上下文摘要。收尾段一律不注（它属于窗口总结）；一段的最后一条消息还在历史窗口里
    /// （`lastNodeId` 在窗口的节点 id 里；老段没有 id 就看下标：它盖到的最后一条 ≥ 窗口起点）→ 不注（宁缺不重，Q9）
    static func injectableSegments(_ segments: [SessionSegment], windowIds: Set<String>, windowStart: Int) -> [SessionSegment] {
        segments.filter { seg in
            guard seg.kind != .closeout else { return false }
            if let id = seg.lastNodeId { return !windowIds.contains(id) }
            return seg.to <= windowStart
        }
    }

    /// 窗口内注入：最近 fullCount 段全文，更早的每段一行「时间 · 标题」
    static func injectionText(_ s: SessionSummary, fullCount: Int) -> String? {
        guard !s.segments.isEmpty else { return nil }
        let keep = max(1, fullCount)
        let older = s.segments.dropLast(keep)
        let recent = s.segments.suffix(keep)
        var out: [String] = []
        if !older.isEmpty {
            out.append("更早（只列标题，细节用 recall 翻 conversation_id=\(s.conversationId.prefix(8))）：\n"
                       + older.map { "- \(timeRange($0)) · \($0.title)" }.joined(separator: "\n"))
        }
        for seg in recent {
            out.append("〔\(timeRange(seg)) · \(seg.title)〕\n\(segmentText(seg))")
        }
        return out.joined(separator: "\n\n")
    }

    /// recall 只给 conversation_id 时：段标题全列 + 最近两段全文（没做完的事只在待续本子里，这里不列）
    static func recallText(_ s: SessionSummary) -> String {
        var out = "《\(s.title)》conv \(s.conversationId.prefix(8)) · 共 \(s.segments.count) 段"
        if s.segments.count > 2 {
            out += "\n" + s.segments.dropLast(2).map { "- \(timeRange($0)) · \($0.title)" }.joined(separator: "\n")
        }
        for seg in s.segments.suffix(2) {
            out += "\n\n〔\(timeRange(seg)) · \(seg.title)〕\n\(segmentText(seg))"
        }
        return out
    }

    // MARK: - 文件格式（frontmatter + 每段一个 ## 标题 + 一行机读注释）

    private static let iso = FrontmatterCodec.dateFormatter

    static func render(_ s: SessionSummary) -> String {
        let body = s.segments.map { seg -> String in
            var meta = "kind=\(seg.kind.rawValue) from=\(seg.from) to=\(seg.to) start=\(iso.string(from: seg.start)) end=\(iso.string(from: seg.end))"
            if let id = seg.lastNodeId { meta += " last=\(id)" }
            if seg.isTail { meta += " tail=1" }
            if seg.format > 0 { meta += " w=\(seg.format)" }
            // 标题必须一行：换行进了标题行，段头和机读注释就隔开了（10-16 色色那份严格读判坏）
            return "## \(timeRange(seg)) · \(oneLine(seg.title))\n<!-- seg \(meta) -->\n\(fileText(seg))"
        }.joined(separator: "\n\n")
        var meta: [(key: String, value: String)] = [
            ("conversationId", s.conversationId),
            ("title", oneLine(s.title)),
            ("compressedCount", String(s.compressedCount)),
            ("updatedAt", iso.string(from: s.updatedAt)),
        ]
        if let c = s.closedThrough { meta.append((key: "closedThrough", value: c)) }
        return FrontmatterCodec.render(meta: meta, body: body)
    }

    static func parse(_ raw: String) -> SessionSummary? {
        guard let (meta, body) = FrontmatterCodec.parse(raw), let convId = meta["conversationId"] else { return nil }
        var segments: [SessionSegment] = []
        let lines = body.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix("## "), i + 1 < lines.count, lines[i + 1].hasPrefix("<!-- seg ") else { i += 1; continue }
            let heading = String(lines[i].dropFirst(3))
            let title = heading.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            let fields = Dictionary(lines[i + 1].dropFirst(9).replacingOccurrences(of: " -->", with: "")
                .split(separator: " ").compactMap { pair -> (String, String)? in
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
                }, uniquingKeysWith: { a, _ in a })
            var j = i + 2
            var text: [String] = []
            while j < lines.count, !(lines[j].hasPrefix("## ") && j + 1 < lines.count && lines[j + 1].hasPrefix("<!-- seg ")) {
                text.append(lines[j]); j += 1
            }
            let kind = fields["kind"].flatMap(SessionSegment.Kind.init(rawValue:)) ?? .rolling
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let layers = kind == .legacy ? (story: joined, quotes: "", pending: "") : splitLayers(joined)
            segments.append(SessionSegment(
                kind: kind, title: title,
                start: fields["start"].flatMap(iso.date(from:)) ?? .distantPast,
                end: fields["end"].flatMap(iso.date(from:)) ?? .distantPast,
                from: fields["from"].flatMap { Int($0) } ?? 0,
                to: fields["to"].flatMap { Int($0) } ?? 0,
                lastNodeId: fields["last"],
                story: layers.story, quotes: layers.quotes, pending: layers.pending,
                isTail: fields["tail"] == "1", format: fields["w"].flatMap { Int($0) } ?? 0))
            i = j
        }
        return SessionSummary(
            conversationId: convId, title: meta["title"] ?? "",
            compressedCount: meta["compressedCount"].flatMap { Int($0) } ?? 0,
            segments: segments,
            updatedAt: meta["updatedAt"].flatMap(iso.date(from:)) ?? .distantPast,
            closedThrough: meta["closedThrough"])
    }

    /// 【经过】【原话】【待续】三层拆开；一个标记都没有 = 全当经过
    static func splitLayers(_ text: String) -> (story: String, quotes: String, pending: String) {
        let marks = ["【经过】", "【原话】", "【待续】"]
        var found: [(mark: String, range: Range<String.Index>)] = marks.compactMap { m in text.range(of: m).map { (m, $0) } }
        guard !found.isEmpty else { return (text, "", "") }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out: [String: String] = [:]
        for (k, f) in found.enumerated() {
            let end = k + 1 < found.count ? found[k + 1].range.lowerBound : text.endIndex
            out[f.mark] = String(text[f.range.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (out["【经过】"] ?? "", out["【原话】"] ?? "", out["【待续】"] ?? "")
    }

    /// 压成一行：各种换行（含 \r\n）都换成空格，连着的空行不留多余空格
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// 严格读的错（三代搬迁 astra #9）：「不存在」不算错；文件在但读不了、读得出但格式对不上，都要原样留着、报路径
enum MemoryReadError: LocalizedError, Equatable {
    case unreadable(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "读不了 \(path)"
        case .corrupt(let path): return "格式对不上 \(path)"
        }
    }

    static func read(_ url: URL) throws -> String {
        do { return try String(contentsOf: url, encoding: .utf8) } catch { throw unreadable(url.path) }
    }

    /// 文件夹里按前缀找那份文件；文件夹不在 = nil，列不出来就抛
    static func existingFile(prefix: String, in d: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: d.path) else { return nil }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: d.path) } catch { throw unreadable(d.path) }
        return names.first { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }.map { d.appendingPathComponent($0) }
    }
}
