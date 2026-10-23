import Foundation
import SwiftSoup

/// Bing 网页抓取（无 API key）。
/// 参考 Kelivo bing_search_service.dart——选择器 `li.b_algo` + h2/a + .b_caption/.b_algoSlug。
/// 实测踩坑：
///  1. Bing 链接是 `https://www.bing.com/ck/a?...&u=a1<base64url>&ntb=1` 跳转壳，必须解 base64 才拿真实 URL；
///     不解的话 URL 全是 bing.com，引用点击没意义。
///  2. `.b_caption p` 在 Bing "deeplinks/扩展卡片" 结果里会吸到 maccaron 维基百科整段，必须硬截断字数。
struct BingLocalProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .bingLocal

    /// snippet 字数硬上限——v2 Phase 1：snippet 当索引摘要用，正文走 browse_url 拿
    /// 400 → 100：让模型清楚 snippet 不是答案，必须 browse_url 深读
    private static let snippetMax = 100

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .bingLocal(let opts) = options else { throw WebSearchProviderError.empty }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.bing.com/search?q=\(encoded)") else {
            throw WebSearchProviderError.missingURL
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = common.timeout
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue(opts.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchProviderError.decode("not UTF-8")
        }

        let doc = try SwiftSoup.parse(html)
        let blocks = try doc.select("li.b_algo")
        var items: [WebSearchResultItem] = []
        for el in blocks.array().prefix(common.resultSize) {
            guard let titleEl = try el.select("h2").first(),
                  let linkEl = try el.select("h2 > a").first() else { continue }
            let title = (try? titleEl.text()) ?? ""
            let rawHref = (try? linkEl.attr("href")) ?? ""
            guard !title.isEmpty, !rawHref.isEmpty else { continue }

            // 解 Bing redirect ck/a → 真实 URL
            let href = Self.decodeBingRedirect(rawHref)

            // snippet：用 .b_caption p:first-of-type 拿首段，硬截断 400 字
            // 避免 Bing deeplinks 子卡片把整段维基百科塞进同一 li.b_algo
            let snippetEl = try el.select(".b_caption p, .b_algoSlug").first()
            var snippet = (try? snippetEl?.text()) ?? ""
            if snippet.count > Self.snippetMax {
                snippet = String(snippet.prefix(Self.snippetMax)) + "…"
            }
            items.append(WebSearchResultItem(title: title, url: href, text: snippet))
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }

    /// Bing `ck/a?...&u=a1<base64url>&ntb=1` → 真实 URL
    /// `u=` 参数前两字符是 Bing 的版本 prefix（实测 "a1"），后面是 base64url 编码
    static func decodeBingRedirect(_ href: String) -> String {
        guard href.contains("/ck/a?") || href.contains("bing.com") else { return href }
        guard let comps = URLComponents(string: href),
              let uVal = comps.queryItems?.first(where: { $0.name == "u" })?.value else {
            return href
        }
        // 砍掉前缀（实测 "a1"，也兼容其他长度小前缀）
        let stripped: String
        if uVal.count > 2, uVal.hasPrefix("a") {
            stripped = String(uVal.dropFirst(2))
        } else {
            stripped = uVal
        }
        // base64url → base64
        var b64 = stripped.replacingOccurrences(of: "-", with: "+")
                          .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let decoded = String(data: data, encoding: .utf8),
              decoded.lowercased().hasPrefix("http") else {
            return href
        }
        return decoded
    }
}
