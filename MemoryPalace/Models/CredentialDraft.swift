import Foundation

// MARK: - API 卡草稿 + 唯一落盘入口（plan-onboarding-xiaoya-impl §1 P1a）
// 从 APICredentialEditor 抽出来，行为不变：编辑页和小芽引导的 key 卡共用。
// 草稿不含 key（key 由调用方单独拿着）；测试 / 拉模型都拿 makeCredential 拼出的卡走 ProviderProbe，不落盘；
// 只有 CredentialCommitter.commit 写卡表和钥匙串。

struct CredentialDraft: Equatable, Codable {
    static let customSelection = "_custom_"
    /// 老卡按地址反查不到区域：沿用卡上自己的地址和格式（plan-provider-presets §5.2）
    static let ownRegion = "_own_"

    var presetSelection: String = CredentialDraft.customSelection   // "_custom_" 或 preset.id（如 "openrouter"）
    var customType: ProviderType = .openaiCompatible
    var customBaseURL: String = ""
    var nickname: String = ""
    var emoji: String = "🔑"
    var models: [ProviderModel] = []
    var toolsSupported: Bool = true
    var sideCallStreaming: Bool = true
    /// 预设的区域 id：nil = 默认区域；`ownRegion` = 沿用卡上自己的地址
    var regionSelection: String?
    /// 预设区域两种格式都有时选的那种：nil = 预设默认格式
    var presetProtocol: ProviderType?

    var isCustom: Bool { presetSelection == Self.customSelection }

    var preset: APIProvider? { APIProvider.presets.first(where: { $0.id == presetSelection }) }

    var usesOwnBaseURL: Bool { !isCustom && preset != nil && regionSelection == Self.ownRegion }

    /// 当前区域（自定义卡、沿用卡上地址时没有）
    var region: PresetRegion? {
        guard let preset, !usesOwnBaseURL else { return nil }
        return preset.region(id: regionSelection) ?? preset.defaultRegion
    }

    var type: ProviderType {
        if isCustom || usesOwnBaseURL { return customType }
        guard let preset, let region else { return .openaiCompatible }
        return preset.type(in: region, preferring: presetProtocol)
    }

    /// Ollama 跑在用户自己的机器上：地址得能改（iOS 上 localhost 是手机自己，#092 零散雷）
    var editsBaseURL: Bool { isCustom || presetSelection == APIProvider.ollama.id }

    var baseURL: String {
        if editsBaseURL || usesOwnBaseURL { return customBaseURL }
        return region?.endpoints[type] ?? ""
    }

    /// 「去拿 key」的链接（沿用卡上地址时用这家默认区域的）
    var keysURL: URL? { (region ?? preset?.defaultRegion)?.keysURL }

    /// 换家判断：预设 + 区域 + 实际格式（自定义卡 = 协议）。只改地址不算换家
    var providerKey: String {
        if isCustom { return "\(Self.customSelection)/\(customType.rawValue)" }
        return "\(presetSelection)/\(usesOwnBaseURL ? Self.ownRegion : region?.id ?? "")/\(type.rawValue)"
    }

    /// 判脏用的区域 / 格式：nil 和写明的默认区域、默认格式算同一个（旧草稿没这两个字段）；`ownRegion` 和默认区域不算
    var effectiveRegionSelection: String? { usesOwnBaseURL ? Self.ownRegion : region?.id }
    var effectivePresetProtocol: ProviderType? { region == nil ? nil : type }

    /// 换提供商：区域、格式回到新家的默认；换回卡原来那家就还原原来的区域和格式，
    /// 原来沿用自己地址的连地址和协议一起还原（customBaseURL / customType 各家共用，别把别家改过的带回原卡）
    mutating func switchPreset(to new: String, original: CredentialDraft?) {
        presetSelection = new
        guard let original, original.presetSelection == new else {
            regionSelection = nil
            presetProtocol = nil
            return
        }
        regionSelection = original.regionSelection
        presetProtocol = original.presetProtocol
        if original.usesOwnBaseURL {
            customBaseURL = original.customBaseURL
            customType = original.customType
        }
    }

    /// 换区域（区域 Picker 的 setter）：格式交给目标区域重新定默认（套餐区默认 Anthropic，plan Q3）；换回卡原来的区域就还原原来的格式。
    /// 装载卡 / 恢复草稿直接赋值不走这里，旧卡的格式不变
    mutating func switchRegion(to new: String, original: CredentialDraft?) {
        guard new != effectiveRegionSelection else { return }
        regionSelection = new
        if let original, original.presetSelection == presetSelection,
           original.effectiveRegionSelection == effectiveRegionSelection {
            presetProtocol = original.presetProtocol
        } else {
            presetProtocol = nil
        }
    }

    /// 已存的卡 → 编辑页草稿：区域 = regionId ?? 按地址反查。固定地址的 HTTP 预设反查不到 = 卡上是自己的地址，
    /// 沿用卡的地址和格式；claude-p 的地址靠发现填，维持原样
    static func loaded(from card: APICredential) -> CredentialDraft {
        var d = CredentialDraft(presetSelection: card.presetId ?? customSelection, customType: card.type, customBaseURL: card.baseURL,
                                nickname: card.name, emoji: card.emoji, models: card.models, toolsSupported: card.toolsSupported ?? true,
                                sideCallStreaming: card.sideCallStreaming ?? true)
        guard let preset = d.preset else { return d }
        if let r = preset.resolveRegion(for: card) {
            d.regionSelection = r.id
            d.presetProtocol = r.offers(card.type) ? card.type : nil
        } else if d.isHTTP, !d.editsBaseURL, preset.id != APIProvider.claudeP.id,
                  card.type == .openaiCompatible || card.type == .anthropic {
            d.regionSelection = ownRegion
        }
        return d
    }

    /// 走 HTTP 的两种卡（测试 / 拉模型都用草稿）；桥卡、ChatGPT 账号、本机模型照旧
    var isHTTP: Bool { type == .openaiCompatible || type == .anthropic }

    /// 单例卡（同类全局只能一张），卡 id = 预设 id
    var isSingletonPreset: Bool { type == .chatgptOAuth || type == .ccBridge || type == .localMLX }

    /// 卡的请求头：每次按当前预设 + 格式重算（不继承卡上旧的），切回 OpenAI 格式自然不带 anthropic-version。
    /// Anthropic 格式的聊天请求只从卡上拿这个头，预设没写（新预设的 Anthropic 区域）就补上，写了的不覆盖
    var extraHeaders: [String: String] {
        var headers = isCustom ? [:] : (preset?.extraHeaders ?? [:])
        if type == .anthropic, !headers.keys.contains(where: { $0.caseInsensitiveCompare("anthropic-version") == .orderedSame }) {
            headers["anthropic-version"] = "2023-06-01"
        }
        return headers
    }

    /// 草稿卡（不进卡表）：测试、拉模型、保存都从它出发
    func makeCredential(id: String, existing: APICredential?) -> APICredential {
        APICredential(
            id: id,
            name: nickname.trimmingCharacters(in: .whitespaces),
            emoji: emoji.trimmingCharacters(in: .whitespaces),
            presetId: isCustom ? nil : presetSelection,
            type: type,
            baseURL: BaseURLNormalizer.normalize(baseURL, type: type),
            extraHeaders: extraHeaders,
            models: models.map { ProviderModel(credentialId: id, modelId: $0.modelId, name: $0.name) },
            createdAt: existing?.createdAt ?? Date(),
            lastUsedAt: existing?.lastUsedAt,
            lastUsedModelId: existing?.lastUsedModelId,
            toolsSupported: toolsSupported ? nil : false,
            sideCallStreaming: sideCallStreaming ? nil : false,
            regionId: usesOwnBaseURL ? existing?.regionId : region?.id
        )
    }
}

@MainActor
enum CredentialCommitter {
    /// 存完挑哪个模型收藏 / 按 K3 接管主模型：编辑器 = autoPick；引导 = 用户点的那个（裸 modelId，不带卡 id 前缀）
    enum Adopt: Equatable {
        case none, autoPick, model(String)
    }

    /// 唯一落盘入口：卡 + key（+ 本机模型收藏 / forgetModels / 主模型），返回卡 id。
    /// ccBridge 的 Hub 地址不归卡草稿，调用方自己存（CCBridgeEndpoints.saveManual）。
    /// `modelHints`：页面拉 /models 拿到的元数据，按这次落盘的真实卡 id 整份写进旁表；nil = 这次没拉过，不动卡上已有的
    @discardableResult
    static func commit(_ draft: CredentialDraft, key: String, existing: APICredential?,
                       adopt: Adopt, modelHints: [String: ModelHint]? = nil, hintStore: ModelHints = .shared,
                       providerManager pm: ProviderManager) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = draft.preset

        // 固定 id 的特例：Claude Code / Codex / ChatGPT 账号 / 本机模型都是单卡全局服务，id = 预设 id
        // （cc-bridge / codex-bridge / chatgpt-oauth / local-mlx）。以前 ccBridge 一律 "cc-bridge"，
        // 新建 Codex 会盖掉 Claude Code 卡、下次启动整张被删（#092 零散雷）
        let cardId: String
        if let existing {
            cardId = existing.id
        } else if draft.isSingletonPreset {
            cardId = draft.presetSelection
        } else {
            cardId = "cred-\(UUID().uuidString)"
        }

        var cred = draft.makeCredential(id: cardId, existing: existing)
        if cred.name.isEmpty { cred.name = "未命名" }
        if cred.emoji.isEmpty { cred.emoji = "🔑" }
        if !draft.isHTTP {
            // 桥卡 / ChatGPT 账号 / 本机模型：模型清单不走草稿，沿用已存的（新建时用预设自带的）
            cred.models = existing?.models
                ?? (preset?.models.map { ProviderModel(credentialId: cardId, modelId: $0.modelId, name: $0.name) } ?? [])
        }
        let picked: ProviderModel?
        switch adopt {
        case .none:
            picked = nil
        case .autoPick:
            picked = ProviderManager.autoPickModel(cred.models, presetFirst: preset?.models.first?.modelId)
        case .model(let modelId):
            // 引导里手填的模型 ID 不在清单上：补进清单，不然主模型指向一个卡上没有的模型
            if let m = cred.models.first(where: { $0.modelId == modelId }) {
                picked = m
            } else {
                let m = ProviderModel(credentialId: cardId, modelId: modelId, name: modelId)
                cred.models.append(m)
                picked = m
            }
        }
        let dropped = Set((existing?.models ?? []).map(\.id)).subtracting(cred.models.map(\.id))
        // K3（10-15）：这次保存前别的卡里有能用的，就不接管主模型（换了家的卡自己不算）
        let hadUsableCard = pm.credentials.contains { $0.id != cardId && pm.isUsable($0) }

        pm.addCredential(cred)
        pm.forgetModels(dropped)
        if let modelHints { hintStore.replace(credentialId: cardId, with: modelHints) }
        switch draft.type {
        case .ccBridge:
            // Token 可空（loopback）。主 hub 口令（cc-bridge）只由 CCHubRegistry 的配对入口写一次（impl1 #10），这里不再写第二遍
            if cardId != HubTokenStore.keychainAccount { pm.setApiKey(trimmedKey, for: cardId) }
        case .chatgptOAuth:
            // chatgptOAuth：登录时已即时存了 token；这里不动 keychain
            // 仅落卡（emoji/昵称/preset/baseURL/extraHeaders/models）
            break
        case .localMLX:
            // 没有 key；已经装好的模型顺手收藏，选择器里马上能看见
            for model in cred.models where AssistantModelStore.installedDirectory(modelId: model.modelId) != nil
                && !pm.isFavoriteModel(id: model.id) {
                pm.toggleFavoriteModel(id: model.id)
            }
        default:
            pm.setApiKey(trimmedKey, for: cardId)
        }
        if let picked { pm.adoptNewModel(picked, hadUsableCard: hadUsableCard) }
        return cardId
    }
}
