import Foundation

/// Ollama Search API（云端）. POST https://ollama.com/api/web_search
/// 注：不是本地 ollama runtime，是 ollama.com 提供的云搜索 API，需要 key
struct OllamaProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .ollama

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .ollama = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        guard let url = URL(string: "https://ollama.com/api/web_search") else { throw WebSearchProviderError.missingURL }

        let body: [String: Any] = [
            "query": query,
            "max_results": max(1, min(common.resultSize, 10)),
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = common.timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchProviderError.decode("not JSON")
        }
        let raw = (json["results"] as? [[String: Any]]) ?? []
        let items = raw.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            let title = item["title"] as? String ?? ""
            let url = item["url"] as? String ?? ""
            guard !url.isEmpty else { return nil }
            let content = item["content"] as? String ?? ""
            return WebSearchResultItem(title: title.isEmpty ? url : title, url: url, text: content)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
