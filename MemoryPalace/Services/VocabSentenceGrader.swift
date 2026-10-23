import Foundation

/// 造句题的 AI 静默判分（不进主对话）。ProviderRouter.sendNonStreaming side-call，
/// AUDN 提取 / 做梦同款链路。任何失败返回 nil → UI 降级自评（App 自包含，AI 是增强）。
enum VocabSentenceGrader {

    static let systemPrompt = """
    你是英语用词判分器。用户在练习用目标单词造句，判断句子是否正确、自然地使用了目标词。
    判分标准：词性用对、语义搭配合理、句子本身通顺。轻微拼写或标点瑕疵不扣。
    只输出 JSON，不要解释：
    {"ok": true/false, "feedback": "一句话中文点评；错了指出错在哪并给一个正确示例"}
    """

    static func buildRequest(word: String, definition: String?, sentence: String)
        -> (systemPrompt: String, messages: [(role: String, content: String)]) {
        var user = "目标词：\(word)"
        if let def = definition, !def.isEmpty {
            user += "（\(def)）"
        }
        user += "\n用户造的句子：\(sentence)"
        return (systemPrompt: systemPrompt, messages: [(role: "user", content: user)])
    }

    /// 严格 JSON → 兜底从文本抽 JSON 块。ok 字段缺失 = 解析失败。
    static func parse(_ response: String) -> (ok: Bool, feedback: String)? {
        if let r = parseJSON(response) { return r }
        if let range = response.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
           let r = parseJSON(String(response[range])) {
            return r
        }
        return nil
    }

    private static func parseJSON(_ json: String) -> (ok: Bool, feedback: String)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = obj["ok"] as? Bool else { return nil }
        return (ok, obj["feedback"] as? String ?? "")
    }

    /// 判分调用。无模型 / 预算闸 / 网络失败 / 解析失败 → nil。
    @MainActor
    static func grade(word: String, definition: String?, sentence: String,
                      providerManager: ProviderManager) async -> (ok: Bool, feedback: String)? {
        guard let model = DreamConsolidator.resolveModel(providerManager: providerManager) else {
            return nil
        }

        let request = buildRequest(word: word, definition: definition, sentence: sentence)

        // 预算闸（做梦同款）
        if let provider = providerManager.provider(for: model) {
            let inputTok = HeuristicEstimator().estimate(request.systemPrompt + request.messages[0].content)
            let estimated = BudgetCalculator.actualCost(
                provider: provider, modelId: model.modelId,
                usage: TokenUsage(inputTokens: inputTok, outputTokens: 256)
            )
            if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated),
               !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: estimated) {
                return nil
            }
        }

        let router = ProviderRouter(usageContext: UsageContext(kind: .vocab))
        guard let (response, usage) = try? await router.sendNonStreaming(
            model: model, messages: request.messages,
            systemPrompt: request.systemPrompt, providerManager: providerManager
        ) else { return nil }

        if let usage, let provider = providerManager.provider(for: model) {
            let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
            providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage)
        }

        return parse(response)
    }
}
