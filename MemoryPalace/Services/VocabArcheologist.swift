import Foundation

/// 考古走哪条路（#054）。开源版只有 `.app`；私用版默认 `.mac`（她 Mac 上 hub 跑 claude -p，和以前一样），设置里可切。
enum VocabArcheologyRoute: String {
    case mac, app

    static let storageKey = "vocabArcheologyRoute"

    static var current: VocabArcheologyRoute {
        .app
    }
}

/// 考古 · App 路（#054）：用 App 里配好的模型一次性写一篇，落 live 覆盖层，发 `.vocabCorpusArrived`。
/// 提示词 = 夜跑脚本同一份「语言考古学家」（Resources/vocab-prompt）。
/// 流式而不是 sendNonStreaming：后者 Anthropic 写死 max_tokens 1024、整篇生成完才回首字节会撞 60s 空闲超时，一篇 ~10KB 撑不住。
enum VocabArcheologist {

    static let promptFileName = "语言考古学家_批量版"
    static let maxOutputTokens = 12_000
    static let expectedOutputTokens = 6_000
    /// 同 vocab-daily.ts：>500 字节才算有实质内容
    static let minBytes = 500

    static func systemPrompt(bundle: Bundle = .main) -> String? {
        let url = bundle.url(forResource: promptFileName, withExtension: "md", subdirectory: "vocab-prompt")
            ?? bundle.url(forResource: promptFileName, withExtension: "md")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    /// 裸词会被当对话语汇（acknowledge=确认），包成任务句消歧义——同 vocab-daily.ts
    static func userMessage(word: String) -> String {
        "本轮要考古的单词：\(word)"
    }

    static func accept(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.utf8.count > minBytes ? t : nil
    }

    /// 聊天模型优先（和普通对话同一个提供商）；CC / 本机 / 不认识的卡走不了一次性长文，退副模型（记忆提取用的那个）。
    static func resolveModel(providerManager: ProviderManager, defaults: UserDefaults = .standard) -> ProviderModel? {
        for key in ["selectedChatModel", "memoryExtractModelId"] {
            let id = defaults.string(forKey: key) ?? ""
            guard !id.isEmpty, let m = providerManager.model(byId: id),
                  let type = providerManager.provider(for: m)?.type else { continue }
            switch type {
            case .openaiCompatible, .anthropic, .chatgptOAuth: return m
            case .ccBridge, .localMLX, .unsupported: continue
            }
        }
        return nil
    }

    /// 进行中的请求（router 要活到回调结束）
    @MainActor private static var routers: [String: ProviderRouter] = [:]

    /// fire-and-forget；结果一律经 `.vocabCorpusArrived`（word / ok / reason）回投，sheet 关了也照样落盘。
    @MainActor
    static func run(word: String, providerManager: ProviderManager) {
        guard routers[word] == nil else { return }
        guard let system = systemPrompt() else {
            finish(word: word, ok: false, reason: "考古提示词缺失")
            return
        }
        guard let model = resolveModel(providerManager: providerManager) else {
            finish(word: word, ok: false, reason: "考古要先配一个云端模型")
            return
        }
        let messages = [(role: "user", content: userMessage(word: word))]
        let provider = providerManager.provider(for: model)

        var estimated = 0.0
        if let provider {
            let inputTok = HeuristicEstimator().estimate(system + messages[0].content)
            estimated = BudgetCalculator.actualCost(
                provider: provider, modelId: model.modelId,
                usage: TokenUsage(inputTokens: inputTok, outputTokens: expectedOutputTokens)
            )
            if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated),
               !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: estimated) {
                finish(word: word, ok: false, reason: "本月预算到顶了")
                return
            }
        }

        var params = SamplingParams()
        params.maxTokens = maxOutputTokens
        params.maxTokensAuto = false

        let router = ProviderRouter(usageContext: UsageContext(kind: .vocabArcheology))
        routers[word] = router
        router.sendStreaming(
            model: model, messages: messages, systemPrompt: system,
            providerManager: providerManager, samplingParams: params,
            onToken: { _ in },
            onComplete: { [weak router] text, usage in
                // router 在调 onComplete 之前同步写好截断标志
                let truncated = router?.lastReplyHitOutputLimit ?? false
                Task { @MainActor in
                    if let provider {
                        // 有的端点流式不回 usage → 按发送前估算扣（ConversationViewModel.commitBudgetSpend 同款兜底）
                        let cost = usage.map { BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: $0) } ?? estimated
                        if cost > 0 { providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage) }
                    }
                    if truncated {
                        finish(word: word, ok: false, reason: "写到一半撞了模型输出上限，换个模型再试")
                    } else if let md = accept(text) {
                        if VocabCorpusStore.saveLive(word: word, markdown: md) {
                            finish(word: word, ok: true, reason: nil)
                        } else {
                            finish(word: word, ok: false, reason: "写好了但存不下来，检查一下磁盘空间")
                        }
                    } else {
                        finish(word: word, ok: false, reason: "模型没写出完整的一篇，稍后再试")
                    }
                }
            },
            onError: { message in
                Task { @MainActor in finish(word: word, ok: false, reason: "考古失败：\(message)") }
            }
        )
    }

    @MainActor
    private static func finish(word: String, ok: Bool, reason: String?) {
        routers[word] = nil
        // sheet 关着时没人收通知，全局「考古中」在这里清，免得重开后按钮永远禁用
        VocabArcheologyTracker.inFlight.remove(word)
        var info: [String: Any] = ["word": word, "ok": ok]
        if let reason { info["reason"] = reason }
        NotificationCenter.default.post(name: .vocabCorpusArrived, object: nil, userInfo: info)
    }
}
