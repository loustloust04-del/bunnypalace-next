import Foundation

/// Jina Search API. POST https://s.jina.ai/
/// Jina 偶尔需要较长 timeout（Kelivo 设了 15s 下限），我们至少 10s。
struct JinaProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .jina

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .jina = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        guard let url = URL(string: "https://s.jina.ai/") else { throw WebSearchProviderError.missingURL }

        let body: [String: Any] = ["q": query]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Jina 慢，timeout 至少 10s
        req.timeoutInterval = max(common.timeout, 10.0)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchProviderError.decode("not JSON")
        }
        let raw = (json["data"] as? [[String: Any]]) ?? (json["results"] as? [[String: Any]]) ?? []
        let items = raw.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            guard let url = item["url"] as? String else { return nil }
            let title = item["title"] as? String ?? url
            let desc = item["description"] as? String ?? (item["content"] as? String ?? "")
            return WebSearchResultItem(title: title, url: url, text: desc)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
