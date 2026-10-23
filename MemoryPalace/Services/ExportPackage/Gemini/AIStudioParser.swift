import Foundation

/// Google AI Studio 的 prompt 文件（Drive 下载，常无扩展名）：`runSettings` + `systemInstruction` + `chunkedPrompt.chunks[]`
/// → 一段对话（#047，实验性）。相邻同角色 chunk 合成一条消息，思考 / 正文 / 图片按原顺序成段。
enum AIStudioParser {
    static let provider = "aistudio"
    static let maxInlineImageBytes = 20 * 1024 * 1024

    static func isAIStudio(_ root: Any) -> Bool {
        guard let dict = root as? [String: Any], let prompt = dict["chunkedPrompt"] as? [String: Any] else { return false }
        return prompt["chunks"] is [Any]
    }

    static func parse(file url: URL) throws -> GeminiImportResult {
        try parse(data: ExportJSON.data(at: url), fileName: url.lastPathComponent)
    }

    static func parse(data: Data, fileName: String) throws -> GeminiImportResult {
        guard let root = GeminiImportSupport.jsonObject(data), isAIStudio(root),
              let dict = root as? [String: Any],
              let chunks = (dict["chunkedPrompt"] as? [String: Any])?["chunks"] as? [Any] else {
            throw GeminiImportError.notRecognized
        }
        var result = GeminiImportResult()
        let chunkDicts = chunks.compactMap { $0 as? [String: Any] }
        guard let first = chunkDicts.first else { return result }

        let systemText = ((dict["systemInstruction"] as? [String: Any])?["text"] as? String) ?? ""
        let firstTime = first["createTime"] as? String
        var idParts = [systemText, first["role"] as? String ?? "", chunkIdentity(first), firstTime ?? ""]
        if firstTime == nil { idParts.append(fileName) }
        // 哈希放前面：附件目录按对话 id 前 8 位分（AttachmentStore），固定前缀会让所有 AI Studio 对话挤一个目录
        let conversationId = GeminiImportSupport.shortHash(idParts) + "-aistudio"

        // 相邻同角色合并
        var groups: [(role: String, indices: [Int])] = []
        for (i, chunk) in chunkDicts.enumerated() {
            let role = chunk["role"] as? String ?? ""
            if let last = groups.last, last.role == role {
                groups[groups.count - 1].indices.append(i)
            } else {
                groups.append((role, [i]))
            }
        }

        var items: [GeminiImportSupport.ChainItem] = []
        var times: [Date] = []
        for group in groups {
            var segments: [MessageSegment] = []
            var rawChunks: [Any] = []
            for i in group.indices {
                segments += self.segments(of: chunkDicts[i], index: i, result: &result)
                rawChunks.append(redactedBase64(chunkDicts[i]))
            }
            // 工具调用 / 结果等不显示的内容也留一条隐藏消息（原始 chunk 在元数据里），只有真空的才跳过
            let unsupported = segments.isEmpty && group.indices.contains { hasContent(chunkDicts[$0]) }
            guard !segments.isEmpty || unsupported else { continue }
            if unsupported { result.unsupportedMessageCount += 1 }
            let time = GeminiImportSupport.parseISO(chunkDicts[group.indices[0]]["createTime"] as? String)
            if chunkDicts[group.indices[0]]["createTime"] != nil && time == nil { result.unreadableTimeCount += 1 }
            if let time { times.append(time) }

            let role: String
            var visibility: String?
            switch group.role {
            case "user": role = "user"
            case "model": role = "assistant"
            default:
                role = group.role.isEmpty ? "unknown" : group.role
                visibility = "hidden"
                if !unsupported { result.unknownRoleCount += 1 }
            }
            if unsupported { visibility = "hidden" }
            items.append(.init(id: "\(conversationId)/\(group.indices[0])", role: role, segments: segments, time: time,
                               metadata: GeminiImportSupport.jsonData(["chunks": rawChunks]), visibility: visibility))
        }
        guard let last = items.last, items.contains(where: { $0.visibility == nil }) else { return result }

        var meta: [String: Any] = ["source": "aistudio", "fileName": fileName]
        for (key, value) in dict where key != "chunkedPrompt" { meta[key] = value }
        let created = times.min() ?? .distantPast
        result.payloads.append(ImportedConversationPayload(
            id: conversationId,
            title: title(fileName: fileName, items: items),
            createTime: created,
            updateTime: times.max() ?? created,
            currentNodeId: last.id,
            provider: provider,
            nodes: GeminiImportSupport.chain(items),
            sourceMetadata: GeminiImportSupport.jsonData(meta)
        ))
        return result
    }

    /// 开场那条的身份：文字 + 图片内容摘要 + Drive 图 id（只看文字的话，同一句「描述这张图」配不同图会撞成一段）
    private static func chunkIdentity(_ chunk: [String: Any]) -> String {
        var parts: [String] = []
        if let text = chunk["text"] as? String { parts.append(text) }
        for part in (chunk["parts"] as? [[String: Any]]) ?? [] {
            if let text = part["text"] as? String { parts.append(text) }
            if let data = (part["inlineData"] as? [String: Any])?["data"] as? String { parts.append("img:" + GeminiImportSupport.shortHash([data])) }
        }
        if let data = (chunk["inlineImage"] as? [String: Any])?["data"] as? String { parts.append("img:" + GeminiImportSupport.shortHash([data])) }
        if let id = (chunk["driveImage"] as? [String: Any])?["id"] as? String { parts.append("drive:" + id) }
        if let id = (chunk["driveDocument"] as? [String: Any])?["id"] as? String { parts.append("doc:" + id) }
        return parts.joined(separator: "\u{1F}")
    }

    /// 除了角色 / 时间 / 计数这类附带字段，还有没有别的内容
    private static let bookkeepingKeys: Set<String> = ["role", "createTime", "tokenCount", "finishReason", "isThought", "thoughtSignatures", "text", "parts"]

    private static func hasContent(_ chunk: [String: Any]) -> Bool {
        if !Set(chunk.keys).subtracting(bookkeepingKeys).isEmpty { return true }
        if let text = chunk["text"] as? String, !text.isEmpty { return true }
        return ((chunk["parts"] as? [[String: Any]]) ?? []).contains { !$0.isEmpty && !($0.count == 1 && ($0["text"] as? String)?.isEmpty == true) }
    }

    private static func segments(of chunk: [String: Any], index: Int, result: inout GeminiImportResult) -> [MessageSegment] {
        var out: [MessageSegment] = []
        let chunkIsThought = chunk["isThought"] as? Bool ?? false
        if let parts = chunk["parts"] as? [[String: Any]], !parts.isEmpty {
            for (p, part) in parts.enumerated() {
                if let inline = part["inlineData"] as? [String: Any] {
                    out.append(image(inline, name: "image-\(index)-\(p)", result: &result))
                }
                if let text = part["text"] as? String, !text.isEmpty {
                    let isThought = (part["thought"] as? Bool ?? false) || chunkIsThought
                    out.append(isThought ? .thinking(text: text, signature: nil) : .text(text))
                }
            }
        } else if let text = chunk["text"] as? String, !text.isEmpty {
            out.append(chunkIsThought ? .thinking(text: text, signature: nil) : .text(text))
        }
        if let inline = chunk["inlineImage"] as? [String: Any] {
            out.append(image(inline, name: "image-\(index)", result: &result))
        }
        if let drive = chunk["driveImage"] as? [String: Any], let id = drive["id"] as? String, !id.isEmpty {
            out.append(.file(name: "Drive 图片", uuid: id))
            result.attachmentPlaceholderCount += 1
        }
        if out.isEmpty, let error = chunk["errorMessage"] as? String, !error.isEmpty {
            out.append(.text("⚠️ " + error))
        }
        return out
    }

    private static func image(_ inline: [String: Any], name: String, result: inout GeminiImportResult) -> MessageSegment {
        let mime = inline["mimeType"] as? String
        let ext = mime.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "bin"
        let encoded = inline["data"] as? String ?? ""
        guard encoded.utf8.count / 4 * 3 <= maxInlineImageBytes,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty else {
            result.droppedImageCount += 1
            return .file(name: "\(name).\(ext)", uuid: "")
        }
        return .image(name: "\(name).\(ext)", type: mime, data: data)
    }

    /// 元数据里的 chunk 原样保留，只把 base64 正文换成长度（图片本体已在段里）
    private static func redactedBase64(_ chunk: [String: Any]) -> [String: Any] {
        func redact(_ inline: Any?) -> Any? {
            guard var dict = inline as? [String: Any], let data = dict["data"] as? String else { return inline }
            dict["data"] = "<base64 \(data.utf8.count) chars>"
            return dict
        }
        var out = chunk
        if let inline = redact(chunk["inlineImage"]) { out["inlineImage"] = inline }
        if let parts = chunk["parts"] as? [[String: Any]] {
            out["parts"] = parts.map { part -> [String: Any] in
                var p = part
                if let inline = redact(part["inlineData"]) { p["inlineData"] = inline }
                return p
            }
        }
        return out
    }

    private static func title(fileName: String, items: [GeminiImportSupport.ChainItem]) -> String {
        let last = (fileName as NSString).lastPathComponent
        let base = ((last as NSString).pathExtension.lowercased() == "json" ? (last as NSString).deletingPathExtension : last)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty, base.lowercased() != "untitled prompt" { return base }
        for item in items where item.role == "user" {
            for case .text(let text) in item.segments where !text.isEmpty {
                return GeminiImportSupport.titleSnippet(text)
            }
        }
        return "AI Studio 对话"
    }
}
