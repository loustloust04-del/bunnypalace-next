import Foundation

enum BudgetPreflight {
    static func shouldRefine(enabled: Bool, budget: Double, spent: Double, estimated: Double) -> Bool {
        let remaining = budget - spent
        guard enabled, remaining > 0 else { return false }
        return estimated >= remaining * 0.75 && estimated <= remaining * 1.25
    }

    static func mayDeferEarlyGate(provider: APICredential, estimated: Double) -> Bool {
        guard OfficialTokenCounter.supports(URL(string: provider.baseURL)) else { return false }
        let store = GlobalBudgetStore.shared
        return shouldRefine(enabled: store.enabled,
                            budget: store.isBudgetSet ? store.budgetUSD : GlobalBudgetStore.defaultBudgetUSD,
                            spent: store.spentUSD, estimated: estimated)
    }

    struct State {
        let enabled: Bool
        let isBudgetSet: Bool
        let budgetUSD: Double
        let spentUSD: Double
        var effectiveBudget: Double { isBudgetSet ? budgetUSD : GlobalBudgetStore.defaultBudgetUSD }
        static var current: State {
            let store = GlobalBudgetStore.shared
            return State(enabled: store.enabled, isBudgetSet: store.isBudgetSet, budgetUSD: store.budgetUSD, spentUSD: store.spentUSD)
        }
    }

    struct Decision {
        let allowed: Bool
        let estimatedCost: Double
    }

    /// 不支持官方计数的端点没有等待步骤，按当前余额同步完成最终 gate。
    static func immediateDecision(_ request: URLRequest, state: () -> State = { State.current }) -> Decision? {
        guard !OfficialTokenCounter.supports(request.url) else { return nil }
        guard let usage = estimate(request) else { return Decision(allowed: true, estimatedCost: 0) }
        let rate = PricingCatalog.price(for: usage.model) ?? PricingCatalog.budgetFallback
        let estimated = rate.cost(promptTokens: usage.input, completionTokens: usage.output, cacheReadTokens: 0, cacheWriteTokens: 0)
        return finalDecision(estimatedCost: estimated, current: state())
    }

    private static func finalDecision(estimatedCost: Double, current: State) -> Decision {
        let gate = BudgetCalculator.gate(enabled: current.enabled, isBudgetSet: current.isBudgetSet,
                                         budgetUSD: current.budgetUSD, spentUSD: current.spentUSD, estimatedCost: estimatedCost)
        if case .blocked = gate { return Decision(allowed: false, estimatedCost: estimatedCost) }
        return Decision(allowed: true, estimatedCost: estimatedCost)
    }

    static func estimate(_ request: URLRequest) -> (model: String, input: Int, output: Int)? {
        guard let raw = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let model = body["model"] as? String, body["messages"] != nil else { return nil }
        func text(_ value: Any) -> String {
            if let s = value as? String { return s }
            if let array = value as? [Any] { return array.map(text).joined(separator: "\n") }
            if let dict = value as? [String: Any] {
                if dict["content"] != nil || dict["text"] != nil || dict["tool_calls"] != nil {
                    return [text(dict["content"] ?? ""), text(dict["text"] ?? ""), text(dict["tool_calls"] ?? [])]
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                }
                return dict.filter { !["data", "url", "image_url", "source", "role", "type", "cache_control"].contains($0.key) }
                    .sorted { $0.key < $1.key }.map { text($0.value) }.joined(separator: "\n")
            }
            return ""
        }
        var inputText = text(body["system"] ?? "") + text(body["messages"] ?? [])
        if let tools = body["tools"], let data = try? JSONSerialization.data(withJSONObject: tools, options: .sortedKeys) {
            inputText += String(decoding: data, as: UTF8.self)
        }
        let output = min(body["max_completion_tokens"] as? Int ?? body["max_tokens"] as? Int ?? OutputTokenCap.budgetExpected,
                         OutputTokenCap.budgetExpected)
        return (model, HeuristicEstimator().estimate(inputText), output)
    }

    @MainActor static func decision(_ request: URLRequest, counter: OfficialTokenCounter = OfficialTokenCounter(),
                                    state: () -> State = { State.current }) async -> Decision {
        guard let usage = estimate(request) else { return Decision(allowed: true, estimatedCost: 0) }
        let initial = state()
        let rate = PricingCatalog.price(for: usage.model) ?? PricingCatalog.budgetFallback
        var estimated = rate.cost(promptTokens: usage.input, completionTokens: usage.output, cacheReadTokens: 0, cacheWriteTokens: 0)
        if OfficialTokenCounter.supports(request.url),
           shouldRefine(enabled: initial.enabled, budget: initial.effectiveBudget, spent: initial.spentUSD, estimated: estimated),
           let exact = await counter.count(request) {
            estimated = rate.cost(promptTokens: exact, completionTokens: usage.output, cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        // 失败仍按启发式判断；计数接口错误本身不阻断发送。
        return finalDecision(estimatedCost: estimated, current: state())
    }

    @MainActor static func check(_ request: URLRequest, counter: OfficialTokenCounter = OfficialTokenCounter()) async -> Bool {
        await decision(request, counter: counter).allowed
    }
}
