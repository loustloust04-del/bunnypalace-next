import CryptoKit
import Foundation

/// 时间轴的老条目（v2 = 一天 × 一个窗口一条，`day` + 窗口编号；更老的 `day == nil` 一次收尾一条）。只读：
/// 新的 A4 一天一条（`TimelineDayRecord`）重拼不了的日子（只有老收尾段 / 第 0 段）留着它，界面和注入标「旧格式」
public struct TimelineEntry: Equatable {
    public var start: Date
    public var end: Date
    public var conversationId: String
    public var title: String
    public var text: String
    public var pending: String
    /// v2：归哪天（05:00 日界，yyyy-MM-dd）；nil = 更老的格式
    public var day: String? = nil
    /// v2：写到哪条消息
    public var lastNodeId: String? = nil

    /// 归哪天：v2 用存好的 day，更老的按开始时间现算
    public var dayKey: String { day ?? MemoryDay.key(start) }

    /// 话题行（去掉「- 」）；更老的整段一行
    public var topics: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }

    public init(start: Date, end: Date, conversationId: String, title: String, text: String, pending: String,
                day: String? = nil, lastNodeId: String? = nil) {
        self.start = start
        self.end = end
        self.conversationId = conversationId
        self.title = title
        self.text = text
        self.pending = pending
        self.day = day
        self.lastNodeId = lastNodeId
    }
}

/// 一天的四个时段：上午 05–12 / 下午 12–18 / 晚上 18–24 / 深夜 00–05（深夜归前一个记忆日）
public enum TimelinePeriod: String, CaseIterable, Codable {
    case morning, afternoon, evening, lateNight

    public var label: String {
        switch self {
        case .morning: return "上午"
        case .afternoon: return "下午"
        case .evening: return "晚上"
        case .lateNight: return "深夜"
        }
    }

    public static func of(_ date: Date, calendar: Calendar = .current) -> TimelinePeriod {
        switch calendar.component(.hour, from: date) {
        case MemoryDay.boundaryHour..<12: return .morning
        case 12..<18: return .afternoon
        case 18..<24: return .evening
        default: return .lateNight
        }
    }
}

/// A4 一天一条（plan-memory-c2c3-v2 第 7 段）：代码按 A2 段拼的骨架 + 模型只写的一句主调（≤40 字）和 1–3 个话题词
public struct TimelineDayRecord: Equatable {
    public struct Item: Equatable, Codable {
        public enum Kind: String, Codable {
            /// 一段（或同窗口连着的几段）A2
            case segment
            /// 长窗口里还没压成 A2 的那截
            case uncompressed
            /// 短窗口（≤5 条）、没写 A2
            case short
        }
        public var kind: Kind
        public var conversationId: String
        /// 窗口名
        public var window: String
        /// A2 段标题（同窗口连着的几段用「；」连）；没压缩的 =「（N 条，没压缩）」
        public var title: String
        /// 这一项在当天的第一条 / 最后一条消息的时间
        public var start: Date
        public var end: Date
        /// 稳定指针：这一项在当天的第一条 / 最后一条消息 id（段号显示时现算）；nil = 这段在当前分支上找不到了
        public var from: String?
        public var to: String?
        /// 跨天的段：第一天之后的每一天都标「接前一天」
        public var continued = false

        public func period(calendar: Calendar = .current) -> TimelinePeriod { .of(start, calendar: calendar) }

        public init(kind: Kind, conversationId: String, window: String, title: String, start: Date, end: Date,
                    from: String? = nil, to: String? = nil, continued: Bool = false) {
            self.kind = kind
            self.conversationId = conversationId
            self.window = window
            self.title = title
            self.start = start
            self.end = end
            self.from = from
            self.to = to
            self.continued = continued
        }
    }

    public var date: String
    /// nil = 还没有（这天的对话都还没压成 A2，或主调没写成）
    public var headline: String?
    public var topics: [String] = []
    public var items: [Item]
    /// 主调那次调用喂的标题清单的指纹：标题没变就不再调模型
    public var source = ""

    public init(date: String, headline: String? = nil, topics: [String] = [], items: [Item], source: String = "") {
        self.date = date
        self.headline = headline
        self.topics = topics
        self.items = items
        self.source = source
    }
}

/// memory/timeline/{yyyy-MM}.md：新的一天一条（`<!-- day …-->` 块）+ 重拼不了的日子留着的老条目（`<!-- entry …-->` 块），
/// 按记忆日（05:00）归月、按日期排。旧的按天日记在 daily/，停写只读
public enum TimelineStore {}

public extension TimelineStore {
    static let folder = "timeline"

    /// 带几天（今天算第 1 天）：最近 fullDays 天带各时段，再往前到这里只带主调
    static var injectDays: Int {
        let v = MemoryReadEnvironment.defaults.integer(forKey: "mem_timeline_inject_days")
        return v > 0 ? v : 7
    }
    static let fullDays = 2
    static let headlineLimit = 40

    /// 读路径只拼路径不建目录（组 prompt 在主线程读，见 MainThreadIOBudgetTests）；写才建
    static func dir(memoryRoot: URL) -> URL {
        dir(root: memoryRoot)
    }

    static func dir(root: URL) -> URL {
        root.appendingPathComponent(folder, isDirectory: true)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let iso = FrontmatterCodec.dateFormatter

    // MARK: - 月文件

    struct Month: Equatable {
        public var days: [TimelineDayRecord] = []
        public var entries: [TimelineEntry] = []

        public init(days: [TimelineDayRecord] = [], entries: [TimelineEntry] = []) {
            self.days = days
            self.entries = entries
        }
    }

    static func month(_ month: String, in dir: URL) -> Month {
        MainThreadIO.note(.read, "TimelineStore.month")
        guard let raw = try? String(contentsOf: dir.appendingPathComponent("\(month).md"), encoding: .utf8) else { return Month() }
        return parseMonth(raw)
    }

    /// 文件不在 = 空的；读不了 / 机读注释的块数和读出来的对不上就抛（三代搬迁 astra #9：读坏的绝不能当空的写回去）
    static func monthStrict(_ month: String, in dir: URL) throws -> Month {
        let url = dir.appendingPathComponent("\(month).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return Month() }
        let raw = try MemoryReadError.read(url)
        let m = parseMonth(raw)
        let lines = raw.components(separatedBy: "\n")
        guard m.entries.count == lines.filter({ $0.hasPrefix("<!-- entry ") }).count,
              m.days.count == lines.filter({ $0.hasPrefix("<!-- day ") }).count,
              m.days.map(\.items.count).reduce(0, +) == lines.filter({ $0.hasPrefix("- ") && $0.contains(itemMark) }).count
        else { throw MemoryReadError.corrupt(url.path) }
        return m
    }

    /// 写侧一把锁（astra #6）：月文件是几个窗口 / 几天共用的，「读—改—整份覆盖」要串行
    private static let writeLock = NSRecursiveLock()

    /// 拿着月文件的写锁做一件事：A4 提交前看维护纪元、恢复备份换 timeline/ 文件夹都在这把锁里（可重入）
    static func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        try writeLock.withLock(body)
    }

    static func save(_ m: Month, month: String, in dir: URL) throws {
        try writeLock.withLock {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(render(m, month: month).utf8).write(to: dir.appendingPathComponent("\(month).md"), options: .atomic)
        }
    }

    /// 读—改—写一个月文件（整段在锁里，严格读）
    static func mutateMonth(_ month: String, in dir: URL, _ change: (inout Month) throws -> Void) throws {
        try writeLock.withLock {
            var m = try monthStrict(month, in: dir)
            try change(&m)
            try save(m, month: month, in: dir)
        }
    }

    // MARK: - 老条目（只读；三代搬迁撤回老标记还要换回去）

    static func entries(month: String, memoryRoot: URL) -> [TimelineEntry] {
        entries(month: month, in: dir(memoryRoot: memoryRoot))
    }

    static func entries(month: String, in dir: URL) -> [TimelineEntry] {
        self.month(month, in: dir).entries
    }

    static func entriesStrict(month: String, in dir: URL) throws -> [TimelineEntry] {
        try monthStrict(month, in: dir).entries
    }

    /// 老条目整份写（新的一天一条原样留着）：测试夹具、三代搬迁撤回用
    static func write(_ list: [TimelineEntry], month: String, in dir: URL) throws {
        try writeLock.withLock {
            var m = self.month(month, in: dir)
            m.entries = list
            try save(m, month: month, in: dir)
        }
    }

    /// 同 `write`，但读用严格读
    static func mutateStrict(month: String, in dir: URL, _ change: ([TimelineEntry]) -> [TimelineEntry]) throws {
        try mutateMonth(month, in: dir) { $0.entries = change($0.entries) }
    }

    /// 已有的月份（timeline/ 下的 yyyy-MM.md），新→旧
    static func months(memoryRoot: URL) -> [String] {
        months(in: dir(memoryRoot: memoryRoot))
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

    /// 文件夹不在 = 没有；列不出来就抛
    static func monthsStrict(in dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        do { return monthNames(try FileManager.default.contentsOfDirectory(atPath: dir.path)) } catch {
            throw MemoryReadError.unreadable(dir.path)
        }
    }

    /// 这个窗口最新一条老条目（没迁移的楼层 recall 找待续老字段用）
    static func latest(conversationId: String, in dir: URL) -> TimelineEntry? {
        for month in months(in: dir) {
            if let best = entries(month: month, in: dir).filter({ $0.conversationId == conversationId })
                .max(by: { ($0.dayKey, $0.end) < ($1.dayKey, $1.end) }) { return best }
        }
        return nil
    }

    /// 待续一条一行；空或「无」= 没有
    static func pendingItems(_ pending: String) -> [String] {
        let items = pending.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
        return items == ["无"] ? [] : items
    }

    /// 老条目改不改得、注不注：别的窗口的全注；当前窗口的，它的 last 还在历史窗口里就不注（老格式没有 id，照注）
    static func injectable(_ e: TimelineEntry, currentConversationId: String, windowIds: Set<String>) -> Bool {
        guard e.conversationId == currentConversationId, let last = e.lastNodeId else { return true }
        return !windowIds.contains(last)
    }

    // MARK: - 一天一条

    static func day(_ date: String, in dir: URL) -> TimelineDayRecord? {
        month(String(date.prefix(7)), in: dir).days.first { $0.date == date }
    }

    /// 这几天（yyyy-MM-dd）的新条目和老条目，按日期
    static func days(_ dates: [String], in dir: URL) -> (days: [String: TimelineDayRecord], entries: [String: [TimelineEntry]]) {
        var days: [String: TimelineDayRecord] = [:]
        var entries: [String: [TimelineEntry]] = [:]
        let wanted = Set(dates)
        for m in Set(dates.map { String($0.prefix(7)) }) {
            let month = month(m, in: dir)
            for d in month.days where wanted.contains(d.date) { days[d.date] = d }
            for e in month.entries where wanted.contains(e.dayKey) { entries[e.dayKey, default: []].append(e) }
        }
        return (days, entries)
    }

    /// 标题清单的指纹（日期 + 标题按先后）
    static func source(date: String, titles: [String]) -> String {
        let digest = SHA256.hash(data: Data(([date] + titles).joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 显示和注入共用的字（界面那一行 = 注入那一行，一字不差）

    static func headlineText(_ r: TimelineDayRecord) -> String {
        r.headline ?? "（还没有主调）"
    }

    /// 一项那一行 = 正文 + 空格 + 窗口短编号（recall 靠编号取窗口总结，v4-1）；界面把编号那截画成小号灰字，字不变
    static func itemText(_ i: TimelineDayRecord.Item, calendar: Calendar = .current) -> String {
        itemBody(i, calendar: calendar) + " " + convTag(i.conversationId)
    }

    static func itemBody(_ i: TimelineDayRecord.Item, calendar: Calendar = .current) -> String {
        "\(hm(i.start, calendar))–\(hm(i.end, calendar)) 《\(i.window.isEmpty ? "没有标题的窗口" : i.window)》\(i.title)"
            + (i.continued ? "（接前一天）" : "")
    }

    static func legacyText(_ e: TimelineEntry, calendar: Calendar = .current) -> String {
        legacyBody(e, calendar: calendar) + " " + convTag(e.conversationId)
    }

    static func legacyBody(_ e: TimelineEntry, calendar: Calendar = .current) -> String {
        let body = e.day == nil ? SessionSummaryStore.oneLine(e.text) : e.topics.joined(separator: "；")
        return "\(hm(e.start, calendar))–\(hm(e.end, calendar)) 《\(e.title.isEmpty ? "没有标题的窗口" : e.title)》\(body)"
    }

    /// 「conv 1a2b3c4d」
    static func convTag(_ conversationId: String) -> String {
        "conv \(conversationId.prefix(8))"
    }

    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// 「10-16 周四」
    static func dayLabel(_ date: String, calendar: Calendar = .current) -> String {
        guard let d = MemoryDay.date(ofKey: date, calendar: calendar) else { return date }
        return "\(date.dropFirst(5)) \(weekdays[(calendar.component(.weekday, from: d) - 1) % 7])"
    }

    private static func hm(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - 注入

    /// 注进去的一个单位（发送时记账）：一天的主调行 / 一项 / 一条老条目
    struct Unit: Equatable {
        public var key: String
        public var line: String

        public init(key: String, line: String) {
            self.key = key
            self.line = line
        }
    }

    /// 注进去的一窗待续（发送时记账；行与注入文本里那行一字不差）
    struct PendingUnit: Equatable {
        public var conversationId: String
        public var line: String

        public init(conversationId: String, line: String) {
            self.conversationId = conversationId
            self.line = line
        }
    }

    struct Injection: Equatable {
        public var text: String?
        public var units: [Unit]
        public var pendingUnits: [PendingUnit]
        /// 仅因 `hiddenConversations` 被挡掉的项 + 老条目 + 待续窗条数（不数还在窗口里的）
        public var hiddenCount: Int

        public init(text: String?, units: [Unit], pendingUnits: [PendingUnit] = [], hiddenCount: Int = 0) {
            self.text = text
            self.units = units
            self.pendingUnits = pendingUnits
            self.hiddenCount = hiddenCount
        }
    }

    /// 纯函数（可测）：今天算第 1 天，最近 fullDays 天带主调 + 各时段，往前到第 days 天只带主调（没有主调、只有老条目的那天
    /// 带一行老条目的话题，标旧格式；什么都没有的不带）。当前窗口还在历史窗口里的项 / 老条目不注（它的最后一条还在窗口里，原文就在眼前）。
    /// 待续单独一段：带这几天有东西注进去的窗口里没做完的；openPending = nil（这一层待续还没迁移）照读注进去的老条目里最新那条的老字段。
    /// `hiddenConversations` = 来源窗已删 / 关参与（plan-memory-participation §2.4）：那窗的项 / 老条目 / 待续都不带；
    /// 一天一条的主调行是整天聚合、不归属单个窗，不按窗挡——但当天条目全来自隐藏窗时主调也不带（条目本来就空的日子照带）。
    static func injection(records: [String: TimelineDayRecord], entries: [String: [TimelineEntry]], today: String,
                          currentConversationId: String, windowIds: Set<String>, openPending: [String: [String]]?,
                          days: Int = injectDays, calendar: Calendar = .current, timelineLines: Bool = true,
                          hiddenConversations: Set<String> = []) -> Injection {
        guard let todayDate = MemoryDay.date(ofKey: today, calendar: calendar) else { return Injection(text: nil, units: []) }
        let span = max(days, 1)
        let dates = (0..<span).reversed().compactMap { k -> String? in
            calendar.date(byAdding: .day, value: -k, to: todayDate).map { MemoryDay.key(MemoryDay.boundary(of: $0, calendar: calendar), calendar: calendar) }
        }
        func stillInWindow(_ i: TimelineDayRecord.Item) -> Bool {
            i.conversationId == currentConversationId && i.to.map(windowIds.contains) == true
        }
        var lines: [String] = []
        var units: [Unit] = []
        var windows: [String: String] = [:]
        var seenWindows: [String] = []
        var latestOld: [String: TimelineEntry] = [:]
        /// 隐藏老条目的逐窗最新快照：`openPending == nil` 的老路只能从这里取隐藏窗的待续
        var latestHiddenOld: [String: TimelineEntry] = [:]
        var hiddenCount = 0
        var hiddenWindows: [String] = []
        /// 被来源窗挡掉：记住这窗（待续那行也要数）；项 / 老条目只有真勾着时间轴才是一条候选
        func dropByWindow(_ id: String, countsLine: Bool) -> Bool {
            guard hiddenConversations.contains(id) else { return false }
            if countsLine { hiddenCount += 1 }
            if !hiddenWindows.contains(id) { hiddenWindows.append(id) }
            return true
        }
        func saw(_ id: String, _ title: String) {
            if windows[id] == nil { seenWindows.append(id) }
            if windows[id]?.isEmpty ?? true { windows[id] = title }
        }
        for (k, date) in dates.enumerated() {
            let full = span - 1 - k < fullDays
            let record = records[date]
            let rawItems = record?.items ?? []
            let visibleItems = rawItems.sorted { $0.start < $1.start }.filter { !stillInWindow($0) }
            let items = visibleItems.filter { !dropByWindow($0.conversationId, countsLine: timelineLines) }
            let olds = (entries[date] ?? []).sorted { $0.start < $1.start }
                .filter { injectable($0, currentConversationId: currentConversationId, windowIds: windowIds) }
                .filter { entry in
                    guard dropByWindow(entry.conversationId, countsLine: timelineLines) else { return true }
                    // 隐藏老条目：留下逐窗最新 pending 快照，`openPending == nil` 分支靠它数待续窗
                    if let o = latestHiddenOld[entry.conversationId], o.end >= entry.end { return false }
                    latestHiddenOld[entry.conversationId] = entry
                    return false
                }
            // 主调是当天各条目写的：当天注得进去的条目全来自隐藏窗 → 主调也是那扇窗的摘要，一起不带
            //（条目本来就空的日子、以及只是还在窗口里被去重的日子照带）
            let headlineHidden = !visibleItems.isEmpty && items.isEmpty
            let headlineVisible = record?.headline != nil && !headlineHidden
            items.forEach { saw($0.conversationId, $0.window) }
            for e in olds {
                saw(e.conversationId, e.title)
                if let o = latestOld[e.conversationId], o.end >= e.end { continue }
                latestOld[e.conversationId] = e
            }
            if !full {
                let line: String
                if let r = record, headlineVisible {
                    line = "\(dayLabel(date, calendar: calendar))：\(headlineText(r))"
                } else if !olds.isEmpty {
                    line = "\(dayLabel(date, calendar: calendar))：（旧格式）" + olds.map { e in
                        "《\(e.title.isEmpty ? "没有标题的窗口" : e.title)》" + (e.day == nil ? SessionSummaryStore.oneLine(e.text) : e.topics.joined(separator: "、"))
                            + " " + convTag(e.conversationId)
                    }.joined(separator: "；")
                } else {
                    continue
                }
                lines.append(line)
                units.append(Unit(key: date, line: line))
                continue
            }
            var body: [Unit] = items.map { item in
                Unit(key: "\(date)|\(item.conversationId)|\(item.to ?? iso.string(from: item.start))",
                     line: "  \(item.period(calendar: calendar).label) · \(itemText(item, calendar: calendar))")
            }
            // 老条目原样留在文件里（c2c3-v2 第 7 段）：这天有新主调就只用新的，没有才带老条目那几行
            if !headlineVisible {
                body += olds.map { Unit(key: "\(date)|\($0.conversationId)", line: "  旧格式 · \(legacyText($0, calendar: calendar))") }
            }
            guard headlineVisible || !body.isEmpty else { continue }
            let head = "\(dayLabel(date, calendar: calendar))：\(record.flatMap { headlineVisible ? headlineText($0) : nil } ?? "（旧格式，没有主调）")"
            lines.append(head)
            units.append(Unit(key: date, line: head))
            lines += body.map(\.line)
            units += body
        }
        func resolvedPending(_ id: String) -> [String] {
            openPending.map { $0[id] ?? [] }
                ?? latestOld[id].map { pendingItems($0.pending) }
                ?? latestHiddenOld[id].map { pendingItems($0.pending) } ?? []
        }
        let pending: [(String, [String])] = seenWindows.compactMap { id in
            let items = resolvedPending(id)
            return items.isEmpty ? nil : (id, items)
        }
        // 被挡掉的窗的待续本来也该带一行，同算一条
        hiddenCount += hiddenWindows.filter { !resolvedPending($0).isEmpty }.count
        let pendingUnits = pending.map { id, items in
            PendingUnit(conversationId: id,
                        line: "- 《\(windows[id].flatMap { $0.isEmpty ? nil : $0 } ?? "没有标题的窗口")》\(convTag(id))：\(items.joined(separator: "；"))")
        }
        // 段④：本窗只要待续不要时间轴 → 只出待续那一段（窗口还是按这几天时间轴里出现过的认）
        if !timelineLines {
            lines = []
            units = []
        }
        guard !lines.isEmpty || !pending.isEmpty else {
            return Injection(text: nil, units: [], hiddenCount: hiddenCount)
        }
        var text = timelineLines ? "[时间轴]（一天一条，05:00 换日；最近 \(fullDays) 天带各时段聊了什么，更早的只带一句主调）" : ""
        if !lines.isEmpty { text += "\n" + lines.joined(separator: "\n") }
        if !pendingUnits.isEmpty {
            if !text.isEmpty { text += "\n" }
            text += "[待续]（还没做完的；做完了 / 淡了用 pending_notes 标）\n" + pendingUnits.map(\.line).joined(separator: "\n")
        }
        return Injection(text: text, units: units, pendingUnits: pendingUnits, hiddenCount: hiddenCount)
    }

    /// 楼层入口：读这几天的月文件（组 prompt 在主线程，只读不建目录）
    static func injection(memoryRoot: URL, now: Date, currentConversationId: String, windowIds: Set<String>,
                          openPending: () -> [String: [String]]?, timelineLines: Bool = true,
                          hiddenConversations: Set<String> = []) -> Injection {
        let today = MemoryDay.key(now)
        guard let todayDate = MemoryDay.date(ofKey: today) else { return Injection(text: nil, units: []) }
        let dates = (0..<max(injectDays, 1)).compactMap { k in
            Calendar.current.date(byAdding: .day, value: -k, to: todayDate).map { MemoryDay.key(MemoryDay.boundary(of: $0)) }
        }
        let loaded = days(dates, in: dir(memoryRoot: memoryRoot))
        guard !loaded.days.isEmpty || !loaded.entries.isEmpty else { return Injection(text: nil, units: []) }
        return injection(records: loaded.days, entries: loaded.entries, today: today, currentConversationId: currentConversationId,
                         windowIds: windowIds, openPending: openPending(), timelineLines: timelineLines,
                         hiddenConversations: hiddenConversations)
    }

    // MARK: - 文件格式

    private static let itemMark = " <!-- item "

    private static func safe(_ s: String) -> String {
        SessionSummaryStore.oneLine(s).replacingOccurrences(of: "-->", with: "->")
    }

    private struct DayMeta: Codable {
        var date: String
        var headline: String?
        var topics: [String]
        var source: String
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = iso.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "日期认不出：\(s)"))
            }
            return date
        }
        return d
    }()

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// 只写老条目（三代搬迁的「正在搬」标记记原样用）
    static func render(_ list: [TimelineEntry], month: String) -> String {
        render(Month(entries: list), month: month)
    }

    static func render(_ m: Month, month: String) -> String {
        var blocks: [(day: String, order: Int, start: Date, text: String)] = []
        for r in m.days {
            var block = "## \(r.date) · \(safe(headlineText(r)))\n"
            block += "<!-- day \(json(DayMeta(date: r.date, headline: r.headline.map(safe), topics: r.topics.map(safe), source: r.source))) -->"
            if !r.topics.isEmpty { block += "\n话题：" + r.topics.map(safe).joined(separator: "、") }
            let items = r.items.sorted { $0.start < $1.start }
            for period in TimelinePeriod.allCases {
                let these = items.filter { $0.period() == period }
                guard !these.isEmpty else { continue }
                block += "\n### \(period.label)"
                for var item in these {
                    item.window = safe(item.window)
                    item.title = safe(item.title)
                    block += "\n- \(itemText(item))\(itemMark)\(json(item)) -->"
                }
            }
            blocks.append((r.date, 0, .distantPast, block))
        }
        for e in m.entries {
            // 窗口标题必须一行（带换行的话条目头和机读注释隔开，严格读整个月文件判坏）
            var block = "## \(rangeText(e)) · 《\(SessionSummaryStore.oneLine(e.title))》 · conv \(e.conversationId.prefix(8))\n"
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
            blocks.append((e.dayKey, 1, e.start, block))
        }
        let body = blocks.sorted { ($0.day, $0.order, $0.start) < ($1.day, $1.order, $1.start) }.map(\.text).joined(separator: "\n\n")
        return FrontmatterCodec.render(meta: [("month", month)], body: body)
    }

    /// 老条目的头：「MM-dd HH:mm–HH:mm」
    static func rangeText(_ e: TimelineEntry) -> String {
        let day = DateFormatter(); day.dateFormat = "MM-dd HH:mm"
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let sameDay = Calendar.current.isDate(e.start, inSameDayAs: e.end)
        return "\(day.string(from: e.start))–\(sameDay ? hm.string(from: e.end) : day.string(from: e.end))"
    }

    /// 只读老条目
    static func parse(_ raw: String) -> [TimelineEntry] {
        parseMonth(raw).entries
    }

    static func parseMonth(_ raw: String) -> Month {
        guard let (_, body) = FrontmatterCodec.parse(raw) else { return Month() }
        let lines = body.components(separatedBy: "\n")
        func blockStart(_ i: Int) -> Bool {
            lines[i].hasPrefix("## ") && i + 1 < lines.count && (lines[i + 1].hasPrefix("<!-- entry ") || lines[i + 1].hasPrefix("<!-- day "))
        }
        var out = Month()
        var i = 0
        while i < lines.count {
            guard blockStart(i) else { i += 1; continue }
            var j = i + 2
            while j < lines.count, !blockStart(j) { j += 1 }
            if lines[i + 1].hasPrefix("<!-- day ") {
                if let day = parseDay(meta: lines[i + 1], body: Array(lines[(i + 2)..<j])) { out.days.append(day) }
            } else if let e = parseEntry(heading: lines[i], meta: lines[i + 1], body: Array(lines[(i + 2)..<j])) {
                out.entries.append(e)
            }
            i = j
        }
        return out
    }

    private static func commentJSON(_ line: String, after mark: String) -> Data? {
        guard let a = line.range(of: mark), let b = line.range(of: " -->", options: .backwards), a.upperBound <= b.lowerBound else { return nil }
        return Data(line[a.upperBound..<b.lowerBound].utf8)
    }

    private static func parseDay(meta: String, body: [String]) -> TimelineDayRecord? {
        guard let data = commentJSON(meta, after: "<!-- day "), let m = try? decoder.decode(DayMeta.self, from: data) else { return nil }
        let items = body.filter { $0.hasPrefix("- ") && $0.contains(itemMark) }.compactMap { line in
            commentJSON(line, after: itemMark).flatMap { try? decoder.decode(TimelineDayRecord.Item.self, from: $0) }
        }
        return TimelineDayRecord(date: m.date, headline: m.headline, topics: m.topics, items: items, source: m.source)
    }

    private static func parseEntry(heading: String, meta: String, body: [String]) -> TimelineEntry? {
        let title = heading.range(of: "《").flatMap { a in heading.range(of: "》", range: a.upperBound..<heading.endIndex).map { String(heading[a.upperBound..<$0.lowerBound]) } } ?? ""
        let fields = Dictionary(meta.dropFirst(11).replacingOccurrences(of: " -->", with: "")
            .split(separator: " ").compactMap { pair -> (String, String)? in
                let kv = pair.split(separator: "=", maxSplits: 1)
                return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            }, uniquingKeysWith: { a, _ in a })
        guard let conv = fields["conv"] else { return nil }
        let v2 = fields["v"] == "2"
        var text: [String] = []
        var pending: [String] = []
        var inPending = false
        for l in body {
            if l.hasPrefix("待续：") {
                inPending = true
                let rest = String(l.dropFirst(3))
                if !(v2 && rest.trimmingCharacters(in: .whitespaces).isEmpty) { pending.append(rest) }
            } else if inPending {
                pending.append(v2 && l.hasPrefix("- ") ? String(l.dropFirst(2)) : l)
            } else {
                text.append(l)
            }
        }
        return TimelineEntry(
            start: fields["start"].flatMap(iso.date(from:)) ?? .distantPast,
            end: fields["end"].flatMap(iso.date(from:)) ?? .distantPast,
            conversationId: conv, title: title,
            text: text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            pending: pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            day: v2 ? fields["day"] : nil,
            lastNodeId: v2 ? fields["last"] : nil)
    }
}
