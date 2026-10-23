import Foundation

/// Exa Search API. POST https://api.exa.ai/search
struct ExaProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .exa

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .exa(let opts) = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        let urlStr = opts.customURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? "https://api.exa.ai/search"
            : opts.customURL
        guard let url = URL(string: urlStr) else { throw WebSearchProviderError.missingURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = common.timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["query": query, "numResults": common.resultSize]
        if opts.fetchFullText { body["contents"] = ["text": true] }
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
            let text = item["text"] as? String ?? (item["snippet"] as? String ?? "")
            return WebSearchResultItem(title: title, url: url, text: text)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
