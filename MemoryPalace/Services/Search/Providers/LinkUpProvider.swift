import Foundation

/// LinkUp Search API. POST https://api.linkup.so/v1/search
struct LinkUpProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .linkup

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .linkup(let opts) = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        guard let url = URL(string: "https://api.linkup.so/v1/search") else { throw WebSearchProviderError.missingURL }

        let body: [String: Any] = [
            "q": query,
            "depth": opts.depth.isEmpty ? "standard" : opts.depth,
            "outputType": "sourcedAnswer",
            "includeImages": "false",
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
        let sources = (json["sources"] as? [[String: Any]]) ?? []
        let items = sources.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            guard let url = item["url"] as? String else { return nil }
            let title = item["name"] as? String ?? url
            let snippet = item["snippet"] as? String ?? ""
            return WebSearchResultItem(title: title, url: url, text: snippet)
        }
        let answer = json["answer"] as? String
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(answer: answer, items: items)
    }
}
