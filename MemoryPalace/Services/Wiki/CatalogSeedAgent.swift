import Foundation

// MARK: - 种子：同一个 CatalogAgent 循环 / Deps / 后端，跑一个任务（没有日常的轮数、回执字数、单主题上限，也没有替代闸门）。
// 出目录：一段对话读完全部原料交目录；写正文：每个已批目录项单开一段对话，只带这一项的原料（read 回执那一版）

extension CatalogAgent {
    /// 本机后端的生成上限（云端按模型默认）；整份目录一次交，留够
    static let seedMaxTokens = 16_000
    /// 同一页连续这么多轮没交出合格的这一页就停（存 checkpoint、不记完成、不再自动请求）
    static let pageStallLimit = 3

    struct SeedJob {
        var task: CatalogSeedTask
        /// 还没读的原料的正文（恢复时只为没读的现取；读过的在回合里）
        var materials: [String: CatalogSeedMaterials.Item]
        var wiki: WikiStore
        var names: MemoryExtractor.Names
        var run: CatalogRunRecord
        /// 审批后继续：审批结果（只写进整理记录；写正文每页单开一段对话，不发给模型）
        var control: String? = nil
        var now: Date = Date()
    }

    enum SeedStop: Equatable {
        /// 目录交了，等批
        case outlineSubmitted
        /// 获批的页都交了正文（剩下的等批，或全写完）
        case paused
        case emptyOutline(String)
        case cancelled
        case blocked(String)
        case failed(String)

        /// 正常停在等批（不是被停 / 出错 / 被拦）
        var isNormal: Bool { self == .outlineSubmitted || self == .paused }
    }

    struct SeedOutcome {
        var task: CatalogSeedTask
        var stop: SeedStop
        var outlineItems = 0
        /// 这次交的正文提案
        var pages: [String] = []
        var items = 0
        var dropped = 0
        /// 最后一次 checkpoint 存成了
        var persisted = true
    }

    func runSeed(_ job: SeedJob) async -> SeedOutcome {
        let token = cancelToken
        return await withTaskCancellationHandler {
            await runSeedCancellable(job)
        } onCancel: {
            token.cancel()
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func runSeedCancellable(_ job: SeedJob) async -> SeedOutcome {
        var task = job.task
        let taskId = task.id
        let wiki = job.wiki
        let proposals = WikiProposalStore(wiki: wiki)
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let run = job.run
        currentRun = run
        currentAnchor = nil
        var out = SeedOutcome(task: task, stop: .cancelled)
        let system = CatalogSeedPrompts.system(names: job.names, entry: task.entry, day: CatalogSurvey.day(task.createdAt))
        let pageSystem = CatalogSeedPrompts.pageSystem(names: job.names, entry: task.entry, day: CatalogSurvey.day(task.createdAt))
        var history = task.history.map { (role: $0.role, content: $0.content) }
        var turns = task.turns.map(\.toolTurn)
        var traced: (history: Int, turns: Int)?
        /// 写正文时正在写的那一页（单开的对话）
        var pageItem = task.page?.item
        var pageHistory = task.page?.history.map { (role: $0.role, content: $0.content) } ?? []
        var pageTurns = task.page?.turns.map(\.toolTurn) ?? []
        var pagePending = task.page?.pending
        var pageKey = task.page?.key
        /// 上次停在「连续无进展」：这次是她点了继续（或批了别的又续上），重新数
        var pageStalls = (task.page?.stalls ?? 0) >= Self.pageStallLimit ? 0 : (task.page?.stalls ?? 0)
        var pageTraced: (history: Int, turns: Int)?
        let backend = deps.makeBackend()
        self.backend = backend

        func sync() {
            task.history = history.map { .init(role: $0.role, content: $0.content) }
            task.turns = turns.map(CatalogSeedTask.Turn.init)
            task.page = pageItem.map {
                CatalogSeedTask.PageSession(item: $0, history: pageHistory.map { .init(role: $0.role, content: $0.content) },
                                            turns: pageTurns.map(CatalogSeedTask.Turn.init), pending: pagePending, key: pageKey, stalls: pageStalls)
            }
        }

        func persist() async -> String? {
            sync()
            let snapshot = task
            let error = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try tasks.save(snapshot)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            out.persisted = error == nil
            return error
        }

        func loadOutline() async -> WikiProposal? {
            await Task.detached(priority: .utility) { proposals.load(taskId) }.value
        }

        func clearPage() {
            pageItem = nil
            pageHistory = []
            pageTurns = []
            pagePending = nil
            pageKey = nil
            pageStalls = 0
        }

        func finish(_ stop: SeedStop) async -> SeedOutcome {
            out.stop = stop
            // 正在写的那一页已经交上了（回退交上一稿、对账补记）：这一页的对话不留
            if let current = pageItem, !CatalogSeedTask.unwritten(await loadOutline()).contains(where: { $0.id == current }) { clearPage() }
            let reason: String
            switch stop {
            case .outlineSubmitted:
                task.state = .waiting
                task.note = nil
                reason = "目录交了，等批"
            case .paused:
                task.state = .waiting
                task.note = nil
                reason = "获批的页都交了正文"
            case .emptyOutline(let why):
                task.state = .ended
                task.note = "目录是空的：\(why)"
                task.endedAt = job.now
                reason = task.note ?? ""
            case .cancelled:
                task.state = .stopped
                task.note = "停了"
                reason = "停了"
            case .blocked(let why):
                task.state = .stopped
                task.note = "被拦：\(why)"
                reason = task.note ?? ""
            case .failed(let note):
                task.state = .stopped
                task.note = note
                reason = note
            }
            run.section("种子 agent 停下", body: "结果：\n\(CatalogRunRecord.code(reason))\n\n累计轮数：\(task.rounds)\n\n读过：\(task.read.count) / \(task.materials.count) 份\n\n这次交的正文提案：\(out.pages.count) 份 · \(out.items) 条 · 扔了 \(out.dropped) 处")
            if let error = await persist() {
                run.section("checkpoint 没存成", body: CatalogRunRecord.code(error))
            }
            await run.flush()
            out.task = task
            return out
        }

        enum PageStep {
            case written, open
            case stop(SeedOutcome)
        }

        /// 这一轮没交出合格的这一页：记一次，连续到上限就停（存 checkpoint，不记完成，不再自动请求）
        func stalled(_ d: WikiProposal.Direction, last: String) async -> SeedOutcome? {
            pageStalls += 1
            guard pageStalls >= Self.pageStallLimit else { return nil }
            let note = CatalogSeedPrompts.stallNote(title: d.title, rounds: pageStalls, last: last)
            await seedLog(job, note, ok: false, cost: nil)
            return await finish(.failed(note))
        }

        /// 处理这一页收到的一轮调用（新收到的，或续跑时还没处理完的）：执行、记回执、存 checkpoint
        func settle(_ turn: ToolTurn, _ item: WikiProposal.Item, _ d: WikiProposal.Direction, cost: Double?) async -> PageStep {
            var results: [ToolResultBlock] = []
            var notes: [String] = []
            for call in turn.calls {
                let handled = await handlePageCall(call, item: item, title: d.title, job: job, task: &task, out: &out)
                results.append(ToolResultBlock(toolUseId: call.id, text: handled.text, isError: handled.isError))
                notes.append(handled.note)
                run.section("种子第 \(task.rounds) 轮工具实际回执 · \(call.id)", body: Self.traceResults([results[results.count - 1]]))
            }
            var done = turn
            done.results = results
            pageTurns.append(done)
            pagePending = nil
            await seedLog(job, "第 \(task.rounds) 轮（写「\(d.title)」）：" + notes.joined(separator: "、"), ok: true, cost: cost)
            if !CatalogSeedTask.unwritten(await loadOutline()).contains(where: { $0.id == item.id }) {
                clearPage()
                if let error = await persist() { return .stop(await finish(.failed("checkpoint 没存成：\(error)"))) }
                return .written
            }
            if let stop = await stalled(d, last: notes.joined(separator: "、")) { return .stop(stop) }
            if let error = await persist() { return .stop(await finish(.failed("checkpoint 没存成：\(error)"))) }
            return .open
        }

        /// 写一页：这一页自己的对话，直到交上正文（返回 nil）或停下
        func writePage(_ item: WikiProposal.Item, _ d: WikiProposal.Direction) async -> SeedOutcome? {
            while true {
                if isCancelled { return await finish(.cancelled) }
                task.rounds += 1
                task.state = .writing
                onRound?(task.rounds)
                let request = AssistantBackendRequest(system: pageSystem, history: pageHistory, tools: CatalogSeedTools.pageDefinitions(item: item.id),
                                                      toolTurns: pageTurns, maxTokens: Self.seedMaxTokens)
                currentAnchor = run.section("种子第 \(task.rounds) 轮 · 写「\(d.title)」· 请求", body: Self.traceSeedRequest(request, since: pageTraced))
                pageTraced = (pageHistory.count, pageTurns.count)
                if let why = await deps.gate(Self.payload(pageSystem, pageHistory, pageTurns)) {
                    await seedLog(job, "第 \(task.rounds) 轮（写「\(d.title)」）被拦（\(why)）", ok: false, cost: nil)
                    _ = await deliverRevisionDrafts("那轮被预算拦下（\(why)）", only: nil, job: job, task: &task, out: &out)
                    return await finish(.blocked(why))
                }
                if isCancelled { return await finish(.cancelled) }
                let response = await step(backend, request)
                var replyBody = "### 模型正文\n" + CatalogRunRecord.code(response.text)
                if case .toolCalls(let calls) = response.event { replyBody += "\n\n### 工具调用\n" + Self.traceCalls(calls) }
                if case .failed(let message) = response.event { replyBody = "事件：失败\n\n" + CatalogRunRecord.code(message) + "\n\n" + replyBody }
                if case .finished(let text) = response.event { replyBody = "### 模型正文\n" + CatalogRunRecord.code(text) }
                run.section("种子第 \(task.rounds) 轮 · 写「\(d.title)」· 模型回复", body: replyBody)
                if isCancelled { return await finish(.cancelled) }
                let cost = deps.roundCost(backend)
                switch response.event {
                case .token:
                    continue
                case .failed(let message):
                    let note = CatalogSeedPrompts.contextTooLong(message)
                        ? CatalogSeedPrompts.pageContextNote(title: d.title, round: task.rounds, model: task.modelName, raw: message)
                        : "第 \(task.rounds) 轮出错（写「\(d.title)」）：\(message)"
                    await seedLog(job, note, ok: false, cost: cost)
                    _ = await deliverRevisionDrafts("那轮出错（\(message)）", only: nil, job: job, task: &task, out: &out)
                    return await finish(.failed(note))
                case .finished(let text):
                    await seedLog(job, "第 \(task.rounds) 轮（写「\(d.title)」）没调工具，提醒它", ok: true, cost: cost)
                    Self.remind(CatalogSeedPrompts.pageNudge(item.id), history: &pageHistory, turns: &pageTurns, lastText: text)
                    if let stop = await stalled(d, last: "只回了字、没调工具") { return stop }
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                case .toolCalls(let calls):
                    let extras = deps.roundTurn(backend)
                    var received = ToolTurn(calls: calls, results: [], assistantContent: extras?.assistantContent,
                                            thinkingTokens: extras?.thinkingTokens, reasoning: extras?.reasoning)
                    received.text = response.text.isEmpty ? nil : response.text
                    pagePending = CatalogSeedTask.Turn(received)
                    if let error = await persist() { return await finish(.failed("收到的工具调用没存成，没执行：\(error)")) }
                    switch await settle(received, item, d, cost: cost) {
                    case .written: return nil
                    case .open: continue
                    case .stop(let stop): return stop
                    }
                }
            }
        }

        /// 写正文：每个已批、还没写的目录项单开一段对话（system + 整份目录 + 这一项的原料全文 + 要更新的已有页），
        /// 不带出目录那段历史、也不带别的原料；出处校验、版本、完成判定照旧
        func writePages() async -> SeedOutcome {
            while true {
                if isCancelled { return await finish(.cancelled) }
                let loaded = await loadOutline()
                let left = CatalogSeedTask.unwritten(loaded)
                if let current = pageItem, !left.contains(where: { $0.id == current }) {
                    clearPage()
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                }
                guard let outline = loaded, let item = left.first(where: { $0.id == pageItem }) ?? left.first, let d = item.change.direction else {
                    return await finish(.paused)
                }
                // 先对账：这一页收到、还没处理完的调用照现在的目录项处理掉（不重新问模型）
                if pageItem == item.id, let pending = pagePending {
                    run.section("接着处理「\(d.title)」上次收到、没处理完的工具调用（不重新问模型）", body: Self.traceCalls(pending.toolTurn.calls))
                    switch await settle(pending.toolTurn, item, d, cost: nil) {
                    case .written: continue
                    case .stop(let stop): return stop
                    case .open: break
                    }
                }
                let key = Self.pageKey(d, task: task)
                if pageItem == item.id, pageKey == nil || pageKey == key {
                    pageKey = key
                    run.section("写正文 · 「\(d.title)」（item \(item.id.prefix(8))）· 接着上次这一页的对话",
                                body: "本项的目标、原料和读到的版本没变，这一页的对话接着用（已有 \(pageTurns.count) 个回合；别的目录项变了不重开）")
                } else {
                    let restarted = pageItem == item.id
                    sync()
                    let snapshot = task
                    let revision = Self.revision(for: item.id, task: snapshot)
                    let opened = await Task.detached(priority: .utility) { Self.pageOpening(item, outline: outline, task: snapshot, revision: revision) }.value
                    let page: (text: String, trace: String)
                    switch opened {
                    case .failure(let problem):
                        await seedLog(job, problem.note, ok: false, cost: nil)
                        return await finish(.failed(problem.note))
                    case .success(let got):
                        page = got
                    }
                    if revision == nil, task.revisionDrafts?[item.id] != nil {
                        // 找不回修改要求的残留修订稿（旧 checkpoint 取消后留下的）：清掉，这一页按第一稿重新来
                        task.revisionDrafts?[item.id] = nil
                        task.revisionAsks?[item.id] = nil
                    }
                    pageItem = item.id
                    pageKey = key
                    pageHistory = [(role: "user", content: page.text)]
                    pageTurns = []
                    pagePending = nil
                    pageStalls = 0
                    pageTraced = nil
                    run.section("写正文 · 「\(d.title)」（item \(item.id.prefix(8))）· 单开一段对话"
                                + (restarted ? "（本项的目标或原料变了，重开）" : "") + (revision == nil ? "" : "（带上一稿和修改要求）"), body: page.trace)
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                }
                if let stop = await writePage(item, d) { return stop }
            }
        }

        while true {
            if isCancelled { return await finish(.cancelled) }
            if task.pending == nil, task.outlineSaved {
                if let note = job.control {
                    run.section("审批后继续 · 审批结果（只记录：写正文每页单开一段对话，不接在出目录的对话后面）", body: CatalogRunRecord.code(note))
                }
                return await writePages()
            }
            let turn: ToolTurn
            var cost: Double?
            if let pending = task.pending {
                turn = pending.toolTurn
                run.section("接着处理上次收到、没处理完的工具调用（不重新问模型）", body: Self.traceCalls(turn.calls))
            } else {
                task.rounds += 1
                task.state = .reading
                onRound?(task.rounds)
                let request = AssistantBackendRequest(system: system, history: history, tools: CatalogSeedTools.definitions,
                                                      toolTurns: turns, maxTokens: Self.seedMaxTokens)
                currentAnchor = run.section("种子第 \(task.rounds) 轮 · 请求", body: Self.traceSeedRequest(request, since: traced))
                traced = (history.count, turns.count)
                if let why = await deps.gate(Self.payload(system, history, turns)) {
                    await seedLog(job, "第 \(task.rounds) 轮被拦（\(why)）", ok: false, cost: nil)
                    _ = await deliverRevisionDrafts("那轮被预算拦下（\(why)）", only: nil, job: job, task: &task, out: &out)
                    return await finish(.blocked(why))
                }
                if isCancelled { return await finish(.cancelled) }
                let response = await step(backend, request)
                var replyBody = "### 模型正文\n" + CatalogRunRecord.code(response.text)
                if case .toolCalls(let calls) = response.event { replyBody += "\n\n### 工具调用\n" + Self.traceCalls(calls) }
                if case .failed(let message) = response.event { replyBody = "事件：失败\n\n" + CatalogRunRecord.code(message) + "\n\n" + replyBody }
                if case .finished(let text) = response.event { replyBody = "### 模型正文\n" + CatalogRunRecord.code(text) }
                run.section("种子第 \(task.rounds) 轮 · 模型回复", body: replyBody)
                if isCancelled { return await finish(.cancelled) }
                cost = deps.roundCost(backend)
                switch response.event {
                case .token:
                    continue
                case .failed(let message):
                    let note = CatalogSeedPrompts.contextTooLong(message)
                        ? CatalogSeedPrompts.contextNote(round: task.rounds, model: task.modelName, raw: message)
                        : "第 \(task.rounds) 轮出错：\(message)"
                    await seedLog(job, note, ok: false, cost: cost)
                    _ = await deliverRevisionDrafts("那轮出错（\(message)）", only: nil, job: job, task: &task, out: &out)
                    return await finish(.failed(note))
                case .finished(let text):
                    await seedLog(job, "第 \(task.rounds) 轮没调工具，提醒它", ok: true, cost: cost)
                    Self.remind(CatalogSeedPrompts.nudge, history: &history, turns: &turns, lastText: text)
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                    continue
                case .toolCalls(let calls):
                    let extras = deps.roundTurn(backend)
                    var received = ToolTurn(calls: calls, results: [], assistantContent: extras?.assistantContent,
                                            thinkingTokens: extras?.thinkingTokens, reasoning: extras?.reasoning)
                    received.text = response.text.isEmpty ? nil : response.text
                    turn = received
                    task.pending = CatalogSeedTask.Turn(received)
                    if let error = await persist() { return await finish(.failed("收到的工具调用没存成，没执行：\(error)")) }
                }
            }
            var results: [ToolResultBlock] = []
            var notes: [String] = []
            var outlineDone = false
            var emptyReason: String?
            /// 生成这一轮时模型已经读到的：交目录 / 交页只认它，这一轮新 read 的下一次请求发出去之后才算读过
            let delivered = task.read
            for call in turn.calls {
                let handled = await handleSeedCall(call, job: job, task: &task, delivered: delivered, out: &out)
                results.append(ToolResultBlock(toolUseId: call.id, text: handled.text, isError: handled.isError))
                notes.append(handled.note)
                outlineDone = outlineDone || handled.outlineSaved
                emptyReason = emptyReason ?? handled.emptyOutline
                run.section("种子第 \(task.rounds) 轮工具实际回执 · \(call.id)", body: Self.traceResults([results[results.count - 1]]))
            }
            var done = turn
            done.results = results
            turns.append(done)
            task.pending = nil
            await seedLog(job, "第 \(task.rounds) 轮：" + notes.joined(separator: "、"), ok: true, cost: cost)
            if let emptyReason { return await finish(.emptyOutline(emptyReason)) }
            if outlineDone {
                task.state = .waiting
                if let error = await persist() { return await finish(.failed("目录存了，checkpoint 没存成（重启续跑会对上这份目录）：\(error)")) }
                return await finish(.outlineSubmitted)
            }
            if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
        }
    }

    private struct SeedHandled {
        var text: String
        var isError = false
        var note: String
        var outlineSaved = false
        var emptyOutline: String? = nil
    }

    private func handleSeedCall(_ call: ToolCallBlock, job: SeedJob, task: inout CatalogSeedTask, delivered: [String: String],
                                out: inout SeedOutcome) async -> SeedHandled {
        let json = call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON
        /// 诊断写在最后：被截断、坏了都只丢诊断，诊断键之前那段完整就照收
        let args = CatalogSeedTools.parse(json, truncated: call.truncated)
        let truncated = call.truncated && args == nil
        if call.name == CatalogAgentTools.submit, truncated || args == nil, args?.phase != "outline" {
            let why = truncated ? "那次输出被截断" : "那次参数不是合格的 JSON"
            let item = args?.item?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fell = await deliverRevisionDrafts(why, only: item, job: job, task: &task, delivered: delivered, out: &out)
            if !fell.isEmpty {
                return SeedHandled(text: "收到（\(why)），这几页交的是上一稿：\(fell.joined(separator: "、"))", note: "重写用不了，交上一稿")
            }
        }
        guard let args else {
            return SeedHandled(text: "参数不是合格的 JSON", isError: true, note: "\(call.name) 参数不合格")
        }
        switch call.name {
        case CatalogSeedTools.read:
            let path = (args.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if task.read[path] != nil {
                return SeedHandled(text: "这份已经读过了（内容在前面的回执里），不用再读：\(path)", note: "read \(path)（读过了）")
            }
            guard task.materials.contains(where: { $0.path == path }) else {
                return SeedHandled(text: "不在这次的原料清单里：\(path)（只能读清单里的路径）", isError: true, note: "read \(path)（不在清单）")
            }
            guard let item = job.materials[path] else {
                task.read[path] = ""
                return SeedHandled(text: "这份原料已经不在了：\(path)", isError: true, note: "read \(path)（已不在）")
            }
            task.read[path] = item.version
            return SeedHandled(text: "【\(item.path) · \(item.layer) · \(item.name)】\n\(item.text)", note: "read \(path) \(item.text.count) 字")
        case CatalogAgentTools.submit:
            if truncated {
                return SeedHandled(text: "输出太长被截断了：目录的钩子写短一点，或这一页少写几条，再交", isError: true, note: "交的输出被截断")
            }
            switch args.phase {
            case "outline": return await submitOutline(args, job: job, task: &task, delivered: delivered, out: &out)
            case "page": return await submitPage(args, call: call, json: json, job: job, task: &task, delivered: delivered, out: &out)
            default: return SeedHandled(text: "phase 只能是 outline 或 page", isError: true, note: "submit phase 不对")
            }
        default:
            return SeedHandled(text: "没有这个工具：\(call.name)", isError: true, note: call.name)
        }
    }

    /// 写正文那段对话里的调用：只认给这一项交页
    private func handlePageCall(_ call: ToolCallBlock, item: WikiProposal.Item, title: String, job: SeedJob, task: inout CatalogSeedTask,
                                out: inout SeedOutcome) async -> SeedHandled {
        guard call.name == CatalogAgentTools.submit else {
            return SeedHandled(text: "这一页的原料全文都在开头给了，不用 \(call.name)；写好用 submit_proposal（phase = page，item = \(item.id)）交",
                               isError: true, note: "\(call.name)（写正文时用不到）")
        }
        let args = CatalogSeedTools.parse(call.argumentsJSON, truncated: call.truncated)
        if args?.phase == "outline" {
            return SeedHandled(text: "目录已经交过了；现在只写「\(title)」（phase = page，item = \(item.id)）", isError: true, note: "又交目录")
        }
        if let other = args?.item?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty, other != item.id {
            return SeedHandled(text: "这一次只写「\(title)」（item = \(item.id)），别的页另开一次写", isError: true, note: "交了别的页 \(other)")
        }
        return await handleSeedCall(call, job: job, task: &task, delivered: task.read, out: &out)
    }

    struct PageProblem: Error {
        var note: String
    }

    /// 开这一页对话时本项的目标、原料和读到的版本（别的目录项变了不算）
    nonisolated static func pageKey(_ d: WikiProposal.Direction, task: CatalogSeedTask) -> String {
        let paths = (d.sources ?? []) + (d.action == .update ? [CatalogSeedMaterials.wikiPath(d.path)] : [])
        return ([d.path, d.action == .update ? "更新" : "新开"] + paths.map { "\($0)@\(task.read[$0] ?? "未读")" }).joined(separator: "\n")
    }

    /// 这一页的修订：第一稿 + 当时的修改要求（新任务存在 revisionAsks；旧 checkpoint 从回合回执里找回来）
    nonisolated static func revision(for itemId: String, task: CatalogSeedTask) -> (asks: String, draft: String)? {
        guard let draft = task.revisionDrafts?[itemId] else { return nil }
        if let asks = task.revisionAsks?[itemId] { return (asks, draft) }
        for turn in (task.turns + (task.page?.turns ?? [])).reversed() {
            for call in turn.calls where call.name == CatalogAgentTools.submit
                && CatalogSeedTools.parse(call.argumentsJSON, truncated: call.truncated)?.item?.trimmingCharacters(in: .whitespacesAndNewlines) == itemId {
                guard let result = turn.results.first(where: { $0.toolUseId == call.id }), let r = result.text.range(of: "整页重交：\n") else { continue }
                return (String(result.text[r.upperBound...]), draft)
            }
        }
        return nil
    }

    /// 写一页送进去的开场（和记录里列的原料）：原料和要更新的已有页都只认任务的 read 回执（正文和版本成对，和出处校验同一份），
    /// 不读盘补；缺了 / 对不上就停在这一页
    nonisolated static func pageOpening(_ item: WikiProposal.Item, outline: WikiProposal, task: CatalogSeedTask,
                                        revision: (asks: String, draft: String)? = nil) -> Result<(text: String, trace: String), PageProblem> {
        guard let d = item.change.direction else { return .failure(PageProblem(note: "目录项不见了")) }
        let byPath = Dictionary(task.materials.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let paths = d.sources ?? []
        var sources: [CatalogSeedPrompts.PageSource] = []
        for path in paths {
            var text: String?
            switch task.read[path] {
            case nil:
                return .failure(PageProblem(note: "checkpoint 不一致：「\(d.title)」列着的 \(path) 没有读过的记录。这一页停在这里，没有另外读盘补"))
            case let version? where !version.isEmpty:
                guard let got = task.readText(path) else {
                    return .failure(PageProblem(note: "checkpoint 不一致：「\(d.title)」列着的 \(path) 读过（版本 \(version.prefix(12))），任务记录里却找不到读到的正文。这一页停在这里，没有另外读盘补"))
                }
                text = got
            default:
                break
            }
            sources.append(CatalogSeedPrompts.PageSource(path: path, layer: byPath[path]?.layer ?? "", name: byPath[path]?.name ?? path, text: text))
        }
        var existing: String?
        if d.action == .update {
            let wikiPath = CatalogSeedMaterials.wikiPath(d.path)
            if paths.contains(wikiPath) {
                existing = "（就是上面原料里的 \(wikiPath)）"
            } else if let version = task.read[wikiPath], !version.isEmpty, let text = task.readText(wikiPath) {
                existing = text
            } else {
                return .failure(PageProblem(note: "「\(d.title)」要更新的已有页 \(d.path) 不在这次读过的原料里（没有读到的正文和版本），不能另外读盘补，这一页停在这里。可以放弃这个种子任务再重新播种"))
            }
        }
        let text = CatalogSeedPrompts.pageOpening(item, outline: outline, sources: sources, existing: existing, revision: revision)
        let listed = sources.map { s in
            "- \(s.path) · " + (s.text.map { "\($0.count) 字 · 读到的版本 \(task.read[s.path] ?? "")" } ?? "读的时候已经不在了")
        }
        var trace = "只送：写页 system、整份目录、这一项列着的原料（read 回执那一版）" + (existing == nil ? "" : "、要更新的已有页")
            + "；不带出目录那段对话和别的原料\n\n这一页的原料（\(sources.count) 份）：\n" + listed.joined(separator: "\n")
        if let existing { trace += "\n\n要更新的已有页 \(d.path)：\(existing.count) 字（read 回执，版本 \(task.read[CatalogSeedMaterials.wikiPath(d.path)] ?? "")）" }
        if let revision { trace += "\n\n带上一稿（\(revision.draft.count) 字）和修改要求：\n\(revision.asks)" }
        trace += "\n\n开场共 \(text.count) 字"
        return .success((text, trace))
    }

    private func submitOutline(_ args: CatalogSeedTools.Args, job: SeedJob, task: inout CatalogSeedTask, delivered: [String: String],
                               out: inout SeedOutcome) async -> SeedHandled {
        guard !task.outlineSaved else { return SeedHandled(text: "目录已经交过了，等\(job.names.user)批", note: "目录交过了") }
        let store = WikiProposalStore(wiki: job.wiki)
        let taskId = task.id
        if let existing = await Task.detached(priority: .utility, operation: { store.load(taskId) }).value {
            task.outlineSaved = true
            out.outlineItems = existing.items.count
            return SeedHandled(text: "目录收到：\(existing.items.count) 项。现在停下，等\(job.names.user)批；批了会告诉你写哪几页。",
                               note: "目录已存（对上了上次存下的）", outlineSaved: true)
        }
        var seen = task
        seen.read = delivered
        let unread = seen.unread
        guard unread.isEmpty else {
            return SeedHandled(text: "还有 \(unread.count) 份没读，先读完再交目录：\n" + unread.map { "- \($0.path)" }.joined(separator: "\n"),
                               isError: true, note: "目录交早了（还有 \(unread.count) 份没读）")
        }
        let entries = args.outline ?? []
        let snapshot = seen
        let wiki = job.wiki
        let (items, dropped) = await Task.detached(priority: .utility) { CatalogSeedTools.outline(entries, task: snapshot, wiki: wiki) }.value
        if items.isEmpty {
            if entries.isEmpty, let reason = args.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                return SeedHandled(text: "收到：目录是空的（\(reason)）", note: "交了空目录", emptyOutline: reason)
            }
            return SeedHandled(text: "目录里没有能用的项，按下面的原因改了重交：\n" + dropped.joined(separator: "\n"), isError: true, note: "目录不合格")
        }
        var proposal = WikiProposal(id: taskId, origin: .seed, createdAt: job.now, title: "种子目录 · \(task.entry.label)",
                                    seedSkipped: task.skipped.isEmpty ? nil : task.skipped, items: items,
                                    run: job.run.link(anchor: currentAnchor))
        proposal.seedTask = taskId
        let saved = proposal
        let saveError = await Task.detached(priority: .utility) { () -> String? in
            do {
                try store.save(saved)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let saveError { return SeedHandled(text: "目录没存成：\(saveError)", isError: true, note: "目录没存成") }
        task.outlineSaved = true
        out.outlineItems = items.count
        let droppedText = dropped.isEmpty ? "" : "（扔了 \(dropped.count) 项：\(dropped.joined(separator: "；"))）"
        return SeedHandled(text: "目录收到：\(items.count) 项\(droppedText)。现在停下，等\(job.names.user)批；批了会告诉你写哪几页。",
                           note: "交了目录 \(items.count) 项" + (dropped.isEmpty ? "" : "（扔了 \(dropped.count) 项）"), outlineSaved: true)
    }

    /// 修订之后只要不是被取消，用不了（截断、坏参数、出错、被拦）就把还没交的第一稿交成提案；返回交了哪几页。only = 只交这一项
    private func deliverRevisionDrafts(_ why: String, only: String?, job: SeedJob, task: inout CatalogSeedTask,
                                       delivered read: [String: String]? = nil, out: inout SeedOutcome) async -> [String] {
        let store = WikiProposalStore(wiki: job.wiki)
        let taskId = task.id
        let outline = await Task.detached(priority: .utility) { store.load(taskId) }.value
        var delivered: [String] = []
        for (itemId, first) in (task.revisionDrafts ?? [:]).sorted(by: { $0.key < $1.key }) where only == nil || only == itemId {
            guard let entry = outline?.items.first(where: { $0.id == itemId }), let d = entry.change.direction,
                  entry.state == .approved, d.contentProposalId == nil else { continue }
            let args = CatalogSeedTools.Args(path: nil, phase: "page", item: itemId, reason: nil, outline: nil)
            let call = ToolCallBlock(id: "revision-fallback", name: CatalogAgentTools.submit, argumentsJSON: first, truncated: false)
            let handled = await submitPage(args, call: call, json: first, job: job, task: &task, delivered: read ?? task.read, out: &out, fallback: why)
            if !handled.isError { delivered.append(d.title) }
        }
        return delivered
    }

    private func submitPage(_ args: CatalogSeedTools.Args, call: ToolCallBlock, json: String, job: SeedJob,
                            task: inout CatalogSeedTask, delivered: [String: String], out: inout SeedOutcome, fallback: String? = nil) async -> SeedHandled {
        guard task.outlineSaved else { return SeedHandled(text: "还没交目录：先交 phase = outline", isError: true, note: "交页太早") }
        let itemId = (args.item ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wiki = job.wiki
        let store = WikiProposalStore(wiki: wiki)
        let taskId = task.id
        let outline = await Task.detached(priority: .utility) { store.load(taskId) }.value
        guard let entry = outline?.items.first(where: { $0.id == itemId }), let d = entry.change.direction, d.mode == .seed else {
            return SeedHandled(text: "没有这个目录项：\(itemId)", isError: true, note: "交页：没有目录项 \(itemId)")
        }
        guard entry.state == .approved else {
            return SeedHandled(text: "「\(d.title)」还没批或被驳回了，不写", isError: true, note: "交页：「\(d.title)」没批")
        }
        let commitId = CatalogSeedTask.commitId(task: taskId, call: call.id, item: entry.id)
        if let existing = d.contentProposalId, existing != commitId {
            return SeedHandled(text: "「\(d.title)」已经交过了（提案 \(existing.prefix(8))），不重复交", note: "「\(d.title)」交过了")
        }
        let content: WikiProposal
        let dropped: [String]
        if let saved = await Task.detached(priority: .utility, operation: { store.load(commitId) }).value {
            content = saved
            dropped = []
        } else {
            var snapshot = task
            snapshot.read = delivered
            var sources = CatalogSeedTools.sources(snapshot, allowed: Set(d.sources ?? []))
            sources.linkTargets = Set((outline?.items ?? []).filter { $0.state == .approved }.compactMap { $0.change.direction?.path }).subtracting([d.path])
            let given = sources
            let seen = snapshot
            func check(_ raw: String, truncated: Bool = false) async -> (parsed: CatalogItems.Parsed?, page: (items: [WikiProposal.Item], dropped: [String])?, error: String) {
                let (parsed, parseError) = await Task.detached(priority: .utility) { () -> (CatalogItems.Parsed?, String) in
                    var failure = ""
                    let parsed = CatalogItems.parse(raw, sources: given, wiki: wiki, truncated: truncated) { failure = $0 }
                    return (parsed, failure)
                }.value
                return (parsed, parsed.map { CatalogSeedTools.page($0, direction: d, task: seen) }, parseError)
            }
            var got = await check(json, truncated: call.truncated)
            /// 这一页的诊断：final = 存成了交审的那一份；别的（打回修订、没能用的）标中间稿
            func diagnose(final: Bool) {
                guard var shown = got.parsed else { return }
                shown.items = got.page?.items ?? []
                shown.dropReasons = got.page?.dropped ?? shown.dropReasons
                CatalogDiagnostics.record(shown, sources: given, final: final, title: "种子交页「\(d.title)」· \(call.id)", run: job.run)
            }
            if let fallback {
                got.parsed?.revision = CatalogChecks.fellBack(fallback)
            } else if let first = task.revisionDrafts?[entry.id] {
                if got.page?.items.isEmpty == false, let parsed = got.parsed {
                    got.parsed?.revision = CatalogChecks.revised(parsed)
                } else {
                    let why = got.page.map { "那次交的没有能用的内容（\($0.dropped.joined(separator: "；"))）" } ?? "那次格式不对（\(got.error)）"
                    got = await check(first)
                    got.parsed?.revision = CatalogChecks.fellBack(why)
                }
            }
            guard let parsed = got.parsed, let checked = got.page, !checked.items.isEmpty else {
                diagnose(final: false)
                let why = got.page.map { $0.dropped.joined(separator: "\n") } ?? "格式不对：\(got.error)"
                return SeedHandled(text: "「\(d.title)」没有能用的条目，按下面的原因改了重交：\n" + why, isError: true, note: "「\(d.title)」不合格")
            }
            CatalogWriter.recordChecks(parsed, names: job.names, title: "种子交页「\(d.title)」· \(call.id)", run: job.run)
            if !parsed.revisionNotes.isEmpty, task.revisionDrafts?[entry.id] == nil {
                task.revisionDrafts = (task.revisionDrafts ?? [:]).merging([entry.id: json]) { a, _ in a }
                task.revisionAsks = (task.revisionAsks ?? [:]).merging([entry.id: parsed.revisionNotes.map { "- " + $0 }.joined(separator: "\n")]) { a, _ in a }
                diagnose(final: false)
                return SeedHandled(text: "「\(d.title)」这几处没过检查。只改这几处，别的照旧，整页重交：\n" + parsed.revisionNotes.map { "- " + $0 }.joined(separator: "\n"),
                                   isError: true, note: "「\(d.title)」没过检查，重写一次")
            }
            var proposal = WikiProposal(id: commitId, origin: .seed, createdAt: job.now, title: d.title, items: checked.items,
                                        directionRef: .init(proposalId: taskId, itemId: entry.id), run: job.run.link(anchor: currentAnchor))
            proposal.seedTask = taskId
            let unapplied = parsed.unapplied.filter { $0.page == nil || $0.page == d.path }
            proposal.unapplied = unapplied.isEmpty ? nil : unapplied
            proposal.revision = parsed.revision
            let saved = proposal
            let saveError = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try store.save(saved)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let saveError { return SeedHandled(text: "「\(d.title)」的正文没存成：\(saveError)", isError: true, note: "「\(d.title)」没存成") }
            diagnose(final: true)
            content = proposal
            dropped = checked.dropped
        }
        if d.contentProposalId == nil {
            do {
                try await WikiProposalReview.recordDirection(taskId, itemId: entry.id, result: "交了 \(content.items.count) 条正文等批",
                                                             contentProposalId: content.id, store: store)
            } catch {
                return SeedHandled(text: "「\(d.title)」的正文存了，没记到目录上（续跑会对上）：\(error.localizedDescription)", isError: true,
                                   note: "「\(d.title)」没记上")
            }
        }
        out.pages.append(content.id)
        out.items += content.items.count
        out.dropped += dropped.count
        let left = CatalogSeedTask.unwritten(await Task.detached(priority: .utility) { store.load(taskId) }.value)
            .compactMap { $0.change.direction?.title }
        let droppedText = dropped.isEmpty ? "" : "（扔了 \(dropped.count) 处：\(dropped.joined(separator: "；"))）"
        let next = left.isEmpty ? "批过的都写完了。" : "还剩 \(left.count) 页：\(left.joined(separator: "、"))。"
        return SeedHandled(text: "收到「\(d.title)」：\(content.items.count) 条，等\(job.names.user)批\(droppedText)。\(next)",
                           note: "交了「\(d.title)」\(content.items.count) 条" + (dropped.isEmpty ? "" : "（扔了 \(dropped.count) 处）"))
    }

    /// 第一轮（和每次继续的第一轮）记完整请求；之后只记这一轮新加的消息和回合（上一回合重记一遍，带上补进去的提醒）
    private static func traceSeedRequest(_ request: AssistantBackendRequest, since: (history: Int, turns: Int)?) -> String {
        guard let since else { return traceRequest(request) }
        var parts = ["（系统提示、工具定义和更早的内容同上一轮，下面只列这一轮新增的；完整请求 = 这次运行第一轮的记录 + 之后每轮新增）"]
        let messages = Array(request.history.enumerated().dropFirst(since.history))
        if !messages.isEmpty {
            parts.append("### 新增消息\n" + messages.map { index, message in
                "#### 消息 \(index + 1) · \(message.role)\n" + CatalogRunRecord.code(message.content)
            }.joined(separator: "\n\n"))
        }
        let turns = Array(request.toolTurns.enumerated().dropFirst(max(0, since.turns - 1)))
        if !turns.isEmpty {
            parts.append("### 回灌 toolTurns（新增 / 上一回合）\n" + turns.map { index, turn in
                "#### 工具回合 \(index + 1)\n" + traceCalls(turn.calls) + "\n\n" + traceResults(turn.results)
            }.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// 每轮一行记忆日志，带同一份记录的链接和这一轮的锚点
    private func seedLog(_ job: SeedJob, _ note: String, ok: Bool, cost: Double?) async {
        let link = job.run.link(anchor: currentAnchor)
        await job.run.flush()
        await MemoryWriteLog.metered {
            if let cost { MemoryWriteLog.addCost(cost) }
            MemoryWriteLog.record(writer: .c3, profileId: job.task.profileId, ok: ok, note: "种子 · \(note)", model: job.task.modelName, run: link)
        }
    }
}
