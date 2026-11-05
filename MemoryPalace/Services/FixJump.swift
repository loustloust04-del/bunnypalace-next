import Foundation

/// 聊天报错胶囊的「去改」：按报错文字认是哪一类、该去哪改（plan-api-draft-and-fix-jump §3.2，Q5-A）。
/// 识别串都是我们自己写的中文，生成方（`ParamErrorClassifier` / `ProviderRouter.failureMessage` / 本地报错）
/// 和这里引用同一组常量，改文案时两边一起变。
enum FixJump {
    enum Kind: Equatable {
        case badKey, badURL, cardMissing, prefill, reasoning, samplingValue, quota, contextTooLong, learned, budget, unavailableModel

        var buttonTitle: String { self == .learned || self == .quota ? "去看" : "去改" }
    }

    // MARK: 识别常量（生成方共用）

    static let badKeyPhrase = "key 不对或没有权限"
    static let badURLPhrase = "地址不对，检查 Base URL"
    static let missingProviderPrefix = "找不到提供商"
    static let unsupportedCardPhrase = "卡的类型当前版本不支持"
    static let noKeyPrefix = "未设置 "
    static let noKeySuffix = " 的 API Key"
    static let prefillPhrase = "不收预填"
    static let reasoningPhrase = "不收推理强度"
    static let samplingPrefix = "不收参数 "
    static let samplingSuffix = "现在的值"
    static let learnedPrefix = "已记住："
    static let budgetPhrase = "保险闸"
    static let quotaPhrase = "这张卡的额度用完了或余额不足，充值或换一张卡"
    static let contextTooLongPhrase = "对话太长了，超过这个模型一次能读的长度"
    static let unavailableModelPhrase = "渠道，换个模型或去中转后台看分组"
    static let groupDeniedPhrase = "这把 key 的分组不能用这个模型"
    static let prepaidQuotaNote = "（有的中转按最大输出预扣额度）"
    static let thinkingBudgetPhrase = "思考预算比输出上限还大"

    static func missingProviderMessage(_ credentialId: String) -> String { "\(missingProviderPrefix): \(credentialId)" }
    static func unsupportedCardMessage(_ raw: String?) -> String {
        "这张 API \(unsupportedCardPhrase)（\(raw ?? "未知")），请更新 app 或换一张卡"
    }
    static func noKeyMessage(_ cardName: String) -> String { noKeyPrefix + cardName + noKeySuffix }
    static let budgetPreflightMessage = budgetPhrase + "：本次预计花费超过剩余额度"
    /// R4：只在这次一个思考参数都没发时才提「可能是中转开的」，不下定论；已经压过一档还不行也走这句
    static func thinkingBudgetMessage(sentThinking: Bool) -> String {
        thinkingBudgetPhrase + (sentThinking
            ? "，把预设里的 Max Tokens 调大一点或把思考调低一档再发"
            : "（这次没发思考参数，可能是中转给这个模型开了思考），把预设里的 Max Tokens 调大一点再发")
    }
    /// R3：报错里的参数名被打码、认不准是哪个：不自动改、不学
    static func maskedParamMessage(_ token: String) -> String {
        "报错里的参数名被中转打了码（\(token)），认不准是哪个参数，没有自动改。可以去中转后台看完整报错"
    }
    static func unavailableModelMessage(_ modelId: String) -> String {
        "这个中转的当前分组里没有可用的「\(modelId)」" + unavailableModelPhrase
    }

    /// 失败尾巴「（host · 模型 · HTTP 状态码）」
    static func statusTail(host: String, modelId: String, status: Int) -> String {
        "（\(host) · \(modelId) · HTTP \(status)）"
    }

    // MARK: 识别

    /// 只对 `ChatSystemMessage.split(...).error`（⚠️ 标记拆出来的报错）跑；从上往下第一个命中的算
    static func kind(for errorText: String) -> Kind? {
        let t = errorText
        // 分组无权（R5）不是 key 填错，不出按钮；预扣型余额不足（R2）403 也按额度
        if t.contains(groupDeniedPhrase) { return nil }
        if t.contains(unavailableModelPhrase) { return .unavailableModel }
        if t.contains(quotaPhrase) && !t.contains(badKeyPhrase) { return .quota }
        if t.contains("HTTP 401）") || t.contains("HTTP 403）") || t.contains(badKeyPhrase) { return .badKey }
        if t.contains(noKeyPrefix), t.contains(noKeySuffix) { return .badKey }
        if t.contains("HTTP 404）") || t.contains(badURLPhrase) { return .badURL }
        if t.contains(missingProviderPrefix) || t.contains(unsupportedCardPhrase) { return .cardMissing }
        if t.contains(prefillPhrase) { return .prefill }
        if t.contains(reasoningPhrase) { return .reasoning }
        if t.contains(samplingPrefix), t.contains(samplingSuffix) { return .samplingValue }
        if t.contains(contextTooLongPhrase) { return .contextTooLong }
        if t.contains(learnedPrefix) { return .learned }
        if t.contains(budgetPhrase) { return .budget }
        return nil
    }

    /// 「未设置 X 的 API Key」里的 X
    static func cardName(inNoKeyError text: String) -> String? {
        guard let start = text.range(of: noKeyPrefix), let end = text.range(of: noKeySuffix, range: start.upperBound..<text.endIndex) else { return nil }
        let name = String(text[start.upperBound..<end.lowerBound])
        return name.isEmpty ? nil : name
    }

    /// 尾巴「（host · 模型 · HTTP n）」里的 host
    static func host(inTail text: String) -> String? {
        guard let match = text.range(of: #"（[^（）·]+ · [^（）]* · HTTP \d+）"#, options: .regularExpression) else { return nil }
        let inner = text[match].dropFirst()
        guard let dot = inner.range(of: " · ") else { return nil }
        let host = String(inner[..<dot.lowerBound])
        return host.isEmpty ? nil : host
    }

    // MARK: 点按钮

    /// 「那张卡」在点按钮时才找（astra #8：宁可打开卡列表也不开错卡）：
    /// ① 账本里这条节点最后一行记的卡——卡还在就是它，已经删了就 nil（不再往下猜）
    /// ② 没进账本（本地报错）：「未设置 X 的 API Key」按卡名，**只有唯一一张同名**才认
    /// ③ 尾巴 host 对卡地址，**只有唯一一张**才认；都不成 = nil（只开到卡列表）
    static func credentialId(ledgerProviderId: String?, errorText: String, credentials: [APICredential]) -> String? {
        if let id = ledgerProviderId {
            return credentials.contains(where: { $0.id == id }) ? id : nil
        }
        if let name = cardName(inNoKeyError: errorText) {
            let hits = credentials.filter { $0.name == name }
            return hits.count == 1 ? hits[0].id : nil
        }
        if let host = host(inTail: errorText) {
            let hits = credentials.filter { URL(string: $0.baseURL)?.host == host || $0.baseURL == host }
            return hits.count == 1 ? hits[0].id : nil
        }
        return nil
    }

    /// 账本里这条节点最后一行的卡 id（没有 = nil）。整本账要读要解码，放后台（astra #11）
    static func ledgerProviderId(nodeId: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            UsageLedger.shared.load().last(where: { $0.messageNodeId == nodeId })?.providerId
        }.value
    }

    /// 胶囊 / 报错详情里的「去改」
    @MainActor
    static func perform(_ kind: Kind, nodeId: String, errorText: String, providerManager: ProviderManager?,
                        viewModel: ConversationViewModel?, delay: TimeInterval = 0) {
        let jump = SettingsJump.shared
        /// 要找卡的几类：后台读完账本再回主线程投信
        func withCard(_ make: @escaping @MainActor (String?) -> SettingsJumpTarget) {
            Task { @MainActor in
                let ledgerId = await ledgerProviderId(nodeId: nodeId)
                let id = credentialId(ledgerProviderId: ledgerId, errorText: errorText, credentials: providerManager?.credentials ?? [])
                jump.request(make(id), delay: delay)
            }
        }
        switch kind {
        case .badKey, .badURL, .quota:
            withCard { id in id.map(SettingsJumpTarget.editCredential) ?? .apiPage }
        case .cardMissing:
            jump.request(.apiPage, delay: delay)
        case .prefill:
            jump.request(.persona(anchor: SettingsJump.prefillAnchor), delay: delay)
        case .samplingValue:
            jump.request(.persona(anchor: SettingsJump.samplingAnchor), delay: delay)
        case .contextTooLong:
            jump.request(.persona(anchor: SettingsJump.contextDepthAnchor), delay: delay)
        case .reasoning:
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                viewModel?.modelPickerRequested = true
            }
        case .learned, .unavailableModel:
            withCard { id in .modelPool(credentialId: id) }
        case .budget:
            jump.request(.budget, delay: delay)
        }
    }
}
