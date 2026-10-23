import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Provider Type

enum ProviderType: String, Codable {
    case openaiCompatible  // OpenAI / OpenRouter / DeepSeek / Groq / xAI / 任意中转站
    case anthropic         // Claude native Messages API
    case ccBridge          // 本地 Claude Code 通过 hub 桥接（WebSocket）
    case chatgptOAuth      // ChatGPT 账号 OAuth → Codex Responses API（走 ChatGPT 订阅 quota）
    case localMLX          // 本机模型（MLX，手机 / Mac 上直接跑；plan-小芽-v3 §1）
    /// 本版本不认识的类型（新版写的存档 / 导入的他人配置）。
    /// 关键：解码遇到未知 raw **不抛错**——原来会让整张凭据表解码失败回空数组，
    /// 用户看到的是「所有 API key 都不见了」（对比线洞 4，08-25 修）。
    /// 原始字符串存在 `APICredential.unknownTypeRaw` 里，编码时原样写回，降级再升级不丢数据。
    /// 绝不自动降级成 .openaiCompatible——那会往错误端点发请求带着用户的 key。
    case unsupported

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderType(rawValue: raw) ?? .unsupported
    }

    /// 能不能拿来发请求。`.unsupported` 只读展示，不参与任何网络路径。
    var isUsable: Bool { self != .unsupported }
}

// MARK: - Provider Model
//
// 注意：字段名 `credentialId` 是 M1 重构后的语义（卡片维度），但旧版 ProviderModel JSON
// 用 `providerId` 作为 key 存盘。Codable 这里同时认两个 key，迁移期间老存档仍能解析。
// 复合 id 形如 `<credentialId>/<modelId>`，由 selectedChatModel / favoriteModels /
// Conversation.selectedModelId 等多处消费。

struct ProviderModel: Identifiable, Hashable, Codable {
    var id: String { "\(credentialId)/\(modelId)" }
    let credentialId: String   // 由哪张 APICredential 卡拉到的（取代旧 providerId 语义）
    let modelId: String
    let name: String           // Friendly display name

    enum CodingKeys: String, CodingKey {
        case credentialId, providerId, modelId, name
    }

    init(credentialId: String, modelId: String, name: String) {
        self.credentialId = credentialId
        self.modelId = modelId
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let cid = try c.decodeIfPresent(String.self, forKey: .credentialId) {
            self.credentialId = cid
        } else {
            // 兼容老存档（providerId）
            self.credentialId = (try? c.decode(String.self, forKey: .providerId)) ?? ""
        }
        self.modelId = try c.decode(String.self, forKey: .modelId)
        self.name = try c.decode(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(credentialId, forKey: .credentialId)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(name, forKey: .name)
    }
}

// MARK: - API Credential (M1 重构核心实体)
//
// 一张"卡" = 一把 API key 的完整身份。粟粟的心智模型：
//   加 key → 命名昵称 → 选提供商（预设/自定义）→ 测试通过 → 保存
//   外面只显示「emoji + 昵称 + sk前4后4」，详情页才能改 key/提供商。
//
// 字段命名沿用 APIProvider 旧字段以减少后台 call site 改动（baseURL/extraHeaders/models/type 等）。
// ratios 字段是 BudgetCalculator 历史遗留乘法（实际用户改不了、永远 1.0），保留兼容 BudgetCalculator 签名。

struct APICredential: Identifiable, Codable {
    let id: String                          // "cred-" + UUID（也是 Keychain account 和复合 id 前缀）
    var name: String                        // 昵称（列表主标题；沿用 .name 字段名以让 call site 不动）
    var emoji: String                       // 必填、全局唯一、列表/池子前缀
    var presetId: String?                   // 选了哪个内置预设（"openrouter"…）；自定义=nil
    var type: ProviderType                  // 沿用 APIProvider 字段名
    var baseURL: String
    var extraHeaders: [String: String]
    var models: [ProviderModel]             // 该卡拉到/手填的模型
    var createdAt: Date
    var lastUsedAt: Date?
    var lastUsedModelId: String?
    /// 工具调用通道：nil/true = 正常下发 tools；false = 这张卡的后端不带 function calling（剥 tools 的中转、
    /// 文本模式代理等），发请求不带 tools 也不在 system 里提工具——否则模型会对着空气用文本假装调用
    /// （2026-08-25 claude-proxy 首验实锤）。Optional 是为了老存档解码不炸（对比线洞 4）。
    var toolsSupported: Bool?
    /// `type == .unsupported` 时保存原始 type 字符串，编码时原样写回（降级→升级不丢数据）。
    var unknownTypeRaw: String?

    init(
        id: String,
        name: String,
        emoji: String,
        presetId: String? = nil,
        type: ProviderType,
        baseURL: String,
        extraHeaders: [String: String] = [:],
        models: [ProviderModel] = [],
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        lastUsedModelId: String? = nil,
        toolsSupported: Bool? = nil,
        unknownTypeRaw: String? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.presetId = presetId
        self.type = type
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.models = models
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastUsedModelId = lastUsedModelId
        self.toolsSupported = toolsSupported
        self.unknownTypeRaw = unknownTypeRaw
    }

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, presetId, type, baseURL, extraHeaders, models
        case createdAt, lastUsedAt, lastUsedModelId, toolsSupported, unknownTypeRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🔑"
        self.presetId = try c.decodeIfPresent(String.self, forKey: .presetId)
        self.type = try c.decode(ProviderType.self, forKey: .type)
        // 未知类型：把原始字符串抓下来，encode 时原样写回（本版本认识的类型不需要这个字段）
        if self.type == .unsupported {
            self.unknownTypeRaw = (try? c.decode(String.self, forKey: .type))
                ?? (try? c.decodeIfPresent(String.self, forKey: .unknownTypeRaw)) ?? nil
        } else {
            self.unknownTypeRaw = try c.decodeIfPresent(String.self, forKey: .unknownTypeRaw)
        }
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.extraHeaders = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
        self.models = try c.decodeIfPresent([ProviderModel].self, forKey: .models) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.lastUsedModelId = try c.decodeIfPresent(String.self, forKey: .lastUsedModelId)
        self.toolsSupported = try c.decodeIfPresent(Bool.self, forKey: .toolsSupported)
        // 老存档可能带 modelRatio/completionRatio/groupRatio/currencyRate —— 静默忽略
    }

    /// 自定义 encode 只为一件事：`.unsupported` 的卡把原始 type 字符串写回去，
    /// 不把用户在新版里建的卡在旧版存盘时改写成 "unsupported"（那是不可逆的数据损坏）。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(emoji, forKey: .emoji)
        try c.encodeIfPresent(presetId, forKey: .presetId)
        try c.encode(type == .unsupported ? (unknownTypeRaw ?? type.rawValue) : type.rawValue, forKey: .type)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(extraHeaders, forKey: .extraHeaders)
        try c.encode(models, forKey: .models)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try c.encodeIfPresent(lastUsedModelId, forKey: .lastUsedModelId)
        try c.encodeIfPresent(toolsSupported, forKey: .toolsSupported)
        try c.encodeIfPresent(unknownTypeRaw, forKey: .unknownTypeRaw)
    }
}

// MARK: - API Provider (降级：只读预设目录)
//
// M1 之前 APIProvider 既是预设又是列表实体；现在只是「新建卡」时给详情页带出 type/baseURL/extraHeaders/预填模型 的模板。
// 不再持久化、不进列表、不与 Keychain 关联。

struct APIProvider: Identifiable {
    let id: String                          // 预设 id，如 "openrouter"
    var name: String
    var type: ProviderType
    var baseURL: String
    var extraHeaders: [String: String]
    var models: [ProviderModel]             // 模板里预填的模型（构造 credential 时复制一份过去）
}

extension APIProvider {
    /// 内置预设目录。M2 详情页的"选提供商"下拉就读它。
    static let presets: [APIProvider] = {
        var list: [APIProvider] = [
            .chatgptOAuth, .anthropic, .openai, .openrouter, .deepseek, .groq, .xai,
            .siliconflow, .dashscope, .zhipu, .doubao, .gemini, .moonshot, .ollama, .claudeP, .ccBridge, .codexBridge,
        ]
        // 本机模型（plan-小芽-v3 §1）：放在 Ollama 后面；模拟器跑不了 MLX，不列
        if LocalLLMService.isSupported {
            list.insert(.localMLX, at: list.firstIndex(where: { $0.id == APIProvider.ollama.id })! + 1)
        }
        return list
    }()

    static let chatgptOAuth = APIProvider(
        id: "chatgpt-oauth",
        name: "GPT OAuth (账号登录)",
        type: .chatgptOAuth,
        baseURL: "https://chatgpt.com/backend-api/codex",
        extraHeaders: [:],
        models: [
            // 兜底预设，登录后会从 /models 拉真列表覆盖
            ProviderModel(credentialId: "chatgpt-oauth", modelId: "gpt-5.2", name: "GPT-5.2"),
        ]
    )

    static let anthropic = APIProvider(
        id: "anthropic",
        name: "Anthropic",
        type: .anthropic,
        baseURL: "https://api.anthropic.com/v1",
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
        type: .openaiCompatible,
        baseURL: "https://api.openai.com/v1",
        extraHeaders: [:],
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
        type: .openaiCompatible,
        baseURL: "https://openrouter.ai/api/v1",
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
        ]
    )

    static let deepseek = APIProvider(
        id: "deepseek",
        name: "DeepSeek",
        type: .openaiCompatible,
        baseURL: "https://api.deepseek.com/v1",
        extraHeaders: [:],
        models: [
            ProviderModel(credentialId: "deepseek", modelId: "deepseek-chat", name: "DeepSeek V3"),
            ProviderModel(credentialId: "deepseek", modelId: "deepseek-reasoner", name: "DeepSeek R1"),
        ]
    )

    static let groq = APIProvider(
        id: "groq",
        name: "Groq",
        type: .openaiCompatible,
        baseURL: "https://api.groq.com/openai/v1",
        extraHeaders: [:],
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
        type: .openaiCompatible,
        baseURL: "https://api.x.ai/v1",
        extraHeaders: [:],
        models: [
            ProviderModel(credentialId: "xai", modelId: "grok-3", name: "Grok 3"),
            ProviderModel(credentialId: "xai", modelId: "grok-3-mini", name: "Grok 3 Mini"),
        ]
    )

    static let siliconflow = APIProvider(
        id: "siliconflow", name: "SiliconFlow",
        type: .openaiCompatible, baseURL: "https://api.siliconflow.cn/v1",
        extraHeaders: [:], models: []
    )

    static let dashscope = APIProvider(
        id: "dashscope", name: "通义千问 (DashScope)",
        type: .openaiCompatible, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        extraHeaders: [:], models: []
    )

    static let zhipu = APIProvider(
        id: "zhipu", name: "智谱 (GLM)",
        type: .openaiCompatible, baseURL: "https://open.bigmodel.cn/api/paas/v4",
        extraHeaders: [:], models: []
    )

    static let doubao = APIProvider(
        id: "doubao", name: "豆包 (Volcengine)",
        type: .openaiCompatible, baseURL: "https://ark.cn-beijing.volces.com/api/v3",
        extraHeaders: [:], models: []
    )

    static let gemini = APIProvider(
        id: "gemini", name: "Google Gemini",
        type: .openaiCompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        extraHeaders: [:], models: []
    )

    static let moonshot = APIProvider(
        id: "moonshot", name: "Moonshot / Kimi",
        type: .openaiCompatible, baseURL: "https://api.moonshot.cn/v1",
        extraHeaders: [:], models: []
    )

    static let ollama = APIProvider(
        id: "ollama", name: "Ollama (本地)",
        type: .openaiCompatible, baseURL: "http://localhost:11434/v1",
        extraHeaders: [:], models: []
    )

    /// 本机 claude-proxy（把 `claude -p` 包成 Anthropic 兼容端点，走订阅不烧 API 钱）。
    /// baseURL 空是**有意的**：地址由局域网发现填（每台 Mac 不一样），选中它时编辑器展开发现列表。
    /// 用户看到的就是一个叫 claude-p 的提供商，不需要理解 Bonjour/"发现"这些词。
    static let claudeP = APIProvider(
        id: "claude-p", name: "claude-p",
        type: .anthropic, baseURL: "",
        extraHeaders: ["anthropic-version": "2023-06-01"], models: []
    )


    /// 本机模型：没有 key、没有网络；模型跟着 app 内置清单（AssistantLocalModel.catalog）
    static let localMLX = APIProvider(
        id: APICredential.localId, name: "本机模型",
        type: .localMLX, baseURL: "",
        extraHeaders: [:],
        models: AssistantLocalModel.catalog.map { ProviderModel(credentialId: APICredential.localId, modelId: $0.id, name: $0.title) }
    )

    static let ccBridge = APIProvider(
        id: "cc-bridge", name: "Claude Code (本地)",
        type: .ccBridge, baseURL: "ws://127.0.0.1:7890/cc",
        extraHeaders: [:],
        models: [ProviderModel(credentialId: "cc-bridge", modelId: "cc-local", name: "Claude Code")]
    )

    /// Codex 与 Claude Code 平级的本地模型（07-20 粟粟拍）：同 ccBridge 通道（发送链零分叉），
    /// 靠 credential id "codex-bridge" 区分 engine——选它时 session picker 列 mp-codex-*。
    static let codexBridge = APIProvider(
        id: "codex-bridge", name: "Codex (本地)",
        type: .ccBridge, baseURL: "ws://127.0.0.1:7890/cc",
        extraHeaders: [:],
        models: [ProviderModel(credentialId: "codex-bridge", modelId: "codex-local", name: "Codex")]
    )
}

extension APICredential {
    /// 示例卡（粟粟 09-05）：新装机默认收藏 Claude Code / Codex 之外再给一张「示例 API」占个位。
    static let exampleId = "example-api"
    /// 本机模型卡（plan-小芽-v3 §1）：固定 id，模型 id = AssistantLocalModel.id
    static let localId = "local-mlx"
    /// 删卡确认文案（列表左滑 / mac 右键 / 详情页三处同一句）
    static let deleteWarning = "这张卡的 key 会一起从钥匙串删掉，删了找不回来。用它的模型的对话会改用别的模型。"
    static let exampleModelId = "example-model"
}

// MARK: - Emoji Pool（D4：默认派发池 + 唯一性校验）

enum CredentialEmoji {
    /// 默认池 —— 新建卡时从池里挑一个未占用的。粟粟可在详情页改。
    static let pool: [String] = [
        "🦊", "🐼", "🐨", "🦁", "🐯", "🦄", "🐙", "🦜", "🦋", "🐝",
        "🌸", "🌻", "🌈", "⭐️", "🍀", "🍑", "🍋", "🍓", "🌙", "☀️",
        "💎", "🔮", "🎀", "🎈", "🎨", "📚", "🍵", "☕️", "🧸", "🔥",
    ]

    /// 在已用集合里挑第一个未占用 emoji。池子用光了 → fallback 编号 emoji（不太美但能跑）。
    static func allocate(excluding used: Set<String>) -> String {
        if let pick = pool.first(where: { !used.contains($0) }) { return pick }
        return "🔑"  // 兜底，详情页强制改
    }
}

// MARK: - Provider Manager (M1 重构主控)

private let credentialsKey = "credentials"              // 新存档 key
private let legacyCustomProvidersKey = "customProviders"  // 老 API 自定义 provider 存档（迁移源）
private let legacyExtraModelsKey = "customModels"       // 老 API 内置 provider 的额外模型（迁移源）
private let cloudSyncKey = "apiKeyCloudSync"
private let favoriteModelsKey = "favoriteModels"
private let legacyApiKeyPrefix = "apikey-"              // 远古 UserDefaults 明文 key 前缀（早就 deprecated）
private let credentialMigrationV1DoneKey = "credentialMigrationV1Done"
private let keychainLegacyCleanupV1DoneKey = "keychainLegacyCleanupV1Done"
private let ccBridgeIdFixupV2DoneKey = "ccBridgeIdFixupV2Done"
private let localEngineAutoFavoritedKey = "localEngineAutoFavoritedIds"   // 已做过"首次默认收藏"的模型（让取消是永久的）
private let exampleCardSeededKey = "exampleCardSeededV1"                   // 示例卡只在新装机播一次（删了就删了）
private let baseURLNormalizeV1DoneKey = "credentialURLNormalizeV1Done"
private let chatgptOAuthCardSeededKey = "chatgptOAuthCardSeededV1"           // GPT OAuth 卡只播一次（删了就删了）
private let credentialsURLBackupKey = "credentialsBackupPreURLNormalize"   // 规整前的整张原表（撤回用）

@Observable
final class ProviderManager {
    /// M1 重构后唯一的列表实体：用户加的每张 key 卡。
    private(set) var credentials: [APICredential] = []
    private(set) var favoriteModelIds: [String] = []

    /// providerId → apiKey 内存缓存（key 是 Keychain account；M1 后 = credentialId）。
    /// 启动一次性批量读，避免重复 Keychain 弹窗。
    @ObservationIgnored
    private var apiKeyCache: [String: String] = [:]

    @ObservationIgnored
    private var apiKeyCacheLoaded = false

    init() {
        migrateLegacyKeysIfNeeded()
        warmUpApiKeyCache()
        let isFreshInstall = !UserDefaults.standard.bool(forKey: credentialMigrationV1DoneKey)
        migrateToCredentialsV1IfNeeded()  // M1 一次性迁移
        fixupCCBridgeIdV2IfNeeded()  // F1 修 ccBridge 卡 id 回 "cc-bridge"（V1 误用 cred-UUID）
        normalizeStoredBaseURLsV1IfNeeded()  // #092 A：老卡地址规整一次（先备份原表）
        // 收藏存档必须在 ensure* 之前读进来：ensureDefaultFavorites 往 favoriteModelIds 追加后整表存回，
        // 以前这行排在后面，追加时列表还是空的 → 用户的收藏被整表覆盖（粟粟 09-05「收藏的模型下次 build 就消失」）。
        favoriteModelIds = loadFavoriteModelIds()
        ensureChatGPTOAuthCard()  // G-F1 GPT OAuth 卡自动加入 API 列表（未授权时显示）
        ensureCodexBridgeCard()   // 配了 CC 桥的用户自动配平 Codex 卡（同通道平级模型）
        removeAutoLocalCard()
        if isFreshInstall { ensureExampleCard() }
        reload()
        ensureDefaultFavorites()  // 要在 reload 之后：只收藏卡上真的有的模型
        cleanupLegacyKeychainAccountsIfNeeded()  // D2 清理旧 preset id account（要等 credentials 加载完）

        // 监听 settings config 导入完成 → 重新 load credentials + favorites
        NotificationCenter.default.addObserver(
            forName: .settingsConfigDidImport, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
            self?.favoriteModelIds = self?.loadFavoriteModelIds() ?? []
            self?.apiKeyCacheLoaded = false  // 加密导入可能写回了 key，下次读时重拉 Keychain
        }
        #if os(iOS)
        // #042：锁屏冷启动（VoIP 拉起）时整批读空，解锁后下次读时重拉，否则这个进程活着期间 key 都像没填
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.apiKeyCacheLoaded = false
        }
        #endif
    }

    // MARK: - G-F1: GPT OAuth 卡自动加入 API 列表
    //
    // 粟粟要求：只要用户安装/启动 app，API 列表就显示一张 "GPT OAuth (账号登录)" 卡（未授权状态），
    // 不需要手动 + 新建。token 没登录时 keyLabel 显示"未登录 ChatGPT"，点进卡详情登录。
    //
    // 跟 ccBridge 一样固定 id "chatgpt-oauth"，避免 token 落 "chatgpt-oauth" account 而卡 id 是
    // cred-UUID 对不上的坑。

    private func ensureCodexBridgeCard() {
        var list = loadCredentials()
        // V1 迁移曾把 Codex 预设也建成 id "cc-bridge"（新装机 API 列表两张「Codex (本地)」，NOW 09-02 记过）——
        // 撞 id 的那张删掉，真正的 codex-bridge 卡下面补。
        let before = list.count
        list.removeAll { $0.id == APIProvider.ccBridge.id && $0.presetId == APIProvider.codexBridge.id }
        var changed = list.count != before
        if list.contains(where: { $0.type == .ccBridge && $0.id != "codex-bridge" }),
           !list.contains(where: { $0.id == "codex-bridge" }) {
            let preset = APIProvider.codexBridge
            list.append(APICredential(
                id: preset.id, name: preset.name, emoji: "🌰",
                presetId: preset.id, type: preset.type,
                baseURL: preset.baseURL, extraHeaders: preset.extraHeaders,
                models: preset.models.map {
                    ProviderModel(credentialId: preset.id, modelId: $0.modelId, name: $0.name)
                }
            ))
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: credentialsKey)
        }
    }

    /// #092 A（粟粟 10-14 拍 K1）：老卡的地址按 BaseURLNormalizer 规整一次，聊天才和测试打同一个 URL。
    /// 只动 baseURL（key 在钥匙串里不碰）；改之前整张原表存进 credentialsBackupPreURLNormalize，改了哪几张记面包屑。
    private func normalizeStoredBaseURLsV1IfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: baseURLNormalizeV1DoneKey) else { return }
        defaults.set(true, forKey: baseURLNormalizeV1DoneKey)
        guard let raw = defaults.data(forKey: credentialsKey) else { return }
        var list = loadCredentials()
        var notes: [String] = []
        for i in list.indices {
            let fixed = BaseURLNormalizer.normalize(list[i].baseURL, type: list[i].type)
            guard fixed != list[i].baseURL else { continue }
            notes.append("\(list[i].emoji)\(list[i].name)：\(list[i].baseURL) → \(fixed)")
            list[i].baseURL = fixed
        }
        guard !notes.isEmpty, let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(raw, forKey: credentialsURLBackupKey)
        defaults.set(data, forKey: credentialsKey)
        BreadcrumbLog.shared.add("🔧", "API 卡地址规整 \(notes.count) 张（原表已备份）：" + notes.joined(separator: "；"))
    }

    /// v3 P2 第一版自动建过一张「本机模型」卡（presetId 为空）；粟粟 09-26：要自己在「新建 API → 提供商」里选。
    /// 自己建的那张 presetId = local-mlx，不会被误删
    private func removeAutoLocalCard() {
        var list = loadCredentials()
        let before = list.count
        list.removeAll { $0.id == APICredential.localId && $0.presetId == nil }
        guard list.count != before, let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: credentialsKey)
    }

    /// 示例卡（粟粟 09-05）：新装机除了 Claude Code / Codex，再给一张「示例 API」占个位——选择器里有个
    /// 「你自己的 API 会出现在这」的样子。没 key、baseURL 是占位；用户去 设置 → API 改成自己的或删掉。
    /// 只播一次（seeded 标记），删了不会再冒回来。
    private func ensureExampleCard() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: exampleCardSeededKey) { return }
        defaults.set(true, forKey: exampleCardSeededKey)
        var list = loadCredentials()
        guard !list.contains(where: { $0.id == APICredential.exampleId }) else { return }
        list.append(APICredential(
            id: APICredential.exampleId, name: "示例 API",
            emoji: CredentialEmoji.allocate(excluding: Set(list.map(\.emoji))),
            type: .openaiCompatible, baseURL: "https://api.example.com/v1",
            models: [ProviderModel(credentialId: APICredential.exampleId,
                                   modelId: APICredential.exampleModelId, name: "示例模型")]
        ))
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: credentialsKey)
        }
    }

    /// 默认收藏（粟粟 09-05 拍：Claude Code、Codex、示例卡，别的都不收藏）：page1 模型选择器只列收藏——
    /// 不收藏=选择器里永远看不见，每次想用还得先去 API 页点星星。
    ///
    /// **每个模型只在第一次见到时收藏一次**，之后记进"已处理"表。旧实现无条件 append，
    /// 用户点掉星星下次启动又冒回来，等于取消不掉；现在点掉就是点掉了。
    /// 要在 reload() 之后跑：只收藏卡上真的有的模型。
    private func ensureDefaultFavorites() {
        var handled = Set(UserDefaults.standard.stringArray(forKey: localEngineAutoFavoritedKey) ?? [])
        var addedAny = false
        let defaults = [APIProvider.ccBridge.models[0].id, APIProvider.codexBridge.models[0].id,
                        "\(APICredential.exampleId)/\(APICredential.exampleModelId)"]
        for modelId in defaults where model(byId: modelId) != nil {
            guard !handled.contains(modelId) else { continue }   // 处理过 → 尊重用户当前选择
            if !favoriteModelIds.contains(modelId) {
                favoriteModelIds.append(modelId)
                addedAny = true
            }
            handled.insert(modelId)
        }
        if addedAny { saveFavoriteModelIds(favoriteModelIds) }
        UserDefaults.standard.set(Array(handled).sorted(), forKey: localEngineAutoFavoritedKey)
    }

    private func ensureChatGPTOAuthCard() {
        // 只播一次（#092）：以前每次启动「没有就建」，用户删了下次又冒出来
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: chatgptOAuthCardSeededKey) { return }
        defaults.set(true, forKey: chatgptOAuthCardSeededKey)
        var list = loadCredentials()
        // 已有 chatgptOAuth 卡（任意 id）→ 不重复建
        if list.contains(where: { $0.type == .chatgptOAuth }) { return }
        // 用 preset 当模板（含兜底 gpt-5.2 模型）
        let preset = APIProvider.chatgptOAuth
        let emoji = "🤖"
        let card = APICredential(
            id: preset.id,  // 固定 "chatgpt-oauth"
            name: preset.name,
            emoji: emoji,
            presetId: preset.id,
            type: preset.type,
            baseURL: preset.baseURL,
            extraHeaders: preset.extraHeaders,
            models: preset.models.map {
                ProviderModel(credentialId: preset.id, modelId: $0.modelId, name: $0.name)
            }
        )
        list.append(card)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: credentialsKey)
        }
    }

    /// 一次性批量读 Keychain，填充 apiKeyCache。只触发一次 Keychain 授权弹窗。
    private func warmUpApiKeyCache() {
        apiKeyCache = KeychainStore.getAll()
        apiKeyCacheLoaded = true
    }

    /// 从存档加载 credentials；不再合并 builtIn / extraModels（迁移完一次性合并完了）。
    func reload() {
        var list = loadCredentials()
        // 设置导入进来的卡也走同一套地址规整（启动时的老卡已由 normalizeStoredBaseURLsV1IfNeeded 落盘过）
        for i in list.indices {
            list[i].baseURL = BaseURLNormalizer.normalize(list[i].baseURL, type: list[i].type)
        }

        // ccBridge 卡的 baseURL override（手动 LAN 配置）。
        let ccOverride = UserDefaults.standard.string(forKey: "ccBridgeBaseURLOverride") ?? ""
        if !ccOverride.isEmpty, let idx = list.firstIndex(where: { $0.type == .ccBridge }) {
            list[idx].baseURL = ccOverride
        }

        credentials = list
    }

    // MARK: - 兼容旧 API 入口（外部仍能读到「卡列表」）

    /// 历史 call site 用 `pm.providers` —— 现在等于 credentials（语义已变成卡列表）。
    /// 暴露 APICredential 数组而不是 APIProvider 数组，类型从 [APIProvider] → [APICredential]。
    var providers: [APICredential] { credentials }

    // MARK: - API Key (Keychain-backed)

    var cloudSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: cloudSyncKey)
    }

    /// 取某张卡的 key（也接受旧 providerId 兜底，主要给迁移/旧 call site 用）。
    func apiKey(for credentialId: String) -> String? {
        if !apiKeyCacheLoaded { warmUpApiKeyCache() }
        guard let key = apiKeyCache[credentialId], !key.isEmpty else { return nil }
        return key
    }

    func setApiKey(_ key: String, for credentialId: String) {
        if !apiKeyCacheLoaded { warmUpApiKeyCache() }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apiKeyCache.removeValue(forKey: credentialId)
            KeychainStore.remove(account: credentialId)
        } else {
            apiKeyCache[credentialId] = trimmed
            _ = KeychainStore.set(trimmed, account: credentialId, sync: cloudSyncEnabled)
        }
    }

    func hasKey(for credentialId: String) -> Bool {
        if !apiKeyCacheLoaded { warmUpApiKeyCache() }
        guard let key = apiKeyCache[credentialId] else { return false }
        return !key.isEmpty
    }

    /// 切换 iCloud 同步开关后把所有已有 key 按新状态重写一遍。
    /// 返回失败的 account 列表（为空表示全部成功）。
    @discardableResult
    func reencryptAllKeys(sync: Bool) -> [String] {
        UserDefaults.standard.set(sync, forKey: cloudSyncKey)
        var failures: [String] = []
        let all = KeychainStore.getAll()
        for (account, value) in all {
            if !KeychainStore.set(value, account: account, sync: sync) {
                failures.append(account)
            } else {
                apiKeyCache[account] = value
            }
        }
        return failures
    }

    /// 一次性把 UserDefaults 里的 `apikey-*` 搬到 Keychain，搬完清掉明文。
    /// 这是更古老的迁移（UserDefaults 明文 → Keychain），与 M1 credential 迁移不冲突。
    private func migrateLegacyKeysIfNeeded() {
        let defaults = UserDefaults.standard
        let dict = defaults.dictionaryRepresentation()
        let sync = defaults.bool(forKey: cloudSyncKey)
        for (key, value) in dict where key.hasPrefix(legacyApiKeyPrefix) {
            guard let stringValue = value as? String, !stringValue.isEmpty else {
                defaults.removeObject(forKey: key)
                continue
            }
            let providerId = String(key.dropFirst(legacyApiKeyPrefix.count))
            guard !providerId.isEmpty else {
                defaults.removeObject(forKey: key)
                continue
            }
            if KeychainStore.set(stringValue, account: providerId, sync: sync) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Queries

    /// 有 key 的卡（ccBridge 无需 key 也算）。给后台 fallback 模型查找 / picker 用。
    var enabledCredentials: [APICredential] {
        credentials.filter { c in
            if c.type == .ccBridge { return true }
            if c.type == .localMLX { return c.models.contains { AssistantModelStore.installedDirectory(modelId: $0.modelId) != nil } }
            return hasKey(for: c.id)
        }
    }

    /// 旧 API 名沿用 —— 让 call site 不动；语义等价 enabledCredentials。
    var enabledProviders: [APICredential] { enabledCredentials }

    var availableModels: [ProviderModel] {
        enabledCredentials.flatMap(\.models)
    }

    /// #092 D：这张卡现在发得出请求吗（选择器、兜底、新卡要不要接管主模型共用）。
    /// 比 enabledCredentials 严：示例卡不算；iOS 上没扫码配过对的桥卡不算（只剩回环地址＝手机自己）。
    func isUsable(_ c: APICredential) -> Bool {
        Self.isUsable(type: c.type, isExample: c.id == APICredential.exampleId, hasKey: hasKey(for: c.id),
                      hasInstalledLocalModel: c.type == .localMLX
                          && c.models.contains { AssistantModelStore.installedDirectory(modelId: $0.modelId) != nil },
                      bridgeReachable: Self.bridgeReachable)
    }

    static func isUsable(type: ProviderType, isExample: Bool, hasKey: Bool,
                         hasInstalledLocalModel: Bool, bridgeReachable: Bool) -> Bool {
        if isExample { return false }
        switch type {
        case .ccBridge: return bridgeReachable
        case .localMLX: return hasInstalledLocalModel
        case .unsupported: return false
        case .openaiCompatible, .anthropic, .chatgptOAuth: return hasKey
        }
    }

    /// mac 上回环地址就是本机 hub；iOS 上得扫码配过对（配了主 / 备 / 中继任一个）
    private static var bridgeReachable: Bool {
        #if os(macOS)
        return true
        #else
        return !CCBridgeEndpoints.configuredURLs(fallbackToLocal: false).isEmpty
        #endif
    }

    func isModelUsable(id combinedId: String) -> Bool {
        guard let m = model(byId: combinedId), let c = credential(for: m) else { return false }
        return isUsable(c)
    }

    /// 新卡保存后挑哪个模型收藏 / 接管主模型：预设推荐的第一个（拉到的清单里还有它）优先，否则第一个聊天模型
    static func autoPickModel(_ models: [ProviderModel], presetFirst: String?) -> ProviderModel? {
        if let p = presetFirst, let m = models.first(where: { $0.modelId == p }) { return m }
        return models.first(where: { !ProviderProbe.isNonChatModel($0.modelId) }) ?? models.first
    }

    /// 新卡落盘后：收藏挑中的模型；当前主模型（🌞）空着或不能用时才把它设成主模型（粟粟 10-14 拍 K3）
    func adoptNewModel(_ model: ProviderModel) {
        if !isFavoriteModel(id: model.id) { toggleFavoriteModel(id: model.id) }
        let current = UserDefaults.standard.string(forKey: "selectedChatModel") ?? ""
        if current.isEmpty || !isModelUsable(id: current) {
            UserDefaults.standard.set(model.id, forKey: "selectedChatModel")
        }
    }

    /// 卡上删掉的模型：收藏、🌞 主模型、🌛 记忆模型里指向它们的一并清掉
    func forgetModels(_ combinedIds: Set<String>) {
        guard !combinedIds.isEmpty else { return }
        let kept = favoriteModelIds.filter { !combinedIds.contains($0) }
        if kept.count != favoriteModelIds.count {
            favoriteModelIds = kept
            saveFavoriteModelIds(kept)
        }
        for key in ["selectedChatModel", "memoryExtractModelId"]
        where combinedIds.contains(UserDefaults.standard.string(forKey: key) ?? "") {
            UserDefaults.standard.set("", forKey: key)
        }
    }

    /// 给定模型反查它属于哪张卡。
    func provider(for model: ProviderModel) -> APICredential? {
        credentials.first(where: { $0.id == model.credentialId })
    }

    /// 同名变体（语义更清晰）。
    func credential(for model: ProviderModel) -> APICredential? {
        provider(for: model)
    }

    func model(byId combinedId: String) -> ProviderModel? {
        for c in credentials {
            if let m = c.models.first(where: { $0.id == combinedId }) {
                return m
            }
        }
        return nil
    }

    /// 三级解析：对话级 → 全局兜底 → 第一个可用 → 硬兜底。
    func resolveModel(conversationModelId: String?, globalFallbackId: String?) -> ProviderModel {
        if let cid = conversationModelId, !cid.isEmpty, let m = model(byId: cid) { return m }
        if let gid = globalFallbackId, !gid.isEmpty, let m = model(byId: gid) { return m }
        return fallbackModel ?? ProviderModel(credentialId: "openrouter", modelId: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4")
    }

    /// 兜底顺序（#092 D）：能用的网络卡 → 本机 → 能用的桥卡 → 旧口径。以前取 availableModels.first，
    /// 桥卡算「有 key」又排在前面，新用户第一句落到没配对的 Claude Code 上
    private var fallbackModel: ProviderModel? {
        let usable = credentials.filter { isUsable($0) }
        let rank: (APICredential) -> Int = { c in
            switch c.type {
            case .openaiCompatible, .anthropic, .chatgptOAuth: return 0
            case .localMLX: return 1
            default: return 2
            }
        }
        let ordered = usable.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return ordered.lazy.compactMap { c in c.models.first(where: { !ProviderProbe.isNonChatModel($0.modelId) }) ?? c.models.first }.first
            ?? availableModels.first
    }

    /// 若 `selectedChatModel` 指向不存在的模型 → 清空，避免 picker 静默 fallback 到无关模型。
    func resolveStaleSelectedModel() {
        let key = "selectedChatModel"
        guard let current = UserDefaults.standard.string(forKey: key), !current.isEmpty else { return }
        if model(byId: current) == nil {
            print("[ProviderManager] selectedChatModel '\(current)' no longer resolvable, clearing")
            UserDefaults.standard.set("", forKey: key)
        }
    }

    // MARK: - Saved Credential List

    /// 所有用户加的卡（含还没填 key 的草稿卡），按最近使用时间降序。
    /// 给 API 一级页用 —— 替代旧 savedAPIProviders（旧逻辑是 hasKey 才进列表，新设计列表 = 全部卡）。
    var savedAPIProviders: [APICredential] {
        credentials.sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (la?, lb?): return la > lb
            case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
    }

    /// 旧名沿用。
    var customProviders: [APICredential] { credentials }

    /// 改卡昵称。
    func renameCredential(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = credentials.firstIndex(where: { $0.id == id }) else { return }
        credentials[idx].name = trimmed
        persist()
    }

    /// 旧 API 名沿用。
    func renameCustomProvider(id: String, newName: String) { renameCredential(id: id, newName: newName) }

    /// 改 emoji（保存时校验唯一）。
    @discardableResult
    func setEmoji(_ emoji: String, for credentialId: String) -> Bool {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if credentials.contains(where: { $0.id != credentialId && $0.emoji == trimmed }) { return false }
        guard let idx = credentials.firstIndex(where: { $0.id == credentialId }) else { return false }
        credentials[idx].emoji = trimmed
        persist()
        return true
    }

    /// 校验 emoji 是否被别的卡占用（详情页保存前用）。
    func isEmojiTaken(_ emoji: String, excluding credentialId: String?) -> Bool {
        let t = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return credentials.contains(where: { $0.id != credentialId && $0.emoji == t })
    }

    /// 派一个未占用的默认 emoji（新建卡用）。
    func allocateUnusedEmoji() -> String {
        let used = Set(credentials.map(\.emoji))
        return CredentialEmoji.allocate(excluding: used)
    }

    /// 记录某张卡用了某 model（卡片相对时间 + 下次 useCredential 恢复）。
    func touchLastUsed(credentialId: String, modelId: String) {
        guard let idx = credentials.firstIndex(where: { $0.id == credentialId }) else { return }
        credentials[idx].lastUsedModelId = modelId
        credentials[idx].lastUsedAt = Date()
        persist()
    }

    /// 旧 API 名沿用（参数名 providerId 实为 credentialId）。
    func touchLastUsed(providerId: String, modelId: String) {
        touchLastUsed(credentialId: providerId, modelId: modelId)
    }

    // MARK: - Budget (全局保险闸 — 粟粟决策 2026-04-23)
    // per-id 签名保留避免上游改动；内部忽略 id，全部走 GlobalBudgetStore。

    func setBudgetEnabled(_ enabled: Bool, for id: String) {
        GlobalBudgetStore.shared.setEnabled(enabled)
    }

    func setBudgetUSD(_ amount: Double, for id: String) {
        GlobalBudgetStore.shared.setBudgetUSD(amount)
    }

    /// 发送后把实际 cost（USD）累加到全局 spent。
    func commitSpend(providerId: String, amount: Double, usage: TokenUsage? = nil) {
        guard usage?.ledgerSpendRecorded != true else { return }
        GlobalBudgetStore.shared.commitSpend(amount)
    }

    /// 重置全局"已用"；预算上限保留。
    func resetSpent(providerId: String) {
        GlobalBudgetStore.shared.resetSpent()
    }

    /// 发送前门控：估算 cost → 全局保险闸。
    func budgetGate(providerId: String, estimatedCost: Double) -> BudgetGate {
        BudgetCalculator.gate(estimatedCost: estimatedCost)
    }

    // MARK: - ccBridge LAN URL override

    var ccBridgeBaseURL: String {
        let override = UserDefaults.standard.string(forKey: "ccBridgeBaseURLOverride") ?? ""
        if !override.isEmpty { return override }
        return APIProvider.ccBridge.baseURL
    }

    func setCCBridgeBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == APIProvider.ccBridge.baseURL {
            UserDefaults.standard.removeObject(forKey: "ccBridgeBaseURLOverride")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "ccBridgeBaseURLOverride")
        }
        reload()
    }

    var ccBridgeBaseURLBackup: String {
        UserDefaults.standard.string(forKey: "ccBridgeBaseURLBackup") ?? ""
    }

    func setCCBridgeBaseURLBackup(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "ccBridgeBaseURLBackup")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "ccBridgeBaseURLBackup")
        }
    }

    // MARK: - Favorite Models（☆ 收藏 / M3/M4 主消费）

    /// model id 格式为 "credentialId/modelId"。
    func isFavoriteModel(id: String) -> Bool {
        favoriteModelIds.contains(id)
    }

    func toggleFavoriteModel(id: String) {
        if let idx = favoriteModelIds.firstIndex(of: id) {
            favoriteModelIds.remove(at: idx)
        } else {
            favoriteModelIds.append(id)
        }
        saveFavoriteModelIds(favoriteModelIds)
    }

    func resolveStaleFavorites() {
        let filtered = favoriteModelIds.filter { model(byId: $0) != nil }
        if filtered.count != favoriteModelIds.count {
            favoriteModelIds = filtered
            saveFavoriteModelIds(filtered)
        }
    }

    /// 按卡分组的收藏模型（ModelPickerPopover 用）。
    var favoritesByCredential: [(APICredential, [ProviderModel])] {
        var map: [String: [ProviderModel]] = [:]
        for id in favoriteModelIds {
            guard let m = model(byId: id) else { continue }
            map[m.credentialId, default: []].append(m)
        }
        return credentials.compactMap { c -> (APICredential, [ProviderModel])? in
            // 只出发得出请求的卡（#092 D / K2）：示例卡、没 key 的、iOS 上没配对的桥卡都不进选择器
            guard isUsable(c), let ms = map[c.id], !ms.isEmpty else { return nil }
            return (c, ms)
        }
    }

    /// 旧 API 名沿用。
    var favoritesByProvider: [(APICredential, [ProviderModel])] { favoritesByCredential }

    /// "使用这张卡"：切 selectedChatModel 到该卡 lastUsedModelId（fallback models.first）。
    @discardableResult
    func useCredential(id: String) -> String? {
        guard let c = credentials.first(where: { $0.id == id }) else { return nil }
        let targetModelId: String? = {
            if let last = c.lastUsedModelId, c.models.contains(where: { $0.modelId == last }) {
                return last
            }
            return c.models.first?.modelId
        }()
        guard let mid = targetModelId else { return nil }
        let combined = "\(id)/\(mid)"
        UserDefaults.standard.set(combined, forKey: "selectedChatModel")
        touchLastUsed(credentialId: id, modelId: mid)
        return combined
    }

    /// 旧 API 名沿用。
    @discardableResult
    func useProvider(id: String) -> String? { useCredential(id: id) }

    // MARK: - Credential CRUD

    /// 加一张新卡（详情页保存路径）。
    func addCredential(_ c: APICredential) {
        var c = c
        c.baseURL = BaseURLNormalizer.normalize(c.baseURL, type: c.type)
        var list = credentials
        // 同 id 原地替换（以前先删后追加，编辑一次卡就挪到列表最后）
        if let idx = list.firstIndex(where: { $0.id == c.id }) {
            list[idx] = c
        } else {
            list.append(c)
        }
        credentials = list
        persist()
    }

    /// 更新一张卡。
    func updateCredential(_ c: APICredential) {
        addCredential(c)  // 同 id 替换
    }

    /// 删一张卡 + 清 Keychain。
    func removeCredential(id: String) {
        credentials.removeAll { $0.id == id }
        apiKeyCache.removeValue(forKey: id)
        KeychainStore.remove(account: id)
        persist()
    }

    // 旧 API 名沿用 ——
    func addProvider(_ p: APICredential) { addCredential(p) }
    func updateProvider(_ p: APICredential) { updateCredential(p) }
    func removeProvider(id: String) { removeCredential(id: id) }

    // MARK: - Model Management

    /// 给某张卡加一个 model（手动添加 / fetch 后合并）。
    func addModel(to credentialId: String, model: ProviderModel) {
        guard let idx = credentials.firstIndex(where: { $0.id == credentialId }) else { return }
        // 保证 model.credentialId 字段与目标卡一致
        let m = ProviderModel(credentialId: credentialId, modelId: model.modelId, name: model.name)
        credentials[idx].models.removeAll { $0.modelId == m.modelId }
        credentials[idx].models.append(m)
        persist()
    }

    /// 从某张卡删一个 model。
    func removeModel(from credentialId: String, modelId: String) {
        guard let idx = credentials.firstIndex(where: { $0.id == credentialId }) else { return }
        credentials[idx].models.removeAll { $0.modelId == modelId }
        persist()
    }

    // MARK: - Fetch Models from API

    /// Fetch available models from this credential's /models endpoint
    func fetchModels(credentialId: String) async -> Result<[ProviderModel], Error> {
        guard let c = credentials.first(where: { $0.id == credentialId }) else {
            return .failure(NSError(domain: "ProviderManager", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "找不到提供商"]))
        }
        guard let key = apiKey(for: credentialId) else {
            return .failure(NSError(domain: "ProviderManager", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "未设置 API Key"]))
        }

        // chatgptOAuth：走 codex /models 端点，专属 headers + 解码格式
        if c.type == .chatgptOAuth {
            return await fetchChatGPTOAuthModels(credentialId: credentialId, c: c, oauthJSON: key)
        }

        switch c.type {
        case .ccBridge:
            return .failure(NSError(domain: "ProviderManager", code: -5,
                                    userInfo: [NSLocalizedDescriptionKey: "CC Bridge 不支持拉取模型列表"]))
        case .localMLX:
            return .failure(NSError(domain: "ProviderManager", code: -8,
                                    userInfo: [NSLocalizedDescriptionKey: "本机模型跟着 app 内置清单走，不用拉取"]))
        case .unsupported:
            return .failure(NSError(domain: "ProviderManager", code: -7,
                                    userInfo: [NSLocalizedDescriptionKey: "这张卡的类型（\(c.unknownTypeRaw ?? "未知")）当前版本不支持"]))
        case .openaiCompatible, .anthropic, .chatgptOAuth:
            return await ProviderProbe.fetchModels(draft: c, key: key)
        }
    }

    /// 旧 API 名沿用。
    func fetchModels(providerId: String) async -> Result<[ProviderModel], Error> {
        await fetchModels(credentialId: providerId)
    }

    // MARK: - ChatGPT OAuth /models 拉取（G-M6）

    /// 拉 codex /models 端点。oauthJSON 是 Keychain 里存的 OAuth token JSON 字符串。
    /// 必要时自动刷新 access_token，并把新 token 写回 Keychain。
    private func fetchChatGPTOAuthModels(
        credentialId: String,
        c: APICredential,
        oauthJSON: String
    ) async -> Result<[ProviderModel], Error> {
        guard let token0 = OAuthTokenSet.fromKeychainString(oauthJSON) else {
            return .failure(NSError(domain: "ProviderManager", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "ChatGPT 账号未登录"]))
        }
        // 必要时刷新
        let token: OAuthTokenSet
        if token0.isExpired() {
            do {
                token = try await ChatGPTOAuthExchange.refresh(refreshToken: token0.refreshToken)
                await MainActor.run { self.setOAuthToken(token, for: credentialId) }
            } catch {
                return .failure(error)
            }
        } else {
            token = token0
        }

        // 构 URL：baseURL + /models + ?client_version=...
        var trimmedBase = c.baseURL.hasSuffix("/") ? String(c.baseURL.dropLast()) : c.baseURL
        if trimmedBase.isEmpty { trimmedBase = ChatGPTOAuthConfig.codexBaseURL }
        var comps = URLComponents(string: trimmedBase + ChatGPTOAuthConfig.modelsPath)
        comps?.queryItems = [URLQueryItem(name: "client_version", value: ChatGPTOAuthConfig.modelsClientVersion)]
        guard let url = comps?.url else {
            return .failure(NSError(domain: "ProviderManager", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "无效 URL"]))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in ChatGPTOAuthProvider.codexHeaders(accessToken: token.accessToken) {
            // 用 codex headers 包括 Authorization / originator / UA / ChatGPT-Account-ID
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(NSError(domain: "ProviderManager", code: code,
                                        userInfo: [NSLocalizedDescriptionKey: "/models 失败 (\(code))：\(body.prefix(200))"]))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(NSError(domain: "ProviderManager", code: -4,
                                        userInfo: [NSLocalizedDescriptionKey: "/models 响应解析失败"]))
            }
            let rawModels = (json["models"] as? [[String: Any]]) ?? []
            // filter visibility=="list" && supported_in_api=true，按 priority 排
            let filtered = rawModels.compactMap { (m: [String: Any]) -> (modelId: String, name: String, priority: Int)? in
                let visibility = (m["visibility"] as? String) ?? ""
                let supported = (m["supported_in_api"] as? Bool) ?? true
                // 严格筛：visibility 限 "list"（picker 默认可见）；老 ModelInfo 可能没这俩字段，宽容放行
                if !visibility.isEmpty && visibility != "list" { return nil }
                if supported == false { return nil }
                guard let slug = m["slug"] as? String, !slug.isEmpty else { return nil }
                let name = (m["display_name"] as? String) ?? ModelCatalog.shared.model(for: slug)?.name ?? slug
                let priority = (m["priority"] as? Int) ?? 0
                return (modelId: slug, name: name, priority: priority)
            }
            let sorted = filtered.sorted { $0.priority < $1.priority }
            let providerModels = sorted.map {
                ProviderModel(credentialId: credentialId, modelId: $0.modelId, name: $0.name)
            }
            return .success(providerModels)
        } catch {
            return .failure(error)
        }
    }

    /// Fetch and merge models into the credential (adds new, keeps existing)
    func fetchAndMergeModels(credentialId: String) async -> Result<Int, Error> {
        let result = await fetchModels(credentialId: credentialId)
        switch result {
        case .success(let fetched):
            guard !fetched.isEmpty else { return .success(0) }
            let existingIds = Set(credentials.first(where: { $0.id == credentialId })?.models.map(\.modelId) ?? [])
            var addedCount = 0
            for model in fetched where !existingIds.contains(model.modelId) {
                addModel(to: credentialId, model: model)
                addedCount += 1
            }
            return .success(addedCount)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// 旧 API 名沿用。
    func fetchAndMergeModels(providerId: String) async -> Result<Int, Error> {
        await fetchAndMergeModels(credentialId: providerId)
    }

    // MARK: - Connection Test

    /// 已存卡的测试：取卡 + key 交给 ProviderProbe（草稿测试直接调 ProviderProbe.test，不经这里）。
    func testConnection(credentialId: String, preferredModelId: String? = nil) async -> Result<String, Error> {
        guard let c = credentials.first(where: { $0.id == credentialId }) else {
            return .failure(NSError(domain: "ProviderManager", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "找不到提供商"]))
        }
        if c.type == .chatgptOAuth {
            // ChatGPT OAuth：用 /models 端点当探活（成功 = 有效 token + 网络通）
            switch await fetchModels(credentialId: credentialId) {
            case .success(let models): return .success("ChatGPT 账号有效（\(models.count) 个模型）")
            case .failure(let err): return .failure(err)
            }
        }
        if c.type == .unsupported {
            return .failure(NSError(domain: "ProviderManager", code: -7,
                                    userInfo: [NSLocalizedDescriptionKey: "这张卡的类型（\(c.unknownTypeRaw ?? "未知")）当前版本不支持"]))
        }
        let key = apiKey(for: credentialId) ?? ""
        if key.isEmpty && (c.type == .openaiCompatible || c.type == .anthropic) {
            return .failure(NSError(domain: "ProviderManager", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "未设置 API Key"]))
        }
        return await ProviderProbe.test(draft: c, key: key, preferredModelId: preferredModelId).map(\.summary)
    }

    /// 旧 API 名沿用。
    func testConnection(providerId: String, preferredModelId: String? = nil) async -> Result<String, Error> {
        await testConnection(credentialId: providerId, preferredModelId: preferredModelId)
    }

    // MARK: - Persistence (private)

    private func persist() {
        let data = try? JSONEncoder().encode(credentials)
        UserDefaults.standard.set(data, forKey: credentialsKey)
    }

    private func loadCredentials() -> [APICredential] {
        guard let data = UserDefaults.standard.data(forKey: credentialsKey) else { return [] }
        if let all = try? JSONDecoder().decode([APICredential].self, from: data) { return all }
        // 整表解码失败时**不要返回空数组**——那等于「所有 API key 都不见了」（对比线洞 4）。
        // 退回逐条解码：坏的那张跳过，其余照常出现在列表里。
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var out: [APICredential] = []
        var skipped = 0
        for item in raw {
            guard let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let cred = try? JSONDecoder().decode(APICredential.self, from: itemData) else { skipped += 1; continue }
            out.append(cred)
        }
        if skipped > 0 { BreadcrumbLog.shared.add("⚠️", "凭据表有 \(skipped) 条解码失败，已跳过（其余 \(out.count) 条正常）") }
        return out
    }

    private func loadFavoriteModelIds() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: favoriteModelsKey) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func saveFavoriteModelIds(_ ids: [String]) {
        let data = try? JSONEncoder().encode(ids)
        UserDefaults.standard.set(data, forKey: favoriteModelsKey)
    }

    // MARK: - M1 一次性迁移：providerId → credentialId

    /// 把旧版"以 providerId 为身份"的数据迁到"以 credentialId 为身份"。
    /// 只跑一次（防重跑标记 `credentialMigrationV1Done`）。
    private func migrateToCredentialsV1IfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: credentialMigrationV1DoneKey) { return }

        // 1) 枚举旧"有 key 的 provider"：内置 presets 命中 Keychain account + 老 custom JSON
        var idMap: [String: String] = [:]   // 旧 providerId → 新 credentialId
        var newCreds: [APICredential] = []
        var usedEmojis: Set<String> = []

        let allKeys = apiKeyCache  // warmUp 已跑过

        // 1a) 老 custom provider JSON（曾持久化为 [APIProvider]，但旧 APIProvider 结构里就有 ratios/budget 字段——
        // 我们用 LegacyCustomProvider 简洁解码兼容字段。）
        if let data = defaults.data(forKey: legacyCustomProvidersKey),
           let legacy = try? JSONDecoder().decode([LegacyCustomProvider].self, from: data) {
            for p in legacy {
                let credId = "cred-\(UUID().uuidString)"
                idMap[p.id] = credId
                let emoji = CredentialEmoji.allocate(excluding: usedEmojis)
                usedEmojis.insert(emoji)
                let migratedModels = p.models.map {
                    ProviderModel(credentialId: credId, modelId: $0.modelId, name: $0.name)
                }
                newCreds.append(APICredential(
                    id: credId,
                    name: p.name,
                    emoji: emoji,
                    presetId: nil,  // custom 不绑预设
                    type: p.type,
                    baseURL: p.baseURL,
                    extraHeaders: p.extraHeaders,
                    models: migratedModels,
                    createdAt: p.createdAt ?? Date(),
                    lastUsedAt: p.lastUsedAt,
                    lastUsedModelId: p.lastUsedModelId
                ))
            }
        }

        // 1b) 内置 presets 命中 Keychain → 转成卡
        let legacyExtraModels: [String: [LegacyModel]] = {
            guard let data = defaults.data(forKey: legacyExtraModelsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: [LegacyModel]].self, from: data)) ?? [:]
        }()

        for preset in APIProvider.presets {
            // 内置 presets 全部检查：有 key（或是 ccBridge）才建卡
            let hasKey = (allKeys[preset.id] ?? "").isEmpty == false
            let needCard = hasKey || preset.type == .ccBridge
            guard needCard else { continue }

            // ccBridge 是本地全局单例，固定用 "cc-bridge" 作 id（也是 keychain account），
            // 避免 ContentView/CCSettingsView 等硬编码引用到 cred-UUID 找不到 token。
            // Codex 预设同为 ccBridge 类型——以前这里一律写 "cc-bridge"，两张卡撞 id（新装机两张「Codex (本地)」）；
            // 本地桥卡一律用预设 id 当卡 id（"cc-bridge" / "codex-bridge"）。
            let credId = preset.type == .ccBridge ? preset.id : "cred-\(UUID().uuidString)"
            idMap[preset.id] = credId
            let emoji = CredentialEmoji.allocate(excluding: usedEmojis)
            usedEmojis.insert(emoji)

            // 合并 preset 自带模型 + 老 extraModels[preset.id]
            var modelList: [ProviderModel] = preset.models.map {
                ProviderModel(credentialId: credId, modelId: $0.modelId, name: $0.name)
            }
            if let extras = legacyExtraModels[preset.id] {
                let existing = Set(modelList.map(\.modelId))
                for e in extras where !existing.contains(e.modelId) {
                    modelList.append(ProviderModel(credentialId: credId, modelId: e.modelId, name: e.name))
                }
            }

            newCreds.append(APICredential(
                id: credId,
                name: preset.name,
                emoji: emoji,
                presetId: preset.id,
                type: preset.type,
                baseURL: preset.baseURL,
                extraHeaders: preset.extraHeaders,
                models: modelList
            ))
        }

        // 2) 写 Keychain：把每张卡的 key 用新 credentialId 重新存一份（旧 account 保留，不删，做兜底）
        let sync = defaults.bool(forKey: cloudSyncKey)
        for (oldId, newId) in idMap {
            if let key = allKeys[oldId], !key.isEmpty {
                _ = KeychainStore.set(key, account: newId, sync: sync)
                apiKeyCache[newId] = key
            }
        }

        // 3) 持久化 credentials
        if let data = try? JSONEncoder().encode(newCreds) {
            defaults.set(data, forKey: credentialsKey)
        }

        // 4) 重写复合 id：selectedChatModel / memoryExtractModelId / favoriteModels
        func remapCombined(_ combined: String) -> String? {
            guard let slashIdx = combined.firstIndex(of: "/") else { return nil }
            let oldPid = String(combined[..<slashIdx])
            let modelPart = String(combined[combined.index(after: slashIdx)...])
            guard let newId = idMap[oldPid] else { return nil }
            return "\(newId)/\(modelPart)"
        }

        if let cur = defaults.string(forKey: "selectedChatModel"), let m = remapCombined(cur) {
            defaults.set(m, forKey: "selectedChatModel")
        }
        if let cur = defaults.string(forKey: "memoryExtractModelId"), let m = remapCombined(cur) {
            defaults.set(m, forKey: "memoryExtractModelId")
        }
        if let data = defaults.data(forKey: favoriteModelsKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            let remapped = arr.compactMap { remapCombined($0) ?? $0 }  // 没映射就保留原值（孤儿会被 resolveStaleFavorites 清）
            if let out = try? JSONEncoder().encode(remapped) {
                defaults.set(out, forKey: favoriteModelsKey)
            }
        }

        // 5) 重写 SwiftData Conversation.selectedModelId —— 由调用方在 init 后跑（需要 ModelContext，这里没有）
        // 暴露 idMap 给外部用：见 `pendingConversationRemap`。
        pendingConversationRemap = idMap

        defaults.set(true, forKey: credentialMigrationV1DoneKey)
        print("[ProviderManager] migrateToCredentialsV1: 迁出 \(newCreds.count) 张卡，旧 id 映射 \(idMap.count) 条")
    }

    /// M1 迁移产物：旧 providerId → 新 credentialId。
    /// 外部（MemoryPalaceApp 启动后）拿这个映射去重写 SwiftData Conversation.selectedModelId。
    /// 用完一次就清空。
    @ObservationIgnored
    private(set) var pendingConversationRemap: [String: String] = [:]

    func consumePendingConversationRemap() -> [String: String] {
        let map = pendingConversationRemap
        pendingConversationRemap = [:]
        return map
    }

    // MARK: - D2: 旧 Keychain account 清理
    //
    // M1 迁移把每张卡的 key 写到新 credentialId account，**保留**了旧 providerId account 兜底。
    // 第二次启动后（v1 迁移已成功），下次冷启动跑一次清理：
    //   - 扫所有 Keychain account
    //   - 是已知 preset id（"openrouter"/"openai"/.../"cc-bridge"）的
    //   - 且当前 credentials 里有对应 presetId 的卡且已有 key（key 已经搬到新 account）
    //   - 删旧 account
    // 防重跑：用 keychainLegacyCleanupV1DoneKey，只跑一次。
    //
    // 不在 init 同步里跑——要等 reload() 后 credentials 是最新的。已挂在 init 末尾。

    // F1: ccBridge 卡 id 修复
    //
    // 历史：M1 迁移给所有卡（包含 ccBridge）派 cred-UUID 当 id。但 ccBridge 是本地全局单例，
    // ContentView/CCSettingsView/扫码配对回调等多处硬编码 "cc-bridge" 当 keychain account
    // 读写 token——这些地方拿不到 cred-UUID（也无意订阅 PM），导致：
    //   1. 启动时 ContentView 读不到 token → LAN 模式连不上、靠手动按重连
    //   2. 扫码配对回调写错 account → token 落在 "cc-bridge"，但卡用 cred-UUID 读
    //
    // 修法：把 ccBridge 卡的 id 强制为 "cc-bridge"。
    // - 新迁移路径：V1 迁移函数对 cc 卡直接用 "cc-bridge"
    // - 旧装机量：本 fixup pass 把已存在的 cred-UUID ccBridge 卡的 id 改回 "cc-bridge"，
    //   keychain token 从旧 account 搬过来；selectedChatModel/favoriteModels 里复合 id 也重写。
    // 防重跑：ccBridgeIdFixupV2DoneKey

    private func fixupCCBridgeIdV2IfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: ccBridgeIdFixupV2DoneKey) { return }

        var creds = loadCredentials()
        guard let idx = creds.firstIndex(where: { $0.type == .ccBridge }) else {
            // 没 cc 卡，标记完事
            defaults.set(true, forKey: ccBridgeIdFixupV2DoneKey)
            return
        }

        let oldId = creds[idx].id
        if oldId == "cc-bridge" {
            // 已经是固定 id，无需 fixup（迁移路径就走 V1 改过的）
            defaults.set(true, forKey: ccBridgeIdFixupV2DoneKey)
            return
        }

        // 1) 把 token 从旧 account 搬到 "cc-bridge"
        let sync = defaults.bool(forKey: cloudSyncKey)
        if let oldKey = apiKeyCache[oldId], !oldKey.isEmpty {
            _ = KeychainStore.set(oldKey, account: "cc-bridge", sync: sync)
            apiKeyCache["cc-bridge"] = oldKey
        }
        KeychainStore.remove(account: oldId)
        apiKeyCache.removeValue(forKey: oldId)

        // 2) 改卡 id 和卡里 models 的 credentialId
        var fixed = creds[idx]
        fixed = APICredential(
            id: "cc-bridge",
            name: fixed.name,
            emoji: fixed.emoji,
            presetId: fixed.presetId,
            type: fixed.type,
            baseURL: fixed.baseURL,
            extraHeaders: fixed.extraHeaders,
            models: fixed.models.map {
                ProviderModel(credentialId: "cc-bridge", modelId: $0.modelId, name: $0.name)
            },
            createdAt: fixed.createdAt,
            lastUsedAt: fixed.lastUsedAt,
            lastUsedModelId: fixed.lastUsedModelId
        )
        creds[idx] = fixed
        if let data = try? JSONEncoder().encode(creds) {
            defaults.set(data, forKey: credentialsKey)
        }

        // 3) 重写 selectedChatModel / memoryExtractModelId / favoriteModels 里复合 id 前缀
        func remap(_ combined: String) -> String? {
            guard combined.hasPrefix(oldId + "/") else { return nil }
            return "cc-bridge/" + String(combined.dropFirst(oldId.count + 1))
        }
        if let cur = defaults.string(forKey: "selectedChatModel"), let m = remap(cur) {
            defaults.set(m, forKey: "selectedChatModel")
        }
        if let cur = defaults.string(forKey: "memoryExtractModelId"), let m = remap(cur) {
            defaults.set(m, forKey: "memoryExtractModelId")
        }
        if let data = defaults.data(forKey: favoriteModelsKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            let remapped = arr.map { remap($0) ?? $0 }
            if let out = try? JSONEncoder().encode(remapped) {
                defaults.set(out, forKey: favoriteModelsKey)
            }
        }

        // 4) Conversation.selectedModelId remap 也加进 pendingConversationRemap，让 App.task 处理
        pendingConversationRemap[oldId] = "cc-bridge"

        defaults.set(true, forKey: ccBridgeIdFixupV2DoneKey)
        print("[ProviderManager] fixupCCBridgeIdV2: \(oldId) → cc-bridge")
    }

    private func cleanupLegacyKeychainAccountsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: keychainLegacyCleanupV1DoneKey) { return }
        // 必须先确认 V1 迁移已成功，否则可能误删未迁移的 key
        guard defaults.bool(forKey: credentialMigrationV1DoneKey) else { return }

        let presetIds = Set(APIProvider.presets.map(\.id))
        // 当前每个 preset 是否已有对应 credential 持有 key（迁移成功标志）
        let presetsCoveredByNewKey: Set<String> = {
            var s: Set<String> = []
            for c in credentials {
                guard let pid = c.presetId, hasKey(for: c.id) else { continue }
                s.insert(pid)
            }
            return s
        }()

        var removed: [String] = []
        for (account, _) in apiKeyCache {
            // 只清"形如 preset id"的旧 account；新 credentialId 是 "cred-..." 不会撞
            guard presetIds.contains(account) else { continue }
            // cc-bridge 卡的 id 就是 "cc-bridge"（本地全局单例特例），keychain account 也用这个
            // 不能误删（否则 token 丢，重连要重新扫码）
            // codex-bridge 同理（V1 现在用预设 id 当卡 id）
            if account == "cc-bridge" || account == "codex-bridge" { continue }
            guard presetsCoveredByNewKey.contains(account) else { continue }  // 没成功迁移的不动
            KeychainStore.remove(account: account)
            apiKeyCache.removeValue(forKey: account)
            removed.append(account)
        }

        defaults.set(true, forKey: keychainLegacyCleanupV1DoneKey)
        if !removed.isEmpty {
            print("[ProviderManager] cleanupLegacyKeychainAccounts: 清理 \(removed.count) 条旧 account: \(removed)")
        }
    }
}

// MARK: - 旧存档解码兼容类型（仅迁移用）

private struct LegacyCustomProvider: Decodable {
    let id: String
    let name: String
    let type: ProviderType
    let baseURL: String
    let extraHeaders: [String: String]
    let models: [LegacyModel]
    let createdAt: Date?
    let lastUsedAt: Date?
    let lastUsedModelId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, baseURL, extraHeaders, models, createdAt, lastUsedAt, lastUsedModelId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(ProviderType.self, forKey: .type)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.extraHeaders = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
        self.models = try c.decodeIfPresent([LegacyModel].self, forKey: .models) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.lastUsedModelId = try c.decodeIfPresent(String.self, forKey: .lastUsedModelId)
        // 老存档可能带 ratio 字段 —— 不解码，让 decoder 静默忽略
    }
}

private struct LegacyModel: Decodable {
    let modelId: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case providerId, credentialId, modelId, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.modelId = try c.decode(String.self, forKey: .modelId)
        self.name = try c.decode(String.self, forKey: .name)
    }
}
