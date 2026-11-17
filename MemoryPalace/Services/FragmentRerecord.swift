import MemoryCore
import Foundation
import SwiftData

// MARK: - C2 跑一批（自动触发和「重新记这个窗口」共用同一条路：认领 → process → finish）

enum FragmentBatch {
    /// 跑一批要用的东西（主线程取好）
    struct Job {
        let conversationId: String
        let profileId: String
        let names: MemoryExtractor.Names
        let caller: SessionSegmentWriter.Caller
        let local: Bool
        let modelName: String
        let fallbackNote: String?
        /// 整段写手（云上模型）；不是 = 老写手（本机模型）
        let whole: Bool
        /// 每满几条写一次
        let every: Int
        let container: ModelContainer
        var watch: FragmentWatch = .shared
        /// 聊天时每轮本来就带着的内容（`FragmentResident`）：给整段写手和「C2 整理」。认领到一批、且不是 CC 窗口才在主线程取（见 `run`）；
        /// 不给 = 空
        var resident: (@MainActor () -> [FragmentVerdict.ResidentSection])? = nil
        /// 写成一批之后接不接「C2 整理」（开关另看 `FragmentDream.isOn`；本机模型不管这里给什么都不做）。只测写手那一圈的测试关掉
        var dreams = true
    }

    /// 这个窗口现在的主线；窗口没了 / 关了记忆 = nil
    static func path(_ job: Job) -> (title: String, nodes: [ConversationMessage])? {
        path(container: job.container, profileId: job.profileId, conversationId: job.conversationId)
    }

    static func path(container: ModelContainer, profileId: String, conversationId: String) -> (title: String, nodes: [ConversationMessage])? {
        let source = SwiftDataConversationSource(container: container)
        guard let conv = try? source.window(profileId: profileId, idOrPrefix: conversationId), conv.memoryEnabled else { return nil }
        return (conv.title, SessionCloseout.mainPathNodes(conv, source: source))
    }

    static func size(_ node: ConversationMessage) -> Int {
        CatalogOriginalText.body(of: node, cacheKey: node.id).count
    }

    /// 认领水位之后的一批写掉，按结果收水位。没认领到（不够一批 / 这个窗口正有一截在跑 / 窗口不参与）= nil。
    /// tail = 不够一批、满 `wholeTailMinimum` 条也写（只归整段写手）；label 进日志那条（「重新记 · 第 2 / 5 批」）；
    /// notify = 记下了新卡就发 `.memoryDidChange`（重新记自己在最后发一次）；manual = 她手动点的，不看格式失败的冷却
    @discardableResult
    static func run(_ job: Job, tail: Bool, label: String? = nil, notify: Bool = true, manual: Bool = false) async -> FragmentPool.Outcome? {
        guard job.whole || !tail, let path = Self.path(job) else { return nil }
        let context = ModelContext(job.container)
        context.autosaveEnabled = false
        let cid = job.conversationId, pid = job.profileId, nodes = path.nodes
        func message(_ node: ConversationMessage) -> FragmentPool.Message {
            FragmentPool.Message(id: node.id, role: node.role, content: CatalogOriginalText.body(of: node, cacheKey: node.id), date: node.createTime)
        }
        guard let claim = await job.watch.due(conversationId: cid, pathIds: nodes.map(\.id), dates: nodes.map(\.createTime),
                                              threshold: tail ? FragmentWatch.wholeTailMinimum : job.every,
                                              sizes: job.whole ? nodes.map(size) : nil, manual: manual)
        else { return nil }
        let msgs = nodes[claim.range].map(message)
        // CC 窗口每轮带的提示词在电脑上、app 拿不到：这一块传空
        var resident: [FragmentVerdict.ResidentSection] = []
        if !SessionCloseout.isCCPath(nodes), let take = job.resident { resident = await MainActor.run { take() } }
        var wholeContext: FragmentPool.WholeContext?
        if job.whole {
            let before = FragmentWatch.before(nodes, upTo: claim.range.lowerBound, size: size).map(message)
            wholeContext = FragmentPool.WholeContext(windowTitle: path.title, before: before,
                                                     known: FragmentPool.knownCards(profileId: pid, conversationId: cid, store: SwiftDataMemoryStore(), context: context),
                                                     resident: resident)
        }
        let written = FragmentCardIds()
        let note = [job.fallbackNote, label].compactMap { $0 }.joined(separator: " · ")
        let outcome = await MemoryWriteLog.metered {
            await FragmentPool.process(msgs, names: job.names, caller: job.caller,
                                       local: job.local, profileId: pid,
                                       modelName: job.modelName, fallbackNote: note.isEmpty ? nil : note, whole: wholeContext) { fragments in
                // 认领超时作废了就不落库（10-16 astra #3）
                guard await job.watch.holds(conversationId: cid, token: claim.token) else { throw FragmentPoolError.staleClaim }
                let ids = try FragmentPool.insert(fragments, messages: msgs, profileId: pid, conversationId: cid,
                                                  extractedBy: job.modelName, store: SwiftDataMemoryStore(), context: context)
                written.set(ids)
                return ids.count
            }
        }
        // 写成（含合法空包）/ 老写手整包拒收才挪水位；预算跳过 / 断网 / 请求或落库失败 / 整段写手整包拒收留着下次再来（同 API 那条路，10-16 astra #2）
        await job.watch.finish(conversationId: cid, claim: claim, outcome: outcome)
        if notify, case .done(let added) = outcome, added > 0 {
            await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
        }
        // 「C2 整理」：水位收好之后才做（没跑成不影响写手）；在这里等它做完，「重新记」的下一批就看得到这一批并 / 删之后的样子
        if job.dreams, !job.local, !written.ids.isEmpty {
            await FragmentDream.run(.init(profileId: pid, conversationId: cid, windowTitle: path.title, names: job.names, messages: msgs,
                                          cardIds: written.ids, resident: resident, modelName: job.modelName, caller: job.caller, label: label),
                                    container: job.container)
        }
        return outcome
    }
}

/// 写手那一包落库的卡 id（落库的闭包在别的任务里跑，带出来给「C2 整理」）
final class FragmentCardIds: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID] = []

    func set(_ ids: [UUID]) {
        lock.lock(); stored = ids; lock.unlock()
    }

    var ids: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

// MARK: - 重新记这个窗口（对话 ⋯）：水位挪回起点，照常一批一批跑到追上

/// 装新写法之前聊过的内容不会被记（第一次见到窗口时水位直接放在最后一条）。她点一下 = 把这一个窗口从起点到现在用现行写手记一遍。
/// 起点 = 「记忆从哪天开始」之后的第一条，没设就从窗口第一条。不另写流程：`FragmentWatch.rewind` 之后反复 `FragmentBatch.run`
enum FragmentRerecord {
    struct Plan: Equatable {
        /// 从主线第几条开始读（下标）
        let start: Int
        /// 要读几条
        let messages: Int
        /// 这些条一共多少字
        let chars: Int
        /// 大约分几批
        let batches: Int
        /// 接着上次没记完的（水位不挪）
        let resumed: Bool
        /// 开始那条的时间
        let from: Date?
    }

    /// resumeAt = 上次重新记停在哪（水位之后第一条的下标）；nil = 从起点来
    static func plan(dates: [Date?], sizes: [Int], startDay: Date?, every: Int, resumeAt: Int? = nil) -> Plan {
        let start = min(resumeAt ?? MemoryStartDay.firstAllowedIndex(dates, startDay: startDay), sizes.count)
        var at = start, batches = 0
        while let end = FragmentPool.wholeSpanEnd(sizes: sizes, from: at, every: every, tail: true) {
            batches += 1
            at = end
        }
        return Plan(start: start, messages: sizes.count - start, chars: sizes[start...].reduce(0, +), batches: batches,
                    resumed: resumeAt != nil, from: dates.indices.contains(start) ? dates[start] : nil)
    }

    /// 往高里估的 token：每批调两次，每次都带提示词、前文、已记的卡和这一批原文（一个字算一个 token），第二次多带初稿。
    /// dream = 写完还接「C2 整理」：每批再多一次，带这一批原文、聊天时本来就带着的内容（按上限算）、提示词和卡
    static func estimatedUsage(_ plan: Plan, dream: Bool = false) -> (input: Int, output: Int) {
        let overhead = 5_000 + FragmentPool.wholeBeforeChars + 4_000
        var input = 2 * (plan.chars + plan.batches * overhead) + plan.batches * 3_000
        var output = plan.batches * 2 * 3_000
        if dream {
            let more = dreamUsage(chars: plan.chars, batches: plan.batches)
            input += more.input
            output += more.output
        }
        return (input, output)
    }

    /// 「C2 整理」那一次调用往高里估的 token：这一批原文、聊天时本来就带着的内容（按上限算）、提示词和卡。手动「重新整理」也用它
    static func dreamUsage(chars: Int, batches: Int) -> (input: Int, output: Int) {
        (chars + batches * (FragmentVerdict.Limits().maxResidentChars + 6_000), batches * 3_000)
    }

    /// 确认框问什么；canRun = false 时只有一个「好」
    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let conversationId: String
        let profileId: String
        let plan: Plan
        let text: String
        let canRun: Bool

        static func == (a: Prompt, b: Prompt) -> Bool { a.id == b.id }
    }

    static func money(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    static func spend(_ usd: Double) -> String {
        usd < 0.01 ? "估计花不到 $0.01" : "估计花 \(money(usd)) 左右"
    }

    /// 确认框的字（纯函数，可测）。cost = 估计花多少（模型没标价 = nil）；budget = 写入预算还剩多少（没开 = nil）；
    /// dream = 写完还接「C2 整理」（每批多一次调用，已有的卡可能被并进去的新情况改掉）
    static func confirmText(_ plan: Plan, startDay: Date?, cost: Double?, budget: Double?, dream: Bool = false) -> (text: String, canRun: Bool) {
        guard plan.batches > 0 else {
            return (plan.resumed ? "上次没记完的只剩 \(plan.messages) 条，不到 \(FragmentPool.wholeTailMinimum) 条，不用再记。"
                                 : "从起点到现在只有 \(plan.messages) 条，不到 \(FragmentPool.wholeTailMinimum) 条，没有要记的。", false)
        }
        if let budget, budget <= 0 {
            return ("写入预算已经用完，现在记不了。去 设置 › 记忆 把写入预算调高或重置已用，再回来点。", false)
        }
        let day = plan.from.map { MemoryStartDay.format($0) } ?? "第一条"
        var lines: [String] = []
        if plan.resumed {
            lines.append("接着上次没记完的：从 \(day) 起还有 \(plan.messages) 条要读，")
        } else if startDay != nil {
            lines.append("从「记忆从哪天开始」之后的第一条（\(day)）起，有 \(plan.messages) 条要读，")
        } else {
            lines.append("没设「记忆从哪天开始」，从这个窗口第一条（\(day)）起，有 \(plan.messages) 条要读，")
        }
        lines[0] += dream ? "大约分 \(plan.batches) 批，每批调三次模型（写一次、核对一次、写完自动整理一次）。"
                          : "大约分 \(plan.batches) 批，每批调两次模型（写一次、核对一次）。"
        switch (cost, budget) {
        case (let cost?, let budget?):
            lines.append(cost <= budget ? "\(spend(cost))，写入预算还剩 \(money(budget))，够。"
                                        : "\(spend(cost))，写入预算只剩 \(money(budget))，不够：写到预算用完会停下，下次再点接着记。")
        case (let cost?, nil):
            lines.append("\(spend(cost))；写入预算没开，不限。")
        case (nil, let budget?):
            lines.append("这个模型没标价，估不出花多少；写入预算还剩 \(money(budget))，用完会停下，下次再点接着记。")
        case (nil, nil):
            lines.append("这个模型没标价，估不出花多少；写入预算没开，不限。")
        }
        lines.append(dream ? "新条目里和已有的说同一件事的会并进去，已有的那条可能跟着改（记忆日志里每一笔能 Undo）。以前这个窗口记过又被删掉的事，可能会再出现。"
                           : "这个窗口已有的记忆条目不动。以前这个窗口记过又被删掉的事，可能会再出现。")
        return (lines.joined(separator: "\n"), true)
    }

    enum Stop: Equatable {
        /// 追上了
        case caughtUp
        /// 这一批没写成、水位没动：预算闸 / 模型没回 / 开关关了 / 认领作废
        case skipped
        /// 这一批请求或落库失败 / 整包格式不对（记了失败），水位没动
        case failed
        /// 别的触发一直占着这个窗口
        case busy
        /// 窗口没了 / 关了记忆
        case gone
        /// 水位不在现在这条主线上（中途切了分支）
        case lostMark
    }

    struct Report: Equatable {
        /// 写完了几批（水位挪过去的）
        var batches = 0
        /// 新记下几条
        var added = 0
        var stop: Stop = .caughtUp
    }

    /// 她确认了：不是接着跑的先把水位挪回起点，再一批一批跑。这个窗口正有一截在跑、挪不了 = `.busy`
    static func begin(_ job: FragmentBatch.Job, plan: Plan, startDay: Date?, pause: Duration = .seconds(3), maxWaits: Int = 100,
                      progress: (_ batch: Int, _ of: Int) async -> Void = { _, _ in }) async -> Report {
        if !plan.resumed {
            guard let path = FragmentBatch.path(job) else { return Report(stop: .gone) }
            let dates = path.nodes.map(\.createTime)
            guard await job.watch.rewind(conversationId: job.conversationId, pathIds: path.nodes.map(\.id), dates: dates,
                                         start: MemoryStartDay.firstAllowedIndex(dates, startDay: startDay)) else { return Report(stop: .busy) }
        }
        return await run(job, total: plan.batches, pause: pause, maxWaits: maxWaits, progress: progress)
    }

    /// 一批接一批跑到追上（水位之后不到 `wholeTailMinimum` 条）；哪一批没写成就停在它前面，水位留在上一批末尾。
    /// 每批都重读主线：跑的时候她接着聊，新消息排在后面照样认领。total = 开跑前估的批数（只用来报进度）
    static func run(_ job: FragmentBatch.Job, total: Int, pause: Duration = .seconds(3), maxWaits: Int = 100,
                    progress: (_ batch: Int, _ of: Int) async -> Void = { _, _ in }) async -> Report {
        var report = Report()
        var waits = 0
        while true {
            guard let path = FragmentBatch.path(job) else { report.stop = .gone; break }
            guard let backlog = await job.watch.backlog(conversationId: job.conversationId, pathIds: path.nodes.map(\.id)) else {
                report.stop = .lostMark
                break
            }
            guard backlog >= FragmentWatch.wholeTailMinimum else {
                await job.watch.endRedo(conversationId: job.conversationId)
                break
            }
            let number = report.batches + 1, of = max(total, number)
            await progress(number, of)
            let label = "重新记 · 第 \(number) / \(of) 批"
            var outcome = await FragmentBatch.run(job, tail: false, label: label, notify: false, manual: true)
            if outcome == nil { outcome = await FragmentBatch.run(job, tail: true, label: label, notify: false, manual: true) }
            guard let outcome else {
                // 还有积压却没认领到 = 自动触发正占着这个窗口，等它交回
                waits += 1
                guard waits <= maxWaits else { report.stop = .busy; break }
                try? await Task.sleep(for: pause)
                continue
            }
            waits = 0
            guard outcome.settled else {
                report.stop = outcome == .skipped ? .skipped : .failed
                break
            }
            report.batches += 1
            if case .done(let added) = outcome { report.added += added }
        }
        return report
    }

    /// 跑完的提示（纯函数，可测）。budgetOut = 停下时写入预算已经用完
    static func summary(_ report: Report, budgetOut: Bool = false) -> String {
        let done = report.batches > 0 ? "写完 \(report.batches) 批、记下 \(report.added) 条" : "一批都没写"
        switch report.stop {
        case .caughtUp: return "📝 重新记完了：\(done)"
        case .skipped: return budgetOut ? "📝 写入预算用完，停下了（\(done)）。下次再点接着记"
                                        : "📝 有一批没写成（预算闸拦下或模型没回），停下了（\(done)）。再点接着记"
        case .failed: return "📝 有一批出错了，停下了（\(done)），看记忆日志。再点接着记"
        case .busy: return "📝 后台一直在写这个窗口，先停下（\(done)）。稍后再点接着记"
        case .gone: return "📝 这个窗口不参与记忆了，停下了（\(done)）"
        case .lostMark: return "📝 对话切了分支，停下了（\(done)）"
        }
    }
}

/// 「重新记」的确认框和进度（只给界面看）
@MainActor
@Observable
final class FragmentRerecordStatus {
    static let shared = FragmentRerecordStatus()
    /// 等她确认的那一问
    var prompt: FragmentRerecord.Prompt?
    /// 正在重新记的窗口：第几批 / 共几批
    private(set) var running: [String: (batch: Int, of: Int)] = [:]
    private var preparing = false

    /// 点了菜单：后台数一数要读多少，数完弹确认框
    func ask(conversationId: String, profileId: String) {
        guard !preparing, prompt == nil, running[conversationId] == nil else { return }
        preparing = true
        Task {
            prompt = await SessionCloseoutTrigger.shared.prepareRerecord(conversationId: conversationId, profileId: profileId)
            preparing = false
        }
    }

    /// 她确认了：跑，跑完把结果交给 notice
    func start(_ prompt: FragmentRerecord.Prompt, notice: @escaping @MainActor (String) -> Void) {
        let cid = prompt.conversationId
        guard running[cid] == nil else { return }
        running[cid] = (1, max(prompt.plan.batches, 1))
        Task {
            let text = await SessionCloseoutTrigger.shared.rerecord(prompt) { batch, of in
                await MainActor.run { self.running[cid] = (batch, of) }
            }
            running[cid] = nil
            notice(text)
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
    }
}
