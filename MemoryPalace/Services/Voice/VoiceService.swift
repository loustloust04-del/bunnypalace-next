import Foundation

// MARK: - 语音服务配置（plan-voice-providers V1a）
//
// 一份 VoiceService = 一个厂商账号的配置（名字、地址、专有参数）；key 不进配置，存钥匙串 account `voice.<id>`。
// 楼层按 `Profile.voiceServiceId` 选用哪一份。合成能力见 VoiceSynthesizer.swift。

/// 厂商种类。按原始字符串编码；不认识的种类（新版本写的、被降级读到）解成 `.unknown(原值)`，再编码原样写回。
enum VoiceServiceKind: Hashable, Codable {
    case elevenLabs
    case openAICompatible
    case miniMax
    case system
    case unknown(String)

    /// 「添加服务」里能选的厂商（顺序即界面顺序）
    static let addable: [VoiceServiceKind] = [.elevenLabs, .openAICompatible, .miniMax, .system]

    init(rawValue: String) {
        switch rawValue {
        case "elevenLabs": self = .elevenLabs
        case "openAICompatible": self = .openAICompatible
        case "miniMax": self = .miniMax
        case "system": self = .system
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .elevenLabs: "elevenLabs"
        case .openAICompatible: "openAICompatible"
        case .miniMax: "miniMax"
        case .system: "system"
        case .unknown(let raw): raw
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAICompatible: "OpenAI 兼容"
        case .miniMax: "MiniMax"
        case .system: "系统音"
        case .unknown: "不支持的服务"
        }
    }

    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// 需要 API key（系统音不要）
    var needsKey: Bool {
        switch self {
        case .elevenLabs, .openAICompatible, .miniMax: true
        case .system, .unknown: false
        }
    }

    /// 编辑表单里的地址栏：nil = 不显示；required = 必填
    var baseURLField: (placeholder: String, required: Bool)? {
        switch self {
        case .openAICompatible: ("https://api.openai.com/v1", true)
        case .miniMax: (MiniMaxOptions.defaultBaseURL, false)
        case .elevenLabs, .system, .unknown: nil
        }
    }
}

/// OpenAI 兼容（`/audio/speech`）专有参数：可选模型由用户填（各家模型名不一样）
struct OpenAICompatibleOptions: Codable, Equatable {
    static let defaultModels = ["gpt-4o-mini-tts", "tts-1"]
    static let formats = ["mp3", "wav"]
    var models: [String] = OpenAICompatibleOptions.defaultModels
    /// 输出格式 mp3 / wav；nil = 自动（地址含 groq 用 wav——Groq Orpheus 只出 wav，其余 mp3）
    var responseFormat: String? = nil

    init(models: [String] = OpenAICompatibleOptions.defaultModels, responseFormat: String? = nil) {
        self.models = models
        self.responseFormat = responseFormat
    }

    /// 实际请求的格式
    func effectiveFormat(baseURL: String?) -> String {
        if let f = responseFormat, Self.formats.contains(f) { return f }
        return (baseURL ?? "").lowercased().contains("groq") ? "wav" : "mp3"
    }
}

/// MiniMax（`t2a_v2`）专有参数。默认地址按官方文档（10-04：国内 api.minimax.cn；国际站填 https://api.minimax.io/v1）
struct MiniMaxOptions: Codable, Equatable {
    static let defaultBaseURL = "https://api.minimax.cn/v1"
    var groupId: String = ""
}

struct VoiceService: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: VoiceServiceKind
    /// 空 = 用厂商默认地址
    var baseURL: String?
    var openAICompatible: OpenAICompatibleOptions?
    var miniMax: MiniMaxOptions?

    init(id: String = UUID().uuidString, name: String, kind: VoiceServiceKind, baseURL: String? = nil,
         openAICompatible: OpenAICompatibleOptions? = nil, miniMax: MiniMaxOptions? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.openAICompatible = openAICompatible
        self.miniMax = miniMax
    }

    /// 新建时按厂商带上默认专有参数
    static func blank(kind: VoiceServiceKind) -> VoiceService {
        VoiceService(name: kind.displayName, kind: kind,
                     openAICompatible: kind == .openAICompatible ? OpenAICompatibleOptions() : nil,
                     miniMax: kind == .miniMax ? MiniMaxOptions() : nil)
    }

    var openAICompatibleOptions: OpenAICompatibleOptions {
        get { openAICompatible ?? OpenAICompatibleOptions() }
        set { openAICompatible = newValue }
    }

    var miniMaxOptions: MiniMaxOptions {
        get { miniMax ?? MiniMaxOptions() }
        set { miniMax = newValue }
    }

    /// 地址：去空白；空串当 nil
    var trimmedBaseURL: String? {
        let t = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Store

/// 语音服务列表（UserDefaults）+ 各自的 key（钥匙串）。
@Observable
final class VoiceServiceStore {
    static let shared = VoiceServiceStore()
    static let listKey = "voiceServices.v1"

    private(set) var services: [VoiceService]
    private let defaults: UserDefaults
    private let keychainService: String

    /// 测试注入独立 UserDefaults suite + 钥匙串 service，别碰真条目
    init(defaults: UserDefaults = .standard, keychainService: String = KeychainStore.service) {
        self.defaults = defaults
        self.keychainService = keychainService
        if let data = defaults.data(forKey: Self.listKey),
           let decoded = try? JSONDecoder().decode([VoiceService].self, from: data) {
            services = decoded
        } else {
            services = []
        }
    }

    static func keychainAccount(for serviceId: String) -> String { "voice.\(serviceId)" }

    func service(id: String?) -> VoiceService? {
        guard let id else { return nil }
        return services.first { $0.id == id }
    }

    func add(_ service: VoiceService, key: String? = nil) {
        services.removeAll { $0.id == service.id }
        services.append(service)
        save()
        if let key { setKey(key, for: service) }
    }

    func update(_ service: VoiceService) {
        guard let i = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[i] = service
        save()
    }

    /// 删配置 + 删 key（楼层引用由调用方先清）
    func delete(id: String) {
        services.removeAll { $0.id == id }
        save()
        KeychainStore.remove(account: Self.keychainAccount(for: id), service: keychainService)
    }

    func key(for serviceId: String) -> String? {
        let k = KeychainStore.get(account: Self.keychainAccount(for: serviceId), service: keychainService)
        return (k ?? "").isEmpty ? nil : k
    }

    /// 空串 = 删 key。
    /// 过渡期：ElevenLabs 的 key 同时写回老 account `elevenlabs`——语音条 / 通话还在读老 account（V3/V4 换完调用点后删这段）。
    /// 迁移本身传 `mirrorLegacy: false`，不重写老条目。返回 `voice.<id>` 这条是否写成功（镜像不计）。
    @discardableResult
    func setKey(_ key: String?, for service: VoiceService, mirrorLegacy: Bool = true) -> Bool {
        let trimmed = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        let ok = KeychainStore.set(value, account: Self.keychainAccount(for: service.id), sync: false, service: keychainService)
        if mirrorLegacy, service.kind == .elevenLabs {
            KeychainStore.set(value, account: VoiceTuning.keychainAccount, sync: false, service: keychainService)
        }
        return ok
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(services) else { return }
        defaults.set(data, forKey: Self.listKey)
    }

    // MARK: - 错误信息去 key

    /// 给界面看的错误文字：统一过 `redact`，带上这个服务自己的 key 一起抹
    func errorMessage(_ error: Error, serviceId: String?) -> String {
        let raw = (error as? VoiceSynthError)?.message ?? error.localizedDescription
        let secrets = serviceId.flatMap { key(for: $0) }.map { [$0] } ?? []
        return Self.redact(raw, secrets: secrets)
    }

    /// 抹掉已知 key 原文 + 常见 token 形状（`Bearer xxx`、`sk-xxx`、`xi-api-key: xxx`）
    static func redact(_ text: String, secrets: [String]) -> String {
        var out = text
        for s in secrets where s.count >= 4 {
            out = out.replacingOccurrences(of: s, with: "•••")
        }
        let patterns = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#, "$1•••"),
            (#"(?i)((?:xi-api-key|api[_-]?key|authorization)["']?\s*[:=]\s*["']?)[A-Za-z0-9._\-]+"#, "$1•••"),
            (#"\bsk-[A-Za-z0-9_\-]{6,}"#, "sk-•••"),
        ]
        for (pattern, template) in patterns {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }
}

// MARK: - 楼层声音写入

extension Profile {
    /// 换服务 / 换声音都走这里。过渡期：服务是 ElevenLabs 时同步写老字段 `elevenVoiceId/Name`
    /// （语音条、通话、提示词注入还读老字段，V3/V4 换完调用点后删），别的服务清掉老字段。
    mutating func setVoice(service: VoiceService?, voiceId: String?, voiceName: String?) {
        let trimmed = (voiceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanId: String? = trimmed.isEmpty ? nil : trimmed
        if voiceServiceId != service?.id {
            messageModel = nil
            callModel = nil
        }
        voiceServiceId = service?.id
        self.voiceId = cleanId
        self.voiceName = cleanId == nil ? nil : (voiceName ?? cleanId)
        if service?.kind == .elevenLabs {
            elevenVoiceId = self.voiceId
            elevenVoiceName = self.voiceName
        } else {
            elevenVoiceId = nil
            elevenVoiceName = nil
        }
    }
}
