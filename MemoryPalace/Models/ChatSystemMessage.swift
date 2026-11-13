import Foundation

enum ChatSystemMessage {
    struct Content: Equatable {
        let body: String
        let error: String?
        var notice: String? = nil
    }

    /// 报错写进正文时的开头：看不见的分隔符（U+2063）+ ⚠️。AI 正常回复里的「⚠️ 」不会被当成报错（plan-send-notice-marker B）
    static let errorMarker = "\u{2063}⚠️ "
    /// 这天之前的消息还认老标记「⚠️ 」（那时候报错就是这么存的）
    /// 分界定在改这天（不再往后留空档：留两天 = 这两天 AI 写的「⚠️ 」照样被拆，sim 实测撞上）。
    /// 代价：没装新包的设备在这之后写的报错，会显示成正文里的一行「⚠️ …」
    static let markerSince = Date(timeIntervalSince1970: 1_794_186_000)   // 2026-11-08 17:00 -08:00

    static func errorLine(_ text: String) -> String { errorMarker + text }

    static func usesLegacyMarker(_ createdAt: Date?) -> Bool { (createdAt ?? .distantPast) < markerSince }

    /// 仅分离段首或段落边界的末尾报错，不改存储原文。`legacy` = 老消息，也认没有分隔符的「⚠️ 」
    static func split(_ content: String, legacy: Bool) -> Content {
        for marker in legacy ? [errorMarker, "⚠️ "] : [errorMarker] {
            if content.hasPrefix(marker) { return Content(body: "", error: String(content.dropFirst(marker.count))) }
            if let range = content.range(of: "\n\n" + marker, options: .backwards) {
                return Content(body: String(content[..<range.lowerBound]), error: String(content[range.upperBound...]))
            }
        }
        let paragraphs = content.components(separatedBy: "\n\n")
        if let last = paragraphs.last, last == "（已停止）" ||
            last.hasPrefix("（工具调用达到上限") || last == "（预算收尾请求仍返回了工具调用，已结束。）" {
            return Content(body: paragraphs.dropLast().joined(separator: "\n\n"), error: nil,
                           notice: last.trimmingCharacters(in: CharacterSet(charactersIn: "（）")))
        }
        return Content(body: content, error: nil)
    }

    static func removingTrailingError(from segments: [MessageSegment], legacy: Bool) -> [MessageSegment] {
        guard case .text(let text)? = segments.last else { return segments }
        let content = split(text, legacy: legacy)
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
