import Foundation

/// Perplexity Search API. POST https://api.perplexity.ai/search
/// 结果可能嵌套（多 query）——展平后取前 N 条。
struct PerplexityProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .perplexity

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .perplexity(let opts) = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        guard let url = URL(string: "https://api.perplexity.ai/search") else { throw WebSearchProviderError.missingURL }

        var body: [String: Any] = [
            "query": query,
            "max_results": max(1, min(common.resultSize, 20))
        ]
        let country = opts.country.trimmingCharacters(in: .whitespaces)
        if !country.isEmpty { body["country"] = country }
        if !opts.allowedDomains.isEmpty { body["search_domain_filter"] = opts.allowedDomains }
        if opts.maxTokensPerPage > 0 { body["max_tokens_per_page"] = opts.maxTokensPerPage }

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

        // results 可能是 [Any]，里面元素可能是 [String:Any] 也可能是 [[String:Any]]（嵌套）
        var flat: [[String: Any]] = []
        if let raw = json["results"] as? [Any] {
            for item in raw {
                if let dict = item as? [String: Any] { flat.append(dict) }
                else if let arr = item as? [[String: Any]] { flat.append(contentsOf: arr) }
            }
        }
        let items = flat.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            let snippet = item["snippet"] as? String ?? (item["text"] as? String ?? "")
            return WebSearchResultItem(title: title, url: url, text: snippet)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
