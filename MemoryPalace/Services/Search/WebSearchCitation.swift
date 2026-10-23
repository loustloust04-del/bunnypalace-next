import Foundation

/// 给 markdown link handler 用：从 message segments 里找 search_web tool 结果，按 `index:id` 反查真实 URL。
/// 3 层 fallback（抄 Kelivo chat_message_widget.dart:2066-2134）：
/// 1. UUID id 精确匹配
/// 2. id 是纯数字 → 按 index 匹配
/// 3. id 看起来像 URL → 直接打开
enum WebSearchCitation {
    /// 从 segments 里提取所有 search_web tool 的 result item
    /// 配对：toolUse(id, name) + toolResult(toolUseId=id, text) → 只保留 name=="search_web" 的 toolResult.text
    static func collectItems(from segments: [MessageSegment]) -> [WebSearchResultItem] {
        var nameByUseId: [String: String] = [:]
        for s in segments {
            if case .toolUse(let id, let name, _, _, _) = s { nameByUseId[id] = name }
        }
        var items: [WebSearchResultItem] = []
        for s in segments {
            if case .toolResult(let toolUseId, let text, let isError, _) = s,
               nameByUseId[toolUseId] == WebSearchToolService.toolName, !isError {
                items.append(contentsOf: parseItems(json: text))
            }
        }
        return items
    }

    /// 解析单个 search_web tool result JSON
    static func parseItems(json: String) -> [WebSearchResultItem] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["items"] as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let url = dict["url"] as? String else { return nil }
            let text = dict["text"] as? String ?? ""
            let id = dict["id"] as? String
            let index: Int?
            if let i = dict["index"] as? Int { index = i }
            else if let s = dict["index"] as? String, let i = Int(s) { index = i }
            else { index = nil }
            return WebSearchResultItem(title: title, url: url, text: text, id: id, index: index)
        }
    }

    /// 给定 markdown link 的 URL 字符串，3 层 fallback 找真实 URL
    /// 解析模型输出 `[citation](1:a1b2c3)` 等 → URL 字符串 `1:a1b2c3`
    /// 也兼容 `[citation](a1b2c3)` 纯 id / 整数 index
    static func resolve(linkURL: String, items: [WebSearchResultItem]) -> String? {
        let trimmed = linkURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 1) `<index>:<id>` 形式
        if let colon = trimmed.firstIndex(of: ":") {
            let idxStr = String(trimmed[..<colon])
            let idStr = String(trimmed[trimmed.index(after: colon)...])
            if let match = items.first(where: { $0.id == idStr }) {
                return match.url
            }
            if let idx = Int(idxStr), let match = items.first(where: { $0.index == idx }) {
                return match.url
            }
        }

        // 2) 纯 id 形式（无冒号）
        if let match = items.first(where: { $0.id == trimmed }) {
            return match.url
        }

        // 3) 纯数字当 index
        if let idx = Int(trimmed), let match = items.first(where: { $0.index == idx }) {
            return match.url
        }

        // 4) 看起来像 URL：fallback 直接用
        if trimmed.contains("/") || trimmed.contains(".") {
            return trimmed
        }
        return nil
    }
}
