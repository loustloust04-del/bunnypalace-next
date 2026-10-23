import Foundation

/// SearXNG 自建实例 API. GET <baseURL>/search?q=...&format=json
/// 可选 basic auth：username 走 options，password 走 Keychain key
struct SearXNGProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .searxng

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .searxng(let opts) = options else { throw WebSearchProviderError.empty }
        let rawURL = opts.customURL.trimmingCharacters(in: .whitespaces)
        guard !rawURL.isEmpty else { throw WebSearchProviderError.missingURL }

        let base = rawURL.hasSuffix("/") ? String(rawURL.dropLast()) : rawURL
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var urlStr = "\(base)/search?q=\(encoded)&format=json"
        if !opts.engines.isEmpty {
            urlStr += "&engines=\(opts.engines.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        if !opts.language.isEmpty {
            urlStr += "&language=\(opts.language.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        guard let url = URL(string: urlStr) else { throw WebSearchProviderError.missingURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = common.timeout

        // Basic auth：username + key（key 当 password 用）
        let password = (await MainActor.run { WebSearchSettings.shared.apiKey(for: options) }) ?? ""
        if !opts.username.isEmpty, !password.isEmpty {
            let pair = "\(opts.username):\(password)"
            if let data = pair.data(using: .utf8) {
                req.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchProviderError.decode("not JSON")
        }
        let raw = (json["results"] as? [[String: Any]]) ?? []
        let items = raw.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            let content = item["content"] as? String ?? ""
            return WebSearchResultItem(title: title, url: url, text: content)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }
}
