import Foundation
import Observation
import SwiftData

/// 记忆写手的总调度（plan-memory-v4-1 §四 §五）：W2 上下文摘要（API 超窗压缩 / CC 满 60 条或跨过 05:00）、
/// W3 收尾（窗口总结）都从这里进，同一个窗口同一时刻只有一个写手在写。A4 时间轴一天一条另走 `TimelineDaily`（巡检后面接着拼）
actor SessionCloseout {
    static let shared = SessionCloseout()

    /// 静默多久算这个窗口聊完（v5 粟粟 10-15：30 分钟太短 → 12 小时）；A3 / A4 各自「停 N 分钟」的默认值
    static let idleInterval: TimeInterval = 12 * 3600
    /// 新建对话时：最近多久聊过的对话立刻收尾（不等静默；跟着改 12 小时，Q-b）
    static let recentInterval: TimeInterval = 12 * 3600
    /// 巡检只看最近几天动过的对话（上线第一天不把几百个老对话从头补一遍）
    static let lookbackDays = 7
    /// 一份最多多少条消息（超长尾巴切份）
    static let chunkSize = 60
    /// 一个对话第一次写、前面什么都没有时，最多从倒数第几条开始；窗口总结最后那段也最多这么多条
    static let firstCloseoutCap = 150
    /// 格式两次都不合格后，同一个窗口同一个写手多久不再试（Q7）
    static let formatCooldown: TimeInterval = 30 * 60

    struct Context {
        let profileId: String
        let persona: String
        let userName: String
        let assistantName: String
        let model: ProviderModel
        /// v5 A7：各写手单选的模型（没选 = model，即提取模型）
        var writerModels: [Writer: ProviderModel] = [:]
        /// 手动「现在写」：不等静默、不看冷却、不看写入预算（Q10）
        var manual = false

        /// 人设 = 系统提示 + 角色描述（和第二刀提取同一个口径）
        init(profile: Profile, model: ProviderModel, writerModels: [Writer: ProviderModel] = [:]) {
            profileId = profile.id
            persona = [profile.systemPrompt, profile.characterDescription]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            userName = profile.userName
            assistantName = profile.assistantName
            self.model = model
            self.writerModels = writerModels
        }

        var speakers: SessionSegmentWriter.Speakers { .init(userName: userName, assistantName: assistantName) }

        func model(_ writer: Writer) -> ProviderModel { writerModels[writer] ?? model }
    }

    /// 三个写手（健康状态三行、冷却各算各的）
    enum Writer: String, CaseIterable {
        case context, window, timeline

        var health: MemoryHealthStore.Kind {
            switch self {
            case .context: return .context
            case .window: return .summary
            case .timeline: return .timeline
            }
        }

        var id: MemoryWriterID {
            switch self {
            case .context: return .a2
            case .window: return .a3
            case .timeline: return .a4
            }
        }

        /// 账本里算谁的（v5 · A11）
        var usage: UsageKind {
            switch self {
            case .context: return .summary
            case .window: return .windowSummary
            case .timeline: return .timeline
            }
        }
    }

    /// 真调模型的 caller：各写手用自己的模型、记自己的用途；手动「现在写」不看写入预算
    static func modelCaller(_ writer: Writer, ctx: Context, providerManager: ProviderManager, conversationId: String) -> SessionSegmentWriter.Caller {
        SessionSegmentWriter.modelCaller(model: ctx.model(writer), providerManager: providerManager, conversationId: conversationId,
                                         profileId: ctx.profileId, kind: writer.usage, checkWriteBudget: !ctx.manual)
    }

    /// 这个写手现在还开着吗（总开关 && 这一项）
    static func isOn(_ writer: Writer) -> Bool { MemoryHealthStore.isOn(writer.health) }

    /// astra #1：每次调模型前、落盘前复查总开关 + 这一项的开关
    /// A2 落盘（存段 / 换尾段）唯一出口：先保全、后覆盖（c2c3-v2 第 7 段，车头 10-22）——旧摘要和新摘要里的待续先进本子或待补，
    /// 确认落盘了才覆盖文件；保不住就抛、这次不存（不调模型、不看 A4 开关）
    static func saveA2(_ s: SessionSummary, profileId: String) throws {
        try TimelineDaily.preserveBeforeSave(s, profileId: profileId)
        try SessionSummaryStore.save(s, profileId: profileId)
    }

    static func gated(_ writer: Writer, _ caller: @escaping SessionSegmentWriter.Caller) -> SessionSegmentWriter.Caller {
        SessionSegmentWriter.gated({ isOn(writer) }, caller)
    }

    private var sweeping = false
    private var sweepAgain = false
    /// 正在写的窗口 → 在写什么（「收尾」「上下文摘要」…，10-16 搬迁等不到时说得出是谁）：W2、W3 动笔前先占住，占不到记一笔，前一个跑完再补跑一次
    private var busy: [String: String] = [:]
    private var retryAfter: [String: [String: () async -> Void]] = [:]
    /// 「写手|窗口」→ 冷却到什么时候（格式两次不合格）
    private var cooldown: [String: Date] = [:]
    /// CC 巡检记过的（窗口 → 当时的更新时间 + 那天）：没新消息、没跨过 05:00 就不再读节点
    private var ccChecked: [String: (updated: Date, day: String)] = [:]
    /// CC 窗口上次没写成：到这个时间以后再查
    private var ccRetryAt: [String: Date] = [:]
    /// 重新生成（DEBUG）进行中：日常写手都先停
    private(set) var regenerating = false
    /// A2「停 N 分钟」：这个窗口最近一轮的快照（每轮回复后换新），静默够了巡检时压
    private var idleCompress: [String: IdleCompress] = [:]

    struct IdleCompress {
        let messages: [SessionSegmentWriter.Message]
        let oldCount: Int
        let title: String
        let ctx: Context
        let at: Date
        /// 上次出错（非断网）后到这个时间再试
        var retryAt: Date? = nil
    }

    /// 写入 A2 上下文摘要开关：管 W2（v5 起只管写）
    static var enabled: Bool { MemoryFlags.contextSummaryEnabled }
    /// 写入 A3 窗口总结开关（v5 拆开）
    static var windowEnabled: Bool { MemoryFlags.windowSummaryEnabled }
    /// 写入 A4 时间轴开关（A4 一天一条另走 `TimelineDaily`，不在收尾里）
    static var timelineEnabled: Bool { TimelineConsolidator.enabled }
    /// 收尾跑不跑：A3 开着才跑
    static var closeoutEnabled: Bool { windowEnabled }

    static var fullSegmentCount: Int {
        let v = UserDefaults.standard.integer(forKey: "mem_session_full_segments")
        return v > 0 ? min(v, 4) : 2
    }

    // MARK: - 占位 / 冷却 / 健康

    private func claim(_ conversationId: String, job: String, retry: @escaping () async -> Void) -> Bool {
        guard busy[conversationId] != nil else {
            busy[conversationId] = job
            return true
        }
        retryAfter[conversationId, default: [:]][job] = retry
        CacheDiagLog.shared.log("📝 记忆写手: 这个窗口正在写，\(job) 等它写完再补一次")
        return false
    }

    private func release(_ conversationId: String) {
        busy[conversationId] = nil
        guard let jobs = retryAfter.removeValue(forKey: conversationId) else { return }
        for job in jobs.values { Task.detached(priority: .utility) { await job() } }
    }

    private func cooling(_ writer: Writer, _ conversationId: String, now: Date = Date()) -> Bool {
        (cooldown["\(writer.rawValue)|\(conversationId)"] ?? .distantPast) > now
    }

    /// 写手出错：断网 / 被掐断不算（返回 true = 整个停下，下次巡检自动补）；格式错进冷却；都记健康状态（顺手记日志）。
    /// 开关已经关了：这次是被关掉放弃的，不记失败、整个停下（astra #1）
    private func noteFailure(_ error: Error, writer: Writer, conversationId: String, ctx: Context) -> Bool {
        if Self.isTransient(error) || !Self.isOn(writer) { return true }
        if case MemoryWriterError.format = error {
            cooldown["\(writer.rawValue)|\(conversationId)"] = Date().addingTimeInterval(Self.formatCooldown)
        }
        MemoryHealthStore.recordError(writer.health, profileId: ctx.profileId, message: error.localizedDescription, modelName: ctx.model(writer).name)
        return false
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let code = (error as? URLError)?.code, [.cancelled, .networkConnectionLost, .notConnectedToInternet].contains(code) { return true }
        return false
    }

    func setRegenerating(_ on: Bool) { regenerating = on }

    /// 等日常写手停手的结果（10-16）
    enum IdleWait: Equatable {
        case idle
        /// 等够了还有人在写：在写的那几个（「收尾 · 1a2b3c4d」）
        case timedOut([String])
        case cancelled
    }

    /// 搬迁 / 恢复最多等日常写手多久（10-16：以前没上限，一个写手挂住，搬迁就跟着干等、界面一个字没有）
    static let idleWaitTimeout: TimeInterval = 60

    /// 重新生成要等日常写手都停手：有人在写就等一会儿，最多等 timeout 秒；被取消立刻返回
    /// （10-16：以前 `try?` 吞了取消，Task.sleep 一取消就立刻抛 → 空转死循环）
    func waitUntilIdle(timeout: TimeInterval = idleWaitTimeout) async -> IdleWait {
        // 10-16 astra #1：没人在写时也要认取消（进门、出门各看一次）
        if Task.isCancelled { return .cancelled }
        let deadline = Date().addingTimeInterval(timeout)
        while !busy.isEmpty {
            guard Date() < deadline else { return .timedOut(busy.map { "\($0.value) · \($0.key.prefix(8))" }.sorted()) }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return .cancelled }
        }
        return Task.isCancelled ? .cancelled : .idle
    }

    // MARK: - W2 上下文摘要 · API（超窗时，由发消息那条路触发）

    /// messages = 当前路径全部 user / assistant（和历史窗口同一个口径）；oldCount = 窗外条数。
    /// 已被老收尾段总结过的部分不重写，只推锚点；没总结过的那截写成上下文摘要段。返回新的锚点（nil = 没动）
    func compress(messages: [SessionSegmentWriter.Message], oldCount: Int, conversationId: String, title: String,
                  ctx: Context, caller: @escaping SessionSegmentWriter.Caller) async throws -> Int? {
        // v5 · 0.1：关着不跑（补跑闭包也走这里，关了以后不会再跑、再记失败）
        guard Self.enabled, !regenerating, ctx.manual || !cooling(.context, conversationId) else { return nil }
        guard claim(conversationId, job: "上下文摘要", retry: { [self] in
            _ = try? await self.compress(messages: messages, oldCount: oldCount, conversationId: conversationId, title: title,
                                         ctx: ctx, caller: caller)
        }) else { return nil }
        defer { release(conversationId) }

        return try await MemoryWriteLog.metered {
            var s = SessionSummaryStore.loadOrSeed(conversationId: conversationId, profileId: ctx.profileId, title: title)
            let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: MemoryStartDay.current)
            guard let plan = Self.compressPlan(s, pathIds: messages.map(\.id), dates: messages.map(\.date), oldCount: oldCount, notBefore: notBefore) else { return nil }
            let parts = plan.ranges.flatMap { Self.chunks($0) }
            let before = s.segments.filter { !$0.isTail }.count
            let finished: Bool
            do {
                finished = try await Self.writeContextParts(parts, messages: messages, into: &s, title: title,
                                                            persona: ctx.persona, speakers: ctx.speakers, caller: Self.gated(.context, caller)) {
                    try Self.saveA2($0, profileId: ctx.profileId)
                }
            } catch {
                _ = noteFailure(error, writer: .context, conversationId: conversationId, ctx: ctx)
                throw error
            }
            guard finished else { return nil }
            s.compressedCount = plan.anchor
            s.title = title
            s.updatedAt = Date()
            try Self.saveA2(s, profileId: ctx.profileId)
            if !parts.isEmpty {
                MemoryHealthStore.recordOK(.context, profileId: ctx.profileId, modelName: ctx.model(.context).name,
                                           note: Self.contextNote(added: s.segments.filter { !$0.isTail }.count - before, title: title))
            }
            return plan.anchor
        }
    }

    /// 日志那条：「写了 1 段 · 《看病》」
    static func contextNote(added: Int, title: String) -> String {
        "写了 \(max(added, 0)) 段 · 《\(title.isEmpty ? "没有标题" : title)》"
    }

    struct CompressPlan: Equatable {
        /// 这次要写成压缩段的那几截（按先后）；空 = 压缩段已经盖到窗外了（切过分支锚点落后时），只推锚点
        let ranges: [Range<Int>]
        /// 写完锚点推到哪（= 窗外条数）
        let anchor: Int
    }

    /// 纯函数（可测）：窗外 oldCount 条里哪几截要写成压缩段（同 `pendingRanges`：已有段盖住的不重写、首次补写的上限、
    /// 不早于 notBefore）。锚点只算真写进段的：窗外没盖住的全在「记忆从哪天开始」以前时返回 nil，锚点不动——
    /// 以后起点往前挪，这截还能补；不动锚点也不会每轮白跑，每轮只多算一次 notBefore（纯函数，不读盘不调模型）。
    /// nil = 不用压
    static func compressPlan(_ s: SessionSummary, pathIds: [String], dates: [Date?], oldCount: Int, notBefore: Int = 0) -> CompressPlan? {
        guard oldCount > s.compressedCount else { return nil }
        let ranges = pendingRanges(s, pathIds: pathIds, dates: dates, end: oldCount, notBefore: notBefore)
        guard !ranges.isEmpty || SessionSummaryStore.resumeIndex(coverage(s), pathIds: pathIds) >= oldCount else { return nil }
        return CompressPlan(ranges: ranges, anchor: oldCount)
    }

    /// 一截截写成上下文摘要段插进 s（插回时间顺序；每截写完就 save，中途断了下次从水位线接着）。
    /// 返回 false = 写手跳过（预算闸 / 空输出），后面的不写。onPart(第几截, 一共几截) 在每截动笔前喊一声（10-16 搬迁进度用）
    static func writeContextParts(_ parts: [Range<Int>], messages: [SessionSegmentWriter.Message], into s: inout SessionSummary,
                                  title: String, persona: String, speakers: SessionSegmentWriter.Speakers,
                                  caller: SessionSegmentWriter.Caller, save: (SessionSummary) throws -> Void,
                                  onPart: (Int, Int) -> Void = { _, _ in }) async throws -> Bool {
        // v5 D1：尾段被正式压缩后换成正式段——要写正式段了就先拿掉尾段（下次收尾整段重写）
        if !parts.isEmpty { s.segments.removeAll { $0.isTail } }
        for (k, part) in parts.enumerated() {
            onPart(k + 1, parts.count)
            let at = insertionIndex(s, chunkStart: messages[part.lowerBound].date)
            guard let segment = try await SessionSegmentWriter.write(
                .init(messages: Array(messages[part]), kind: .rolling, from: part.lowerBound, persona: persona,
                      speakers: speakers, previous: s.segments[..<at].last(where: { $0.kind != .closeout })),
                caller: caller) else { return false }
            s.segments.insert(segment, at: at)
            s.title = title
            s.updatedAt = Date()
            try save(s)
        }
        return true
    }

    // MARK: - W2 上下文摘要 · CC（回复落地 + 巡检）

    /// 纯函数（可测）：CC 窗口这次要写成上下文摘要的那几截——上下文摘要水位线之后（同 `pendingRanges`），先按天切再按 60 条切；
    /// 一份满 60 条，或者它那天已经过去（跨过 05:00），就写；今天没满 60 条的尾巴留着（后面的只会更晚，遇到就停）
    static func ccCompressRanges(_ s: SessionSummary, pathIds: [String], dates: [Date?], notBefore: Int, now: Date,
                                 calendar: Calendar = .current, capFirst: Bool = true) -> [Range<Int>] {
        let today = MemoryDay.key(now, calendar: calendar)
        var out: [Range<Int>] = []
        for r in pendingRanges(s, pathIds: pathIds, dates: dates, notBefore: notBefore, capFirst: capFirst) {
            for day in MemoryDay.split(Array(dates[r]), calendar: calendar) {
                let abs = (r.lowerBound + day.lowerBound)..<(r.lowerBound + day.upperBound)
                let past = dates[abs].lazy.compactMap { $0 }.first.map { MemoryDay.key($0, calendar: calendar) < today } ?? false
                for part in chunks(abs) {
                    guard part.count == chunkSize || past else { return out }
                    out.append(part)
                }
            }
        }
        return out
    }

    /// CC 窗口这一趟的结果（astra #9）：只有写成了 / 确认不用写，巡检才记「今天查过了」；失败、冷却、被占、写手跳过都要再查
    enum CCResult: Equatable {
        /// 写成了
        case wrote
        /// 确认不用写（不是 CC 窗口 / 记忆关着 / 没有满 60 条或跨过 05:00 的）
        case nothingToWrite
        /// 这次没写成，到 `retryAt` 以后再查（nil = 下次巡检就查）
        case retry(at: Date?)

        var settled: Bool { self == .wrote || self == .nothingToWrite }
    }

    /// 一个 CC 窗口：水位线之后满 60 条 / 跨过 05:00 的写成上下文摘要。不动 compressedCount（CC 不用花园的历史窗口；
    /// 以后换 API，锚点从 0 退回滑动窗，和窗口原文重叠的段注入时会挡掉）。caller 只给测试换假写手
    @discardableResult
    func compressCC(conversationId: String, ctx: Context, container: ModelContainer, providerManager: ProviderManager,
                    now: Date = Date(), caller testCaller: SessionSegmentWriter.Caller? = nil) async -> CCResult {
        guard !regenerating else { return .retry(at: nil) }
        // v5 A8：A2 选了「只手动」就不自动写（CC 楼层也一样，只剩对话 ⋯「现在写」）
        guard Self.enabled, ctx.manual || MemoryTriggers.mode(.a2) != .manual else { return .nothingToWrite }
        if !ctx.manual, let until = cooldown["\(Writer.context.rawValue)|\(conversationId)"], until > now { return .retry(at: until) }
        guard claim(conversationId, job: "CC 上下文摘要", retry: { [self] in
            await self.compressCC(conversationId: conversationId, ctx: ctx, container: container, providerManager: providerManager,
                                  caller: testCaller)
        }) else { return .retry(at: nil) }
        defer { release(conversationId) }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let cid = conversationId, pid = ctx.profileId
        guard let conv = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.id == cid && $0.profileId == pid
        })).first, conv.memoryEnabled, !conv.isTrashed else { return .nothingToWrite }
        let nodes = Self.mainPathNodes(conv, profileId: pid, context: context)
        guard Self.isCCPath(nodes) else { return .nothingToWrite }
        let caller = testCaller ?? Self.modelCaller(.context, ctx: ctx, providerManager: providerManager, conversationId: cid)
        switch await writeCC(conversationId: cid, title: conv.title, messages: nodes.map(Self.message), ctx: ctx, caller: caller, now: now) {
        case .wrote: return .wrote
        case .nothing: return .nothingToWrite
        case .skipped: return .retry(at: nil)   // 预算闸 / 空输出：下次巡检再来
        case .failed(let at): return .retry(at: at)
        }
    }

    /// CC 窗口写一趟的结果（巡检、「现在写」各自翻译）
    enum CCWrite: Equatable {
        case wrote(Int)
        case nothing
        case skipped
        case failed(retryAt: Date?)
    }

    /// CC 窗口 A2 的正文（已经占住窗口）：水位线之后满 60 条 / 跨过 05:00 的写成上下文摘要段
    private func writeCC(conversationId cid: String, title: String, messages: [SessionSegmentWriter.Message], ctx: Context,
                         caller: @escaping SessionSegmentWriter.Caller, now: Date) async -> CCWrite {
        let pid = ctx.profileId
        var s = SessionSummaryStore.loadOrSeed(conversationId: cid, profileId: pid, title: title)
        let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: MemoryStartDay.current)
        let parts = Self.ccCompressRanges(s, pathIds: messages.map(\.id), dates: messages.map(\.date), notBefore: notBefore, now: now)
        guard !parts.isEmpty else { return .nothing }
        let before = s.segments.filter { !$0.isTail }.count
        return await MemoryWriteLog.metered {
            do {
                let done = try await Self.writeContextParts(parts, messages: messages, into: &s, title: title,
                                                            persona: ctx.persona, speakers: ctx.speakers, caller: Self.gated(.context, caller), save: {
                    try Self.saveA2($0, profileId: pid)
                })
                await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
                guard done else { return .skipped }
                MemoryHealthStore.recordOK(.context, profileId: pid, modelName: ctx.model(.context).name,
                                           note: Self.contextNote(added: parts.count, title: title))
                CacheDiagLog.shared.log("📝 上下文摘要（CC）: ✅ \(title)（\(parts.count) 份）")
                return .wrote(max(0, s.segments.filter { !$0.isTail }.count - before))
            } catch {
                CacheDiagLog.shared.log("📝 上下文摘要（CC）: ❌ \(title) — \(error.localizedDescription)")
                _ = noteFailure(error, writer: .context, conversationId: cid, ctx: ctx)
                return .failed(retryAt: cooldown["\(Writer.context.rawValue)|\(cid)"])
            }
        }
    }

    /// 巡检时把最近动过的 CC 窗口查一遍（凌晨聊完、早上回来，昨天剩的那截也会写）。
    /// 写成了 / 确认不用写的，没新消息、也没跨过 05:00 就不再读节点；没写成的到重试时间以后再查
    private func sweepCC(ctx: Context, container: ModelContainer, providerManager: ProviderManager, now: Date) async {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let pid = ctx.profileId
        guard let since = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: now) else { return }
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.profileId == pid && $0.isTrashed == false && $0.updateTime >= since
        }))) ?? []
        let today = MemoryDay.key(now)
        for conv in convs where conv.memoryEnabled && conv.ccBridgeSessionName != nil {
            if let seen = ccChecked[conv.id], seen.updated == conv.updateTime, seen.day == today { continue }
            if let at = ccRetryAt[conv.id], at > now { continue }
            let id = conv.id, updated = conv.updateTime
            let result = await compressCC(conversationId: id, ctx: ctx, container: container, providerManager: providerManager, now: now)
            if result.settled {
                ccChecked[id] = (updated, today)
                ccRetryAt[id] = nil
            } else if case .retry(let at) = result {
                ccChecked[id] = nil
                ccRetryAt[id] = at
            }
        }
    }

    // MARK: - W3 收尾巡检

    /// 一次巡检请求（合并时攒着，补跑逐个消费：各带各的窗口 / 楼层，astra #11）
    private struct SweepRequest {
        let ctx: Context
        let container: ModelContainer
        let providerManager: ProviderManager
        let force: String?
        let active: String?
        let callers: ((Writer) -> SessionSegmentWriter.Caller)?

        func same(_ o: SweepRequest) -> Bool { ctx.profileId == o.ctx.profileId && force == o.force && active == o.active }
    }

    private var queuedSweeps: [SweepRequest] = []

    /// 合并触发：正在巡检就把这次请求攒下，跑完逐个补跑。activeConversationId = 刚回完一轮的那个窗口（A3 / A4 选了「每 N 回合」时只看它）。
    /// callers 只给测试换假写手
    func sweep(ctx: Context, container: ModelContainer, providerManager: ProviderManager,
               forceRecentExcept newConversationId: String? = nil, activeConversationId: String? = nil,
               callers testCallers: ((Writer) -> SessionSegmentWriter.Caller)? = nil) async {
        guard Self.closeoutEnabled || Self.enabled, !regenerating else { return }
        let request = SweepRequest(ctx: ctx, container: container, providerManager: providerManager, force: newConversationId,
                                   active: activeConversationId, callers: testCallers)
        if !queuedSweeps.contains(where: { $0.same(request) }) { queuedSweeps.append(request) }
        if sweeping { sweepAgain = true; return }
        sweeping = true
        defer { sweeping = false }
        repeat {
            sweepAgain = false
            let batch = queuedSweeps
            queuedSweeps = []
            for r in batch {
                await runSweep(ctx: r.ctx, container: r.container, providerManager: r.providerManager, force: r.force,
                               active: r.active, callers: r.callers)
            }
            if Self.enabled, let first = batch.first {
                await runIdleCompress(providerManager: first.providerManager, now: Date())
                var seen: Set<String> = []
                for r in batch where seen.insert(r.ctx.profileId).inserted {
                    await sweepCC(ctx: r.ctx, container: r.container, providerManager: r.providerManager, now: Date())
                }
            }
        } while sweepAgain
    }

    private func runSweep(ctx: Context, container: ModelContainer, providerManager: ProviderManager, force newConvId: String?,
                          active: String?, callers testCallers: ((Writer) -> SessionSegmentWriter.Caller)? = nil) async {
        guard Self.closeoutEnabled else { return }
        let now = Date()
        for item in Self.candidates(profileId: ctx.profileId, container: container, now: now, force: newConvId, active: active) {
            // 窗口总结格「正在记」显示「正在整理…」用；成功、失败、被掐断都先清掉再往下走
            await SessionCloseoutStatus.set(running: item.conversationId)
            let stop = await closeout(item, ctx: ctx, container: container, callers: testCallers ?? {
                Self.modelCaller($0, ctx: ctx, providerManager: providerManager, conversationId: item.conversationId)
            })
            await SessionCloseoutStatus.set(running: nil)
            // 进后台被掐断 / 没网：这一轮停下，下次巡检自动补
            if stop { return }
        }
    }

    // MARK: - A2「停 N 分钟」

    /// 每轮回复后（A2 选了「停 N 分钟」）记下这个窗口最新的样子；静默够了巡检时压
    func noteIdleCompress(conversationId: String, messages: [SessionSegmentWriter.Message], oldCount: Int, title: String,
                          ctx: Context, now: Date = Date()) {
        idleCompress[conversationId] = IdleCompress(messages: messages, oldCount: oldCount, title: title, ctx: ctx, at: now)
    }

    /// 静默够了的压掉。确认压到目标（锚点到了 oldCount）才出队；预算拦下 / 被占 / 暂时失败留着，下次巡检再试（astra #9）。
    /// 冷却中 compress 直接跳过不调模型；别的错（非断网、非格式）退避 30 分钟，免得每次巡检都打一遍。caller 只给测试换假写手
    func runIdleCompress(providerManager: ProviderManager, now: Date,
                         caller testCaller: ((Context, String) -> SessionSegmentWriter.Caller)? = nil) async {
        guard MemoryTriggers.mode(.a2) == .idle else { idleCompress = [:]; return }
        let idle = MemoryTriggers.idle(.a2)
        for (cid, job) in idleCompress where now.timeIntervalSince(job.at) >= idle && (job.retryAt ?? .distantPast) <= now {
            let caller = testCaller?(job.ctx, cid) ?? Self.modelCaller(.context, ctx: job.ctx, providerManager: providerManager, conversationId: cid)
            var failed = false
            do {
                _ = try await compress(messages: job.messages, oldCount: job.oldCount, conversationId: cid, title: job.title, ctx: job.ctx,
                                       caller: caller)
            } catch {
                failed = !Self.isTransient(error)
            }
            // 等模型时又来了一轮：快照已经换新，别动它
            guard idleCompress[cid]?.at == job.at else { continue }
            let covered = SessionSummaryStore.load(conversationId: cid, profileId: job.ctx.profileId)?.compressedCount ?? 0
            if covered >= job.oldCount {
                idleCompress[cid] = nil
            } else if failed {
                idleCompress[cid]?.retryAt = now.addingTimeInterval(Self.formatCooldown)
            }
        }
    }

    /// 测试用：还排着的 A2「停 N 分钟」
    var idleCompressPending: Set<String> { Set(idleCompress.keys) }

    struct Candidate {
        let conversationId: String
        let title: String
        let messages: [SessionSegmentWriter.Message]
        /// 这次写哪几个（各按自己的触发到点了的）
        var writers: Set<Writer> = [.window]
    }

    private static func candidates(profileId: String, container: ModelContainer, now: Date, force newConvId: String?,
                                   active: String?) -> [Candidate] {
        queue(profileId: profileId, container: container, now: now, force: newConvId, includeWaiting: false, active: active)
            .filter { $0.state == .due }
            .map { Candidate(conversationId: $0.conversationId, title: $0.title, messages: $0.messages, writers: $0.writers) }
    }

    /// 收尾队列里一个对话现在的状态（`candidates` 和窗口总结格「正在记」共用 `queueState` 这一份规则）
    enum QueueState: Equatable {
        /// 不在队列：水位线后面没有新消息
        case none
        /// 还没静默够：到这个时间点之后的下一次巡检才记
        case waiting(until: Date)
        /// 该收尾了：下一次巡检就记
        case due
    }

    struct QueueEntry {
        let conversationId: String
        let title: String
        let messages: [SessionSegmentWriter.Message]
        let state: QueueState
        /// 到点了的写手
        var writers: Set<Writer> = [.window]
    }

    /// 纯函数（可测）：updateTime = 对话最后更新；coveredUntil = 这个写手写到哪了（没写过 = nil）；
    /// force = 新建对话那次巡检（最近 recent 内聊过的不等静默）；idle = 这个写手「停 N 分钟」
    static func queueState(updateTime: Date, coveredUntil: Date?, lastMessageDate: Date?, hasPending: Bool,
                           now: Date, force: Bool, idle: TimeInterval = idleInterval, recent: TimeInterval = recentInterval) -> QueueState {
        // 已经写到对话最后更新那会儿 → 没有新消息（updateTime 比最后一条消息晚一点点，留 2 分钟余量）
        if let c = coveredUntil, c.addingTimeInterval(120) >= updateTime { return .none }
        guard let lastDate = lastMessageDate, hasPending else { return .none }
        if !force, now.timeIntervalSince(updateTime) < idle { return .waiting(until: updateTime.addingTimeInterval(idle)) }
        let quiet = now.timeIntervalSince(lastDate)
        let due = quiet >= idle || (force && quiet < recent)
        return due ? .due : .waiting(until: lastDate.addingTimeInterval(idle))
    }

    /// 一个写手的触发设置
    struct Trigger: Equatable {
        var mode: MemoryTriggerMode
        var idle: TimeInterval
        var rounds: Int
        var onNew: Bool

        static func current(_ writer: Writer) -> Trigger {
            Trigger(mode: MemoryTriggers.mode(writer.id), idle: MemoryTriggers.idle(writer.id),
                    rounds: MemoryTriggers.rounds(writer.id), onNew: MemoryTriggers.closesOnNewConversation(writer.id))
        }
    }

    /// 纯函数（可测）：一个写手对一个窗口的状态。pending = 它水位线之后还有几条没写
    /// - 停 N 分钟：同 `queueState`
    /// - 每 N 回合：攒够 N 回合（2N 条）就写；新建对话那次照 `onNew` 先写掉最近聊过的
    /// - 只手动：从不自动写
    static func writerState(_ t: Trigger, pending: Int, updateTime: Date, coveredUntil: Date?, lastMessageDate: Date?,
                            now: Date, force: Bool) -> QueueState {
        guard pending > 0 else { return .none }
        let forced = force && t.onNew
        switch t.mode {
        case .manual:
            return .none
        case .idle:
            if force && !t.onNew { return .none }
            return queueState(updateTime: updateTime, coveredUntil: coveredUntil, lastMessageDate: lastMessageDate, hasPending: true,
                              now: now, force: forced, idle: t.idle)
        case .rounds:
            if pending >= t.rounds * 2 { return .due }
            if forced, let last = lastMessageDate, now.timeIntervalSince(last) < recentInterval { return .due }
            return .none
        }
    }

    /// 纯函数（可测）：整个窗口主线两边加起来不超过 `MemoryMigration.shortWindowMax`（5）条 = 太短，收尾不写 A2 尾段 / A3
    /// （A2 尾段就在 A3 那一块里，一起不写；「现在写」不经队列，照样能写）。门槛和三代搬迁同一个（粟粟 10-16：5 句以内不走 A2 / A3）
    static func skipsSummary(messageCount: Int) -> Bool {
        messageCount <= MemoryMigration.shortWindowMax
    }

    /// 几个写手合起来：有一个到点 = 到点（只写到点的那几个）；否则最早的等待时间
    static func combined(_ states: [Writer: QueueState]) -> (state: QueueState, due: Set<Writer>) {
        let due = Set(states.filter { $0.value == .due }.keys)
        if !due.isEmpty { return (.due, due) }
        let waits = states.values.compactMap { s -> Date? in if case .waiting(let d) = s { return d } else { return nil } }
        return (waits.min().map { .waiting(until: $0) } ?? .none, [])
    }

    /// 最近 lookbackDays 天动过、开着记忆参与的对话里，窗口总结还有没写到的那些。
    /// includeWaiting = false（巡检）：还没静默够的先用 updateTime 便宜地跳过，不读节点（每轮回复后都巡检，别每次全读）；
    /// 「每 N 回合」只看刚回完一轮的那个窗口（active）
    static func queue(profileId: String, container: ModelContainer, now: Date, force newConvId: String?,
                      includeWaiting: Bool, active: String? = nil) -> [QueueEntry] {
        guard windowEnabled else { return [] }
        let triggers: [Writer: Trigger] = [.window: .current(.window)]
        let idleTriggers = triggers.values.filter { $0.mode == .idle }
        let minIdle = idleTriggers.map(\.idle).min()
        let anyRounds = triggers.values.contains { $0.mode == .rounds }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now) else { return [] }
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.profileId == profileId && $0.isTrashed == false && $0.updateTime >= since
        }))) ?? []
        // 「记忆从哪天开始」：最后一条消息早于起点的窗口不进队列（和「最近 7 天动过」两个条件都要满足）
        let startDay = MemoryStartDay.current
        var out: [QueueEntry] = []
        for conv in convs where conv.memoryEnabled && conv.id != newConvId {
            if !includeWaiting, newConvId == nil {
                let roundsHere = anyRounds && conv.id == active
                let quietEnough = minIdle.map { now.timeIntervalSince(conv.updateTime) >= $0 } ?? false
                if !roundsHere && !quietEnough { continue }
            }
            if let d = startDay, conv.updateTime < d { continue }
            let window = WindowSummaryStore.load(conversationId: conv.id, profileId: profileId)
            if let c = window?.updatedAt, c.addingTimeInterval(120) >= conv.updateTime { continue }
            let messages = mainPath(conv, profileId: profileId, context: context)
            guard let last = messages.last, let lastDate = last.date else { continue }
            if let d = startDay, lastDate < d { continue }
            let ids = messages.map(\.id)
            let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: startDay)
            var states: [Writer: QueueState] = [:]
            // 短窗口：不给 A3 排状态（「正在记」也不显示 A3 在等）；条数按整个窗口算，不管起点切掉几条
            if let t = triggers[.window], !skipsSummary(messageCount: messages.count) {
                let pending = window?.closedThrough == last.id ? 0 : windowPendingCount(pathIds: ids, closedThrough: window?.closedThrough, notBefore: notBefore)
                states[.window] = writerState(t, pending: pending, updateTime: conv.updateTime, coveredUntil: window?.updatedAt,
                                              lastMessageDate: lastDate, now: now, force: newConvId != nil)
            }
            let (state, due) = combined(states)
            guard state != .none, includeWaiting || state == .due else { continue }
            out.append(QueueEntry(conversationId: conv.id, title: conv.title, messages: messages, state: state, writers: due))
        }
        return out.sorted { ($0.messages.last?.date ?? .distantPast) < ($1.messages.last?.date ?? .distantPast) }
    }

    /// 纯函数（可测）：窗口总结水位线之后还有几条（没写过 = 起点之后全部）
    static func windowPendingCount(pathIds: [String], closedThrough: String?, notBefore: Int) -> Int {
        let start = closedThrough.flatMap { pathIds.lastIndex(of: $0) }.map { $0 + 1 } ?? 0
        return max(0, pathIds.count - max(start, notBefore))
    }

    /// 纯函数（可测）：[0, end) 里还要写进上下文摘要的那几截，按先后；空 = 没有要写的。end 默认整条路径，压缩传窗外条数。
    /// dates 和 pathIds 一一对应（消息时间）。
    /// - 一段都没有：最多从倒数 firstCloseoutCap 条开始（首次补写）
    /// - 最后一段之后：从水位线（`resumeIndex`）接着写，不设上限（原规则）
    /// - 第一段之前没写的（「记忆从哪天开始」往前挪了才会有）：按时间认——比最早一段还早的消息补上；
    ///   不早于整条路径倒数 firstCloseoutCap 条（路径只会变长，这条线不会早于当初首次补写的起点，当初被上限截掉的不会翻出来）。
    ///   有改版前累计摘要（它从第 0 条盖起）就没有这截
    /// - 全都不早于 notBefore（`MemoryStartDay.firstAllowedIndex`）；已有段盖住的一条都不重写
    /// - 只信压缩段和改造前的第 0 段（`coverage`）：老收尾段不再注入，它盖的那截要重新压成压缩段（astra #7）
    /// - capFirst = false（重新生成）：不套首次补写的 150 条上限，原来盖到哪就重建到哪
    static func pendingRanges(_ s: SessionSummary, pathIds: [String], dates: [Date?], end: Int? = nil,
                              notBefore: Int = 0, capFirst: Bool = true) -> [Range<Int>] {
        let s = coverage(s)
        let count = pathIds.count
        let end = min(end ?? count, count)
        let cap = capFirst ? firstCloseoutCap : count
        guard !s.segments.isEmpty else {
            let start = max(notBefore, end - cap, 0)
            return start < end ? [start..<end] : []
        }
        let tailStart = max(SessionSummaryStore.resumeIndex(s, pathIds: pathIds), notBefore)
        var out: [Range<Int>] = []
        if !s.segments.contains(where: { $0.kind == .legacy }), dates.count == count,
           let firstStart = s.segments.map(\.start).min() {
            let floor = max(notBefore, count - cap, 0)
            let stop = min(end, tailStart)
            if floor < stop {
                let headEnd = (floor..<stop).first { (dates[$0] ?? .distantFuture) >= firstStart } ?? stop
                if floor < headEnd { out.append(floor..<headEnd) }
            }
        }
        if tailStart < end { out.append(tailStart..<end) }
        return out
    }

    /// 上下文摘要真正盖住的段：压缩段 + 改造前的第 0 段。老收尾段不注入（属于窗口总结），不能算压缩水位
    static func coverage(_ s: SessionSummary) -> SessionSummary {
        var c = s
        c.segments = s.segments.filter { $0.kind != .closeout }
        return c
    }

    /// 纯函数（可测）：新写的一截插在哪——第一个开始得比它晚的段之前；接着写的照旧追加在最后。
    /// 段数组保持时间先后，`segments.last` 仍是最新那段（水位线、注入、recall 都靠它）
    static func insertionIndex(_ s: SessionSummary, chunkStart: Date?) -> Int {
        guard let d = chunkStart else { return s.segments.count }
        return s.segments.firstIndex { $0.kind != .legacy && $0.start > d } ?? s.segments.count
    }

    /// 纯函数（可测）：切成每份不超过 chunkSize 条
    static func chunks(_ range: Range<Int>, size: Int = chunkSize) -> [Range<Int>] {
        stride(from: range.lowerBound, to: range.upperBound, by: size).map { $0..<min($0 + size, range.upperBound) }
    }

    /// 一个窗口收尾（几个写手同一个 caller：测试用）
    func closeout(_ item: Candidate, ctx: Context, caller: @escaping SessionSegmentWriter.Caller) async -> Bool {
        await closeout(item, ctx: ctx, callers: { _ in caller })
    }

    /// 一个窗口收尾：A3 窗口总结（A2 开着时先把尾段收进 A2，再整个窗口重压）。
    /// container 非空（巡检）：占到窗口后按当前路径重读一遍再写——巡检开头取的快照可能已经旧了（astra #2）。
    /// 返回 true = 断网 / 被掐断，这一轮停下
    func closeout(_ item: Candidate, ctx: Context, container: ModelContainer? = nil,
                  callers: @escaping (Writer) -> SessionSegmentWriter.Caller) async -> Bool {
        guard !regenerating else { return true }
        guard claim(item.conversationId, job: "收尾", retry: { [self] in
            _ = await self.closeout(item, ctx: ctx, container: container, callers: callers)
        }) else { return false }
        defer { release(item.conversationId) }
        var item = item
        if let container {
            guard let path = Self.currentPath(item.conversationId, profileId: ctx.profileId, container: container) else { return false }
            item = Candidate(conversationId: item.conversationId, title: path.title, messages: path.messages, writers: item.writers)
        }
        return await closeoutBody(item, ctx: ctx, callers: callers).stop
    }

    /// 一次收尾写了什么（「现在写」的提示用）
    struct CloseoutResult: Equatable {
        var stop = false
        var tail = false
        var window = false
        /// 「现在写」顺手拼的 A4 天数（`TimelineDaily`）
        var timeline = 0
        /// CC 窗口「现在写」写的 A2 正式段（astra #6）
        var context = 0
        /// 这个窗口后台正在写，这次没动（astra #10，不排队）
        var busy = false
        /// 有写手被预算闸拦下 / 模型没回内容
        var skipped = false
        /// 有写手出错
        var failed = false
    }

    /// 纯函数（可测，astra #7）：收尾时写不写 A2 尾段——A2 开着才写；「只手动」或格式失败冷却中不自动写（A3 直接压原文那截），
    /// 「现在写」照写
    static func writesTail(manual: Bool, a2On: Bool, a2Mode: MemoryTriggerMode, a2Cooling: Bool) -> Bool {
        guard a2On else { return false }
        return manual || (a2Mode != .manual && !a2Cooling)
    }

    /// 纯函数（可测，astra #2）：已经写到的那条（mark / 它的消息时间）比这份快照更靠后 = 落盘会倒退。
    /// mark 在快照路径上 → 不靠后；不在（快照之后才来的消息，或切过分支）→ 按时间比：比快照最后一条还晚就是更靠后
    static func wouldRegress(mark: String?, markDate: Date?, snapshot: [SessionSegmentWriter.Message]) -> Bool {
        guard let mark, !snapshot.contains(where: { $0.id == mark }) else { return false }
        guard let markDate, let last = snapshot.last?.date else { return false }
        return markDate > last
    }

    /// 调模型返回 nil（预算闸 / 空输出 / 开关关了）记一笔，给「现在写」的提示用
    private final class NilProbe {
        var hit = false
        func watch(_ caller: @escaping SessionSegmentWriter.Caller) -> SessionSegmentWriter.Caller {
            { [self] system, user in
                let raw = try await caller(system, user)
                if raw == nil { hit = true }
                return raw
            }
        }
    }

    private func closeoutBody(_ item: Candidate, ctx: Context,
                              callers rawCallers: @escaping (Writer) -> SessionSegmentWriter.Caller) async -> CloseoutResult {
        // 短窗口门槛按执行时的实际路径再判一次（10-16 astra #8：排队时 6 条、等的时候删到 5 条也不写 A2 尾段 / A3）；「现在写」豁免
        var item = item
        if !ctx.manual, Self.skipsSummary(messageCount: item.messages.count) { item.writers.remove(.window) }
        let root = FileLibraryStore.memoryRoot(profileId: ctx.profileId)
        let notBefore = MemoryStartDay.firstAllowedIndex(item.messages.map(\.date), startDay: MemoryStartDay.current)
        var result = CloseoutResult()
        let probe = NilProbe()
        // astra #1：每次调模型前、落盘前复查总开关 + 这一项的开关
        let callers: (Writer) -> SessionSegmentWriter.Caller = { probe.watch(Self.gated($0, rawCallers($0))) }

        let window = WindowSummaryStore.load(conversationId: item.conversationId, in: root)
        if item.writers.contains(.window), Self.windowEnabled, ctx.manual || !cooling(.window, item.conversationId),
           notBefore < item.messages.count,
           window?.closedThrough != item.messages.last?.id,
           !Self.wouldRegress(mark: window?.closedThrough, markDate: window?.updatedAt, snapshot: item.messages) {
            var s = SessionSummaryStore.loadOrSeed(conversationId: item.conversationId, profileId: ctx.profileId, title: item.title)
            // D1：A2 写着 → 尾段收进 A2（整段重写）；写不成照样往下，A3 用原文那截。
            // A2「只手动」/ 冷却中不自动写尾段（astra #7）
            if Self.writesTail(manual: ctx.manual, a2On: Self.enabled, a2Mode: MemoryTriggers.mode(.a2),
                               a2Cooling: cooling(.context, item.conversationId)) {
                await MemoryWriteLog.metered {
                    do {
                        if let t = try await Self.writeTail(context: s, messages: item.messages, notBefore: notBefore, persona: ctx.persona,
                                                            speakers: ctx.speakers, caller: callers(.context)) {
                            s = t
                            try Self.saveA2(s, profileId: ctx.profileId)
                            result.tail = true
                            MemoryHealthStore.recordOK(.context, profileId: ctx.profileId, modelName: ctx.model(.context).name,
                                                       note: "尾段 · 《\(item.title)》")
                        }
                    } catch {
                        CacheDiagLog.shared.log("📝 上下文摘要尾段: ❌ \(item.title) — \(error.localizedDescription)")
                        result.failed = true
                        if noteFailure(error, writer: .context, conversationId: item.conversationId, ctx: ctx) { result.stop = true }
                    }
                }
                if result.stop { result.skipped = probe.hit; return result }
            }
            // D2：A2 全部段 + 尾段，整个窗口重压
            await MemoryWriteLog.metered {
                do {
                    if let w = try await Self.recompressWindow(context: s, messages: item.messages, title: item.title, notBefore: notBefore,
                                                               persona: ctx.persona, speakers: ctx.speakers, caller: callers(.window)) {
                        try WindowSummaryStore.save(w, in: root)
                        result.window = true
                        let chars = w.segments.first?.story.count ?? 0
                        MemoryHealthStore.recordOK(.summary, profileId: ctx.profileId, modelName: ctx.model(.window).name,
                                                   note: "《\(item.title)》\(chars) 字")
                        CacheDiagLog.shared.log("📝 窗口总结: ✅ \(item.title)（\(chars) 字）")
                    }
                } catch {
                    CacheDiagLog.shared.log("📝 窗口总结: ❌ \(item.title) — \(error.localizedDescription)")
                    result.failed = true
                    if noteFailure(error, writer: .window, conversationId: item.conversationId, ctx: ctx) { result.stop = true }
                }
            }
            if result.stop { result.skipped = probe.hit; return result }
        }

        if result.tail || result.window {
            await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
        }
        result.skipped = probe.hit
        return result
    }

    // MARK: - 对话 ⋯「现在写」（plan §九）

    /// 这个窗口开着的 A2 / A3 立刻写一遍：不等静默、不看冷却、不看写入预算（ctx.manual）；A4 由 `SessionCloseoutTrigger.writeNow` 接着拼。
    /// API 窗口的 A2 由发消息那条路的手动压缩写；CC 窗口的 A2 在这里写（astra #6，不依赖 A3）。
    /// 后台正在写这个窗口：不排队，返回 busy（astra #10）
    func closeoutNow(conversationId: String, ctx: Context, container: ModelContainer, providerManager: ProviderManager,
                     now: Date = Date(), callers testCallers: ((Writer) -> SessionSegmentWriter.Caller)? = nil) async -> CloseoutResult {
        guard Self.closeoutEnabled || Self.enabled else { return CloseoutResult() }
        let cid = conversationId
        guard !regenerating, busy[cid] == nil else { return CloseoutResult(busy: true) }
        var ctx = ctx
        ctx.manual = true
        guard let path = Self.currentPath(cid, profileId: ctx.profileId, container: container), !path.messages.isEmpty else {
            return CloseoutResult()
        }
        guard claim(cid, job: "现在写", retry: {}) else { return CloseoutResult(busy: true) }
        defer { release(cid) }
        let manualCtx = ctx
        let callers: (Writer) -> SessionSegmentWriter.Caller = testCallers
            ?? { Self.modelCaller($0, ctx: manualCtx, providerManager: providerManager, conversationId: cid) }
        var result = CloseoutResult()
        if Self.enabled, path.isCC {
            switch await writeCC(conversationId: cid, title: path.title, messages: path.messages, ctx: ctx, caller: callers(.context), now: now) {
            case .wrote(let n): result.context = n
            case .nothing: break
            case .skipped: result.skipped = true
            case .failed: result.failed = true
            }
        }
        guard Self.closeoutEnabled else { return result }
        let body = await closeoutBody(Candidate(conversationId: cid, title: path.title, messages: path.messages), ctx: ctx, callers: callers)
        result.stop = body.stop
        result.tail = body.tail
        result.window = body.window
        result.skipped = result.skipped || body.skipped
        result.failed = result.failed || body.failed
        return result
    }

    /// 这个窗口现在的主线路径（对话不在 / 关了记忆 / 进了回收站 = nil）。isCC = 回复是从 CC 那条路落地的
    static func currentPath(_ cid: String, profileId pid: String, container: ModelContainer)
        -> (title: String, messages: [SessionSegmentWriter.Message], isCC: Bool)? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let conv = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.id == cid && $0.profileId == pid
        })).first, conv.memoryEnabled, !conv.isTrashed else { return nil }
        let nodes = mainPathNodes(conv, profileId: pid, context: context)
        return (conv.title, nodes.map(message), isCCPath(nodes))
    }

    // MARK: - W3① 窗口总结

    /// 纯函数（可测）：最后那截从哪条开始 = 给的这些段的水位线之后，最多 150 条，不早于记忆起点
    static func windowTailStart(context segments: [SessionSegment], pathIds: [String], notBefore: Int) -> Int {
        let ctxOnly = SessionSummary(conversationId: "", title: "", compressedCount: 0, segments: segments, updatedAt: .distantPast)
        let resume = segments.isEmpty ? 0 : SessionSummaryStore.resumeIndex(ctxOnly, pathIds: pathIds)
        return min(max(resume, notBefore, pathIds.count - firstCloseoutCap, 0), pathIds.count)
    }

    /// D1：A2 的尾段——上下文摘要正式段（老收尾段不算）水位线之后到眼下这一截，整段重写，换掉旧尾段。
    /// nil = 没有要写的（没新消息 / 尾段已经写到最后一条）或写手跳过
    static func writeTail(context s: SessionSummary, messages: [SessionSegmentWriter.Message], notBefore: Int,
                          persona: String, speakers: SessionSegmentWriter.Speakers,
                          caller: SessionSegmentWriter.Caller) async throws -> SessionSummary? {
        let formal = s.segments.filter { $0.kind != .closeout }
        let start = windowTailStart(context: formal, pathIds: messages.map(\.id), notBefore: notBefore)
        guard start < messages.count else { return nil }
        if let old = s.segments.last(where: \.isTail) {
            if old.from == start, old.lastNodeId == messages.last?.id { return nil }
            // astra #2：旧尾段已经写到这份快照之后了，不倒退
            if wouldRegress(mark: old.lastNodeId, markDate: old.end, snapshot: messages) { return nil }
        }
        guard var tail = try await SessionSegmentWriter.write(
            .init(messages: Array(messages[start...]), kind: .closeout, from: start, persona: persona,
                  speakers: speakers, previous: formal.last),
            caller: caller) else { return nil }
        tail.isTail = true
        var out = s
        out.segments.removeAll { $0.isTail }
        out.segments.append(tail)
        out.updatedAt = Date()
        return out
    }

    /// D2：A3 = 读 A2 全部段 + 尾段（老收尾段不算；A2 没盖到的最后那截给原文），整个窗口重压约 N 字，存成一段。nil = 写手跳过 / 没东西
    static func recompressWindow(context s: SessionSummary, messages: [SessionSegmentWriter.Message], title: String, notBefore: Int,
                                 persona: String, speakers: SessionSegmentWriter.Speakers, caller: SessionSegmentWriter.Caller,
                                 chars: Int = MemoryWriterSettings.a3Chars) async throws -> SessionSummary? {
        guard let first = messages.first, let last = messages.last else { return nil }
        let segments = s.segments.filter { $0.kind != .closeout || $0.isTail }
        let start = windowTailStart(context: segments, pathIds: messages.map(\.id), notBefore: notBefore)
        let raw = start < messages.count ? Array(messages[start...]) : []
        guard !segments.isEmpty || !raw.isEmpty else { return nil }
        guard let seg = try await WindowSummaryWriter.write(
            title: title, segments: segments, rawTail: raw, persona: persona, speakers: speakers, chars: chars,
            start: segments.first?.start ?? first.date ?? Date(), end: last.date ?? Date(), to: messages.count, lastNodeId: last.id,
            caller: caller) else { return nil }
        return SessionSummary(conversationId: s.conversationId, title: title, compressedCount: s.compressedCount,
                              segments: [seg], updatedAt: last.date ?? Date(), closedThrough: last.id)
    }

    /// 尾段 + 重压合起来（三代搬迁用）：返回新的 A2（带尾段）和 A3。
    /// 尾段算 A2 的（tailCaller），重压算 A3 的（windowCaller）——各用各的模型、记各的账（三代搬迁 M3）
    static func composeWindowSummary(context s: SessionSummary, messages: [SessionSegmentWriter.Message], title: String,
                                     notBefore: Int, persona: String, speakers: SessionSegmentWriter.Speakers,
                                     tailCaller: SessionSegmentWriter.Caller, windowCaller: SessionSegmentWriter.Caller) async throws -> (context: SessionSummary, window: SessionSummary)? {
        var ctx = s
        if let t = try await writeTail(context: s, messages: messages, notBefore: notBefore, persona: persona,
                                       speakers: speakers, caller: tailCaller) {
            ctx = t
        }
        guard let w = try await recompressWindow(context: ctx, messages: messages, title: title, notBefore: notBefore,
                                                 persona: persona, speakers: speakers, caller: windowCaller) else { return nil }
        return (ctx, w)
    }

    // MARK: - 主线路径（和 recall 同一个求法）

    static func mainPathNodes(_ conv: Conversation, profileId: String, context: ModelContext) -> [MessageNode] {
        (try? mainPathNodesStrict(conv, profileId: profileId, context: context)) ?? []
    }

    /// 同上，取不出就抛（A4 读窗口：读不全要明说，不当成「没消息」）
    static func mainPathNodesStrict(_ conv: Conversation, profileId: String, context: ModelContext) throws -> [MessageNode] {
        let cid = conv.id
        let nodes = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> {
            $0.conversationId == cid && $0.profileId == profileId && $0.isTrashed == false
        }))
        let mainSet = ConversationViewModel.computeMainPathSet(nodes: nodes, currentNodeId: conv.currentNodeId, selectionData: conv.branchSelectionData)
        return nodes
            .filter { mainSet.contains($0.id) && ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty }
            .sorted { ($0.createTime ?? .distantPast) < ($1.createTime ?? .distantPast) }
    }

    static func message(_ node: MessageNode) -> SessionSegmentWriter.Message {
        .init(id: node.id, role: node.role, content: ContentCleaner.clean(node.content, cacheKey: node.id), date: node.createTime)
    }

    static func mainPath(_ conv: Conversation, profileId: String, context: ModelContext) -> [SessionSegmentWriter.Message] {
        mainPathNodes(conv, profileId: profileId, context: context).map(message)
    }

    /// CC 窗口：主线上最后一条 assistant 带 ccMessageId（回复是从 CC 那条路落地的）
    static func isCCPath(_ nodes: [MessageNode]) -> Bool {
        nodes.last { $0.role == "assistant" }?.ccMessageId != nil
    }
}

/// 收尾巡检的触发口：app 启动时接上 manager，之后回到前台 / 进后台 / 每轮回复结束 / 切换对话 / 新建对话都喊一声。
/// 不挂在发消息那条路上——cc-bridge 楼层不经过花园组 prompt，也照样能收尾。
@MainActor
final class SessionCloseoutTrigger {
    static let shared = SessionCloseoutTrigger()

    private weak var profileManager: ProfileManager?
    private weak var providerManager: ProviderManager?

    func attach(profileManager: ProfileManager, providerManager: ProviderManager) {
        self.profileManager = profileManager
        self.providerManager = providerManager
        PendingStore.warm(profileId: profileManager.currentProfile.id)   // v5：组 prompt 只读待续缓存，启动时后台先读好
    }

    /// 哪个线程都能喊（VM 不是 MainActor 隔离的）；真正干活在主线程上拿 manager。
    /// activeConversationId = 刚回完一轮的窗口（A3 / A4 选了「每 N 回合」时巡检只看它）；profileId = 它在哪一层（nil = 当前楼层）
    nonisolated func request(newConversationId: String? = nil, activeConversationId: String? = nil, profileId: String? = nil) {
        Task { @MainActor in
            self.requestOnMain(newConversationId: newConversationId, activeConversationId: activeConversationId, profileId: profileId)
        }
    }

    /// CC 回复落地要喊哪几声（纯函数，可测）
    enum CCLanding: Equatable {
        /// A2：满 60 条 / 跨过 05:00
        case contextSummary
        /// A3 收尾巡检（「每 N 回合」看这个窗口，astra #8）+ 后面接着的 A4 一天一条
        case closeout
        /// C2：每满 N 条（`mem_c2_every`，默认 20）
        case fragments
    }

    nonisolated static func ccLandingRequests(memoryEnabled: Bool) -> [CCLanding] {
        guard memoryEnabled else { return [] }
        var out: [CCLanding] = []
        if MemoryFlags.contextSummaryEnabled { out.append(.contextSummary) }
        if SessionCloseout.closeoutEnabled || SessionCloseout.timelineEnabled { out.append(.closeout) }
        if MemoryFlags.masterEnabled && MemoryFlags.factsEnabled { out.append(.fragments) }
        return out
    }

    /// CC 回复落地（`insertProactiveAssistantMessage` 末尾）：和 API 那条路一样喊——A2、A3 巡检 + A4（带这个窗口和它的楼层）、C2
    nonisolated func ccReplyLanded(conversationId: String, profileId: String, memoryEnabled: Bool) {
        for r in Self.ccLandingRequests(memoryEnabled: memoryEnabled) {
            switch r {
            case .contextSummary: requestCC(conversationId: conversationId, profileId: profileId)
            case .closeout: request(activeConversationId: conversationId, profileId: profileId)
            case .fragments: requestFragmentsCC(conversationId: conversationId, profileId: profileId)
            }
        }
    }

    /// 收尾 / CC 写手用的上下文：各写手单选的模型（v5 A7，没选 = 提取模型）。chat = 退回用的对话模型（nil = 全局选的）
    nonisolated static func context(profile: Profile, providers: ProviderManager, chat: ProviderModel? = nil) -> SessionCloseout.Context {
        let chat = chat ?? providers.resolveModel(conversationModelId: nil, globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        let memory = ConversationViewModel.memoryModel(providerManager: providers, fallback: chat)
        let available = FragmentModelRoute.remoteCredentials(providers.enabledProviders).flatMap(\.models)
        var models: [SessionCloseout.Writer: ProviderModel] = [:]
        for w in SessionCloseout.Writer.allCases {
            models[w] = MemoryWriterModels.resolve(choice: MemoryWriterModels.choice(w.id), memoryModel: memory, available: available)
        }
        return SessionCloseout.Context(profile: profile, model: memory, writerModels: models)
    }

    /// CC 回复落地（`insertProactiveAssistantMessage` 末尾）：这个 CC 窗口满 60 条 / 跨过 05:00 的写成上下文摘要。
    /// 同一个对话 60 秒内只喊一次（hub replay 一次能砸来几百条）
    private var lastCCRequest: [String: Date] = [:]

    nonisolated func requestCC(conversationId: String, profileId: String) {
        Task { @MainActor in self.requestCCOnMain(conversationId: conversationId, profileId: profileId) }
    }

    private func requestCCOnMain(conversationId: String, profileId: String, now: Date = Date()) {
        guard SessionCloseout.enabled, let pm = profileManager, let providers = providerManager else { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if let last = lastCCRequest[conversationId], now.timeIntervalSince(last) < 60 { return }
        lastCCRequest[conversationId] = now
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("ccContextSummary"); return }
        #endif
        let profile = pm.profiles.first { $0.id == profileId } ?? pm.currentProfile
        let ctx = Self.context(profile: profile, providers: providers)
        let container = pm.container
        Task.detached(priority: .utility) {
            await SessionCloseout.shared.compressCC(conversationId: conversationId, ctx: ctx, container: container, providerManager: providers)
        }
    }

    /// C2 · CC 窗口（plan §七）：CC 回复落地时数一下，每满 N 条新消息（`mem_c2_every`）把这一截交给碎片池（同 API 那条路、同一份水位：只加、严格 JSON）
    nonisolated func requestFragmentsCC(conversationId: String, profileId: String) {
        Task { @MainActor in self.requestFragmentsCCOnMain(conversationId: conversationId, profileId: profileId) }
    }

    private func requestFragmentsCCOnMain(conversationId: String, profileId: String) {
        guard MemoryFlags.masterEnabled, MemoryFlags.factsEnabled, let pm = profileManager, let providers = providerManager else { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("memoryExtract"); return }
        #endif
        let profile = pm.profiles.first { $0.id == profileId } ?? pm.currentProfile
        let chat = providers.resolveModel(conversationModelId: nil, globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        let route = FragmentModelRoute.resolve(providerManager: providers, chatFallback: chat)
        let caller = FragmentModelRoute.caller(for: route.route, providerManager: providers, conversationId: conversationId, profileId: profileId)
        let names = MemoryExtractor.Names(userName: profile.userName, assistantName: profile.assistantName)
        let container = pm.container
        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let cid = conversationId, pid = profileId
            guard let conv = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
                $0.id == cid && $0.profileId == pid
            })).first, conv.memoryEnabled, !conv.isTrashed else { return }
            let nodes = SessionCloseout.mainPathNodes(conv, profileId: pid, context: context)
            guard let claim = await FragmentWatch.shared.due(conversationId: cid, pathIds: nodes.map(\.id), dates: nodes.map(\.createTime),
                                                            threshold: FragmentWatch.every())
            else { return }
            let msgs = nodes[claim.range].map {
                FragmentPool.Message(id: $0.id, role: $0.role, content: ContentCleaner.clean($0.content, cacheKey: $0.id), date: $0.createTime)
            }
            let outcome = await MemoryWriteLog.metered {
                await FragmentPool.process(msgs, names: names, caller: caller,
                                           local: route.isLocal, profileId: pid,
                                           modelName: route.displayName, fallbackNote: route.fallbackNote) { fragments in
                    // 认领超时作废了就不落库（10-16 astra #3）
                    guard await FragmentWatch.shared.holds(conversationId: cid, token: claim.token) else { throw FragmentPoolError.staleClaim }
                    return try FragmentPool.write(fragments, messages: msgs, profileId: pid, conversationId: cid,
                                                  extractedBy: route.displayName, store: SwiftDataMemoryStore(), context: context)
                }
            }
            // 写成（含合法空包）/ 整包拒收才挪水位；预算跳过 / 断网 / 请求或落库失败留着下次再来（同 API 那条路，10-16 astra #2）
            await FragmentWatch.shared.finish(conversationId: cid, claim: claim, outcome: outcome)
            if case .done(let added) = outcome, added > 0 {
                await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
            }
        }
    }

    /// newConversationId 非空 = 刚新建了对话：最近 12 小时聊过的立刻收尾（各写手「新建对话时先写掉」开着的），不等静默。
    /// 收尾巡检完再看 A4：这一层今天（05:00 起）还没拼过就拼最近几天（A2 刚落盘的段也算进去）
    private func requestOnMain(newConversationId: String?, activeConversationId: String?, profileId: String?) {
        guard SessionCloseout.closeoutEnabled || SessionCloseout.enabled || SessionCloseout.timelineEnabled,
              let pm = profileManager, let providers = providerManager else { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("closeout"); return }
        #endif
        let profile = profileId.flatMap { id in pm.profiles.first { $0.id == id } } ?? pm.currentProfile
        let ctx = Self.context(profile: profile, providers: providers)
        let container = pm.container
        let timeline = SessionCloseout.timelineEnabled && !TimelineDaily.ranToday(profileId: profile.id)
            ? Self.timelineInput(profile: profile, providers: providers, container: container, manual: false) : nil
        Task.detached(priority: .utility) {
            await SessionCloseout.shared.sweep(ctx: ctx, container: container, providerManager: providers,
                                               forceRecentExcept: newConversationId, activeConversationId: activeConversationId)
            if let timeline { _ = await Self.runTimeline(timeline, force: false) }
        }
    }

    /// 对话 ⋯「现在写」的 A3 那半 + CC 窗口的 A2（plan §九），再拼 A4（最近几天 + 今天，今天的主调重写）：不等静默、不看冷却、不看写入预算。返回写了什么
    func writeNow(conversationId: String, profile: Profile) async -> SessionCloseout.CloseoutResult {
        guard let pm = profileManager, let providers = providerManager else { return .init() }
        let ctx = Self.context(profile: profile, providers: providers)
        let container = pm.container
        let timeline = SessionCloseout.timelineEnabled ? Self.timelineInput(profile: profile, providers: providers, container: container, manual: true) : nil
        return await Task.detached(priority: .userInitiated) {
            var r = await SessionCloseout.shared.closeoutNow(conversationId: conversationId, ctx: ctx, container: container, providerManager: providers)
            if !r.busy, let timeline, let report = await Self.runTimeline(timeline, force: true) {
                r.timeline = report.written.count
                if !report.failed.isEmpty || report.blocked != nil { r.failed = true }
            }
            return r
        }.value
    }

    /// A4 一天一条（第 7 段）：C3 每天那次先等它（`CatalogRunner.dailyTick`）。今天拼过就直接回来；正在拼就等它拼完
    @discardableResult
    func timelineDaily(profile: Profile) async -> TimelineDaily.Report? {
        guard SessionCloseout.timelineEnabled, let pm = profileManager, let providers = providerManager else { return nil }
        let input = Self.timelineInput(profile: profile, providers: providers, container: pm.container, manual: false)
        return await Task.detached(priority: .utility) { await Self.runTimeline(input, force: false) }.value
    }

    /// 时间轴页「重写这天的主调」：只这一天，有标题就重调一次（不看写入预算）
    @discardableResult
    func timelineRegenerate(day: String, profile: Profile) async -> TimelineDaily.Report? {
        guard SessionCloseout.timelineEnabled, let pm = profileManager, let providers = providerManager else { return nil }
        let input = Self.timelineInput(profile: profile, providers: providers, container: pm.container, manual: true)
        return await Task.detached(priority: .userInitiated) {
            guard await !SessionCloseout.shared.regenerating else { return nil }
            return await TimelineDaily.shared.regenerate(day: day, input)
        }.value
    }

    nonisolated static func runTimeline(_ input: TimelineDaily.Input, force: Bool) async -> TimelineDaily.Report? {
        guard await !SessionCloseout.shared.regenerating else { return nil }
        return await TimelineDaily.shared.runDue(input, force: force)
    }

    /// A4 的模型 / 楼层 / 读窗口（主线程取好）：默认本机轻巧款，没装 / 在后台退回提取模型；manual 不看写入预算。账记在 A4 名下
    static func timelineInput(profile: Profile, providers: ProviderManager, container: ModelContainer, manual: Bool) -> TimelineDaily.Input {
        let chat = providers.resolveModel(conversationModelId: nil, globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        let route = TimelineModelRoute.resolve(providerManager: providers, chatFallback: chat)
        let pid = profile.id
        func remote(_ model: ProviderModel) -> SessionSegmentWriter.Caller {
            SessionCloseout.gated(.timeline, SessionSegmentWriter.modelCaller(model: model, providerManager: providers, conversationId: "", profileId: pid,
                                                                               kind: .timeline, checkWriteBudget: !manual))
        }
        let caller: SessionSegmentWriter.Caller
        var fallback: SessionSegmentWriter.Caller?
        switch route.route {
        case .local:
            caller = SessionCloseout.gated(.timeline, FragmentModelRoute.caller(for: route.route, providerManager: providers, conversationId: "", profileId: pid,
                                                                                kind: .timeline, budgetExceeded: manual ? { false } : { WriteBudgetStore.exceeded() }))
            // 本机放不下 / 跑挂 / 回来解析不了：A4 这层退到提取模型（云端，照查写入预算和全局闸）
            fallback = remote(ConversationViewModel.memoryModel(providerManager: providers, fallback: chat))
        case .remote(let model):
            caller = remote(model)
        }
        if let note = route.fallbackNote { CacheDiagLog.shared.log("📝 时间轴: \(note)") }
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        return TimelineDaily.Input(profileId: pid, memoryRoot: root, startDay: MemoryStartDay.current,
                                   caller: caller, fallback: fallback, modelName: route.displayName,
                                   load: { TimelineDaily.windows(profileId: pid, container: container, memoryRoot: root, in: $0) })
    }
}
/// 收尾巡检正在整理哪个对话（窗口总结格「正在记」显示「正在整理…」用）。只给界面看，不参与收尾逻辑
@MainActor
@Observable
final class SessionCloseoutStatus {
    static let shared = SessionCloseoutStatus()
    private(set) var runningConversationId: String?

    nonisolated static func set(running conversationId: String?) async {
        await MainActor.run { shared.runningConversationId = conversationId }
    }
}
