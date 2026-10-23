import Foundation
import SwiftSoup

/// DuckDuckGo HTML 端点（无 API key）。
/// Kelivo 用 ddgs Dart 包，Swift 没等价物——直接抓 `html.duckduckgo.com/html/`。
/// 字段 fallback 多：DDG HTML 结构改过几版，给 a.result__a / .result__title > a / .result__snippet 都试。
struct DuckDuckGoProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .duckduckgo

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .duckduckgo(let opts) = options else { throw WebSearchProviderError.empty }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kl", value: opts.region.isEmpty ? "wt-wt" : opts.region),
        ]
        _ = encoded
        guard let url = components.url else { throw WebSearchProviderError.missingURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = common.timeout
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchProviderError.decode("not UTF-8")
        }

        let doc = try SwiftSoup.parse(html)
        let blocks = try doc.select(".result, .web-result")
        var items: [WebSearchResultItem] = []
        for el in blocks.array().prefix(common.resultSize) {
            let titleEl = try el.select("a.result__a, .result__title a").first()
            let title = (try? titleEl?.text()) ?? ""
            var href = (try? titleEl?.attr("href")) ?? ""
            // DDG 经常包 redirect: /l/?uddg=ENCODED — 解出来
            href = decodeDDGRedirect(href)
            let snippet = (try? el.select(".result__snippet").first()?.text()) ?? ""
            guard !title.isEmpty, !href.isEmpty else { continue }
            items.append(WebSearchResultItem(title: title, url: href, text: snippet))
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }

    /// DDG 用 `/l/?uddg=<url-encoded>` 包跳转——拆开拿真实 url
    private func decodeDDGRedirect(_ href: String) -> String {
        guard href.contains("/l/?") || href.hasPrefix("//duckduckgo.com/l/") else { return href }
        let full = href.hasPrefix("//") ? "https:\(href)" : href
        guard let comps = URLComponents(string: full),
              let q = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
              let decoded = q.removingPercentEncoding else { return href }
        return decoded
    }
}
