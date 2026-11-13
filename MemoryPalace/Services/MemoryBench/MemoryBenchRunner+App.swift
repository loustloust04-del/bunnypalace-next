import MemoryCore
import Foundation

/// 试写台在 app 这一半：真调模型（凭据 / 脱敏 / 记账口径）、启动维护、本机执行器注入、写手注册表。
/// 纯逻辑（展开 / 跑 / 打分 / 落盘）在包里的 `MemoryBenchRunner`
extension MemoryBenchRunner {
    /// app 这一半的跑一次：本机执行器 / 楼层记忆根都按 app 的规则注入
    static func run(writer: any MemoryBenchWriter, set: MemoryBenchSet, caseIds: [String]? = nil,
                    recipes: [MemoryBenchRecipe], models: [MemoryBenchModelRef],
                    store: MemoryBenchStore, profileId: String, caller: @escaping MemoryBenchCaller,
                    runId: String = UUID().uuidString, now: @escaping @Sendable () -> Date = { Date() },
                    onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> MemoryBenchRun {
        try await run(writer: writer, set: set, caseIds: caseIds, recipes: recipes, models: models,
                      store: store, profileId: profileId,
                      memoryRoot: { FileLibraryStore.memoryRoot(profileId: profileId) },
                      local: { try await MemoryBenchLocalExecutor.execute(testCase: $0, recipe: $1) },
                      caller: caller, runId: runId, now: now, onProgress: onProgress)
    }

    // MARK: - 启动时

    /// 每层楼：遗留的 running 标成中断（这个进程正在跑的不动）、清 30 天前的完整日志和原始输出。后台调
    static func maintain(profileIds: [String], now: Date = Date()) {
        let active = activeRunIds
        for id in profileIds {
            let store = MemoryBenchStore.forMemoryRoot(FileLibraryStore.memoryRoot(profileId: id))
            guard FileManager.default.fileExists(atPath: store.root.path) else { continue }
            let marked = store.markInterrupted(active: active, scorers: { MemoryBenchWriters.writer($0)?.scorers ?? [MemoryBenchBasicScorer()] }, now: now)
            if marked > 0 { CacheDiagLog.shared.log("🧪 试写台: \(marked) 次跑到一半被打断，已标成中断（做完的格子留着）") }
            store.pruneLogs(now: now)
        }
    }
}

// MARK: - 真跑

/// 一次调用里 onUsage 回来的 token / 钱（回调在调用方的任务上，读在 await 之后）
private final class MemoryBenchUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var usage: TokenUsage?
    private var usd: Double?

    func set(_ u: TokenUsage?, _ c: Double?) {
        lock.lock(); usage = u; usd = c; lock.unlock()
    }

    func get() -> (TokenUsage?, Double?) {
        lock.lock(); defer { lock.unlock() }
        return (usage, usd)
    }
}

/// 交给试写台的错误：原文已脱敏
struct MemoryBenchCallError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension MemoryBenchRunner {
    /// 真调模型：记在「试写」名下、不看写入预算（规格 §5-3，同「现在写」），全局预算闸照查。本机模型不收。
    /// 这一层手里有凭据：抛出去的错误一律先脱敏（key 原文 / JSON 转义形式、带鉴权意味的请求头值、URL 里的 query 和 userinfo）——
    /// HTTP 200 但回包解析失败时，错误里带着回包开头 200 字，可能回显 key（astra zd2 #2）
    static func liveCaller(providerManager: ProviderManager, profileId: String) -> MemoryBenchCaller {
        { ref, prompt in
            guard !ref.local else { throw MemoryBenchRunError.localModel(ref.name) }
            let model = ProviderModel(credentialId: ref.credentialId, modelId: ref.modelId, name: ref.name)
            let secrets = secrets(for: ref.credentialId, providerManager: providerManager)
            let box = MemoryBenchUsageBox()
            let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: providerManager, conversationId: "",
                                                          profileId: profileId, kind: .memoryTrial, checkWriteBudget: false,
                                                          onUsage: { box.set($0, $1) })
            let text: String?
            do {
                text = try await caller(prompt.system, prompt.user)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MemoryBenchCallError(message: ParamErrorClassifier.redacted(error.localizedDescription, secrets: secrets))
            }
            let (usage, spent) = box.get()
            let (tokens, usd, source) = accounting(usage, spent: spent)
            return MemoryBenchCallResult(text: text, usage: tokens, usd: usd, costSource: source)
        }
    }

    /// 这张卡的 key + 名字带鉴权意味的额外请求头的值
    static func secrets(for credentialId: String, providerManager: ProviderManager) -> [String] {
        var out = [providerManager.apiKey(for: credentialId) ?? ""]
        if let card = providerManager.credentials.first(where: { $0.id == credentialId }) {
            for (name, value) in card.extraHeaders {
                let n = name.lowercased()
                if ["auth", "key", "token", "secret", "cookie", "session"].contains(where: { n.contains($0) }) { out.append(value) }
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// 用量 / 钱的三种来源（astra zd2 #9）：回包没报用量 → token 未知（nil，不是 0）；账本按估算记的 → 估算；
    /// 价目表里没这个模型 → 金额未知（nil，不是 $0）
    static func accounting(_ usage: TokenUsage?, spent: Double?) -> (MemoryBenchUsage?, Double?, MemoryBenchCostSource?) {
        guard let usage, usage.completeness != .missing else { return (nil, nil, nil) }
        let tokens = MemoryBenchUsage(input: usage.inputTokens, output: usage.outputTokens,
                                      source: usage.completeness == .complete ? MemoryBenchUsage.measured : MemoryBenchUsage.estimated)
        if let record = usage.ledgerRecord {
            guard let cost = record.costUSD else { return (tokens, nil, .unpriced) }
            let estimated = record.costSource == .estimated || record.costSource == .partial || usage.completeness != .complete
            return (tokens, cost, estimated ? .estimated : .measured)
        }
        if usage.ledgerCostRecorded {
            guard let cost = usage.ledgerCostUSD else { return (tokens, nil, .unpriced) }
            return (tokens, cost, usage.completeness == .complete ? .measured : .estimated)
        }
        guard let spent else { return (tokens, nil, .unpriced) }
        return (tokens, spent, usage.completeness == .complete ? .measured : .estimated)
    }

    /// 估算一格的钱（同 `SessionSegmentWriter.budgetBlock` 的口径）；不知道价 nil
    static func liveCost(providerManager: ProviderManager) -> (MemoryBenchModelRef, MemoryBenchPrompt) -> Double? {
        { ref, prompt in
            guard !ref.local else { return nil }
            let model = ProviderModel(credentialId: ref.credentialId, modelId: ref.modelId, name: ref.name)
            guard let provider = providerManager.provider(for: model) else { return nil }
            return BudgetCalculator.actualCost(provider: provider, modelId: ref.modelId,
                                               usage: TokenUsage(inputTokens: HeuristicEstimator().estimate(prompt.system + prompt.user),
                                                                 outputTokens: estimatedOutputTokens))
        }
    }
}

extension MemoryBenchModelRef {
    init(_ model: ProviderModel) {
        self.init(credentialId: model.credentialId, modelId: model.modelId, name: model.name)
    }
}

extension MemoryBenchStore {
    /// 启动时：遗留的 running（不在 `active` 里 = 不是这个进程正在跑的）改成 interrupted，已完成的格子留着、按它们重新打分。返回改了几份
    @discardableResult
    func markInterrupted(active: Set<String>, scorers: (String) -> [any MemoryBenchScorer], now: Date = Date()) -> Int {
        var changed = 0
        for var run in runs() where run.status == .running && !active.contains(run.id) {
            run.status = .interrupted
            run.finishedAt = MemoryBench.stamp(now)
            run.scores = run.scored(with: scorers(run.writer))
            guard (try? saveRun(run)) != nil else { continue }
            changed += 1
        }
        return changed
    }
}

// MARK: - 注册表

/// 试写台认识的写手（包里已有协议 / 翻记忆，C2 留在 app）
enum MemoryBenchWriters {
    /// `ToolSchemaRenderer` / `RecallTool` 的提示词面只在 app，摘要闭包从这里注入包里
    static func recallContract() -> String? {
        guard let schema = try? JSONSerialization.data(withJSONObject: ToolSchemaRenderer.openAI(RecallTool.definition),
                                                       options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return MemoryBench.digest(Data(RecallTool.toolDescription.utf8) + schema)
    }

    static func recallReader(profileId: String? = nil) -> MemoryBenchRecallReader {
        MemoryBenchRecallReader(profileId: profileId, contract: recallContract, floorURL: floorURL)
    }

    /// 内置快照随 app 资源走（`Resources/MemoryBench/`）；资源缺失时给不存在的路径，
    /// 让 `Reader.floor(for:)` 返回 nil（与旧 loader 找不到文件等价），不崩。
    static var floorURL: URL {
        Bundle.main.url(forResource: "memory-bench-recall-floor-xingyan", withExtension: "json", subdirectory: "MemoryBench")
            ?? Bundle.main.url(forResource: "memory-bench-recall-floor-xingyan", withExtension: "json")
            ?? URL(fileURLWithPath: "/nonexistent/memory-bench-recall-floor-xingyan.json")
    }

    static let all: [any MemoryBenchWriter] = [MemoryBenchC2Writer(), recallReader()]

    static func writer(_ id: String) -> (any MemoryBenchWriter)? {
        all.first { $0.id == id }
    }
}
