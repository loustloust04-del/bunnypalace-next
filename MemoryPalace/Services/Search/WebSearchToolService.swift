import Foundation

/// 联网搜索工具——双轨：Anthropic 走 server tool (web_search_20250305)，其他 model 走 client function (search_web)。
/// 执行：按当前选中 provider 派发到具体 backend，结果加 id/index 后 JSON 回灌；模型用 `[citation](index:id)` 引用。
enum WebSearchToolService {
    static let toolName = "search_web"

    // MARK: - 双轨工具定义

    private static let toolDescription = """
    联网搜索——你**唯一**的联网通道。\
    用户问任何涉及实时信息（天气/新闻/今天/最近/最新/价格/赛事/演出/股价/汇率/版本号/上映时间…）\
    或你不确定的事实，**必须先调这个工具再回答**。\
    绝对不要说"我没联网功能/无法访问网络/无法查询实时信息"——你**有这个工具**就是用来联网的。\
    一次查清：用最可能命中的关键词，不要翻页式反复调用。\
    用结果时在引用内容后紧跟 `[citation](index:id)` 标注来源。
    """

    private static let properties: [String: Any] = [
        "query": ["type": "string", "description": "搜索关键词"],
    ]
    private static let required = ["query"]

    /// Client-side function——OpenAI 系用；anthropic 直连走下面的 server tool（注入处特例）
    static var clientDefinition: ToolDefinition {
        ToolDefinition(name: toolName, description: toolDescription, properties: properties, required: required)
    }

    /// Server-side tool——只有 .anthropic 直连用，Claude 后端自己执行搜索
    /// allowed_domains / blocked_domains / user_location 走配置面板（M2 后期暴露）
    static func anthropicServerTool(maxUses: Int = 5,
                                    allowedDomains: [String] = [],
                                    blockedDomains: [String] = []) -> [String: Any] {
        var entry: [String: Any] = [
            "type": "web_search_20250305",
            "name": "web_search",
            "max_uses": maxUses,
        ]
        if !allowedDomains.isEmpty { entry["allowed_domains"] = allowedDomains }
        if !blockedDomains.isEmpty { entry["blocked_domains"] = blockedDomains }
        return entry
    }

    // MARK: - system prompt（client-side 才用——教模型引用规范，带 assistantName）

    static func systemPrompt(assistantName: String) -> String {
        let name = assistantName.isEmpty ? "你" : assistantName
        return """
        ## 联网搜索（search_web + browse_url 双工具）

        \(name)，你有**两个联网工具**，**永远不要说"我没联网/无法访问网络/无法查询实时信息"**：
        - `search_web`：搜候选页面，返回标题 + URL + ≤100 字短摘要。**绝不基于摘要直接回答**——摘要是索引不是答案。
        - `browse_url`：读 URL 的网页正文，返回 Markdown 全文。

        ### 标准流程（先搜后读）
        用户问任何涉及实时信息（天气/新闻/今天/最近/价格/股价/汇率/比赛/演出/版本号/上映时间…）或你不确定的事实：
        1. `search_web(关键词)` → 拿候选 URL 列表
        2. 挑 1-2 条权威源（中国天气网 / 新华社 / 维基百科 / 官方网站 / 主流媒体 …）
        3. `browse_url(那个 url)` → 拿全文 Markdown
        4. 基于全文回答 + `[citation](index:id)` 标 search 来源 + 必要时附原文链接

        ### 引用格式
        搜索结果每项带 `index`（序号）和 `id`（唯一标识）。引用规则：
        - 用到搜索结果时，紧跟相关内容输出 `[citation](index:id)`，**不要堆到末尾**
          例：`今天北京晴，最高 28℃。[citation](1:a1b2c3) 明天有小雨。[citation](2:f4e5d6)`
        - 用到 browse_url 全文时：可在引用片段后写 `[来源](URL)`，或末尾附"参考：URL"

        ### 绝对不能做
        - ❌ 基于 search_web 100 字 snippet 直接回答——**必须 browse_url 拿全文**
        - ❌ 说"我没联网/无法访问网络"——你**有 search_web + browse_url 两个工具**
        - ❌ 查询范围太宽乱搜——先和用户确认主题

        ### 使用要点
        1. 一轮搜清——一次 search_web 用最可能命中的关键词
        2. browse_url 限 1-2 条，挑最权威源，不要每条都 browse
        3. browse_url 抽不到正文时（SPA/资源页）允许 fallback 到 search 的 snippet，但**明确告诉用户"未能读到正文"**
        """
    }

    // MARK: - 执行

    struct ExecResult {
        let text: String           // JSON 字符串，回填给 tool result
        let isError: Bool
    }

    @MainActor
    static func execute(inputJSON: String) async -> ExecResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return ExecResult(text: errorJSON("search_web 缺少 query 参数"), isError: true)
        }
        guard let options = WebSearchSettings.shared.selected else {
            return ExecResult(text: errorJSON("没有配置任何搜索服务"), isError: true)
        }

        do {
            let provider = try WebSearchProviderFactory.make(for: options)
            let raw = try await provider.search(
                query: query,
                common: WebSearchSettings.shared.commonOptions,
                options: options
            )
            let labeled = labelItems(raw.items)
            var dict: [String: Any] = ["items": labeled.map { itemToDict($0) }]
            if let a = raw.answer, !a.isEmpty { dict["answer"] = a }
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            return ExecResult(text: String(data: data, encoding: .utf8) ?? "{}", isError: false)
        } catch {
            return ExecResult(text: errorJSON("搜索失败: \(error.localizedDescription)"), isError: true)
        }
    }

    // MARK: - helpers

    /// 给每条结果加 6-char UUID id 和 1-based index
    static func labelItems(_ items: [WebSearchResultItem]) -> [WebSearchResultItem] {
        items.enumerated().map { (i, item) in
            WebSearchResultItem(
                title: item.title,
                url: normalizeURL(item.url),
                text: item.text,
                id: shortUUID(),
                index: i + 1
            )
        }
    }

    static func shortUUID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
    }

    /// 补 https://、trim、修裸域名等
    static func normalizeURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return s }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return s
    }

    private static func itemToDict(_ item: WebSearchResultItem) -> [String: Any] {
        var d: [String: Any] = [
            "title": item.title,
            "url": item.url,
            "text": item.text,
        ]
        if let id = item.id { d["id"] = id }
        if let idx = item.index { d["index"] = idx }
        return d
    }

    private static func errorJSON(_ msg: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: ["error": msg]), encoding: .utf8)) ?? "{\"error\":\"\(msg)\"}"
    }
}

/// 派发：按 WebSearchServiceOptions 的 kind 实例化对应 backend。
/// Phase A 占位 throw；Phase B/E/F/G 各家实现完成后填进 switch。
enum WebSearchProviderFactory {
    static func make(for options: WebSearchServiceOptions) throws -> WebSearchProvider {
        switch options.kind {
        case .bingLocal:    return BingLocalProvider()
        case .duckduckgo:   return DuckDuckGoProvider()
        case .brave:        return BraveProvider()
        case .tavily:       return TavilyProvider()
        case .exa:          return ExaProvider()
        case .perplexity:   return PerplexityProvider()
        case .linkup:       return LinkUpProvider()
        case .jina:         return JinaProvider()
        case .zhipu:        return ZhipuProvider()
        case .bocha:        return BochaProvider()
        case .metaso:       return MetasoProvider()
        case .searxng:      return SearXNGProvider()
        case .ollama:       return OllamaProvider()
        }
    }
}
