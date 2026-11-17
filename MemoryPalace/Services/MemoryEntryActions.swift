import MemoryCore
import Foundation
import SwiftData

/// 一条 C2 原子事实的改 / 删 / 钉 / 放回 / 新加，从哪个入口做都走这一处（粟粟 11-15「为什么记忆看一个条目在记忆-审计台和记忆-记忆是两回事」）：
/// 存盘、存不成放回原样、记进记忆日志（`MemoryAuditLog`，能 Undo）、发 `.memoryDidChange`。
/// 记忆页、整理台、常驻页、「想起来了」卡、mac 设置、详情页都调这里，不各存各的
@MainActor
enum MemoryEntryActions {
    typealias Change = (card: UUID, before: MemoryAuditLog.CardState, after: MemoryAuditLog.CardState?, full: MemoryAuditLog.FullCard?)

    struct Outcome {
        /// 存不成的那句；nil = 存成了（或者什么都没变）
        var error: String?
        /// 这一笔（没变 = nil）
        var entry: MemoryAuditLog.Entry?
        /// 这一笔记进了文件（记不进不拦操作，只是撤不回）
        var logged = false

        var ok: Bool { error == nil }
        /// 能撤的那一笔
        var undoable: MemoryAuditLog.Entry? { logged ? entry : nil }
    }

    /// 改库：动之前 / 之后逐张比，没变不存；存不成把这几张放回动之前（只放回自己动的，不 rollback 全 app 共用的主 context）；
    /// 存成了记一笔、发通知。`bulk` = 这一下是不是从「整批」的入口来的（见 `isBulk`），原样记进那一笔；
    /// actor / label / note / dream 原样记进那一笔（详细度重写用：actor 是重写它的模型）
    @discardableResult
    static func commit(_ ms: [Memory], profileId: String, context: ModelContext, bulk: Bool = false, now: Date = Date(),
                       actor: String = MemoryAuditLog.you, label: String? = nil, note: String? = nil, dream: String? = nil,
                       _ change: () -> Void) -> Outcome {
        let before = ms.map { ($0, MemoryAuditLog.CardState($0)) }
        change()
        let changes: [Change] = before.compactMap { m, was in
            let now = MemoryAuditLog.CardState(m)
            return now == was ? nil : (m.id, was, now, nil)
        }
        guard !changes.isEmpty else { return Outcome() }
        do {
            try context.save()
        } catch {
            for (m, was) in before { was.apply(to: m) }
            return Outcome(error: "保存失败：\(error.localizedDescription)")
        }
        let (entry, logged) = log(changes, profileId: profileId, bulk: bulk, now: now, actor: actor, label: label, note: note, dream: dream)
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return Outcome(entry: entry, logged: logged)
    }

    /// 存成了才记；记不进文件不拦操作
    static func log(_ changes: [Change], profileId: String, action: MemoryAuditLog.Action? = nil, bulk: Bool? = nil,
                    now: Date = Date(), actor: String = MemoryAuditLog.you, label: String? = nil, note: String? = nil,
                    dream: String? = nil) -> (MemoryAuditLog.Entry?, Bool) {
        guard let entry = MemoryAuditLog.entry(changes, actor: actor, label: label, note: note, dream: dream, action: action,
                                               bulk: bulk, now: now) else { return (nil, false) }
        do {
            try MemoryAuditLog.append(entry, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
            return (entry, true)
        } catch {
            return (entry, false)
        }
    }

    // MARK: - 几种动作

    /// 详情页的 Save：规则全在 `MemoryAudit.apply`（改了算 Approve、她改过记 100、**不钉**）
    static func save(_ edit: MemoryAudit.Edit, to m: Memory, context: ModelContext, now: Date = Date()) -> Outcome {
        commit([m], profileId: m.profileId, context: context, now: now) { MemoryAudit.apply(edit, to: m, now: now) }
    }

    static func approve(_ ms: [Memory], profileId: String, context: ModelContext) -> Outcome {
        commit(ms, profileId: profileId, context: context) { MemoryAudit.keep(ms) }
    }

    /// 删 = 进 Deleted（能 Restore，30 天内彻底删了也能从记忆日志放回）
    static func trash(_ ms: [Memory], profileId: String, context: ModelContext, bulk: Bool = false) -> Outcome {
        commit(ms, profileId: profileId, context: context, bulk: bulk) { MemoryAudit.trash(ms) }
    }

    /// 多选之后删的这一下算不算「整批」：把眼前列着的全选上了、而且不止一条（Select all 再 Delete N）。
    /// 她一条条点选了其中几条的不算；单张删的不算。整理台 ⋯ 里的 Delete all 不用问这里，本来就是整批
    static func isBulk(picked: Int, shown: Int) -> Bool {
        picked > 1 && picked >= shown
    }

    static func restore(_ ms: [Memory], profileId: String, context: ModelContext) -> Outcome {
        commit(ms, profileId: profileId, context: context) { MemoryAudit.restore(ms) }
    }

    /// 钉 / 取消钉（`MemoryPinPlan`：选中的全钉着 = 这次是取消）
    static func togglePin(_ ms: [Memory], profileId: String, context: ModelContext) -> Outcome {
        commit(ms, profileId: profileId, context: context) { MemoryPinPlan.apply(ms) }
    }

    /// 新加一条（记忆页的 ＋、mac 设置、Lite）：她亲手写的 = 直接算批过（Archive）、记「她改过」、置信度 100（她亲手定了别的以她的为准）；
    /// 有发生日（进得了对话，同 `MemoryCardTool` 的 add）。钉不钉只看她点没点 Pin。记一笔 Add（Undo = 进 Deleted）
    static func create(_ edit: MemoryAudit.Edit, pinned: Bool, profileId: String, context: ModelContext,
                       now: Date = Date()) -> (memory: Memory?, outcome: Outcome) {
        guard let text = MemoryAudit.cleaned(edit.text) else { return (nil, Outcome()) }
        let m = SwiftDataMemoryStore().insertUnsaved(content: text, category: MemoryAudit.cleaned(edit.category) ?? MemoryAuditTraits.plainCategory,
                                                     keywords: MemoryAudit.cleanedTags(edit.keywords), profileId: profileId,
                                                     isUserExplicit: pinned, extractedBy: manualWriter, sourceConversationId: nil,
                                                     sourceQuote: nil, sourceNodeId: nil, context: context)
        m.occurredDay = MemoryDay.key(now)
        m.subject = MemoryAudit.cleaned(edit.subject)
        m.speaker = MemoryAudit.cleaned(edit.speaker)
        m.importance = edit.importance.map { min(max($0, 1), 5) }
        m.confidence = edit.confidence.map { min(max($0, 0), 100) }
        if pinned { m.decayWeight = 1.0 }
        m.createdAt = now
        m.updatedAt = now
        m.userEditedAt = now
        m.reviewedAt = now
        do {
            try context.save()
        } catch {
            context.delete(m)
            return (nil, Outcome(error: "保存失败：\(error.localizedDescription)"))
        }
        let (entry, logged) = log([MemoryAuditLog.added(m, now: now)], profileId: profileId, action: .add, now: now)
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return (m, Outcome(entry: entry, logged: logged))
    }

    static let manualWriter = "manual"

    /// 撤一笔（Undo 浮条 / 记忆日志里那颗）：存不成整个放回；存成了把「撤回」本身也记一笔。返回浮条上那句和存不成的红字
    static func undo(_ entry: MemoryAuditLog.Entry, profileId: String, context: ModelContext) -> (text: String, error: String?) {
        let result = MemoryAuditLog.undo(entry, profileId: profileId, context: context)
        do {
            try context.save()
        } catch {
            context.rollback()
            return ("", "保存失败：\(error.localizedDescription)")
        }
        if let undone = result.entry {
            try? MemoryAuditLog.append(undone, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return (result.skipped == 0 ? "Undone \(result.restored)" : "Undone \(result.restored) · \(result.skipped) 张后来动过没撤", nil)
    }

    /// 浮条上的过去式（「Deleted 1」）
    static func past(_ a: MemoryAuditLog.Action) -> String {
        switch a {
        case .approve: return "Approved"
        case .delete: return "Deleted"
        case .restore: return "Restored"
        case .edit, .category, .importance: return "Edited"
        case .purge: return "Deleted forever"
        case .undo: return "Undone"
        case .mixed: return "Changed"
        case .add: return "Added"
        case .pin: return "Pinned"
        case .unpin: return "Unpinned"
        }
    }

    static func toastText(_ entry: MemoryAuditLog.Entry) -> String { "\(past(entry.action)) \(entry.items.count)" }
}

// MARK: - 一份列表的口径（记忆页和整理台同一套数）

/// 记忆页那排「全部 / Draft / Archive」；整理台就是只看 Draft 的那一面
enum MemoryListFilter: Hashable, CaseIterable {
    case all, draft, archive

    func matches(_ m: Memory) -> Bool {
        switch self {
        case .all: return m.supersededAt == nil
        case .draft: return MemoryAudit.state(of: m) == .unreviewed
        case .archive: return MemoryAudit.state(of: m) == .kept
        }
    }

    /// 三个数：和整理台顶上那三段同一个函数（`MemoryAudit.counts`，不带筛选）
    static func counts(_ memories: [Memory]) -> [MemoryListFilter: Int] {
        let c = MemoryAudit.counts(memories, filter: MemoryAudit.Filter())
        let draft = c[.unreviewed] ?? 0, archive = c[.kept] ?? 0
        return [.all: draft + archive, .draft: draft, .archive: archive]
    }
}

extension MemoryAudit {
    /// Deleted 的数（记忆页底那一行和整理台第三段同一个数）：删掉的原子事实 + {助手}自己记下的、划掉的
    static func deletedCount(_ memories: [Memory], selfMemories: [SelfMemory]) -> Int {
        memories.filter { $0.supersededAt != nil }.count + selfMemories.filter { !$0.isActive }.count
    }
}

extension MemoryAudit.Edit {
    /// 新加一条时的空草稿
    init(text: String = "", category: String = MemoryAuditTraits.plainCategory, importance: Int? = nil, subject: String? = nil,
         speaker: String? = nil, keywords: [String] = [], confidence: Int? = nil) {
        self.text = text
        self.category = category
        self.importance = importance
        self.subject = subject
        self.speaker = speaker
        self.keywords = keywords
        self.confidence = confidence
    }
}

// MARK: - 出处那一句

/// Source 托盘里标哪一句（粟粟 11-15：托盘倒出一整条几百字的消息，看不出是哪句）。
/// 库里没存「是哪一句」（写手只给消息编号），所以只在**靠得住**时标：条目正文和出处消息有一段一字不差的原文
/// （至少 6 个汉字，或至少 16 个字母 / 数字），而且这段在消息里只出现一次——标这一段所在的那一句（到句号 / 问号 / 叹号 / 分号 / 换行为止）。
/// 对不上、出现不止一次、整条消息就是这一句，都不标
enum MemorySourceSpot {
    static let minHan = 6
    static let minChars = 16
    /// 太长的消息不找（找最长公共片段是 正文长 × 消息长）
    static let maxMessage = 40_000

    static func locate(content: String, in message: String) -> Range<String.Index>? {
        let a = content.unicodeScalars.map(\.value)
        let scalars = Array(message.unicodeScalars), b = scalars.map(\.value)
        guard !a.isEmpty, !b.isEmpty, b.count <= maxMessage else { return nil }
        // 最长公共片段（逐行滚动的 DP）：记长度和它在消息里的结尾
        var prev = [Int](repeating: 0, count: b.count + 1), cur = prev
        var best = 0, bestEnd = 0
        for i in 1...a.count {
            let x = a[i - 1]
            for j in 1...b.count {
                if x == b[j - 1] {
                    let n = prev[j - 1] + 1
                    cur[j] = n
                    if n > best { best = n; bestEnd = j }
                } else {
                    cur[j] = 0
                }
            }
            swap(&prev, &cur)
        }
        guard best > 0 else { return nil }
        let run = Array(scalars[(bestEnd - best)..<bestEnd])
        let han = run.filter(isHan).count, chars = run.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.count
        guard han >= minHan || chars >= minChars else { return nil }
        guard occurrences(Array(b[(bestEnd - best)..<bestEnd]), in: b) == 1 else { return nil }
        // 往前到上一句的末尾；往后到这一句的末尾（片段自己以句末结尾就到它为止），连着的句末标点、收尾的引号括号一起带上
        var lo = bestEnd - best, hi = bestEnd
        while lo > 0, !isEnd(scalars, lo - 1) { lo -= 1 }
        if !isEnd(scalars, hi - 1) {
            while hi < scalars.count, !isEnd(scalars, hi) { hi += 1 }
            if hi < scalars.count { hi += 1 }
        }
        while hi < scalars.count, !isNewline(scalars[hi]), enders.contains(scalars[hi]) || closers.contains(scalars[hi]) { hi += 1 }
        while lo < hi, scalars[lo].properties.isWhitespace || closers.contains(scalars[lo]) { lo += 1 }
        let head = scalars[..<lo].allSatisfy { $0.properties.isWhitespace }
        let tail = scalars[hi...].allSatisfy { $0.properties.isWhitespace }
        guard !(head && tail), lo < hi else { return nil }
        let view = message.unicodeScalars
        return view.index(view.startIndex, offsetBy: lo)..<view.index(view.startIndex, offsetBy: hi)
    }

    private static let enders: Set<Unicode.Scalar> = ["。", "！", "？", "!", "?", "；", ";", "…"]
    private static let closers: Set<Unicode.Scalar> = ["」", "』", "”", "’", "\"", "'", "）", ")", "】"]

    private static func isNewline(_ s: Unicode.Scalar) -> Bool { s == "\n" || s == "\r" || s == "\u{2028}" || s == "\u{2029}" }

    /// 第 i 个字是不是一句的末尾（英文句号要后面跟空白或到头才算）
    private static func isEnd(_ b: [Unicode.Scalar], _ i: Int) -> Bool {
        guard i >= 0, i < b.count else { return false }
        if enders.contains(b[i]) || isNewline(b[i]) { return true }
        return b[i] == "." && (i + 1 == b.count || b[i + 1].properties.isWhitespace)
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
    }

    private static func occurrences(_ run: [UInt32], in b: [UInt32]) -> Int {
        guard !run.isEmpty, run.count <= b.count else { return 0 }
        var n = 0
        for start in 0...(b.count - run.count) where b[start] == run[0] && b[start..<(start + run.count)].elementsEqual(run) {
            n += 1
            if n > 1 { return n }
        }
        return n
    }
}
