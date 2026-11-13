import MemoryCore
import Foundation

/// 写手调模型走 app 这条路：写入预算 / 全局预算闸 → `ProviderRouter` 非流式 → 花销记进 `MemoryWriteLog` + 账本。
/// 参数、调用时机、记账口径和 E-4 之前闭包版 `SessionSegmentWriter.modelCaller` 一字不差
struct AppModelCaller: ModelCaller, @unchecked Sendable {
    let model: ProviderModel
    let providerManager: ProviderManager
    let conversationId: String
    let profileId: String
    let kind: UsageKind
    let checkWriteBudget: Bool
    let preflight: ((String) async -> String?)?
    let onUsage: ((TokenUsage?, Double?) -> Void)?

    func complete(_ request: ModelRequest) async throws -> ModelReply {
        let blocked: String?
        if let preflight {
            blocked = await preflight(request.system + request.user)
        } else {
            blocked = SessionSegmentWriter.budgetBlock(model: model, providerManager: providerManager,
                                                       text: request.system + request.user, checkWriteBudget: checkWriteBudget)
        }
        if let why = blocked {
            CacheDiagLog.shared.log("📝 记忆写手: 跳过（\(why)）")
            return ModelReply()
        }
        let router = ProviderRouter(usageContext: UsageContext(kind: kind, conversationId: conversationId, profileId: profileId))
        let (response, usage) = try await router.sendNonStreaming(
            model: model, messages: [(role: "user", content: request.user)], systemPrompt: request.system, providerManager: providerManager)
        var spent: Double?
        if let usage, let provider = providerManager.provider(for: model) {
            let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
            spent = cost
            MemoryWriteLog.addCost(cost)
            await MainActor.run { providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage) }
        }
        onUsage?(usage, spent)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let reported = usage.map {
            ModelUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                       cacheReadTokens: $0.cacheReadTokens, cacheWriteTokens: $0.cacheWriteTokens, costUSD: spent)
        }
        guard !trimmed.isEmpty else {
            CacheDiagLog.shared.log("📝 记忆写手: ⚠️ 模型返回空内容")
            return ModelReply(usage: reported)
        }
        return ModelReply(text: trimmed, usage: reported)
    }
}

extension SessionSegmentWriter {
    /// app 这一半的写一段：软检查日志根照旧按 `memoryRoot ?? 楼层根` 懒求值
    static func write(_ req: Request, caller: Caller) async throws -> SessionSegment? {
        try await write(req, fallbackLogRoot: { req.memoryRoot ?? FileLibraryStore.memoryRoot(profileId: req.profileId) }, caller: caller)
    }

    /// 真的调模型：写入预算（后台写手才查；手动「现在写」不查，v5 Q10）→ 全局预算闸 → 副模型非流式 → 记花费；空输出 = nil。
    /// kind = 账本里算谁的（A2 .summary / A3 .windowSummary / A4 .timeline / C2 .memory，v5 · A11）
    /// preflight = 调用方自己的那一查（C3 在主线程读卡片和全局闸），给了就不走 budgetBlock
    /// onUsage = 这次调用用了多少 token、花了多少钱（试写台要显示；没报用量就是 nil, nil）
    static func modelCaller(model: ProviderModel, providerManager: ProviderManager, conversationId: String, profileId: String,
                            kind: UsageKind = .summary, checkWriteBudget: Bool = true,
                            preflight: ((String) async -> String?)? = nil,
                            onUsage: ((TokenUsage?, Double?) -> Void)? = nil) -> SessionSegmentWriter.Caller {
        let caller = AppModelCaller(model: model, providerManager: providerManager, conversationId: conversationId, profileId: profileId,
                                    kind: kind, checkWriteBudget: checkWriteBudget, preflight: preflight, onUsage: onUsage)
        return { system, user in try await caller.complete(ModelRequest(system: system, user: user)).text }
    }

    /// 后台写手发请求前那一查（modelCaller 和 C3 手动 agent 每一轮共用）：写入预算 → 全局预算闸（按这次要送的字估）。
    /// 拦下 = 原因；model = nil（本机）只查写入预算。读账本，后台调
    static func budgetBlock(model: ProviderModel?, providerManager: ProviderManager, text: String, checkWriteBudget: Bool = true) -> String? {
        if checkWriteBudget, WriteBudgetStore.exceeded() { return "写入预算用完" }
        guard let model, let provider = providerManager.provider(for: model) else { return nil }
        let est = BudgetCalculator.actualCost(
            provider: provider, modelId: model.modelId,
            usage: TokenUsage(inputTokens: HeuristicEstimator().estimate(text), outputTokens: 1500))
        if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: est),
           !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: est) {
            return "预算闸"
        }
        return nil
    }
}

extension WindowSummaryWriter {
    /// app 这一半的写一个窗口总结：软检查日志根照旧按 `memoryRoot ?? 楼层根` 懒求值
    static func write(title: String, segments: [SessionSegment], rawTail: [SessionSegmentWriter.Message],
                      persona: String, speakers: SessionSegmentWriter.Speakers,
                      start: Date, end: Date, to: Int, lastNodeId: String?,
                      profileId: String = "", memoryRoot: URL? = nil,
                      caller: SessionSegmentWriter.Caller) async throws -> SessionSegment? {
        try await write(title: title, segments: segments, rawTail: rawTail, persona: persona, speakers: speakers,
                        start: start, end: end, to: to, lastNodeId: lastNodeId, profileId: profileId, memoryRoot: memoryRoot,
                        fallbackLogRoot: { memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId) }, caller: caller)
    }
}
