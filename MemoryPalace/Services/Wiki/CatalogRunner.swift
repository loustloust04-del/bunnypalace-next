import MemoryCore
import Foundation
import SwiftData
#if DEBUG
import os
#endif

// MARK: - C3 的设置（二级页那几行；plan-memory-c3-catalog 4.3）

enum CatalogSettings {
    /// 每天自动整理（默认开）
    static let dailyKey = "mem_c3_daily"
    /// 自动一次最多几个主题（⧫E = 8，只管自动那次）
    static let maxTopicsKey = "mem_c3_max_topics"
    static let defaultMaxTopics = 8
    static let maxTopicsRange = 1...30
    /// 手动整理一个主题最多几轮（⧫F = 10）
    static let maxRoundsKey = "mem_c3_agent_rounds"
    static let defaultMaxRounds = CatalogAgent.defaultRounds
    static let maxRoundsRange = 3...20
    /// 分拣：代码（默认，零模型）/ 模型（用 C3 所选模型，算写入预算）
    static let sorterKey = "mem_c3_sorter"

    enum Sorter: String, Sendable {
        case code, model
    }

    static func sorter(_ defaults: UserDefaults = .standard) -> Sorter {
        defaults.string(forKey: sorterKey).flatMap(Sorter.init(rawValue:)) ?? .code
    }

    static func daily(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: dailyKey) as? Bool) ?? true
    }

    static func maxTopics(_ defaults: UserDefaults = .standard) -> Int {
        clamp(defaults.integer(forKey: maxTopicsKey), default: defaultMaxTopics, maxTopicsRange)
    }

    static func maxRounds(_ defaults: UserDefaults = .standard) -> Int {
        clamp(defaults.integer(forKey: maxRoundsKey), default: defaultMaxRounds, maxRoundsRange)
    }

    private static func clamp(_ v: Int, default d: Int, _ range: ClosedRange<Int>) -> Int {
        v == 0 ? d : min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - 每天什么时候跑（⧫A：过了 05:00 第一次在前台；mac 开着到点直接跑）

enum CatalogSchedule {
    /// 这个楼层哪天跑过（运行记录，不进配置导出）
    static func ranKey(_ profileId: String) -> String { "mem_c3_ran.\(profileId)" }

    enum Decision: Equatable {
        case run
        /// 今天记下、不跑，日志记一行原因
        case skip(String)
    }

    /// 记忆日（05:00 分界）换了才算新的一天
    static func isDue(lastDay: String?, now: Date, calendar: Calendar = .current) -> Bool {
        lastDay != MemoryDay.key(now, calendar: calendar)
    }

    /// 下一个 05:00
    static func nextBoundary(after now: Date, calendar: Calendar = .current) -> Date {
        let start = MemoryDay.dayStart(now, calendar: calendar)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return MemoryDay.boundary(of: next, calendar: calendar)
    }

    /// 今天要不要管：nil = 今天已经管过了；否则记下今天，再看开关和预算（一天只记一行，回前台几次都不重复）
    static func decide(profileId: String, now: Date, defaults: UserDefaults = .standard, calendar: Calendar = .current,
                       budgetExceeded: () -> Bool) -> Decision? {
        let key = ranKey(profileId)
        guard isDue(lastDay: defaults.string(forKey: key), now: now, calendar: calendar) else { return nil }
        defaults.set(MemoryDay.key(now, calendar: calendar), forKey: key)
        if !MemoryWriterSettings.writes(.c3, defaults: defaults) { return .skip("C3 关着，今天不自动整理") }
        if !CatalogSettings.daily(defaults) { return .skip("「每天自动整理」关着，今天不自动整理") }
        if budgetExceeded() { return .skip("写入预算用完，今天不自动整理") }
        return .run
    }
}

// MARK: - 同一楼层同一时间只跑一个（手动和自动互斥，后来的排队）

actor CatalogLock {
    static let shared = CatalogLock()

    private var busy = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    #if DEBUG
    private static let waiterCounts = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func waiterCount(_ key: String) -> Int {
        waiterCounts.withLock { $0[key, default: 0] }
    }
    #endif

    func acquire(_ profileId: String) async {
        guard busy.contains(profileId) else {
            busy.insert(profileId)
            return
        }
        await withCheckedContinuation {
            waiters[profileId, default: []].append($0)
            #if DEBUG
            Self.waiterCounts.withLock { $0[profileId, default: 0] += 1 }
            #endif
        }
    }

    func release(_ profileId: String) {
        if var queue = waiters[profileId], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[profileId] = queue.isEmpty ? nil : queue
            #if DEBUG
            Self.waiterCounts.withLock {
                let remaining = $0[profileId, default: 0] - 1
                $0[profileId] = remaining > 0 ? remaining : nil
            }
            #endif
            next.resume()
        } else {
            busy.remove(profileId)
        }
    }
}

// MARK: - 一次整理

/// 一次整理要的东西（模型、楼层、路径都备好；测试换假的 caller / 后端）
struct CatalogJob {
    var profileId: String
    var memoryRoot: URL
    var container: ModelContainer
    var names: MemoryExtractor.Names
    var floorPrompt: String
    var modelName: String
    /// 两步用：写入预算 → 全局闸 → 请求 → 记账（`UsageKind.catalog`）
    var caller: SessionSegmentWriter.Caller
    /// 手动 agent 用
    var agentDeps: CatalogAgent.Deps
    var maxTopics = CatalogSettings.defaultMaxTopics
    var maxRounds = CatalogSettings.defaultMaxRounds
    var sorter = CatalogSettings.Sorter.code
    /// A4 开着才读时间轴这一路线索
    var timeline = true
    var embedder: any MemoryEmbedding = AppleMemoryEmbedder.shared
    /// 种子读的 Prompt 原料：楼层完整底图（主线程取好的不可变值；nil = 没有 Prompt 原料）
    var floorBase: CatalogFloorBase? = nil
    /// 种子的 agent 依赖：不查、不扣日常写入预算（全局总闸照查）；nil = 同 agentDeps（测试）
    var seedDeps: CatalogAgent.Deps? = nil
    /// C3 所选模型的稳定身份（`local:<id>` / `remote:<凭据>/<模型>`）：种子任务绑它，续跑按它认，本机路线的写手按它判全文会不会被裁
    var seedModel = ""
    /// 所选模型这次用不了、会回退到别的模型时的原因：种子不许隐式回退，直接不跑
    var seedBlocked: String? = nil

    var wiki: WikiStore { WikiStore(root: memoryRoot.appendingPathComponent("wiki", isDirectory: true)) }
}

/// 种子续跑按任务合并：还在排队的不再排第二个；正在跑时又有新审批，跑完且正常结束才再续一次；
/// 失败 / 停 / 被拦之后，排着的旧请求不自动再付费跑（等她点「继续」或再批）
struct CatalogSeedResumeQueue {
    private var states: [String: (started: Bool, again: Bool)] = [:]

    /// 要不要现在排一个
    mutating func request(_ taskId: String) -> Bool {
        if let state = states[taskId] {
            if state.started { states[taskId]?.again = true }
            return false
        }
        states[taskId] = (false, false)
        return true
    }

    mutating func began(_ taskId: String) {
        states[taskId]?.started = true
    }

    func contains(_ taskId: String) -> Bool { states[taskId] != nil }

    /// 跑完：要不要再续一次
    mutating func finished(_ taskId: String, ok: Bool) -> Bool {
        let again = states[taskId]?.again ?? false
        states[taskId] = nil
        return again && ok
    }
}

/// 一次整理的结果（审计台「整理提案」格顶上那行、记忆日志）
struct CatalogRunReport: Equatable, Sendable {
    var proposals = 0
    var items = 0
    var single = 0
    /// 没整理完的提案几份
    var incomplete = 0
    /// 没跑（没有待整理的碎片 / 开关 / 预算）
    var skipped: String? = nil
    /// 被写入预算 / 全局闸拦下
    var blocked: String? = nil
    var failures: [String] = []
    var cancelled = false
    /// 给她看的附注（清旧种子的清单、种子完成）
    var notes: [String] = []

    var summary: String {
        if let skipped { return skipped }
        var parts: [String] = notes
        parts.append(proposals > 0 ? "交了 \(proposals) 份提案 · \(items) 条" : "没出提案")
        if incomplete > 0 { parts.append("\(incomplete) 份没整理完") }
        if single > 0 { parts.append("\(single) 条单条就够") }
        if let blocked { parts.append("被拦：\(blocked)") }
        if !failures.isEmpty { parts.append("\(failures.count) 处出错") }
        if cancelled { parts.append("停了") }
        return parts.joined(separator: " · ")
    }
}

/// 跑一次：每天自动（分拣提方向）/ 批了的方向（这才搜、写）/ 现在整理（分拣列主题，再每个主题一个 agent）/ 整理一个主题（一个 agent）
@MainActor
final class CatalogSession {
    let job: CatalogJob
    /// (当前主题, 第几轮)；日常写手那次轮数是 0
    var onProgress: ((String?, Int) -> Void)?
    /// 自动写手、分组调整和它们的格式重试都看它
    let cancelToken = CatalogCancel()
    private var agent: CatalogAgent?
    private let finishSeed: @Sendable (WikiStore, Date, String) throws -> Void
    private var run: CatalogRunRecord?
    /// 模型分拣成功那次的输入指纹：方向全部存下了才落盘（停了 / 哪一步失败都不写，也不覆盖旧的）
    private var sortFingerprint: String?
    /// 这次看过的 A4 日记录（日期 → 签名）：方向全部存下了才记进进度；没交出去的方向依据的那几天不算看过
    private var timelineSeen: [String: String]?

    var isCancelled: Bool { cancelToken.isCancelled }

    init(job: CatalogJob, finishSeed: @escaping @Sendable (WikiStore, Date, String) throws -> Void = { try CatalogSeed.finish(wiki: $0, at: $1, taskId: $2) }) {
        self.job = job
        self.finishSeed = finishSeed
    }

    func cancel() {
        cancelToken.cancel()
        agent?.cancel()
    }

    private func log(_ note: String, ok: Bool = true) async {
        let anchor = run?.section("日志", body: CatalogRunRecord.code(note))
        await run?.flush()
        MemoryWriteLog.record(writer: .c3, profileId: job.profileId, ok: ok, note: note, model: job.modelName,
                              run: run?.link(anchor: anchor), memoryRoot: FileLibraryStore.memoryRoot(profileId: job.profileId))
    }

    private func save(_ proposal: WikiProposal) async -> Bool {
        let store = WikiProposalStore(wiki: job.wiki)
        do {
            try await Task.detached(priority: .utility) { try store.save(proposal) }.value
            return true
        } catch {
            await log("提案没存成：\(error.localizedDescription)", ok: false)
            return false
        }
    }

    private func beginRun(_ topic: String, kind: String, now: Date) {
        run = CatalogRunRecord(wiki: job.wiki, topic: topic, kind: kind, now: now)
    }

    private func finishRun(_ report: CatalogRunReport) async -> CatalogRunReport {
        run?.section("运行结果", body: CatalogRunRecord.code(report.summary))
        await run?.flush()
        return report
    }

    /// 自动方向：碎片分拣（代码基线默认零模型 / 模型可选）+ A4 时间轴连续出现的新话题 + 页上 valid_until 到期，都对着此刻的 wiki 索引，
    /// 再去掉以前提过的方向：已有待批方向的目标不重复提，处理过的目标没有新碎片 / 新线索不再提。最多 maxTopics 个，剩下的下次。
    /// 没有新碎片照样看时间轴和到期；A4 这一路没准备好只记一笔，不挡别的
    private func discover(drafts: CatalogDrafts, now: Date, report: inout CatalogRunReport) async -> (items: [WikiProposal.Item], rest: Int) {
        let wiki = job.wiki
        let root = job.memoryRoot
        let readTimeline = job.timeline
        let pool = await CatalogMaterial.pending(profileId: job.profileId, container: job.container, wiki: wiki)
        let hasFresh = pool.contains { $0.organizedAt == nil }
        timelineSeen = nil
        let (snapshot, prior, source, reported) = await Task.detached(priority: .utility) {
            let state = CatalogDiscoveryState.load(wiki)
            return (WikiInjection.load(wiki), CatalogSorter.priorDirections(WikiProposalStore(wiki: wiki)),
                    readTimeline ? CatalogTimeline.load(memoryRoot: root, consumed: state.consumed, now: now) : nil, state.reported)
        }.value
        let problems = source?.problems ?? []
        if problems != reported {
            if let error = source?.error {
                await log("A4 时间轴这一路没准备好（\(error)），这次不看时间轴，碎片和到期照常", ok: false)
            } else if !problems.isEmpty {
                await log("A4 时间轴有 \(problems.count) 天有 A2 标题、主调却没写成（\(problems.joined(separator: "、"))），这几天的话题不算，别的照常", ok: false)
            }
            await Task.detached(priority: .utility) { try? CatalogDiscoveryState.update(wiki) { $0.reported = problems } }.value
        }
        let timeline = source.map { CatalogTimeline.modelDays($0) } ?? []
        let blocked = [job.names.user, job.names.char] + snapshot.stopWords
        var grouped = CatalogSorter.Grouped(topics: [], unclear: 0)
        var timelineRead = job.sorter == .code || timeline.isEmpty
        if hasFresh || (job.sorter == .model && !timeline.isEmpty) {
            if let g = await sort(hasFresh ? pool : [], snapshot: snapshot, blocked: blocked, timeline: timeline, drafts: drafts, now: now,
                                  fingerprinted: true, report: &report) {
                grouped = g
                timelineRead = true
            } else if report.cancelled {
                return ([], 0)
            }
        }
        let history = source?.history ?? [:]
        let fromTimeline = job.sorter == .code
            ? source.map { CatalogSorter.timeline($0, pages: snapshot.pages, blocked: blocked, taken: grouped.topics) } ?? []
            : grouped.timeline.map { CatalogTimeline.identified($0, history: history) }
        let expired = CatalogSorter.expired(snapshot.pages, now: now)
        let all = CatalogSorter.merged(grouped.topics + fromTimeline + expired)
        let hooks = Dictionary(snapshot.pages.map { ($0.path, $0.hook) }, uniquingKeysWith: { a, _ in a })
        let blockedSet = Set(blocked.map(CatalogSorter.key))
        let fresh = all.filter { t in
            !prior.pending.contains(t.target) && CatalogSorter.isNew(t, clues: prior.clues[t.target] ?? [], basis: prior.basis)
        }
        if (grouped.topics + grouped.timeline).contains(where: { prior.pending.contains($0.target) }) || fresh.count > job.maxTopics { sortFingerprint = nil }
        if let source, timelineRead {
            let delivered = Set(fresh.prefix(job.maxTopics).map(\.target))
            let held = all.filter { !$0.days.isEmpty && !delivered.contains($0.target) && !Set($0.basis).isSubset(of: prior.basis) }
            let keep = Set(held.flatMap(\.days))
            timelineSeen = source.signatures.filter { !keep.contains($0.key) }
        }
        let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = fresh.prefix(job.maxTopics).map { t -> WikiProposal.Item in
            let titles = t.fragmentIds.compactMap { byId[$0] }.map { "「\(CatalogSorter.title($0, blocked: blockedSet))」" }
            let shown = titles.prefix(5).joined(separator: "、") + (titles.count > 5 ? " 等" : "")
            return WikiProposal.Item(change: .direction(.init(path: t.path, title: t.title, hook: t.group ? "" : hooks[t.path] ?? "", kind: t.kind,
                                                              aliases: t.aliases, action: t.existing || t.group ? .update : .newPage,
                                                              reason: t.reason + (titles.isEmpty ? "" : " · \(titles.count) 条碎片：\(shown)"),
                                                              clues: t.fragmentIds, mode: .daily, group: t.group ? true : nil,
                                                              basis: t.basis.isEmpty ? nil : t.basis)))
        }
        let updates = items.filter { $0.change.direction?.action == .update }.count
        let basis = items.compactMap { $0.change.direction?.basis }
        let fromA4 = basis.filter { $0.contains { $0.hasPrefix("A4") } }.count
        let due = basis.filter { $0.contains { $0.contains(WikiPage.validUntilKey) } }.count
        await log("自动提方向（" + (job.sorter == .code ? "代码分拣：对 wiki 索引字面比对 + 按 subject 聚 + A4 话题连续出现，没调模型" : "模型分拣") + "）："
            + "更新已有页 \(updates) 个 · 开新页 \(items.count - updates) 个"
            + (fromA4 > 0 ? " · 其中来自 A4 时间轴 \(fromA4) 个" : "") + (due > 0 ? " · 到期复核 \(due) 个" : "")
            + (hasFresh ? "" : " · 没有待整理的碎片")
            + ((source?.backlog ?? 0) > 0 ? " · A4 还有 \(source!.backlog) 天新写成的日记录下次再看" : "")
            + (grouped.unclear > 0 ? " · 碰上不止一页、拿不准的 \(grouped.unclear) 条留着" : ""))
        if !hasFresh, items.isEmpty, report.failures.isEmpty, report.blocked == nil { report.skipped = "没有待整理的碎片，时间轴和到期也没有要提的" }
        return (Array(items), max(0, fresh.count - job.maxTopics))
    }

    /// 分拣（自动方向、现在整理共用）：代码基线零模型；模型用 C3 所选模型、算写入预算，判单条就够的直接打标留池。
    /// nil = 这轮没分出来（被拦 / 校验两次不过 / 停了），原因记进报告和日志，不提方向
    /// fingerprinted = 自动那次：输入和上次交付完的一样就不再付费；「现在整理」是她主动要的，不读也不记
    private func sort(_ pool: [CatalogFragment], snapshot: WikiInjectionSnapshot, blocked: [String], timeline: [CatalogTimeline.Day] = [],
                      drafts: CatalogDrafts, now: Date, fingerprinted: Bool, report: inout CatalogRunReport) async -> CatalogSorter.Grouped? {
        guard job.sorter == .model else {
            let user = job.names.user
            return await Task.detached(priority: .utility) { CatalogSorter.group(pool, pages: snapshot.pages, blocked: blocked, user: user) }.value
        }
        let wiki = job.wiki
        let (names, model) = (job.names, job.modelName)
        sortFingerprint = nil
        if fingerprinted {
            let same = await Task.detached(priority: .utility) {
                CatalogModelSorter.fingerprint(pool, pages: snapshot.pages, timeline: timeline, names: names, model: model) == CatalogModelSorter.lastFingerprint(wiki)
            }.value
            if same {
                await log("模型分拣：碎片、wiki 索引、模型、提示词和上次交付完的那次完全一样，跳过，不再付费")
                return CatalogSorter.Grouped(topics: [], unclear: 0)
            }
        }
        onProgress?("分拣", 0)
        do {
            guard let sorted = try await CatalogModelSorter.run(pool, pages: snapshot.pages, timeline: timeline, names: job.names, caller: job.caller,
                                                               drafts: drafts, cancel: cancelToken, run: run) else {
                report.blocked = "写入预算 / 预算闸"
                await log("模型分拣被拦：写入预算 / 预算闸，或模型没回；这轮不提方向", ok: false)
                return nil
            }
            if !sorted.single.isEmpty {
                do {
                    try await CatalogMaterial.markSingle(sorted.single, container: job.container, now: now)
                    report.single += sorted.single.count
                    NotificationCenter.default.post(name: .memoryDidChange, object: nil)
                } catch {
                    await log("模型分拣判单条就够的没标上：\(error.localizedDescription)", ok: false)
                }
            }
            var after = pool
            for i in after.indices where sorted.single.contains(after[i].id) { after[i].organizedAt = now }
            let marked = after
            if fingerprinted {
                sortFingerprint = await Task.detached(priority: .utility) {
                    CatalogModelSorter.fingerprint(marked, pages: snapshot.pages, timeline: timeline, names: names, model: model)
                }.value
            }
            await log("模型分拣：分出 \(sorted.grouped.topics.count) 组 · 单条就够 \(sorted.single.count) 条 · 暂存或新页不到 3 条 \(sorted.waiting) 条"
                + (sorted.grouped.timeline.isEmpty ? "" : " · 时间轴提开新页 \(sorted.grouped.timeline.count) 个"))
            return sorted.grouped
        } catch is CancellationError {
            report.cancelled = true
            return nil
        } catch {
            report.failures.append("模型分拣：\(error.localizedDescription)")
            await log("模型分拣没过：\(error.localizedDescription)；这轮不提方向", ok: false)
            return nil
        }
    }

    private func rememberSort() async {
        let wiki = job.wiki
        if let seen = timelineSeen {
            timelineSeen = nil
            await Task.detached(priority: .utility) { try? CatalogDiscoveryState.update(wiki) { $0.consumed.merge(seen) { $1 } } }.value
        }
        guard let fingerprint = sortFingerprint else { return }
        sortFingerprint = nil
        await Task.detached(priority: .utility) { CatalogModelSorter.remember(fingerprint, wiki: wiki) }.value
    }

    // MARK: 每天自动：分拣提方向（第一批），批了才搜、写（第二批）

    func daily(now: Date = Date()) async -> CatalogRunReport {
        await cancellable { await self.dailyCancellable(now: now) }
    }

    private func dailyCancellable(now: Date) async -> CatalogRunReport {
        beginRun("每天自动整理", kind: "自动提方向", now: now)
        var report = CatalogRunReport()
        let wiki = job.wiki
        await Task.detached(priority: .utility) {
            let store = WikiProposalStore(wiki: wiki)
            if (try? CatalogDiscoveryState.rememberHandled(store)) != nil { store.purgeFinished(now: now) }
            CatalogDrafts.prune(wiki, now: now)
        }.value
        let drafts = CatalogDrafts(wiki: wiki, now: now)
        var (items, rest) = await discover(drafts: drafts, now: now, report: &report)
        if report.blocked == nil, !isCancelled {
            items += await regroup(drafts: drafts, report: &report)
        }
        if isCancelled { report.cancelled = true }
        var saved = items.isEmpty
        if !items.isEmpty, !report.cancelled, await save(WikiProposal(origin: .scheduled, createdAt: now, items: items)) {
            report.proposals = 1
            report.items = items.count
            report.skipped = nil
            saved = true
        }
        if saved, !report.cancelled { await rememberSort() }
        if !report.cancelled { await checkHealth(now: now) }
        if report.skipped != nil { return await finishRun(report) }
        await log("定时整理：" + report.summary + (rest > 0 ? " · 还有 \(rest) 个方向下次再提" : ""), ok: report.failures.isEmpty)
        return await finishRun(report)
    }

    /// 巡检后的纯代码 wiki 体检：只报告，不改页、不调模型；目录漂移照现有做法由代码重建索引，报告记重建前的差异
    private func checkHealth(now: Date) async {
        let wiki = job.wiki
        /// 检查、重建、存结果拿着审批锁一起做：不和批提案写页 / 重建索引交错
        let checked: (WikiHealth, String?)
        do {
            checked = try await WikiProposalReview.exclusive(WikiProposalStore(wiki: wiki)) {
                await Task.detached(priority: .utility) { () -> (WikiHealth, String?) in
                    var health = WikiHealth.check(wiki, now: now)
                    if !health.drift.isEmpty {
                        do { try wiki.rebuildAllIndexes() } catch { health.rebuildError = error.localizedDescription }
                    }
                    do {
                        try health.save(wiki)
                        return (health, nil)
                    } catch {
                        return (health, error.localizedDescription)
                    }
                }.value
            }
        } catch {
            MemoryWriteLog.record(writer: .c3, profileId: job.profileId, ok: false, note: "wiki 体检没跑成：\(error.localizedDescription)", model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: job.profileId))
            return
        }
        let (health, saveError) = checked
        let anchor = run?.section("wiki 体检（纯代码，只报告）", body: health.details)
        await run?.flush()
        MemoryWriteLog.record(writer: .c3, profileId: job.profileId, ok: health.rebuildError == nil && saveError == nil,
                              note: "wiki 体检：" + health.summary + (health.rebuildError.map { " · 索引没重建成：\($0)" } ?? "")
                                + (saveError.map { " · 结果没存上：\($0)" } ?? ""),
                              model: "", run: run?.link(anchor: anchor), memoryRoot: FileLibraryStore.memoryRoot(profileId: job.profileId))
    }

    // MARK: 批了的方向：这才搜原料、读页、写，写完交正文提案

    func directions(_ proposalId: String, itemIds: Set<String>? = nil, now: Date = Date()) async -> CatalogRunReport {
        await cancellable { await self.directionsCancellable(proposalId, itemIds: itemIds, now: now) }
    }

    private func directionsCancellable(_ proposalId: String, itemIds: Set<String>?, now: Date) async -> CatalogRunReport {
        var report = CatalogRunReport()
        let store = WikiProposalStore(wiki: job.wiki)
        let source: WikiProposal
        let claimed: [WikiProposal.Item]
        do {
            (source, claimed) = try await WikiProposalReview.claimDirections(proposalId, itemIds: itemIds, store: store, now: now)
        } catch {
            report.failures.append("方向没读到：\(error.localizedDescription)")
            MemoryWriteLog.record(writer: .c3, profileId: job.profileId, ok: false, note: "批了的方向没读到：\(error.localizedDescription)", model: job.modelName, memoryRoot: FileLibraryStore.memoryRoot(profileId: job.profileId))
            return report
        }
        guard !claimed.isEmpty else {
            report.skipped = "没有要执行的方向"
            return report
        }
        beginRun(source.title ?? "批了的方向", kind: "执行方向", now: now)
        let snapshot = await CatalogMaterial.snapshot(profileId: job.profileId, container: job.container, embedder: job.embedder, cancel: cancelToken)
        let visible = await CatalogMaterial.conversationIds(profileId: job.profileId, source: SwiftDataConversationSource(container: job.container))
        let drafts = CatalogDrafts(wiki: job.wiki, now: now)
        for item in claimed {
            guard let d = item.change.direction else { continue }
            let ref = WikiProposal.DirectionRef(proposalId: source.id, itemId: item.id)
            var outcome: (result: String, proposalId: String?) = ("停了，没执行", nil)
            let failures = report.failures.count, blocked = report.blocked
            if isCancelled {
                report.cancelled = true
            } else {
                outcome = await execute(d, ref: ref, origin: source.origin, snapshot: snapshot, visible: visible, drafts: drafts,
                                        now: now, report: &report)
            }
            await log("方向「\(d.title)」：\(outcome.result)", ok: report.failures.count == failures && report.blocked == blocked)
            do {
                try await WikiProposalReview.recordDirection(source.id, itemId: item.id, result: outcome.result,
                                                             contentProposalId: outcome.proposalId, store: store)
            } catch {
                await log("方向「\(d.title)」的结果没记上：\(error.localizedDescription)", ok: false)
            }
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return await finishRun(report)
    }

    /// 一条批了的方向：只给还在池里的线索；日常 = 一次写手，agent = 自己查（最多 N 轮）
    private func execute(_ d: WikiProposal.Direction, ref: WikiProposal.DirectionRef, origin: WikiProposal.Origin,
                         snapshot: [CatalogFragment], visible: Set<String>, drafts: CatalogDrafts, now: Date,
                         report: inout CatalogRunReport) async -> (result: String, proposalId: String?) {
        let wiki = job.wiki
        let path = d.path
        let group = d.group == true
        let existing = await Task.detached(priority: .utility) { !group && wiki.pageExists(path) }.value
        let clues = snapshot.filter { d.clues.contains($0.id) && $0.organizedPage == nil && !$0.rejected }
        let topic = CatalogSorter.Topic(path: d.path, title: d.title, kind: d.kind, aliases: d.aliases, existing: existing,
                                        fragmentIds: clues.map(\.id), hook: d.hook, reason: d.reason, group: group)
        onProgress?(d.title, 0)
        switch d.mode {
        case .agent:
            var a = agentJob(d.title, snapshot: snapshot, conversationIds: visible)
            a.aliases = d.aliases
            a.fragmentIds = topic.fragmentIds
            a.path = group ? nil : d.path
            a.hint = (group ? Self.groupHint(d.path) : existing ? "已有页：\(d.path)" : "新主题 · 建议路径：\(d.path)") + "\n为什么提这个方向：\(d.reason)"
                + (d.hook.isEmpty ? "" : "\n定好的钩子：\(d.hook)（新开页、改钩子都用这一句）")
            let r = await agentTopic(a, origin: origin, directionRef: ref, request: nil, hook: d.hook, now: now, report: &report)
            return (r.result, r.proposalId)
        case .seed:
            return ("种子目录项由种子任务自己接着写", nil)
        case .daily:
            let material = await CatalogWriter.material(topic, fragments: clues, floorPrompt: job.floorPrompt, wiki: wiki,
                                                        memoryRoot: job.memoryRoot, now: now, snapshot: snapshot,
                                                        conversationIds: visible, embedder: job.embedder,
                                                        originalSearch: originalSearch(scope: visible), cancel: cancelToken)
            do {
                guard let parsed = try await CatalogWriter.write(material, names: job.names, wiki: wiki, caller: job.caller, drafts: drafts,
                                                                 cancel: cancelToken, run: run,
                                                                 trim: job.seedModel.hasPrefix("local:") ? CatalogLocalTrim.apply : nil) else {
                    report.blocked = "写入预算 / 预算闸"
                    return ("被拦：写入预算 / 预算闸，或模型没回，没写", nil)
                }
                let single = parsed.single.filter(topic.fragmentIds.contains)
                var items = parsed.items
                let thin = group ? CatalogItems.dropThinNewPages(&items, among: Set(topic.fragmentIds), threshold: CatalogSorter.newPageThreshold) : []
                if !thin.isEmpty { run?.section("写手 · \(d.title) · 新开页不到 \(CatalogSorter.newPageThreshold) 条", body: thin.joined(separator: "\n")) }
                if !group { await applyHook(&items, hook: d.hook, path: d.path) }
                var final = parsed
                final.items = items
                final.single = single
                let anchor = run.map { CatalogDiagnostics.record(final, sources: material.sources, final: true, title: "写手 · \(d.title)", run: $0) }
                let delivered = await deliver(items, single: single, title: d.title, origin: origin, incomplete: false,
                                              directionRef: ref, request: nil, reason: parsed.reason, unapplied: parsed.unapplied,
                                              revision: parsed.revision, diagnostics: anchor, now: now, report: &report)
                return (([delivered.result] + thin).joined(separator: " · ") + (parsed.dropped > 0 ? " · 扔了 \(parsed.dropped) 处（没出处 / 不合格）" : ""),
                        delivered.proposalId)
            } catch is CancellationError {
                report.cancelled = true
                return ("停了，没交正文", nil)
            } catch {
                report.failures.append("\(d.title)：\(error.localizedDescription)")
                return ("出错：\(error.localizedDescription)", nil)
            }
        }
    }

    /// 方向里定好的钩子落到条目上（读这页现在的样子和版本，改钩子照样等批）
    private func applyHook(_ items: inout [WikiProposal.Item], hook: String, path: String) async {
        guard !hook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wiki = job.wiki
        let (page, version) = await Task.detached(priority: .utility) { (wiki.read(path), wiki.version(of: path)) }.value
        CatalogItems.applyHook(&items, hook: hook, path: path, page: page, version: version)
    }

    /// 写模块的结果：有条目 → 一份正文提案（第二批，批了才落页、才打标）；单条就够直接打标留池；
    /// 什么都没有不造假提案、不动整理标记，只说原因
    private func deliver(_ items: [WikiProposal.Item], single: [UUID], title: String, origin: WikiProposal.Origin, incomplete: Bool,
                         directionRef: WikiProposal.DirectionRef?, request: WikiProposal.Request?, reason: String?,
                         unapplied: [WikiProposal.Unapplied] = [], revision: String? = nil, diagnostics: String? = nil, now: Date,
                         report: inout CatalogRunReport) async -> (result: String, proposalId: String?) {
        var parts: [String] = []
        var proposalId: String?
        if !items.isEmpty || !unapplied.isEmpty {
            var p = WikiProposal(origin: origin, createdAt: now, title: title, incomplete: incomplete, items: items,
                                 directionRef: directionRef, request: request, run: run?.link(anchor: diagnostics))
            p.unapplied = unapplied.isEmpty ? nil : unapplied
            p.revision = revision
            if await save(p) {
                proposalId = p.id
                report.proposals += 1
                report.items += items.count
                if incomplete { report.incomplete += 1 }
                parts.append("交了 \(items.count) 条正文等批" + (incomplete ? "（没整理完）" : "")
                    + (unapplied.isEmpty ? "" : " · \(unapplied.count) 处没收进页，留在提案上给你看"))
            } else {
                report.failures.append("\(title)：正文提案没存成")
                parts.append("正文提案没存成")
            }
        }
        if !single.isEmpty {
            do {
                try await CatalogMaterial.markSingle(single, container: job.container, now: now)
                report.single += single.count
                parts.append("单条就够 \(single.count) 条，留在碎片池")
                NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            } catch {
                parts.append("单条就够的没标上：\(error.localizedDescription)")
            }
        }
        if parts.isEmpty { parts.append("没有可写的材料" + (reason.map { "：\($0)" } ?? "")) }
        return (parts.joined(separator: " · "), proposalId)
    }

    // MARK: 种子：一个 agent 任务——全读原料 → 交目录等批（暂停）→ 批了同一任务逐页写 → 正文再批。不算日常写入预算

    /// 两个入口（CC 记忆 / 人设）都走这里：先清旧种子（只第一次有），再开一个新任务
    func seed(entry: CatalogSeedEntry = .cc, now: Date = Date()) async -> CatalogRunReport {
        await cancellable { await self.seedCancellable(entry: entry, now: now) }
    }

    /// 批了 / 驳回了目录、或她点了「继续」：从 checkpoint 接着跑同一个任务（不重读原料、不换材料；写正文每个获批项单开一段对话，原料取 read 回执）
    func resumeSeed(_ taskId: String, now: Date = Date()) async -> CatalogRunReport {
        await cancellable { await self.resumeSeedCancellable(taskId, now: now) }
    }

    private func seedCancellable(entry: CatalogSeedEntry, now: Date) async -> CatalogRunReport {
        beginRun("种子 · \(entry.label)", kind: "种子（要点卡 → 代码聚合 → 目录 → 逐页写）", now: now)
        var report = CatalogRunReport()
        let wiki = job.wiki
        let root = job.memoryRoot
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        await log("种子（\(entry.label)）：开始")
        if let why = job.seedBlocked {
            report.failures.append("C3 选的模型现在用不了（\(why)），种子不换别的模型，没开始")
            await log(report.failures[0], ok: false)
            return await finishRun(report)
        }
        if let open = await Task.detached(priority: .utility, operation: { tasks.open(proposals: WikiProposalStore(wiki: wiki)) }).value,
           open.task.isLegacyLayout {
            report.notes += await abandonSeed(open.task.id, now: now, reason: CatalogSeedTask.legacyLayoutNote).notes
        }
        if let open = await Task.detached(priority: .utility, operation: { tasks.open(proposals: WikiProposalStore(wiki: wiki)) }).value {
            report.skipped = "还有一个种子任务没完成（\(open.status.text)），先在审计台 › wiki › 整理提案批完或放弃再开新的"
            await log(report.summary)
            return await finishRun(report)
        }
        if isCancelled {
            report.cancelled = true
            return await finishRun(report)
        }
        do {
            if let cleaned = try await CatalogSeedCleanup.runIfNeeded(memoryRoot: root, wiki: wiki, now: now) {
                report.notes.append(cleaned.summary)
                await log(cleaned.summary)
            }
        } catch {
            let message = error is CatalogSeedCleanup.CleanupError
                ? "清旧种子没成：\(error.localizedDescription)"
                : "清旧种子没成，一个都没删：\(error.localizedDescription)"
            report.failures.append(message)
            await log(message, ok: false)
            return await finishRun(report)
        }
        let base = job.floorBase
        let materials: CatalogSeedMaterials
        do {
            materials = try await Task.detached(priority: .utility) { try CatalogSeedMaterials.gather(floorBase: base, memoryRoot: root, wiki: wiki) }.value
        } catch {
            report.failures.append("原料没读到：\(error.localizedDescription)")
            await log(report.failures[0], ok: false)
            return await finishRun(report)
        }
        if !materials.skipped.isEmpty { await log("种子：没读的 · " + materials.skipped.joined(separator: "；")) }
        guard !materials.items.isEmpty else {
            report.skipped = "没有可用的原料（Prompt、CC、wiki 都是空的）"
            await log(report.summary)
            return await finishRun(report)
        }
        guard let run, !isCancelled else {
            report.cancelled = true
            return await finishRun(report)
        }
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: job.profileId, entry: entry, modelName: job.modelName,
                                   modelKey: job.seedModel, createdAt: now, run: run.link())
        task.skipped = materials.skipped
        // 原料全文先落快照（写不成不发请求），清单和版本从快照来；再存任务；之后才问模型
        let snapshot: CatalogSeedMaterials.Snapshot
        switch await writeSnapshot(materials, task: &task, tasks: tasks) {
        case .success(let s): snapshot = s
        case .failure(let failure):
            report.failures.append(failure.message)
            await log(failure.message, ok: false)
            return await finishRun(report)
        }
        let first = task
        do {
            try await Task.detached(priority: .utility) { try tasks.save(first) }.value
        } catch {
            report.failures.append("种子任务没存成，没开始问模型：\(error.localizedDescription)")
            await log(report.failures[0], ok: false)
            return await finishRun(report)
        }
        let counts = Dictionary(grouping: materials.items, by: \.layer).mapValues(\.count)
        await log("种子（\(entry.label)）：原料 \(materials.items.count) 份（Prompt \(counts["Prompt"] ?? 0) · CC \(counts["CC"] ?? 0) · wiki \(counts["wiki"] ?? 0)），"
                  + Self.batchNote(materials, entry: entry))
        return await runSeedTask(task, snapshot: snapshot, control: nil, now: now, report: &report)
    }

    struct SnapshotWriteError: Error {
        let message: String
    }

    /// 原料快照写进 `.proposals/<任务>/materials/`，清单 / 版本 / 出卡进度一次填齐
    private func writeSnapshot(_ materials: CatalogSeedMaterials, task: inout CatalogSeedTask, tasks: CatalogSeedTaskStore) async -> Result<CatalogSeedMaterials.Snapshot, SnapshotWriteError> {
        let id = task.id
        let written: CatalogSeedMaterials.Snapshot
        do {
            written = try await Task.detached(priority: .utility) { try tasks.writeSnapshot(materials, id: id) }.value
        } catch {
            return .failure(SnapshotWriteError(message: "原料快照没存成，没开始问模型：\(error.localizedDescription)"))
        }
        task.materials = written.materials
        task.read = written.read
        task.carded = task.carded ?? [:]
        task.notes = task.notes ?? SeedNoteProgress()
        return .success(written)
    }

    /// 日志里那一句：可出卡几份、分几批
    private static func batchNote(_ materials: CatalogSeedMaterials, entry: CatalogSeedEntry) -> String {
        let cardable = materials.items.filter { SeedNoteBatcher.cardable($0, entry: entry) }
        let batches = SeedNoteBatcher.batches(cardable, limit: CatalogSettings.seedBatchChars(), carded: [:], entry: entry).count
        return "可出卡 \(cardable.count) 份，分 \(batches) 批出要点卡，再由代码聚合成目录"
    }

    /// 重启 / 续跑前先对账：目录已经存了就认；正文提案存了、目录上还没记的补记上（都按任务文件夹里实际存下的）
    private func reconcileSeed(_ task: inout CatalogSeedTask) async -> WikiProposal? {
        let store = WikiProposalStore(wiki: job.wiki)
        let id = task.id
        let (outline, contents) = await Task.detached(priority: .utility) { () -> (WikiProposal?, [WikiProposal]) in
            (store.load(id), store.list().filter { $0.seedTask == id && $0.directionRef?.proposalId == id })
        }.value
        guard let outline else { return nil }
        task.outlineSaved = true
        for item in CatalogSeedTask.unwritten(outline) {
            guard let content = contents.first(where: { $0.directionRef?.itemId == item.id }) else { continue }
            do {
                try await WikiProposalReview.recordDirection(id, itemId: item.id, result: "交了 \(content.items.count) 条正文等批",
                                                             contentProposalId: content.id, store: store)
                await log("种子：对上了上次存下、还没记到目录上的正文「\(content.title ?? "")」")
            } catch {
                await log("种子：对账没记上：\(error.localizedDescription)", ok: false)
            }
        }
        let refreshed = await Task.detached(priority: .utility) { store.load(id) }.value
        // 那一页已经交上了（回退交上一稿、崩溃前存下的正文刚对上）：单页对话不留，随结算一起存
        if let current = task.page?.item, !CatalogSeedTask.unwritten(refreshed).contains(where: { $0.id == current }) { task.page = nil }
        return refreshed
    }

    private func resumeSeedCancellable(_ taskId: String, now: Date) async -> CatalogRunReport {
        var report = CatalogRunReport()
        let wiki = job.wiki
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        guard var task = await Task.detached(priority: .utility, operation: { tasks.load(taskId) }).value,
              task.state != .complete, task.state != .abandoned, task.state != .ended else {
            report.skipped = "这个种子任务不在了，或已经结束"
            return report
        }
        if task.isLegacyLayout { return await abandonSeed(taskId, now: now, reason: CatalogSeedTask.legacyLayoutNote) }
        // 目录还有待批、这一下也没批出要写的页（逐项驳回时）：不续记录、不记日志，等批完那一下再结算（走查：每驳回一项多一行「写好了」）
        if task.outlineSaved,
           let saved = await Task.detached(priority: .utility, operation: { WikiProposalStore(wiki: wiki).load(taskId) }).value,
           saved.pendingCount > 0, CatalogSeedTask.unwritten(saved).isEmpty {
            report.skipped = "目录还有 \(saved.pendingCount) 项待批"
            return report
        }
        run = CatalogRunRecord(wiki: wiki, continuing: task.run, topic: "种子 · \(task.entry.label)", now: now)
        let outline = await reconcileSeed(&task)
        let left = CatalogSeedTask.unwritten(outline)
        if task.outlineSaved, left.isEmpty {
            await settleSeed(&task, outline: outline, normal: !isCancelled, now: now, report: &report)
            return await finishRun(report)
        }
        // 三问答完时没有能用的模型：第一次真跑才绑模型
        if task.modelKey == nil, job.seedBlocked == nil {
            task.modelKey = job.seedModel
            task.modelName = job.modelName
        }
        guard task.modelKey == job.seedModel, job.seedBlocked == nil else {
            let why = job.seedBlocked.map { "C3 选的模型现在用不了（\($0)）" } ?? "这个种子任务开始时用的是「\(task.modelName)」，现在 C3 选的不是同一个模型"
            report.failures.append(why + "；种子不换模型，换回去再继续")
            await log(report.failures[0], ok: false)
            return await finishRun(report)
        }
        let root = job.memoryRoot
        let day = CatalogSurvey.day(task.createdAt)
        let loaded = await Task.detached(priority: .utility) { () -> Result<CatalogSeedMaterials.Snapshot, Error> in
            Result { try tasks.loadSnapshot(taskId) }
        }.value
        var snapshot = try? loaded.get()
        // 还没开工（清单 / 版本都空）：上次快照写成了、任务没来得及存（或那次没存成）→ 从快照恢复清单和版本，先存任务再问模型
        let initialized = !task.materials.isEmpty || !task.read.isEmpty
        if !initialized, let recovered = snapshot {
            task.materials = recovered.materials
            task.read = recovered.read
            task.carded = task.carded ?? [:]
            task.notes = task.notes ?? SeedNoteProgress()
            task.state = .reading
            task.note = nil
            task.layout = CatalogSeedTask.currentLayout
            let first = task
            do {
                try await Task.detached(priority: .utility) { try tasks.save(first) }.value
            } catch {
                report.failures.append("种子任务没存成，没开始问模型：\(error.localizedDescription)")
                await log(report.failures[0], ok: false)
                return await finishRun(report)
            }
            await log("种子：上次原料快照写成了、任务没存上，从快照恢复了原料清单（\(recovered.entries.count) 份）再接着跑")
        }
        // 三问：答案存好以后头一回真跑，这才定原料（答案 + wiki 只看）、写快照，先存任务再问模型
        let fresh = task.entry == .survey && snapshot == nil && !initialized
        if fresh {
            let answers = task.answers ?? []
            let materials = await Task.detached(priority: .utility) { CatalogSurvey.materials(answers, day: day, memoryRoot: root, wiki: wiki) }.value
            task.skipped = materials.skipped
            switch await writeSnapshot(materials, task: &task, tasks: tasks) {
            case .success(let s): snapshot = s
            case .failure(let failure):
                report.failures.append(failure.message)
                await log(failure.message, ok: false)
                return await finishRun(report)
            }
            task.state = .reading
            task.note = nil
            task.layout = CatalogSeedTask.currentLayout
            let first = task
            do {
                try await Task.detached(priority: .utility) { try tasks.save(first) }.value
            } catch {
                report.failures.append("种子任务没存成，没开始问模型：\(error.localizedDescription)")
                await log(report.failures[0], ok: false)
                return await finishRun(report)
            }
            let answered = materials.items.filter { $0.layer == CatalogSurvey.layer }.count
            await log("种子（\(task.entry.label)）：答案 \(answered) 条 · wiki \(materials.items.count - answered) 份（只看、不当出处），" + Self.batchNote(materials, entry: .survey))
        }
        guard let snapshot else {
            var why = ""
            if case .failure(let error as SafeWiki.PathError) = loaded { why = "（\(error.localizedDescription)）" }
            report.failures.append("这个种子任务的原料快照不在了（或被动过）\(why)，续不了；可以放弃这次种子再重新播种")
            await log(report.failures[0], ok: false)
            return await finishRun(report)
        }
        // 已开工的：快照 manifest 必须和任务记的清单 / 版本一致，不一致不接着跑（不静默少读、不换原料）
        if initialized, let mismatch = task.snapshotMismatch(snapshot) {
            report.failures.append("这个种子任务的原料快照和任务记的原料清单对不上（\(mismatch)），续不了：没有再问模型。请放弃这个种子任务再重新播种")
            await log(report.failures[0], ok: false)
            return await finishRun(report)
        }
        let control = task.outlineSaved ? outline.map { CatalogSeedPrompts.control($0, names: job.names) } : nil
        if !fresh {
            await log(task.outlineSaved ? "种子：接着同一个任务写 \(left.count) 页（不重读原料）"
                      : "种子：接着同一个任务出目录（还有 \(task.uncarded.count) 份没出要点卡）")
        }
        return await runSeedTask(task, snapshot: snapshot, control: control, now: now, report: &report)
    }

    private func runSeedTask(_ task: CatalogSeedTask, snapshot: CatalogSeedMaterials.Snapshot, control: String?, now: Date,
                             report: inout CatalogRunReport) async -> CatalogRunReport {
        guard let run else { return report }
        let agent = CatalogAgent(deps: job.seedDeps ?? job.agentDeps, cancel: cancelToken)
        self.agent = agent
        agent.onRound = { [weak self] round in self?.onProgress?("种子", round) }
        if isCancelled { agent.cancel() }
        let outcome = await agent.runSeed(.init(task: task, snapshot: snapshot, wiki: job.wiki, names: job.names, run: run, control: control, now: now))
        self.agent = nil
        var task = outcome.task
        report.proposals += outcome.pages.count
        report.items += outcome.items
        switch outcome.stop {
        case .outlineSubmitted:
            report.proposals += 1
            report.items += outcome.outlineItems
            await log("种子：目录交了 \(outcome.outlineItems) 项，等你在审计台 › wiki › 整理提案批（批了才逐页写）")
        case .paused:
            await log("种子：获批的页都交了正文" + (outcome.pages.isEmpty ? "" : "（这次 \(outcome.pages.count) 页 · \(outcome.items) 条）"))
        case .emptyOutline(let why):
            report.failures.append("目录是空的：\(why)，不记完成")
            await log(report.failures.last ?? "", ok: false)
        case .cancelled:
            report.cancelled = true
            await log("种子：停了（没完成，可以继续）")
        case .blocked(let why):
            report.blocked = why
            await log("种子：被拦（\(why)），没完成", ok: false)
        case .failed(let note):
            report.failures.append(note)
            await log("种子：" + note, ok: false)
        }
        if !outcome.persisted { report.failures.append("种子任务快照没存成，不记完成") }
        let wiki = job.wiki
        let taskId = task.id
        let outline = await Task.detached(priority: .utility) { WikiProposalStore(wiki: wiki).load(taskId) }.value
        await settleSeed(&task, outline: outline, normal: outcome.stop.isNormal && outcome.persisted && !isCancelled, now: now, report: &report)
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
        return await finishRun(report)
    }

    /// 完成只按整份目录算：没有待批、至少一页获批、获批的页都成功交了正文提案（正文没批不拦），
    /// 而且这次是正常停下、没被停、该存的都存成了。先把完成写进任务快照，存成了才写完成标记；
    /// 写标记前后点了停 = 标记恢复原样、快照退回等批。目录全驳回 = 结束但不完成
    private func settleSeed(_ task: inout CatalogSeedTask, outline: WikiProposal?, normal: Bool, now: Date, report: inout CatalogRunReport) async {
        let wiki = job.wiki
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        func save(_ snapshot: CatalogSeedTask) async -> Bool {
            do {
                try await Task.detached(priority: .utility) { try tasks.save(snapshot) }.value
                return true
            } catch {
                report.failures.append("种子任务快照没存成：\(error.localizedDescription)")
                return false
            }
        }
        guard normal else {
            _ = await save(task)
            return
        }
        if CatalogSeedTask.isComplete(outline) {
            var done = task
            done.state = .complete
            done.note = nil
            done.endedAt = now
            guard await save(done), !isCancelled else {
                if isCancelled {
                    report.cancelled = true
                    _ = await save(task)
                }
                return
            }
            if task.entry == .survey {
                task = done
                let pages = outline?.items.filter { $0.state == .approved }.count ?? 0
                report.notes.append("三问基础页：目录处理完，获批的 \(pages) 页都交了正文（正文批了才进 wiki）")
                await log(report.notes.last ?? "")
                return
            }
            let finish = finishSeed, id = task.id, cancel = cancelToken
            let previous = await Task.detached(priority: .utility) { CatalogSeed.stateData(wiki: wiki) }.value
            do {
                try await Task.detached(priority: .utility) {
                    try cancel.check()
                    try finish(wiki, now, id)
                }.value
                try cancelToken.check()
                task = done
                let pages = outline?.items.filter { $0.state == .approved }.count ?? 0
                report.notes.append("种子完成：整份目录处理完，获批的 \(pages) 页都交了正文（正文批了才进 wiki）")
                await log(report.notes.last ?? "")
            } catch {
                try? await Task.detached(priority: .utility) { try CatalogSeed.restoreState(wiki: wiki, data: previous) }.value
                if error is CancellationError || isCancelled {
                    report.cancelled = true
                    await log("种子：写完成标记时点了停，标记恢复原样，没记完成")
                } else {
                    report.failures.append("完成标记没写上：\(error.localizedDescription)")
                    await log(report.failures.last ?? "", ok: false)
                }
                _ = await save(task)
            }
            return
        }
        if task.outlineSaved, let outline, outline.pendingCount == 0, CatalogSeedTask.unwritten(outline).isEmpty {
            task.state = .ended
            task.note = "目录全部驳回，没有获批的页，不记完成"
            task.endedAt = now
            await log("种子：" + (task.note ?? ""), ok: false)
        }
        _ = await save(task)
    }

    /// 放弃：剩下待批的目录项驳回（目录项不带碎片，不伤碎片），任务记成放弃；已交的正文提案照常在审计台。
    /// reason = 代码替她作废（旧格式），记成这句话
    func abandonSeed(_ taskId: String, now: Date = Date(), reason: String? = nil) async -> CatalogRunReport {
        var report = CatalogRunReport()
        let wiki = job.wiki
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let store = WikiProposalStore(wiki: wiki)
        let (loaded, outline) = await Task.detached(priority: .utility) { (tasks.load(taskId), store.load(taskId)) }.value
        guard var task = loaded, task.state != .complete, task.state != .abandoned else {
            report.skipped = "这个种子任务不在了，或已经结束"
            return report
        }
        do {
            if let outline, outline.pendingCount > 0 {
                try await WikiProposalReview.reject(taskId, origin: .abandonedSeed, store: store,
                    profileId: job.profileId, context: ModelContext(job.container), now: now)
            }
            task.state = .abandoned
            task.note = reason ?? "放弃了"
            task.endedAt = now
            let snapshot = task
            try await Task.detached(priority: .utility) { try tasks.save(snapshot) }.value
            report.notes.append(reason ?? "放弃了这次种子（已交的正文提案还在审计台 › wiki › 整理提案）")
            MemoryWriteLog.record(writer: .c3, profileId: job.profileId, ok: true, note: "种子：" + (reason ?? "放弃了这次任务"), model: job.modelName,
                                  run: CatalogRunLink(path: task.run.path), memoryRoot: FileLibraryStore.memoryRoot(profileId: job.profileId))
        } catch {
            report.failures.append("没放弃成：\(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
        return report
    }

    /// 超过 30 行的层各提一次「分组调整」（她还没批的那层不再提）；进同一份定时提案
    private func regroup(drafts: CatalogDrafts, report: inout CatalogRunReport) async -> [WikiProposal.Item] {
        let wiki = job.wiki
        let layers = await Task.detached(priority: .utility) {
            let waiting = CatalogRegrouper.pendingLayers(WikiProposalStore(wiki: wiki))
            return wiki.overfullLayers().filter { !waiting.contains($0) }
        }.value
        var out: [WikiProposal.Item] = []
        for layer in layers {
            if isCancelled {
                report.cancelled = true
                break
            }
            onProgress?("分组：\(layer)", 0)
            do {
                guard let got = try await CatalogRegrouper.run(layer, wiki: wiki, names: job.names, caller: job.caller, drafts: drafts,
                                                               cancel: cancelToken, run: run) else {
                    report.blocked = "写入预算 / 预算闸"
                    await log("「\(layer)」超过 \(WikiStore.layerLimit) 行，没提分组：写入预算 / 预算闸拦下，或模型没回", ok: false)
                    break
                }
                out += got
                await log("「\(layer)」超过 \(WikiStore.layerLimit) 行：" + (got.isEmpty ? "模型没给出能用的分组" : "提了分组调整"))
            } catch is CancellationError {
                report.cancelled = true
                break
            } catch {
                report.failures.append("分组 \(layer)：\(error.localizedDescription)")
                await log("「\(layer)」分组没提成：\(error.localizedDescription)", ok: false)
            }
        }
        return out
    }

    // MARK: 手动

    /// 一个主题跑一个 agent，交一份正文提案；continues = false 是被拦 / 停了，后面的不跑
    private func agentTopic(_ agentJob: CatalogAgent.Job, origin: WikiProposal.Origin, directionRef: WikiProposal.DirectionRef?,
                            request: WikiProposal.Request?, hook: String = "", now: Date,
                            report: inout CatalogRunReport) async -> (continues: Bool, result: String, proposalId: String?) {
        let agent = CatalogAgent(deps: job.agentDeps, cancel: cancelToken)
        self.agent = agent
        agent.onRound = { [weak self] round in self?.onProgress?(agentJob.topic, round) }
        if isCancelled { agent.cancel() }
        let outcome = await agent.run(agentJob)
        self.agent = nil
        let head = "「\(agentJob.topic)」\(outcome.rounds) 轮 · 查回 \(outcome.searchedChars) 字正文 · 工具回执 \(outcome.toolChars) 字 · "
        switch outcome.stop {
        case .submitted:
            var items = outcome.items
            if let path = agentJob.path { await applyHook(&items, hook: hook, path: path) }
            let delivered = await deliver(items, single: outcome.single, title: agentJob.topic, origin: origin, incomplete: outcome.incomplete,
                                          directionRef: directionRef, request: request, reason: outcome.reason, unapplied: outcome.unapplied,
                                          revision: outcome.revision, diagnostics: outcome.diagnostics, now: now, report: &report)
            await log(head + (outcome.items.isEmpty ? "交了 0 条，不建提案" : "交了 \(outcome.items.count) 条" + (outcome.incomplete ? "（没整理完）" : ""))
                + (outcome.single.isEmpty ? "" : " · 单条就够 \(outcome.single.count) 条")
                + (outcome.dropped > 0 ? " · 扔了 \(outcome.dropped) 处" : ""))
            return (true, delivered.result, delivered.proposalId)
        case .gaveUp:
            await log(head + "到顶了也没交，不建提案", ok: false)
            return (true, "到顶了也没交，没出正文", nil)
        case .blocked(let why):
            report.blocked = why
            guard !outcome.items.isEmpty || !outcome.unapplied.isEmpty else {
                await log(head + "被拦（\(why)），停了", ok: false)
                return (false, "被拦：\(why)，没写", nil)
            }
            let delivered = await deliver(outcome.items, single: outcome.single, title: agentJob.topic, origin: origin, incomplete: true,
                                          directionRef: directionRef, request: request, reason: outcome.reason, unapplied: outcome.unapplied,
                                          revision: outcome.revision, diagnostics: outcome.diagnostics, now: now, report: &report)
            await log(head + "重写那轮被拦（\(why)），交了第一稿 \(outcome.items.count) 条，后面的停了", ok: false)
            return (false, delivered.result + " · 被拦：\(why)，后面的主题停了", delivered.proposalId)
        case .cancelled:
            report.cancelled = true
            await log(head + "她点了停")
            return (false, "停了，没交正文", nil)
        case .failed(let message):
            report.failures.append("\(agentJob.topic)：\(message)")
            await log(head + "出错：\(message)", ok: false)
            return (true, "出错：\(message)", nil)
        }
    }

    /// 分组方向给 agent 的话：在分组下归页 / 开页，改已有页前先读全文
    static func groupHint(_ path: String) -> String {
        "整理分组：\(path)（在 \(path)/ 下归到现有的页或开新页，不建「\(path)」这一页本身；改、追加已有页之前先把那页全文读一遍）"
    }

    private func originalSearch(scope: Set<String>) -> CatalogRetrieval.OriginalSearch {
        let pid = job.profileId
        let container = job.container
        return { terms, interval, cancel in
            await SearchService.catalogContent(terms: terms, profileId: pid, container: container, interval: interval, scope: scope, cancel: cancel)
        }
    }

    private func agentJob(_ topic: String, snapshot: [CatalogFragment], conversationIds: Set<String>) -> CatalogAgent.Job {
        CatalogAgent.Job(topic: topic, profileId: job.profileId, memoryRoot: job.memoryRoot, names: job.names, floorPrompt: job.floorPrompt,
                         snapshot: snapshot, modelName: job.modelName, maxRounds: job.maxRounds, run: run,
                         conversationIds: conversationIds, embedder: job.embedder, originalSearch: originalSearch(scope: conversationIds))
    }

    /// 「现在整理」（⧫G）：这句话本身就是方向授权——分拣列主题（同自动），每个主题一个 agent，不设主题上限，
    /// 每个主题一份正文提案（来源 = 手动），正文照样等她批
    func organizeNow(now: Date = Date()) async -> CatalogRunReport {
        await cancellable { await self.organizeNowCancellable(now: now) }
    }

    private func organizeNowCancellable(now: Date) async -> CatalogRunReport {
        beginRun("现在整理", kind: "列主题 + 逐主题 agent", now: now)
        var report = CatalogRunReport()
        let request = WikiProposal.Request(profileId: job.profileId, text: "现在整理")
        let wiki = job.wiki
        let pool = await CatalogMaterial.pending(profileId: job.profileId, container: job.container, wiki: wiki)
        guard pool.contains(where: { $0.organizedAt == nil }) else {
            report.skipped = "没有待整理的碎片"
            await log("没有待整理的碎片")
            return await finishRun(report)
        }
        let index = await Task.detached(priority: .utility) { WikiInjection.load(wiki) }.value
        guard let grouped = await sort(pool, snapshot: index, blocked: [job.names.user, job.names.char] + index.stopWords,
                                       drafts: CatalogDrafts(wiki: wiki, now: now), now: now, fingerprinted: false, report: &report) else {
            await log("现在整理：" + report.summary, ok: report.failures.isEmpty)
            return await finishRun(report)
        }
        await log("现在整理：" + (job.sorter == .code ? "代码分拣列出 \(grouped.topics.count) 个主题（没调模型）" : "模型分拣列出 \(grouped.topics.count) 个主题")
            + (grouped.unclear > 0 ? " · 碰上不止一页、拿不准的 \(grouped.unclear) 条留着" : ""))
        let snapshot = await CatalogMaterial.snapshot(profileId: job.profileId, container: job.container, embedder: job.embedder, cancel: cancelToken)
        guard !isCancelled else { report.cancelled = true; return await finishRun(report) }
        let visible = await CatalogMaterial.conversationIds(profileId: job.profileId, source: SwiftDataConversationSource(container: job.container))
        for topic in grouped.topics {
            if isCancelled {
                report.cancelled = true
                break
            }
            var a = agentJob(topic.title, snapshot: snapshot, conversationIds: visible)
            a.aliases = topic.aliases
            a.fragmentIds = topic.fragmentIds
            a.path = topic.group ? nil : topic.path
            a.hint = topic.group ? Self.groupHint(topic.path)
                : topic.existing ? "已有页：\(topic.path)" : "新主题 · " + (topic.kind.map { "类：\($0.rawValue) · " } ?? "") + "建议路径：\(topic.path)"
                + (topic.reason.isEmpty ? "" : "\n为什么列这个主题：\(topic.reason)")
            guard await agentTopic(a, origin: .manual, directionRef: nil, request: request, now: now, report: &report).continues else { break }
        }
        await log("现在整理：" + report.summary, ok: report.failures.isEmpty)
        return await finishRun(report)
    }

    /// 「人设改了，整理一次」：她手动发起，这句话本身就是方向授权（不监听人设自动重播）。一个 agent 对照现在的人设查 wiki，
    /// 改和人设矛盾、过时的页；来源 = 手动，正文照样等她批
    func personaChanged(now: Date = Date()) async -> CatalogRunReport {
        await cancellable { await self.personaChangedCancellable(now: now) }
    }

    static let personaRequest = "人设改了，整理一次"

    static func personaHint(_ names: MemoryExtractor.Names) -> String {
        "\(names.user)刚改过人设（上面的楼层提示词就是现在的人设）。先 list_wiki 看有哪些页，read_wiki 读和人设有关的页，"
            + "找出和现在的人设说法矛盾、已经过时的地方：「现在」按新人设改（人设里写了的写「详见人设」），需要时追加一条记录说明改过；"
            + "和人设没关系的页不动，没有要改的就交空并说明原因"
    }

    private func personaChangedCancellable(now: Date) async -> CatalogRunReport {
        beginRun(Self.personaRequest, kind: "人设变化 · 手动", now: now)
        var report = CatalogRunReport()
        let snapshot = await CatalogMaterial.snapshot(profileId: job.profileId, container: job.container, embedder: job.embedder, cancel: cancelToken)
        guard !isCancelled else { report.cancelled = true; return await finishRun(report) }
        let visible = await CatalogMaterial.conversationIds(profileId: job.profileId, source: SwiftDataConversationSource(container: job.container))
        let request = WikiProposal.Request(profileId: job.profileId, text: Self.personaRequest)
        var a = agentJob("人设变化", snapshot: snapshot, conversationIds: visible)
        a.hint = Self.personaHint(job.names)
        _ = await agentTopic(a, origin: .manual, directionRef: nil, request: request, now: now, report: &report)
        await log("\(Self.personaRequest)：" + report.summary, ok: report.failures.isEmpty)
        return await finishRun(report)
    }

    /// 「整理一个主题…」：这句话本身就是方向授权，一个 agent 跑这一个主题（不受 3 条门槛）；来源 = 点名主题，正文照样等她批
    func organizeTopic(_ topic: String, now: Date = Date()) async -> CatalogRunReport {
        await cancellable { await self.organizeTopicCancellable(topic, now: now) }
    }

    private func organizeTopicCancellable(_ topic: String, now: Date) async -> CatalogRunReport {
        beginRun(topic, kind: "整理一个主题", now: now)
        var report = CatalogRunReport()
        let snapshot = await CatalogMaterial.snapshot(profileId: job.profileId, container: job.container, embedder: job.embedder, cancel: cancelToken)
        guard !isCancelled else { report.cancelled = true; return await finishRun(report) }
        let visible = await CatalogMaterial.conversationIds(profileId: job.profileId, source: SwiftDataConversationSource(container: job.container))
        let request = WikiProposal.Request(profileId: job.profileId, text: "整理一个主题：\(topic)")
        _ = await agentTopic(agentJob(topic, snapshot: snapshot, conversationIds: visible), origin: .topic, directionRef: nil,
                             request: request, now: now, report: &report)
        return await finishRun(report)
    }

    private func cancellable(_ body: () async -> CatalogRunReport) async -> CatalogRunReport {
        let token = cancelToken
        return await withTaskCancellationHandler {
            await body()
        } onCancel: {
            token.cancel()
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }
}

// MARK: - 给审计台「整理提案」格的入口和状态（todo 10 的 UI 读它）

@MainActor
@Observable
final class CatalogRunner {
    static let shared = CatalogRunner()

    private(set) var isRunning = false
    private(set) var currentTopic: String?
    private(set) var round = 0
    /// 排在后面的
    private(set) var queued = 0
    private(set) var lastReport: CatalogRunReport?
    private(set) var lastFinishedAt: Date?

    @ObservationIgnored private weak var profileManager: ProfileManager?
    @ObservationIgnored private weak var providerManager: ProviderManager?
    @ObservationIgnored private weak var presetManager: PresetManager?
    @ObservationIgnored private var sessions: [CatalogSession] = []
    @ObservationIgnored private var seedRequests: [String: CatalogCancel] = [:]
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    /// 这次进程什么时候起的：早于它认领、没记结果的方向是上次中断的
    @ObservationIgnored private let launchedAt = Date()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func attach(profileManager: ProfileManager, providerManager: ProviderManager) {
        self.profileManager = profileManager
        self.providerManager = providerManager
        let ids = profileManager.profiles.map(\.id)
        let before = launchedAt
        Task {
            for id in ids {
                let store = await Task.detached(priority: .utility) { WikiProposalStore(wiki: WikiStore(profileId: id)) }.value
                do {
                    _ = try await WikiProposalReview.finishInterrupted(store: store, before: before,
                        profileId: id, context: ModelContext(profileManager.container))
                } catch {
                    CacheDiagLog.shared.log("📚 整理编目: 中断方向收尾失败 \(error.localizedDescription)")
                }
            }
        }
        #if os(macOS)
        guard clock == nil, !Self.isTesting else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                let wait = CatalogSchedule.nextBoundary(after: Date()).timeIntervalSinceNow + 5
                try? await Task.sleep(for: .seconds(max(wait, 60)))
                self?.dailyTick()
            }
        }
        #endif
    }

    func attach(presetManager: PresetManager) {
        self.presetManager = presetManager
    }

    /// 楼层完整底图：主线程从 Prompt 页同一份实例 / 楼层字段取一次，之后只读
    func floorBase(profile: Profile) -> CatalogFloorBase? {
        guard let presetManager else { return nil }
        return CatalogFloorBase.make(profile: profile, presets: presetManager.presets,
                                     names: EffectiveCharacterContext(profile: profile, defaults: defaults))
    }

    /// 写手 / agent 看的楼层提示：完整底图（不截断、带自建槽）；没接 PresetManager（只有测试）才退回旧五段
    func writerFloorPrompt(profile: Profile) -> String {
        floorBase(profile: profile)?.text ?? CatalogFloorPrompt.text(profile: profile, defaults: defaults)
    }

    /// 启动 / 回前台 / mac 到点喊一声：当前楼层今天还没管过就看要不要跑
    func dailyTick(now: Date = Date()) {
        guard !Self.isTesting, let pm = profileManager else { return }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("catalogDaily"); return }
        #endif
        let profile = pm.currentProfile
        let defaults = defaults
        Task {
            let exceeded = await Task.detached(priority: .utility) { WriteBudgetStore.exceeded() }.value
            switch CatalogSchedule.decide(profileId: profile.id, now: now, defaults: defaults, budgetExceeded: { exceeded }) {
            case nil:
                return
            case .skip(let why)?:
                MemoryWriteLog.record(writer: .c3, profileId: profile.id, ok: true, note: why, model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profile.id))
            case .run?:
                // c2c3-v2 第 7 段：同一次巡检里 A4 一天一条先拼完、落盘，再整理（拼不成也接着整理，A4 自己记状态）
                await SessionCloseoutTrigger.shared.timelineDaily(profile: profile)
                await start(profile: profile) { await $0.daily(now: now) }
            }
        }
    }

    /// 「现在整理」：C3 关着不出这个按钮，这里也不跑
    func organizeNow(profile: Profile) {
        guard MemoryWriterSettings.writes(.c3, defaults: defaults) else { return }
        Task { await start(profile: profile) { await $0.organizeNow() } }
    }

    /// 批了方向之后：这才去搜、写；同一条只执行一次（认领在锁里记开始时间）。
    /// 没跑成（C3 关着 / 楼层模型没准备好 / 排队时点了停）也把这几条记下原因，不留在「还没开始写」
    @discardableResult
    func runDirections(proposalId: String, itemIds: Set<String>, profile: Profile) -> Task<Void, Never> {
        let pid = profile.id
        guard MemoryWriterSettings.writes(.c3, defaults: defaults) else {
            return Task { await Self.close(proposalId, itemIds: itemIds, profileId: pid, result: "C3 关着，没执行") }
        }
        return Task {
            guard let job = await makeJob(profile: profile) else {
                await Self.close(proposalId, itemIds: itemIds, profileId: pid, result: "楼层或模型没准备好，没执行")
                return
            }
            await runDirections(job: job, proposalId: proposalId, itemIds: itemIds).value
        }
    }

    @discardableResult
    func runDirections(job: CatalogJob, proposalId: String, itemIds: Set<String>) -> Task<Void, Never> {
        Task {
            let ran = await start(job: job) { await $0.directions(proposalId, itemIds: itemIds) }
            if !ran {
                await Self.close(proposalId, itemIds: itemIds, profileId: job.profileId, wiki: job.wiki, result: "排队时点了停，没执行")
            }
        }
    }

    private static func close(_ proposalId: String, itemIds: Set<String>, profileId: String, wiki: WikiStore? = nil, result: String) async {
        let store = await Task.detached(priority: .utility) { WikiProposalStore(wiki: wiki ?? WikiStore(profileId: profileId)) }.value
        do {
            try await WikiProposalReview.closeDirections(proposalId, itemIds: itemIds, result: result, store: store)
            MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: false, note: "批了的方向没执行：\(result)", model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        } catch {
            MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: false, note: "批了的方向没执行，结果也没记上：\(error.localizedDescription)", model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    /// 「人设改了，整理一次」：C3 关着不跑
    func personaChanged(profile: Profile) {
        guard MemoryWriterSettings.writes(.c3, defaults: defaults) else { return }
        Task { await start(profile: profile) { await $0.personaChanged() } }
    }

    /// 「整理一个主题…」
    func organizeTopic(_ topic: String, profile: Profile) {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, MemoryWriterSettings.writes(.c3, defaults: defaults) else { return }
        Task { await start(profile: profile) { await $0.organizeTopic(t) } }
    }

    @ObservationIgnored private var seedResumes = CatalogSeedResumeQueue()

    func hasActiveSeed(_ taskId: String, profileId: String?) -> Bool {
        seedResumes.contains(taskId) || profileId.map { seedRequests[$0] != nil } == true
    }

    /// 「从 CC 记忆播种」/「从人设生成基础 wiki」：同一个种子任务机制
    func seed(profile: Profile, entry: CatalogSeedEntry) {
        guard MemoryWriterSettings.writes(.c3, defaults: defaults), seedRequests[profile.id] == nil else { return }
        let token = CatalogCancel()
        seedRequests[profile.id] = token
        MemoryWriteLog.record(writer: .c3, profileId: profile.id, ok: true, note: "种子（\(entry.label)）：进入整理队列", model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profile.id))
        Task {
            defer { seedRequests[profile.id] = nil }
            await start(profile: profile) { session in
                if token.isCancelled { session.cancel() }
                return await session.seed(entry: entry)
            }
        }
    }

    /// 批了 / 驳回了种子目录（真有新审批时才调），或点了「继续」：同一个任务接着跑（批前不在后台空转）
    func resumeSeed(_ taskId: String, profile: Profile) {
        guard MemoryWriterSettings.writes(.c3, defaults: defaults), seedResumes.request(taskId) else { return }
        Task {
            var report: CatalogRunReport?
            await start(profile: profile) { [weak self] session in
                self?.seedResumes.began(taskId)
                let r = await session.resumeSeed(taskId)
                report = r
                return r
            }
            let ok = report.map { $0.failures.isEmpty && $0.blocked == nil && !$0.cancelled } ?? false
            if seedResumes.finished(taskId, ok: ok) { resumeSeed(taskId, profile: profile) }
        }
    }

    func abandonSeed(_ taskId: String, profile: Profile) {
        Task { await start(profile: profile) { await $0.abandonSeed(taskId) } }
    }

    /// 新用户三问答完（小芽引导）：答案先落进目标楼层（一个还没开跑的种子任务，同一个任务 id 只建一次），能跑就排队出目录；
    /// 没有能用的模型 / C3 关着就停着，可稍后在 C3 页「继续这个种子任务」生成。不等模型，不挡聊天
    /// enqueue = 能跑时怎么排队（默认 resumeSeed；测试换成记下来，不真发请求）
    func survey(_ answers: [CatalogSurvey.Answer], taskId: String, profileId: String, now: Date = Date(),
                enqueue: ((String, Profile) -> Void)? = nil) async -> CatalogSurvey.Outcome {
        guard !answers.isEmpty else { return .empty }
        guard let profile = profileManager?.profiles.first(where: { $0.id == profileId }) else { return .failed }
        let blocked = surveyBlocker()
        let outcome: CatalogSurvey.Outcome
        do {
            outcome = try await Task.detached(priority: .utility) {
                try await CatalogSurvey.create(taskId: taskId, profileId: profileId, answers: answers, wiki: WikiStore(profileId: profileId),
                                               blocked: blocked, now: now)
            }.value
        } catch {
            MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: false, note: "种子（新用户三问）：答案没存成：\(error.localizedDescription)", model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
            return .failed
        }
        MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: true,
                              note: blocked.map { "种子（新用户三问）：答案存好了，现在生成不了（\($0.reason)），可稍后生成" } ?? "种子（新用户三问）：答案存好了，进入整理队列",
                              model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        if blocked == nil {
            if let enqueue { enqueue(taskId, profile) } else { resumeSeed(taskId, profile: profile) }
        }
        return outcome
    }

    /// 三问答完能不能马上生成：记忆总开关 / C3 关着、所选本机模型用不了或在后台、所选卡发不出请求（口径同 ProviderManager.isUsable：桥接卡不要钥匙）
    private func surveyBlocker() -> CatalogSurvey.Blocker? {
        guard MemoryWriterSettings.writes(.c3, defaults: defaults) else {
            return MemoryWriterSettings.isOn(.c3, defaults: defaults) ? .memoryOff : .c3Off
        }
        guard let providers = providerManager else { return .noModel }
        let chat = providers.resolveModel(conversationModelId: nil, profileModelId: nil, globalFallbackId: defaults.string(forKey: "selectedChatModel"))
        let route = CatalogModelRoute.resolve(providerManager: providers, chatFallback: chat, defaults: defaults)
        if route.fallbackNote != nil { return route.localMissing || !LocalLLMService.isSupported ? .localModel : .background }
        if case .remote(let m) = route.route, !(providers.provider(for: m).map(providers.isUsable) ?? false) { return .noModel }
        return nil
    }

    /// 停：正在跑的不再发请求（已交的条目照常成提案），排着的不跑了
    func cancel() {
        for token in seedRequests.values { token.cancel() }
        for s in sessions { s.cancel() }
    }

    private func start(profile: Profile, _ body: @escaping (CatalogSession) async -> CatalogRunReport) async {
        guard let job = await makeJob(profile: profile) else { return }
        await start(job: job, body)
    }

    /// 返回 body 跑没跑（排队时被停了 = false）
    @discardableResult
    func start(job: CatalogJob, _ body: @escaping (CatalogSession) async -> CatalogRunReport) async -> Bool {
        let session = CatalogSession(job: job)
        var ran = false
        sessions.append(session)
        queued = sessions.count - 1
        isRunning = true
        let token = session.cancelToken
        await withTaskCancellationHandler {
        await CatalogLock.shared.acquire(job.profileId)
        if !session.isCancelled {
            session.onProgress = { [weak self] topic, round in
                self?.currentTopic = topic
                self?.round = round
            }
            currentTopic = nil
            round = 0
            ran = true
            lastReport = await body(session)
            lastFinishedAt = Date()
        }
        await CatalogLock.shared.release(job.profileId)
        } onCancel: {
            token.cancel()
            Task { @MainActor in session.cancel() }
        }
        sessions.removeAll { $0 === session }
        queued = max(0, sessions.count - 1)
        isRunning = !sessions.isEmpty
        if !isRunning {
            currentTopic = nil
            round = 0
        }
        return ran
    }

    private func makeJob(profile: Profile) async -> CatalogJob? {
        guard let pm = profileManager, let providers = providerManager else { return nil }
        let pid = profile.id
        let chat = providers.resolveModel(conversationModelId: nil, profileModelId: nil, globalFallbackId: defaults.string(forKey: "selectedChatModel"))
        let route = CatalogModelRoute.resolve(providerManager: providers, chatFallback: chat, defaults: defaults)
        let remote: ProviderModel?
        if case .remote(let m) = route.route { remote = m } else { remote = nil }
        func backend(_ kind: UsageKind) -> @MainActor () -> AssistantBackend {
            {
                switch route.route {
                case .local(let id): return AssistantLocalBackend(modelId: id)
                case .remote(let m): return AssistantCloudBackend(model: m, providerManager: providers, usage: UsageContext(kind: kind, profileId: pid))
                }
            }
        }
        let deps = CatalogAgent.Deps(makeBackend: backend(.catalog),
                                     gate: { text in await CatalogBudget.block(model: remote, providerManager: providers, text: text) })
        let seedDeps = CatalogAgent.Deps(makeBackend: backend(.catalogSeed),
                                         gate: { text in await CatalogBudget.globalGate(model: remote, providerManager: providers, text: text) })
        let seedModel: String
        switch route.route {
        case .local(let id): seedModel = "local:\(id)"
        case .remote(let m): seedModel = "remote:\(m.credentialId)/\(m.modelId)"
        }
        let root = await Task.detached(priority: .utility) { FileLibraryStore.memoryRoot(profileId: pid) }.value
        return CatalogJob(profileId: pid, memoryRoot: root, container: pm.container,
                          names: MemoryExtractor.Names(userName: profile.userName, assistantName: profile.assistantName),
                          floorPrompt: writerFloorPrompt(profile: profile),
                          modelName: route.displayName + (route.fallbackNote.map { "（\($0)）" } ?? ""),
                          caller: FragmentModelRoute.caller(for: route.route, providerManager: providers, conversationId: "", profileId: pid, kind: .catalog,
                                                            preflight: { text in await CatalogBudget.block(model: remote, providerManager: providers, text: text) }),
                          agentDeps: deps, maxTopics: CatalogSettings.maxTopics(defaults), maxRounds: CatalogSettings.maxRounds(defaults),
                          sorter: CatalogSettings.sorter(defaults), timeline: SessionCloseout.timelineEnabled,
                          floorBase: floorBase(profile: profile), seedDeps: seedDeps, seedModel: seedModel, seedBlocked: route.fallbackNote)
    }
}

// MARK: - C3 发请求前那一查（两步每次请求、手动 agent 每一轮）

/// 写入预算读账本在后台；卡片和全局闸的可变状态在主线程读（astra 10-16 #11）
enum CatalogBudget {
    /// 拦下 = 原因；model = nil（本机）只查写入预算
    static func block(model: ProviderModel?, providerManager: ProviderManager, text: String) async -> String? {
        let tokens = await Task.detached(priority: .utility) { () -> Int? in
            WriteBudgetStore.exceeded() ? nil : HeuristicEstimator().estimate(text)
        }.value
        guard let tokens else { return "写入预算用完" }
        return await gate(model: model, providerManager: providerManager, inputTokens: tokens)
    }

    /// 种子：不查日常写入预算（点开始就是同意花这一次），全局总闸照查
    static func globalGate(model: ProviderModel?, providerManager: ProviderManager, text: String) async -> String? {
        let tokens = await Task.detached(priority: .utility) { HeuristicEstimator().estimate(text) }.value
        return await gate(model: model, providerManager: providerManager, inputTokens: tokens)
    }

    @MainActor
    static func gate(model: ProviderModel?, providerManager: ProviderManager, inputTokens: Int) -> String? {
        guard let model, let provider = providerManager.provider(for: model) else { return nil }
        let est = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId,
                                              usage: TokenUsage(inputTokens: inputTokens, outputTokens: 1500))
        if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: est),
           !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: est) {
            return "预算闸"
        }
        return nil
    }
}
