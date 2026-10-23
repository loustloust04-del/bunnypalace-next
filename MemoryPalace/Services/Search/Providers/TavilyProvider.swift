import Foundation

/// Tavily Search API. POST https://api.tavily.com/search
struct TavilyProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .tavily

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .tavily(let opts) = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        let urlStr = opts.customURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? "https://api.tavily.com/search"
            : opts.customURL
        guard let url = URL(string: urlStr) else { throw WebSearchProviderError.missingURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = common.timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["query": query, "max_results": common.resultSize]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchProviderError.decode("not JSON")
        }
        let results = (json["results"] as? [[String: Any]]) ?? []
        let items = results.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            let content = item["content"] as? String ?? ""
            return WebSearchResultItem(title: title, url: url, text: content)
        }
        let answer = json["answer"] as? String
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(answer: answer, items: items)
    }
}
