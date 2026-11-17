import Foundation
import SwiftData

/// 整理台的操作记录和撤回（plan-memory-audit-log）。一笔 = 一次操作动过的卡，每张记动之前 / 动之后的样子；
/// 存成楼层记忆目录下只追加的一个文件（一行一笔 JSON），不改库结构。
/// 「C2 整理」写同一份（actor = `FragmentDream.actor`，一个结论一笔，带模型给的理由和那次做梦的记录编号）
enum MemoryAuditLog {
    static let fileName = "audit-log.jsonl"
    static let keepDays = 90
    /// 彻底删的整卡副本留多久（过了就真没了）
    static let fullCopyDays = 30
    static let you = "You"

    /// 写手给的四项：说的是谁 / 谁说的 / 标签 / 置信度（Edit 页能改）
    struct Traits: Codable, Equatable {
        var subject: String?
        var speaker: String?
        var keywords: [String]
        var confidence: Int?
    }

    /// 整理台会动到的那几个字段
    struct CardState: Codable, Equatable {
        var content: String
        var category: String
        var importance: Int?
        var reviewedAt: Date?
        var supersededAt: Date?
        var userEditedAt: Date?
        var updatedAt: Date
        /// nil = 加这一项之前记的老记录：不比、不放回
        var traits: Traits?
        /// 钉没钉住（`isUserExplicit`）；nil = 加这一项之前记的老记录：不比、不放回
        var pinned: Bool?
        /// 全部出处（`sourceNodeIds`，「C2 整理」并的时候会挂上去）；卡上没有记成空的；nil = 加这一项之前记的老记录。
        /// 是出处元数据、不是她写的东西：判「被动过、撤不了」不看它，`apply` 也不动它；只有撤的正是挂出处的那一笔才放回（`undo`）
        var sourceNodeIds: [String]?

        init(_ m: Memory) {
            content = m.content
            category = m.category
            importance = m.importance
            reviewedAt = m.reviewedAt
            supersededAt = m.supersededAt
            userEditedAt = m.userEditedAt
            updatedAt = m.updatedAt
            traits = Traits(subject: m.subject, speaker: m.speaker, keywords: m.keywords, confidence: m.confidence)
            pinned = m.isUserExplicit
            sourceNodeIds = m.sourceNodeIds ?? []
        }

        /// 存进文件的日子只到毫秒：比「还是不是那个样子」时按毫秒比
        func matches(_ other: CardState) -> Bool {
            func ms(_ d: Date?) -> Int64? { d.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } }
            return content == other.content && category == other.category && importance == other.importance
                && ms(reviewedAt) == ms(other.reviewedAt) && ms(supersededAt) == ms(other.supersededAt)
                && ms(userEditedAt) == ms(other.userEditedAt) && ms(updatedAt) == ms(other.updatedAt)
                && (traits == nil || other.traits == nil || traits == other.traits)
                && (pinned == nil || other.pinned == nil || pinned == other.pinned)
        }

        func apply(to m: Memory) {
            if m.content != content {
                m.content = content
                m.tokenCount = Memory.estimateTokens(content)
                m.embeddingData = nil
            }
            m.category = category
            m.importance = importance
            m.reviewedAt = reviewedAt
            m.supersededAt = supersededAt
            m.userEditedAt = userEditedAt
            m.updatedAt = updatedAt
            if let traits {
                m.subject = traits.subject
                m.speaker = traits.speaker
                m.keywords = traits.keywords
                m.confidence = traits.confidence
            }
            if let pinned { m.isUserExplicit = pinned }
        }

        /// 只放回出处（「C2 整理」落库失败回滚、撤挂出处的那一笔用）
        func applySources(to m: Memory) {
            if let sourceNodeIds { m.sourceNodeIds = sourceNodeIds.isEmpty ? nil : sourceNodeIds }
        }

        /// 两个样子只差出处
        func differsOnlyInSources(from other: CardState) -> Bool {
            guard sourceNodeIds != other.sourceNodeIds else { return false }
            var same = self
            same.sourceNodeIds = other.sourceNodeIds
            return same == other
        }
    }

    /// 彻底删之前留的整张卡（向量、热度这些能重算的不留）
    struct FullCard: Codable, Equatable {
        var profileId: String
        var keywords: [String]
        var isUserExplicit: Bool
        var extractedBy: String
        var sourceConversationId: String?
        var sourceQuote: String?
        var sourceNodeId: String?
        var subject: String?
        var speaker: String?
        var occurredDay: String?
        var emotion: Int?
        var resolved: Bool?
        var validUntil: Date?
        var createdAt: Date
        var organizedAt: Date?
        var organizedPage: String?
        var organizeRejectedAt: Date?
        var confidence: Int?
        var sourceNodeIds: [String]?

        init(_ m: Memory) {
            profileId = m.profileId
            keywords = m.keywords
            isUserExplicit = m.isUserExplicit
            extractedBy = m.extractedBy
            sourceConversationId = m.sourceConversationId
            sourceQuote = m.sourceQuote
            sourceNodeId = m.sourceNodeId
            subject = m.subject
            speaker = m.speaker
            occurredDay = m.occurredDay
            emotion = m.emotion
            resolved = m.resolved
            validUntil = m.validUntil
            createdAt = m.createdAt
            organizedAt = m.organizedAt
            organizedPage = m.organizedPage
            organizeRejectedAt = m.organizeRejectedAt
            confidence = m.confidence
            sourceNodeIds = m.sourceNodeIds
        }
    }

    struct Item: Codable, Equatable {
        var card: UUID
        var before: CardState
        /// nil = 这张被彻底删了
        var after: CardState?
        /// 只有彻底删带
        var full: FullCard?
    }

    enum Action: String, Codable {
        case approve = "Approve", delete = "Delete", restore = "Restore", edit = "Edit"
        case category = "Category", importance = "Importance", purge = "Delete forever", undo = "Undo", mixed = "Change"
        /// 新加一张（助手的 `memory_card`）；钉 / 取消钉（助手，或她在文件库里改 Pinned）
        case add = "Add", pin = "Pin", unpin = "Unpin"
    }

    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID()
        var at: Date
        var actor: String
        var action: Action
        var items: [Item]
        /// 这一笔是撤回哪一笔
        var undoOf: UUID?
        /// 下面三项只有「C2 整理」的那几笔带（她自己的操作都是 nil；老记录没有这几个字段）。
        /// label = 这是哪种结论（Keep / Drop / Merge / Rewrite），界面上代替 action 显示
        var label: String? = nil
        /// 模型给的一句理由
        var note: String? = nil
        /// 那次做梦的记录编号（点开看喂了什么、回了什么）
        var dream: String? = nil
        /// 这一笔从哪来的：nil = 整理台（老记录都是）；助手在聊天里动的 = `viaChat`，她在文件库里改的 = `viaFileLibrary`，
        /// CC 里的助手经 hub 动的 = `viaCC`
        var via: String? = nil
        /// 她在界面上做的这一笔是不是从「整批」的入口来的：true = 整理台 ⋯ 里的 Delete all、或把眼前列着的全选了再删
        /// （`MemoryEntryActions.isBulk`）；false = 逐条（单张，或她一条条点选的几张）。
        /// nil = 加这一项之前的老记录，或者不是她在界面上做的（助手 / 「C2 整理」/ Undo）
        var bulk: Bool? = nil
    }

    static let viaChat = "聊天"
    static let viaFileLibrary = "文件库"
    static let viaCC = "CC"

    // MARK: - 记

    /// 一张卡动之前 / 动之后比出来这是什么动作；没变 = nil
    static func action(before: CardState, after: CardState?) -> Action? {
        guard let after else { return .purge }
        if before == after { return nil }
        if before.supersededAt == nil, after.supersededAt != nil { return .delete }
        if before.supersededAt != nil, after.supersededAt == nil { return .restore }
        if before.content != after.content || traitsEdited(before, after) { return .edit }
        if before.category != after.category { return .category }
        if before.importance != after.importance { return .importance }
        if let was = before.pinned, let now = after.pinned, was != now { return now ? .pin : .unpin }
        if before.reviewedAt == nil, after.reviewedAt != nil { return .approve }
        return .mixed
    }

    /// 四项是不是她改的：只改类别 / 重要度带出来的那一下「人改过 = 置信度 100」不算，那一笔还叫 Category / Importance
    private static func traitsEdited(_ before: CardState, _ after: CardState) -> Bool {
        guard before.traits != after.traits else { return false }
        guard before.category != after.category || before.importance != after.importance,
              var was = before.traits, let now = after.traits, now.confidence == MemoryAudit.handEditedConfidence else { return true }
        was.confidence = now.confidence
        return was != now
    }

    /// 把一次操作排成一笔：没变的卡不记；一张都没变 = nil。动作各不相同时记成 Change。
    /// `action` 给了就照它记（新加一张：动之前 = 同一张卡标着已删，见 `added`）
    static func entry(_ changes: [(card: UUID, before: CardState, after: CardState?, full: FullCard?)],
                      actor: String = you, undoOf: UUID? = nil, label: String? = nil, note: String? = nil, dream: String? = nil,
                      action override: Action? = nil, via: String? = nil, bulk: Bool? = nil, now: Date = Date()) -> Entry? {
        var items: [Item] = []
        var actions = Set<Action>()
        for change in changes {
            guard let action = action(before: change.before, after: change.after) else { continue }
            // 只挂了出处的那张照记（撤得回），但不改这一笔叫什么（并卡「那张已经说全了」还是 Delete）
            if change.after.map({ !change.before.differsOnlyInSources(from: $0) }) ?? true { actions.insert(action) }
            items.append(Item(card: change.card, before: change.before, after: change.after, full: change.after == nil ? change.full : nil))
        }
        guard !items.isEmpty else { return nil }
        return Entry(at: now, actor: actor, action: undoOf != nil ? .undo : (override ?? (actions.count == 1 ? actions.first! : .mixed)), items: items, undoOf: undoOf,
                     label: label, note: note, dream: dream, via: via, bulk: bulk)
    }

    /// 新加的一张怎么记：动之后 = 这张卡现在的样子，动之前 = 同一张卡标着已删（库里本来没有它）。
    /// 这样 Undo 一笔 Add = 这张进 Deleted（整理台里还能 Restore / 彻底删），不用另写一套撤回
    static func added(_ m: Memory, now: Date = Date()) -> (card: UUID, before: CardState, after: CardState?, full: FullCard?) {
        let after = CardState(m)
        var before = after
        before.supersededAt = now
        return (m.id, before, after, nil)
    }

    // MARK: - 存

    static func url(memoryRoot: URL) -> URL { memoryRoot.appendingPathComponent(fileName) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    static func append(_ entry: Entry, memoryRoot: URL) throws {
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let file = url(memoryRoot: memoryRoot)
        try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file, options: .atomic)
        }
    }

    /// 新的在前；读不懂的行跳过
    static func load(memoryRoot: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url(memoryRoot: memoryRoot), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }.reversed()
    }

    /// 清过期的：超过 keepDays 的整笔丢掉；超过 fullCopyDays 的彻底删副本拿掉（那一笔还在，只是放不回来了）。有变化才重写文件
    static func prune(memoryRoot: URL, now: Date = Date()) {
        let all = Array(load(memoryRoot: memoryRoot).reversed())
        let keepAfter = now.addingTimeInterval(-Double(keepDays) * 86400), fullAfter = now.addingTimeInterval(-Double(fullCopyDays) * 86400)
        var kept = all.filter { $0.at >= keepAfter }
        for i in kept.indices where kept[i].at < fullAfter {
            for j in kept[i].items.indices { kept[i].items[j].full = nil }
        }
        guard kept != all else { return }
        let lines = kept.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url(memoryRoot: memoryRoot), atomically: true, encoding: .utf8)
    }

    // MARK: - 撤

    /// 已经被撤回过的那些笔
    static func undone(_ entries: [Entry]) -> Set<UUID> { Set(entries.compactMap(\.undoOf)) }

    /// 这一笔还能不能撤：没被撤过，且至少有一张放得回去（彻底删的要副本还在）
    static func canUndo(_ entry: Entry, in entries: [Entry]) -> Bool {
        !undone(entries).contains(entry.id) && entry.items.contains { $0.after != nil || $0.full != nil }
    }

    struct UndoResult: Equatable {
        var restored = 0
        /// 后来又被动过、或者放不回去的
        var skipped = 0
        var entry: Entry?
    }

    /// 撤回一笔：只把「还停在这一笔之后那个样子」的卡放回去；彻底删的按副本重新放回库（库里已经有同一张就跳过）。
    /// 只改 context，不存盘、不写记录——调用方存成了再 `append(result.entry)`
    static func undo(_ entry: Entry, profileId: String, context: ModelContext, now: Date = Date()) -> UndoResult {
        let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = UndoResult()
        var changes: [(card: UUID, before: CardState, after: CardState?, full: FullCard?)] = []
        for item in entry.items {
            if let after = item.after, item.before.differsOnlyInSources(from: after) {
                // 只挂了出处的那张（「C2 整理」并卡）：只看出处还是不是挂上之后那样，别的字段她后来改没改都不碍事，也不动
                guard let memory = byId[item.card], (memory.sourceNodeIds ?? []) == after.sourceNodeIds else { result.skipped += 1; continue }
                var was = CardState(memory)
                was.sourceNodeIds = after.sourceNodeIds
                item.before.applySources(to: memory)
                changes.append((item.card, was, CardState(memory), nil))
            } else if let after = item.after {
                guard let memory = byId[item.card], CardState(memory).matches(after) else { result.skipped += 1; continue }
                item.before.apply(to: memory)
                // 出处不跟着放回：之后挂上去的出处留着（撤的正是挂出处的那一笔时，它也改了正文，出处一起放回）
                if item.before.sourceNodeIds != after.sourceNodeIds, (memory.sourceNodeIds ?? []) == after.sourceNodeIds {
                    item.before.applySources(to: memory)
                }
                changes.append((item.card, after, item.before, nil))
            } else {
                guard let full = item.full, full.profileId == profileId, byId[item.card] == nil else { result.skipped += 1; continue }
                let memory = revive(item.card, state: item.before, full: full)
                context.insert(memory)
                // 放回来的卡还在 Deleted 里（彻底删之前的样子）；这一笔撤回再被撤也只是让它留在 Deleted
                var gone = item.before
                gone.updatedAt = now
                changes.append((item.card, gone, item.before, nil))
            }
            result.restored += 1
        }
        result.entry = Self.entry(changes, undoOf: entry.id, now: now)
        return result
    }

    private static func revive(_ id: UUID, state: CardState, full: FullCard) -> Memory {
        let m = Memory(content: state.content, category: state.category, keywords: full.keywords, profileId: full.profileId,
                       isUserExplicit: full.isUserExplicit, extractedBy: full.extractedBy, sourceConversationId: full.sourceConversationId)
        m.id = id
        m.sourceQuote = full.sourceQuote
        m.sourceNodeId = full.sourceNodeId
        m.subject = full.subject
        m.speaker = full.speaker
        m.occurredDay = full.occurredDay
        m.emotion = full.emotion
        m.resolved = full.resolved
        m.validUntil = full.validUntil
        m.createdAt = full.createdAt
        m.organizedAt = full.organizedAt
        m.organizedPage = full.organizedPage
        m.organizeRejectedAt = full.organizeRejectedAt
        m.confidence = full.confidence
        m.sourceNodeIds = full.sourceNodeIds
        state.apply(to: m)
        return m
    }

    // MARK: - 她逐条删过的（「C2 整理」拿来当「删过的卡」：删过的事不再记）

    /// 这一笔是不是她本人做的：她在界面上（整理台 / 记忆页 / 详情页 /「想起来了」卡）或文件库里动的。
    /// 助手（聊天里 / CC）和「C2 整理」的不算——就算助手的名字正好也叫 You，来处（`via`）也对不上
    static func isHers(_ entry: Entry) -> Bool {
        entry.actor == you && (entry.via == nil || entry.via == viaFileLibrary)
    }

    /// 这一笔算不算她「逐条」做的（整批清掉的不算「别再记」，粟粟 11-15）：有 `bulk` 标记的照标记；没有的是老记录，走下面那条退路
    static func isOneByOne(_ entry: Entry) -> Bool {
        guard isHers(entry) else { return false }
        return entry.bulk.map { !$0 } ?? legacyOneByOne(entry)
    }

    /// 只管加 `bulk` 标记之前的老记录：那时候日志分不清是单张删、多选删还是 Delete all，只动了一条的才算逐条。
    /// 新写的记录都带标记，不走这里
    static func legacyOneByOne(_ entry: Entry) -> Bool {
        entry.items.count == 1
    }

    /// 按日志从旧到新走一遍：现在还停在「她逐条删掉」的那些卡，值 = 那一下写上的 `supersededAt`。
    /// 每张卡只看让它变成删掉状态的最后那一笔：她逐条删的才算；「C2 整理」的 Drop / Merge、助手删的、她整批删的都不算；
    /// 后来 Restore 了（或者那一笔被 Undo 了）就不再算；Undo = 回到被撤那一笔之前的样子（撤掉一笔 Restore = 又回到原来那次删）。
    /// 日志里没有的删法（没留痕的老入口、过了保留天数被清掉的）认不出来，不算。
    /// `entries` 照 `load` 给的顺序（新的在前）
    static func handDeletedStamps(_ entries: [Entry]) -> [UUID: Date] {
        /// 一张卡现在按日志是怎么被删的：是不是她逐条删的、那一下写上的时间
        struct Deletion {
            var oneByOne: Bool
            var at: Date
        }
        var now: [UUID: Deletion] = [:]
        /// 每一笔动某张卡之前，那张卡是什么样（没删 = 没有这一项）：给 Undo 放回去
        var before: [UUID: [UUID: Deletion]] = [:]
        for entry in entries.reversed() {
            for item in entry.items {
                let was = now[item.card]
                before[entry.id, default: [:]][item.card] = was
                if let undone = entry.undoOf {
                    now[item.card] = before[undone]?[item.card]
                } else if item.before.supersededAt == nil, let at = item.after?.supersededAt {
                    now[item.card] = Deletion(oneByOne: isOneByOne(entry), at: at)
                } else if item.before.supersededAt != nil, item.after?.supersededAt == nil {
                    // Restore / 新加的一张 / 彻底删：不再是「删掉了还在库里」
                    now[item.card] = nil
                }
            }
        }
        return now.filter(\.value.oneByOne).mapValues(\.at)
    }

    /// 这张卡现在的删掉状态是不是日志里她逐条删的那一下（按毫秒比，同 `CardState.matches`）：
    /// 对不上 = 之后又被没留痕的路子动过（放回来又被别的删掉），不算
    static func isHandDeleted(supersededAt: Date?, stamp: Date?) -> Bool {
        guard let supersededAt, let stamp else { return false }
        func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        return ms(supersededAt) == ms(stamp)
    }

    /// 哪些卡是「她逐条删过的」。`cards` = 卡的 id 和它现在的 `supersededAt`；`entries` 照 `load` 给的顺序（新的在前）
    static func handDeleted(_ cards: [(id: UUID, supersededAt: Date?)], entries: [Entry]) -> Set<UUID> {
        let stamps = handDeletedStamps(entries)
        return Set(cards.filter { isHandDeleted(supersededAt: $0.supersededAt, stamp: stamps[$0.id]) }.map(\.id))
    }
}
