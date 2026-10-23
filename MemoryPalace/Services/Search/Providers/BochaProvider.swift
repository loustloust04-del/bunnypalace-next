import Foundation

/// 博查搜索（百度系）. POST https://api.bochaai.com/v1/web-search
/// 外层有 `code: 200` 校验，code != 200 视作错误。
struct BochaProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .bocha

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .bocha(let opts) = options else { throw WebSearchProviderError.empty }
        guard let key = await MainActor.run(body: { WebSearchSettings.shared.apiKey(for: options) }), !key.isEmpty else {
            throw WebSearchProviderError.missingAPIKey
        }
        guard let url = URL(string: "https://api.bochaai.com/v1/web-search") else { throw WebSearchProviderError.missingURL }

        var body: [String: Any] = [
            "query": query,
            "summary": opts.summary,
            "count": common.resultSize,
        ]
        if !opts.freshness.isEmpty, opts.freshness != "noLimit" {
            body["freshness"] = opts.freshness
        }
        let inc = opts.includeDomains.trimmingCharacters(in: .whitespaces)
        if !inc.isEmpty { body["include"] = inc }
        let exc = opts.excludeDomains.trimmingCharacters(in: .whitespaces)
        if !exc.isEmpty { body["exclude"] = exc }

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
        if let code = json["code"] as? Int, code != 200 {
            throw WebSearchProviderError.http(code, json["msg"] as? String ?? "code != 200")
        }
        let d = json["data"] as? [String: Any] ?? [:]
        let webPages = d["webPages"] as? [String: Any] ?? [:]
        let value = webPages["value"] as? [[String: Any]] ?? []
        let items = value.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            let title = item["name"] as? String ?? ""
            let url = item["url"] as? String ?? ""
            guard !url.isEmpty else { return nil }
            let text = (item["summary"] as? String) ?? (item["snippet"] as? String) ?? ""
            return WebSearchResultItem(title: title.isEmpty ? url : title, url: url, text: text)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
