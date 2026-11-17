import MemoryCore
import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

/// 手动「重新整理一遍」（记忆格 ⋯ 和 设置 › 记忆 › 写入 › C2 碎片池 两处入口，调的是同一个东西）：
/// 把这一层楼还在 Draft 的卡（C2 写的、没删、她没批过没改过没钉住）按来源窗口分批，逐批走现有的「C2 整理」
/// （`FragmentDream.run`：同一份提示词、同一套落库 / 审计日志 / Undo / 记录存盘、同一条全 app 的队）。
/// 每批的原文 = 那个窗口的主线照写手的切法切出来的一截（`FragmentPool.wholeSpanEnd`），卡按出处那条消息落在哪一截归批，没有卡的那几截不调。
/// 来源窗口没了 / 不参与记忆、出处那条消息不在主线上的卡：跳过并报数，不拿别的原文瞎判。
/// 停在哪一批前面，那批往后的卡都原样；再点接着整理这一趟里还没下过结论的
enum FragmentReorganize {
    /// 日志那条后面带的（「手动整理 · 第 2 / 5 批」）
    static let label = "手动整理"

    /// 现在能不能点；不能 = 写给她看的原因（两个入口都读这一句）。本机模型装不下这份材料，和自动那条路一样不做
    static func blocked(master: Bool, facts: Bool, choice: String) -> String? {
        if !master || !facts { return "记忆总开关或 C2 原子事实关着，整理不了" }
        if FragmentModelRoute.localModelId(choice: choice) != nil { return "C2 选的是本机模型，装不下整理要读的材料；换成云上模型才能整理" }
        return nil
    }

    static func blocked(_ defaults: UserDefaults = .standard) -> String? {
        blocked(master: MemoryFlags.masterEnabled, facts: MemoryFlags.factsEnabled, choice: defaults.string(forKey: FragmentModelRoute.key) ?? "")
    }

    // MARK: - 要整理哪些卡

    struct Card: Equatable, Sendable {
        let id: UUID
        let conversationId: String?
        let nodeId: String?
    }

    /// C2 写的、没删、她没批过没改过没钉住。她批过 / 改过 / 钉住的只当「已有的卡」
    static func isDraft(_ m: Memory) -> Bool {
        m.isFragment && FragmentDream.isFreshDraft(m)
    }

    /// 这一层的 Draft，建得早的在前。since = 上次没整理完的那一趟是什么时候开始的：那以后下过结论、还留在 Draft 的不再送
    static func cards(profileId: String, context: ModelContext, since: Date?, notes: [UUID: FragmentDreamNotes.Note]) -> [Card] {
        SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
            .filter(isDraft)
            .filter { m in since.map { (notes[m.id]?.at ?? .distantPast) < $0 } ?? true }
            .sorted { $0.createdAt < $1.createdAt }
            .map { Card(id: $0.id, conversationId: $0.sourceConversationId, nodeId: $0.sourceNodeId) }
    }

    // MARK: - 分批（纯函数）

    struct Batch: Equatable, Sendable {
        /// 原文是主线的哪一截（下标）
        let range: Range<Int>
        let cards: [UUID]
    }

    /// 主线照写手的切法从头切成一截一截；最后不够一批的并进前一截（整个窗口都不够一批 = 自己一截）
    static func spans(sizes: [Int], every: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var at = 0
        while let end = FragmentPool.wholeSpanEnd(sizes: sizes, from: at, every: every, tail: true) {
            out.append(at..<end)
            at = end
        }
        guard at < sizes.count else { return out }
        out.append((out.popLast()?.lowerBound ?? 0)..<sizes.count)
        return out
    }

    /// 一个窗口里的卡落到哪几批（只留有卡的那几截，卡按出处先后）；missing = 出处那条不在主线上的
    static func place(_ cards: [Card], pathIds: [String], sizes: [Int], every: Int) -> (batches: [Batch], missing: Int) {
        let index = Dictionary(pathIds.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let placed = cards.enumerated().compactMap { offset, card in
            card.nodeId.flatMap { index[$0] }.map { (id: card.id, at: $0, order: offset) }
        }.sorted { ($0.at, $0.order) < ($1.at, $1.order) }
        let batches = spans(sizes: sizes, every: every).compactMap { span -> Batch? in
            let inside = placed.filter { span.contains($0.at) }.map(\.id)
            return inside.isEmpty ? nil : Batch(range: span, cards: inside)
        }
        return (batches, cards.count - placed.count)
    }

    struct Window: Equatable, Sendable {
        let conversationId: String
        let cards: [Card]
    }

    struct Plan: Equatable, Sendable {
        /// 有卡要整理的窗口（最早那张卡建得早的在前）
        var windows: [Window] = []
        /// 要整理几张（出处找得到的）
        var cards = 0
        /// 大约分几批
        var batches = 0
        /// 这些批的原文一共多少字
        var chars = 0
        /// 出处找不到、跳过的
        var missing = 0
        /// 其中不在 `windows` 里的（卡上没记来源窗口、窗口没了 / 不参与记忆、整个窗口的卡出处都不在了）
        var orphans = 0
        /// 接着上次没整理完的那一趟
        var resumed = false
    }

    /// path = 这个窗口现在的主线（每条的 id 和字数）；窗口没了 / 不参与记忆 = nil
    static func plan(_ cards: [Card], resumed: Bool, every: Int, path: (String) -> (ids: [String], sizes: [Int])?) -> Plan {
        var plan = Plan(resumed: resumed)
        var order: [String] = []
        var groups: [String: [Card]] = [:]
        for card in cards {
            guard let cid = card.conversationId else { plan.orphans += 1; continue }
            if groups[cid] == nil { order.append(cid) }
            groups[cid, default: []].append(card)
        }
        for cid in order {
            let group = groups[cid] ?? []
            guard let path = path(cid) else { plan.orphans += group.count; continue }
            let placed = place(group, pathIds: path.ids, sizes: path.sizes, every: every)
            guard !placed.batches.isEmpty else { plan.orphans += group.count; continue }
            plan.windows.append(Window(conversationId: cid, cards: group))
            plan.batches += placed.batches.count
            plan.cards += group.count - placed.missing
            plan.chars += placed.batches.reduce(0) { $0 + path.sizes[$1.range].reduce(0, +) }
            plan.missing += placed.missing
        }
        plan.missing += plan.orphans
        return plan
    }

    // MARK: - 上次没整理完的那一趟（存它开始的时间，不进库）

    static func sinceKey(_ profileId: String) -> String { "mem_c2_reorganize_since.\(profileId)" }

    static func unfinishedSince(profileId: String, defaults: UserDefaults = .standard) -> Date? {
        let at = defaults.double(forKey: sinceKey(profileId))
        return at > 0 ? Date(timeIntervalSince1970: at) : nil
    }

    /// 这一趟算不算完：走到了头，而且没有漏下的批（一批都没成也算完——再点从头来，免得一直只补同样那几批）
    static func isComplete(_ report: Report) -> Bool {
        report.stop == .finished && (report.failed == 0 || report.batches == 0)
    }

    // MARK: - 确认框

    /// 确认框问什么；canRun = false 时只有一个「OK」
    struct Prompt: Identifiable, Equatable, Sendable {
        let id = UUID()
        let profileId: String
        /// 哪个入口问的（那个入口自己的记号）：确认框只在问的那一处弹
        let host: UUID
        let plan: Plan
        let text: String
        let canRun: Bool

        static func == (a: Prompt, b: Prompt) -> Bool { a.id == b.id }
    }

    static func missingText(_ count: Int) -> String {
        "\(count) 张出处找不到（来源窗口删了、不参与记忆，或那条消息不在了）"
    }

    /// 确认框的字（纯函数，可测）。cost = 估计花多少（模型没标价 = nil）；budget = 写入预算还剩多少（没开 = nil）；
    /// needsReview = 「整理留下的卡要我批」开没开
    static func confirmText(_ plan: Plan, cost: Double?, budget: Double?, needsReview: Bool) -> (text: String, canRun: Bool) {
        guard plan.batches > 0 else {
            return (plan.missing > 0 ? "没有能整理的：Draft 里的 \(missingText(plan.missing))，没法对着原文整理。"
                                     : "这一层没有还在 Draft 的记忆条目，没有要整理的。", false)
        }
        if let budget, budget <= 0 {
            return ("写入预算已经用完，现在整理不了。去 设置 › 记忆 把写入预算调高或重置已用，再回来点。", false)
        }
        var lines = [(plan.resumed ? "接着上次没整理完的：还有 \(plan.cards) 条 Draft 记忆条目，" : "这一层有 \(plan.cards) 条 Draft 记忆条目要整理，")
                     + "出自 \(plan.windows.count) 个窗口，大约分 \(plan.batches) 批，每批调一次模型。"]
        if plan.missing > 0 { lines.append("另有 \(missingText(plan.missing))，跳过不整理。") }
        switch (cost, budget) {
        case (let cost?, let budget?):
            lines.append(cost <= budget ? "\(FragmentRerecord.spend(cost))，写入预算还剩 \(FragmentRerecord.money(budget))，够。"
                                        : "\(FragmentRerecord.spend(cost))，写入预算只剩 \(FragmentRerecord.money(budget))，不够：整理到预算用完会停下，下次再点接着整理。")
        case (let cost?, nil):
            lines.append("\(FragmentRerecord.spend(cost))；写入预算没开，不限。")
        case (nil, let budget?):
            lines.append("这个模型没标价，估不出花多少；写入预算还剩 \(FragmentRerecord.money(budget))，用完会停下，下次再点接着整理。")
        case (nil, nil):
            lines.append("这个模型没标价，估不出花多少；写入预算没开，不限。")
        }
        lines.append("删掉、并进已有的、改对直接生效，已有的条目可能跟着改（记忆日志里每一笔能 Undo）。"
                     + (needsReview ? "留下的和拿不准的还在 Draft。" : "留下的直接算批过，只有拿不准的留在 Draft。"))
        return (lines.joined(separator: "\n"), true)
    }

    /// 点了按钮先数一数（后台调）：几张卡、几个窗口、大约几批、估多少钱。
    /// cost = 按这一轮用的模型算价（没标价 = nil）；budget = 写入预算还剩多少
    static func prepare(profileId: String, host: UUID, container: ModelContainer, every: Int, defaults: UserDefaults = .standard,
                        memoryRoot: URL? = nil, cost: (_ input: Int, _ output: Int) -> Double? = { _, _ in nil },
                        budget: Double? = nil) -> Prompt {
        let notes = FragmentDreamNotes.load(memoryRoot: memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId))
        let context = ModelContext(container)
        func made(since: Date?) -> Plan {
            Self.plan(cards(profileId: profileId, context: context, since: since, notes: notes), resumed: since != nil, every: every) { cid in
                FragmentBatch.path(container: container, profileId: profileId, conversationId: cid).map {
                    ($0.nodes.map(\.id), $0.nodes.map(FragmentBatch.size))
                }
            }
        }
        var plan = made(since: unfinishedSince(profileId: profileId, defaults: defaults))
        if plan.resumed, plan.batches == 0 {
            // 上次那一趟其实没有剩下能整理的了：当新的一趟
            defaults.removeObject(forKey: sinceKey(profileId))
            plan = made(since: nil)
        }
        let usage = FragmentRerecord.dreamUsage(chars: plan.chars, batches: plan.batches)
        let confirm = confirmText(plan, cost: plan.batches > 0 ? cost(usage.input, usage.output) : nil, budget: budget,
                                  needsReview: FragmentDream.needsReview(defaults))
        return Prompt(profileId: profileId, host: host, plan: plan, text: confirm.text, canRun: confirm.canRun)
    }

    // MARK: - 跑

    enum Stop: Equatable {
        /// 走到头了
        case finished
        /// 她点了 Stop
        case stopped
        /// 这一批被拦下没做：预算闸 / 模型没回
        case skipped
        /// 这一批请求出错 / 结论没存上（原因）
        case failed(String)
        /// app 进了后台
        case background
        /// 记忆或 C2 关了、换成了本机模型、楼层没了
        case unavailable
    }

    struct Report: Equatable {
        /// 整理完了几批
        var batches = 0
        /// 模型两次都没交出合格结论、跳过去的批（卡原样）
        var failed = 0
        var counts: [FragmentDream.Applied: Int] = [:]
        /// 出处找不到、跳过的卡
        var missing = 0
        var stop: Stop = .finished
    }

    /// 她点的 Stop（跑的那头每批开始前看一眼）
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        func set() {
            lock.lock(); stopped = true; lock.unlock()
        }

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }
    }

    @MainActor
    static func appInBackground() -> Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    /// 她确认了：不是接着跑的先记下这一趟从什么时候开始，跑完（没有漏下的批）把这个记号清掉。
    /// 停在半路 / 有批没整理成 = 记号留着，再点只送这一趟里还没下过结论的
    static func begin(_ plan: Plan, profileId: String, every: Int, job: (String) async -> FragmentBatch.Job?,
                      defaults: UserDefaults = .standard, memoryRoot: URL? = nil, now: Date = Date(),
                      shouldStop: () -> Bool = { false }, inBackground: () async -> Bool = { false },
                      progress: (_ batch: Int, _ of: Int) async -> Void = { _, _ in }) async -> Report {
        if !plan.resumed { defaults.set(now.timeIntervalSince1970, forKey: sinceKey(profileId)) }
        let report = await run(plan, profileId: profileId, every: every, job: job, defaults: defaults, memoryRoot: memoryRoot,
                               shouldStop: shouldStop, inBackground: inBackground, progress: progress)
        if isComplete(report) { defaults.removeObject(forKey: sinceKey(profileId)) }
        return report
    }

    /// 一个窗口接一个窗口、一批接一批跑。每到一个窗口重读它的主线、重新归批（确认之后她可能又聊了、切了分支）；
    /// 每批送去时库里什么样由 `FragmentDream` 自己看（她中途批掉 / 改掉的卡不会被动）。
    /// job = 这个窗口这一轮用的模型、名字、调用口（`SessionCloseoutTrigger.fragmentJob`）。
    /// 被拦下 / 出错 / 她点 Stop / 进后台 = 停在那一批前面；模型两次格式都不对的那批跳过去接着跑
    static func run(_ plan: Plan, profileId: String, every: Int, job: (String) async -> FragmentBatch.Job?,
                    defaults: UserDefaults = .standard, memoryRoot: URL? = nil,
                    shouldStop: () -> Bool = { false }, inBackground: () async -> Bool = { false },
                    progress: (_ batch: Int, _ of: Int) async -> Void = { _, _ in }) async -> Report {
        var report = Report(missing: plan.orphans)
        var number = 0
        windows: for window in plan.windows {
            guard MemoryHealthStore.isOn(.extract), let job = await job(window.conversationId), !job.local else {
                report.stop = .unavailable
                break
            }
            guard let path = FragmentBatch.path(job) else {
                report.missing += window.cards.count
                continue
            }
            let nodes = path.nodes
            let placed = place(window.cards, pathIds: nodes.map(\.id), sizes: nodes.map(FragmentBatch.size), every: every)
            report.missing += placed.missing
            guard !placed.batches.isEmpty else { continue }
            // CC 窗口每轮带的提示词在电脑上、app 拿不到：这一块传空（同自动那条路）
            var resident: [FragmentVerdict.ResidentSection] = []
            if !SessionCloseout.isCCPath(nodes), let take = job.resident { resident = await MainActor.run { take() } }
            for batch in placed.batches {
                if shouldStop() { report.stop = .stopped; break windows }
                if await inBackground() { report.stop = .background; break windows }
                guard MemoryHealthStore.isOn(.extract) else { report.stop = .unavailable; break windows }
                number += 1
                let of = max(plan.batches, number)
                await progress(number, of)
                let messages = nodes[batch.range].map {
                    FragmentPool.Message(id: $0.id, role: $0.role, content: CatalogOriginalText.body(of: $0, cacheKey: $0.id), date: $0.createTime)
                }
                let input = FragmentDream.Input(profileId: profileId, conversationId: window.conversationId, windowTitle: path.title,
                                                names: job.names, messages: messages, cardIds: batch.cards, resident: resident,
                                                modelName: job.modelName, caller: job.caller, label: "\(label) · 第 \(number) / \(of) 批")
                // nil = 这批的卡她都动过了，没有要判的
                guard let summary = await FragmentDream.run(input, container: job.container, defaults: defaults,
                                                            memoryRoot: memoryRoot, manual: true) else { continue }
                if summary.skipped { report.stop = .skipped; break windows }
                if let failure = summary.failure {
                    guard summary.malformed else { report.stop = .failed(failure); break windows }
                    report.failed += 1
                    continue
                }
                report.batches += 1
                for (kind, count) in summary.counts { report.counts[kind, default: 0] += count }
            }
        }
        return report
    }

    /// 跑完那一句（纯函数，可测）。budgetOut = 停下时写入预算已经用完
    static func summary(_ report: Report, budgetOut: Bool = false, needsReview: Bool = true) -> String {
        let tally = FragmentDream.Summary(recordId: "", counts: report.counts).note(total: 0, needsReview: needsReview, label: nil)
        let done = report.batches > 0 ? "整理了 \(report.batches) 批：\(tally)" : "一批都没整理"
        var extra: [String] = []
        if report.missing > 0 { extra.append("跳过 \(report.missing) 张（出处找不到）") }
        if report.failed > 0 { extra.append("\(report.failed) 批模型没交出合格的结论，条目还在 Draft") }
        let tail = extra.isEmpty ? "" : "；" + extra.joined(separator: "；")
        let again = "再点接着整理剩下的"
        switch report.stop {
        case .finished:
            if report.batches == 0, report.failed == 0 { return "没有整理到条目" + tail }
            return (report.batches > 0 ? "整理完了，\(report.batches) 批：\(tally)" : "一批都没整理成") + tail
                + (report.failed > 0 && report.batches > 0 ? "，再点只补这几批" : "")
        case .stopped: return "停下了（\(done)）\(tail)。\(again)"
        case .skipped: return (budgetOut ? "写入预算用完，停下了（\(done)）\(tail)。调高预算后\(again)"
                                         : "有一批没做成（预算闸拦下或模型没回），停下了（\(done)）\(tail)。\(again)")
        case .failed(let why): return "有一批出错了（\(why)），停下了（\(done)）\(tail)。细节在记忆日志，\(again)"
        case .background: return "app 进了后台，停下了（\(done)）\(tail)。\(again)"
        case .unavailable: return "现在整理不了，停下了（\(done)）\(tail)：记忆或 C2 原子事实关了，或 C2 换成了本机模型"
        }
    }
}

/// 「重新整理」的确认框、进度和结果（只给界面看）。两个入口看的是同一份
@MainActor
@Observable
final class FragmentReorganizeStatus {
    static let shared = FragmentReorganizeStatus()

    struct Running: Equatable {
        var batch: Int
        var of: Int
        /// 她点了 Stop，等这一批跑完
        var stopping = false
    }

    /// 等她确认的那一问
    var prompt: FragmentReorganize.Prompt?
    /// 正在数的楼层
    private(set) var counting: Set<String> = []
    /// 正在整理的楼层：第几批 / 共几批
    private(set) var running: [String: Running] = [:]
    /// 每层上一次跑完的那句
    private(set) var results: [String: String] = [:]
    private var flags: [String: FragmentReorganize.StopFlag] = [:]

    /// 点了按钮：后台数一数，数完在问的那个入口（host）弹确认框
    func ask(profileId: String, host: UUID) {
        guard !profileId.isEmpty, counting.isEmpty, running[profileId] == nil else { return }
        counting.insert(profileId)
        results[profileId] = nil
        prompt = nil
        Task {
            let asked = await SessionCloseoutTrigger.shared.prepareReorganize(profileId: profileId, host: host)
            counting.remove(profileId)
            if let asked { prompt = asked } else { results[profileId] = FragmentReorganize.blocked() ?? "现在整理不了" }
        }
    }

    /// 她确认了：跑，跑完留一句结果
    func start(_ prompt: FragmentReorganize.Prompt) {
        let pid = prompt.profileId
        guard running[pid] == nil else { return }
        let flag = FragmentReorganize.StopFlag()
        flags[pid] = flag
        running[pid] = Running(batch: 1, of: max(prompt.plan.batches, 1))
        Task {
            let text = await SessionCloseoutTrigger.shared.reorganize(prompt, shouldStop: { flag.isSet }) { batch, of in
                await MainActor.run {
                    self.running[pid]?.batch = batch
                    self.running[pid]?.of = of
                }
            }
            running[pid] = nil
            flags[pid] = nil
            results[pid] = text
        }
    }

    /// 这一批跑完就停
    func stop(profileId: String) {
        flags[profileId]?.set()
        running[profileId]?.stopping = true
    }

    func dismissResult(profileId: String) {
        results[profileId] = nil
    }
}
