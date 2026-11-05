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

    /// thinking 回传 astra #3：当轮回传的思考块按输入计费，签名是密文不能按字估。
    /// 知道那一次回复的 thinking_tokens 就直接加；不知道的记签名字数（能官方计数就强制计，不能就按 4 字 1 token 保守估）
    struct EchoedThinking: Equatable {
        var knownTokens = 0
        var unknownSignatureChars = 0
        var hasUnknown: Bool { unknownSignatureChars > 0 }
        var conservativeTokens: Int { knownTokens + unknownSignatureChars / 4 }

        init(knownTokens: Int = 0, unknownSignatureChars: Int = 0) {
            self.knownTokens = knownTokens
            self.unknownSignatureChars = unknownSignatureChars
        }

        init(_ turns: [ToolTurn]) {
            for turn in turns where turn.thinkingBlockCount > 0 {
                if let tokens = turn.thinkingTokens {
                    knownTokens += tokens
                } else {
                    unknownSignatureChars += (turn.assistantContent ?? []).filter(ReplyBlock.isThinking).reduce(0) { n, block in
                        n + max(1, (block["signature"] as? String ?? block["data"] as? String ?? "").count)
                    }
                }
            }
        }
    }

    /// 不支持官方计数的端点没有等待步骤，按当前余额同步完成最终 gate。
    static func immediateDecision(_ request: URLRequest, echoed: EchoedThinking = EchoedThinking(),
                                  state: () -> State = { State.current }) -> Decision? {
        guard !OfficialTokenCounter.supports(request.url) else { return nil }
        guard let usage = estimate(request) else { return Decision(allowed: true, estimatedCost: 0) }
        let rate = PricingCatalog.price(for: usage.model) ?? PricingCatalog.budgetFallback
        let estimated = rate.cost(promptTokens: usage.input + echoed.conservativeTokens, completionTokens: usage.output,
                                  cacheReadTokens: 0, cacheWriteTokens: 0)
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
                // signature（思考块签名）是密文，不当正文估字数（thinking 回传 Q9-A）
                return dict.filter { !["data", "url", "image_url", "source", "role", "type", "cache_control", "signature"].contains($0.key) }
                    .sorted { $0.key < $1.key }.map { text($0.value) }.joined(separator: "\n")
            }
            return ""
        }
        var inputText = text(body["system"] ?? "") + text(body["messages"] ?? [])
        if let tools = body["tools"], let data = try? JSONSerialization.data(withJSONObject: tools, options: .sortedKeys) {
            inputText += String(decoding: data, as: UTF8.self)
        }
        let output = min(body["max_completion_tokens"] as? Int ?? body["max_tokens"] as? Int ?? OutputTokenCap.budgetExpected,
                         OutputTokenCap.budgetExpected + thinkingHeadroom(body, model: model))
        return (model, HeuristicEstimator().estimate(inputText), output)
    }

    /// 开思考时期望输出加这一档余量（Q9-A）：output_config.effort / budget_tokens / adaptive 没写档 = 官方默认档
    static func thinkingHeadroom(_ body: [String: Any], model: String) -> Int {
        guard let thinking = body["thinking"] as? [String: Any] else { return 0 }
        if let budget = thinking["budget_tokens"] as? Int { return budget }
        if let effort = (body["output_config"] as? [String: Any])?["effort"] as? String {
            return ReasoningEffort.headroom(effort) ?? 0
        }
        return ReasoningEffort.headroom(ModelLineage.defaultEffort(model)) ?? 0
    }

    @MainActor static func decision(_ request: URLRequest, counter: OfficialTokenCounter = OfficialTokenCounter(),
                                    echoed: EchoedThinking = EchoedThinking(),
                                    state: () -> State = { State.current }) async -> Decision {
        guard let usage = estimate(request) else { return Decision(allowed: true, estimatedCost: 0) }
        let initial = state()
        let rate = PricingCatalog.price(for: usage.model) ?? PricingCatalog.budgetFallback
        var estimated = rate.cost(promptTokens: usage.input + echoed.conservativeTokens, completionTokens: usage.output,
                                  cacheReadTokens: 0, cacheWriteTokens: 0)
        // 回传了不知道 token 数的思考块：不看离额度近不近，一律走官方计数（count_tokens 认思考块）
        if OfficialTokenCounter.supports(request.url),
           (initial.enabled && echoed.hasUnknown) || shouldRefine(enabled: initial.enabled, budget: initial.effectiveBudget, spent: initial.spentUSD, estimated: estimated),
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
