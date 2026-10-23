import Foundation

/// 单条搜索结果项。
/// id/index 在 WebSearchToolService.execute 里赋值，模型用 `[citation](index:id)` 引用，UI 反查跳 URL。
struct WebSearchResultItem: Codable, Equatable {
    let title: String
    let url: String
    let text: String
    var id: String?
    var index: Int?

    init(title: String, url: String, text: String, id: String? = nil, index: Int? = nil) {
        self.title = title
        self.url = url
        self.text = text
        self.id = id
        self.index = index
    }
}

struct WebSearchResult: Codable, Equatable {
    let answer: String?
    let items: [WebSearchResultItem]

    init(answer: String? = nil, items: [WebSearchResultItem]) {
        self.answer = answer
        self.items = items
    }
}

/// 所有搜索 backend 共享的请求参数。
/// resultSize：返回多少条；timeoutMs：网络请求超时（毫秒）。
struct WebSearchCommonOptions {
    var resultSize: Int = 10
    var timeoutMs: Int = 5000

    var timeout: TimeInterval { Double(timeoutMs) / 1000.0 }
}

enum WebSearchProviderError: LocalizedError {
    case missingAPIKey
    case missingURL
    case http(Int, String)
    case decode(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "缺少 API key"
        case .missingURL: return "缺少服务 URL"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decode(let msg): return "解析失败: \(msg)"
        case .empty: return "搜索结果为空"
        }
    }
}

/// 所有 backend 实现此 protocol。具体 options 经 SearchServiceFactory 派发。
protocol WebSearchProvider {
    /// backend 内部 id，与 WebSearchServiceOptions case 一一对应
    static var kind: WebSearchProviderKind { get }
    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult
}
