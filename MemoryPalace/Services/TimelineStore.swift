import Foundation

/// 时间轴的一条。v2（plan-memory-v4-1 §三）= 一天 × 一个窗口一条：`day` + 窗口编号是键，同一天同一窗口收尾多次改写同一条；
/// 正文一个话题一行（「- 话题」），待续一条一行。老格式（`day == nil`，一次收尾一条）照读，不参与按键改写
struct TimelineEntry: Equatable {
    var start: Date
    var end: Date
    var conversationId: String
    var title: String
    var text: String
    var pending: String
    /// v2：归哪天（05:00 日界，yyyy-MM-dd）；nil = 老格式
    var day: String? = nil
    /// v2：写到哪条消息（时间轴水位线）
    var lastNodeId: String? = nil

    /// 归哪天：v2 用存好的 day，老格式按开始时间现算
    var dayKey: String { day ?? MemoryDay.key(start) }

    /// 话题行（去掉「- 」）；老格式整段一行
    var topics: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }
}

/// memory/timeline/{yyyy-MM}.md，一条一个 ## 块（按开始时间排），按 05:00 日界归月。旧的按天日记在 daily/，停写只读。
enum TimelineStore {
    static let folder = "timeline"

    static var injectCount: Int {
        let v = UserDefaults.standard.integer(forKey: "mem_timeline_inject_count")
        return v > 0 ? v : 8
    }
    static var injectDays: Int {
        let v = UserDefaults.standard.integer(forKey: "mem_timeline_inject_days")
        return v > 0 ? v : 7
    }

    /// 读路径只拼路径不建目录（组 prompt 在主线程读，见 MainThreadIOBudgetTests）；写才建
    static func dir(profileId: String) -> URL {
        dir(root: FileLibraryStore.memoryRoot(profileId: profileId))
    }

    static func dir(root: URL) -> URL {
        root.appendingPathComponent(folder, isDirectory: true)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let iso = FrontmatterCodec.dateFormatter

    // MARK: - 读写

    static func entries(month: String, profileId: String) -> [TimelineEntry] {
        entries(month: month, in: dir(profileId: profileId))
    }

    static func entries(month: String, in dir: URL) -> [TimelineEntry] {
        let url = dir.appendingPathComponent("\(month).md")
        MainThreadIO.note(.read, "TimelineStore.entries")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(raw)
    }

    /// 已有的月份（timeline/ 下的 yyyy-MM.md），新→旧
    static func months(profileId: String) -> [String] {
        months(in: dir(profileId: profileId))
    }

    static func months(in dir: URL) -> [String] {
        MainThreadIO.note(.enumerate, "TimelineStore.months")
        return monthNames((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    static func monthNames(_ fileNames: [String]) -> [String] {
        fileNames.compactMap { name -> String? in
            guard name.hasSuffix(".md") else { return nil }
            let m = String(name.dropLast(3))
            return m.count == 7 && monthFormatter.date(from: m) != nil ? m : nil
        }.sorted(by: >)
    }

    /// 整个月文件重写（按开始时间排）
    static func write(_ list: [TimelineEntry], month: String, in dir: URL) throws {
        try writeLock.withLock {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(render(sorted(list), month: month).utf8).write(to: dir.appendingPathComponent("\(month).md"), options: .atomic)
        }
    }

    /// 写侧一把锁（astra #6）：月文件是几个窗口共用的，「读—改—整份覆盖」要串行，不然后写的会盖掉别的窗口刚写的条目。
    /// 只锁读改写本身，模型调用照样并行
    private static let writeLock = NSRecursiveLock()

    /// 读—改—写一个月文件（整段在锁里）
    static func mutate(month: String, in dir: URL, _ change: ([TimelineEntry]) -> [TimelineEntry]) throws {
        try writeLock.withLock {
            try write(change(entries(month: month, in: dir)), month: month, in: dir)
        }
    }

    /// 老写法：一次一条往后加（按 05:00 归月）
    static func append(_ e: TimelineEntry, profileId: String) throws {
        try mutate(month: MemoryDay.month(e.start), in: dir(profileId: profileId)) { $0 + [e] }
    }

    /// 纯函数（可测）：按（日期, 窗口编号）改写——有就整条替换，没有就新加；老格式条目不参与
    static func upserting(_ e: TimelineEntry, into list: [TimelineEntry]) -> [TimelineEntry] {
        var out = list
        if let day = e.day, let i = out.firstIndex(where: { $0.day == day && $0.conversationId == e.conversationId }) {
            out[i] = e
        } else {
            out.append(e)
        }
        return sorted(out)
    }

    /// v2 条目写进它那天所在的月文件
    static func upsert(_ e: TimelineEntry, in dir: URL) throws {
        try mutate(month: String(e.dayKey.prefix(7)), in: dir) { upserting(e, into: $0) }
    }

    /// 这一天这个窗口已有的那条（v2）
    static func entry(day: String, conversationId: String, in dir: URL) -> TimelineEntry? {
        entries(month: String(day.prefix(7)), in: dir).first { $0.day == day && $0.conversationId == conversationId }
    }

    /// 这个窗口在 day 以前（不含）最新的一条，从新的月份往回找；day = nil 不限；v2Only = 老格式不算
    static func latest(conversationId: String, before day: String? = nil, v2Only: Bool = false, in dir: URL) -> TimelineEntry? {
        for month in months(in: dir) {
            if let day, month > String(day.prefix(7)) { continue }
            let hits = entries(month: month, in: dir).filter { e in
                e.conversationId == conversationId && (!v2Only || e.day != nil) && (day.map { e.dayKey < $0 } ?? true)
            }
            if let best = hits.max(by: { ($0.dayKey, $0.end) < ($1.dayKey, $1.end) }) { return best }
        }
        return nil
    }

    /// 最近两个月（05:00 日界）里每个窗口最新的一条 v2 条目（收尾队列一次读齐用）
    static func latestByConversation(near now: Date, in dir: URL) -> [String: TimelineEntry] {
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        var out: [String: TimelineEntry] = [:]
        for month in Set([MemoryDay.month(lastMonth), MemoryDay.month(now)]) {
            for e in entries(month: month, in: dir) where e.day != nil {
                if let old = out[e.conversationId], (old.dayKey, old.end) >= (e.dayKey, e.end) { continue }
                out[e.conversationId] = e
            }
        }
        return out
    }

    /// 最近的：本月 + 上月（05:00 日界），days 天内、最新的 count 条，按时间先后排；skip = 不注入的（先挑掉再取 count 条）
    static func recent(profileId: String, now: Date = Date(), count: Int = injectCount, days: Int = injectDays,
                       skip: (TimelineEntry) -> Bool = { _ in false }) -> [TimelineEntry] {
        let cal = Calendar.current
        let lastMonth = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let months = Set([MemoryDay.month(lastMonth), MemoryDay.month(now)])
        let d = dir(profileId: profileId)
        let all = months.flatMap { entries(month: $0, in: d) }
        return select(all.filter { !skip($0) }, now: now, count: count, days: days)
    }

    /// 纯函数（v4-1 §六）：注不注。别的窗口的条目全注；当前窗口自己的条目，它的 last 还在历史窗口里就不注（判定用节点 id）；
    /// 老格式没有 id，照注
    static func injectable(_ e: TimelineEntry, currentConversationId: String, windowIds: Set<String>) -> Bool {
        guard e.conversationId == currentConversationId, let last = e.lastNodeId else { return true }
        return !windowIds.contains(last)
    }

    /// 纯函数（可测）：days 天内（按结束时间）、最新 count 条，按开始时间先后排
    static func select(_ all: [TimelineEntry], now: Date, count: Int, days: Int) -> [TimelineEntry] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return Array(sorted(all.filter { $0.end >= since }).suffix(count))
    }

    static func sorted(_ list: [TimelineEntry]) -> [TimelineEntry] {
        list.sorted { $0.start < $1.start }
    }

    // MARK: - 注入

    static func injectionText(_ list: [TimelineEntry]) -> String? {
        guard !list.isEmpty else { return nil }
        // 同一个窗口只在注进去的最新那条后面带待续（Q6）
        let latest = Dictionary(list.indices.map { (list[$0].conversationId, $0) }, uniquingKeysWith: { a, b in
            (list[a].dayKey, list[a].end) >= (list[b].dayKey, list[b].end) ? a : b
        })
        return "[时间轴]（按时间排，一天一个窗口一条；想看哪个窗口从头到尾，用 recall 给 conversation_id 翻它的窗口总结）\n"
            + list.indices.map { line(list[$0], withPending: latest[list[$0].conversationId] == $0) }.joined(separator: "\n")
    }

    static func line(_ e: TimelineEntry, withPending: Bool = true) -> String {
        let body = e.day == nil ? e.text : e.topics.joined(separator: "；")
        var s = "- \(rangeText(e)) 《\(e.title)》conv \(e.conversationId.prefix(8))：\(body)"
        if withPending, let p = pendingInline(e.pending) { s += "（待续：\(p)）" }
        return s
    }

    private static func pendingInline(_ pending: String) -> String? {
        let items = pendingItems(pending)
        return items.isEmpty ? nil : items.joined(separator: "；")
    }

    /// 待续一条一行；空或「无」= 没有
    static func pendingItems(_ pending: String) -> [String] {
        let items = pending.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
        return items == ["无"] ? [] : items
    }

    static func rangeText(_ e: TimelineEntry) -> String {
        let day = DateFormatter(); day.dateFormat = "MM-dd HH:mm"
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let sameDay = Calendar.current.isDate(e.start, inSameDayAs: e.end)
        return "\(day.string(from: e.start))–\(sameDay ? hm.string(from: e.end) : day.string(from: e.end))"
    }

    // MARK: - 文件格式

    static func render(_ list: [TimelineEntry], month: String) -> String {
        let body = list.map { e -> String in
            var block = "## \(rangeText(e)) · 《\(e.title)》 · conv \(e.conversationId.prefix(8))\n"
            if let day = e.day {
                var meta = "v=2 day=\(day) conv=\(e.conversationId) start=\(iso.string(from: e.start)) end=\(iso.string(from: e.end))"
                if let last = e.lastNodeId { meta += " last=\(last)" }
                block += "<!-- entry \(meta) -->\n"
                block += e.text
                let items = pendingItems(e.pending)
                if !items.isEmpty { block += "\n待续：\n" + items.map { "- \($0)" }.joined(separator: "\n") }
            } else {
                block += "<!-- entry conv=\(e.conversationId) start=\(iso.string(from: e.start)) end=\(iso.string(from: e.end)) -->\n"
                block += e.text
                if !e.pending.isEmpty, e.pending != "无" { block += "\n待续：\(e.pending)" }
            }
            return block
        }.joined(separator: "\n\n")
        return FrontmatterCodec.render(meta: [("month", month)], body: body)
    }

    static func parse(_ raw: String) -> [TimelineEntry] {
        guard let (_, body) = FrontmatterCodec.parse(raw) else { return [] }
        let lines = body.components(separatedBy: "\n")
        var out: [TimelineEntry] = []
        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix("## "), i + 1 < lines.count, lines[i + 1].hasPrefix("<!-- entry ") else { i += 1; continue }
            let heading = lines[i]
            let title = heading.range(of: "《").flatMap { a in heading.range(of: "》", range: a.upperBound..<heading.endIndex).map { String(heading[a.upperBound..<$0.lowerBound]) } } ?? ""
            let fields = Dictionary(lines[i + 1].dropFirst(11).replacingOccurrences(of: " -->", with: "")
                .split(separator: " ").compactMap { pair -> (String, String)? in
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
                }, uniquingKeysWith: { a, _ in a })
            let v2 = fields["v"] == "2"
            var j = i + 2
            var text: [String] = []
            var pending: [String] = []
            var inPending = false
            while j < lines.count, !(lines[j].hasPrefix("## ") && j + 1 < lines.count && lines[j + 1].hasPrefix("<!-- entry ")) {
                if lines[j].hasPrefix("待续：") {
                    inPending = true
                    let rest = String(lines[j].dropFirst(3))
                    if !(v2 && rest.trimmingCharacters(in: .whitespaces).isEmpty) { pending.append(rest) }
                } else if inPending {
                    let l = lines[j]
                    pending.append(v2 && l.hasPrefix("- ") ? String(l.dropFirst(2)) : l)
                } else {
                    text.append(lines[j])
                }
                j += 1
            }
            if let conv = fields["conv"] {
                out.append(TimelineEntry(
                    start: fields["start"].flatMap(iso.date(from:)) ?? .distantPast,
                    end: fields["end"].flatMap(iso.date(from:)) ?? .distantPast,
                    conversationId: conv, title: title,
                    text: text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    pending: pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    day: v2 ? fields["day"] : nil,
                    lastNodeId: v2 ? fields["last"] : nil))
            }
            i = j
        }
        return out
    }
}
