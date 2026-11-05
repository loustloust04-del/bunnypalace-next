import Foundation

// MARK: - key 卡 · 草稿状态机（plan-onboarding-xiaoya-impl §3；小样 keyCard ③–⑦）
// 草稿只在内存（CredentialDraft + key 字符串），测试走 ProviderProbe.test、不落盘（H1 / H2）；
// 改服务商 / 协议 / 地址 / key 任一项 → 上次测试作废、回编辑态、给一行提示（H2）；
// 「就用这个」是唯一落盘点，落盘函数由 P4 注入（CredentialCommitter.commit(adopt: .model)），这里不碰卡表和钥匙串。
// 单例类预设（Claude Code / Codex / ChatGPT 账号 / 本机模型）和本机 / 局域网地址的预设不进服务商列表。

@MainActor
final class XiaoyaKeyCardModel: ObservableObject {
    enum Phase: Equatable {
        case edit
        case testing
        case failed(Failure)
        case succeeded(Success)
    }

    /// 失败条四样（H1）：状态码 + 人话 + 上游原文 + 实际请求地址
    struct Failure: Equatable {
        var status: Int?
        var reason: String
        var upstream: String?
        var url: String
    }

    struct Success: Equatable {
        /// 测试时发 hi 的那个模型
        var testedModel: String
        /// 挑默认模型的单选清单（推荐的排第一）
        var models: [ProviderModel]
        /// 「★ 省钱好用」那个
        var recommended: String
    }

    /// (草稿卡, key, 手填的测试模型)：自定义中转不给 /models 时靠手填的模型 ID 发 hi（sol #8）
    typealias Probe = (APICredential, String, String?) async -> Result<ProviderProbe.TestSuccess, Error>
    typealias Fetch = (APICredential, String) async -> Result<[ProviderModel], Error>
    /// (草稿, key, 用户挑的模型 id) → 存好的卡 id。P4 接 CredentialCommitter.commit(draft, key:, existing: nil, adopt: .model(id), providerManager:)
    typealias Commit = (CredentialDraft, String, String) -> String

    /// 测试用的草稿卡 id（不进卡表）
    nonisolated static let probeCredentialId = "xiaoya-key-probe"
    /// 服务商 chips 第一排（小样：OpenAI / Anthropic / Gemini / 自定义中转 / 更多 N 家…）
    static let primaryPresetIds = [APIProvider.openai.id, APIProvider.anthropic.id, APIProvider.gemini.id]

    /// 引导里能选的预设：HTTP 两种卡、https 官方地址、不是单例
    static var guidedPresets: [APIProvider] {
        APIProvider.presets.filter { preset in
            let draft = CredentialDraft(presetSelection: preset.id)
            return draft.isHTTP && !draft.isSingletonPreset && preset.baseURL.lowercased().hasPrefix("https://")
        }
    }

    @Published private(set) var selection: String = APIProvider.openai.id
    @Published private(set) var customType: ProviderType = .openaiCompatible
    @Published private(set) var customBaseURL = ""
    @Published private(set) var key = ""
    @Published var showKey = false
    @Published var showAllProviders = false
    @Published private(set) var phase: Phase = .edit
    /// 作废提示（↻ 一行），下次点「测一下」清掉
    @Published private(set) var note: String?
    @Published private(set) var pickedModel: String?
    @Published private(set) var manualModel = ""

    /// 每次作废 / 新测试 +1：在途的测试回来发现代数变了就丢掉结果
    private var generation = 0
    private let probe: Probe
    private let fetch: Fetch

    init(probe: @escaping Probe = { await ProviderProbe.test(draft: $0, key: $1, preferredModelId: $2) },
         fetch: @escaping Fetch = { await ProviderProbe.fetchModels(draft: $0, key: $1) }) {
        self.probe = probe
        self.fetch = fetch
    }

    // MARK: 派生

    var isCustom: Bool { selection == CredentialDraft.customSelection }

    var preset: APIProvider? { APIProvider.presets.first(where: { $0.id == selection }) }

    /// 给人看的服务商名（也当新卡昵称）
    var providerName: String {
        if isCustom {
            let normalized = BaseURLNormalizer.normalize(customBaseURL, type: customType)
            return URLComponents(string: normalized)?.host ?? "自定义中转"
        }
        return Self.chipTitle(selection)
    }

    static func chipTitle(_ presetId: String) -> String {
        switch presetId {
        case CredentialDraft.customSelection: return "自定义中转"
        case APIProvider.openai.id: return "OpenAI"
        case APIProvider.anthropic.id: return "Anthropic"
        case APIProvider.gemini.id: return "Gemini"
        default: return APIProvider.presets.first(where: { $0.id == presetId })?.name ?? presetId
        }
    }

    /// 当前草稿（不含 key）；测试成功后带上挑模型清单，存卡用
    var draft: CredentialDraft {
        var d = CredentialDraft(presetSelection: selection, customType: customType, customBaseURL: customBaseURL,
                                nickname: providerName)
        if case .succeeded(let s) = phase {
            d.models = s.models
        } else if !isCustom {
            d.models = preset?.models ?? []
        }
        return d
    }

    /// 「实际请求：」完整网址（与保存同一个规整函数）；自定义没填地址时 nil
    var endpointPreview: String? {
        let d = draft
        guard !d.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return BaseURLNormalizer.chatEndpoint(base: d.baseURL, type: d.type)
    }

    /// 官方地址（预设时显示「官方地址，不用改」）
    var officialBaseURL: String { preset?.baseURL ?? "" }

    /// 测试中那行「用 X 发一句 hi」：手填了用手填的，预设知道用哪个，自定义要先拉清单
    var testingModelHint: String? {
        ProviderProbe.testModel(preferred: manualTestModel, lastUsed: nil, models: draft.models)
    }

    /// 编辑 / 失败态手填的模型 ID：测试就用它发 hi（不给 /models 的中转也能测通）；成功后它就是选中的那个
    private var manualTestModel: String? {
        let manual = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? nil : manual
    }

    var isTesting: Bool { phase == .testing }

    var canTest: Bool {
        guard !isTesting else { return false }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isCustom || !customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 手填优先，其次单选
    var chosenModel: String? {
        let manual = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return pickedModel
    }

    var canSave: Bool {
        guard case .succeeded = phase else { return false }
        return chosenModel != nil
    }

    // MARK: 编辑（四种改动都会作废上次结果）

    func selectProvider(_ id: String) {
        guard id != selection else { return }
        selection = id
        invalidate("换了服务商：之前的测试作废，这是一张新草稿")
        manualModel = ""   // 换了家，手填的模型 ID 不再作数
    }

    func setProtocol(_ type: ProviderType) {
        guard type != customType else { return }
        customType = type
        invalidate("换了协议：之前的测试作废")
    }

    func setBaseURL(_ value: String) {
        guard value != customBaseURL else { return }
        customBaseURL = value
        invalidate("改了地址：要重新测")
    }

    func setKey(_ value: String) {
        guard value != key else { return }
        key = value
        invalidate("改了 key：要重新测")
    }

    /// 成功后「换一家」：回编辑态重新选
    func changeProvider() {
        invalidate("重新选服务商")
        manualModel = ""
    }

    func pick(_ modelId: String) {
        pickedModel = modelId
        manualModel = ""
    }

    func setManualModel(_ value: String) {
        manualModel = value
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pickedModel = nil }
    }

    /// 只有出过结果（或正在测）才作废；还在编辑时改字段不出提示
    private func invalidate(_ why: String) {
        switch phase {
        case .edit:
            return
        case .testing, .failed, .succeeded:
            generation += 1
            phase = .edit
            note = why
            pickedModel = nil
            // 手填的模型 ID 留着：改地址 / key 重测还要用它（换服务商那两处另外清）
        }
    }

    // MARK: 测试 / 保存

    func test() async {
        guard canTest else { return }
        generation += 1
        let gen = generation
        note = nil
        phase = .testing
        let draft = self.draft
        let key = self.key
        let preferred = manualTestModel
        let credential = draft.makeCredential(id: Self.probeCredentialId, existing: nil)

        let result = await probe(credential, key, preferred)
        guard gen == generation else { return }
        switch result {
        case .failure(let error):
            phase = .failed(failure(from: error))
        case .success(let ok):
            var models = ok.fetchedModels
            if models.isEmpty, case .success(let list) = await fetch(credential, key) { models = list }
            guard gen == generation else { return }
            if models.isEmpty { models = draft.models }
            if models.isEmpty, !ok.model.isEmpty {
                models = [ProviderModel(credentialId: Self.probeCredentialId, modelId: ok.model, name: ok.model)]
            }
            let recommended = Self.recommend(models, tested: ok.model, price: { PricingCatalog.price(for: $0) })
            let ordered = models.filter { $0.modelId == recommended } + models.filter { $0.modelId != recommended }
            phase = .succeeded(Success(testedModel: ok.model, models: ordered, recommended: recommended))
            // 拿手填的模型测通的：就存它（手填优先）；否则默认选推荐的
            if preferred == nil {
                pickedModel = recommended.isEmpty ? nil : recommended
                manualModel = ""
            } else {
                pickedModel = nil
            }
        }
    }

    /// 「就用这个」：唯一落盘点，调注入的落盘函数；返回给答案用的摘要
    func save(commit: Commit) -> XiaoyaKeySaved? {
        guard canSave, let model = chosenModel else { return nil }
        let credentialId = commit(draft, key, model)
        return XiaoyaKeySaved(credentialId: credentialId, providerName: providerName, modelId: model)
    }

    private func failure(from error: Error) -> Failure {
        let fallbackURL = endpointPreview ?? ""
        guard let f = error as? ProviderProbe.Failure else {
            return Failure(status: nil, reason: error.localizedDescription, upstream: nil, url: fallbackURL)
        }
        return Failure(status: f.status, reason: ProviderProbe.humanReason(f), upstream: Self.upstream(of: f), url: f.url ?? fallbackURL)
    }

    // MARK: 纯函数

    /// 上游原文：Failure.message 是「我们的前缀 + ：+ 上游 message」，把前缀剥掉；有状态码却没有上游那段就不给
    static func upstream(of failure: ProviderProbe.Failure) -> String? {
        var text = failure.message
        if let status = failure.status {
            let prefix = ProviderProbe.describe(status: status, body: Data(), model: nil) + "："
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            } else if let r = text.range(of: "）：") {
                text = String(text[r.upperBound...])
            } else {
                return nil     // 上游没给原文（只有我们的一句）
            }
        } else if text.hasPrefix("连不上：") {
            text = String(text.dropFirst("连不上：".count))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != ProviderProbe.humanReason(failure) else { return nil }
        return text
    }

    /// 「★ 省钱好用」：清单里知道价格的聊天模型挑最便宜的；都不知道价就用测通的那个
    static func recommend(_ models: [ProviderModel], tested: String, price: (String) -> ModelPricing?) -> String {
        let priced = models
            .filter { !ProviderProbe.isNonChatModel($0.modelId) }
            .compactMap { m -> (String, Double)? in
                guard let p = price(m.modelId) else { return nil }
                let total = p.inputUSDPerMTok + p.outputUSDPerMTok
                return total > 0 ? (m.modelId, total) : nil
            }
        if let cheapest = priced.min(by: { $0.1 < $1.1 }) { return cheapest.0 }
        if !tested.isEmpty { return tested }
        return models.first?.modelId ?? ""
    }
}

#if DEBUG
extension XiaoyaKeyCardModel {
    enum Sample: String, CaseIterable {
        case edit, custom, testing, failed401, failed404, timeout, succeeded, invalidated
    }

    /// 样张页：直接摆出各状态；按钮点下去走假的测试（key 里带 ok 就成功，否则 401）
    static func sample(_ which: Sample) -> XiaoyaKeyCardModel {
        let model = XiaoyaKeyCardModel(probe: { _, key, _ in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if key.lowercased().contains("ok") {
                return .success(ProviderProbe.TestSuccess(summary: "", model: "gpt-4o-mini", fetchedModels: []))
            }
            return .failure(ProviderProbe.Failure(status: 401, message: "API Key 无效（401）：Incorrect API key provided: sk-demo…a8Fq",
                                                  url: "https://relay.example.com/v1/chat/completions"))
        }, fetch: { _, _ in
            .success(["gpt-4o-mini", "deepseek-chat", "claude-sonnet-4-5", "qwen-max"].map {
                ProviderModel(credentialId: probeCredentialId, modelId: $0, name: $0)
            })
        })
        let relay = "relay.example.com"
        let endpoint = "https://relay.example.com/v1/chat/completions"
        switch which {
        case .edit:
            break
        case .custom:
            model.selection = CredentialDraft.customSelection
            model.customBaseURL = relay
            model.key = "sk-demo-7Hq2a8Fq"
        case .testing:
            model.selection = CredentialDraft.customSelection
            model.customBaseURL = relay
            model.key = "sk-demo-7Hq2a8Fq"
            model.phase = .testing
        case .failed401:
            model.selection = CredentialDraft.customSelection
            model.customBaseURL = relay
            model.key = "sk-demo-7Hq2a8Fq"
            model.phase = .failed(Failure(status: 401, reason: "key 不对，或者已经失效了",
                                          upstream: #"{"error":{"message":"Incorrect API key provided: sk-demo…a8Fq","code":"invalid_api_key"}}"#,
                                          url: endpoint))
        case .failed404:
            model.selection = CredentialDraft.customSelection
            model.customBaseURL = relay
            model.key = "sk-demo-7Hq2a8Fq"
            model.phase = .failed(Failure(status: 404, reason: "地址不对——这家中转可能要写到 /v1，或者用的是 Anthropic 协议",
                                          upstream: "404 page not found", url: endpoint))
        case .timeout:
            model.selection = CredentialDraft.customSelection
            model.customBaseURL = relay
            model.key = "sk-demo-7Hq2a8Fq"
            model.phase = .failed(Failure(status: nil, reason: "15 秒没回音：网络不通，或者地址填错了域名",
                                          upstream: "The request timed out.", url: endpoint))
        case .succeeded:
            model.selection = CredentialDraft.customSelection
            model.customBaseURL = relay
            model.key = "sk-demo-7Hq2a8Fq"
            let models = ["gpt-4o-mini", "deepseek-chat", "claude-sonnet-4-5", "qwen-max"].map {
                ProviderModel(credentialId: probeCredentialId, modelId: $0, name: $0)
            }
            model.phase = .succeeded(Success(testedModel: "gpt-4o-mini", models: models, recommended: "gpt-4o-mini"))
            model.pickedModel = "gpt-4o-mini"
        case .invalidated:
            model.selection = APIProvider.anthropic.id
            model.key = "sk-ant-demo"
            model.note = "换了服务商：之前的测试作废，这是一张新草稿"
        }
        return model
    }
}
#endif
