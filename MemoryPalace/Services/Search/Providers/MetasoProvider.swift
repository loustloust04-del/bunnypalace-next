import Foundation

/// 秘塔搜索 API. POST https://metaso.cn/api/v1/search
struct MetasoProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .metaso

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .metaso = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        guard let url = URL(string: "https://metaso.cn/api/v1/search") else { throw WebSearchProviderError.missingURL }

        let body: [String: Any] = [
            "q": query,
            "scope": "webpage",
            "size": common.resultSize,
            "includeSummary": false,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = common.timeout
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
        let webpages = (json["webpages"] as? [[String: Any]]) ?? []
        let items = webpages.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            let title = item["title"] as? String ?? ""
            let url = item["link"] as? String ?? ""
            guard !url.isEmpty else { return nil }
            let snippet = item["snippet"] as? String ?? ""
            return WebSearchResultItem(title: title.isEmpty ? url : title, url: url, text: snippet)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
