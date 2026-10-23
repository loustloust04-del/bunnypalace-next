import Foundation

/// 13 家 backend 的 kind 标签——WebSearchServiceOptions case 和 UI 显示名都靠它对齐。
enum WebSearchProviderKind: String, Codable, CaseIterable, Identifiable {
    case bingLocal
    case duckduckgo
    case brave
    case tavily
    case exa
    case perplexity
    case linkup
    case jina
    case zhipu
    case bocha
    case metaso
    case searxng
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bingLocal: return "Bing（无 key）"
        case .duckduckgo: return "DuckDuckGo（无 key）"
        case .brave: return "Brave"
        case .tavily: return "Tavily"
        case .exa: return "Exa"
        case .perplexity: return "Perplexity"
        case .linkup: return "LinkUp"
        case .jina: return "Jina"
        case .zhipu: return "智谱"
        case .bocha: return "博查"
        case .metaso: return "秘塔"
        case .searxng: return "SearXNG（自建）"
        case .ollama: return "Ollama（本地）"
        }
    }

    /// 是否需要 API key（决定 UI 是否显示 SecureField）
    /// SearXNG 也走 key 字段：basic auth 时密码用 key，没 auth 时留空
    /// Ollama 用云 API ollama.com/api/web_search，需要 key
    var needsKey: Bool {
        switch self {
        case .bingLocal, .duckduckgo: return false
        default: return true
        }
    }

    /// 是否允许自定义 endpoint
    var supportsCustomURL: Bool {
        switch self {
        case .tavily, .exa, .searxng: return true
        default: return false
        }
    }
}

/// 持久化用——每家配置一个 case，关联值是字段 struct。Codable 走 type+payload 显式 tagging。
enum WebSearchServiceOptions: Codable, Identifiable, Equatable {
    case bingLocal(BingLocalOptions)
    case duckduckgo(DuckDuckGoOptions)
    case brave(BraveOptions)
    case tavily(TavilyOptions)
    case exa(ExaOptions)
    case perplexity(PerplexityOptions)
    case linkup(LinkUpOptions)
    case jina(JinaOptions)
    case zhipu(ZhipuOptions)
    case bocha(BochaOptions)
    case metaso(MetasoOptions)
    case searxng(SearXNGOptions)
    case ollama(OllamaOptions)

    var kind: WebSearchProviderKind {
        switch self {
        case .bingLocal: return .bingLocal
        case .duckduckgo: return .duckduckgo
        case .brave: return .brave
        case .tavily: return .tavily
        case .exa: return .exa
        case .perplexity: return .perplexity
        case .linkup: return .linkup
        case .jina: return .jina
        case .zhipu: return .zhipu
        case .bocha: return .bocha
        case .metaso: return .metaso
        case .searxng: return .searxng
        case .ollama: return .ollama
        }
    }

    /// UI 列表用——每条配置一个稳定 id，UserDefaults 重启后保留
    var id: String {
        switch self {
        case .bingLocal(let o): return o.id
        case .duckduckgo(let o): return o.id
        case .brave(let o): return o.id
        case .tavily(let o): return o.id
        case .exa(let o): return o.id
        case .perplexity(let o): return o.id
        case .linkup(let o): return o.id
        case .jina(let o): return o.id
        case .zhipu(let o): return o.id
        case .bocha(let o): return o.id
        case .metaso(let o): return o.id
        case .searxng(let o): return o.id
        case .ollama(let o): return o.id
        }
    }

    /// 标题（UI 显示）：用户自定义 name 优先，否则用 kind 默认
    var displayLabel: String {
        let custom: String
        switch self {
        case .bingLocal(let o): custom = o.name
        case .duckduckgo(let o): custom = o.name
        case .brave(let o): custom = o.name
        case .tavily(let o): custom = o.name
        case .exa(let o): custom = o.name
        case .perplexity(let o): custom = o.name
        case .linkup(let o): custom = o.name
        case .jina(let o): custom = o.name
        case .zhipu(let o): custom = o.name
        case .bocha(let o): custom = o.name
        case .metaso(let o): custom = o.name
        case .searxng(let o): custom = o.name
        case .ollama(let o): custom = o.name
        }
        return custom.isEmpty ? kind.displayName : custom
    }

    /// Keychain account（统一前缀避免与 LLM provider key 撞名）
    var keychainAccount: String { "websearch:\(id)" }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case kind, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(WebSearchProviderKind.self, forKey: .kind)
        switch kind {
        case .bingLocal: self = .bingLocal(try c.decode(BingLocalOptions.self, forKey: .payload))
        case .duckduckgo: self = .duckduckgo(try c.decode(DuckDuckGoOptions.self, forKey: .payload))
        case .brave: self = .brave(try c.decode(BraveOptions.self, forKey: .payload))
        case .tavily: self = .tavily(try c.decode(TavilyOptions.self, forKey: .payload))
        case .exa: self = .exa(try c.decode(ExaOptions.self, forKey: .payload))
        case .perplexity: self = .perplexity(try c.decode(PerplexityOptions.self, forKey: .payload))
        case .linkup: self = .linkup(try c.decode(LinkUpOptions.self, forKey: .payload))
        case .jina: self = .jina(try c.decode(JinaOptions.self, forKey: .payload))
        case .zhipu: self = .zhipu(try c.decode(ZhipuOptions.self, forKey: .payload))
        case .bocha: self = .bocha(try c.decode(BochaOptions.self, forKey: .payload))
        case .metaso: self = .metaso(try c.decode(MetasoOptions.self, forKey: .payload))
        case .searxng: self = .searxng(try c.decode(SearXNGOptions.self, forKey: .payload))
        case .ollama: self = .ollama(try c.decode(OllamaOptions.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .bingLocal(let o): try c.encode(o, forKey: .payload)
        case .duckduckgo(let o): try c.encode(o, forKey: .payload)
        case .brave(let o): try c.encode(o, forKey: .payload)
        case .tavily(let o): try c.encode(o, forKey: .payload)
        case .exa(let o): try c.encode(o, forKey: .payload)
        case .perplexity(let o): try c.encode(o, forKey: .payload)
        case .linkup(let o): try c.encode(o, forKey: .payload)
        case .jina(let o): try c.encode(o, forKey: .payload)
        case .zhipu(let o): try c.encode(o, forKey: .payload)
        case .bocha(let o): try c.encode(o, forKey: .payload)
        case .metaso(let o): try c.encode(o, forKey: .payload)
        case .searxng(let o): try c.encode(o, forKey: .payload)
        case .ollama(let o): try c.encode(o, forKey: .payload)
        }
    }

    /// 工厂——给空 backend kind 造一份默认 options（add 流程用）
    static func makeDefault(kind: WebSearchProviderKind, id: String = UUID().uuidString) -> WebSearchServiceOptions {
        switch kind {
        case .bingLocal: return .bingLocal(.init(id: id))
        case .duckduckgo: return .duckduckgo(.init(id: id))
        case .brave: return .brave(.init(id: id))
        case .tavily: return .tavily(.init(id: id))
        case .exa: return .exa(.init(id: id))
        case .perplexity: return .perplexity(.init(id: id))
        case .linkup: return .linkup(.init(id: id))
        case .jina: return .jina(.init(id: id))
        case .zhipu: return .zhipu(.init(id: id))
        case .bocha: return .bocha(.init(id: id))
        case .metaso: return .metaso(.init(id: id))
        case .searxng: return .searxng(.init(id: id))
        case .ollama: return .ollama(.init(id: id))
        }
    }
}

// MARK: - 各家 Options struct
// 通用约定：API key 不入 Codable（走 Keychain），struct 只持有 id + 非敏感配置。

protocol WebSearchOptionsBase: Codable, Equatable {
    var id: String { get }
    var name: String { get }
}

struct BingLocalOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var acceptLanguage: String = "zh-CN,zh;q=0.9,en;q=0.8"
}

struct DuckDuckGoOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var region: String = "wt-wt"   // wt-wt = no region; cn-zh / us-en 等
}

struct BraveOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
}

struct TavilyOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var customURL: String = ""    // 空=用默认 https://api.tavily.com/search
}

struct ExaOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var customURL: String = ""    // 空=用默认 https://api.exa.ai/search
    var fetchFullText: Bool = true
}

struct PerplexityOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var country: String = ""             // ISO 3166-1 alpha-2，空=不限
    var allowedDomains: [String] = []
    var maxTokensPerPage: Int = 0        // 0=不限
}

struct LinkUpOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var depth: String = "standard"        // standard / deep
}

struct JinaOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
}

struct ZhipuOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
}

struct BochaOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var freshness: String = "noLimit"     // noLimit / day / week / month / year
    var summary: Bool = true
    var includeDomains: String = ""       // 逗号分隔
    var excludeDomains: String = ""
}

struct MetasoOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
}

struct SearXNGOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
    var customURL: String = ""            // 必填：用户自建实例
    var engines: String = ""              // 逗号分隔，空=用 server 默认
    var language: String = ""             // 空=auto
    var username: String = ""             // basic auth（API key 走 Keychain 即 password）
}

/// Ollama 走云端 search API（ollama.com/api/web_search），不是本地 ollama runtime
struct OllamaOptions: WebSearchOptionsBase {
    var id: String = UUID().uuidString
    var name: String = ""
}
