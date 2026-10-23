import CryptoKit
import Foundation

/// Gemini Takeout / AI Studio 解析结果（#047）：payload 交给 #043 写库引擎，计数进预览和结果卡 notes。
struct GeminiImportResult {
    var payloads: [ImportedConversationPayload] = []
    /// Takeout：认出的 Gemini 活动条数
    var activityCount = 0
    /// Takeout：混合导出里其他 Google 产品的活动
    var otherProductCount = 0
    var explicitConversationCount = 0
    var inferredConversationCount = 0
    var missingResponseCount = 0
    /// 认不出是不是提问的活动（plan D4）：有回答只导回答，没回答跳过
    var unconfirmedPromptCount = 0
    var attachmentPlaceholderCount = 0
    var unreadableTimeCount = 0
    var unknownRoleCount = 0
    /// AI Studio：内嵌图片解不出 / 超限，换成占位
    var droppedImageCount = 0
    /// AI Studio：工具调用 / 结果等暂不显示的消息（保留为隐藏消息）
    var unsupportedMessageCount = 0
    /// 只在 addCounts 累加时用：被加进来的结果的对话段数
    var conversationCount = 0
    /// 只在 addCounts 累加时用：对话 id（预览先查跨楼层冲突，#061）
    var conversationIds: [String] = []

    /// 预览 / 结果卡把多个文件的计数加在一起（payload 不带：导入时重新解析）
    mutating func addCounts(of other: GeminiImportResult) {
        conversationCount += other.conversationCount + other.payloads.count
        conversationIds += other.conversationIds + other.payloads.map(\.id)
        activityCount += other.activityCount
        otherProductCount += other.otherProductCount
        explicitConversationCount += other.explicitConversationCount
        inferredConversationCount += other.inferredConversationCount
        missingResponseCount += other.missingResponseCount
        unconfirmedPromptCount += other.unconfirmedPromptCount
        attachmentPlaceholderCount += other.attachmentPlaceholderCount
        unreadableTimeCount += other.unreadableTimeCount
        unknownRoleCount += other.unknownRoleCount
        droppedImageCount += other.droppedImageCount
        unsupportedMessageCount += other.unsupportedMessageCount
    }

    var notes: [String] {
        var out: [String] = []
        if inferredConversationCount > 0 { out.append("\(inferredConversationCount) 段对话是按时间间隔推测切分的，不是 Gemini 原来的会话") }
        if missingResponseCount > 0 { out.append("\(missingResponseCount) 条提问在导出里没有回答") }
        if unconfirmedPromptCount > 0 { out.append("\(unconfirmedPromptCount) 条活动认不出提问，只导了回答或跳过") }
        if attachmentPlaceholderCount > 0 { out.append("\(attachmentPlaceholderCount) 个附件只放了带名字的占位") }
        if droppedImageCount > 0 { out.append("\(droppedImageCount) 张内嵌图片读不出或过大，换成了占位") }
        if unreadableTimeCount > 0 { out.append("\(unreadableTimeCount) 条记录读不出时间，位置按导出里的前后关系排") }
        if unsupportedMessageCount > 0 { out.append("\(unsupportedMessageCount) 条消息是工具调用等暂不支持显示的内容，已保留但不显示") }
        if unknownRoleCount > 0 { out.append("\(unknownRoleCount) 条消息角色不认识，已保留但不显示") }
        if otherProductCount > 0 { out.append("跳过其他 Google 产品的活动 \(otherProductCount) 条") }
        return out
    }
}

enum GeminiImportError: Error, Equatable {
    case notRecognized
}

enum GeminiImportSupport {
    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func strippingBOM(_ data: Data) -> Data {
        data.starts(with: utf8BOM) ? data.dropFirst(utf8BOM.count) : data
    }

    static func jsonObject(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: strippingBOM(data), options: [.fragmentsAllowed])
    }

    static func shortHash(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static let isoBase: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoParts = try! Regex(#"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$"#)

    /// ISO 8601：Z / ±hh:mm、任意位小数秒（Takeout 可到微秒，ISO8601DateFormatter 小数位数不稳）
    static func parseISO(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let m = try? isoParts.wholeMatch(in: raw),
              let base = m.output[1].substring, let zone = m.output[3].substring,
              let date = isoBase.date(from: String(base) + String(zone)) else { return nil }
        guard let frac = m.output[2].substring, let fraction = Double("0" + frac) else { return date }
        return date.addingTimeInterval(fraction)
    }

    /// 段落编码固定键序：写库引擎叠加导入时按字节比 segmentsData，JSONEncoder 默认键序不稳，同样的内容会被当成「改过」
    static func encodeSegments(_ segments: [MessageSegment]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(segments)
    }

    static func jsonData(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func titleSnippet(_ text: String, limit: Int = 40) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    static func node(id: String, role: String, segments: [MessageSegment], time: Date?, parentId: String?,
                     childId: String?, metadata: Data?, visibility: String? = nil) -> ImportedNodePayload {
        ImportedNodePayload(
            id: id,
            role: role,
            content: ClaudeImporter.flattenSegmentsForSearch(segments),
            contentType: "segmented",
            createTime: time,
            parentId: parentId,
            childrenIds: childId.map { [$0] } ?? [],
            segmentsData: encodeSegments(segments),
            sourceMetadata: metadata,
            sourceVisibility: visibility
        )
    }

    struct ChainItem {
        let id: String
        let role: String
        let segments: [MessageSegment]
        let time: Date?
        let metadata: Data?
        var visibility: String? = nil
    }

    /// 一串消息 → 直链（parent = 上一条，children = 下一条）
    static func chain(_ items: [ChainItem]) -> [ImportedNodePayload] {
        var nodes: [ImportedNodePayload] = []
        for (i, item) in items.enumerated() {
            let parentId: String? = i > 0 ? items[i - 1].id : nil
            let childId: String? = i + 1 < items.count ? items[i + 1].id : nil
            nodes.append(node(id: item.id, role: item.role, segments: item.segments, time: item.time,
                              parentId: parentId, childId: childId, metadata: item.metadata, visibility: item.visibility))
        }
        return nodes
    }
}
