import Foundation

/// Anthropic server-side web_search_tool_result 解析出来的源
/// MessageNode.webSourcesData 持久化 [WebSearchSource]，UI 在气泡底部 chip 横排显示。
struct WebSearchSource: Codable, Equatable, Hashable {
    let title: String
    let url: String
    let pageAge: String?

    init(title: String, url: String, pageAge: String? = nil) {
        self.title = title
        self.url = url
        self.pageAge = pageAge
    }
}
