import Foundation

/// 工具：读 URL → Markdown 全文。
/// 双轨：OpenAI 兼容 / Anthropic（仅 client function；Anthropic server tool 已自带搜+读，不再加 client browse_url）。
enum BrowseURLTool {
    static let toolName = "browse_url"

    private static let toolDescription = """
    读取一个网页 URL 的正文，返回 Markdown 格式。**联网搜索的"读"工具**。

    ### 何时调用
    - search_web 返回的 url 列表里挑 1-2 条权威/相关的源——绝不基于 search_web 的 snippet 直接答（snippet 只是 100 字索引摘要，不是答案）
    - 用户给你一个具体 URL 想了解内容
    - 需要查某个文档/wiki/新闻的详细信息时

    ### 配合 search_web
    正确流程：search_web(关键词) → 拿到 5-10 条候选 → 挑 1-2 条权威源 → browse_url(那个 url) → 看完整正文 → 回答 + [citation](index:id) 标 search 来源 + 必要时附原文链接

    ### 限制
    - 仅支持 http/https 公开页面（Phase 1 不支持登录态站点）
    - 单次返回最多 8000 字，超长会截断并提示
    - SPA / 极动态页面可能抽不到正文——失败时 fallback 到 search_web 的 snippet
    """

    private static let properties: [String: Any] = [
        "url": ["type": "string", "description": "要读的 URL，必须是 http:// 或 https:// 开头"],
    ]
    private static let required = ["url"]

    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: toolDescription, properties: properties, required: required)
    }

    // MARK: - 执行

    struct ExecResult {
        let text: String      // 回填给 tool result（Markdown or JSON 错误）
        let isError: Bool
    }

    @MainActor
    static func execute(inputJSON: String) async -> ExecResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        guard let urlStr = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlStr.isEmpty else {
            return ExecResult(text: errorJSON("browse_url 缺少 url 参数"), isError: true)
        }
        guard let url = URL(string: urlStr) else {
            return ExecResult(text: errorJSON("URL 解析失败：\(urlStr)"), isError: true)
        }

        do {
            let page = try await InternalBrowser.shared.read(url: url)
            return ExecResult(text: formatPage(page, url: url), isError: false)
        } catch let err as InternalBrowser.BrowseError {
            return ExecResult(text: errorJSON(err.localizedDescription), isError: true)
        } catch {
            return ExecResult(text: errorJSON("意外错误：\(error.localizedDescription)"), isError: true)
        }
    }

    /// 给模型看的格式：YAML-ish header + Markdown body
    private static func formatPage(_ page: InternalBrowser.ExtractedPage, url: URL) -> String {
        var out = "---\n"
        out += "url: \(url.absoluteString)\n"
        if !page.title.isEmpty { out += "title: \(page.title)\n" }
        if let byline = page.byline, !byline.isEmpty { out += "byline: \(byline)\n" }
        out += "length: \(page.length)\n"
        if page.truncated { out += "truncated: true\n" }
        if page.usedCookies > 0 {
            // 透明告知模型：本次读到的是登录态下的内容（cookie 数 > 0），可能含付费/私域内容
            out += "cookie: used (\(page.usedCookies))\n"
        }
        if let excerpt = page.excerpt, !excerpt.isEmpty { out += "excerpt: \(excerpt)\n" }
        out += "---\n\n"
        out += page.markdown
        return out
    }

    private static func errorJSON(_ msg: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: ["error": msg]), encoding: .utf8)) ?? "{\"error\":\"\(msg)\"}"
    }
}
