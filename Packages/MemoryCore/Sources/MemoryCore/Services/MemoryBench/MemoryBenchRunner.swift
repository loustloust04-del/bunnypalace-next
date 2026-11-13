import Foundation

/// 一格调模型的结果。usage = nil：回包没报用量（未知，不是 0）；usd = nil：金额未知（未计价 / 没调成），不是 $0
public struct MemoryBenchCallResult: Equatable, Sendable {
    public var text: String?
    public var usage: MemoryBenchUsage?
    public var usd: Double?
    public var costSource: MemoryBenchCostSource?

    public init(text: String? = nil, usage: MemoryBenchUsage? = nil, usd: Double? = nil, costSource: MemoryBenchCostSource? = nil) {
        self.text = text
        self.usage = usage
        self.usd = usd
        self.costSource = costSource
    }
}

/// 调模型：真跑用 `MemoryBenchRunner.liveCaller`，测试注入假的
public typealias MemoryBenchCaller = @Sendable (MemoryBenchModelRef, MemoryBenchPrompt) async throws -> MemoryBenchCallResult

public enum MemoryBenchRunError: LocalizedError, Equatable {
    case empty
    case tooMany(count: Int, limit: Int)
    case template(recipe: String, caseId: String, message: String)
    /// 用例 / 配方 / 模型里有重复的身份
    case duplicate(kind: String, id: String)
    /// 本机模型这一刀不能当被测模型（实际送出的提示词会被本机路线裁、取消也停不住，和记录对不上）
    case localModel(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "没有可跑的：至少选一个用例、一个配方、一个模型"
        case .tooMany(let count, let limit): return "这次要跑 \(count) 次，一次最多 \(limit) 次——少勾一个，或者先挑几个用例"
        case .template(let recipe, let caseId, let message): return "「\(recipe)」在用例 \(caseId) 上写错了：\(message)"
        case .duplicate(let kind, let id): return "\(kind)「\(id)」重复了，同一次跑里每个\(kind)只能有一个"
        case .localModel(let name): return "本机模型（\(name)）还不能拿来试写——它会悄悄裁掉放不下的对话、停也停不住，试出来的和记下来的对不上。换一个云端模型"
        }
    }
}

/// 一格要跑的：用例 × 配方 × 模型
public struct MemoryBenchJob: Equatable, Sendable {
    public let testCase: MemoryBenchCase
    public let recipe: MemoryBenchRecipe
    public let model: MemoryBenchModelRef

    public var cellId: String { "\(testCase.id)|\(recipe.id)|\(model.id)" }
}

/// 跑一次（plan-memory-audit-home-trial 第五节「跑一次」）：用例 × 配方 × 模型展开、超过上限直接拒（报数，不默默截）、
/// 先把所有模板渲染一遍（写错就一格都不发）、最多同时 3 个请求、能取消；每格一完成就把结果和请求记录落盘（中途被杀，付过钱的不丢），
/// 全部写完才标「完成」；每格解析 + 检查 + 自动配标签，打分，记一条汇总日志。只读用例、不碰任何记忆数据，不进健康状态
public enum MemoryBenchRunner {
    public static let maxCalls = 60
    public static let maxConcurrent = 3
    /// 估算输出按这么多 token 算（同 `SessionSegmentWriter.budgetBlock`）
    public static let estimatedOutputTokens = 1500

    // MARK: - 这个进程正在跑哪些（启动时只把不在这里的 running 标成中断）

    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeIds: Set<String> = []

    public static var activeRunIds: Set<String> {
        activeLock.lock(); defer { activeLock.unlock() }
        return activeIds
    }

    private static func setActive(_ id: String, _ on: Bool) {
        activeLock.lock(); defer { activeLock.unlock() }
        if on { activeIds.insert(id) } else { activeIds.remove(id) }
    }

    // MARK: - 展开 / 校验

    /// 按用例分组排：用例 → 配方 → 模型。三样各自不能有重复身份；只有离线执行可收本地引用
    public static func jobs(cases: [MemoryBenchCase], recipes: [MemoryBenchRecipe], models: [MemoryBenchModelRef],
                     limit: Int = maxCalls, allowLocal: Bool = false) throws -> [MemoryBenchJob] {
        if let id = firstDuplicate(cases.map(\.id)) { throw MemoryBenchRunError.duplicate(kind: "用例", id: id) }
        if let id = firstDuplicate(recipes.map(\.id)) { throw MemoryBenchRunError.duplicate(kind: "配方", id: id) }
        if let id = firstDuplicate(models.map(\.id)) { throw MemoryBenchRunError.duplicate(kind: "模型", id: id) }
        if !allowLocal, let local = models.first(where: \.local) { throw MemoryBenchRunError.localModel(local.name) }
        let count = cases.count * recipes.count * models.count
        guard count > 0 else { throw MemoryBenchRunError.empty }
        guard count <= limit else { throw MemoryBenchRunError.tooMany(count: count, limit: limit) }
        return cases.flatMap { c in recipes.flatMap { r in models.map { MemoryBenchJob(testCase: c, recipe: r, model: $0) } } }
    }

    private static func firstDuplicate(_ ids: [String]) -> String? {
        var seen: Set<String> = []
        return ids.first { !seen.insert($0).inserted }
    }

    public static func prompts(_ jobs: [MemoryBenchJob], writer: any MemoryBenchWriter) throws -> [MemoryBenchPrompt] {
        try jobs.map { job in
            do { return try writer.prompt(for: job.testCase, recipe: job.recipe) } catch {
                throw MemoryBenchRunError.template(recipe: job.recipe.name, caseId: job.testCase.id, message: error.localizedDescription)
            }
        }
    }

    /// 估算这次要花多少：知道价的格子相加；一个都不知道 = nil
    public static func estimate(_ jobs: [MemoryBenchJob], prompts: [MemoryBenchPrompt],
                         cost: (MemoryBenchModelRef, MemoryBenchPrompt) -> Double?) -> Double? {
        let known = zip(jobs, prompts).compactMap { cost($0.model, $1) }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    // MARK: - 跑

    public static func run(writer: any MemoryBenchWriter, set: MemoryBenchSet, caseIds: [String]? = nil,
                    recipes: [MemoryBenchRecipe], models: [MemoryBenchModelRef],
                    store: MemoryBenchStore, profileId: String, memoryRoot: @escaping @Sendable () -> URL,
                    local: @escaping @Sendable (MemoryBenchCase, MemoryBenchRecipe) async throws -> String,
                    caller: @escaping MemoryBenchCaller,
                    runId: String = UUID().uuidString, now: @escaping @Sendable () -> Date = { Date() },
                    onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> MemoryBenchRun {
        let cases = caseIds.map { ids in set.cases.filter { ids.contains($0.id) } } ?? set.cases
        let jobs = try jobs(cases: cases, recipes: recipes, models: models, allowLocal: writer.callStyle == .local)
        let prompts = try prompts(jobs, writer: writer)
        let stamped: @Sendable () -> Date = { MemoryBench.stamp(now()) }

        setActive(runId, true)
        defer { setActive(runId, false) }

        var run = MemoryBenchRun(id: runId, writer: writer.id, at: stamped(), finishedAt: nil, status: .running,
                                 set: .init(id: set.id, name: set.name, revision: set.revision),
                                 recipes: recipes, models: models, caseIds: cases.map(\.id),
                                 cells: [], judgments: [], scores: [], pinned: false, note: nil)
        try store.saveRun(run)

        // 每格完成就落盘（在这个任务上串行写，不和并发的格子抢文件）
        var persistError: Error?
        var finished = [Int]()
        await withTaskGroup(of: (Int, MemoryBenchCell, MemoryBenchRequest)?.self) { group in
            var next = 0
            func addNext() {
                guard next < jobs.count else { return }
                let i = next
                next += 1
                let job = jobs[i], prompt = prompts[i]
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let (cell, request) = await runCell(job, prompt: prompt, writer: writer, caller: caller, local: local, now: stamped)
                    return (i, cell, request)
                }
            }
            for _ in 0..<min(maxConcurrent, jobs.count) { addNext() }
            while let result = await group.next() {
                if let r = result {
                    let (i, cell, request) = r
                    finished.append(i)
                    run.cells.append(cell)
                    do {
                        try store.appendRequests([request], runId: run.id)
                        try store.saveRun(run)
                    } catch {
                        if persistError == nil { persistError = error }
                    }
                    onProgress?(finished.count, jobs.count)
                }
                if !Task.isCancelled { addNext() }
            }
        }

        // 收尾：按展开顺序排好、自动配标签、打分，最后才标完成
        let order = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($1.cellId, $0) })
        run.cells.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        let labels = Dictionary(cases.map { ($0.id, $0.labels) }, uniquingKeysWith: { a, _ in a })
        let at = stamped()
        run.judgments = run.cells.flatMap { cell in
            writer.autoJudge(items: cell.items, labels: labels[cell.caseId] ?? []).map {
                MemoryBenchJudgment(cellId: cell.id, item: $0.item, verdict: $0.verdict, labelId: $0.labelId, by: .auto, at: at)
            }
        }
        run.scores = run.scored(with: writer.scorers)
        run.status = Task.isCancelled || finished.count < jobs.count ? .cancelled : .done
        run.finishedAt = stamped()
        if let persistError {
            run.status = .failed
            run.note = "中途写盘失败：\(persistError.localizedDescription)"
        }
        try store.saveRun(run)
        logSummary(run, writer: writer, profileId: profileId, memoryRoot: memoryRoot)
        if let persistError { throw persistError }
        return run
    }

    private static func runCell(_ job: MemoryBenchJob, prompt: MemoryBenchPrompt, writer: any MemoryBenchWriter,
                                caller: MemoryBenchCaller, local: @Sendable (MemoryBenchCase, MemoryBenchRecipe) async throws -> String,
                                now: @Sendable () -> Date) async -> (MemoryBenchCell, MemoryBenchRequest) {
        let started = now()
        let clock = ContinuousClock.now
        var result = MemoryBenchCallResult()
        if writer.callStyle == .local {
            result.usd = 0
            result.costSource = .unpriced
        }
        var error: String?
        do {
            if writer.callStyle == .local {
                result = MemoryBenchCallResult(text: try await local(job.testCase, job.recipe),
                                               usage: nil, usd: 0, costSource: .unpriced)
            } else {
                result = try await caller(job.model, prompt)
            }
            if result.text == nil { error = "没有结果：被全局预算闸拦下，或模型没回内容" }
        } catch is CancellationError {
            error = "停下了"
        } catch let e {
            error = e.localizedDescription
        }
        let elapsed = ContinuousClock.now - clock
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let parsed = result.text.map { writer.parse(output: $0, testCase: job.testCase, recipe: job.recipe) }
        let cell = MemoryBenchCell(id: job.cellId, caseId: job.testCase.id, recipeId: job.recipe.id, modelId: job.model.id,
                                   output: result.text, items: parsed?.items ?? [], checks: parsed?.checks ?? [],
                                   usage: result.usage, usd: result.usd, costSource: result.costSource, ms: ms, error: error)
        let request = MemoryBenchRequest(cellId: job.cellId, at: started, model: job.model.id, system: prompt.system, user: prompt.user,
                                         response: result.text, error: error, usage: result.usage, usd: result.usd,
                                         costSource: result.costSource, ms: ms)
        return (cell, request)
    }

    /// 记忆日志一条汇总（试写标记，不算失败）
    public static func logSummary(_ run: MemoryBenchRun, writer: any MemoryBenchWriter, profileId: String, memoryRoot: @escaping @Sendable () -> URL) {
        guard let id = MemoryWriterID(rawValue: writer.id) else { return }
        let mains = run.scores.compactMap { s -> String? in
            guard let main = s.main else { return nil }
            let recipe = run.recipes.first { $0.id == s.recipeId }?.name ?? s.recipeId
            let model = run.models.first { $0.id == s.modelId }?.name ?? s.modelId
            return "\(recipe) × \(model) \(Int((main * 100).rounded()))%"
        }
        let errors = run.cells.filter { $0.error != nil }.count
        var note = "试写 · \(run.set.name) · \(run.cells.count) 格"
        if errors > 0 { note += " · \(errors) 格没结果" }
        if run.unpricedCells > 0 { note += " · \(run.unpricedCells) 格金额未知" }
        if run.status == .cancelled { note += " · 中途停下" }
        if run.status == .failed { note += " · 写盘失败" }
        if !mains.isEmpty { note += " · " + mains.joined(separator: "，") }
        MemoryWriteLog.record(writer: id, profileId: profileId, ok: true, note: note,
                              model: run.models.map(\.name).joined(separator: "、"), now: run.finishedAt ?? Date(),
                              trial: true, cost: run.totalUSD, memoryRoot: memoryRoot())
    }

}
