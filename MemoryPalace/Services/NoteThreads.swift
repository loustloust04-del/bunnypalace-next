import Foundation

// 批注时间线规则（plan-reading-marks §1 契约），读书（TXT / PDF）和聊天等处共用。
//
// - 「一处」= 同章同起止（PDF 同页同框）的所有根笔画；时间线挂在最早那道上。
// - 时间线的条目 = 这处根笔画里写了内容的 + 挂在它们下面的回复，按 `createdAt` 排。
// - 删条目永不级联；删根那条只清内容、留笔画。
// - 删一道笔画：这处还有别的笔画 → 它的内容 / 回复转挂到剩下最早那道；没有了 → 整处删。
// - 整处删只删你的笔画和你写的；AI 写的留下（不可删对方笔迹），挂空了就自己成一处。

/// 能进时间线的一条划线 / 批注。读书（BookStore.Note）和聊天等处（ChatHighlight）各自实现。
protocol ThreadMark {
    var id: String { get }
    var replyTo: String? { get set }
    var createdAt: Date { get set }
    var content: String { get set }
    /// highlight（只划线）/ note（有批注）/ aiBubble（问 AI 的占位）
    var kind: String { get set }
    var role: String { get }
    var color: String? { get set }
    var style: String? { get set }
    /// 划的那段原文
    var quoteText: String { get }
    var strokeColorHex: String { get }
    var strokeStyle: HighlightStyle { get }
    /// 问 AI 的占位条目对应的主对话消息（点「看完整对话」）；没有就 nil
    var chatMessageId: String? { get }
    /// 同一处（读书：同章同起止 / 同页同框；聊天：同锚同原文）
    func samePlace(as other: Self) -> Bool
    /// 在这一处下面挂一条回复
    func reply(content: String, at: Date) -> Self
}

/// 一处：这处的根笔画，按时间排；第一道挂时间线
struct MarkPlace<M: ThreadMark>: Identifiable {
    let strokes: [M]
    var primary: M { strokes[0] }
    var id: String { primary.id }
}

extension BookStore.Note: ThreadMark {
    var quoteText: String { anchorText }
    var chatMessageId: String? { kind == "aiBubble" ? messageId.flatMap { $0.isEmpty ? nil : $0 } : nil }

    func samePlace(as other: BookStore.Note) -> Bool {
        chapter == other.chapter && anchorStart == other.anchorStart && anchorEnd == other.anchorEnd
            && (rects ?? []) == (other.rects ?? [])
    }

    func reply(content: String, at: Date) -> BookStore.Note {
        BookStore.Note(id: UUID().uuidString, chapter: chapter, anchorText: anchorText,
                       anchorStart: anchorStart, anchorEnd: anchorEnd, kind: "note",
                       content: content, role: "user", messageId: nil, createdAt: at, replyTo: id)
    }
}

enum NoteThreads {
    typealias Note = BookStore.Note
    typealias Place = MarkPlace<BookStore.Note>

    /// 某条（根或回复）所在的那一处
    static func place<M: ThreadMark>(of id: String, in notes: [M]) -> MarkPlace<M>? {
        guard var n = notes.first(where: { $0.id == id }) else { return nil }
        if let parent = n.replyTo, let root = notes.first(where: { $0.id == parent }) { n = root }
        guard n.replyTo == nil else { return nil }
        let strokes = notes.filter { $0.replyTo == nil && $0.samePlace(as: n) }.sorted(by: earlier)
        return strokes.isEmpty ? nil : MarkPlace(strokes: strokes)
    }

    /// 点中的一串 id → 去重后的几处（按最早时间排）
    static func places<M: ThreadMark>(for ids: [String], in notes: [M]) -> [MarkPlace<M>] {
        var seen = Set<String>()
        return ids.compactMap { place(of: $0, in: notes) }
            .filter { seen.insert($0.id).inserted }
            .sorted { earlier($0.primary, $1.primary) }
    }

    static func entries<M: ThreadMark>(of place: MarkPlace<M>, in notes: [M]) -> [M] {
        let ids = Set(place.strokes.map(\.id))
        let written = place.strokes.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let replies = notes.filter { $0.replyTo.map(ids.contains) ?? false }
        return (written + replies).sorted(by: earlier)
    }

    /// 选区和已有某处完全相同 → 那一处（加笔记进它的时间线）
    static func existingPlace(chapter: Int, start: Int, end: Int, rects: [[Double]]? = nil, in notes: [Note]) -> Place? {
        guard let hit = notes.first(where: {
            $0.replyTo == nil && $0.chapter == chapter && $0.anchorStart == start && $0.anchorEnd == end
                && ($0.rects ?? []) == (rects ?? [])
        }) else { return nil }
        return place(of: hit.id, in: notes)
    }

    /// 再写一条：最早那道还没写过内容（只划了线）→ 写进它；否则挂成回复
    @discardableResult
    static func addEntry<M: ThreadMark>(_ content: String, to place: MarkPlace<M>, in notes: inout [M], now: Date = Date()) -> String {
        let p = place.primary
        if p.role == "user", p.kind == "highlight", p.content.isEmpty,
           let i = notes.firstIndex(where: { $0.id == p.id }) {
            notes[i].content = content
            notes[i].kind = "note"
            notes[i].createdAt = min(notes[i].createdAt, now)
            return p.id
        }
        let r = p.reply(content: content, at: now)
        notes.append(r)
        return r.id
    }

    static func editEntry<M: ThreadMark>(_ id: String, content: String, in notes: inout [M]) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].content = content
    }

    /// 删一条：回复直接删；根那条只清内容（笔画和后面的条目都留着）
    static func deleteEntry<M: ThreadMark>(_ id: String, in notes: inout [M]) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[i].replyTo != nil {
            notes.remove(at: i)
        } else {
            notes[i].content = ""
            if notes[i].kind == "note" { notes[i].kind = "highlight" }
        }
    }

    /// 删一道笔画（调色条的垃圾桶 / 小窗里某道颜色）
    static func removeStroke<M: ThreadMark>(_ id: String, in notes: inout [M]) {
        guard let place = place(of: id, in: notes), place.strokes.contains(where: { $0.id == id }) else { return }
        let rest = place.strokes.filter { $0.id != id }
        guard let heir = rest.first else {
            removePlace(place, in: &notes)
            return
        }
        for i in notes.indices where notes[i].replyTo == id { notes[i].replyTo = heir.id }
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.remove(at: i)
        } else {
            // 写过的内容不丢：变成挂在剩下那道上的一条（时间不变）
            notes[i].replyTo = heir.id
            notes[i].color = nil
            notes[i].style = nil
        }
    }

    /// 删掉这处划线：你的笔画和你写的一起删；AI 写的留下，挂空的自己成一处
    static func removePlace<M: ThreadMark>(_ place: MarkPlace<M>, in notes: inout [M]) {
        let strokeIds = Set(place.strokes.map(\.id))
        notes.removeAll { n in
            n.role != "ai" && (strokeIds.contains(n.id) || (n.replyTo.map(strokeIds.contains) ?? false))
        }
        for i in notes.indices {
            if let r = notes[i].replyTo, strokeIds.contains(r) { notes[i].replyTo = nil }
        }
    }

    /// 书摘卡 / 列表用：这处最新的一条内容 + 一共几条
    static func summary<M: ThreadMark>(of place: MarkPlace<M>, in notes: [M]) -> (latest: String?, count: Int) {
        let list = entries(of: place, in: notes).filter { $0.kind != "aiBubble" || !$0.content.isEmpty }
        return (list.last?.content.trimmingCharacters(in: .whitespacesAndNewlines), list.count)
    }

    /// 落盘时间只到秒，同一秒的并列靠 sorted 稳定排序留数组（写入）先后
    private static func earlier<M: ThreadMark>(_ a: M, _ b: M) -> Bool {
        a.createdAt < b.createdAt
    }
}
