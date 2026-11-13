import Foundation

// MARK: - API Provider（预设数据表，plan-provider-presets §2.1）
//
// 一家预设 = 表里一行，下挂 ≥1 个区域（第一个是默认）。只读，不持久化、不进列表、不与 Keychain 关联：
// 「新建卡」时给编辑页带出格式 / 地址 / 请求头 / 预填模型。卡上只存 presetId + regionId + 实际 baseURL，表改了不影响已存的卡。
// `type` / `baseURL` 是默认区域的值，老 call site 语义不变。

struct APIProvider: Identifiable {
    let id: String                          // 预设 id，如 "openrouter"；上线后不改
    var name: String
    var group: PresetGroup
    var regions: [PresetRegion]             // ≥1；第一个是默认（老预设的默认区域 = 原 baseURL，老卡反查靠它）
    var regionLabel: String = "套餐与地区"
    var defaultProtocol: ProviderType       // 区域两种格式都有时默认用哪种
    var extraHeaders: [String: String] = [:]
    var models: [ProviderModel] = []        // 模板里预填的模型（构造 credential 时复制一份过去）
    var login: PresetLogin = .apiKey

    var defaultRegion: PresetRegion { regions[0] }
    var type: ProviderType { type(in: defaultRegion, preferring: nil) }
    var baseURL: String { defaultRegion.endpoints[type] ?? "" }

    /// 这个区域用哪种格式：想要的区域有就用它，没有就用区域有的第一种。
    /// 没指定时套餐区域默认 Anthropic、按量区域默认 defaultProtocol（plan Q3：Anthropic 这条路思考和签名都通）
    func type(in region: PresetRegion, preferring wanted: ProviderType?) -> ProviderType {
        let want = wanted ?? (region.isPlan ? .anthropic : defaultProtocol)
        return region.offers(want) ? want : (region.protocols.first ?? defaultProtocol)
    }
}

enum PresetGroup: CaseIterable {
    case overseas, domestic, aggregator, account, local

    /// 提供商菜单的分节名：账号和本机并成一节
    var menuSection: String {
        switch self {
        case .overseas: "海外"
        case .domestic: "国内"
        case .aggregator: "聚合平台"
        case .account, .local: "本机与账号"
        }
    }
}

/// 区域 / 套餐变体：切换时这一组端点、链接、目录 id 一起换。
struct PresetRegion: Identifiable, Equatable {
    let id: String                          // 会落进卡里；改显示名不改 id
    var name: String
    var endpoints: [ProviderType: String]   // 规整后的 base（BaseURLNormalizer 口径）；账号 / 桥 / 本机类只放一个
    var keysURL: URL? = nil
    var catalogIds: [String] = []           // models.dev provider id
    var listsModels: Bool = true            // false = 不问 /models，直接用种子
    var seedModelIds: [String] = []         // 区域专属种子；空 = 用 APIProvider.models
    var keyHint: String? = nil              // key 输入框占位
    var isPlan: Bool = false
    var terms: PlanTerms? = nil

    var protocols: [ProviderType] {
        [.openaiCompatible, .anthropic, .chatgptOAuth, .ccBridge, .localMLX].filter { endpoints[$0] != nil }
    }

    func offers(_ type: ProviderType) -> Bool { endpoints[type] != nil }
}

/// 套餐条款提示（plan Q1 = A）：编辑页显示「{预设名}官方说明：{summary} 看原文 ↗」
struct PlanTerms: Equatable {
    var summary: String
    var url: URL

    /// 官方条款写着套餐只给编程 / AI 工具用的那几家（plan §3.4，2026-10-15 官方页）
    static func codingToolsOnly(_ url: String) -> PlanTerms {
        PlanTerms(summary: "套餐额度只给编程类工具用。在记忆花园里用是你自己的选择，可能被限额或停用。", url: URL(string: url)!)
    }
}

enum PresetLogin {
    case apiKey, openRouter, chatgptOAuth, bridge, local, discovery
}

// MARK: - 查询

extension APIProvider {
    static func preset(id: String?) -> APIProvider? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    func region(id: String?) -> PresetRegion? {
        guard let id else { return nil }
        return regions.first { $0.id == id }
    }

    /// 卡 → 区域：regionId 命中就用；否则拿规整后的 baseURL 比对每个区域这种格式的端点；都不中 = 卡上是自己的地址
    func resolveRegion(for card: APICredential) -> PresetRegion? {
        if let r = region(id: card.regionId) { return r }
        let base = BaseURLNormalizer.normalize(card.baseURL, type: card.type)
        return regions.first { region in
            region.endpoints[card.type].map { BaseURLNormalizer.normalize($0, type: card.type) } == base
        }
    }

    /// 区域的种子模型：区域自带的优先，没有就用预设的
    func seedModels(in region: PresetRegion?, credentialId: String) -> [ProviderModel] {
        if let ids = region?.seedModelIds, !ids.isEmpty {
            return ids.map { ProviderModel(credentialId: credentialId, modelId: $0, name: $0) }
        }
        return models.map { ProviderModel(credentialId: credentialId, modelId: $0.modelId, name: $0.name) }
    }

    /// 提供商菜单：按分组分节，节内保持 presets 的顺序
    static var menuSections: [(title: String, presets: [APIProvider])] {
        var titles: [String] = []
        for group in PresetGroup.allCases where !titles.contains(group.menuSection) { titles.append(group.menuSection) }
        return titles.compactMap { title -> (title: String, presets: [APIProvider])? in
            let list = presets.filter { $0.group.menuSection == title }
            return list.isEmpty ? nil : (title, list)
        }
    }
}

// MARK: - 表

extension APIProvider {
    /// 内置预设目录。编辑页的「提供商」菜单就读它。
    static let presets: [APIProvider] = {
        var list: [APIProvider] = [
            .chatgptOAuth, .anthropic, .openai, .openrouter, .deepseek, .groq, .xai,
            .siliconflow, .dashscope, .zhipu, .doubao, .gemini, .moonshot, .ollama, .claudeP, .ccBridge, .codexBridge,
            // 阶段 3 / 4（plan-provider-presets §3.2）：官方明说允许第三方工具的 Kimi Code、阶跃排前面（Q1）
            .kimiCode, .stepfun, .zai, .minimax, .xiaomi, .qianfan, .tencent, .huawei,
            .together, .fireworks, .nvidia,
        ]
        // 本机模型（plan-小芽-v3 §1）：放在 Ollama 后面；模拟器跑不了 MLX，不列
        if LocalLLMService.isSupported {
            list.insert(.localMLX, at: list.firstIndex(where: { $0.id == APIProvider.ollama.id })! + 1)
        }
        #if PERSONAL_APPS
        #if DEBUG
        // 粟粟自用：只进她的 Debug 包，Release / TestFlight 不出现
        list.insert(.kimiP, at: list.firstIndex(where: { $0.id == APIProvider.claudeP.id })! + 1)
        #endif
        #endif
        return list
    }()

    static let chatgptOAuth = APIProvider(
        id: "chatgpt-oauth",
        name: "GPT OAuth (账号登录)",
        group: .account,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.chatgptOAuth: "https://chatgpt.com/backend-api/codex"])],
        defaultProtocol: .chatgptOAuth,
        models: [
            // 兜底预设，登录后会从 /models 拉真列表覆盖
            ProviderModel(credentialId: "chatgpt-oauth", modelId: "gpt-5.2", name: "GPT-5.2"),
        ],
        login: .chatgptOAuth
    )

    static let anthropic = APIProvider(
        id: "anthropic",
        name: "Anthropic",
        group: .overseas,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.anthropic: "https://api.anthropic.com/v1"],
                               keysURL: URL(string: "https://platform.claude.com/settings/keys"))],
        defaultProtocol: .anthropic,
        extraHeaders: ["anthropic-version": "2023-06-01"],
        models: [
            ProviderModel(credentialId: "anthropic", modelId: "claude-opus-5-5", name: "Claude Opus 5.5"),
            ProviderModel(credentialId: "anthropic", modelId: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
            ProviderModel(credentialId: "anthropic", modelId: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
            ProviderModel(credentialId: "anthropic", modelId: "claude-fable-5-1", name: "Claude Fable 5.1"),
            ProviderModel(credentialId: "anthropic", modelId: "claude-opus-4-8", name: "Claude Opus 4.8"),
            ProviderModel(credentialId: "anthropic", modelId: "claude-sonnet-4-6", name: "Claude Sonnet 4.6"),
            ProviderModel(credentialId: "anthropic", modelId: "claude-opus-4-6", name: "Claude Opus 4.6"),
            ProviderModel(credentialId: "anthropic", modelId: "claude-haiku-4-5", name: "Claude Haiku 4.5"),
        ]
    )

    static let openai = APIProvider(
        id: "openai",
        name: "OpenAI",
        group: .overseas,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://api.openai.com/v1"],
                               keysURL: URL(string: "https://platform.openai.com/api-keys"))],
        defaultProtocol: .openaiCompatible,
        models: [
            ProviderModel(credentialId: "openai", modelId: "gpt-4o", name: "GPT-4o"),
            ProviderModel(credentialId: "openai", modelId: "gpt-4o-mini", name: "GPT-4o Mini"),
            ProviderModel(credentialId: "openai", modelId: "gpt-4.1", name: "GPT-4.1"),
            ProviderModel(credentialId: "openai", modelId: "gpt-4.1-mini", name: "GPT-4.1 Mini"),
            ProviderModel(credentialId: "openai", modelId: "gpt-4.1-nano", name: "GPT-4.1 Nano"),
            ProviderModel(credentialId: "openai", modelId: "o3", name: "o3"),
            ProviderModel(credentialId: "openai", modelId: "o3-mini", name: "o3 Mini"),
            ProviderModel(credentialId: "openai", modelId: "o4-mini", name: "o4 Mini"),
        ]
    )

    static let openrouter = APIProvider(
        id: "openrouter",
        name: "OpenRouter",
        group: .aggregator,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://openrouter.ai/api/v1"],
                               keysURL: URL(string: "https://openrouter.ai/keys"), catalogIds: ["openrouter"])],
        defaultProtocol: .openaiCompatible,
        extraHeaders: [
            "HTTP-Referer": "MemoryPalace/1.0",
            "X-Title": "MemoryPalace",
        ],
        models: [
            ProviderModel(credentialId: "openrouter", modelId: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
            ProviderModel(credentialId: "openrouter", modelId: "anthropic/claude-haiku-4", name: "Claude Haiku 4"),
            ProviderModel(credentialId: "openrouter", modelId: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5"),
            ProviderModel(credentialId: "openrouter", modelId: "openai/gpt-4o", name: "GPT-4o"),
            ProviderModel(credentialId: "openrouter", modelId: "openai/gpt-4o-mini", name: "GPT-4o Mini"),
            ProviderModel(credentialId: "openrouter", modelId: "openai/gpt-4.1", name: "GPT-4.1"),
            ProviderModel(credentialId: "openrouter", modelId: "google/gemini-2.5-pro-preview", name: "Gemini 2.5 Pro"),
            ProviderModel(credentialId: "openrouter", modelId: "google/gemini-2.5-flash-preview", name: "Gemini 2.5 Flash"),
            ProviderModel(credentialId: "openrouter", modelId: "deepseek/deepseek-chat", name: "DeepSeek V3"),
            ProviderModel(credentialId: "openrouter", modelId: "deepseek/deepseek-reasoner", name: "DeepSeek R1"),
            ProviderModel(credentialId: "openrouter", modelId: "x-ai/grok-3-mini", name: "Grok 3 Mini"),
        ],
        login: .openRouter
    )

    static let deepseek = APIProvider(
        id: "deepseek",
        name: "DeepSeek",
        group: .domestic,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://api.deepseek.com/v1"],
                               keysURL: URL(string: "https://platform.deepseek.com/api_keys"))],
        defaultProtocol: .openaiCompatible,
        models: [
            ProviderModel(credentialId: "deepseek", modelId: "deepseek-chat", name: "DeepSeek V3"),
            ProviderModel(credentialId: "deepseek", modelId: "deepseek-reasoner", name: "DeepSeek R1"),
        ]
    )

    static let groq = APIProvider(
        id: "groq",
        name: "Groq",
        group: .overseas,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://api.groq.com/openai/v1"],
                               keysURL: URL(string: "https://console.groq.com/keys"))],
        defaultProtocol: .openaiCompatible,
        models: [
            ProviderModel(credentialId: "groq", modelId: "llama-3.3-70b-versatile", name: "Llama 3.3 70B"),
            ProviderModel(credentialId: "groq", modelId: "llama-3.1-8b-instant", name: "Llama 3.1 8B"),
            ProviderModel(credentialId: "groq", modelId: "gemma2-9b-it", name: "Gemma 2 9B"),
            ProviderModel(credentialId: "groq", modelId: "mixtral-8x7b-32768", name: "Mixtral 8x7B"),
        ]
    )

    static let xai = APIProvider(
        id: "xai",
        name: "xAI",
        group: .overseas,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://api.x.ai/v1"],
                               keysURL: URL(string: "https://console.x.ai"))],
        defaultProtocol: .openaiCompatible,
        models: [
            ProviderModel(credentialId: "xai", modelId: "grok-3", name: "Grok 3"),
            ProviderModel(credentialId: "xai", modelId: "grok-3-mini", name: "Grok 3 Mini"),
        ]
    )

    static let siliconflow = APIProvider(
        id: "siliconflow", name: "SiliconFlow", group: .aggregator,
        regions: [
            PresetRegion(id: "cn", name: "国内", endpoints: [.openaiCompatible: "https://api.siliconflow.cn/v1"],
                         keysURL: URL(string: "https://cloud.siliconflow.cn/account/ak"), catalogIds: ["siliconflow"]),
            PresetRegion(id: "intl", name: "国际", endpoints: [.openaiCompatible: "https://api.siliconflow.com/v1"],
                         keysURL: URL(string: "https://cloud.siliconflow.com/account/ak"), catalogIds: ["siliconflow"]),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// 阿里的两种套餐 key 都是 sk-sp- 开头，只认自己的地址（按量 key 是 sk-）
    static let dashscope = APIProvider(
        id: "dashscope", name: "通义千问 (DashScope)", group: .domestic,
        regions: [
            PresetRegion(id: "cn-payg", name: "国内 · 按量",
                         endpoints: [.openaiCompatible: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                                     .anthropic: "https://dashscope.aliyuncs.com/apps/anthropic/v1"],
                         keysURL: URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key"), catalogIds: ["alibaba"]),
            PresetRegion(id: "intl-payg", name: "国际 · 按量",
                         endpoints: [.openaiCompatible: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                                     .anthropic: "https://dashscope-intl.aliyuncs.com/apps/anthropic/v1"],
                         keysURL: URL(string: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key"), catalogIds: ["alibaba"]),
            PresetRegion(id: "coding-cn", name: "Coding Plan · 国内",
                         endpoints: [.openaiCompatible: "https://coding.dashscope.aliyuncs.com/v1",
                                     .anthropic: "https://coding.dashscope.aliyuncs.com/apps/anthropic/v1"],
                         keysURL: URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key"),
                         keyHint: "sk-sp- 开头的套餐 key", isPlan: true,
                         terms: .codingToolsOnly("https://help.aliyun.com/zh/model-studio/coding-plan")),
            PresetRegion(id: "coding-intl", name: "Coding Plan · 国际",
                         endpoints: [.openaiCompatible: "https://coding-intl.dashscope.aliyuncs.com/v1",
                                     .anthropic: "https://coding-intl.dashscope.aliyuncs.com/apps/anthropic/v1"],
                         keysURL: URL(string: "https://modelstudio.console.alibabacloud.com/"),
                         keyHint: "sk-sp- 开头的套餐 key", isPlan: true,
                         terms: .codingToolsOnly("https://www.alibabacloud.com/help/en/model-studio/coding-plan")),
            PresetRegion(id: "token-cn", name: "Token Plan · 国内",
                         endpoints: [.openaiCompatible: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
                                     .anthropic: "https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic/v1"],
                         keysURL: URL(string: "https://bailian.console.aliyun.com/cn-beijing/subscription/token-plan/personal"),
                         keyHint: "sk-sp- 开头的套餐 key", isPlan: true),
            PresetRegion(id: "token-intl", name: "Token Plan · 国际",
                         endpoints: [.openaiCompatible: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
                                     .anthropic: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic/v1"],
                         keysURL: URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual"),
                         keyHint: "sk-sp- 开头的套餐 key", isPlan: true),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// Coding Plan 的 key 打按量地址会报没余额；两边的 Anthropic 地址是同一个，只认 key
    static let zhipu = APIProvider(
        id: "zhipu", name: "智谱 (GLM)", group: .domestic,
        regions: [
            PresetRegion(id: "payg", name: "按量",
                         endpoints: [.openaiCompatible: "https://open.bigmodel.cn/api/paas/v4",
                                     .anthropic: "https://open.bigmodel.cn/api/anthropic/v1"],
                         keysURL: URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"), catalogIds: ["zhipuai"]),
            PresetRegion(id: "coding", name: "Coding Plan",
                         endpoints: [.openaiCompatible: "https://open.bigmodel.cn/api/coding/paas/v4",
                                     .anthropic: "https://open.bigmodel.cn/api/anthropic/v1"],
                         keysURL: URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"), catalogIds: ["zhipuai"],
                         isPlan: true, terms: .codingToolsOnly("https://docs.bigmodel.cn/cn/coding-plan/overview")),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// 套餐是方舟的产品，不是豆包的：显示名叫「火山方舟（豆包）」（plan Q10），id 不变。
    /// 两种套餐各有自己的 key，额度只在自己的地址上扣；按量 /api/v3 另算钱
    static let doubao = APIProvider(
        id: "doubao", name: "火山方舟（豆包）", group: .domestic,
        regions: [
            PresetRegion(id: "payg", name: "按量", endpoints: [.openaiCompatible: "https://ark.cn-beijing.volces.com/api/v3"],
                         keysURL: URL(string: "https://ark.volcengine.com/region:cn-beijing/apikey")),
            PresetRegion(id: "coding", name: "Coding Plan",
                         endpoints: [.openaiCompatible: "https://ark.cn-beijing.volces.com/api/coding/v3",
                                     .anthropic: "https://ark.cn-beijing.volces.com/api/coding/v1"],
                         keysURL: URL(string: "https://ark.volcengine.com/region:cn-beijing/apikey"),
                         seedModelIds: arkPlanModels, isPlan: true,
                         terms: .codingToolsOnly("https://docs.volcengine.com/docs/82379/1925114")),
            PresetRegion(id: "agent", name: "Agent Plan",
                         endpoints: [.openaiCompatible: "https://ark.cn-beijing.volces.com/api/plan/v3",
                                     .anthropic: "https://ark.cn-beijing.volces.com/api/plan/v1"],
                         keysURL: URL(string: "https://ark.volcengine.com/region:cn-beijing/apikey"),
                         seedModelIds: arkPlanModels, isPlan: true),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// 方舟两种套餐的模型（magpie presets.go volcengine，照抄；ark-code-latest = 控制台里选的那个）
    private static let arkPlanModels = [
        "ark-code-latest", "doubao-seed-evolving", "doubao-seed-2.1-pro", "doubao-seed-2.1-lite", "doubao-seed-2.0-mini",
        "minimax-m3", "glm-5.3", "glm-5.3-flash", "deepseek-v4.1-flash", "deepseek-v4-flash", "deepseek-v4-pro",
        "kimi-k2.7-code", "kimi-k2.8-preview", "kimi-k3",
    ]

    static let gemini = APIProvider(
        id: "gemini", name: "Google Gemini", group: .overseas,
        regions: [PresetRegion(id: "default", name: "默认",
                               endpoints: [.openaiCompatible: "https://generativelanguage.googleapis.com/v1beta/openai"],
                               keysURL: URL(string: "https://aistudio.google.com/app/apikey"))],
        defaultProtocol: .openaiCompatible
    )

    static let moonshot = APIProvider(
        id: "moonshot", name: "Moonshot / Kimi", group: .domestic,
        regions: [
            PresetRegion(id: "cn", name: "国内",
                         endpoints: [.openaiCompatible: "https://api.moonshot.cn/v1", .anthropic: "https://api.moonshot.cn/anthropic/v1"],
                         keysURL: URL(string: "https://platform.moonshot.cn/console/api-keys"), catalogIds: ["moonshotai"]),
            PresetRegion(id: "intl", name: "国际",
                         endpoints: [.openaiCompatible: "https://api.moonshot.ai/v1", .anthropic: "https://api.moonshot.ai/anthropic/v1"],
                         keysURL: URL(string: "https://platform.moonshot.ai/console/api-keys"), catalogIds: ["moonshotai"]),
        ],
        defaultProtocol: .openaiCompatible
    )

    static let ollama = APIProvider(
        id: "ollama", name: "Ollama (本地)", group: .local,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "http://localhost:11434/v1"])],
        defaultProtocol: .openaiCompatible
    )

    /// 本机 claude-proxy（把 `claude -p` 包成 Anthropic 兼容端点，走订阅不烧 API 钱）。
    /// baseURL 空是**有意的**：地址由局域网发现填（每台 Mac 不一样），选中它时编辑器展开发现列表。
    /// 用户看到的就是一个叫 claude-p 的提供商，不需要理解 Bonjour/"发现"这些词。
    static let claudeP = APIProvider(
        id: "claude-p", name: "claude-p", group: .local,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.anthropic: ""])],
        defaultProtocol: .anthropic,
        extraHeaders: ["anthropic-version": "2023-06-01"],
        login: .discovery
    )

    #if PERSONAL_APPS
    #if DEBUG
    /// 本机 kimi-proxy（`~/Desktop/susu-project/kimi-proxy`，Kimi Code 订阅包成 Anthropic 兼容端点）。
    /// 地址是粟粟那台 Mac 的局域网 IP，只进 Debug 包。
    static let kimiP = APIProvider(
        id: "kimi-p", name: "kimi-p", group: .local,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.anthropic: "http://192.168.31.20:8793"])],
        defaultProtocol: .anthropic,
        extraHeaders: ["anthropic-version": "2023-06-01"],
        models: [
            ProviderModel(credentialId: "kimi-p", modelId: "k3", name: "Kimi K3"),
            ProviderModel(credentialId: "kimi-p", modelId: "k3-256k", name: "Kimi K3-256K"),
        ]
    )
    #endif
    #endif

    /// 本机模型：没有 key、没有网络；模型跟着 app 内置清单（AssistantLocalModel.catalog）
    static let localMLX = APIProvider(
        id: APICredential.localId, name: "本机模型", group: .local,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.localMLX: ""])],
        defaultProtocol: .localMLX,
        models: AssistantLocalModel.catalog.map { ProviderModel(credentialId: APICredential.localId, modelId: $0.id, name: $0.title) },
        login: .local
    )

    static let ccBridge = APIProvider(
        id: "cc-bridge", name: "Claude Code (本地)", group: .local,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.ccBridge: "ws://127.0.0.1:7890/cc"])],
        defaultProtocol: .ccBridge,
        models: [ProviderModel(credentialId: "cc-bridge", modelId: "cc-local", name: "Claude Code")],
        login: .bridge
    )

    /// Codex 与 Claude Code 平级的本地模型（07-20 粟粟拍）：同 ccBridge 通道（发送链零分叉），
    /// 靠 credential id "codex-bridge" 区分 engine——选它时 session picker 列 mp-codex-*。
    static let codexBridge = APIProvider(
        id: "codex-bridge", name: "Codex (本地)", group: .local,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.ccBridge: "ws://127.0.0.1:7890/cc"])],
        defaultProtocol: .ccBridge,
        models: [ProviderModel(credentialId: "codex-bridge", modelId: "codex-local", name: "Codex")],
        login: .bridge
    )
}

// MARK: - 阶段 3：国内套餐全套 + Kimi Code（plan-provider-presets §3.2）
// 端点照 magpie presets.go / omp 原文，Anthropic base 按 §2.4 补 /v1（不带 key 实测：带 /v1 回 401/400/422，不带回 404）。
// 套餐区域 isPlan：没指定格式时默认 Anthropic（Q3）。条款受限的套餐挂 terms（Q1 = A）；不加任何冒充客户端的请求头。

extension APIProvider {
    /// Kimi Code 会员：官方允许第三方工具用（只要求不伪造客户端标识），两种格式同一个 base
    static let kimiCode = APIProvider(
        id: "kimi-code", name: "Kimi Code 会员", group: .domestic,
        regions: [
            PresetRegion(id: "cn", name: "国内",
                         endpoints: [.openaiCompatible: "https://api.kimi.com/coding/v1", .anthropic: "https://api.kimi.com/coding/v1"],
                         keysURL: URL(string: "https://www.kimi.com/code/console"), catalogIds: ["kimi-code-plan-cn"], isPlan: true),
            PresetRegion(id: "global", name: "海外",
                         endpoints: [.openaiCompatible: "https://api.kimi.ai/coding/v1", .anthropic: "https://api.kimi.ai/coding/v1"],
                         keysURL: URL(string: "https://www.kimi.com/code/console"), catalogIds: ["kimi-code-plan-global"], isPlan: true),
        ],
        defaultProtocol: .anthropic
    )

    /// 阶跃 Step Plan：官方不限工具，走 step_plan 地址就扣套餐额度；按量另算
    static let stepfun = APIProvider(
        id: "stepfun", name: "阶跃星辰", group: .domestic,
        regions: [
            PresetRegion(id: "plan-cn", name: "Step Plan · 国内",
                         endpoints: [.openaiCompatible: "https://api.stepfun.com/step_plan/v1", .anthropic: "https://api.stepfun.com/step_plan/v1"],
                         keysURL: URL(string: "https://platform.stepfun.com/interface-key"), catalogIds: ["stepfun-step-plan"], isPlan: true),
            PresetRegion(id: "plan-intl", name: "Step Plan · 国际",
                         endpoints: [.openaiCompatible: "https://api.stepfun.ai/step_plan/v1", .anthropic: "https://api.stepfun.ai/step_plan/v1"],
                         keysURL: URL(string: "https://platform.stepfun.ai/interface-key"), catalogIds: ["stepfun-ai-step-plan"], isPlan: true),
            PresetRegion(id: "payg-cn", name: "按量 · 国内",
                         endpoints: [.openaiCompatible: "https://api.stepfun.com/v1", .anthropic: "https://api.stepfun.com/v1"],
                         keysURL: URL(string: "https://platform.stepfun.com/interface-key"), catalogIds: ["stepfun"]),
            PresetRegion(id: "payg-intl", name: "按量 · 国际",
                         endpoints: [.openaiCompatible: "https://api.stepfun.ai/v1", .anthropic: "https://api.stepfun.ai/v1"],
                         keysURL: URL(string: "https://platform.stepfun.ai/interface-key"), catalogIds: ["stepfun-ai"]),
        ],
        defaultProtocol: .openaiCompatible
    )

    static let zai = APIProvider(
        id: "zai", name: "Z.AI（智谱国际）", group: .overseas,
        regions: [
            PresetRegion(id: "payg", name: "按量",
                         endpoints: [.openaiCompatible: "https://api.z.ai/api/paas/v4", .anthropic: "https://api.z.ai/api/anthropic/v1"],
                         keysURL: URL(string: "https://z.ai/manage-apikey/apikey-list"), catalogIds: ["zhipuai"]),
            PresetRegion(id: "coding", name: "Coding Plan",
                         endpoints: [.openaiCompatible: "https://api.z.ai/api/coding/paas/v4", .anthropic: "https://api.z.ai/api/anthropic/v1"],
                         keysURL: URL(string: "https://z.ai/manage-apikey/apikey-list"), catalogIds: ["zhipuai"], isPlan: true),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// 按量 key 和 Token Plan 的 key 用同一组地址，只拆国内 / 国际（Q11）
    static let minimax = APIProvider(
        id: "minimax", name: "MiniMax", group: .domestic,
        regions: [
            PresetRegion(id: "cn", name: "国内",
                         endpoints: [.openaiCompatible: "https://api.minimaxi.com/v1", .anthropic: "https://api.minimaxi.com/anthropic/v1"],
                         keysURL: URL(string: "https://platform.minimax.cn/console/access?tab=api-keys"), catalogIds: ["minimax"],
                         keyHint: "按量 key 或 Token Plan 的 key 都填这里"),
            PresetRegion(id: "intl", name: "国际",
                         endpoints: [.openaiCompatible: "https://api.minimax.io/v1", .anthropic: "https://api.minimax.io/anthropic/v1"],
                         keysURL: URL(string: "https://platform.minimax.io/console/access"), catalogIds: ["minimax"],
                         keyHint: "按量 key 或 Token Plan 的 key 都填这里"),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// Token Plan 的 tp- key 只在自己那个地区的地址上扣额度；按量走 api.xiaomimimo.com
    static let xiaomi = APIProvider(
        id: "xiaomi", name: "小米 MiMo", group: .domestic,
        regions: [
            PresetRegion(id: "plan-cn", name: "Token Plan · 国内",
                         endpoints: [.openaiCompatible: "https://token-plan-cn.xiaomimimo.com/v1",
                                     .anthropic: "https://token-plan-cn.xiaomimimo.com/anthropic/v1"],
                         keysURL: URL(string: "https://platform.xiaomimimo.com/token-plan"), catalogIds: ["xiaomi-token-plan-cn"],
                         keyHint: "tp- 开头的 Token Plan key", isPlan: true),
            PresetRegion(id: "plan-sgp", name: "Token Plan · 新加坡",
                         endpoints: [.openaiCompatible: "https://token-plan-sgp.xiaomimimo.com/v1",
                                     .anthropic: "https://token-plan-sgp.xiaomimimo.com/anthropic/v1"],
                         keysURL: URL(string: "https://platform.xiaomimimo.com/token-plan"), catalogIds: ["xiaomi"],
                         keyHint: "tp- 开头的 Token Plan key", isPlan: true),
            PresetRegion(id: "plan-ams", name: "Token Plan · 欧洲",
                         endpoints: [.openaiCompatible: "https://token-plan-ams.xiaomimimo.com/v1",
                                     .anthropic: "https://token-plan-ams.xiaomimimo.com/anthropic/v1"],
                         keysURL: URL(string: "https://platform.xiaomimimo.com/token-plan"), catalogIds: ["xiaomi"],
                         keyHint: "tp- 开头的 Token Plan key", isPlan: true),
            PresetRegion(id: "payg", name: "按量",
                         endpoints: [.openaiCompatible: "https://api.xiaomimimo.com/v1", .anthropic: "https://api.xiaomimimo.com/anthropic/v1"],
                         keysURL: URL(string: "https://platform.xiaomimimo.com/#/console/api-keys"), catalogIds: ["xiaomi"]),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// 千帆：两种 Token Plan 不提供 /models（404），用种子；按量的 /v2/models 能拉
    static let qianfan = APIProvider(
        id: "qianfan", name: "百度千帆", group: .domestic,
        regions: [
            PresetRegion(id: "personal", name: "Token Plan · 个人",
                         endpoints: [.openaiCompatible: "https://qianfan.baidubce.com/v2/tokenplan/personal",
                                     .anthropic: "https://qianfan.baidubce.com/anthropic/tokenplan/personal/v1"],
                         keysURL: URL(string: "https://console.bce.baidu.com/qianfan/resource/token-plan"),
                         listsModels: false, seedModelIds: qianfanPersonalModels, isPlan: true,
                         terms: .codingToolsOnly("https://cloud.baidu.com/doc/qianfan/s/Dmrabu8b6")),
            PresetRegion(id: "team", name: "Token Plan · 企业",
                         endpoints: [.openaiCompatible: "https://qianfan.baidubce.com/v2/tokenplan/team",
                                     .anthropic: "https://qianfan.baidubce.com/anthropic/tokenplan/team/v1"],
                         keysURL: URL(string: "https://console.bce.baidu.com/qianfan/resource/token-plan"),
                         listsModels: false, seedModelIds: qianfanTeamModels, isPlan: true,
                         terms: .codingToolsOnly("https://cloud.baidu.com/doc/qianfan/s/Dmrabu8b6")),
            PresetRegion(id: "payg", name: "按量",
                         endpoints: [.openaiCompatible: "https://qianfan.baidubce.com/v2", .anthropic: "https://qianfan.baidubce.com/anthropic/v1"],
                         keysURL: URL(string: "https://console.bce.baidu.com/iam/#/iam/apikey/list")),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// 千帆两种套餐的模型（magpie presets.go baidu-qianfan 原文；deepseek-v4-flash、deepseek-v3.2、glm-5 只有企业版有）
    private static let qianfanTeamModels = [
        "qianfan-code-latest", "deepseek-v4.1-flash", "deepseek-v4-pro", "deepseek-v4-pro-0813",
        "deepseek-v4-flash", "deepseek-v4-flash-0731", "deepseek-v3.2", "glm-5.3", "glm-5.3-flash", "glm-5.2", "glm-5.1", "glm-5",
    ]
    private static let qianfanPersonalModels = qianfanTeamModels.filter { !["deepseek-v4-flash", "deepseek-v3.2", "glm-5"].contains($0) }

    /// 腾讯云：Token Plan（sk-tp- key，只有 /plan 下的地址，不提供 /models）+ TokenHub 按量（自己的 key，广州 / 新加坡）
    static let tencent = APIProvider(
        id: "tencent", name: "腾讯云", group: .domestic,
        regions: [
            PresetRegion(id: "plan", name: "Token Plan",
                         endpoints: [.openaiCompatible: "https://api.lkeap.cloud.tencent.com/plan/v3",
                                     .anthropic: "https://api.lkeap.cloud.tencent.com/plan/anthropic/v1"],
                         keysURL: URL(string: "https://console.cloud.tencent.com/tokenhub/tokenplan"),
                         listsModels: false,
                         seedModelIds: ["tc-code-latest", "glm-5.3", "glm-5.3-flash", "glm-5.2", "glm-5.1", "glm-5", "kimi-k3", "kimi-k2.7-code",
                                        "deepseek-v4-pro-202606", "deepseek-v4-flash-202605", "minimax-m3", "minimax-m2.7", "hy4-preview", "hy3"],
                         keyHint: "sk-tp- 开头的 Token Plan key", isPlan: true,
                         terms: .codingToolsOnly("https://cloud.tencent.com/document/product/1823/130060")),
            PresetRegion(id: "hub-cn", name: "TokenHub 按量 · 国内",
                         endpoints: [.openaiCompatible: "https://tokenhub.tencentmaas.com/v1", .anthropic: "https://tokenhub.tencentmaas.com/v1"],
                         keysURL: URL(string: "https://console.cloud.tencent.com/tokenhub/apikey"), catalogIds: ["tencent-tokenhub"]),
            PresetRegion(id: "hub-intl", name: "TokenHub 按量 · 国际",
                         endpoints: [.openaiCompatible: "https://tokenhub-intl.tencentmaas.com/v1", .anthropic: "https://tokenhub-intl.tencentmaas.com/v1"],
                         keysURL: URL(string: "https://console.tencentcloud.com/tokenhub/apikey"), catalogIds: ["tencent-tokenhub"]),
        ],
        defaultProtocol: .openaiCompatible
    )

    /// 华为云 MaaS：Token Plan 只在 /plan 下的地址扣额度、不提供 /models（只给个人、西南-贵阳一）；按量走 /openai/v1
    static let huawei = APIProvider(
        id: "huawei", name: "华为云 MaaS", group: .domestic,
        regions: [
            PresetRegion(id: "plan", name: "Token Plan",
                         endpoints: [.openaiCompatible: "https://api.modelarts-maas.com/plan/v2",
                                     .anthropic: "https://api.modelarts-maas.com/plan/anthropic/v1"],
                         keysURL: URL(string: "https://console.huaweicloud.com/modelarts/?#/model-studio/authmanage"),
                         listsModels: false, seedModelIds: ["glm-5.3", "glm-5.1", "kimi-k2.6", "deepseek-v4.1-flash", "deepseek-v4-flash"],
                         isPlan: true,
                         terms: .codingToolsOnly("https://support.huaweicloud.com/Token-plan-maas/tokenplan-maas-0001.html")),
            PresetRegion(id: "payg", name: "按量",
                         endpoints: [.openaiCompatible: "https://api.modelarts-maas.com/openai/v1",
                                     .anthropic: "https://api.modelarts-maas.com/anthropic/v1"],
                         keysURL: URL(string: "https://console.huaweicloud.com/modelarts/?#/model-studio/authmanage")),
        ],
        defaultProtocol: .openaiCompatible
    )
}

// MARK: - 阶段 4：聚合商（plan Q6）

extension APIProvider {
    static let together = APIProvider(
        id: "together", name: "Together AI", group: .aggregator,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://api.together.xyz/v1"],
                               keysURL: URL(string: "https://api.together.ai/settings/api-keys"), catalogIds: ["togetherai"])],
        defaultProtocol: .openaiCompatible
    )

    static let fireworks = APIProvider(
        id: "fireworks", name: "Fireworks", group: .aggregator,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://api.fireworks.ai/inference/v1"],
                               keysURL: URL(string: "https://app.fireworks.ai/settings/users/api-keys"), catalogIds: ["fireworks-ai"])],
        defaultProtocol: .openaiCompatible
    )

    static let nvidia = APIProvider(
        id: "nvidia", name: "NVIDIA NIM", group: .aggregator,
        regions: [PresetRegion(id: "default", name: "默认", endpoints: [.openaiCompatible: "https://integrate.api.nvidia.com/v1"],
                               keysURL: URL(string: "https://build.nvidia.com/settings/api-keys"), catalogIds: ["nvidia"])],
        defaultProtocol: .openaiCompatible
    )
}
