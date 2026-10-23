import Foundation

// MARK: - Proxy Card Installer（发现→添加，整笔事务）
//
// "一键添加"要么整笔成功要么什么都不留：探活 → 写卡 → 拉模型 → 收藏默认模型。
// 中途任何一步失败都把卡撤回，不留一张聊不了天的半成品（卡的可用模型只来自 models，
// 聊天模型选择器又只列已收藏的——少任何一步，用户会拿到一张"保存成功但没法用"的卡）。

// MARK: - /health 三态（proxy 侧已定的响应形状）

enum ProxyHealth: Equatable {
    /// `{"status":"ok",...}`
    case ok(version: String?)
    /// `{"status":"degraded",...,"backend":{"executable":false}}` —— 发现得到但后端没配好，发消息会 503
    case degraded(String)
    /// HTTP 403 `{"error":{"reason":"untrusted-network","message":...}}` —— 这台 Mac 没批准当前网络
    case untrusted(String)
    /// 连不上（孤儿广播 / proxy 已退出）
    case unreachable

    var isUsable: Bool {
        if case .ok = self { return true }
        return false
    }

    /// 纯解析，跟网络无关，单测直接喂 body。
    static func parse(statusCode: Int, body: Data) -> ProxyHealth {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]

        if statusCode == 403 {
            let err = json?["error"] as? [String: Any]
            let message = (err?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // proxy 给的那句话本身就是操作指引，原样透出去，别翻译成"连接失败"
            return .untrusted(message.isEmpty ? "当前网络未被这台 Mac 批准。" : message)
        }
        guard (200..<300).contains(statusCode) else {
            return .degraded("服务返回 HTTP \(statusCode)")
        }

        let version = json?["version"] as? String
        let status = (json?["status"] as? String)?.lowercased() ?? ""
        // 老版本 proxy 不带 status：拿到 200 就当活着（跟 CC 桥探针同款放宽）
        if status.isEmpty || status == "ok" { return .ok(version: version) }

        let backend = json?["backend"] as? [String: Any]
        if (backend?["executable"] as? Bool) == false {
            let path = (backend?["path"] as? String) ?? ""
            return .degraded(path.isEmpty
                ? "这台 Mac 上的 claude 命令不可用"
                : "这台 Mac 上的 claude 命令不可用（\(path)）")
        }
        return .degraded("服务状态：\(status)")
    }
}

enum ProxyCardInstallError: LocalizedError {
    case health(ProxyHealth)
    case modelsFailed(String)
    case noModels

    var errorDescription: String? {
        switch self {
        case .health(.unreachable):
            return "连不上这个服务（可能已经退出了，广播还没撤回）"
        case .health(.untrusted(let message)):
            return message
        case .health(.degraded(let why)):
            return "服务在，但后端没准备好：\(why)"
        case .health(.ok):
            return "探活通过"
        case .modelsFailed(let why):
            return "拉模型列表失败：\(why)"
        case .noModels:
            return "服务没返回任何模型"
        }
    }
}

enum ProxyCardInstaller {
    /// 发现添加出来的卡专属 id 前缀 —— 卡本身没有"能力"字段，靠 id 认出它是纯文本代理。
    /// （同款手法：ccBridge / codexBridge 也是靠固定 id 区分 engine。）
    static let idPrefix = "mpclaude-"

    /// C2：key 只是占位——没 key 的卡不进 enabledCredentials，模型选择器就看不见它。
    /// 准入靠 C4 的网络白名单（TXT `auth=lan`），不靠这个值。
    static let placeholderKey = "local"

    static func isProxyCard(id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// 默认模型按能力挑，不按字母序拿第一个 —— 模型列表是排过序的，字母序第一个永远是 haiku
    /// （h < o < s），拿最弱的模型当默认会让人以为这条通路本身不行。
    /// 顺序：sonnet（日常主力）> opus（贵但强）> 未知名字 > haiku（兜底）。
    static func pickDefaultModel(_ models: [ProviderModel]) -> ProviderModel? {
        func rank(_ id: String) -> Int {
            let name = id.lowercased()
            if name.contains("sonnet") { return 0 }
            if name.contains("opus") { return 1 }
            if name.contains("haiku") { return 3 }
            return 2
        }
        return models.min { a, b in
            let (ra, rb) = (rank(a.modelId), rank(b.modelId))
            return ra != rb ? ra < rb : a.modelId < b.modelId
        }
    }

    /// 探活：2s 超时。既挡孤儿广播（proxy 崩了但 mDNS 还没撤回），也把 degraded / 403
    /// 这两种"发现得到但用不了"分辨出来，免得添加完才在聊天页炸。
    static func checkHealth(_ url: URL, timeout: TimeInterval = 2) async -> ProxyHealth {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return ProxyHealth.parse(statusCode: http.statusCode, body: data)
        } catch {
            return .unreachable
        }
    }

    /// 整笔安装。成功返回落盘后的卡；失败已自行回滚。
    @discardableResult
    @MainActor
    static func install(_ proxy: DiscoveredProxy, into pm: ProviderManager) async throws -> APICredential {
        guard let healthURL = proxy.healthURL else {
            throw ProxyCardInstallError.health(.unreachable)
        }
        let health = await checkHealth(healthURL)
        guard health.isUsable else { throw ProxyCardInstallError.health(health) }

        let cardId = idPrefix + UUID().uuidString
        let card = APICredential(
            id: cardId,
            name: proxy.displayName,
            emoji: pm.allocateUnusedEmoji(),
            presetId: nil,
            type: .anthropic,
            baseURL: proxy.baseURL,
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: []
        )
        pm.addCredential(card)
        pm.setApiKey(placeholderKey, for: cardId)

        if case .failure(let err) = await pm.fetchAndMergeModels(credentialId: cardId) {
            pm.removeCredential(id: cardId)
            throw ProxyCardInstallError.modelsFailed(err.localizedDescription)
        }
        guard let saved = pm.credentials.first(where: { $0.id == cardId }),
              let defaultModel = pickDefaultModel(saved.models) else {
            pm.removeCredential(id: cardId)
            throw ProxyCardInstallError.noModels
        }

        if !pm.isFavoriteModel(id: defaultModel.id) {
            pm.toggleFavoriteModel(id: defaultModel.id)
        }
        // 只在当前主模型缺位时才顶上，不抢正在用的模型
        let selectedKey = "selectedChatModel"
        let current = UserDefaults.standard.string(forKey: selectedKey) ?? ""
        if current.isEmpty || pm.model(byId: current) == nil {
            UserDefaults.standard.set(defaultModel.id, forKey: selectedKey)
        }
        return saved
    }
}
