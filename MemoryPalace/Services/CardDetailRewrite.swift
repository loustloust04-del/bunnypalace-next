import MemoryCore
import Foundation
import SwiftData

/// 条目的「详细度」（plan-card-detail-slider）app 这一半：取当时附近的原文 → 调一次模型（不查写入预算，查全局预算，记在写入用量名下）
/// → 存这次喂了什么、回了什么 → 结果交给详情页放进编辑框草稿；她点 Save 才落库、记一笔。
/// 提示词和解码在包里 `CardDetail`。这一条现在是哪一档不进库：从审计日志推（`states`）
enum CardDetailRewrite {
    /// 界面上和审计日志 label 的名字（卡底那排 chip 都是英文；发给模型的提示词里还是「简略 / 适中 / 详细」）
    static let name = "Detail"

    /// 界面上那一格的词
    static func word(_ level: CardDetail.Level) -> String {
        switch level {
        case .brief: return "Brief"
        case .medium: return "Normal"
        case .detailed: return "Detailed"
        }
    }

    /// 审计日志那一笔的 label：「Detail · Brief」
    static func label(_ level: CardDetail.Level) -> String { "\(name) · \(word(level))" }

    static func level(ofLabel label: String?) -> CardDetail.Level? {
        CardDetail.Level.allCases.first { self.label($0) == label }
    }

    // MARK: - 取材料

    /// 「当时附近」是哪一截
    enum Source: String, Codable, Equatable, Sendable {
        /// 锚点所在的那一段 A2 上下文摘要盖的那几条
        case segment
        /// 写手写这一批时看到的那一截（照写手的切法重切）+ 前文
        case span
    }

    struct Picked: Equatable {
        let range: Range<Int>
        let before: Range<Int>
        let source: Source
    }

    /// 纯函数（可测）：锚点在主线第几条 → 落在哪一段 A2（按 `SummaryRewrite.range` 认，取盖得最小的那段）；
    /// 没有段盖到它 → 照写手的切法（`FragmentReorganize.spans`）找它那一截，前文照写手的取法（`FragmentPool.wholeBefore`）。
    /// 锚点不在主线上 = nil
    static func pick(anchor: String?, segments: [SessionSegment], pathIds: [String], dates: [Date?], sizes: [Int], every: Int) -> Picked? {
        guard let anchor, let at = pathIds.firstIndex(of: anchor) else { return nil }
        let covering = segments.compactMap { SummaryRewrite.range(of: $0, pathIds: pathIds, dates: dates) }.filter { $0.contains(at) }
        if let range = covering.min(by: { $0.count < $1.count }) {
            return Picked(range: range, before: range.lowerBound..<range.lowerBound, source: .segment)
        }
        guard let span = FragmentReorganize.spans(sizes: sizes, every: every).first(where: { $0.contains(at) }) else { return nil }
        let before = FragmentPool.wholeBefore(sizes, upTo: span.lowerBound, size: { $0 })
        return Picked(range: span, before: before.startIndex..<before.endIndex, source: .span)
    }

    /// 送去重写时这张卡的样子（主线程取好，后台用）
    struct Card: Equatable, Sendable {
        let id: UUID
        let content: String
        let subject: String?
        let conversationId: String?
        let anchor: String?

        init(_ m: Memory) {
            id = m.id
            content = m.content
            subject = m.subject
            conversationId = m.sourceConversationId
            anchor = m.sourceNodeId ?? m.sourceNodeIds?.first
        }
    }

    /// 取好的材料
    struct Prepared: Equatable, Sendable {
        let card: UUID
        let conversationId: String
        let material: CardDetail.Material
        let source: Source

        /// 原文一共多少字（估价用）
        var chars: Int { (material.lines + material.before).reduce(0) { $0 + $1.text.count } }
    }

    enum Gathered: Equatable, Sendable {
        case ready(Prepared)
        /// 点不了，写给她看的原因
        case unavailable(String)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 找这条当时附近的原文（读库读盘，后台调）
    static func gather(_ card: Card, profileId: String, names: MemoryExtractor.Names, container: ModelContainer,
                       every: Int, memoryRoot: URL? = nil) -> Gathered {
        guard let cid = card.conversationId, card.anchor != nil else { return .unavailable("这条没记出处，找不到当时的原文") }
        guard let path = FragmentBatch.path(container: container, profileId: profileId, conversationId: cid) else {
            return .unavailable("出处窗口删了或不参与记忆，找不到当时的原文")
        }
        let nodes = path.nodes
        let segments = SessionSummaryStore.load(conversationId: cid, memoryRoot: memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId))?.segments ?? []
        guard let picked = pick(anchor: card.anchor, segments: segments, pathIds: nodes.map(\.id), dates: nodes.map(\.createTime),
                                sizes: nodes.map(FragmentBatch.size), every: every) else {
            return .unavailable("出处那条消息不在这个窗口现在的主线上（切过分支或删了），找不到当时的原文")
        }
        func line(_ node: ConversationMessage) -> FragmentVerdict.Line {
            FragmentVerdict.Line(role: node.role, text: CatalogOriginalText.body(of: node, cacheKey: node.id),
                                 at: node.createTime.map { stamp.string(from: $0) })
        }
        let anchor = card.anchor.flatMap { id in nodes[picked.range].firstIndex { $0.id == id } }.map { $0 - picked.range.lowerBound + 1 }
        let material = CardDetail.Material(windowTitle: path.title, names: names, subject: card.subject, content: card.content,
                                           lines: nodes[picked.range].map(line), before: nodes[picked.before].map(line), anchor: anchor)
        return .ready(Prepared(card: card.id, conversationId: cid, material: material, source: picked.source))
    }

    // MARK: - 用哪个模型

    enum Route {
        /// 跟 C2 写手同一个模型（`FragmentModelRoute`）；name = 实际跑的模型名
        case remote(ProviderModel, name: String)
        case unavailable(String)
    }

    /// 只能用云上的模型：本机模型装不下原文（同手动「重新整理」）
    @MainActor
    static func route(providers: ProviderManager?, defaults: UserDefaults = .standard) -> Route {
        guard let providers else { return .unavailable("这里拿不到模型设置，到记忆页打开这条再点") }
        let chat = providers.resolveModel(conversationModelId: nil, profileModelId: nil, globalFallbackId: defaults.string(forKey: "selectedChatModel"))
        let resolved = FragmentModelRoute.resolve(providerManager: providers, chatFallback: chat, defaults: defaults)
        guard case .remote(let model) = resolved.route else { return .unavailable("C2 选的是本机模型，装不下当时的原文；换成云上模型才能用") }
        return .remote(model, name: resolved.displayName)
    }

    /// 估计花多少；模型没标价 = nil
    @MainActor
    static func cost(_ prepared: Prepared, level: CardDetail.Level, model: ProviderModel, providers: ProviderManager?) -> Double? {
        guard let provider = providers?.provider(for: model) else { return nil }
        let u = usage(prepared, level: level)
        let usd = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: TokenUsage(inputTokens: u.input, outputTokens: u.output))
        return usd > 0 ? usd : nil
    }

    // MARK: - 确认框

    /// 确认框的字（纯函数，可测）。cost = 估计花多少（模型没标价 = nil）
    static func askText(_ level: CardDetail.Level, prepared: Prepared, model: String, cost: Double?) -> String {
        let n = prepared.material.lines.count
        let from: String
        switch prepared.source {
        case .segment: from = "这条出处所在的那一段上下文摘要盖的 \(n) 条"
        case .span:
            let before = prepared.material.before.count
            from = "写手写这一批时看到的 \(n) 条" + (before > 0 ? "，外加前面 \(before) 条前文" : "")
        }
        let spend = cost.map(FragmentRerecord.spend) ?? "这个模型没标价，估不出花多少"
        let what = level == .medium ? "按写手平时的写法重写一句（写手原来那句在记忆日志里已经找不到了）" : "重写成「\(word(level))」"
        return "用 \(model) 照这条当时附近的原文（\(from)）\(what)。\(spend)，不看写入预算。"
            + "重写好的先放进正文，你看了点 Save 才存；Cancel 就当没发生。"
    }

    /// 往高里估的 token：原文一个字算一个，加提示词；详细的回得长些
    static func usage(_ prepared: Prepared, level: CardDetail.Level) -> (input: Int, output: Int) {
        (prepared.chars + 3_000, level == .detailed ? 1_500 : 500)
    }

    // MARK: - 跑一次

    struct Outcome: Equatable, Sendable {
        let recordId: String
        /// 重写好的正文；没成 = nil
        let text: String?
        let failure: String?
    }

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

    /// 调一次模型重写。什么都不抛：没成写进 failure；不碰库。每次都存一份记录、记一行记忆日志（花费记在 C2 名下）
    static func run(_ level: CardDetail.Level, prepared: Prepared, model: String, caller: @escaping SessionSegmentWriter.Caller,
                    profileId: String, memoryRoot: URL? = nil, now: @escaping () -> Date = { Date() }) async -> Outcome {
        let root = memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId)
        return await MemoryWriteLog.metered {
            let started = now()
            let id = CardDetailRecord.newId(started)
            let log = CallLog()
            let logged: SessionSegmentWriter.Caller = { system, user in
                do {
                    let reply = try await caller(system, user)
                    log.add(.init(system: system, user: user, reply: reply, error: nil))
                    return reply
                } catch {
                    log.add(.init(system: system, user: user, reply: nil, error: error.localizedDescription))
                    throw error
                }
            }
            var text: String?
            var failure: String?
            var retried = false
            do {
                if let out = try await CardDetail.run(prepared.material, level: level, caller: logged) {
                    text = out.text
                    retried = out.retried
                } else {
                    failure = MemoryWriteLog.meter?.skip ?? "模型没回内容"
                }
            } catch {
                failure = SessionCloseout.isTransient(error) ? "断网或被打断" : error.localizedDescription
            }
            let record = CardDetailRecord(id: id, at: started, card: prepared.card, conversationId: prepared.conversationId,
                                          windowTitle: prepared.material.windowTitle, model: model, level: level, source: prepared.source,
                                          lines: prepared.material.lines.count, before: prepared.material.before.count,
                                          content: prepared.material.content, text: text, failure: failure, retried: retried,
                                          calls: log.calls, costUSD: MemoryWriteLog.meter?.usd)
            CardDetailRecord.save(record, memoryRoot: root, now: now())
            MemoryWriteLog.record(writer: .c2, profileId: profileId, ok: text != nil,
                                  note: "\(label(level)) · 窗口「\(SessionSummaryStore.oneLine(prepared.material.windowTitle))」"
                                    + (failure.map { " · 没重写成：\($0)" } ?? ""),
                                  model: model, now: now(), dream: id, memoryRoot: root)
            return Outcome(recordId: id, text: text, failure: failure)
        }
    }

    // MARK: - Save

    /// 编辑框里等她 Save 的那一份
    struct Draft: Equatable {
        let level: CardDetail.Level
        let text: String
        /// 送去时 / 找回原句时卡上的正文：Save 时对不上 = 这期间别处改过它，不存
        let sent: String
        /// 这次重写的记录；点回适中、从日志找回原句的 = nil
        let recordId: String?
        /// 记一笔时的 actor：重写它的模型；找回原句的 = You
        let actor: String
    }

    static let changedText = "重写之后这条被别处改过，没存；再点一次 \(name)"

    /// 她点了 Save：只换正文，算批过（写 `reviewedAt`）；不记「她亲手改过」、置信度不动。记一笔：label 写档位、带记录编号
    @MainActor
    static func save(_ draft: Draft, to m: Memory, context: ModelContext, now: Date = Date()) -> MemoryEntryActions.Outcome {
        guard m.supersededAt == nil, m.content == draft.sent else { return MemoryEntryActions.Outcome(error: changedText) }
        let note = draft.recordId == nil ? "找回写手原来那句" : "照当时附近的原文重写成「\(word(draft.level))」"
        return MemoryEntryActions.commit([m], profileId: m.profileId, context: context, now: now, actor: draft.actor,
                                         label: label(draft.level), note: note, dream: draft.recordId) {
            if m.content != draft.text {
                m.content = draft.text
                m.tokenCount = Memory.estimateTokens(draft.text)
                m.embeddingData = nil
            }
            m.updatedAt = now
            m.reviewedAt = now
        }
    }

    // MARK: - 从审计日志推：现在是哪一档、写手原来那句

    struct State: Equatable {
        /// 现在的正文是哪一档写的；nil = 之后又被改过正文，不再算哪一档
        var level: CardDetail.Level?
        /// 第一次改详细度之前那句（点回适中时放回去）；找不回 = nil
        var original: String?
    }

    /// 按日志从旧到新走一遍（同 `MemoryAuditLog.handDeletedStamps` 的回放）：带「详细度」label 的一笔 = 那一档；
    /// 之后正文被别的一笔改了 = 不再算；Undo = 回到被撤那一笔之前。只返回现在还算某一档的卡。`entries` 照 `load` 的顺序（新的在前）
    static func states(_ entries: [MemoryAuditLog.Entry]) -> [UUID: State] {
        var now: [UUID: State] = [:]
        var before: [UUID: [UUID: State]] = [:]
        for entry in entries.reversed() {
            let tier = level(ofLabel: entry.label)
            for item in entry.items {
                let was = now[item.card]
                before[entry.id, default: [:]][item.card] = was
                if let undone = entry.undoOf {
                    now[item.card] = before[undone]?[item.card]
                } else if let after = item.after {
                    if let tier {
                        // 适中那一笔写下的就是适中那句；别的档：接着上一档的原句，第一次改的拿改之前那句
                        let original = tier == .medium ? after.content : (was?.level != nil ? was?.original : item.before.content)
                        now[item.card] = State(level: tier, original: original)
                    } else if after.content != item.before.content {
                        now[item.card] = nil
                    }
                } else {
                    now[item.card] = nil
                }
            }
        }
        return now.compactMapValues { $0.level == nil ? nil : $0 }
    }

    /// 「C2 整理」不许改正文的那些（最后一次正文变动是详细度那一笔）
    static func protected(_ entries: [MemoryAuditLog.Entry]) -> Set<UUID> {
        Set(states(entries).keys)
    }
}

// MARK: - 每次重写喂了什么、回了什么

/// 一次重写的完整记录。存楼层 `memory/log/card-detail/{编号}.json`，保留天数同记忆日志；编号带 `prefix`，记忆日志按它认出该开哪种记录
struct CardDetailRecord: Codable, Identifiable, Equatable {
    var id: String
    var at: Date
    var card: UUID
    var conversationId: String
    var windowTitle: String
    var model: String
    var level: CardDetail.Level
    var source: CardDetailRewrite.Source
    /// 原文几条、前文几条
    var lines: Int
    var before: Int
    /// 送去时的正文
    var content: String
    /// 模型重写成的；没成 = nil
    var text: String?
    var failure: String?
    var retried: Bool
    var calls: [FragmentDreamRecord.Call]
    var costUSD: Double?

    static let folder = "card-detail"
    static let prefix = "detail-"
    static let keepDays = MemoryWriteLog.keepDays
    static let expiredMessage = "这次重写的记录已经清掉了（只留 \(keepDays) 天）"

    static func newId(_ at: Date) -> String { prefix + FragmentDreamRecord.newId(at) }

    static func isId(_ id: String) -> Bool { id.hasPrefix(prefix) && FragmentDreamRecord.isValidId(id) }

    static func directory(memoryRoot: URL) -> URL {
        memoryRoot.appendingPathComponent(MemoryWriteLog.folder, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
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

    /// 存一份，顺手清掉过期的。存不上只记一行调试日志
    static func save(_ record: CardDetailRecord, memoryRoot: URL, now: Date = Date()) {
        let dir = directory(memoryRoot: memoryRoot)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: dir.appendingPathComponent(record.id + ".json"), options: .atomic)
        } catch {
            MemoryLogging.shared.log("🧠 详细度: ❌ 记录没存上 — \(error.localizedDescription)")
        }
        let since = now.addingTimeInterval(-TimeInterval(keepDays) * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "json" {
            guard let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, changed < since else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func load(id: String, memoryRoot: URL) -> CardDetailRecord? {
        guard isId(id), let data = try? Data(contentsOf: directory(memoryRoot: memoryRoot).appendingPathComponent(id + ".json")) else { return nil }
        return try? decoder.decode(CardDetailRecord.self, from: data)
    }
}
