import Foundation
import SwiftData

/// Claude.ai 导出（conversations.json / design_chats）→ 导入 payload。
/// 写库走 `PayloadImportEngine`（#043 D10），这里只管解析。
/// Content blocks: text, thinking, tool_use, tool_result, flag, image, document, voice_note
enum ClaudeImporter {
    // MARK: - 日期解析（兼容 Claude 最新导出的微秒时间戳）

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 解析 Claude 导出时间戳。新格式带微秒（"...:21.893586Z"），`.iso8601` 默认不认小数秒，
    /// 这里把小数秒截到毫秒（3 位）再用 withFractionalSeconds，fallback 到整秒。
    static func parseClaudeDate(_ s: String) -> Date? {
        var str = s
        if let dot = str.firstIndex(of: ".") {
            let afterDot = str.index(after: dot)
            if let tz = str[afterDot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                let frac = str[afterDot..<tz]
                if frac.count > 3 {
                    str = String(str[..<afterDot]) + String(frac.prefix(3)) + String(str[tz...])
                }
            }
        }
        return iso8601WithFraction.date(from: str) ?? iso8601Plain.date(from: s)
    }

    static func makeClaudeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let d = Self.parseClaudeDate(s) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath,
                    debugDescription: "无法解析 Claude 日期: \(s)"))
            }
            return d
        }
        return decoder
    }


    // MARK: - 对话文件 → payload

    /// 读一个 conversations.json。转 payload 由调用方按批做（不同时在内存里放两份）。
    static func load(file url: URL) throws -> [ClaudeRawConversation] {
        try makeClaudeDecoder().decode([ClaudeRawConversation].self, from: try ExportJSON.data(at: url))
    }

    /// nil = 没有有效内容（计未导入）。`folderIdByProject`：对话自带 project_uuid / project.uuid 时
    /// 归进对应文件夹（D7）。
    static func payload(from raw: ClaudeRawConversation, folderIdByProject: [String: String]) -> ImportedConversationPayload? {
        guard var payload = makePayload(from: raw) else { return nil }
        if let project = raw.project_uuid ?? raw.project?.uuid {
            payload.folderId = folderIdByProject[project]
        }
        return payload
    }

    static func makePayload(from raw: ClaudeRawConversation) -> ImportedConversationPayload? {
        let messages = raw.chat_messages ?? []
        guard !messages.isEmpty else { return nil }

        // Parent 解析：优先 export 自带的 parent_message_uuid，fallback 到 index-1 的 linear 假设。
        func resolveParentId(at index: Int) -> String? {
            let msg = messages[index]
            if let p = msg.parent_message_uuid, !p.isEmpty {
                return p
            }
            return index == 0 ? nil : messages[index - 1].uuid
        }

        // 反向建 childrenIds：parent -> [child uuid]，按 messages 顺序排（保留 Claude 排序）。
        var childrenByParent: [String: [String]] = [:]
        for (idx, msg) in messages.enumerated() {
            if let pid = resolveParentId(at: idx) {
                childrenByParent[pid, default: []].append(msg.uuid)
            }
        }

        let encoder = segmentsEncoder()
        let nodes = messages.enumerated().map { index, msg -> ImportedNodePayload in
            let segments = Self.extractSegments(from: msg)
            let flatContent = Self.flattenSegmentsForSearch(segments)
            let segmentsData = try? encoder.encode(segments)
            return ImportedNodePayload(
                id: msg.uuid,
                role: mapSender(msg.sender),
                content: flatContent,
                contentType: "segmented",
                createTime: msg.created_at,
                parentId: resolveParentId(at: index),
                childrenIds: childrenByParent[msg.uuid] ?? [],
                segmentsData: segmentsData
            )
        }

        let hasDisplayableNodes = nodes.contains {
            isDisplayableNode(role: $0.role, content: $0.content)
        }
        guard hasDisplayableNodes else { return nil }

        let trimmedTitle = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 导出带 current_leaf_message_uuid（有重新生成分支时）就停在那条；没有退回最后一条
        let leaf = raw.current_leaf_message_uuid.flatMap { id in messages.contains { $0.uuid == id } ? id : nil }

        return ImportedConversationPayload(
            id: raw.uuid,
            title: trimmedTitle.isEmpty ? "无标题" : trimmedTitle,
            createTime: raw.created_at ?? Date.distantPast,
            updateTime: raw.updated_at ?? Date.distantPast,
            currentNodeId: leaf ?? messages.last?.uuid ?? "",
            provider: "claude",
            nodes: nodes
        )
    }

    /// 键排序：同样的分段每次编出同样的字节。叠加导入按 segmentsData 字节比较判断「改没改」，
    /// 键序不定会把没变的对话也判成更新（#043 回归护栏抓到的旧问题）
    private static func segmentsEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static func mapSender(_ sender: String?) -> String {
        switch sender {
        case "human": return "user"
        case "assistant": return "assistant"
        default: return sender ?? "unknown"
        }
    }

    // MARK: - 设计对话（design_chats/<uuid>.json，另一套结构）

    /// 设计对话自带的项目（不在 projects/ 里，是另一套「设计项目」），给 D7 建文件夹用
    static func designProjects(_ urls: [URL]) -> [(uuid: String, name: String)] {
        var seen = Set<String>()
        var out: [(uuid: String, name: String)] = []
        for url in urls {
            guard let chat = loadDesignChat(url), let project = chat.project, let id = project.uuid,
                  seen.insert(id).inserted else { continue }
            out.append((id, project.name ?? ""))
        }
        return out
    }

    static func loadDesignChat(_ url: URL) -> ClaudeDesignChat? {
        guard let data = try? ExportJSON.data(at: url) else { return nil }
        return try? makeClaudeDecoder().decode(ClaudeDesignChat.self, from: data)
    }

    /// 消息线性串起来；附件带 content 的进 `.attachment`，只有 path 的进 `.file`
    static func makeDesignChatPayload(_ chat: ClaudeDesignChat, folderIdByProject: [String: String] = [:]) -> ImportedConversationPayload? {
        let messages = (chat.messages ?? []).filter { !$0.uuid.isEmpty }
        guard !messages.isEmpty else { return nil }
        let encoder = segmentsEncoder()
        let nodes = messages.enumerated().map { index, msg -> ImportedNodePayload in
            var segs: [MessageSegment] = []
            if let text = msg.content?.content, !text.isEmpty { segs.append(.text(text)) }
            for att in msg.content?.attachments ?? [] {
                let name = att.name ?? ""
                if let body = att.content, !body.isEmpty {
                    segs.append(.attachment(name: name, type: att.type, extractedContent: body))
                } else if !name.isEmpty {
                    segs.append(.file(name: name, uuid: att.id ?? ""))
                }
            }
            let role = msg.role ?? msg.content?.role ?? "unknown"
            return ImportedNodePayload(
                id: msg.uuid,
                role: role == "human" ? "user" : role,
                content: flattenSegmentsForSearch(segs),
                contentType: "segmented",
                createTime: msg.created_at,
                parentId: index == 0 ? nil : messages[index - 1].uuid,
                childrenIds: index + 1 < messages.count ? [messages[index + 1].uuid] : [],
                segmentsData: try? encoder.encode(segs)
            )
        }
        guard nodes.contains(where: { isDisplayableNode(role: $0.role, content: $0.content) }) else { return nil }
        let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var payload = ImportedConversationPayload(
            id: chat.uuid,
            title: title.isEmpty ? "无标题" : title,
            createTime: chat.created_at ?? messages.first?.created_at ?? .distantPast,
            updateTime: chat.updated_at ?? messages.last?.created_at ?? .distantPast,
            currentNodeId: messages.last?.uuid ?? "",
            provider: "claude",
            nodes: nodes
        )
        if let project = chat.project?.uuid { payload.folderId = folderIdByProject[project] }
        return payload
    }

    // MARK: - V2: Structured segments

    /// 把 Claude 原始 chat_message 按 `content[]` 顺序解析为结构化分段数组。
    /// 规则：
    /// - `msg.content` 非空 → 只用 content[]（msg.text 是客户端拍平的冗余文本，100% 数据验证过）
    /// - `msg.content` 空且 `msg.text` 非空 → fallback 单个 `.text(msg.text)`（防御未来导出版本）
    /// - `attachments[]` / `files[]` 作为独立段追加到末尾（粟粟决策 3）
    /// - `image` / `document` 块（2026 新版导出）在原位置插 `.file`；它们的 uuid 同时在 `files[]` 里，
    ///   末尾不再重复追加（导出包不带图片 / 文件字节，只有名字和 uuid）
    /// - 未知 block type 跳过（不丢数据，也不污染 UI）
    static func extractSegments(from msg: ClaudeRawMessage) -> [MessageSegment] {
        var segs: [MessageSegment] = []
        let blocks = msg.content ?? []
        let fileEntries = (msg.files ?? []) + (msg.files_v2 ?? [])
        var fileNames: [String: String] = [:]
        for entry in fileEntries {
            guard let dict = entry.value as? [String: AnyCodable],
                  let uuid = dict["file_uuid"]?.value as? String, !uuid.isEmpty,
                  let name = dict["file_name"]?.value as? String, !name.isEmpty else { continue }
            fileNames[uuid] = name
        }
        var inlineFileUUIDs = Set<String>()

        if blocks.isEmpty {
            if let t = msg.text, !t.isEmpty {
                segs.append(.text(t))
            }
        } else {
            for block in blocks {
                switch block.type {
                case "text":
                    if let t = block.text, !t.isEmpty {
                        segs.append(.text(t))
                    }
                case "thinking":
                    if let t = block.thinking, !t.isEmpty {
                        segs.append(.thinking(text: t, signature: block.signature))
                    }
                case "tool_use":
                    let inputJSON = Self.encodeAnyJSON(block.input)
                    segs.append(.toolUse(
                        id: block.id ?? "",
                        name: block.name ?? "",
                        inputJSON: inputJSON,
                        integrationName: block.integration_name,
                        iconName: block.icon_name
                    ))
                case "tool_result":
                    let flatText = Self.flattenToolResultContent(block.content)
                    segs.append(.toolResult(
                        toolUseId: block.tool_use_id ?? "",
                        text: flatText,
                        isError: block.is_error ?? false,
                        integrationName: block.integration_name
                    ))
                case "flag":
                    segs.append(.flag(
                        kind: block.flag ?? "",
                        helplineName: block.helpline?.name,
                        helplinePhone: block.helpline?.phone_number,
                        helplineUrl: block.helpline?.web_chat_url ?? block.helpline?.url
                    ))
                case "image", "document":
                    let uuid = block.file_uuid ?? ""
                    let title = block.type == "document" ? block.title?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                    let name = (title?.isEmpty == false ? title : nil)
                        ?? fileNames[uuid]
                        ?? (block.type == "image" ? "图片" : "文档")
                    segs.append(.file(name: name, uuid: uuid))
                    if !uuid.isEmpty { inlineFileUUIDs.insert(uuid) }
                case "voice_note":
                    // 语音转写就是用户说的话（别家导出见过，粟粟的样本没有）
                    if let t = block.text, !t.isEmpty {
                        segs.append(.text(t))
                    }
                default:
                    // 未知 block type（redacted_thinking / server_tool_use / token_budget 等）留给未来扩展。
                    // injected_prompt_block（Claude 客户端注入的日期提示 / 记忆块 / 工具清单）故意不导：
                    // 不是用户写的；存成附件卡会在编辑重发时变回输入框附件（#043 D2）
                    break
                }
            }
        }

        // attachments（文本附件，extracted_content 已提取好）→ trailing
        if let attachments = msg.attachments {
            for entry in attachments {
                guard let dict = entry.value as? [String: AnyCodable] else { continue }
                let name = (dict["file_name"]?.value as? String)
                    ?? (dict["name"]?.value as? String)
                    ?? ""
                let type = dict["file_type"]?.value as? String
                let extracted = dict["extracted_content"]?.value as? String
                if !name.isEmpty || (extracted?.isEmpty == false) {
                    segs.append(.attachment(name: name, type: type, extractedContent: extracted))
                }
            }
        }

        // files / files_v2（图像/二进制，导出包里没有字节）→ trailing；已在正文位置插过的 uuid 不重复
        for entry in fileEntries {
            guard let dict = entry.value as? [String: AnyCodable] else { continue }
            let name = (dict["file_name"]?.value as? String) ?? ""
            let uuid = (dict["file_uuid"]?.value as? String) ?? ""
            if !uuid.isEmpty, inlineFileUUIDs.contains(uuid) { continue }
            if !name.isEmpty {
                segs.append(.file(name: name, uuid: uuid))
            }
        }

        return segs
    }

    // MARK: - AnyCodable → JSON string

    /// tool_use.input 是 AnyCodable dict；编码回 JSON 字符串（排序 key，保证搜索 / diff 稳定）。
    static func encodeAnyJSON(_ value: AnyCodable?) -> String {
        guard let value else { return "{}" }
        let raw = unwrap(value.value)
        guard JSONSerialization.isValidJSONObject(raw) else {
            return String(describing: raw)
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: raw,
            options: [.sortedKeys, .prettyPrinted]
        ), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    /// 把嵌套 AnyCodable / [AnyCodable] / [String: AnyCodable] 解包成 JSONSerialization 能吃的原生类型。
    private static func unwrap(_ value: Any) -> Any {
        if let any = value as? AnyCodable { return unwrap(any.value) }
        if let dict = value as? [String: AnyCodable] {
            return dict.mapValues { unwrap($0.value) }
        }
        if let arr = value as? [AnyCodable] {
            return arr.map { unwrap($0.value) }
        }
        return value
    }

    /// tool_result.content 在实测里 100% 是 `[{"type": "text", "text": "..."}]` 列表。
    /// 扁平化成单个字符串（多条用 `\n\n` 连接）。遇到非 text block 用 `[type]` 占位。
    static func flattenToolResultContent(_ value: AnyCodable?) -> String {
        guard let value else { return "" }
        if let str = value.value as? String { return str }
        guard let arr = value.value as? [AnyCodable] else { return "" }
        var parts: [String] = []
        for item in arr {
            if let dict = item.value as? [String: AnyCodable] {
                let type = dict["type"]?.value as? String ?? "unknown"
                if type == "text" {
                    if let t = dict["text"]?.value as? String, !t.isEmpty {
                        parts.append(t)
                    }
                } else {
                    parts.append("[\(type)]")
                }
            } else if let s = item.value as? String {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Flattened search text

    /// 把 segments 压扁成"可搜索正文"，写入 MessageNode.content。搜索逻辑不改。
    /// thinking 段用 `<<<THINK>>>...<<</THINK>>>` 包起来，P6 的"搜索思考"toggle 用这对 marker 做筛选。
    static func flattenSegmentsForSearch(_ segs: [MessageSegment]) -> String {
        var parts: [String] = []
        for seg in segs {
            switch seg {
            case .text(let s):
                if !s.isEmpty { parts.append(s) }
            case .thinking(let text, _):
                if !text.isEmpty { parts.append("<<<THINK>>>\n\(text)\n<<</THINK>>>") }
            case .toolUse(_, let name, let inputJSON, _, _):
                parts.append("🔧 \(name) \(inputJSON)")
            case .toolResult(_, let text, let isError, _):
                if !text.isEmpty {
                    parts.append(isError ? "[tool error] \(text)" : text)
                }
            case .flag(let kind, let hName, _, _):
                parts.append("⚠️ flag:\(kind)\(hName.map { " (\($0))" } ?? "")")
            case .attachment(let name, _, let extracted):
                var s = "📎 \(name)"
                if let ex = extracted, !ex.isEmpty { s += "\n\(ex)" }
                parts.append(s)
            case .file(let name, _):
                parts.append("🖼 \(name)")
            case .image(let name, _, _):
                parts.append("🖼 \(name)")
            case .fileData(let name, _, _):
                parts.append("📎 \(name)")
            case .imageRef(let name, _, _):
                parts.append("🖼 \(name)")
            case .fileDataRef(let name, _, _):
                parts.append("📎 \(name)")
            case .audioRef(_, _, _, _, let script):
                parts.append("🎤 语音条" + (script.map { "：\($0)" } ?? ""))
            }
        }
        return parts.joined(separator: "\n\n")
    }

}

// MARK: - Claude Raw JSON Types

struct ClaudeRawConversation: Decodable {
    let uuid: String
    let name: String?
    let summary: String?
    let created_at: Date?
    let updated_at: Date?
    let account: ClaudeRawAccount?
    let chat_messages: [ClaudeRawMessage]?
    /// 下面三个粟粟的样本里没有，别家导出 / 抓包格式见过（外部调研 §5.3）：有就用
    let current_leaf_message_uuid: String?
    let project_uuid: String?
    let project: ClaudeRawProjectRef?
}

struct ClaudeRawProjectRef: Decodable {
    let uuid: String?
    let name: String?
}

/// design_chats/<uuid>.json
struct ClaudeDesignChat: Decodable {
    struct Message: Decodable {
        struct Content: Decodable {
            let content: String?
            let role: String?
            let attachments: [Attachment]?
        }
        struct Attachment: Decodable {
            let id: String?
            let name: String?
            let type: String?
            let path: String?
            let content: String?
        }
        let uuid: String
        let role: String?
        let content: Content?
        let created_at: Date?
    }
    let uuid: String
    let title: String?
    let project: ClaudeRawProjectRef?
    let created_at: Date?
    let updated_at: Date?
    let messages: [Message]?
}

struct ClaudeRawAccount: Decodable {
    let uuid: String?
}

struct ClaudeRawMessage: Decodable {
    let uuid: String
    let text: String?
    let content: [ClaudeContentBlock]?
    let sender: String?
    let created_at: Date?
    let updated_at: Date?
    let attachments: [AnyCodable]?
    let files: [AnyCodable]?
    let files_v2: [AnyCodable]?
    /// Claude export 实测 100% 出现（16894/16894）。用来替换 index-1 的 linear 假设。
    let parent_message_uuid: String?
}

struct ClaudeContentBlock: Decodable {
    let type: String
    let text: String?
    let thinking: String?
    let name: String?          // tool_use / tool_result 的工具名
    let start_timestamp: String?
    let stop_timestamp: String?
    let flags: AnyCodable?
    let citations: [AnyCodable]?

    // tool_use
    let id: String?
    let input: AnyCodable?

    // tool_result
    let tool_use_id: String?
    let content: AnyCodable?
    let is_error: Bool?

    // thinking 扩展（Opus 4.x / Sonnet 4.x）
    let signature: String?

    // tool_use / tool_result 的 MCP 集成元信息
    let integration_name: String?
    let icon_name: String?

    // flag 块（Claude.ai 客户端扩展，API 里没有）
    let flag: String?
    let helpline: ClaudeHelpline?

    // image / document 块（2026 新版导出）：只有 uuid，没有字节
    let file_uuid: String?
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, name
        case start_timestamp, stop_timestamp, flags, citations
        case id, input, tool_use_id, content, is_error
        case signature, integration_name, icon_name
        case flag, helpline
        case file_uuid, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        start_timestamp = try container.decodeIfPresent(String.self, forKey: .start_timestamp)
        stop_timestamp = try container.decodeIfPresent(String.self, forKey: .stop_timestamp)
        flags = try container.decodeIfPresent(AnyCodable.self, forKey: .flags)
        citations = try container.decodeIfPresent([AnyCodable].self, forKey: .citations)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        input = try container.decodeIfPresent(AnyCodable.self, forKey: .input)
        tool_use_id = try container.decodeIfPresent(String.self, forKey: .tool_use_id)
        content = try container.decodeIfPresent(AnyCodable.self, forKey: .content)
        is_error = try container.decodeIfPresent(Bool.self, forKey: .is_error)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        integration_name = try container.decodeIfPresent(String.self, forKey: .integration_name)
        icon_name = try container.decodeIfPresent(String.self, forKey: .icon_name)
        flag = try container.decodeIfPresent(String.self, forKey: .flag)
        helpline = try container.decodeIfPresent(ClaudeHelpline.self, forKey: .helpline)
        file_uuid = (try? container.decodeIfPresent(String.self, forKey: .file_uuid)) ?? nil
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
    }
}

struct ClaudeHelpline: Decodable {
    let id: String?
    let name: String?
    let phone_number: String?
    let sms_number: String?
    let web_chat_url: String?
    let url: String?
}
