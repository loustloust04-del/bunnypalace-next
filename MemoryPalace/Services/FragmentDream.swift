import MemoryCore
import Foundation
import SwiftData

/// 「C2 整理」（plan-c2-dream）：C2 写手每写成一批新卡，自动给这批新卡下结论——
/// Keep 留 / Drop 删 / Merge 并进已有的 / Rewrite 改对再留 / Unsure 拿不准。
/// 名字学的是 Anthropic 那篇里的「做梦」；**不是 B3「小克做梦」**（那个没做）。
/// 纯逻辑（捞相关的旧卡、提示词、解码校验）在包里 `FragmentVerdict`；这里是 app 这一半：
/// 取材料 → 调一次模型（不带工具，受写入预算管）→ 结论落库 → 每个结论记一笔审计日志（能 Undo）
/// → 存这次喂了什么、回了什么 → 记一行记忆日志。
/// 没跑成（开关关着 / 预算闸 / 断网 / 两次格式都不对 / 存不上）= 这批卡原样留在 Draft，什么都不动，不影响写手的水位
enum FragmentDream {
    /// 审计日志和界面上的名字
    static let actor = "C2 整理"
    /// 写完自动整理一遍（默认开）
    static let enabledKey = "mem_c2_dream"
    /// 整理留下的卡要我批（默认开）；关 = 判 Keep / Rewrite 的由做梦写上 `reviewedAt`，只有 Unsure 的等她
    static let reviewKey = "mem_c2_dream_review"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func needsReview(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: reviewKey) as? Bool ?? true
    }

    // MARK: - 进来的东西

    struct Input {
        let profileId: String
        let conversationId: String
        let windowTitle: String
        let names: MemoryExtractor.Names
        /// 这批新卡出自的那段对话（写手这一批读的那一截）
        let messages: [FragmentPool.Message]
        /// 写手这一批刚落库的卡
        let cardIds: [UUID]
        /// 聊天时每轮本来就带着的内容（她手写的那几段；CC 窗口 = 空）
        let resident: [FragmentVerdict.ResidentSection]
        let modelName: String
        let caller: SessionSegmentWriter.Caller
        /// 日志那条后面带的（「重新记 · 第 2 / 5 批」）
        var label: String? = nil
        var limits = FragmentVerdict.Limits()
    }

    // MARK: - 取材料（主线程）

    /// 送去的那一刻的样子：落库前拿它核对卡有没有被别人动过
    struct Snapshot {
        /// 页（`pages`）不在主线程取：`perform` 读完盘再填
        var material: FragmentVerdict.Material
        let related: FragmentVerdict.Related
        /// 送去时每张卡（新卡 + 喂进去的已有卡和删过的卡）的正文
        let contents: [String: String]
        /// 她改过详细度的卡（`CardDetailRewrite.protected`）：同她改过的一样不许改正文
        var detailed: Set<UUID> = []
    }

    /// 写手刚写的、还没人碰过的 Draft
    static func isFreshDraft(_ m: Memory) -> Bool {
        m.supersededAt == nil && m.reviewedAt == nil && m.userEditedAt == nil && !m.isUserExplicit
    }

    /// 不许改的旧卡：她改过正文、钉住的、已经整理进 wiki 页的
    static func isProtected(_ m: Memory) -> Bool {
        m.userEditedAt != nil || m.isUserExplicit || m.organizedPage != nil
    }

    /// 能当「已有的卡」的：没删、会被用到的（C2 写的或钉住的；改版前没人读的老档案并进去等于丢），不是整理进私人页的
    static func inPool(_ m: Memory) -> Bool {
        m.supersededAt == nil && (m.isFragment || m.isUserExplicit)
            && !(m.organizedPage.map(WikiProposalSources.isPrivate) ?? false)
    }

    /// 能当「删过的卡」的：现在还删着、而且是她逐条删的那一下（`handDeleted` = `MemoryAuditLog.handDeletedStamps`），不是整理进私人页的。
    /// 她整批清掉的、「C2 整理」或助手删的都不算「别再记」
    static func isHandDeleted(_ m: Memory, handDeleted: [UUID: Date]) -> Bool {
        MemoryAuditLog.isHandDeleted(supersededAt: m.supersededAt, stamp: handDeleted[m.id])
            && !(m.organizedPage.map(WikiProposalSources.isPrivate) ?? false)
    }

    /// `handDeleted` = 按审计日志她逐条删过的那些（`perform` 在后台读好传进来）；不给 = 材料里没有「删过的卡」。
    /// `detailed` = 按审计日志她改过详细度的那些：当带锁的卡（不许改正文）
    @MainActor
    static func snapshot(_ input: Input, context: ModelContext, handDeleted: [UUID: Date] = [:], detailed: Set<UUID> = []) -> Snapshot? {
        let all = SwiftDataMemoryStore().listAll(profileId: input.profileId, context: context)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(input.cardIds)
        let fresh = input.cardIds.compactMap { byId[$0] }.filter(isFreshDraft)
        guard !fresh.isEmpty else { return nil }
        let position = Dictionary(input.messages.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        let new = fresh.map { m in
            FragmentVerdict.NewCard(id: m.id.uuidString, content: m.content, subject: m.subject, speaker: m.speaker,
                                    message: m.sourceNodeId.flatMap { position[$0] })
        }
        let pool = all.filter { !wanted.contains($0.id) && (inPool($0) || isHandDeleted($0, handDeleted: handDeleted)) }
            .sorted { $0.createdAt < $1.createdAt }.map { m in
                FragmentVerdict.ArchiveCard(id: m.id.uuidString, content: m.content, subject: m.subject,
                                            otherWindow: m.sourceConversationId != input.conversationId,
                                            isProtected: isProtected(m) || detailed.contains(m.id),
                                            isDeleted: m.supersededAt != nil)
            }
        let related = FragmentVerdict.related(to: new, in: pool, limits: input.limits)
        let lines = input.messages.map { FragmentVerdict.Line(role: $0.role, text: $0.content, at: $0.date.map { stamp.string(from: $0) }) }
        let material = FragmentVerdict.Material(windowTitle: input.windowTitle, names: input.names, lines: lines, new: new,
                                                existing: related.existing, deleted: related.deleted)
        var contents: [String: String] = [:]
        for card in new { contents[card.id] = card.content }
        for card in related.existing + related.deleted { contents[card.id] = card.content }
        return Snapshot(material: material, related: related, contents: contents, detailed: detailed)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 结论落库（主线程）

    /// 一张新卡最后怎么了
    enum Applied: String, Codable {
        /// 留在 Draft 等她批
        case kept
        /// 留下并由做梦批过（「要我批」关着）
        case approved
        case dropped
        case merged
        /// 改对了，留在 Draft
        case rewritten
        /// 改对了并由做梦批过
        case rewrittenApproved
        case unsure
        /// 送去之后她动过这张，没碰
        case skipped

        /// 界面上那个英文词
        var label: String {
            switch self {
            case .kept, .approved: return "Keep"
            case .dropped: return "Drop"
            case .merged: return "Merge"
            case .rewritten, .rewrittenApproved: return "Rewrite"
            case .unsure: return "Unsure"
            case .skipped: return "Skipped"
            }
        }
    }

    struct CardOutcome: Equatable {
        let card: UUID
        var applied: Applied
        /// 这一下为什么没照模型说的做（落库时发现对不上）；照做了 = nil
        var problem: String?
        var verdict: FragmentVerdict.Verdict
        /// 记进审计日志的那一笔（没动库 = nil）
        var entry: UUID?
    }

    struct ApplyResult {
        var outcomes: [CardOutcome] = []
        /// 存不上：一张都没动
        var saveError: String?
    }

    /// 把结论落到库里。删 = 软删；并 = 就地改那张已有的卡（只动正文，置信度取两张里高的）、新卡软删，新卡的出处挂到那张上（`mergedSources`，
    /// 受保护的也挂：挂出处不改她写的正文）；改 = 换新卡正文；
    /// Keep / Unsure 留在 Draft（「要我批」关着时 Keep、Rewrite 由做梦写上 `reviewedAt`）。
    /// 落库前逐张复核：新卡还是送去时那个样子才动；要改的那张已有卡没被动过、没带锁才改，对不上就降成 Unsure。
    /// 一次存盘；存不上把动过的字段全放回去。存成了才记审计日志（一个结论一笔）
    @MainActor
    static func apply(_ verdicts: [FragmentVerdict.Verdict], snapshot: Snapshot, input: Input, recordId: String,
                      needsReview: Bool, context: ModelContext, memoryRoot: URL, now: Date = Date()) -> ApplyResult {
        let all = SwiftDataMemoryStore().listAll(profileId: input.profileId, context: context)
        let byId = Dictionary(all.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        typealias Change = (card: UUID, before: MemoryAuditLog.CardState, after: MemoryAuditLog.CardState?, full: MemoryAuditLog.FullCard?)
        var result = ApplyResult()
        var pending: [(index: Int, label: String, note: String?, touched: [(Memory, MemoryAuditLog.CardState)])] = []
        var rewrittenTargets = Set<String>()

        func setText(_ m: Memory, _ text: String) {
            m.content = text
            m.tokenCount = Memory.estimateTokens(text)
            m.embeddingData = nil
            m.updatedAt = now
        }

        let position = Dictionary(input.messages.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        /// 并：新卡的出处挂到那张已有的卡上（同一个窗口才挂）；挂了返回 true
        func addSources(of new: Memory, to target: Memory) -> Bool {
            let had = target.sourceNodeIds ?? target.sourceNodeId.map { [$0] } ?? []
            guard new.sourceConversationId == target.sourceConversationId,
                  let merged = mergedSources(had, new.sourceNodeIds ?? new.sourceNodeId.map { [$0] } ?? [], position: position),
                  merged != had else { return false }
            target.sourceNodeIds = merged
            return true
        }

        for verdict in verdicts {
            guard let id = UUID(uuidString: verdict.card) else { continue }
            var outcome = CardOutcome(card: id, applied: .unsure, problem: nil, verdict: verdict, entry: nil)
            guard let new = byId[verdict.card], isFreshDraft(new), new.content == snapshot.contents[verdict.card] else {
                outcome.applied = .skipped
                outcome.problem = "送去之后这条被动过，没碰"
                result.outcomes.append(outcome)
                continue
            }
            let before = MemoryAuditLog.CardState(new)
            switch verdict.action {
            case .unsure:
                outcome.applied = .unsure
            case .keep:
                if needsReview {
                    outcome.applied = .kept
                } else {
                    new.reviewedAt = now
                    outcome.applied = .approved
                    pending.append((result.outcomes.count, Applied.approved.label, verdict.why, [(new, before)]))
                }
            case .drop:
                MemoryAudit.trash([new], now: now)
                outcome.applied = .dropped
                pending.append((result.outcomes.count, Applied.dropped.label, verdict.why, [(new, before)]))
            case .rewrite:
                guard let text = verdict.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    outcome.problem = "没给改好的全文"
                    break
                }
                if text != new.content { setText(new, text) }
                if let speaker = verdict.origin.flatMap({ FragmentPool.wholeOrigins[$0] }), speaker != new.speaker {
                    new.speaker = speaker
                    new.updatedAt = now
                }
                if !needsReview { new.reviewedAt = now }
                outcome.applied = needsReview ? .rewritten : .rewrittenApproved
                pending.append((result.outcomes.count, outcome.applied.label, verdict.why, [(new, before)]))
            case .merge:
                guard let ref = verdict.ref, let target = byId[ref], target.supersededAt == nil else {
                    outcome.problem = "要并进去的那条已经不在了"
                    break
                }
                if let text = verdict.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != target.content {
                    guard target.content == snapshot.contents[ref] else {
                        outcome.problem = "要改的那条送去之后被动过"
                        break
                    }
                    guard !isProtected(target), !snapshot.detailed.contains(target.id) else {
                        outcome.problem = FragmentVerdict.protectedProblem(input.names)
                        break
                    }
                    let was = MemoryAuditLog.CardState(target)
                    setText(target, text)
                    if let c = new.confidence { target.confidence = max(target.confidence ?? c, c) }
                    _ = addSources(of: new, to: target)
                    rewrittenTargets.insert(ref)
                    MemoryAudit.trash([new], now: now)
                    outcome.applied = .merged
                    pending.append((result.outcomes.count, Applied.merged.label, verdict.why, [(new, before), (target, was)]))
                } else {
                    // 「那张已经说全了」：那张要是送去之后被她改了，这句就不一定还成立（这次做梦自己改的不算）
                    guard target.content == snapshot.contents[ref] || rewrittenTargets.contains(ref) else {
                        outcome.problem = "要并进去的那条送去之后被动过"
                        break
                    }
                    let was = MemoryAuditLog.CardState(target)
                    let linked = addSources(of: new, to: target)
                    MemoryAudit.trash([new], now: now)
                    outcome.applied = .merged
                    pending.append((result.outcomes.count, Applied.merged.label, verdict.why, linked ? [(new, before), (target, was)] : [(new, before)]))
                }
            }
            result.outcomes.append(outcome)
        }

        guard !pending.isEmpty else { return result }
        do {
            try context.save()
        } catch {
            // 倒着放回：同一张卡这一趟被并过两次时（第二次只挂出处），最后落在第一次之前的样子
            for item in pending.reversed() { for (memory, was) in item.touched.reversed() { was.apply(to: memory); was.applySources(to: memory) } }
            result.saveError = error.localizedDescription
            for i in result.outcomes.indices where result.outcomes[i].applied != .skipped {
                result.outcomes[i].applied = .unsure
                result.outcomes[i].problem = "没存上：\(error.localizedDescription)"
            }
            return result
        }
        for item in pending {
            let changes: [Change] = item.touched.map { ($0.0.id, $0.1, MemoryAuditLog.CardState($0.0), nil) }
            guard let entry = MemoryAuditLog.entry(changes, actor: actor, label: item.label, note: item.note, dream: recordId, now: now) else { continue }
            // 记不进文件不拦落库，只是这一笔在日志里撤不回（同整理台）
            if (try? MemoryAuditLog.append(entry, memoryRoot: memoryRoot)) != nil { result.outcomes[item.index].entry = entry.id }
        }
        return result
    }

    /// 并之后那张卡的全部出处：两张的出处去重；这一批里的按这一批的先后排，不在这一批里的（更早写的）排在前面、保持原来的先后。
    /// 两张都没有出处 = nil
    static func mergedSources(_ target: [String], _ new: [String], position: [String: Int]) -> [String]? {
        var seen = Set<String>()
        let all = (target + new).filter { seen.insert($0).inserted }
        guard !all.isEmpty else { return nil }
        return all.enumerated().sorted { (position[$0.element] ?? 0, $0.offset) < (position[$1.element] ?? 0, $1.offset) }.map(\.element)
    }

    // MARK: - 跑一次

    /// 这次做梦的结果（日志那条、测试看）
    struct Summary: Equatable {
        var recordId: String
        var counts: [Applied: Int] = [:]
        /// 没跑成的原因；跑成了 = nil
        var failure: String?
        /// 被拦下没做（预算闸 / 模型没回 / 开关关了）
        var skipped = false
        /// 没跑成是因为模型两次都没交出合格的结论（手动整理跳过这一批接着跑；别的失败是停下）
        var malformed = false

        func count(_ kinds: Applied...) -> Int { kinds.reduce(0) { $0 + (counts[$1] ?? 0) } }

        /// 日志那条：「Keep 3 · Drop 2 · Merge 1 · Rewrite 1 · Unsure 1」
        func note(total: Int, needsReview: Bool, label: String?) -> String {
            var parts: [String]
            if let failure {
                parts = ["没跑成：\(failure)", "这批 \(total) 条留在 Draft"]
            } else if skipped {
                parts = ["没做（预算闸拦下、模型没回或开关关了）", "这批 \(total) 条留在 Draft"]
            } else {
                parts = [("Keep", count(.kept, .approved)), ("Drop", count(.dropped)), ("Merge", count(.merged)),
                         ("Rewrite", count(.rewritten, .rewrittenApproved)), ("Unsure", count(.unsure))]
                    .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
                if parts.isEmpty { parts = ["没有要下结论的条目"] }
                if count(.skipped) > 0 { parts.append("\(count(.skipped)) 条你动过没碰") }
                if !needsReview, count(.approved, .rewrittenApproved) > 0 { parts.append("留下的直接算批过") }
            }
            if let label { parts.append(label) }
            return parts.joined(separator: " · ")
        }
    }

    /// 记下每次调用喂了什么、回了什么
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [FragmentDreamRecord.Call] = []

        func add(_ call: FragmentDreamRecord.Call) {
            lock.lock(); list.append(call); lock.unlock()
        }

        var calls: [FragmentDreamRecord.Call] {
            lock.lock(); defer { lock.unlock() }
            return list
        }
    }

    /// 写手写成一批之后调。什么都不抛：没跑成只记一行日志。返回 nil = 没做（开关关着 / 没有要判的卡）。
    /// manual = 她手动点的「重新整理」（`FragmentReorganize`）：不看「写完自动整理一遍」那个开关，别的都一样
    @discardableResult
    static func run(_ input: Input, container: ModelContainer, defaults: UserDefaults = .standard,
                    memoryRoot: URL? = nil, now: @escaping () -> Date = { Date() }, manual: Bool = false) async -> Summary? {
        guard manual || isOn(defaults), MemoryHealthStore.isOn(.extract), !input.cardIds.isEmpty else { return nil }
        // 一次只跑一个：两批同时判，会各自看着对方还没落库的结论去并 / 删同一张卡
        return await FragmentDreamQueue.shared.run {
            await MemoryWriteLog.metered {
                await perform(input, container: container, defaults: defaults,
                              memoryRoot: memoryRoot ?? FileLibraryStore.memoryRoot(profileId: input.profileId), now: now, manual: manual)
            }
        }
    }

    private static func perform(_ input: Input, container: ModelContainer, defaults: UserDefaults,
                                memoryRoot: URL, now: @escaping () -> Date, manual: Bool) async -> Summary? {
        // 她逐条删过的、改过详细度的：都只记在审计日志里。读盘和回放在这里，不占主线程
        let audit = MemoryAuditLog.load(memoryRoot: memoryRoot)
        let handDeleted = MemoryAuditLog.handDeletedStamps(audit)
        let detailed = CardDetailRewrite.protected(audit)
        guard var taken = await MainActor.run(body: {
            Self.snapshot(input, context: container.mainContext, handDeleted: handDeleted, detailed: detailed)
        }) else { return nil }
        // 已经写成 wiki 页的内容：楼层的数据，哪种窗口都带；读盘在这里，不占主线程
        let wikiRoot = memoryRoot.appendingPathComponent("wiki", isDirectory: true)
        let wiki = FragmentVerdict.picked(FragmentVerdict.pages(in: WikiStore(root: wikiRoot), user: input.names.user),
                                          for: taken.material.new, limits: input.limits)
        taken.material.pages = wiki.pages
        let snapshot = taken
        let started = now()
        let recordId = FragmentDreamRecord.newId(started)
        let total = snapshot.material.new.count
        let needsReview = Self.needsReview(defaults)
        let system = FragmentVerdict.system(names: input.names, resident: input.resident, limits: input.limits,
                                            deleted: !snapshot.material.deleted.isEmpty, wiki: wiki)
        let log = CallLog()
        let gated = SessionSegmentWriter.gated({ (manual || isOn(defaults)) && MemoryHealthStore.isOn(.extract) }, input.caller)
        let caller: SessionSegmentWriter.Caller = { system, user in
            do {
                let reply = try await gated(system, user)
                log.add(.init(system: system, user: user, reply: reply, error: nil))
                return reply
            } catch {
                log.add(.init(system: system, user: user, reply: nil, error: error.localizedDescription))
                throw error
            }
        }

        var summary = Summary(recordId: recordId)
        var outcome: FragmentVerdict.Outcome?
        do {
            outcome = try await FragmentVerdict.run(snapshot.material, system: system, caller: caller)
            if outcome == nil { summary.skipped = true }
        } catch {
            summary.failure = SessionCloseout.isTransient(error) ? "断网或被打断" : error.localizedDescription
        }
        if outcome?.failed == true {
            summary.failure = "模型两次都没交出合格的结论"
            summary.malformed = true
        }

        var applied = ApplyResult()
        if let outcome, !outcome.failed {
            let verdicts = outcome.verdicts
            applied = await MainActor.run {
                apply(verdicts, snapshot: snapshot, input: input, recordId: recordId, needsReview: needsReview,
                      context: container.mainContext, memoryRoot: memoryRoot, now: now())
            }
            if let error = applied.saveError {
                summary.failure = "结论没存上：\(error)"
            } else {
                for item in applied.outcomes { summary.counts[item.applied, default: 0] += 1 }
                FragmentDreamNotes.add(applied.outcomes, recordId: recordId, memoryRoot: memoryRoot, now: now())
            }
        }

        let record = FragmentDreamRecord(
            id: recordId, at: started, conversationId: input.conversationId, windowTitle: input.windowTitle, model: input.modelName,
            label: input.label, needsReview: needsReview, calls: log.calls,
            cards: FragmentDreamRecord.cards(snapshot: snapshot, outcome: outcome, applied: applied),
            existing: snapshot.material.existing.count,
            residentCut: FragmentVerdict.residentBlock(input.resident, maxChars: input.limits.maxResidentChars).cut,
            retried: outcome?.retried ?? false, stray: outcome?.stray ?? 0, failure: summary.failure, skipped: summary.skipped,
            costUSD: MemoryWriteLog.meter?.usd,
            existingWhole: snapshot.related.whole, wikiPages: wiki.pages.count, wikiCut: wiki.cut,
            deleted: snapshot.material.deleted.count)
        FragmentDreamRecord.save(record, memoryRoot: memoryRoot, now: now())
        MemoryWriteLog.record(writer: .c2, profileId: input.profileId, ok: summary.failure == nil,
                              note: summary.note(total: total, needsReview: needsReview, label: input.label),
                              model: input.modelName, now: now(), dream: recordId, memoryRoot: memoryRoot)
        // 库没动也发：卡上的理由（Keep / Unsure 那几句）是新写的，整理台要重读
        if !applied.outcomes.isEmpty, applied.saveError == nil {
            await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
        }
        return summary
    }
}

/// 「C2 整理」一次只跑一个（全 app 排队）：每一次都是「看库 → 等模型 → 改库」，并着跑会互相踩
actor FragmentDreamQueue {
    static let shared = FragmentDreamQueue()
    private var last: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let previous = last
        let task = Task { () -> T in
            await previous?.value
            return await body()
        }
        last = Task { _ = await task.value }
        return await task.value
    }
}

// MARK: - 每次做梦喂了什么、回了什么（她要看得见）

/// 一次做梦的完整记录：发给模型的提示词和材料、模型原样的回复、每张新卡的结论和最后怎么落的库。
/// 存楼层 `memory/log/c2-dream/{编号}.json`，一次一个文件；保留天数同记忆日志（`MemoryWriteLog.keepDays`）。
/// 从记忆日志里做梦那一行、或做梦的某一笔点进来看
struct FragmentDreamRecord: Codable, Identifiable, Equatable {
    struct Call: Codable, Equatable {
        var system: String
        var user: String
        /// 模型原样回的；被拦下没回 = nil
        var reply: String?
        var error: String?
    }

    struct Card: Codable, Equatable, Identifiable {
        var id: String
        /// 送去时的正文
        var content: String
        /// 模型交的结论（被代码降成 unsure 的记降之前的）
        var verdict: String?
        var reason: String?
        var why: String?
        /// 并进了哪张已有的卡、或和哪张删过的卡是同一件事（送去时的正文）
        var target: String?
        /// 模型写的全文（merge = 那张已有的卡改成什么；rewrite = 这张改成什么）
        var text: String?
        /// 没照模型说的做的原因（解码时降级 / 落库时对不上）
        var problem: String?
        /// 最后怎么了（`FragmentDream.Applied`）；没跑成 = nil
        var applied: String?
        /// 审计日志里那一笔（没动库 = nil）
        var entry: UUID?
    }

    var id: String
    var at: Date
    var conversationId: String
    var windowTitle: String
    var model: String
    var label: String?
    /// 跑的时候「整理留下的卡要我批」开没开
    var needsReview: Bool
    var calls: [Call]
    var cards: [Card]
    /// 喂进去几张已有的卡
    var existing: Int
    /// 「聊天时本来就带着的内容」太长没放进去的字数
    var residentCut: Int
    var retried: Bool
    var stray: Int
    var failure: String?
    var skipped: Bool
    var costUSD: Double?
    /// 已有的卡是整池都喂了（true），还是放不下、挑的最像的（false）；这一项和下面两项老记录里没有 = nil
    var existingWhole: Bool?
    /// 喂进去几页已经写成 wiki 页的内容
    var wikiPages: Int?
    /// wiki 页太长没放进去的字数
    var wikiCut: Int?
    /// 喂进去几张她逐条删过的卡；老记录里没有 = nil
    var deleted: Int?

    static let folder = "c2-dream"
    static let keepDays = MemoryWriteLog.keepDays

    static func directory(memoryRoot: URL) -> URL {
        memoryRoot.appendingPathComponent(MemoryWriteLog.folder, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
    }

    /// 编号 = 时间 + 四位随机（当文件名，只有数字、字母和横线）
    static func newId(_ at: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: at) + "-" + UUID().uuidString.prefix(4).lowercased()
    }

    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static func cards(snapshot: FragmentDream.Snapshot, outcome: FragmentVerdict.Outcome?, applied: FragmentDream.ApplyResult) -> [Card] {
        let verdicts = Dictionary((outcome?.verdicts ?? []).map { ($0.card, $0) }, uniquingKeysWith: { a, _ in a })
        let results = Dictionary(applied.outcomes.map { ($0.card.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        return snapshot.material.new.map { card in
            let verdict = outcome?.failed == true ? nil : verdicts[card.id]
            let result = results[card.id]
            return Card(id: card.id, content: card.content,
                        verdict: verdict.map { ($0.modelAction ?? $0.action).rawValue },
                        reason: verdict?.reason?.rawValue, why: verdict?.why,
                        target: verdict?.ref.flatMap { snapshot.contents[$0] }, text: verdict?.text,
                        problem: result?.problem ?? verdict?.downgraded,
                        applied: result?.applied.rawValue, entry: result?.entry)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// 存一份，顺手清掉过期的。存不上只记一行调试日志（不影响已经落库的结论）
    static func save(_ record: FragmentDreamRecord, memoryRoot: URL, now: Date = Date()) {
        let dir = directory(memoryRoot: memoryRoot)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: dir.appendingPathComponent(record.id + ".json"), options: .atomic)
        } catch {
            MemoryLogging.shared.log("🧠 C2 整理: ❌ 记录没存上 — \(error.localizedDescription)")
        }
        prune(memoryRoot: memoryRoot, now: now)
    }

    static func load(id: String, memoryRoot: URL) -> FragmentDreamRecord? {
        guard isValidId(id), let data = try? Data(contentsOf: directory(memoryRoot: memoryRoot).appendingPathComponent(id + ".json")) else { return nil }
        return try? decoder.decode(FragmentDreamRecord.self, from: data)
    }

    /// 超过保留天数的记录文件删掉（按文件改动时间）
    static func prune(memoryRoot: URL, now: Date = Date()) {
        let dir = directory(memoryRoot: memoryRoot)
        let since = now.addingTimeInterval(-TimeInterval(keepDays) * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != FragmentDreamNotes.fileName {
            guard let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, changed < since else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - 留在 Draft 的卡上那句理由（整理台排序和显示用）

/// 做梦给每张还留着的新卡的一句话：Unsure 的排在 Draft 最前，卡上能看到理由。
/// 不进库（不加字段）：存楼层 `memory/log/c2-dream/notes.json`，卡 id → 一条；保留天数同记录
enum FragmentDreamNotes {
    struct Note: Codable, Equatable {
        /// Keep / Rewrite / Unsure
        var label: String
        var why: String?
        /// 没照模型说的做的原因（它本来想并 / 改，被降成了 Unsure）
        var problem: String?
        /// 被降成 Unsure 之前模型想写的全文
        var text: String?
        var at: Date
        var record: String

        var isUnsure: Bool { label == FragmentDream.Applied.unsure.label }

        /// 卡上那一行：「C2 整理 · Unsure：……」
        var line: String {
            let said = [problem, why].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")
            return "\(FragmentDream.actor) · \(label)" + (said.isEmpty ? "" : "：\(said)")
        }
    }

    static let fileName = "notes.json"

    static func url(memoryRoot: URL) -> URL {
        FragmentDreamRecord.directory(memoryRoot: memoryRoot).appendingPathComponent(fileName)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func load(memoryRoot: URL) -> [UUID: Note] {
        guard let data = try? Data(contentsOf: url(memoryRoot: memoryRoot)),
              let raw = try? decoder.decode([String: Note].self, from: data) else { return [:] }
        var out: [UUID: Note] = [:]
        for (key, note) in raw { if let id = UUID(uuidString: key) { out[id] = note } }
        return out
    }

    /// 这次做梦里还留着的新卡各记一条（删掉的、并掉的、她动过的不记）；过期的顺手清
    static func add(_ outcomes: [FragmentDream.CardOutcome], recordId: String, memoryRoot: URL, now: Date = Date()) {
        let kept = outcomes.filter { [.kept, .approved, .rewritten, .rewrittenApproved, .unsure].contains($0.applied) }
        guard !kept.isEmpty else { return }
        let since = now.addingTimeInterval(-TimeInterval(FragmentDreamRecord.keepDays) * 86400)
        var all = load(memoryRoot: memoryRoot).filter { $0.value.at >= since }
        for item in kept {
            let downgraded = item.applied == .unsure && item.verdict.action != .unsure || item.verdict.downgraded != nil
            all[item.card] = Note(label: item.applied.label, why: item.verdict.why,
                                  problem: item.problem ?? item.verdict.downgraded,
                                  text: downgraded ? item.verdict.text : nil, at: now, record: recordId)
        }
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString, $0.value) })
        do {
            try FileManager.default.createDirectory(at: FragmentDreamRecord.directory(memoryRoot: memoryRoot), withIntermediateDirectories: true)
            try encoder.encode(raw).write(to: url(memoryRoot: memoryRoot), options: .atomic)
        } catch {
            MemoryLogging.shared.log("🧠 C2 整理: ❌ 条目上的理由没存上 — \(error.localizedDescription)")
        }
    }
}
