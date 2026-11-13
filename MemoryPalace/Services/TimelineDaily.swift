import MemoryCore
import Foundation
import SwiftData
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// A4 用哪个模型（第 7 段）：没选过 = 本机轻巧款（没装 / 跑不了 / 在后台沿 `FragmentModelRoute` 退回提取模型）；
/// 选过的（某张卡上的模型 / 跟「提取模型」/ 本机某款）照旧。账记在 A4 名下
enum TimelineModelRoute {
    static var key: String { MemoryWriterModels.key(.a4) }
    static let defaultChoice = FragmentModelRoute.localPrefix + AssistantLocalModel.light.id

    /// 纯函数：存的值 → 实际按哪个选（空 = 没选过 = 本机轻巧款）
    static func choice(_ stored: String) -> String {
        stored.isEmpty ? defaultChoice : stored
    }

    @MainActor
    static func resolve(providerManager: ProviderManager, chatFallback: ProviderModel, defaults: UserDefaults = .standard) -> FragmentModelRoute.Resolved {
        let memory = ConversationViewModel.memoryModel(providerManager: providerManager, fallback: chatFallback)
        #if os(iOS)
        let active = UIApplication.shared.applicationState != .background
        #else
        let active = true
        #endif
        return FragmentModelRoute.resolve(choice: choice(defaults.string(forKey: key) ?? ""), memoryModel: memory,
                                          remoteModels: FragmentModelRoute.remoteCredentials(providerManager.enabledProviders).flatMap(\.models),
                                          localSupported: LocalLLMService.isSupported, appActive: active,
                                          localInstalled: { AssistantModelStore.installedDirectory(modelId: $0) != nil })
    }
}

/// 维护（搬迁 / 恢复）期间 A4 停手：暂停 = 新的一趟不进；纪元变了 = 在途那趟后面的提交一律作废。
/// 提交（月文件、待续本子）和恢复换文件都在 `TimelineStore.withWriteLock` 里，提交前在锁里看一眼它
final class TimelineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var epoch = 0

    var isPaused: Bool { lock.withLock { paused } }
    var current: Int { lock.withLock { epoch } }

    func pause() { lock.withLock { paused = true; epoch += 1 } }
    func resume() { lock.withLock { paused = false } }
    /// 这一趟开始时的纪元还作数（没暂停、中间没维护过）
    func valid(_ e: Int) -> Bool { lock.withLock { !paused && epoch == e } }
}

/// A2 文件变化账（c2c3-v2 第 7 段 astra 二轮 #3 #4）：`timeline/.a4-sources.json`，跟着时间轴文件夹一起备份 / 恢复。
/// 每个 sessions/ 文件记大小、修改时间、内容哈希、它的 A2 段碰到哪几天——这是「骨架 / 待续来源」指纹；主调另有标题指纹
/// （`TimelineDayRecord.source`）。文件变了（新的 / 改了 / 删了）：新旧碰到的日子都标成待拼。不靠窗口最近有没有消息。
/// 待续平时在 A2 覆盖之前就保全了（`TimelineDaily.preserveBeforeSave`）；这里只在第一轮 / 起点变了时把全部 A2 的待续再盘点一遍
struct TimelineSourceState: Codable, Equatable {
    struct File: Codable, Equatable {
        var size: Int
        var mtime: Double
        var sha: String
        var days: [String]
    }

    var files: [String: File] = [:]
    /// 等着重拼的日子：拼成了才出队；没拼成的、还没到时候的（今天）留着；起点以前 / 恢复冻住的丢掉（起点变了会整轮重扫）
    var dirty: [String] = []
    /// 全量盘点（每个文件都读、全部 A2 的待续都搬）是按哪个起点做的（"" = 没设起点）；nil = 还没做过。起点变了就再做一轮
    var harvestedFrom: String? = nil

    static let fileName = ".a4-sources.json"

    static func url(_ timelineDir: URL) -> URL { timelineDir.appendingPathComponent(fileName) }

    /// 没有 / 坏了 = 空的：下次全部重扫（多标几天、多搬一遍都去重，不丢）
    static func load(_ timelineDir: URL) -> TimelineSourceState {
        guard let data = try? Data(contentsOf: url(timelineDir)),
              let s = try? JSONDecoder().decode(TimelineSourceState.self, from: data) else { return TimelineSourceState() }
        return s
    }

    func save(_ timelineDir: URL) throws {
        try FileManager.default.createDirectory(at: timelineDir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: Self.url(timelineDir), options: .atomic)
    }
}

enum TimelineSources {
    struct Scan {
        var files: [String: TimelineSourceState.File] = [:]
        /// 变了的文件新旧 A2 段碰到的日子
        var dirty: Set<String> = []
        /// 全量盘点时：A2 段（含尾段）的待续；起点以前结束的段不搬
        var harvest: [PendingStore.Candidate] = []
        /// 读不了 / 格式对不上的文件：照旧记着上一次的，下次再试
        var errors: [String] = []
    }

    /// 扫 sessions/：大小 + 修改时间没变的不读；变了的算内容哈希，哈希也没变只更新大小时间；真变了的严格读、标日子。
    /// full = 全量盘点：每个文件都重读、全部 A2 段碰到的日子都标、待续都收出来
    static func scan(sessionsDir: URL, previous: TimelineSourceState, startKey: String?, full: Bool = false,
                     calendar: Calendar = .current) -> Scan {
        let fm = FileManager.default
        var out = Scan()
        var listing: [String] = []
        if fm.fileExists(atPath: sessionsDir.path) {
            do { listing = try fm.contentsOfDirectory(atPath: sessionsDir.path) } catch {
                // 目录在却列不出来：不当成空目录，照旧记着上一次的
                out.errors.append(sessionsDir.lastPathComponent)
                out.files = previous.files
                return out
            }
        }
        let names = listing.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
        for name in names {
            let url = sessionsDir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let old = previous.files[name]
            if !full, let old, old.size == size, old.mtime == mtime {
                out.files[name] = old
                continue
            }
            guard let data = try? Data(contentsOf: url), let raw = String(data: data, encoding: .utf8) else {
                out.errors.append(name)
                if let old { out.files[name] = old }
                continue
            }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if !full, let old, old.sha == sha {
                out.files[name] = .init(size: size, mtime: mtime, sha: sha, days: old.days)
                continue
            }
            let summary: SessionSummary?
            do { summary = try SessionSummaryStore.parseStrict(raw, path: url.path) } catch {
                out.errors.append(name)
                if let old { out.files[name] = old }
                continue
            }
            var days = Set<String>()
            for seg in summary?.segments ?? [] where TimelineSkeleton.isA2(seg) {
                days.formUnion(TimelineSkeleton.dayKeys(from: seg.start, to: seg.end, calendar: calendar))
                let end = MemoryDay.key(seg.end, calendar: calendar)
                let texts = TimelineStore.pendingItems(seg.pending)
                guard full, let s = summary, !texts.isEmpty, startKey.map({ end >= $0 }) ?? true else { continue }
                out.harvest.append(.init(conversationId: s.conversationId, day: end, anchor: seg.lastNodeId, texts: texts,
                                         source: PendingStore.segmentSource(conversationId: s.conversationId, segment: seg)))
            }
            out.dirty.formUnion(days)
            out.dirty.formUnion(old?.days ?? [])
            out.files[name] = .init(size: size, mtime: mtime, sha: sha, days: days.sorted())
        }
        for (name, old) in previous.files where !names.contains(name) {
            out.dirty.formUnion(old.days)
        }
        return out
    }
}

/// A4 一天一条的入口（plan-memory-c2c3-v2 第 7 段）：只读已经落盘的 A2 段，不调用、不触发、不等待 A2 压缩
/// （A2 什么时候切段照现在）。跨过 05:00 后第一次巡检拼最近几天 + A2 文件变过的日子（标题没变的不再调模型）。
/// 老的「一天 × 窗口」条目一律原样留着、一条不删（车头 10-22 第一性原理：不再证明覆盖范围），新的一天一条并列加进同一个月文件；
/// 动有老条目的月份、动待续本子之前先备份原始 timeline/ + pending/ 并核过。
/// 同一层的任务排队一个一个跑；维护（搬迁 / 恢复）时停手、在途的提交作废。C3 每天那次先等它跑完（`CatalogRunner.dailyTick`）
actor TimelineDaily {
    static let shared = TimelineDaily()
    static let gate = TimelineGate()

    static let backupPrefix = "A4日级前-"
    /// 最近几天：每次巡检都拼一遍骨架（没压缩的消息、A2 后来压完的那截补进来）
    static let lookbackDays = 7
    /// 有日子没写成：多久以后再试（不造重试队列，就是下一次巡检）
    static let retryAfter: TimeInterval = 30 * 60

    static func ranKey(_ profileId: String) -> String { "mem_a4_daily_ran.\(profileId)" }
    static func backupKey(_ profileId: String) -> String { "mem_a4_daily_backup.\(profileId)" }
    /// 恢复过备份后自动调度不碰的日期范围 [最早, 最晚]（手动「重写这天」照样能写）
    static func frozenKey(_ profileId: String) -> String { "mem_a4_daily_frozen.\(profileId)" }

    /// 这一层今天（记忆日）自动拼过没有（主线程便宜地判一下，免得每轮回复都去取模型）
    static func ranToday(profileId: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: ranKey(profileId)) == MemoryDay.key(now)
    }

    enum Mode: Equatable {
        /// 自动：没有主调 / 标题变了才调模型（重入不重复收费）
        case daily
        /// 手动：有标题就重写主调
        case force
    }

    struct Input {
        var profileId: String
        var memoryRoot: URL
        var startDay: Date?
        /// 先用的模型（本机或云端）；记在 A4 名下
        var caller: SessionSegmentWriter.Caller
        /// caller 是本机时：放不下完整输入 / 本机跑挂 / 回来的解析不了，退到这个（提取模型，云端，照查写入预算和全局闸）
        var fallback: SessionSegmentWriter.Caller? = nil
        var modelName: String
        /// 碰到这段时间的窗口（主线消息 + 已落盘的 A2），后台读；读不全要明说
        var load: (DateInterval) -> TimelineSkeleton.Source
        /// 待续本子在哪：nil = 这一层的真本子（走缓存）；测试 / 演练注入根
        var pendingRoot: URL? = nil
        var defaults: UserDefaults = .standard
    }

    struct Report: Equatable {
        /// 新写 / 改过的日子
        var written: [String] = []
        /// 没写成的日子 → 原因（原样留着，下次再试）
        var failed: [String: String] = [:]
        /// 只有老收尾段 / 第 0 段之类的内容、没有新项：只有老条目
        var keptLegacy: [String] = []
        /// 窗口 / A2 / 月文件读不全，这天没拼
        var unread: [String] = []
        /// 有段在当前分支上找不到范围：按段自己的起止列、没指针
        var unresolved: [String: [String]] = [:]
        var calls = 0
        /// 本机放不下 / 跑挂 / 回来的解析不了，退到提取模型的次数
        var fellBack = 0
        /// 这次做的备份（文件夹名）
        var backup: String?
        /// 备份 / 待续没保全：有老条目的月份、搬待续先不动
        var blocked: String?
        /// 搬进待续本子的条数（A2 段的 + 老条目补齐的不算在内）
        var pendingAdded = 0
        /// 中途进了维护（搬迁 / 恢复），后面的提交作废
        var invalidated = false
        /// 读不了的 A2 文件（下次再试）
        var sourceErrors: [String] = []
    }

    /// 同一层排队：每个任务等前一个跑完才开始；登记只清自己
    private var tail: [String: Task<Report?, Never>] = [:]
    private var retryAt: [String: Date] = [:]

    /// 排在前面的任务跑完才轮到这一趟（C3 每天那次因此会等在途的拼完），轮到时再判：
    /// 自动：维护中 / 这一层今天（记忆日）跑过 / 30 分钟内刚失败过，都不跑。
    /// force（「现在写」）：最近几天照自动的规矩、今天也拼并重写主调。返回 nil = 没跑
    func runDue(_ input: Input, now: Date = Date(), force: Bool = false) async -> Report? {
        guard !Self.gate.isPaused else { return nil }
        return await enqueue(input) { await self.due(input, now: now, force: force) }
    }

    private func due(_ input: Input, now: Date, force: Bool) async -> Report? {
        let pid = input.profileId
        guard !Self.gate.isPaused else { return nil }
        if !force {
            if input.defaults.string(forKey: Self.ranKey(pid)) == MemoryDay.key(now) { return nil }
            if let at = retryAt[pid], at > now { return nil }
        }
        let report = await Self.perform(input, now: now, force: force)
        if report.failed.isEmpty, report.blocked == nil, !report.invalidated {
            input.defaults.set(MemoryDay.key(now), forKey: Self.ranKey(pid))
            retryAt[pid] = nil
        } else {
            retryAt[pid] = now.addingTimeInterval(Self.retryAfter)
        }
        return report
    }

    /// 时间轴页「重写这天的主调」：只这一天，有标题就重调一次（恢复过的日子也照写）；排在前面的任务后面跑
    func regenerate(day: String, _ input: Input, now: Date = Date()) async -> Report? {
        guard !Self.gate.isPaused else { return nil }
        return await enqueue(input) {
            if Self.gate.isPaused { return nil }
            return await Self.perform(input, now: now, modes: [day: .force], scan: false)
        }
    }

    /// 排队 + 记账（这一趟花了多少记进日志那条）+ 记日志都在同一个计量里
    private func enqueue(_ input: Input, _ work: @escaping () async -> Report?) async -> Report? {
        let pid = input.profileId
        let previous = tail[pid]
        let task = Task { () -> Report? in
            _ = await previous?.value
            return await MemoryWriteLog.metered {
                let report = await work()
                if let report { Self.log(report, input: input) }
                return report
            }
        }
        tail[pid] = task
        let report = await task.value
        if tail[pid] == task { tail[pid] = nil }
        return report
    }

    // MARK: - 一趟

    /// 最近几天（不含今天；force 带上今天并重写今天的主调）+ A2 文件变过、碰到的、起点以后、今天以前的日子（扫 sessions/）。
    /// 恢复过的日期范围自动不碰（今天的 force 除外）
    static func perform(_ input: Input, now: Date, force: Bool, calendar: Calendar = .current) async -> Report {
        let today = MemoryDay.key(now, calendar: calendar)
        let startKey = input.startDay.map { MemoryDay.key($0, calendar: calendar) }
        let frozen = frozenRange(input)
        func auto(_ d: String) -> Bool {
            d < today && (startKey.map { d >= $0 } ?? true) && !(frozen.map { $0.contains(d) } ?? false)
        }
        var modes: [String: Mode] = [:]
        for d in recentDays(today: today, count: lookbackDays, includeToday: force, calendar: calendar) {
            if d == today { modes[d] = .force } else if auto(d) { modes[d] = .daily }
        }
        return await perform(input, now: now, modes: modes, scan: true, eligible: auto, later: { $0 >= today }, calendar: calendar)
    }

    struct Invalidated: Error {}

    /// modes：要拼的日子；scan：再扫一遍 A2 文件，变过的（在 eligible 里的）日子一起拼；later：还没到时候的日子（今天），留在待拼里。
    /// 第一轮 / 起点变了：全量盘点，全部 A2 的待续搬一遍（平时待续在 A2 存段时就搬了）。待补的来源也在这里补
    static func perform(_ input: Input, now: Date, modes initial: [String: Mode], scan: Bool,
                        eligible: (String) -> Bool = { _ in false }, later: (String) -> Bool = { _ in false },
                        calendar: Calendar = .current) async -> Report {
        let dir = TimelineStore.dir(root: input.memoryRoot)
        let epoch = gate.current
        var report = Report()
        var modes = initial
        guard gate.valid(epoch) else { return report }
        let previous = scan ? TimelineSourceState.load(dir) : nil
        let startKey = input.startDay.map { MemoryDay.key($0, calendar: calendar) }
        let full = previous.map { $0.harvestedFrom != (startKey ?? "") } ?? false
        let found = previous.map {
            TimelineSources.scan(sessionsDir: SessionSummaryStore.dir(root: input.memoryRoot), previous: $0,
                                 startKey: startKey, full: full, calendar: calendar)
        }
        report.sourceErrors = found?.errors ?? []
        let dirty = Set(previous?.dirty ?? []).union(found?.dirty ?? [])
        for d in dirty where modes[d] == nil && eligible(d) { modes[d] = .daily }
        let harvest = found?.harvest ?? []

        var skeletons: [String: TimelineSkeleton.Day] = [:]
        var readable = true
        if !modes.isEmpty, let source = load(input, modes: modes, calendar: calendar) {
            if let e = source.error {
                unreadAll(modes, why: e, into: &report)
                readable = false
            } else {
                skeletons = TimelineSkeleton.build(source.windows, days: Set(modes.keys), calendar: calendar)
            }
        }
        let days = modes.keys.sorted()
        let legacyMonths = Set(days.map { String($0.prefix(7)) }).filter { m in
            (try? TimelineStore.monthStrict(m, in: dir).entries.isEmpty) == false
        }
        let needLegacy = (try? PendingStore.needsLegacyImport(profileId: input.profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: input.profileId), memoryRoot: input.pendingRoot)) ?? true
        // 安全：动待续本子、或往有老条目的月份里加日记录之前——先备份原始 timeline / pending 并核过；再严格读、补齐老待续、搬 A2 待续
        var safe = true
        let retry = PendingStore.hasRetry(profileId: input.profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: input.profileId), memoryRoot: input.pendingRoot)
        var harvested = harvest.isEmpty && !needLegacy && !retry
        if !harvest.isEmpty || retry || needLegacy || (readable && !legacyMonths.isEmpty) {
            do {
                report.backup = try ensureBackup(memoryRoot: input.memoryRoot, profileId: input.profileId, defaults: input.defaults, now: now)
            } catch {
                report.blocked = "旧时间轴 / 待续备份没做成（\(error.localizedDescription)），有老条目的月份、待续都先不动"
                safe = false
            }
        }
        if safe, !harvested {
            do {
                try TimelineStore.withWriteLock {
                    guard gate.valid(epoch) else { throw Invalidated() }
                    if needLegacy { try PendingStore.importLegacyStrict(profileId: input.profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: input.profileId), memoryRoot: input.pendingRoot) }
                    report.pendingAdded = try PendingStore.addCandidatesFlushingRetry(harvest, profileId: input.profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: input.profileId),
                                                                                      memoryRoot: input.pendingRoot).count
                }
                harvested = true
            } catch is Invalidated {
                report.invalidated = true
                return report
            } catch {
                report.blocked = "待续没保全（\(error.localizedDescription)），这次没搬，下次再来"
            }
        }
        if readable {
            for d in days {
                if Task.isCancelled || report.invalidated { break }
                await rebuild(d, built: skeletons[d] ?? TimelineSkeleton.Day(), mode: modes[d] ?? .daily, dir: dir, input: input,
                              epoch: epoch, safe: safe, into: &report)
            }
        }
        // 来源账：全量盘点的待续搬成了才记「盘点过」和这批指纹（没搬成下次整轮重来）；拼成了的日子出队，
        // 没拼成 / 没读全的、还没到时候的（今天）留着，起点以前 / 冻住的丢掉
        if let previous, let found, !report.invalidated {
            let again = Set(report.failed.keys).union(report.unread)
            // 全量盘点：有一个文件 / 目录读不了就不算盘完（读不了的那份修好以后下一轮还会搬）
            let done = !full || (harvested && found.errors.isEmpty)
            let next = TimelineSourceState(files: done ? found.files : previous.files,
                                           dirty: dirty.filter { later($0) || (eligible($0) && again.contains($0)) }.sorted(),
                                           harvestedFrom: done ? (startKey ?? "") : previous.harvestedFrom)
            if next != previous {
                do {
                    try TimelineStore.withWriteLock {
                        guard gate.valid(epoch) else { throw Invalidated() }
                        try next.save(dir)
                    }
                } catch is Invalidated {
                    report.invalidated = true
                } catch {
                    CacheDiagLog.shared.log("📝 时间轴: 来源账没存上（\(error.localizedDescription)），下次重扫")
                }
            }
        }
        return report
    }

    private static func load(_ input: Input, modes: [String: Mode], calendar: Calendar) -> TimelineSkeleton.Source? {
        let days = modes.keys.sorted()
        guard let lo = days.first, let hi = days.last,
              let from = MemoryDay.date(ofKey: lo, calendar: calendar).map({ MemoryDay.boundary(of: $0, calendar: calendar) }),
              let last = MemoryDay.date(ofKey: hi, calendar: calendar).map({ MemoryDay.boundary(of: $0, calendar: calendar) }),
              let to = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return input.load(DateInterval(start: from, end: to))
    }

    private static func unreadAll(_ modes: [String: Mode], why: String, into report: inout Report) {
        for d in modes.keys.sorted() {
            report.failed[d] = "窗口没读全（\(why)），原样留着"
            report.unread.append(d)
        }
    }

    /// 一天：要不要调模型 → 落盘（月文件锁里看一眼维护纪元再读改写）。老条目一条不动，新的一天一条并列
    /// - A2 读不了 / 月文件读不了：原样留着、记没读全
    /// - 主调没写成：已有这天的（新记录 / 老条目）原样不动，全新的日子存「还没有主调」的骨架
    /// - 备份没做成：这个月有老条目就不动
    static func rebuild(_ d: String, built: TimelineSkeleton.Day, mode: Mode, dir: URL, input: Input, epoch: Int, safe: Bool,
                        into report: inout Report) async {
        if !built.failed.isEmpty {
            report.failed[d] = "上下文摘要读不了（\(built.failed.joined(separator: "、"))），这天原样留着"
            report.unread.append(d)
            return
        }
        let month: TimelineStore.Month
        do { month = try TimelineStore.monthStrict(String(d.prefix(7)), in: dir) } catch {
            report.failed[d] = "月文件读不了或格式对不上（\(error.localizedDescription)），原样留着"
            report.unread.append(d)
            return
        }
        let existing = month.days.first { $0.date == d }
        let hasLegacy = month.entries.contains { $0.dayKey == d }
        if !built.unresolved.isEmpty { report.unresolved[d] = built.unresolved }
        guard !built.items.isEmpty else {
            if hasLegacy, existing == nil { report.keptLegacy.append(d) }
            return
        }
        if !safe, !month.entries.isEmpty {
            report.failed[d] = "备份没做成，这个月有老条目，先不动"
            return
        }
        let source = TimelineStore.source(date: d, titles: built.titles)
        var record = TimelineDayRecord(date: d, headline: nil, items: built.items, source: source)
        let stale = existing?.headline == nil || existing?.source != source
        let call = !built.titles.isEmpty && (mode == .force || stale)
        if !call, let e = existing, !built.titles.isEmpty {
            record.headline = e.headline
            record.topics = e.topics
            record.source = e.source
        }
        if call {
            report.calls += 1
            var why: String?
            do {
                if let draft = try await headline(d, titles: built.titles, input: input, report: &report) {
                    record.headline = draft.headline
                    record.topics = draft.topics
                } else {
                    why = "被预算闸拦下或模型没回内容"
                }
            } catch {
                why = error.localizedDescription
            }
            if let why {
                report.failed[d] = "主调没写成（\(why)）"
                // 旧日数据不动：已有这天的（新记录 / 老条目）原样留着；全新的日子存骨架，标「还没有主调」
                guard existing == nil, !hasLegacy else { return }
            }
        }
        if record == existing { return }
        do {
            try TimelineStore.withWriteLock {
                guard gate.valid(epoch) else { throw Invalidated() }
                try TimelineStore.mutateMonth(String(d.prefix(7)), in: dir) { m in
                    m.days.removeAll { $0.date == d }
                    m.days.append(record)
                }
            }
            if report.failed[d] == nil { report.written.append(d) }
        } catch is Invalidated {
            report.invalidated = true
        } catch {
            report.failed[d] = "写盘失败（\(error.localizedDescription)），原样留着"
        }
    }

    /// 主调：本机先上——放不下完整输入（不拿裁过的写）、本机跑挂、回来解析不了，都退到提取模型；主动取消不退
    static func headline(_ d: String, titles: [String], input: Input, report: inout Report) async throws -> TimelineWriter.Draft? {
        guard let fallback = input.fallback else { return try await TimelineWriter.write(date: d, titles: titles, caller: input.caller) }
        if localFits(system: TimelineWriter.systemPrompt, user: TimelineWriter.userContent(date: d, titles: titles)) {
            do {
                if let draft = try await TimelineWriter.write(date: d, titles: titles, caller: input.caller) { return draft }
                CacheDiagLog.shared.log("📝 时间轴: \(d) 本机没回内容，退到提取模型")
            } catch is CancellationError {
                throw CancellationError()
            } catch FragmentPoolError.interrupted {
                // 被停下 / 进了后台：算主动取消，不退（下次巡检再来）
                throw FragmentPoolError.interrupted
            } catch {
                if Task.isCancelled { throw CancellationError() }
                CacheDiagLog.shared.log("📝 时间轴: \(d) 本机没写成（\(error.localizedDescription)），退到提取模型")
            }
        } else {
            CacheDiagLog.shared.log("📝 时间轴: \(d) 标题太多本机放不下，退到提取模型")
        }
        report.fellBack += 1
        return try await TimelineWriter.write(date: d, titles: titles, caller: fallback)
    }

    /// 本机那条路会把放不下的 system / user 静默裁掉（`LocalChatProvider.trimmed`）：整份放得下才走本机
    static func localFits(system: String, user: String) -> Bool {
        system.count <= LocalChatProvider.systemBudget && user.count <= max(LocalChatProvider.totalBudget - system.count, 500)
    }

    /// 今天往前 count 天（不含今天；includeToday 带上今天），新→旧
    static func recentDays(today: String, count: Int, includeToday: Bool, calendar: Calendar = .current) -> [String] {
        guard let t = MemoryDay.date(ofKey: today, calendar: calendar) else { return [] }
        return ((includeToday ? 0 : 1)...count).compactMap { k in
            calendar.date(byAdding: .day, value: -k, to: t).map { MemoryDay.key(MemoryDay.boundary(of: $0, calendar: calendar), calendar: calendar) }
        }
    }

    // MARK: - 恢复

    static func frozenRange(_ input: Input) -> ClosedRange<String>? {
        guard let r = input.defaults.stringArray(forKey: frozenKey(input.profileId)), r.count == 2, r[0] <= r[1] else { return nil }
        return r[0]...r[1]
    }

    /// 时间轴里出现过的日子：日记录、老条目、等着重拼的（恢复前后各算一次）
    static func dayKeys(timelineDir dir: URL) -> Set<String> {
        var keys = Set(TimelineSourceState.load(dir).dirty)
        for m in TimelineStore.months(in: dir) {
            let month = TimelineStore.month(m, in: dir)
            keys.formUnion(month.days.map(\.date) + month.entries.map(\.dayKey))
        }
        return keys
    }

    /// 恢复了带 timeline/ 的备份（`MemoryRegeneration.restore`）：恢复前后出现过的日子，连同恢复那天以前的全部日子（来源账也被换回去了，
    /// 不冻住就会把历史全部重拼一遍），以后自动调度都不碰；手动「重写这天」照写。空备份（恢复前后都没有日子）也照样记
    static func noteRestored(profileId: String, before: Set<String>, after: Set<String>, now: Date, defaults: UserDefaults = .standard,
                             calendar: Calendar = .current) {
        let today = MemoryDay.key(now, calendar: calendar)
        let yesterday = recentDays(today: today, count: 1, includeToday: false, calendar: calendar).first ?? today
        let touched = before.union(after).max() ?? yesterday
        let old = defaults.stringArray(forKey: frozenKey(profileId)).flatMap { $0.count == 2 ? $0 : nil }
        let hi = [touched, yesterday, old?[1] ?? yesterday].max() ?? yesterday
        defaults.set(["0000-01-01", hi], forKey: frozenKey(profileId))
    }

    // MARK: - 备份（动待续本子 / 有老条目的月份之前）

    /// 记着的那份备份还在、按清单逐个文件核得上（大小 + SHA256）才算数
    static func backupValid(memoryRoot: URL, profileId: String, defaults: UserDefaults) -> Bool {
        guard let name = defaults.string(forKey: backupKey(profileId)) else { return false }
        let url = MemoryRegeneration.backupRoot(memoryRoot: memoryRoot).appendingPathComponent(name, isDirectory: true)
        guard let m = MemoryRegeneration.manifest(of: url) else { return false }
        return (try? MemoryRegeneration.verify(url, m)) != nil
    }

    static func backupValid(_ input: Input) -> Bool {
        backupValid(memoryRoot: input.memoryRoot, profileId: input.profileId, defaults: input.defaults)
    }

    /// 记着的备份核得上就不再做（返回 nil）；否则原样备份 timeline/ + pending/，按清单逐个文件核过才记名
    static func ensureBackup(memoryRoot: URL, profileId: String, defaults: UserDefaults, now: Date) throws -> String? {
        if backupValid(memoryRoot: memoryRoot, profileId: profileId, defaults: defaults) { return nil }
        let url = try MemoryRegeneration.makeBackup(memoryRoot: memoryRoot, name: backupPrefix + MemoryRegeneration.stamp(now),
                                                    folders: [TimelineStore.folder, PendingStore.folder])
        guard let m = MemoryRegeneration.manifest(of: url) else {
            throw MemoryRegeneration.RegenError.incompleteBackup("没有完成清单")
        }
        _ = try MemoryRegeneration.verify(url, m)
        defaults.set(url.lastPathComponent, forKey: backupKey(profileId))
        return url.lastPathComponent
    }

    /// 老条目待续迁移的唯一入口（时间轴页、待续页、记忆页、pending_notes 和 A4 自己都走这条）：标了迁完 / 没有老月文件 = 不用；
    /// 否则拿着月文件锁先备份（原样、核过），再严格读、补齐（以前宽松迁过的不动不重复）、标迁完。维护中不跑；失败抛，本子原样
    @discardableResult
    static func ensurePendingMigrated(profileId: String, memoryRoot: URL? = nil, defaults: UserDefaults = .standard,
                                      now: Date = Date()) throws -> String? {
        let root = memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId)
        return try TimelineStore.withWriteLock {
            guard !gate.isPaused else { throw Invalidated() }
            guard try PendingStore.needsLegacyImport(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), memoryRoot: memoryRoot) else { return nil }
            let backup = try ensureBackup(memoryRoot: root, profileId: profileId, defaults: defaults, now: now)
            try PendingStore.importLegacyStrict(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), memoryRoot: memoryRoot)
            return backup
        }
    }

    // MARK: - 待续在哪儿产生就在哪儿保全（车头 10-22）

    /// 一份 A2 里各段（正式段 + 尾段）的待续
    static func candidates(from s: SessionSummary) -> [PendingStore.Candidate] {
        s.segments.filter(TimelineSkeleton.isA2).compactMap { seg in
            let texts = TimelineStore.pendingItems(seg.pending)
            guard !texts.isEmpty else { return nil }
            return .init(conversationId: s.conversationId, day: MemoryDay.key(seg.end), anchor: seg.lastNodeId, texts: texts,
                         source: PendingStore.segmentSource(conversationId: s.conversationId, segment: seg))
        }
    }

    /// 待续没保全：A2 这次不覆盖（原聊天还在，下次重做）
    struct PendingNotPreserved: LocalizedError {
        var why: String
        var errorDescription: String? { "待续没保全（\(why)），这次没存，下次再来" }
    }

    /// A2 覆盖前先保全（车头 10-22「先保全，后覆盖」，`SessionCloseout.saveA2`、三代搬迁提交都走这里）：
    /// 1. 严格读磁盘上的旧摘要（不在 = 空；读不了就抛，不覆盖）；
    /// 2. 改本子之前 `ensureBackup`（它自己核现有备份能不能用，不能只看记过名字；只真楼层）；
    /// 3. 先迁老待续、补身份（同 `preparePendingForEdit`）；
    /// 4. 旧摘要 + 新摘要两边各段的待续一起导入（来源 + 原文哈希去重），连同待补；
    /// 2–4 有一步不成就把这批记进待补。本子写成了、或待补确认落盘了才返回；两样都不成就抛——调用方不覆盖 A2
    static func preserveBeforeSave(_ new: SessionSummary, profileId: String, memoryRoot: URL? = nil, sessionsDir: URL? = nil,
                                   defaults: UserDefaults = .standard, now: Date = Date()) throws {
        let root = memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId)
        let old: SessionSummary?
        do { old = try SessionSummaryStore.loadStrict(conversationId: new.conversationId, in: sessionsDir ?? SessionSummaryStore.dir(root: root)) } catch {
            throw PendingNotPreserved(why: "旧的上下文摘要读不了：\(error.localizedDescription)")
        }
        var list: [PendingStore.Candidate] = []
        for c in (old.map(candidates(from:)) ?? []) + candidates(from: new) where !list.contains(c) { list.append(c) }
        guard !list.isEmpty else { return }
        do {
            let added = try TimelineStore.withWriteLock { () -> [PendingItem] in
                guard !gate.isPaused else { throw Invalidated() }
                if memoryRoot == nil { _ = try ensureBackup(memoryRoot: root, profileId: profileId, defaults: defaults, now: now) }
                if try PendingStore.needsLegacyImport(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), memoryRoot: memoryRoot) {
                    try PendingStore.importLegacyStrict(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), memoryRoot: memoryRoot)
                }
                return try PendingStore.addCandidatesFlushingRetry(list, profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), memoryRoot: memoryRoot)
            }
            if !added.isEmpty {
                CacheDiagLog.shared.log("📌 待续: 从上下文摘要搬了 \(added.count) 条")
                Task { @MainActor in NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
            }
        } catch {
            do { try PendingStore.enqueueRetry(list, profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), memoryRoot: memoryRoot) } catch let queueError {
                throw PendingNotPreserved(why: "本子没写成（\(error.localizedDescription)），待补也没记上（\(queueError.localizedDescription)）")
            }
            CacheDiagLog.shared.log("📌 待续: 这次没搬进本子（\(error.localizedDescription)），记进待补，下次再搬")
        }
    }

    /// 看 / 改待续之前（时间轴页、待续页、记忆页、pending_notes）：迁好老待续 + 本子每行都认得，才能改。失败抛，界面照实说、不许改
    static func preparePendingForEdit(profileId: String, defaults: UserDefaults = .standard) throws {
        try ensurePendingMigrated(profileId: profileId, defaults: defaults)
        try PendingStore.checkReadable(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
    }

    /// 界面 / 工具上那句话
    static func pendingProblem(_ error: Error) -> String {
        if error is Invalidated { return "正在搬迁 / 恢复记忆，待续这会儿不能改" }
        return "待续本子现在读不全或还没迁好（\(error.localizedDescription)），先不能改；本子原样没动"
    }

    // MARK: - 记账 / 日志

    private static func log(_ r: Report, input: Input) {
        let pid = input.profileId
        if let b = r.backup { CacheDiagLog.shared.log("📝 时间轴: 旧时间轴 / 待续先备份到「\(MemoryRegeneration.backupFolderName)/\(b)」") }
        if !r.written.isEmpty {
            MemoryHealthStore.recordOK(.timeline, profileId: pid, modelName: input.modelName,
                                       note: "拼好 \(r.written.count) 天（\(r.written.map { String($0.dropFirst(5)) }.joined(separator: "、"))）")
        }
        if r.pendingAdded > 0 {
            CacheDiagLog.shared.log("📝 时间轴: 从上下文摘要段搬了 \(r.pendingAdded) 条待续")
            Task { @MainActor in NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
        }
        if r.fellBack > 0 { CacheDiagLog.shared.log("📝 时间轴: \(r.fellBack) 天本机没写成，用了提取模型") }
        if !r.keptLegacy.isEmpty {
            CacheDiagLog.shared.log("📝 时间轴: \(r.keptLegacy.count) 天只有老收尾段 / 第 0 段，只有老条目")
        }
        if !r.sourceErrors.isEmpty {
            CacheDiagLog.shared.log("📝 时间轴: \(r.sourceErrors.count) 个上下文摘要文件读不了，下次再扫")
        }
        if r.invalidated { CacheDiagLog.shared.log("📝 时间轴: 中途在搬迁 / 恢复，后面的没写") }
        for (d, titles) in r.unresolved.sorted(by: { $0.key < $1.key }) {
            CacheDiagLog.shared.log("📝 时间轴: \(d) 有 \(titles.count) 段在当前分支上找不到范围，没列指针")
        }
        let problems = (r.blocked.map { [$0] } ?? []) + r.failed.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)" }
        // 写着写着关了 A4 / 总开关：这次是被关掉放弃的，不记失败（同收尾 astra #1）
        if !problems.isEmpty, MemoryHealthStore.isOn(.timeline) {
            MemoryHealthStore.recordError(.timeline, profileId: pid, message: problems.joined(separator: "；"), modelName: input.modelName)
        }
        if !r.written.isEmpty {
            Task { @MainActor in NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
        }
    }

    // MARK: - 真实接线：读窗口

    /// 碰到这段时间、开着记忆参与、没进回收站的窗口：主线消息（只要 id 和时间）+ 已落盘的 A2（严格读）。后台调。
    /// 对话 / 消息取不出 = 整体没读全；某个窗口的 A2 读不了 = 那个窗口标出来，它碰到的日子不拼
    static func windows(profileId: String, source: any ConversationSource, memoryRoot: URL, in interval: DateInterval) -> TimelineSkeleton.Source {
        let pid = profileId, start = interval.start, end = interval.end
        do {
            let convs = try source.windows(profileId: pid, updatedSince: start, includeTrashed: false)
                .filter { $0.memoryEnabled && $0.createTime < end }.map { ($0.id, $0.title) }
            let sessions = SessionSummaryStore.dir(root: memoryRoot)
            var out: [TimelineSkeleton.Window] = []
            for (id, title) in convs {
                guard let conv = try source.window(profileId: pid, idOrPrefix: id) else { continue }
                let messages = try SessionCloseout.mainPathNodesStrict(conv, source: source)
                    .map { TimelineSkeleton.Message(id: $0.id, date: $0.createTime) }
                guard messages.contains(where: { ($0.date ?? .distantPast) >= start && ($0.date ?? .distantFuture) < end }) else { continue }
                var summary: SessionSummary?
                var summaryError: String?
                do { summary = try SessionSummaryStore.loadStrict(conversationId: id, in: sessions) } catch {
                    summaryError = error.localizedDescription
                }
                out.append(TimelineSkeleton.Window(conversationId: id, title: title, messages: messages, summary: summary,
                                                   summaryError: summaryError))
            }
            return TimelineSkeleton.Source(windows: out)
        } catch {
            return TimelineSkeleton.Source(windows: [], error: error.localizedDescription)
        }
    }
}
