import Foundation

/// Brave Search API. https://api.search.brave.com/res/v1/web/search
struct BraveProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .brave

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .brave = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=\(common.resultSize)") else {
            throw WebSearchProviderError.missingURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = common.timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchProviderError.decode("not JSON")
        }
        let webResults = (json["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        let items = webResults.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            let desc = item["description"] as? String ?? ""
            return WebSearchResultItem(title: title, url: url, text: desc)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
