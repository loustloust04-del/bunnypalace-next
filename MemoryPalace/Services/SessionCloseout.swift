import Foundation
import Observation
import SwiftData

/// 记忆写手的总调度（plan-memory-v4-1 §四 §五）：W2 上下文摘要（API 超窗压缩 / CC 满 60 条或跨过 05:00）、
/// W3 收尾（窗口总结 + 时间轴，两次调用、两种格式）都从这里进，同一个窗口同一时刻只有一个写手在写
actor SessionCloseout {
    static let shared = SessionCloseout()

    /// 静默多久算关窗
    static let idleInterval: TimeInterval = 30 * 60
    /// 新建对话时：最近多久聊过的对话立刻收尾（不等静默）
    static let recentInterval: TimeInterval = 2 * 3600
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

        /// 人设 = 系统提示 + 角色描述（和第二刀提取同一个口径）
        init(profile: Profile, model: ProviderModel) {
            profileId = profile.id
            persona = [profile.systemPrompt, profile.characterDescription]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            userName = profile.userName
            assistantName = profile.assistantName
            self.model = model
        }

        var speakers: SessionSegmentWriter.Speakers { .init(userName: userName, assistantName: assistantName) }
    }

    /// 三个写手（健康状态三行、冷却各算各的）
    enum Writer: String {
        case context, window, timeline

        var health: MemoryHealthStore.Kind {
            switch self {
            case .context: return .context
            case .window: return .summary
            case .timeline: return .timeline
            }
        }
    }

    private var sweeping = false
    private var sweepAgain = false
    /// 正在写的窗口：W2、W3 动笔前先占住，占不到记一笔，前一个跑完再补跑一次
    private var busy: Set<String> = []
    private var retryAfter: [String: [String: () async -> Void]] = [:]
    /// 「写手|窗口」→ 冷却到什么时候（格式两次不合格）
    private var cooldown: [String: Date] = [:]
    /// CC 巡检记过的（窗口 → 当时的更新时间 + 那天）：没新消息、没跨过 05:00 就不再读节点
    private var ccChecked: [String: (updated: Date, day: String)] = [:]
    /// CC 窗口上次没写成：到这个时间以后再查
    private var ccRetryAt: [String: Date] = [:]
    /// 重新生成（DEBUG）进行中：日常写手都先停
    private(set) var regenerating = false

    /// 「上下文摘要和窗口总结」开关：管 W2 和窗口总结
    static var enabled: Bool { MemoryFlags.contextSummaryEnabled }
    /// 「时间轴」开关：管时间轴
    static var timelineEnabled: Bool { TimelineConsolidator.enabled }
    /// 收尾跑不跑：任一个开着就跑（Q3）
    static var closeoutEnabled: Bool { enabled || timelineEnabled }

    static var fullSegmentCount: Int {
        let v = UserDefaults.standard.integer(forKey: "mem_session_full_segments")
        return v > 0 ? min(v, 4) : 2
    }

    // MARK: - 占位 / 冷却 / 健康

    private func claim(_ conversationId: String, job: String, retry: @escaping () async -> Void) -> Bool {
        guard busy.contains(conversationId) else {
            busy.insert(conversationId)
            return true
        }
        retryAfter[conversationId, default: [:]][job] = retry
        CacheDiagLog.shared.log("📝 记忆写手: 这个窗口正在写，\(job) 等它写完再补一次")
        return false
    }

    private func release(_ conversationId: String) {
        busy.remove(conversationId)
        guard let jobs = retryAfter.removeValue(forKey: conversationId) else { return }
        for job in jobs.values { Task.detached(priority: .utility) { await job() } }
    }

    private func cooling(_ writer: Writer, _ conversationId: String, now: Date = Date()) -> Bool {
        (cooldown["\(writer.rawValue)|\(conversationId)"] ?? .distantPast) > now
    }

    /// 写手出错：断网 / 被掐断不算（返回 true = 整个停下，下次巡检自动补）；格式错进冷却；都记健康状态
    private func noteFailure(_ error: Error, writer: Writer, conversationId: String, ctx: Context) -> Bool {
        if Self.isTransient(error) { return true }
        if case MemoryWriterError.format = error {
            cooldown["\(writer.rawValue)|\(conversationId)"] = Date().addingTimeInterval(Self.formatCooldown)
        }
        MemoryHealthStore.recordError(writer.health, profileId: ctx.profileId, message: error.localizedDescription, modelName: ctx.model.name)
        return false
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let code = (error as? URLError)?.code, [.cancelled, .networkConnectionLost, .notConnectedToInternet].contains(code) { return true }
        return false
    }

    func setRegenerating(_ on: Bool) { regenerating = on }

    /// 重新生成要等日常写手都停手：有人在写就等一会儿
    func waitUntilIdle() async {
        while !busy.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    // MARK: - W2 上下文摘要 · API（超窗时，由发消息那条路触发）

    /// messages = 当前路径全部 user / assistant（和历史窗口同一个口径）；oldCount = 窗外条数。
    /// 已被老收尾段总结过的部分不重写，只推锚点；没总结过的那截写成上下文摘要段。返回新的锚点（nil = 没动）
    func compress(messages: [SessionSegmentWriter.Message], oldCount: Int, conversationId: String, title: String,
                  ctx: Context, caller: @escaping SessionSegmentWriter.Caller) async throws -> Int? {
        guard !regenerating, !cooling(.context, conversationId) else { return nil }
        guard claim(conversationId, job: "上下文摘要", retry: { [self] in
            _ = try? await self.compress(messages: messages, oldCount: oldCount, conversationId: conversationId, title: title,
                                         ctx: ctx, caller: caller)
        }) else { return nil }
        defer { release(conversationId) }

        var s = SessionSummaryStore.loadOrSeed(conversationId: conversationId, profileId: ctx.profileId, title: title)
        let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: MemoryStartDay.current)
        guard let plan = Self.compressPlan(s, pathIds: messages.map(\.id), dates: messages.map(\.date), oldCount: oldCount, notBefore: notBefore) else { return nil }
        let parts = plan.ranges.flatMap { Self.chunks($0) }
        let finished: Bool
        do {
            finished = try await Self.writeContextParts(parts, messages: messages, into: &s, title: title,
                                                        persona: ctx.persona, speakers: ctx.speakers, caller: caller) {
                try SessionSummaryStore.save($0, profileId: ctx.profileId)
            }
        } catch {
            _ = noteFailure(error, writer: .context, conversationId: conversationId, ctx: ctx)
            throw error
        }
        guard finished else { return nil }
        s.compressedCount = plan.anchor
        s.title = title
        s.updatedAt = Date()
        try SessionSummaryStore.save(s, profileId: ctx.profileId)
        if !parts.isEmpty { MemoryHealthStore.recordOK(.context, profileId: ctx.profileId, modelName: ctx.model.name) }
        return plan.anchor
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
    /// 返回 false = 写手跳过（预算闸 / 空输出），后面的不写
    static func writeContextParts(_ parts: [Range<Int>], messages: [SessionSegmentWriter.Message], into s: inout SessionSummary,
                                  title: String, persona: String, speakers: SessionSegmentWriter.Speakers,
                                  caller: SessionSegmentWriter.Caller, save: (SessionSummary) throws -> Void) async throws -> Bool {
        for part in parts {
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
        guard Self.enabled else { return .nothingToWrite }
        if let until = cooldown["\(Writer.context.rawValue)|\(conversationId)"], until > now { return .retry(at: until) }
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
        let messages = nodes.map(Self.message)
        var s = SessionSummaryStore.loadOrSeed(conversationId: cid, profileId: pid, title: conv.title)
        let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: MemoryStartDay.current)
        let parts = Self.ccCompressRanges(s, pathIds: messages.map(\.id), dates: messages.map(\.date), notBefore: notBefore, now: now)
        guard !parts.isEmpty else { return .nothingToWrite }
        let caller = testCaller ?? SessionSegmentWriter.modelCaller(model: ctx.model, providerManager: providerManager, conversationId: cid, profileId: pid)
        do {
            let done = try await Self.writeContextParts(parts, messages: messages, into: &s, title: conv.title,
                                                        persona: ctx.persona, speakers: ctx.speakers, caller: caller, save: {
                try SessionSummaryStore.save($0, profileId: pid)
            })
            await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
            guard done else { return .retry(at: nil) }   // 预算闸 / 空输出：下次巡检再来
            MemoryHealthStore.recordOK(.context, profileId: pid, modelName: ctx.model.name)
            CacheDiagLog.shared.log("📝 上下文摘要（CC）: ✅ \(conv.title)（\(parts.count) 份）")
            return .wrote
        } catch {
            CacheDiagLog.shared.log("📝 上下文摘要（CC）: ❌ \(conv.title) — \(error.localizedDescription)")
            _ = noteFailure(error, writer: .context, conversationId: cid, ctx: ctx)
            return .retry(at: cooldown["\(Writer.context.rawValue)|\(cid)"])
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

    /// 合并触发：正在巡检就记一笔，跑完再来一遍
    func sweep(ctx: Context, container: ModelContainer, providerManager: ProviderManager,
               forceRecentExcept newConversationId: String? = nil) async {
        guard Self.closeoutEnabled, !regenerating else { return }
        if sweeping { sweepAgain = true; return }
        sweeping = true
        defer { sweeping = false }
        repeat {
            sweepAgain = false
            await runSweep(ctx: ctx, container: container, providerManager: providerManager, force: newConversationId)
            if Self.enabled { await sweepCC(ctx: ctx, container: container, providerManager: providerManager, now: Date()) }
        } while sweepAgain
    }

    private func runSweep(ctx: Context, container: ModelContainer, providerManager: ProviderManager, force newConvId: String?) async {
        guard Self.closeoutEnabled else { return }
        let now = Date()
        for item in Self.candidates(profileId: ctx.profileId, container: container, now: now, force: newConvId) {
            // 窗口总结格「正在记」显示「正在整理…」用；成功、失败、被掐断都先清掉再往下走
            await SessionCloseoutStatus.set(running: item.conversationId)
            let caller = SessionSegmentWriter.modelCaller(model: ctx.model, providerManager: providerManager,
                                                          conversationId: item.conversationId, profileId: ctx.profileId)
            let stop = await closeout(item, ctx: ctx, caller: caller)
            await SessionCloseoutStatus.set(running: nil)
            // 进后台被掐断 / 没网：这一轮停下，下次巡检自动补
            if stop { return }
        }
    }

    struct Candidate {
        let conversationId: String
        let title: String
        let messages: [SessionSegmentWriter.Message]
    }

    private static func candidates(profileId: String, container: ModelContainer, now: Date, force newConvId: String?) -> [Candidate] {
        queue(profileId: profileId, container: container, now: now, force: newConvId, includeWaiting: false)
            .filter { $0.state == .due }
            .map { Candidate(conversationId: $0.conversationId, title: $0.title, messages: $0.messages) }
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
    }

    /// 纯函数（可测）：updateTime = 对话最后更新；coveredUntil = 开着的写手都写到哪了（取最早的；有一个没写过 = nil）；
    /// force = 新建对话那次巡检（最近 2 小时聊过的不等静默）
    static func queueState(updateTime: Date, coveredUntil: Date?, lastMessageDate: Date?, hasPending: Bool,
                           now: Date, force: Bool) -> QueueState {
        // 已经写到对话最后更新那会儿 → 没有新消息（updateTime 比最后一条消息晚一点点，留 2 分钟余量）
        if let c = coveredUntil, c.addingTimeInterval(120) >= updateTime { return .none }
        guard let lastDate = lastMessageDate, hasPending else { return .none }
        if !force, now.timeIntervalSince(updateTime) < idleInterval { return .waiting(until: updateTime.addingTimeInterval(idleInterval)) }
        let idle = now.timeIntervalSince(lastDate)
        let due = idle >= idleInterval || (force && idle < recentInterval)
        return due ? .due : .waiting(until: lastDate.addingTimeInterval(idleInterval))
    }

    /// 最近 lookbackDays 天动过、开着记忆参与的对话里，窗口总结或时间轴（看哪个开着）还有没写到的那些。
    /// includeWaiting = false（巡检）：还没静默够的先用 updateTime 便宜地跳过，不读节点（每轮回复后都巡检，别每次全读）
    static func queue(profileId: String, container: ModelContainer, now: Date, force newConvId: String?,
                      includeWaiting: Bool) -> [QueueEntry] {
        let summaryOn = enabled, timelineOn = timelineEnabled
        guard summaryOn || timelineOn else { return [] }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now) else { return [] }
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.profileId == profileId && $0.isTrashed == false && $0.updateTime >= since
        }))) ?? []
        // 「记忆从哪天开始」：最后一条消息早于起点的窗口不进队列（和「最近 7 天动过」两个条件都要满足）
        let startDay = MemoryStartDay.current
        let tlDir = TimelineStore.dir(profileId: profileId)
        // 时间轴每个窗口最新一条：本月 + 上月一次读齐（巡检只看最近 7 天动过的）
        let latestTimeline = timelineOn ? TimelineStore.latestByConversation(near: now, in: tlDir) : [:]
        var out: [QueueEntry] = []
        for conv in convs where conv.memoryEnabled && conv.id != newConvId {
            if !includeWaiting, newConvId == nil, now.timeIntervalSince(conv.updateTime) < idleInterval { continue }
            if let d = startDay, conv.updateTime < d { continue }
            let window = summaryOn ? WindowSummaryStore.load(conversationId: conv.id, profileId: profileId) : nil
            let latest = latestTimeline[conv.id]
            let covered = Self.coveredUntil(window: window, latest: latest, summaryOn: summaryOn, timelineOn: timelineOn)
            if let c = covered, c.addingTimeInterval(120) >= conv.updateTime { continue }
            let messages = mainPath(conv, profileId: profileId, context: context)
            guard let last = messages.last, let lastDate = last.date else { continue }
            if let d = startDay, lastDate < d { continue }
            let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: startDay)
            let windowPending = summaryOn && notBefore < messages.count && window?.closedThrough != last.id
            var timelinePending = false
            if timelineOn {
                let legacy = latest == nil
                    ? SessionSummaryStore.load(conversationId: conv.id, profileId: profileId)?.segments.last(where: { $0.kind == .closeout })?.lastNodeId
                    : nil
                timelinePending = timelineStart(pathIds: messages.map(\.id), dates: messages.map(\.date), latest: latest,
                                                legacyLast: legacy, notBefore: notBefore) < messages.count
            }
            let state = queueState(updateTime: conv.updateTime, coveredUntil: covered, lastMessageDate: lastDate,
                                   hasPending: windowPending || timelinePending, now: now, force: newConvId != nil)
            guard state != .none, includeWaiting || state == .due else { continue }
            out.append(QueueEntry(conversationId: conv.id, title: conv.title, messages: messages, state: state))
        }
        return out.sorted { ($0.messages.last?.date ?? .distantPast) < ($1.messages.last?.date ?? .distantPast) }
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

    /// 纯函数（可测，astra #8）：开着的写手都写到哪条消息的时间了（取最早；有一个没写过 = nil）。
    /// 窗口总结用它盖到的最后一条消息的时间（`updatedAt` 存的就是它，不是写文件那一刻），时间轴用最新一条的结束时间——
    /// 写手等模型时又来了新消息，下次巡检照样看得见
    static func coveredUntil(window: SessionSummary?, latest: TimelineEntry?, summaryOn: Bool, timelineOn: Bool) -> Date? {
        var covered: [Date?] = []
        if summaryOn { covered.append(window?.updatedAt) }
        if timelineOn { covered.append(latest?.end) }
        return covered.contains { $0 == nil } ? nil : covered.compactMap { $0 }.min()
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

    /// 一个窗口收尾：窗口总结、时间轴分开写、分开判（一个格式没过不拦另一个）。返回 true = 断网 / 被掐断，这一轮停下
    func closeout(_ item: Candidate, ctx: Context, caller: @escaping SessionSegmentWriter.Caller) async -> Bool {
        guard !regenerating else { return true }
        guard claim(item.conversationId, job: "收尾", retry: { [self] in
            _ = await self.closeout(item, ctx: ctx, caller: caller)
        }) else { return false }
        defer { release(item.conversationId) }

        let root = FileLibraryStore.memoryRoot(profileId: ctx.profileId)
        let notBefore = MemoryStartDay.firstAllowedIndex(item.messages.map(\.date), startDay: MemoryStartDay.current)
        var changed = false

        if Self.enabled, !cooling(.window, item.conversationId) {
            do {
                if try await Self.closeWindowSummary(item, notBefore: notBefore, ctx: ctx, caller: caller, root: root) {
                    changed = true
                    MemoryHealthStore.recordOK(.summary, profileId: ctx.profileId, modelName: ctx.model.name)
                }
            } catch {
                CacheDiagLog.shared.log("📝 窗口总结: ❌ \(item.title) — \(error.localizedDescription)")
                if noteFailure(error, writer: .window, conversationId: item.conversationId, ctx: ctx) { return true }
            }
        }

        if Self.timelineEnabled, !cooling(.timeline, item.conversationId) {
            do {
                let n = try await Self.closeTimeline(item, notBefore: notBefore, ctx: ctx, caller: caller, root: root)
                if n > 0 {
                    changed = true
                    MemoryHealthStore.recordOK(.timeline, profileId: ctx.profileId, modelName: ctx.model.name)
                    CacheDiagLog.shared.log("📝 时间轴: ✅ \(item.title)（\(n) 份）")
                }
            } catch {
                CacheDiagLog.shared.log("📝 时间轴: ❌ \(item.title) — \(error.localizedDescription)")
                if noteFailure(error, writer: .timeline, conversationId: item.conversationId, ctx: ctx) { return true }
            }
        }

        if changed { await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) } }
        return false
    }

    // MARK: - W3① 窗口总结

    /// 纯函数（可测）：窗口总结最后那段从哪条开始 = 上下文摘要水位线之后，最多 150 条，不早于记忆起点
    static func windowTailStart(context segments: [SessionSegment], pathIds: [String], notBefore: Int) -> Int {
        let ctxOnly = SessionSummary(conversationId: "", title: "", compressedCount: 0, segments: segments, updatedAt: .distantPast)
        let resume = segments.isEmpty ? 0 : SessionSummaryStore.resumeIndex(ctxOnly, pathIds: pathIds)
        return min(max(resume, notBefore, pathIds.count - firstCloseoutCap, 0), pathIds.count)
    }

    /// 整份窗口总结：上下文摘要各段（老收尾段不算）原样抄 + 新写的最后那段（每次收尾整段重写）。
    /// nil = 写手跳过（预算闸 / 空输出）；最后那截没有消息就只抄上下文摘要
    static func composeWindowSummary(context s: SessionSummary, messages: [SessionSegmentWriter.Message], title: String,
                                     notBefore: Int, persona: String, speakers: SessionSegmentWriter.Speakers,
                                     caller: SessionSegmentWriter.Caller) async throws -> SessionSummary? {
        let contextSegments = s.segments.filter { $0.kind != .closeout }
        var segments = contextSegments
        let start = windowTailStart(context: contextSegments, pathIds: messages.map(\.id), notBefore: notBefore)
        if start < messages.count {
            guard let tail = try await SessionSegmentWriter.write(
                .init(messages: Array(messages[start...]), kind: .closeout, from: start, persona: persona,
                      speakers: speakers, previous: contextSegments.last),
                caller: caller) else { return nil }
            segments.append(tail)
        }
        return SessionSummary(conversationId: s.conversationId, title: title, compressedCount: s.compressedCount,
                              segments: segments, updatedAt: messages.last?.date ?? Date(), closedThrough: messages.last?.id)
    }

    /// 写窗口总结（整份重写 windows/ 那个文件）。返回 true = 写了
    private static func closeWindowSummary(_ item: Candidate, notBefore: Int, ctx: Context, caller: SessionSegmentWriter.Caller,
                                           root: URL) async throws -> Bool {
        guard notBefore < item.messages.count else { return false }
        if WindowSummaryStore.load(conversationId: item.conversationId, in: root)?.closedThrough == item.messages.last?.id { return false }
        let s = SessionSummaryStore.loadOrSeed(conversationId: item.conversationId, profileId: ctx.profileId, title: item.title)
        guard let w = try await composeWindowSummary(context: s, messages: item.messages, title: item.title, notBefore: notBefore,
                                                     persona: ctx.persona, speakers: ctx.speakers, caller: caller),
              !w.segments.isEmpty else { return false }
        try WindowSummaryStore.save(w, in: root)
        CacheDiagLog.shared.log("📝 窗口总结: ✅ \(item.title)（\(w.segments.count) 段）")
        return true
    }

    // MARK: - W3② 时间轴

    /// 纯函数（可测）：时间轴从路径第几条接着写——这个窗口最新一条 v2 条目的 last；没有 v2 条目时退回旧收尾段的 lastNodeId；
    /// 都没有就算第一次补写（倒回 150 条）。last 在路径里找不到（切过分支）按那条的结束时间认。不早于记忆起点
    static func timelineStart(pathIds: [String], dates: [Date?], latest: TimelineEntry?, legacyLast: String?, notBefore: Int) -> Int {
        let count = pathIds.count
        var start: Int
        if let l = latest, l.day != nil {
            if let id = l.lastNodeId, let i = pathIds.lastIndex(of: id) {
                start = i + 1
            } else {
                start = dates.firstIndex { ($0 ?? .distantPast) > l.end } ?? count
            }
        } else if let id = legacyLast, let i = pathIds.lastIndex(of: id) {
            start = i + 1
        } else {
            start = count - firstCloseoutCap
        }
        return min(max(start, notBefore, 0), count)
    }

    /// 纯函数（可测）：一截消息先按天（05:00）切、每天再按 60 条切，一份一份写
    static func timelineParts(_ range: Range<Int>, dates: [Date?], calendar: Calendar = .current) -> [Range<Int>] {
        MemoryDay.split(Array(dates[range]), calendar: calendar).flatMap { day in
            chunks((range.lowerBound + day.lowerBound)..<(range.lowerBound + day.upperBound))
        }
    }

    /// 一份一份写进时间轴：同一天的几份改写同一条，不同天各一条；日期、起止时间、话题都来自那一天自己的消息。
    /// 每份写完就落盘（中途断了下次从 last 接着）。返回写了几份；写手跳过（预算闸）就停
    static func writeTimeline(_ range: Range<Int>, messages: [SessionSegmentWriter.Message], conversationId: String, title: String,
                              persona: String, speakers: SessionSegmentWriter.Speakers, caller: SessionSegmentWriter.Caller,
                              dir: URL) async throws -> Int {
        var written = 0
        for part in timelineParts(range, dates: messages.map(\.date)) {
            let slice = Array(messages[part])
            guard let firstDate = slice.lazy.compactMap(\.date).first, let lastDate = slice.last(where: { $0.date != nil })?.date else { continue }
            let day = MemoryDay.key(firstDate)
            let existing = TimelineStore.entry(day: day, conversationId: conversationId, in: dir)
            // 这一天已经有条目：不再喂上一条的待续（已有那条接过了，Q5）
            let previousPending = existing == nil ? TimelineStore.latest(conversationId: conversationId, before: day, in: dir)?.pending : nil
            guard let draft = try await TimelineWriter.write(
                .init(day: day, windowTitle: title, existing: existing, previousPending: previousPending,
                      messages: slice, persona: persona, speakers: speakers),
                caller: caller) else { return written }
            let entry = TimelineEntry(start: min(existing?.start ?? firstDate, firstDate), end: max(existing?.end ?? lastDate, lastDate),
                                      conversationId: conversationId, title: title, text: draft.text, pending: draft.pendingText,
                                      day: day, lastNodeId: slice.last?.id)
            try TimelineStore.upsert(entry, in: dir)
            written += 1
        }
        return written
    }

    private static func closeTimeline(_ item: Candidate, notBefore: Int, ctx: Context, caller: SessionSegmentWriter.Caller,
                                      root: URL) async throws -> Int {
        let dir = TimelineStore.dir(root: root)
        let latest = TimelineStore.latest(conversationId: item.conversationId, v2Only: true, in: dir)
        let legacy = latest == nil
            ? SessionSummaryStore.load(conversationId: item.conversationId, profileId: ctx.profileId)?.segments.last(where: { $0.kind == .closeout })?.lastNodeId
            : nil
        let start = timelineStart(pathIds: item.messages.map(\.id), dates: item.messages.map(\.date), latest: latest,
                                  legacyLast: legacy, notBefore: notBefore)
        guard start < item.messages.count else { return 0 }
        return try await writeTimeline(start..<item.messages.count, messages: item.messages, conversationId: item.conversationId,
                                       title: item.title, persona: ctx.persona, speakers: ctx.speakers, caller: caller, dir: dir)
    }

    // MARK: - 主线路径（和 recall 同一个求法）

    static func mainPathNodes(_ conv: Conversation, profileId: String, context: ModelContext) -> [MessageNode] {
        let cid = conv.id
        let nodes = (try? context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> {
            $0.conversationId == cid && $0.profileId == profileId && $0.isTrashed == false
        }))) ?? []
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
    }

    /// 哪个线程都能喊（VM 不是 MainActor 隔离的）；真正干活在主线程上拿 manager
    nonisolated func request(newConversationId: String? = nil) {
        Task { @MainActor in self.requestOnMain(newConversationId: newConversationId) }
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
        let chat = providers.resolveModel(conversationModelId: nil, globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        let ctx = SessionCloseout.Context(profile: profile, model: ConversationViewModel.memoryModel(providerManager: providers, fallback: chat))
        let container = pm.container
        Task.detached(priority: .utility) {
            await SessionCloseout.shared.compressCC(conversationId: conversationId, ctx: ctx, container: container, providerManager: providers)
        }
    }

    /// newConversationId 非空 = 刚新建了对话：最近 2 小时聊过的立刻收尾，不等静默
    private func requestOnMain(newConversationId: String?) {
        guard SessionCloseout.closeoutEnabled, let pm = profileManager, let providers = providerManager else { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("closeout"); return }
        #endif
        let chat = providers.resolveModel(conversationModelId: nil, globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        let ctx = SessionCloseout.Context(profile: pm.currentProfile,
                                          model: ConversationViewModel.memoryModel(providerManager: providers, fallback: chat))
        let container = pm.container
        Task.detached(priority: .utility) {
            await SessionCloseout.shared.sweep(ctx: ctx, container: container, providerManager: providers,
                                               forceRecentExcept: newConversationId)
        }
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
