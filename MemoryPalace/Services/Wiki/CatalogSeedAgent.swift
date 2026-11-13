import MemoryCore
import Foundation

// MARK: - 种子：同一个 CatalogAgent Deps / 后端，跑一个任务（没有日常的轮数、回执字数、单主题上限，也没有替代闸门）。
// 出目录（plan-seed-notes-flow）：原料切批出要点卡 → 代码按实体聚合 → 对齐名单 → 回扫补配 → 聚类 → 目录，每个请求独立、JSON 回复、不带工具；
// 写正文：每个已批目录项单开一段对话，只带这一项的原料（快照那一版）

extension CatalogAgent {
    /// 本机后端的生成上限（云端按模型默认）；一批卡 / 一页正文一次交，留够
    static let seedMaxTokens = 16_000
    /// 同一页连续这么多轮没交出合格的这一页就停（存 checkpoint、不记完成、不再自动请求）
    static let pageStallLimit = 3

    struct SeedJob {
        var task: CatalogSeedTask
        /// 本任务的原料全文快照（出卡、回扫、写页开场都从这里取，不重新读盘）
        var snapshot: CatalogSeedMaterials.Snapshot
        var wiki: WikiStore
        var names: MemoryExtractor.Names
        var run: CatalogRunRecord
        /// 审批后继续：审批结果（只写进整理记录；写正文每页单开一段对话，不发给模型）
        var control: String? = nil
        var now: Date = Date()
        /// 存目录那一步的两个时刻（false = 读完已存的目录、还没写；true = 写完）：测试在这里点停，覆盖最后那段取消窗口
        var onOutlineSave: (@MainActor (_ saved: Bool) -> Void)? = nil
        var onStage: (@MainActor (_ stage: String) -> Void)? = nil
    }

    enum SeedStop: Equatable, Error {
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
        let pageSystem = CatalogSeedPrompts.pageSystem(names: job.names, entry: task.entry, day: CatalogSurvey.day(task.createdAt))
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
        /// 出目录阶段发出去了、还没记进记忆日志的花费（重写那次、每一片对齐都算）：下一行日志带走，一笔只记一次
        var unbilled: Double?
        func takeCost() -> Double? {
            defer { unbilled = nil }
            return unbilled
        }

        func sync() {
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
            // 停在半路（被拦 / 点停 / 出错）时这一阶段已经发出去的请求：费用在这里记，不丢
            if let cost = takeCost() { await seedLog(job, "停下：\(reason)", ok: stop.isNormal, cost: cost) }
            run.section("种子 agent 停下", body: "结果：\n\(CatalogRunRecord.code(reason))\n\n累计请求：\(task.rounds)\n\n出了卡：\(task.cardable.count - task.uncarded.count) / \(task.cardable.count) 份（原料快照 \(task.materials.count) 份）\n\n这次交的正文提案：\(out.pages.count) 份 · \(out.items) 条 · 扔了 \(out.dropped) 处")
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

        /// 这一轮既没交正文、也没核对新的原料：连续到上限就停。
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
            var readProgress = false
            for call in turn.calls {
                let handled = await handlePageCall(call, item: item, title: d.title, job: job, task: &task, out: &out)
                results.append(ToolResultBlock(toolUseId: call.id, text: handled.text, isError: handled.isError))
                notes.append(handled.note)
                if let path = handled.readPath {
                    let alreadyRead = pageTurns.contains { previous in
                        previous.calls.contains { old in
                            old.name == "read"
                                && CatalogSeedTools.parse(old.argumentsJSON)?.path.map { WikiStore.stored($0, user: job.names.user) } == path
                                && previous.results.contains { $0.toolUseId == old.id && !$0.isError }
                        }
                    }
                    readProgress = readProgress || !alreadyRead
                }
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
            if readProgress {
                pageStalls = 0
            } else if let stop = await stalled(d, last: notes.joined(separator: "、")) {
                return .stop(stop)
            }
            if let error = await persist() { return .stop(await finish(.failed("checkpoint 没存成：\(error)"))) }
            return .open
        }

        /// 写一页：这一页自己的对话，直到交上正文（返回 nil）或停下
        func writePage(_ item: WikiProposal.Item, _ d: WikiProposal.Direction) async -> SeedOutcome? {
            /// 上一轮请求超时、已经原样再发过一次（再超时就停）；收到正常回复清零
            var retriedTimeout = false
            while true {
                if isCancelled { return await finish(.cancelled) }
                task.rounds += 1
                task.state = .writing
                onRound?(task.rounds)
                let request = AssistantBackendRequest(system: pageSystem, history: pageHistory, tools: CatalogSeedTools.pageDefinitions(item: item.id, direction: d),
                                                      toolTurns: pageTurns, maxTokens: Self.seedMaxTokens)
                currentAnchor = run.section("种子第 \(task.rounds) 轮 · 写「\(d.title)」· 请求", body: Self.traceSeedRequest(Self.shown(request, user: job.names.user), since: pageTraced))
                pageTraced = (pageHistory.count, pageTurns.count)
                if let why = await deps.gate(Self.payload(pageSystem, pageHistory, pageTurns)) {
                    await seedLog(job, "第 \(task.rounds) 轮（写「\(d.title)」）被拦（\(why)）", ok: false, cost: nil)
                    _ = await deliverRevisionDrafts("那轮被预算拦下（\(why)）", only: nil, job: job, task: &task, out: &out)
                    return await finish(.blocked(why))
                }
                if isCancelled { return await finish(.cancelled) }
                let response = await step(backend, request, user: job.names.user)
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
                    let timedOut = deps.roundTimedOut(backend)
                    if timedOut, !retriedTimeout {
                        retriedTimeout = true
                        await seedLog(job, "第 \(task.rounds) 轮（写「\(d.title)」）请求超时，原样再发一次：\(message)", ok: false, cost: cost)
                        continue
                    }
                    let note = CatalogSeedPrompts.contextTooLong(message)
                        ? CatalogSeedPrompts.pageContextNote(title: d.title, round: task.rounds, model: task.modelName, raw: message)
                        : timedOut ? CatalogSeedPrompts.timeoutNote(round: task.rounds, title: d.title, raw: message)
                        : "第 \(task.rounds) 轮出错（写「\(d.title)」）：\(message)"
                    await seedLog(job, note, ok: false, cost: cost)
                    _ = await deliverRevisionDrafts("那轮出错（\(message)）", only: nil, job: job, task: &task, out: &out)
                    return await finish(.failed(note))
                case .finished(let text):
                    retriedTimeout = false
                    await seedLog(job, "第 \(task.rounds) 轮（写「\(d.title)」）没调工具，提醒它", ok: true, cost: cost)
                    Self.remind(CatalogSeedPrompts.pageNudge(item.id), history: &pageHistory, turns: &pageTurns, reply: text)
                    if let stop = await stalled(d, last: "只回了字、没调工具") { return stop }
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                case .toolCalls(let calls):
                    retriedTimeout = false
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

        /// 写正文：每项单开一段对话（system + 整份目录 + 本项 L1 条目 + 要更新的已有页），
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
                let snapshot = task
                let feedback = await Task.detached(priority: .utility) {
                    Self.pageFeedback(d, task: snapshot, wiki: wiki)
                }.value
                let key = Self.pageKey(d, task: task, feedback: feedback)
                if pageItem == item.id, pageKey == key {
                    pageKey = key
                    run.section("写正文 · 「\(d.title)」（item \(item.id.prefix(8))）· 接着上次这一页的对话",
                                body: "本项的目标、原料和读到的版本没变，这一页的对话接着用（已有 \(pageTurns.count) 个回合；别的目录项变了不重开）")
                } else {
                    let restarted = pageItem == item.id
                    sync()
                    let snapshot = task
                    let revision = Self.revision(for: item.id, task: snapshot)
                    let opened = await Task.detached(priority: .utility) {
                        Self.pageOpening(item, outline: outline, task: snapshot, wiki: wiki, revision: revision, feedback: feedback)
                    }.value
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
                                + (restarted ? "（本项的目标、原料或开场写法变了，重开）" : "") + (revision == nil ? "" : "（带上一稿和修改要求）"), body: page.trace)
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                }
                if let stop = await writePage(item, d) { return stop }
            }
        }

        // MARK: 出目录：要点卡 → 聚合 → 对齐 → 回扫 → 聚类 → 目录（每个请求独立、JSON 回复、不带工具）

        /// 一次独立请求：过闸、记 .runs、发出去（经 step：{{user}} 显示成名字）、收正文。返回 nil = 没拿到正文；
        /// 被拦 / 停记在 stopped，出错记在 lastError；出卡时保存已收好卡和 checkpoint 后停下。
        var stopped: SeedStop?
        var lastError: String?
        /// 阶段边界：报一次进度（纯代码 / 全沿用的阶段界面照样动），返回这时是不是点了停
        func boundary() -> Bool {
            onRound?(task.rounds)
            return isCancelled
        }
        func ask(_ request: AssistantBackendRequest, title: String) async -> String? {
            if isCancelled { stopped = .cancelled; return nil }
            task.rounds += 1
            task.state = .reading
            onRound?(task.rounds)
            currentAnchor = run.section("种子第 \(task.rounds) 轮 · \(title) · 请求", body: Self.traceRequest(Self.shown(request, user: job.names.user)))
            if let why = await deps.gate(Self.payload(request.system, request.history, [])) {
                await seedLog(job, "第 \(task.rounds) 轮（\(title)）被拦（\(why)）", ok: false, cost: takeCost())
                stopped = .blocked(why)
                return nil
            }
            if isCancelled { stopped = .cancelled; return nil }
            let response = await step(backend, request, user: job.names.user)
            if let cost = deps.roundCost(backend) { unbilled = (unbilled ?? 0) + cost }
            switch response.event {
            case .finished(let text):
                run.section("种子第 \(task.rounds) 轮 · \(title) · 模型回复", body: "### 模型正文\n" + CatalogRunRecord.code(text))
                if isCancelled { stopped = .cancelled; return nil }
                return text
            case .toolCalls(let calls):
                // 这段没给工具还调了：当正文处理（解析不过会带原因重写一次）
                run.section("种子第 \(task.rounds) 轮 · \(title) · 模型回复", body: "### 模型正文\n" + CatalogRunRecord.code(response.text)
                            + "\n\n### 工具调用（这段没有工具，不执行）\n" + Self.traceCalls(calls))
                if isCancelled { stopped = .cancelled; return nil }
                return response.text
            case .failed(let message):
                run.section("种子第 \(task.rounds) 轮 · \(title) · 模型回复", body: "事件：失败\n\n" + CatalogRunRecord.code(message) + "\n\n### 模型正文\n" + CatalogRunRecord.code(response.text))
                if isCancelled { stopped = .cancelled; return nil }
                lastError = message
                await seedLog(job, "第 \(task.rounds) 轮（\(title)）出错：\(message)", ok: false, cost: takeCost())
                return nil
            case .token:
                lastError = "没有收到回复"
                return nil
            }
        }

        func factDomainSummary(_ cards: [SeedNoteCard]) -> String {
            var counts = (realWorld: 0, inWorld: 0, mixed: 0, unspecified: 0, legacy: 0)
            for card in cards {
                switch card.factDomain {
                case .realWorld: counts.realWorld += 1
                case .inWorld: counts.inWorld += 1
                case .mixed: counts.mixed += 1
                case .unspecified: counts.unspecified += 1
                case nil: counts.legacy += 1
                }
            }
            return "realWorld \(counts.realWorld)；inWorld \(counts.inWorld)；mixed \(counts.mixed)；unspecified \(counts.unspecified)；旧卡无域 \(counts.legacy)"
        }

        var newCardPaths = Set<String>()

        /// 按份保留已出的卡；失败记录只含没出卡的原料，续跑重新切批。
        func makeCards(_ cardable: [CatalogSeedMaterials.Item], carded: inout [String: String], progress: inout SeedNoteProgress) async -> Result<[String], SeedStop> {
            let cardStore = SeedNoteStore(wiki: wiki)
            let entry = task.entry, names = job.names
            let limit = CatalogSettings.seedBatchChars()
            // 同一份原料同版本以前出过卡（这个或别的任务）：直接复用，不再请求
            let known = carded
            let reusable = await Task.detached(priority: .utility) { () -> [String: String] in
                var out: [String: String] = [:]
                for item in cardable where known[item.path] != item.version && cardStore.load(path: item.path, version: item.version) != nil { out[item.path] = item.version }
                return out
            }.value
            carded.merge(reusable) { _, new in new }
            progress.batches.removeAll { !$0.ok }
            let batches = SeedNoteBatcher.batches(cardable, limit: limit, carded: carded, entry: entry)
            task.carded = carded
            // 卡要重出（或从别处补回）：之前的对齐 / 聚类是按旧卡做的，先作废并落盘，再往下跑
            if !batches.isEmpty || !reusable.isEmpty, progress.aligned || progress.clustered {
                progress.aligned = false
                progress.clustered = false
                task.notes = progress
                run.section("要点卡要重出：上次的对齐 / 聚类结果作废", body: "这次要出卡 \(batches.count) 批、补回 \(reusable.count) 份；对齐和聚类按新卡重做")
                if let error = await persist() { return .failure(.failed("checkpoint 没存成：\(error)")) }
            }
            task.notes = progress
            run.section("要点卡 · 切批", body: "可出卡的原料 \(cardable.count) 份；以前出过卡直接复用 \(reusable.count) 份；已有卡 \(carded.count) 份；这次分 \(batches.count) 批（每批 ≤ \(limit) 字，一份不拆）")
            let system = SeedNotePrompts.cards(names: names, entry: entry, day: CatalogSurvey.day(task.createdAt))
            var failed: [String] = []
            let base = progress.batches.reduce(0) { max($0, $1.index) }
            let frozenTask = task
            let snapshot = await Task.detached(priority: .utility) { frozenTask.snapshot(wiki: wiki) }.value
            for (k, batch) in batches.enumerated() {
                let index = base + k + 1
                let labels = batch.indices.map(SeedNoteBatcher.label)
                let byLabel = Dictionary(uniqueKeysWithValues: zip(labels, batch))
                lastError = nil
                var wholeBatchRewrite = false
                var firstCardRequest = true
                var splitting = false
                let result = await SeedNoteParser.cardsWithOneRewrite(labels: labels, user: names.user) { requested, reason in
                    let single = !firstCardRequest && reason == nil
                    firstCardRequest = false
                    if single, !splitting {
                        splitting = true
                        run.section("第 \(index) 批整批没出卡 · 拆成 \(labels.count) 份单问", body: batch.map(\.path).joined(separator: "\n"))
                    }
                    if reason != nil { wholeBatchRewrite = requested.count == labels.count }
                    let userText = SeedNotePrompts.cardsUser(requested.map { byLabel[$0]! }, labels: requested)
                    return await ask(SeedNoteRequest.make(system: system, user: userText, rewrite: reason),
                                     title: "要点卡 第 \(index) 批（\(requested.count) 份）" + (single ? " · 拆单 \(requested[0])" : reason == nil ? "" : " · 重写"))
                }
                if result.split {
                    if progress.splitBatches == nil { progress.splitBatches = [] }
                    progress.splitBatches?.append(.init(index: index, recovered: result.cards.count))
                }
                let link = run.link(anchor: currentAnchor)
                let made = batch.enumerated().compactMap { i, item -> SeedNoteCard? in
                    guard let b = result.cards[labels[i]] else { return nil }
                    return SeedNoteCard(path: item.path, version: item.version, name: item.name, layer: item.layer, title: b.title, gist: b.gist,
                                        mentions: b.mentions, aboutUser: b.aboutUser, group: b.group, when: b.when,
                                        model: task.modelName, madeAt: job.now, run: link, sourceContext: item.sourceContext, factDomain: b.factDomain)
                }
                let saved = await Task.detached(priority: .utility) { () -> (cards: [SeedNoteCard], errors: [String: String]) in
                    var cards: [SeedNoteCard] = []
                    var errors: [String: String] = [:]
                    for card in made {
                        do {
                            guard let snapshot, let material = snapshot.entries.first(where: { $0.path == card.path }),
                                  material.version == card.version,
                                  // 可出卡层 version = sha(text)，digest 校验等于按 version 算法复核。
                                  material.digest == card.version, let text = snapshot.text(card.path) else {
                                errors[card.path] = "冻结原料缺失或版本与卡不符，未发布 L2 / 卡"
                                continue
                            }
                            try cardStore.saveOriginal(path: card.path, version: card.version, text: text, sourceContext: card.sourceContext)
                            try cardStore.save(card)
                            cards.append(card)
                        }
                        catch { errors[card.path] = "卡没存成：\(error.localizedDescription)" }
                    }
                    return (cards, errors)
                }.value
                for card in saved.cards {
                    carded[card.path] = card.version
                    newCardPaths.insert(card.path)
                }
                let missing = batch.filter { carded[$0.path] != $0.version }.map(\.path)
                let reasons = batch.enumerated().compactMap { i, item -> String? in
                    guard carded[item.path] != item.version else { return nil }
                    let reason: String
                    if case .blocked(let why)? = stopped { reason = "被拦：\(why)" }
                    else if case .cancelled? = stopped { reason = "停了" }
                    else if let error = saved.errors[item.path] { reason = error }
                    else if let raw = lastError, CatalogSeedPrompts.contextTooLong(raw) {
                        reason = saved.cards.isEmpty
                            ? CatalogSeedPrompts.batchContextNote(batch: index, paths: missing, model: task.modelName, raw: raw)
                            : (wholeBatchRewrite ? "整批重写请求过长：\(raw)" : "没出卡原料的重写请求过长：\(raw)")
                    } else if let raw = lastError { reason = "请求出错：\(raw)" }
                    else { reason = result.failures[labels[i]] ?? "没有这份原料的卡" }
                    failed.append("没出成要点卡：\(item.name) · \(reason)")
                    return "\(item.path)：\(reason)"
                }
                if !saved.cards.isEmpty { progress.batches.append(.init(index: index, paths: saved.cards.map(\.path), ok: true)) }
                if !missing.isEmpty {
                    let reason = reasons.joined(separator: "\n")
                    progress.batches.append(.init(index: index, paths: missing, ok: false, reason: reason))
                }
                let longTitles = saved.cards.reduce(0) { $0 + ($1.title.count > SeedNoteParser.titleLimit ? 1 : 0) }
                let summary = "\(saved.cards.count) 张合格（其中 \(longTitles) 张标题超长收下）· \(result.rewritten) 张重写 · \(missing.count) 张没出成；" + factDomainSummary(saved.cards)
                let soft = result.softNotes
                run.section("要点卡 第 \(index) 批 · 校验", body: summary
                            + (saved.cards.isEmpty ? "\n这一批没出卡" : "\n已存进 .cards/\n\n")
                            + saved.cards.map { "- \($0.name) · \($0.title)：\($0.gist)（\($0.group)；域 \($0.factDomain?.rawValue ?? "旧卡无域")；mentions \($0.mentions.count)）" }.joined(separator: "\n")
                            + (reasons.isEmpty ? "" : "\n\n没出成的原料：\n" + reasons.joined(separator: "\n"))
                            + (result.batchProblems.isEmpty ? "" : "\n\n批级问题：\n" + result.batchProblems.joined(separator: "\n"))
                            + (soft.isEmpty ? "" : "\n\n软检查（只记不打回）：\n" + soft.map { "- " + $0 }.joined(separator: "\n")))
                await seedLog(job, "第 \(index) 批：" + summary + (saved.cards.isEmpty ? "（这一批没出卡）" : "")
                              + (soft.isEmpty ? "" : "（软检查提醒 \(soft.count) 条）"), ok: !saved.cards.isEmpty, cost: takeCost())
                task.carded = carded
                task.notes = progress
                if let error = await persist() { return .failure(.failed("checkpoint 没存成：\(error)")) }
                if let stop = stopped { return .failure(stop) }
                if lastError != nil {
                    return .failure(.failed("要点卡请求出错，先停下了（点「继续这个种子任务」只重跑没出卡的原料）：\n" + reasons.joined(separator: "\n")))
                }
            }
            return .success(failed)
        }

        func runNotes() async -> SeedOutcome {
            let snapshot = job.snapshot
            let names = job.names
            let entry = task.entry
            let day = CatalogSurvey.day(task.createdAt)
            let items: [CatalogSeedMaterials.Item]
            do {
                items = try await Task.detached(priority: .utility) { try snapshot.items() }.value
            } catch {
                let note = "原料快照读不到（\(error)），出不了要点卡。可以放弃这个种子任务再重新播种"
                await seedLog(job, note, ok: false, cost: nil)
                return await finish(.failed(note))
            }
            let cardable = items.filter { SeedNoteBatcher.cardable($0, entry: entry) }
            var carded = task.carded ?? [:]
            var progress = task.notes ?? SeedNoteProgress()
            if boundary() { return await finish(.cancelled) }

            // 1. 出卡
            job.onStage?("cards")
            let uncardedNotes: [String]
            switch await makeCards(cardable, carded: &carded, progress: &progress) {
            case .failure(let stop): return await finish(stop)
            case .success(let failed): uncardedNotes = failed
            }
            if boundary() { return await finish(.cancelled) }
            let cardStore = SeedNoteStore(wiki: wiki)
            let cardedItems = cardable.filter { carded[$0.path] == $0.version }
            let cards = await Task.detached(priority: .utility) {
                cardedItems.compactMap { item -> SeedNoteCard? in
                    guard var card = cardStore.load(path: item.path, version: item.version) else { return nil }
                    card.sourceContextIssue = card.contextIssue(for: item.sourceContext)
                    return card
                }
            }.value
            guard cards.count == cardedItems.count else {
                let note = "有 \(cardedItems.count - cards.count) 份原料的要点卡读不回来（.cards/ 被动过？），点「继续这个种子任务」会重新出"
                task.carded = Dictionary(cards.map { ($0.path, $0.version) }, uniquingKeysWith: { a, _ in a })
                await seedLog(job, note, ok: false, cost: nil)
                return await finish(.failed(note))
            }
            let contextIssues = Dictionary(cards.compactMap { card in
                card.sourceContextIssue.map { (card.path, $0) }
            }, uniquingKeysWith: { a, _ in a })
            progress.sourceContextIssues = contextIssues.isEmpty ? nil : contextIssues
            task.notes = progress
            let reusedCards = cards.filter { !newCardPaths.contains($0.path) }
            if !reusedCards.isEmpty || !contextIssues.isEmpty {
                let issues = cards.filter { $0.sourceContextIssue != nil }.sorted { $0.path < $1.path }.map { card in
                    let kind = newCardPaths.contains(card.path) ? "新卡" : "旧卡"
                    let domain = card.factDomain.map { "\(kind)标 \($0.rawValue) 域" } ?? "\(kind)无域"
                    let retained = kind == "旧卡" ? "保留旧卡；" : ""
                    return "\(card.path)：\(card.sourceContextIssue!.note)（\(retained)\(domain)，本轮按待判）"
                }
                run.section("要点卡 · 来源上下文检查", body: "复用卡原域：\(factDomainSummary(reusedCards))；本轮上下文待判 \(contextIssues.count)"
                            + (issues.isEmpty ? "" : "\n" + issues.joined(separator: "\n")))
            }
            if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
            guard !cardable.isEmpty else {
                return await finish(.emptyOutline("没有可出要点卡的原料：Prompt 和 CC 记忆都是空的，已有 wiki 页只作更新基线"))
            }
            guard !cards.isEmpty else {
                let note = "有 \(cardable.count) 份原料没出要点卡，先停下了（点「继续这个种子任务」只重跑没出卡的原料）：\n" + uncardedNotes.joined(separator: "\n")
                return await finish(.failed(note))
            }
            if !uncardedNotes.isEmpty {
                await seedLog(job, "\(uncardedNotes.count) 份没出要点卡，先按其余出目录", ok: true, cost: nil)
            }
            if boundary() { return await finish(.cancelled) }

            // 2. 聚合（纯代码）
            job.onStage?("aggregate")
            let agg = CatalogSeedNotes.aggregate(cards: cards, names: names)
            let realCards = cards.filter { $0.effectiveFactDomain == .realWorld }
            let cardsByPath = Dictionary(cards.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let theatrePool = agg.theatrePaths.compactMap { cardsByPath[$0] }
            let pendingPool = agg.pendingPaths.compactMap { cardsByPath[$0] }
            let wikiPages = items.filter { $0.layer == "wiki" }.compactMap { item -> WikiPage? in
                guard let path = CatalogSeedMaterials.pagePath(item.path) else { return nil }
                return WikiPage.parse(item.text, path: path)
            }
            let unknownPageCount = wikiPages.filter { $0.factDomain == nil }.count
            run.section("聚合", body: "卡 \(cards.count) 张 → 实体 \(agg.entities.count) 个 · 本人池 \(agg.userPaths.count) 份 · 无实体池 \(agg.loosePaths.count) 份\n\n"
                        + agg.entities.map { "- \($0.display) · \($0.group) · \($0.paths.count) 份" + ($0.aliases.isEmpty ? "" : "（又写作 \($0.aliases.joined(separator: "、"))）") }.joined(separator: "\n"))

            // 3. 对齐（只合并不新增；名单上千时切片，每片一次请求，哪片失败哪片按原名）
            job.onStage?("align")
            let anchors = wikiPages.filter { $0.factDomain == .realWorld }.map(SeedNoteAnchor.wiki) + [.user]
            run.section("对齐锚 · 事实域", body: "nil 域已有页 \(unknownPageCount) 页未作锚")
            let alignment: SeedNoteAlignment
            if progress.aligned, let saved = await Task.detached(priority: .utility, operation: { tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: taskId) }).value,
               Set(saved.groups.flatMap(\.paths) + saved.userPaths) == Set(agg.entities.flatMap(\.paths)),
               saved.groups.allSatisfy({ group in group.existingPage == nil || anchors.contains { $0.page == group.existingPage } }) {
                alignment = saved
                run.section("实体对齐 · 沿用上次存下的结果", body: "\(saved.groups.count) 个实体；本人 \(saved.userPaths.count) 份")
            } else if agg.entities.isEmpty {
                alignment = SeedNoteAlignment(groups: [])
            } else {
                // 重新对齐：上次的聚类是按旧对齐分的池，先作废并落盘
                if progress.aligned || progress.clustered {
                    progress.aligned = false
                    progress.clustered = false
                    task.notes = progress
                    run.section("重新对齐：上次的聚类结果作废", body: "对齐结果读不回来或没存成，按现在的卡重新对齐；聚类跟着重做")
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                }
                let system = SeedNotePrompts.align(names: names, entry: entry, day: day)
                let slices = CatalogSeedNotes.alignSlices(agg.entities)
                var merges: [SeedNoteParser.Merge] = []
                var okSlices = 0
                var sliceNotes: [String] = []
                for (s, slice) in slices.enumerated() {
                    let userText = SeedNotePrompts.alignUser(groups: slice, anchors: anchors)
                    let title = "实体对齐" + (slices.count > 1 ? " 第 \(s + 1) / \(slices.count) 片" : "")
                    let result = await SeedNoteParser.withOneRewrite(ask: { reason in
                        await ask(SeedNoteRequest.make(system: system, user: userText, rewrite: reason), title: title + (reason == nil ? "" : " · 重写"))
                    }, parse: { SeedNoteParser.merges($0, user: names.user) })
                    if let stop = stopped { _ = await persist(); return await finish(stop) }
                    switch result {
                    case .success(let m):
                        merges += m
                        okSlices += 1
                    case .failure(let f):
                        sliceNotes.append("\(title)没成（这片按原名）：\(f.message)")
                        run.section("\(title) · 没成", body: CatalogRunRecord.code(f.message))
                    }
                }
                alignment = CatalogSeedNotes.align(groups: agg.entities, anchors: anchors, merges: okSlices > 0 ? merges : nil)
                let mergedLines = alignment.groups.filter { !$0.mergedFrom.isEmpty || $0.existingPage != nil }.map {
                    "- \($0.display)" + ($0.mergedFrom.isEmpty ? "" : " ← \($0.mergedFrom.joined(separator: "、"))") + ($0.existingPage.map { " → 已有页 \($0)" } ?? "")
                }
                run.section("实体对齐 · 结果", body: (okSlices == 0 ? "实体对齐没成，目录按原名\n\n" : "")
                            + "合并后 \(alignment.groups.count) 个实体；合进本人 \(alignment.userPaths.count) 份\n\n" + (mergedLines.isEmpty ? "（没有合并）" : mergedLines.joined(separator: "\n"))
                            + (alignment.dropped.isEmpty ? "" : "\n\n丢掉的合并组：\n" + alignment.dropped.map { "- " + $0 }.joined(separator: "\n"))
                            + (sliceNotes.isEmpty ? "" : "\n\n" + sliceNotes.joined(separator: "\n")))
                await seedLog(job, okSlices == 0 ? "实体对齐没成，目录按原名" : "实体对齐：\(agg.entities.count) 个名字 → \(alignment.groups.count) 个实体" + (sliceNotes.isEmpty ? "" : "（\(sliceNotes.count) 片没成）"),
                              ok: okSlices > 0, cost: takeCost())
                let toSave = alignment
                if let error = await Task.detached(priority: .utility, operation: { () -> String? in
                    do { try tasks.saveNotes(toSave, name: CatalogSeedTaskStore.alignedFileName, id: taskId); return nil } catch { return error.localizedDescription }
                }).value {
                    run.section("对齐结果没存成（续跑会重新对齐）", body: CatalogRunRecord.code(error))
                } else {
                    progress.aligned = true
                    task.notes = progress
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                }
            }

            if boundary() { return await finish(.cancelled) }

            // 3'. 回扫补配（纯代码；只扫本任务同版本已出卡且可出卡的原料）
            job.onStage?("backfill")
            let realPaths = Set(realCards.map(\.path))
            let texts = Dictionary(cardable.filter { carded[$0.path] == $0.version && realPaths.contains($0.path) }.map { ($0.path, $0.text) }, uniquingKeysWith: { a, _ in a })
            let groups = CatalogSeedNotes.backfill(groups: alignment.groups, texts: texts, factDomains: Dictionary(realCards.map { ($0.path, SeedFactDomain.realWorld) }, uniquingKeysWith: { a, _ in a }))
            let backfilled = groups.filter { !($0.candidates ?? []).isEmpty }
            run.section("回扫候选（不算正式原料，写页只给要点卡）", body: backfilled.isEmpty ? "没有" : backfilled.map { g in
                "- \(g.display)：正式原料 \(g.paths.count) 份 · 回扫候选 \(g.candidates?.count ?? 0) 份（" + (g.candidates ?? []).map { "\($0.path) 命中 \($0.hits.joined(separator: "、"))" }.joined(separator: "；") + "）"
            }.joined(separator: "\n"))

            // 4. 聚类（本人池按方面起页、无实体池按话题起页）
            job.onStage?("cluster")
            let userPaths = Set(agg.userPaths).union(alignment.userPaths)
            let entityPaths = Set(groups.filter(CatalogSeedNotes.opensEntityPage).flatMap(\.paths))
            let userPool = realCards.filter { userPaths.contains($0.path) }
            let loosePool = realCards.filter { !userPaths.contains($0.path) && !entityPaths.contains($0.path) }
            let existingPages = Dictionary(wikiPages.map { ($0.path, $0.factDomain) }, uniquingKeysWith: { a, _ in a })
            let entityPagePaths = Set(groups.filter(CatalogSeedNotes.opensEntityPage).map { $0.existingPage ?? "\($0.group)/\($0.display)" })
            let clusters: SeedNoteClusters
            if progress.clustered, let saved = await Task.detached(priority: .utility, operation: { tasks.loadNotes(SeedNoteClusters.self, name: CatalogSeedTaskStore.clusteredFileName, id: taskId) }).value,
               CatalogSeedNotes.reusableClusters(saved, user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool, existingPages: existingPages, entityPaths: entityPagePaths) {
                clusters = saved
                run.section("聚类 · 沿用上次存下的结果", body: "本人页 \(saved.userPages.count) · 主题页 \(saved.topics.count) · 没归进目录 \(saved.unplaced.count)")
            } else if userPool.isEmpty, loosePool.isEmpty, theatrePool.isEmpty, pendingPool.isEmpty {
                clusters = SeedNoteClusters()
                run.section("聚类", body: "四个池都是空的，不用问")
            } else {
                let labels = CatalogSeedNotes.clusterLabels(user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool)
                let system = SeedNotePrompts.cluster(names: names, entry: entry, day: day)
                let userText = SeedNotePrompts.clusterUser(user: labels.user, loose: labels.loose, theatre: labels.theatre, pending: labels.pending)
                let result = await SeedNoteParser.withOneRewrite(ask: { reason in
                    await ask(SeedNoteRequest.make(system: system, user: userText, rewrite: reason), title: "聚类" + (reason == nil ? "" : " · 重写"))
                }, parse: { SeedNoteParser.clusters($0, user: names.user) },
                   salvage: { SeedNoteParser.clusters($0, user: names.user, salvaging: true) })
                if let stop = stopped { _ = await persist(); return await finish(stop) }
                var failNote: String?
                var soft: [String] = []
                var partial: SeedNoteClusters
                switch result {
                case .success(let reply):
                    partial = CatalogSeedNotes.clusters(user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool, reply: reply)
                    soft = reply.softNotes
                case .failure(let f):
                    failNote = f.message
                    partial = CatalogSeedNotes.clusters(user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool, reply: nil)
                }
                let firstPages = partial
                partial = CatalogSeedNotes.reopenThinClusters(partial, user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool, existingPages: existingPages)
                if !partial.unplaced.isEmpty {
                    let missing = Set(partial.unplaced.map(\.path))
                    let missingUser = labels.user.filter { missing.contains($0.card.path) }
                    let missingLoose = labels.loose.filter { missing.contains($0.card.path) }
                    let recoveryText = SeedNotePrompts.clusterRecovery(user: missingUser, loose: missingLoose,
                        theatre: labels.theatre.filter { missing.contains($0.card.path) }, pending: labels.pending.filter { missing.contains($0.card.path) },
                        existing: firstPages, existingPages: existingPages)
                    run.section("聚类 · 第二轮补漏 · 问哪些", body: recoveryText)
                    let recovery = await SeedNoteParser.withOneRewrite(ask: { reason in
                        await ask(SeedNoteRequest.make(system: system, user: recoveryText, rewrite: reason), title: "聚类 · 第二轮补漏" + (reason == nil ? "" : " · 重写"))
                    }, parse: { SeedNoteParser.clusters($0, user: names.user) },
                       salvage: { SeedNoteParser.clusters($0, user: names.user, salvaging: true) })
                    if let stop = stopped { _ = await persist(); return await finish(stop) }
                    switch recovery {
                    case .success(let reply):
                        partial = CatalogSeedNotes.clusters(user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool, reply: reply, existing: partial)
                        soft += reply.softNotes
                    case .failure(let failure):
                        failNote = [failNote, failure.message].compactMap { $0 }.joined(separator: "\n")
                    }
                    partial = CatalogSeedNotes.reopenThinClusters(partial, user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool, existingPages: existingPages)
                    run.section("聚类 · 第二轮补漏 · 剩哪些", body: partial.unplaced.isEmpty ? "没有漏卡" : partial.unplaced.map {
                        "- \($0.path) · \($0.title)：\($0.gist)"
                    }.joined(separator: "\n") + "\n\n以上进各组待归类。")
                }
                clusters = CatalogSeedNotes.completeClusters(partial, user: userPool, loose: loosePool, theatre: theatrePool, pending: pendingPool, existingPages: existingPages, entityPaths: entityPagePaths)
                run.section("聚类 · 结果", body: (failNote.map { "聚类请求没成（漏卡由各组待归类兜底）：\n" + CatalogRunRecord.code($0) + "\n\n" } ?? "")
                            + "本人页 \(clusters.userPages.count)：" + clusters.userPages.map { "\($0.path)（\($0.paths.count) 份）" }.joined(separator: "、")
                            + "\n主题页 \(clusters.topics.count)：" + clusters.topics.map { "\($0.path)（\($0.paths.count) 份）" }.joined(separator: "、")
                            + "\n设定页 \(clusters.theatre.count)：" + clusters.theatre.map { "\($0.path)（\($0.paths.count) 份）" }.joined(separator: "、")
                            + "\n待判页 \(clusters.pending.count)：" + clusters.pending.map { "\($0.path)（\($0.paths.count) 份）" }.joined(separator: "、")
                            + "\n没归进目录 \(clusters.unplaced.count) 份"
                            + "\n改了前缀 \(clusters.normalizedPrefixCount + clusters.reassignedPoolCount) 条"
                            + "\n同数组改前缀 \(clusters.normalizedPrefixCount) 条"
                            + "\n跨数组归位 \(clusters.reassignedPoolCount) 条"
                            + "\ntitle 抄了成员卡，改用页名 \(clusters.copiedTitleCount) 条"
                            + (clusters.dropped.isEmpty ? "" : "\n\n丢掉的：\n" + clusters.dropped.map { "- " + $0 }.joined(separator: "\n"))
                            + (soft.isEmpty ? "" : "\n\n软检查（只记不打回）：\n" + soft.map { "- " + $0 }.joined(separator: "\n")))
                await seedLog(job, failNote == nil ? "聚类：本人页 \(clusters.userPages.count) · 主题页 \(clusters.topics.count) · 没归进目录 \(clusters.unplaced.count) 份"
                              + (soft.isEmpty ? "" : "（软检查提醒 \(soft.count) 条）")
                              : "聚类请求没成，已由各组待归类兜底", ok: failNote == nil, cost: takeCost())
                let toSave = clusters
                if let error = await Task.detached(priority: .utility, operation: { () -> String? in
                    do { try tasks.saveNotes(toSave, name: CatalogSeedTaskStore.clusteredFileName, id: taskId); return nil } catch { return error.localizedDescription }
                }).value {
                    run.section("聚类结果没存成（续跑会重新聚类）", body: CatalogRunRecord.code(error))
                } else {
                    progress.clustered = true
                    task.notes = progress
                    if let error = await persist() { return await finish(.failed("checkpoint 没存成：\(error)")) }
                }
            }
            func domainSummary(theatrePages: Int, pendingPages: Int) -> String {
                "设定池 \(theatrePool.count) 卡 → \(theatrePages) 页 · 待判池 \(pendingPool.count) 卡 → \(pendingPages) 页（其中旧卡无域 \(agg.legacyDomainCount)） · 另起路径 \(clusters.relocated.count) · nil 域已有页 \(unknownPageCount) 页未作锚"
            }
            let clusterDomains = domainSummary(theatrePages: clusters.theatre.count, pendingPages: clusters.pending.count)
            run.section("聚类 · 分域汇总", body: clusterDomains + (clusters.relocated.isEmpty ? "" : "\n" + clusters.relocated.joined(separator: "\n")))

            if boundary() { return await finish(.cancelled) }

            // 5. 目录（代码聚出来，过 checkDirection，存成提案等批）
            job.onStage?("outline")
            let snapshotTask = task
            let outline = await Task.detached(priority: .utility) { CatalogSeedNotes.outline(groups: groups, clusters: clusters, cards: cards, names: names, task: snapshotTask, wiki: wiki, existingPages: existingPages) }.value
            if boundary() { return await finish(.cancelled) }
            let directions = outline.items.compactMap { $0.change.direction }
            let placed = Set(directions.flatMap { $0.sources ?? [] })
            let unplaced = cards.filter { !placed.contains($0.path) }
            let folded = groups.filter { !CatalogSeedNotes.opensEntityPage($0) }
            let foldedPaths = Set(folded.flatMap(\.paths))
            let moved = loosePool.filter { foldedPaths.contains($0.path) }.count
            let qualified = groups.filter { $0.existingPage != nil || Set($0.paths).count >= CatalogSettings.seedEntityPageMinSources }.count
            let personaDirect = groups.count - qualified - folded.count
            let outlineDomains = domainSummary(theatrePages: directions.filter { $0.factDomain == .inWorld }.count,
                pendingPages: directions.filter { $0.factDomain == .mixed || $0.factDomain == .unspecified }.count)
            run.section("门槛汇总", body: "实体 \(agg.entities.count) 个 · 够 \(CatalogSettings.seedEntityPageMinSources) 份 / 已有页锚 \(qualified) 个 · 人设层直开（人） \(personaDirect) 个 · 不够 \(CatalogSettings.seedEntityPageMinSources) 份 \(folded.count) 个（转无实体池 \(moved) 张）\n"
                        + "（按对齐后 \(groups.count) 个实体分三类；已有页锚不受门槛限制）\n"
                        + "最终本人池 \(userPool.count) 份 · 无实体池 \(loosePool.count) 份\n\n不够门槛的名字：\n"
                        + (folded.isEmpty ? "（没有）" : folded.map { "- \($0.display) · \($0.group) · \(Set($0.paths).count) 份" }.joined(separator: "\n")))
            let entityRelocations = "实体撞旧页另起路径 \(outline.relocated.count) 项"
            run.section("目录", body: "\(outline.items.count) 项 · 已安置 \(placed.count) 卡 · 待判 \(pendingPool.filter { placed.contains($0.path) }.count) 卡\n\(outlineDomains)\n\(entityRelocations)"
                        + (outline.relocated.isEmpty ? "" : "\n" + outline.relocated.joined(separator: "\n"))
                        + (outline.dropped.isEmpty ? "" : "；扔了 \(outline.dropped.count) 项：\n" + outline.dropped.map { "- " + $0 }.joined(separator: "\n"))
                        + "\n\n" + outline.items.compactMap { $0.change.direction }.map { "- \($0.path) · \($0.title) · 原料 \($0.sources?.count ?? 0) 份：\(($0.sources ?? []).joined(separator: "、"))"
                            + ($0.candidates.map { " · 回扫候选 \($0.count) 份：" + $0.map(\.path).joined(separator: "、") } ?? "") }.joined(separator: "\n"))
            await seedLog(job, "目录 \(outline.items.count) 项 · 已安置 \(placed.count) 卡 · 待判 \(pendingPool.filter { placed.contains($0.path) }.count) 卡 · \(outlineDomains) · \(entityRelocations)", ok: true, cost: nil)
            guard !outline.items.isEmpty else {
                return await finish(.emptyOutline("所有卡都没有实体也聚不出页" + (outline.dropped.isEmpty ? "" : "（目录项没过检查 \(outline.dropped.count) 项：\(outline.dropped.joined(separator: "；"))）")))
            }
            let skipped = task.skipped + uncardedNotes + unplaced.map { "没归进目录：\($0.name) · \($0.title)：\($0.gist)" } + outline.dropped.map { "目录项没过检查：\($0)" }
            return await saveOutline(outline.items, skipped: skipped)
        }

        /// 存目录：`WikiProposal(id: 任务 id, origin: .seed)`，停下等批
        func saveOutline(_ items: [WikiProposal.Item], skipped: [String]) async -> SeedOutcome {
            if isCancelled { return await finish(.cancelled) }
            let existing = await loadOutline()
            job.onOutlineSave?(false)
            // 读已存目录的时候点了停：不交
            if isCancelled { return await finish(.cancelled) }
            if let existing {
                task.outlineSaved = true
                out.outlineItems = existing.items.count
                await seedLog(job, "目录已存（对上了上次存下的 \(existing.items.count) 项）", ok: true, cost: nil)
                task.state = .waiting
                return await finish(.outlineSubmitted)
            }
            var proposal = WikiProposal(id: taskId, origin: .seed, createdAt: job.now, title: "种子目录 · \(task.entry.label)",
                                        seedSkipped: skipped.isEmpty ? nil : skipped, items: items, run: run.link(anchor: currentAnchor))
            proposal.seedTask = taskId
            let saved = proposal
            let saveError = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try proposals.save(saved)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            job.onOutlineSave?(true)
            if let saveError {
                await seedLog(job, "目录没存成：\(saveError)", ok: false, cost: nil)
                return await finish(.failed("目录没存成：\(saveError)"))
            }
            task.outlineSaved = true
            task.state = .waiting
            out.outlineItems = items.count
            await seedLog(job, "交了目录 \(items.count) 项" + (skipped.isEmpty ? "" : "（没归进目录 / 没读的 \(skipped.count) 条列在提案上）"), ok: true, cost: nil)
            // 写目录的时候点了停：目录留在盘上（续跑对上它，不重聚），这一次算停了
            if isCancelled { return await finish(.cancelled) }
            if let error = await persist() { return await finish(.failed("目录存了，checkpoint 没存成（重启续跑会对上这份目录）：\(error)")) }
            return await finish(.outlineSubmitted)
        }

        if isCancelled { return await finish(.cancelled) }
        if task.outlineSaved {
            job.onStage?("pages")
            if let note = job.control {
                run.section("审批后继续 · 审批结果（只记录：写正文每页单开一段对话，不发给模型）", body: CatalogRunRecord.code(note))
            }
            return await writePages()
        }
        return await runNotes()
    }

    private struct SeedHandled {
        var text: String
        var isError = false
        var note: String
        var readPath: String? = nil
    }

    /// 写正文那段对话里的 submit_proposal（phase = page）
    private func handleSeedCall(_ call: ToolCallBlock, job: SeedJob, task: inout CatalogSeedTask, delivered: [String: String],
                                out: inout SeedOutcome) async -> SeedHandled {
        let json = call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON
        /// 诊断写在最后：被截断、坏了都只丢诊断，诊断键之前那段完整就照收
        let args = CatalogSeedTools.parse(json, truncated: call.truncated, user: job.names.user)
        let truncated = call.truncated && args == nil
        if call.name == CatalogAgentTools.submit, truncated || args == nil {
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
        guard call.name == CatalogAgentTools.submit else {
            return SeedHandled(text: "没有这个工具：\(call.name)", isError: true, note: call.name)
        }
        if truncated {
            return SeedHandled(text: "输出太长被截断了：这一页少写几条，再交", isError: true, note: "交的输出被截断")
        }
        guard args.phase == "page" else {
            return SeedHandled(text: "phase 只能是 page（目录已经交过了）", isError: true, note: "submit phase 不对")
        }
        return await submitPage(args, call: call, json: json, job: job, task: &task, delivered: delivered, out: &out)
    }

    /// 写正文那段对话里的调用：只认给这一项交页
    private func handlePageCall(_ call: ToolCallBlock, item: WikiProposal.Item, title: String, job: SeedJob, task: inout CatalogSeedTask,
                                out: inout SeedOutcome) async -> SeedHandled {
        if call.name == "read" {
            let path = CatalogSeedTools.parse(call.argumentsJSON, user: job.names.user)?.path.map { WikiStore.stored($0, user: job.names.user) }
            guard let path, item.change.direction?.sources?.contains(path) == true else {
                return SeedHandled(text: "只能 read 这一项的一份原料 path", isError: true, note: "窄读不在本项的原料")
            }
            let snapshot = task
            let text = await Task.detached(priority: .utility) { () -> String? in
                guard let text = snapshot.readText(path, wiki: job.wiki) else { return nil }
                let material = snapshot.materials.first { $0.path == path }
                var card = snapshot.carded?[path].flatMap { version in
                    version == snapshot.read[path] ? SeedNoteStore(wiki: job.wiki).load(path: path, version: version) : nil
                }
                let contextIssue = card?.contextIssue(for: material?.sourceContext)
                card?.sourceContextIssue = contextIssue
                let header = CatalogSeedPrompts.jsonLine([("path", path), ("layer", material?.layer ?? ""),
                    ("fact_domain", card?.effectiveFactDomain?.rawValue ?? "unspecified")], sourceContext: material?.sourceContext)
                return header + "\n" + text
            }.value
            guard let text else {
                return SeedHandled(text: "这一份原料快照读不到，没有另外读盘补", isError: true, note: "窄读快照缺失 \(path)")
            }
            return SeedHandled(text: text, note: "窄读原料 \(path)", readPath: path)
        }
        guard call.name == CatalogAgentTools.submit else {
            return SeedHandled(text: "只用 read 单份原料核对原话，写好用 submit_proposal（phase = page，item = \(item.id)）交",
                               isError: true, note: "\(call.name)（本页不支持）")
        }
        let args = CatalogSeedTools.parse(call.argumentsJSON, truncated: call.truncated, user: job.names.user)
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

    /// 开场的写法：改了（比如目录 / 这一项改成每项一行 JSON，路径不再和分类、标题用「 · 」串在一起）旧的那段对话重开一次
    nonisolated static let pageOpeningFormat = "开场 4 · L1 条目 + 域"

    /// 开这一页对话时的开场写法、本项的目标、原料和读到的版本（别的目录项变了不算）
    nonisolated static func pageKey(_ d: WikiProposal.Direction, task: CatalogSeedTask, feedback: [WikiFeedback.Entry] = []) -> String {
        let paths = (d.sources ?? []) + (d.action == .update ? [CatalogSeedMaterials.wikiPath(d.path)] : [])
        let identities = feedback.map { "\($0.operationId)@\(WikiStore.version(of: Data($0.reason.utf8)).prefix(12))" }
        return ([pageOpeningFormat, d.path, d.action == .update ? "更新" : "新开"] + paths.map { "\($0)@\(task.read[$0] ?? "未读")" }
                + (d.candidates ?? []).map { "候选:\($0.path)@\(task.read[$0.path] ?? "未读"):" + Set($0.hits).sorted().joined(separator: "、") }
                + ["反馈:" + (identities.isEmpty ? "无" : identities.joined(separator: "、"))]).joined(separator: "\n")
    }

    nonisolated static func pageFeedback(_ d: WikiProposal.Direction, task: CatalogSeedTask, wiki: WikiStore, now: Date = Date()) -> [WikiFeedback.Entry] {
        WikiFeedback.select(.init(targetPath: d.path, sources: (d.sources ?? []).map {
            .init(path: $0, version: task.read[$0].flatMap { $0.isEmpty ? nil : $0 })
        }), wiki: wiki, now: now)
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

    /// 写一页送进去的开场（和记录里列的原料）：原料和要更新的已有页都只认任务的原料快照（正文和版本成对，和出处校验同一份），
    /// 不读盘补；缺了 / 对不上就停在这一页
    nonisolated static func pageOpening(_ item: WikiProposal.Item, outline: WikiProposal, task: CatalogSeedTask, wiki: WikiStore,
                                        revision: (asks: String, draft: String)? = nil,
                                        feedback: [WikiFeedback.Entry]? = nil) -> Result<(text: String, trace: String), PageProblem> {
        guard let d = item.change.direction else { return .failure(PageProblem(note: "目录项不见了")) }
        let byPath = Dictionary(task.materials.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let snapshot = task.snapshot(wiki: wiki)
        let paths = d.sources ?? []
        let cardStore = SeedNoteStore(wiki: wiki)
        var sources: [CatalogSeedPrompts.PageSource] = []
        for path in paths {
            var text: String?
            switch task.read[path] {
            case nil:
                return .failure(PageProblem(note: "checkpoint 不一致：「\(d.title)」列着的 \(path) 不在这次的原料快照清单里。这一页停在这里，没有另外读盘补"))
            case let version? where !version.isEmpty:
                guard let got = snapshot?.text(path) else {
                    return .failure(PageProblem(note: "checkpoint 不一致：「\(d.title)」列着的 \(path) 在清单里（版本 \(version.prefix(12))），原料快照里却找不到它的正文（快照缺了或被动过）。这一页停在这里，没有另外读盘补"))
                }
                text = got
            default:
                break
            }
            var card = task.carded?[path].flatMap { version in
                version == task.read[path] && !version.isEmpty ? cardStore.load(path: path, version: version) : nil
            }
            let contextIssue = card?.contextIssue(for: byPath[path]?.sourceContext)
            card?.sourceContextIssue = contextIssue
            sources.append(CatalogSeedPrompts.PageSource(path: path, layer: byPath[path]?.layer ?? "", name: card?.name ?? byPath[path]?.name ?? path,
                                                        text: card == nil ? text : nil, when: card?.when ?? [], title: card?.title, gist: card?.gist,
                                                        sourceContext: byPath[path]?.sourceContext, factDomain: card?.effectiveFactDomain))
        }
        var existing: String?
        if d.action == .update {
            let wikiPath = CatalogSeedMaterials.wikiPath(d.path)
            if let version = task.read[wikiPath], !version.isEmpty, let text = snapshot?.text(wikiPath) {
                existing = text
            } else {
                return .failure(PageProblem(note: "「\(d.title)」要更新的已有页 \(d.path) 不在这次的原料快照里（没有快照那一版的正文和版本），不能另外读盘补，这一页停在这里。可以放弃这个种子任务再重新播种"))
            }
        }
        // 回扫候选：只给它那张卡的标题 + 要点（不给全文，常见名字吸进很多份也撑不爆这一页），不能当出处
        let candidates = (d.candidates ?? []).filter { !paths.contains($0.path) }.map { c in
            let card = cardStore.load(path: c.path, version: task.carded?[c.path] ?? task.read[c.path] ?? "")
            return CatalogSeedPrompts.PageCandidate(path: c.path, layer: byPath[c.path]?.layer ?? "", name: byPath[c.path]?.name ?? c.path, hits: c.hits,
                                                    title: card?.title, gist: card?.gist,
                                                    sourceContext: byPath[c.path]?.sourceContext, factDomain: c.factDomain)
        }
        let selected = feedback ?? pageFeedback(d, task: task, wiki: wiki)
        let text = CatalogSeedPrompts.pageOpening(item, outline: outline, sources: sources, existing: existing, revision: revision,
                                                 candidates: candidates, entry: task.entry, feedback: WikiFeedback.render(selected))
        let listed = sources.map { s in
            "- \(s.path) · " + (s.title == nil
                ? "条目卡缺失，回退全文 · " + (s.text.map { "\($0.count) 字" } ?? "读的时候已经不在了")
                : "L1 条目 · 版本 \(task.carded?[s.path] ?? "")")
        }
        var trace = "只送：写页 system、整份目录、这一项条目的 L1（path / name / when / title / gist，不给全文）" + (existing == nil ? "" : "、要更新的已有页")
            + (candidates.isEmpty ? "" : "、回扫候选的要点卡（不给全文、不能当出处）")
            + "；不带出目录那段和别的原料\n\n这一页的原料（\(sources.count) 份）：\n" + listed.joined(separator: "\n")
        if !candidates.isEmpty {
            trace += "\n\n回扫候选（\(candidates.count) 份，只给卡）：\n" + candidates.map { "- \($0.path) · 命中 \($0.hits.joined(separator: "、"))" + ($0.title == nil ? " · 要点卡读不到" : "") }.joined(separator: "\n")
        }
        if let existing { trace += "\n\n要更新的已有页 \(d.path)：\(existing.count) 字（快照版本 \(task.read[CatalogSeedMaterials.wikiPath(d.path)] ?? "")）" }
        if let revision { trace += "\n\n带上一稿（\(revision.draft.count) 字）和修改要求：\n\(revision.asks)" }
        trace += "\n\n开场共 \(text.count) 字"
        return .success((text, trace))
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
            let args = CatalogSeedTools.Args(phase: "page", item: itemId)
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
            // 路径由目录项定：写手交的 path 写成别的（比如少抄半截）也按这一项算，不因此打回；
            // 但明说是另一页的（目录里别的项、这一项原料里别的已有页）不改成本页，打回
            sources.lockedPath = d.path
            sources.otherPages = Set((outline?.items ?? []).compactMap { $0.change.direction?.path }
                + (d.sources ?? []).compactMap(CatalogSeedMaterials.pagePath)).subtracting([d.path])
            let given = sources
            let seen = snapshot
            let user = job.names.user
            func check(_ raw: String, truncated: Bool = false) async -> (parsed: CatalogItems.Parsed?, page: (items: [WikiProposal.Item], dropped: [String])?, error: String) {
                let (parsed, parseError) = await Task.detached(priority: .utility) { () -> (CatalogItems.Parsed?, String) in
                    var failure = ""
                    let parsed = CatalogSeedTools.parsePage(raw, sources: given, wiki: wiki, truncated: truncated, user: user) { failure = $0 }
                    return (parsed, failure)
                }.value
                return (parsed, parsed.map { CatalogSeedTools.page($0, direction: d, task: seen, wiki: wiki) }, parseError)
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
                let reasons = (got.page?.dropped ?? []) + (got.parsed?.revisionNotes ?? [])
                let why = reasons.isEmpty ? "格式不对：\(got.error)" : reasons.joined(separator: "\n")
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
                "#### 工具回合 \(index + 1)\n" + traceTurn(turn)
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
            MemoryWriteLog.record(writer: .c3, profileId: job.task.profileId, ok: ok, note: "种子 · \(note)", model: job.task.modelName, run: link, memoryRoot: FileLibraryStore.memoryRoot(profileId: job.task.profileId))
        }
    }
}
