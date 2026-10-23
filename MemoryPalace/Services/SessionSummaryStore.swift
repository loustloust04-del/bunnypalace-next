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

    static func all(in d: URL) -> [SessionSummary] {
        MainThreadIO.note(.enumerate, "SessionSummaryStore.all")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.compactMap { name in
            MainThreadIO.note(.read, "SessionSummaryStore.all")
            guard let raw = try? String(contentsOf: d.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return parse(raw)
        }
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
        guard let legacy = SummaryFileStore.load(conversationId: conversationId, profileId: profileId), legacy.coveredCount > 0 else { return nil }
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

    static func segmentText(_ seg: SessionSegment) -> String {
        guard seg.kind != .legacy else { return seg.story }
        var parts = ["【经过】\(seg.story)"]
        if !seg.quotes.isEmpty { parts.append("【原话】\(seg.quotes)") }
        if !seg.pending.isEmpty { parts.append("【待续】\(seg.pending)") }
        return parts.joined(separator: "\n")
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

    /// recall 只给 conversation_id 时：段标题全列 + 最近两段全文 + 各段没做完的事
    static func recallText(_ s: SessionSummary) -> String {
        var out = "《\(s.title)》conv \(s.conversationId.prefix(8)) · 共 \(s.segments.count) 段"
        if s.segments.count > 2 {
            out += "\n" + s.segments.dropLast(2).map { "- \(timeRange($0)) · \($0.title)" }.joined(separator: "\n")
        }
        for seg in s.segments.suffix(2) {
            out += "\n\n〔\(timeRange(seg)) · \(seg.title)〕\n\(segmentText(seg))"
        }
        let pendings = s.segments.dropLast(2).filter { !$0.pending.isEmpty && $0.pending != "无" }
        if !pendings.isEmpty {
            out += "\n\n更早段落里没做完的：\n" + pendings.map { "- \($0.title)：\($0.pending)" }.joined(separator: "\n")
        }
        return out
    }

    // MARK: - 文件格式（frontmatter + 每段一个 ## 标题 + 一行机读注释）

    private static let iso = FrontmatterCodec.dateFormatter

    static func render(_ s: SessionSummary) -> String {
        let body = s.segments.map { seg -> String in
            var meta = "kind=\(seg.kind.rawValue) from=\(seg.from) to=\(seg.to) start=\(iso.string(from: seg.start)) end=\(iso.string(from: seg.end))"
            if let id = seg.lastNodeId { meta += " last=\(id)" }
            return "## \(timeRange(seg)) · \(seg.title)\n<!-- seg \(meta) -->\n\(segmentText(seg))"
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
                story: layers.story, quotes: layers.quotes, pending: layers.pending))
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

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
