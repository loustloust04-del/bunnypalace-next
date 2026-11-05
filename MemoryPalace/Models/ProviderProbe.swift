import Foundation

/// #092 B/C：测试连接、拉模型只拿内存里的草稿卡 + key 发请求，不读不写卡表和钥匙串。
/// 编辑器 / 引导测试未保存的草稿走这里；ProviderManager 按 id 的老入口也只是「取卡 + key → 调这里」。
/// 只有 2xx 算成功；失败带状态码、上游原因、实际请求的地址。
enum ProviderProbe {
    struct Failure: LocalizedError {
        let status: Int?
        let message: String
        let url: String?
        var errorDescription: String? {
            guard let url else { return message }
            return message + "\n请求地址：" + url
        }
    }

    struct TestSuccess {
        let summary: String
        let model: String
        /// 卡上没模型时先拉了一次 /models：拉到的清单交回页面填进草稿
        let fetchedModels: [ProviderModel]
    }

    // MARK: 拉模型

    struct Discovered {
        let models: [ProviderModel]
        /// 拉到的上下文 / 输入模态（plan-provider-presets Q5）；nil = 没问 /models（种子清单）
        let hints: [String: ModelHint]?
    }

    /// 给了 `hints` 才按 draft.id 写旁表（已存的卡）；草稿卡的 id 是临时的，元数据由页面拿着、保存成功才按真实卡 id 落（CredentialCommitter.commit）
    static func fetchModels(draft: APICredential, key: String, session: URLSession = .shared,
                            hints: ModelHints? = nil,
                            presetLookup: (String?) -> APIProvider? = { APIProvider.preset(id: $0) }) async -> Result<[ProviderModel], Error> {
        let r = await discoverModels(draft: draft, key: key, session: session, presetLookup: presetLookup)
        if case .success(let found) = r, let hints, let h = found.hints { hints.replace(credentialId: draft.id, with: h) }
        return r.map(\.models)
    }

    /// 区域 `listsModels == false` 直接回种子、不发请求；Anthropic 格式的卡优先打区域的 OpenAI base（很多 Anthropic 兼容端点没有 /models）。
    static func discoverModels(draft: APICredential, key: String, session: URLSession = .shared,
                               presetLookup: (String?) -> APIProvider? = { APIProvider.preset(id: $0) }) async -> Result<Discovered, Error> {
        guard draft.type == .openaiCompatible || draft.type == .anthropic else {
            return .failure(Failure(status: nil, message: "这类卡不用拉模型列表", url: nil))
        }
        let preset = presetLookup(draft.presetId)
        let region = preset.flatMap { discoveryRegion(of: $0, for: draft) }
        if let preset, let region, !region.listsModels {
            return .success(Discovered(models: preset.seedModels(in: region, credentialId: draft.id), hints: nil))
        }
        let listType: ProviderType = draft.type == .anthropic && region?.offers(.openaiCompatible) == true ? .openaiCompatible : draft.type
        let base = listType == draft.type ? draft.baseURL : region?.endpoints[listType] ?? draft.baseURL
        let urlString = BaseURLNormalizer.normalize(base, type: listType) + "/models"
        guard let url = URL(string: urlString), url.host != nil else {
            return .failure(Failure(status: nil, message: "Base URL 不是有效地址", url: urlString))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyAuth(&request, type: listType, draft: draft, key: key)
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                return .failure(Failure(status: code, message: "拉模型列表失败：" + describe(status: code, body: data, model: nil), url: urlString))
            }
            guard let listed = parseModelList(data) else {
                return .failure(Failure(status: code, message: "拉模型列表失败：返回的不是 JSON", url: urlString))
            }
            var models: [ProviderModel] = []
            var found: [String: ModelHint] = [:]
            for item in listed where !isNonChatListing(item.id) {
                // 接口没给显示名 → models.dev 目录补（research-magpie 2.5）
                let displayName = item.displayName ?? ModelCatalog.shared.model(for: item.id)?.name ?? item.id
                models.append(ProviderModel(credentialId: draft.id, modelId: item.id, name: displayName))
                if let hint = item.hint { found[item.id] = hint }
            }
            models.sort { $0.modelId.localizedCaseInsensitiveCompare($1.modelId) == .orderedAscending }
            return .success(Discovered(models: models, hints: found))
        } catch {
            return .failure(Failure(status: nil, message: "连不上：" + error.localizedDescription, url: urlString))
        }
    }

    struct ListedModel: Equatable {
        let id: String
        let displayName: String?
        let hint: ModelHint?
    }

    /// /models 宽容解析（omp openai-compatible.ts 同口径）：裸数组或 `data / models / result / items` 包一层；
    /// 每项是字符串，或对象取 `id ‖ model ‖ name`。不是 JSON 返回 nil；认不出列表 = 空。
    static func parseModelList(_ data: Data) -> [ListedModel]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let items: [Any]
        if let array = json as? [Any] {
            items = array
        } else if let obj = json as? [String: Any] {
            items = ["data", "models", "result", "items"].lazy.compactMap { obj[$0] as? [Any] }.first ?? []
        } else {
            items = []
        }
        return items.compactMap { item -> ListedModel? in
            if let id = nonEmpty(item) { return ListedModel(id: id, displayName: nil, hint: nil) }
            guard let obj = item as? [String: Any],
                  let id = nonEmpty(obj["id"]) ?? nonEmpty(obj["model"]) ?? nonEmpty(obj["name"]) else { return nil }
            let name = nonEmpty(obj["display_name"]) ?? nonEmpty(obj["name"]).flatMap { $0 == id ? nil : $0 }
            // 先各自转类型再回退：首选字段是 JSON null（NSNull）也轮到备选
            let context = (obj["context_length"] as? NSNumber)?.intValue ?? (obj["context_window"] as? NSNumber)?.intValue
            let modalities = ((obj["architecture"] as? [String: Any])?["input_modalities"] as? [String]) ?? (obj["input_modalities"] as? [String])
            let hint = context == nil && modalities == nil ? nil : ModelHint(contextTokens: context, inputModalities: modalities)
            return ListedModel(id: id, displayName: name, hint: hint)
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// 卡还在区域的地址上才按区域拉（地址自己改过的卡照旧打卡上的地址）
    private static func discoveryRegion(of preset: APIProvider, for card: APICredential) -> PresetRegion? {
        guard let region = preset.resolveRegion(for: card), let own = region.endpoints[card.type],
              BaseURLNormalizer.normalize(own, type: card.type) == BaseURLNormalizer.normalize(card.baseURL, type: card.type) else { return nil }
        return region
    }

    // MARK: 测试连接

    /// 用卡清单里的第一个聊天模型发一句最小请求；清单空就先拉 /models 再用拉到的第一个。
    static func test(draft: APICredential, key: String, preferredModelId: String? = nil,
                     session: URLSession = .shared) async -> Result<TestSuccess, Error> {
        switch draft.type {
        case .ccBridge: return .success(TestSuccess(summary: "CC Bridge (WebSocket，无需测试)", model: "", fetchedModels: []))
        case .localMLX: return .success(TestSuccess(summary: "本机模型，无需测试", model: "", fetchedModels: []))
        case .chatgptOAuth, .unsupported:
            return .failure(Failure(status: nil, message: "这类卡不走这里测试", url: nil))
        case .openaiCompatible, .anthropic: break
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(Failure(status: nil, message: "还没填 API Key", url: nil))
        }

        var fetched: [ProviderModel] = []
        var model = testModel(preferred: preferredModelId, lastUsed: draft.lastUsedModelId, models: draft.models)
        if model == nil {
            switch await fetchModels(draft: draft, key: key, session: session) {
            case .success(let list):
                fetched = list
                model = testModel(preferred: nil, lastUsed: nil, models: list)
                if model == nil {
                    return .failure(Failure(status: nil, message: "模型列表是空的，手填一个模型 ID 再测", url: nil))
                }
            case .failure(let err):
                return .failure(Failure(status: (err as? Failure)?.status,
                                        message: "卡上还没有模型，" + ((err as? Failure)?.message ?? err.localizedDescription) + "——手填一个模型 ID 再测",
                                        url: (err as? Failure)?.url))
            }
        }
        guard let model else { return .failure(Failure(status: nil, message: "没有可测的模型", url: nil)) }

        let base = BaseURLNormalizer.normalize(draft.baseURL, type: draft.type)
        let urlString = base + (draft.type == .anthropic ? "/messages" : "/chat/completions")
        guard let url = URL(string: urlString), url.host != nil else {
            return .failure(Failure(status: nil, message: "Base URL 不是有效地址", url: urlString))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, draft: draft, key: key)
        // 上限字段名跟聊天同一口径（ParamCompat：学到的 > OpenAI 官方 host 用 max_completion_tokens）
        let tokenKey = draft.type == .anthropic ? "max_tokens"
            : ParamCompat.resolve(providerType: draft.type, baseURL: base, modelId: model, reasoningEffort: ReasoningEffort.auto).maxTokensKey
        let body: [String: Any] = ["model": model, tokenKey: 1, "messages": [["role": "user", "content": "hi"]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                return .failure(Failure(status: code, message: describe(status: code, body: data, model: model), url: urlString))
            }
            return .success(TestSuccess(summary: "连接成功（用 \(model) 回了一句）", model: model, fetchedModels: fetched))
        } catch {
            return .failure(Failure(status: nil, message: "连不上：" + error.localizedDescription, url: urlString))
        }
    }

    // MARK: 纯函数（单测覆盖）

    static func testModel(preferred: String?, lastUsed: String?, models: [ProviderModel]) -> String? {
        if let p = preferred, !p.isEmpty { return p }
        if let l = lastUsed, models.contains(where: { $0.modelId == l }) { return l }
        return models.first(where: { !isNonChatModel($0.modelId) })?.modelId ?? models.first?.modelId
    }

    static func isNonChatModel(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.contains("embed") || l.contains("bge") || l.contains("rerank") || l.contains("/gte")
    }

    static func describe(status: Int, body: Data, model: String?) -> String {
        let upstream = serverMessage(body).map { "：" + $0 } ?? ""
        switch status {
        case 401: return "API Key 无效（401）" + upstream
        case 403: return "权限不足（403）" + upstream
        case 404: return "地址不对（404）——检查 Base URL 是不是到 /v1 为止" + upstream
        case 429: return "被限流或余额不足（429）" + upstream
        case 500...599: return "服务端暂时不可用（\(status)）" + upstream
        case 400 where model != nil && upstream.lowercased().contains("model"):
            return "模型 \(model ?? "") 在这家不可用（400）" + upstream
        default: return "请求失败（\(status)）" + upstream
        }
    }

    /// 测试失败的一句人话（小芽引导 key 卡用，文案照 design-onboarding-xiaoya 小样；编辑页的报错文案不走这里）。
    /// 上游原文、请求地址由卡片另起一行给，这里只说「多半是哪儿不对」
    static func humanReason(_ failure: Failure) -> String {
        switch failure.status {
        case 401?, 403?: return "key 不对，或者已经失效了"
        case 404?: return "地址不对——这家中转可能要写到 /v1，或者用的是 Anthropic 协议"
        case 429?: return "被限流了，或者余额不够了"
        case (500...599)?: return "这家服务暂时出问题了，过一会儿再试"
        case let code?: return "这家没接受这次请求（\(code)）"
        case nil:
            let m = failure.message
            if m.contains("timed out") || m.contains("超时") { return "15 秒没回音：网络不通，或者地址填错了域名" }
            if m.contains("连不上") { return "连不上：网络不通，或者地址填错了" }
            return m
        }
    }

    /// 上游错误体里的 message；不是 JSON（中转的 HTML 404 页）就给纯文本开头，HTML 不给
    static func serverMessage(_ data: Data) -> String? {
        let raw: String?
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { raw = m }
            else if let m = obj["message"] as? String { raw = m }
            else if let m = obj["error"] as? String { raw = m }
            else { raw = nil }
        } else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            raw = text.hasPrefix("<") ? nil : text
        }
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return String(s.prefix(300))
    }

    private static func isNonChatListing(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.contains("embed") || l.contains("tts") || l.contains("whisper") || l.contains("dall-e")
            || l.contains("moderation") || l.contains("davinci") || l.contains("babbage")
    }

    private static func applyAuth(_ request: inout URLRequest, type: ProviderType? = nil, draft: APICredential, key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type ?? draft.type {
        case .anthropic:
            request.setValue(k, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            request.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        for (h, v) in draft.extraHeaders { request.setValue(v, forHTTPHeaderField: h) }
    }
}
