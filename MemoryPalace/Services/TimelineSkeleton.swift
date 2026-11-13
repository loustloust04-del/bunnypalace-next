import MemoryCore
import Foundation

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
