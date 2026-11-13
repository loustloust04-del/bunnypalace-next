import Foundation

/// 窗口透视：把一轮预览（TurnPreview 的 segments / tools）归成「一行一类」。纯函数，token 是本地估算。
struct ContextLensRow: Identifiable, Equatable {
    struct Item: Identifiable, Equatable {
        let id: Int
        let title: String
        let tokens: Int
        let text: String
    }

    let id: String
    let title: String
    let tokens: Int
    /// 行尾的小字（「12 条」「28 个」）
    let countText: String
    let items: [Item]
}

enum ContextLens {
    static func rows(segments: [TaggedSegment], tools: [[String: Any]]?, tuckedTools: [String]) -> [ContextLensRow] {
        var buckets: [String: [TaggedSegment]] = [:]
        for segment in segments { buckets[groupId(segment.source), default: []].append(segment) }

        var rows: [ContextLensRow] = []
        for (id, title, unit) in groups {
            guard let members = buckets[id], !members.isEmpty else { continue }
            let items = members.enumerated().map { index, segment in
                ContextLensRow.Item(id: index, title: itemTitle(segment), tokens: TokenEstimator.estimate(segment.content), text: segment.content)
            }
            rows.append(ContextLensRow(id: id, title: title, tokens: items.reduce(0) { $0 + $1.tokens },
                                       countText: "\(members.count) \(unit)",
                                       // 对话历史就是聊天页上那些消息，不逐条再列一遍
                                       items: id == "history" ? [] : items))
        }

        if let tools, !tools.isEmpty {
            let items = tools.enumerated().map { index, tool -> ContextLensRow.Item in
                let json = (try? JSONSerialization.data(withJSONObject: tool, options: [.sortedKeys, .prettyPrinted]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                return ContextLensRow.Item(id: index, title: toolName(tool), tokens: json.isEmpty ? 0 : TokenEstimator.estimate(json), text: json)
            }
            let tucked = tuckedTools.isEmpty ? "" : "，另有 \(tuckedTools.count) 个收在「更多工具」"
            rows.append(ContextLensRow(id: "tools", title: "工具", tokens: items.reduce(0) { $0 + $1.tokens },
                                       countText: "\(tools.count) 个\(tucked)", items: items))
        }
        return rows
    }

    static func toolName(_ tool: [String: Any]) -> String {
        if let name = tool["name"] as? String { return name }
        if let function = tool["function"] as? [String: Any], let name = function["name"] as? String { return name }
        return tool["type"] as? String ?? "?"
    }

    private static let groups: [(id: String, title: String, unit: String)] = [
        ("history", "对话历史", "条"),
        ("slots", "预设插槽", "段"),
        ("worldBook", "世界书", "条"),
        ("memory", "记忆", "段"),
        ("summary", "上下文摘要", "段"),
        ("timeline", "时间轴", "段"),
        ("files", "文件库", "段"),
        ("other", "其它", "段"),
    ]

    private static func groupId(_ source: SegmentSource) -> String {
        switch source {
        case .chatHistory: return "history"
        case .slot: return "slots"
        case .worldBook: return "worldBook"
        case .memory, .userProfile: return "memory"
        case .contextSummary: return "summary"
        case .timeline: return "timeline"
        case .fileLibrary: return "files"
        case .dialogueExample, .volatileContext, .style, .cardGuide, .folder: return "other"
        }
    }

    private static func itemTitle(_ segment: TaggedSegment) -> String {
        if case .worldBook(let name) = segment.source { return name }
        return segment.source.displayName
    }
}
