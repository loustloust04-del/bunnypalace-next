import Foundation

/// 编目专用正文（读侧口径）。app 侧另有一个收 `MessageNode` 的便利重载，内部转值类型后调这里。
public enum CatalogOriginalText {
    public static func body(of message: ConversationMessage) -> String {
        body(of: message, clean: { ContentCleaner.clean($0, cached: false) })
    }

    /// 写手用的缓存版本；分段选择与 `body(of:)` 同一逻辑，仅清洗这一步走缓存（键规矩 `source == text`）。
    public static func body(of message: ConversationMessage, cacheKey: String) -> String {
        body(of: message, clean: { ContentCleaner.clean($0, cacheKey: cacheKey) })
    }

    private static func body(of message: ConversationMessage, clean: (String) -> String) -> String {
        guard message.role == "user" || message.role == "assistant" else { return "" }
        let text: String
        if let segments = message.segments {
            if message.role == "assistant", message.contentType == "text", !segments.isEmpty,
               segments.allSatisfy({ if case .audioRef = $0 { return true }; return false }) {
                // 原生回复后挂语音条：正文仍在 content，script 不是正文。
                text = message.content
            } else {
                text = segments.compactMap { segment in
                    if case .text(let value) = segment { return value }
                    return nil
                }.joined(separator: "\n\n")
            }
        } else {
            switch message.contentType {
            case "segmented", "multimodal_text", "image_asset_pointer", "thoughts", "reasoning_recap",
                 "execution_output", "computer_output", "tether_browsing_display", "tether_quote", "system_error":
                return ""
            default:
                text = message.content
            }
        }
        return cleanedBody(text, clean: clean)
    }

    private static func cleanedBody(_ text: String, clean: (String) -> String) -> String {
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
        body = stripLeadingThink(body)
        return clean(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `LeadingThinkTagSplitter` 整串喂完 + flush 的等价结果：
    /// 开头（允许前置空白）是 `<think>` 就剥到第一个 `</think>`，没闭合返回空；其余原样返回。
    private static func stripLeadingThink(_ text: String) -> String {
        let open = "<think>"
        let close = "</think>"
        let lead = text.drop(while: \.isWhitespace)
        guard lead.count >= open.count, lead.hasPrefix(open) else { return text }
        let rest = lead.dropFirst(open.count)
        guard let end = rest.range(of: close) else { return "" }
        return String(rest[end.upperBound...].drop(while: \.isWhitespace))
    }
}
