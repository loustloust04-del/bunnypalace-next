import Foundation

enum ChatSystemMessage {
    struct Content: Equatable {
        let body: String
        let error: String?
        var notice: String? = nil
    }

    /// 兼容已有发送失败标记，仅分离段首或段落边界的末尾报错，不改存储原文。
    static func split(_ content: String) -> Content {
        let marker = "⚠️ "
        if content.hasPrefix(marker) { return Content(body: "", error: String(content.dropFirst(marker.count))) }
        if let range = content.range(of: "\n\n⚠️ ", options: .backwards) {
            return Content(body: String(content[..<range.lowerBound]), error: String(content[range.upperBound...]))
        }
        let paragraphs = content.components(separatedBy: "\n\n")
        if let last = paragraphs.last, last == "（已停止）" ||
            last.hasPrefix("（工具调用达到上限") || last == "（预算收尾请求仍返回了工具调用，已结束。）" {
            return Content(body: paragraphs.dropLast().joined(separator: "\n\n"), error: nil,
                           notice: last.trimmingCharacters(in: CharacterSet(charactersIn: "（）")))
        }
        return Content(body: content, error: nil)
    }

    static func removingTrailingError(from segments: [MessageSegment]) -> [MessageSegment] {
        guard case .text(let text)? = segments.last else { return segments }
        let content = split(text)
        guard content.error != nil || content.notice != nil else { return segments }
        return Array(segments.dropLast()) + (content.body.isEmpty ? [] : [.text(content.body)])
    }

    static func noticeText(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter {
            !($0.properties.isEmoji && $0.value > 0x2000) && $0.value != 0xFE0F
        }
        return String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
