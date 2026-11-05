import Foundation

/// 编目专用正文；不改变搜索框或已有索引。必须在持有 node 的 ModelContext 内调用。
enum CatalogOriginalText {
    static func body(of node: MessageNode) -> String {
        guard node.role == "user" || node.role == "assistant" else { return "" }
        let text: String
        if node.segmentsData != nil {
            // 有结构却解不开时，不相信供旧搜索使用的扁平 content。
            guard let segments = node.segments else { return "" }
            if node.role == "assistant", node.contentType == "text", !segments.isEmpty,
               segments.allSatisfy({ if case .audioRef = $0 { return true }; return false }) {
                // 原生回复后挂语音条：正文仍在 content，script 不是正文。
                text = node.content
            } else {
                text = segments.compactMap { segment in
                    if case .text(let value) = segment { return value }
                    return nil
                }.joined(separator: "\n\n")
            }
        } else {
            switch node.contentType {
            case "segmented", "multimodal_text", "image_asset_pointer", "thoughts", "reasoning_recap",
                 "execution_output", "computer_output", "tether_browsing_display", "tether_quote", "system_error":
                return ""
            default:
                text = node.content
            }
        }
        return cleanedBody(text)
    }

    private static func cleanedBody(_ text: String) -> String {
        var body = text
        // 只认已落盘的明确思考标记；缺闭合/嵌套损坏时不回退到含思考的原串。
        for (open, close) in [("<<<THINK>>>", "<<</THINK>>>"), ("[thinking]", "[/thinking]")] {
            while let start = body.range(of: open, options: .caseInsensitive) {
                guard let end = body.range(of: close, options: .caseInsensitive, range: start.upperBound..<body.endIndex),
                      body.range(of: open, options: .caseInsensitive, range: start.upperBound..<end.lowerBound) == nil,
                      body.range(of: close, options: .caseInsensitive, range: body.startIndex..<start.lowerBound) == nil
                else { return "" }
                body.removeSubrange(start.lowerBound..<end.upperBound)
            }
            guard body.range(of: close, options: .caseInsensitive) == nil else { return "" }
        }
        // 沿用原生兼容路：仅开头的 <think> 是思考，正文中引用该标签不猜测。
        var splitter = LeadingThinkTagSplitter()
        var reasoning = ReasoningCapture()
        body = splitter.feed(body, into: &reasoning, enabled: true) + splitter.flush(into: &reasoning)
        return ContentCleaner.clean(body, cached: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
