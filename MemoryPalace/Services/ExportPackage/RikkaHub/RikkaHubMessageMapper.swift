import Foundation
import UniformTypeIdentifiers

/// 导入过程中不致命、但要在结果页说一声的东西
struct RikkaHubWarnings: Equatable {
    var missingAttachments = 0
    /// 附件路径想跳出 staging（`..` 之类），按缺失处理
    var rejectedPaths = 0
    var unknownParts = 0
    var badTimestamps = 0
    var clampedSelections = 0
    var emptyPositions = 0
    var brokenJSON = 0
    var emptyConversations = 0

    mutating func add(_ other: RikkaHubWarnings) {
        missingAttachments += other.missingAttachments
        rejectedPaths += other.rejectedPaths
        unknownParts += other.unknownParts
        badTimestamps += other.badTimestamps
        clampedSelections += other.clampedSelections
        emptyPositions += other.emptyPositions
        brokenJSON += other.brokenJSON
        emptyConversations += other.emptyConversations
    }
}

/// 一条 RikkaHub `UIMessage` 解出来的样子
struct RikkaHubMessage {
    let id: String?
    let role: String
    var segments: [MessageSegment]
    let createdAt: Date?
    /// 节点 sourceMetadata：原时间字符串、模型快照、用量等（research §4），不含 provider 私有 metadata
    let sourceMetadata: Data?
}

/// 附件 URL → staging 里的文件。只认 `…/files/upload/<名>`、`…/files/media_creation/<相对路径>` 和 `data:`；
/// 远程网址不联网下载，找不到的留带名字的占位（research §4.1）
struct RikkaHubAttachmentResolver {
    let stagingDir: URL
    var maxBytes: Int = 200 * 1024 * 1024

    enum Kind {
        case image
        case file(mime: String?)
    }

    func segment(url: String, fileName: String?, kind: Kind, warnings: inout RikkaHubWarnings) -> MessageSegment {
        let displayName = fileName.flatMap { $0.isEmpty ? nil : $0 } ?? Self.lastComponent(of: url)
        if url.hasPrefix("data:") {
            if let (mime, data) = Self.decodeDataURI(url) {
                return make(kind: kind, name: fileName ?? "image.\(Self.fileExtension(mime: mime))", mime: mime, data: data)
            }
            warnings.missingAttachments += 1
            return .file(name: displayName, uuid: "data:")
        }
        switch localFile(for: url) {
        case .found(let file):
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= maxBytes {
                let mime: String? = if case .file(let declared) = kind { declared } else { nil }
                return make(kind: kind, name: displayName, mime: mime ?? Self.mime(forExtension: file.pathExtension), data: data)
            }
            warnings.missingAttachments += 1
        case .rejected:
            warnings.rejectedPaths += 1
            warnings.missingAttachments += 1
        case .notLocal:
            warnings.missingAttachments += 1
        }
        return .file(name: displayName, uuid: url)
    }

    private enum Lookup {
        case found(URL)
        case rejected
        case notLocal
    }

    private func localFile(for url: String) -> Lookup {
        let path: String
        if url.hasPrefix("file:") {
            guard let parsed = URL(string: url), parsed.isFileURL else { return .notLocal }
            path = parsed.path(percentEncoded: false)
        } else if url.hasPrefix("/") {
            path = url
        } else {
            return .notLocal
        }
        guard let range = path.range(of: "/files/") else { return .notLocal }
        let relative = String(path[range.upperBound...])
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return .rejected }
        guard RikkaHubArchive.neededForImport(relative) else { return .notLocal }
        let file = stagingDir.appendingPathComponent(relative)
        guard file.standardizedFileURL.path.hasPrefix(stagingDir.standardizedFileURL.path + "/") else { return .rejected }
        return FileManager.default.fileExists(atPath: file.path) ? .found(file) : .notLocal
    }

    private func make(kind: Kind, name: String, mime: String, data: Data) -> MessageSegment {
        switch kind {
        case .image: return .image(name: name, type: mime, data: data)
        case .file: return .fileData(name: name, mime: mime, data: data)
        }
    }

    private static func lastComponent(of url: String) -> String {
        if url.hasPrefix("data:") { return "图片" }
        let trimmed = url.split(separator: "?").first.map(String.init) ?? url
        let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return (name.removingPercentEncoding ?? name).isEmpty ? "附件" : (name.removingPercentEncoding ?? name)
    }

    private static func decodeDataURI(_ uri: String) -> (String, Data)? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(7))
        guard let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters) else { return nil }
        return (mime.isEmpty ? "application/octet-stream" : mime, data)
    }

    static func mime(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func fileExtension(mime: String) -> String {
        UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
    }
}

/// RikkaHub `UIMessage` JSON → 花园消息段。逐字段宽松解（`JSONSerialization`），一段坏只丢这一段
enum RikkaHubMessageMapper {
    /// v14 前 part 的 `type` 是类名（`Text` / `UIMessagePart.Text` / `me.rerere.ai.ui.UIMessagePart.Text`），现在是 SerialName
    private static let legacyPartTypes: [String: String] = [
        "Text": "text", "Image": "image", "Video": "video", "Audio": "audio", "Document": "document",
        "Reasoning": "reasoning", "Search": "search", "ToolCall": "tool_call", "ToolResult": "tool_result", "Tool": "tool",
    ]

    static func normalizedPartType(_ raw: String) -> String {
        let short = raw.components(separatedBy: "UIMessagePart.").last ?? raw
        return legacyPartTypes[short] ?? short
    }

    static func message(_ object: [String: Any], timeZone: TimeZone, resolver: RikkaHubAttachmentResolver,
                        warnings: inout RikkaHubWarnings) -> RikkaHubMessage {
        // 逐个认：夹了一个坏元素不连累同条消息里别的段
        let rawParts = object["parts"] as? [Any] ?? []
        let parts = rawParts.compactMap { $0 as? [String: Any] }
        warnings.unknownParts += rawParts.count - parts.count
        let mapped = parts.flatMap { Self.segments(for: $0, resolver: resolver, warnings: &warnings) }
        let createdRaw = object["createdAt"] as? String
        let createdAt = createdRaw.flatMap { parseLocalDateTime($0, in: timeZone) }
        if createdAt == nil { warnings.badTimestamps += 1 }
        return RikkaHubMessage(
            id: object["id"] as? String,
            role: (object["role"] as? String) ?? "assistant",
            segments: mapped,
            createdAt: createdAt,
            sourceMetadata: sourceMetadata(object)
        )
    }

    static func segments(for part: [String: Any], resolver: RikkaHubAttachmentResolver,
                         warnings: inout RikkaHubWarnings) -> [MessageSegment] {
        let type = normalizedPartType(part["type"] as? String ?? "")
        switch type {
        case "text":
            let text = part["text"] as? String ?? ""
            return text.isEmpty ? [] : [.text(text)]
        case "image":
            guard let url = part["url"] as? String, !url.isEmpty else { return [] }
            return [resolver.segment(url: url, fileName: nil, kind: .image, warnings: &warnings)]
        case "video", "audio", "document":
            guard let url = part["url"] as? String, !url.isEmpty else { return [] }
            let mime = (part["mime"] as? String).flatMap { $0.contains("*") ? nil : $0 }
            return [resolver.segment(url: url, fileName: part["fileName"] as? String, kind: .file(mime: mime), warnings: &warnings)]
        case "reasoning":
            let text = part["reasoning"] as? String ?? ""
            return text.isEmpty ? [] : [.thinking(text: text, signature: nil)]
        case "tool":
            let id = part["toolCallId"] as? String ?? ""
            var result: [MessageSegment] = [.toolUse(id: id, name: part["toolName"] as? String ?? "", inputJSON: part["input"] as? String ?? "",
                                                     integrationName: nil, iconName: nil)]
            let output = part["output"] as? [[String: Any]] ?? []
            let outputText = output.compactMap { normalizedPartType($0["type"] as? String ?? "") == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            let approval = (part["approvalState"] as? [String: Any])?["type"] as? String
            if !outputText.isEmpty {
                result.append(.toolResult(toolUseId: id, text: outputText, isError: false, integrationName: nil))
            } else if approval == "denied" {
                let reason = (part["approvalState"] as? [String: Any])?["reason"] as? String ?? ""
                result.append(.toolResult(toolUseId: id, text: reason.isEmpty ? "（已拒绝）" : "（已拒绝）\(reason)", isError: true, integrationName: nil))
            }
            for item in output where normalizedPartType(item["type"] as? String ?? "") == "image" {
                result += segments(for: item, resolver: resolver, warnings: &warnings)
            }
            return result
        case "server_tool":
            let id = part["toolCallId"] as? String ?? ""
            var result: [MessageSegment] = [.toolUse(id: id, name: part["toolName"] as? String ?? "", inputJSON: jsonText(part["input"]),
                                                     integrationName: nil, iconName: nil)]
            let failed = (part["status"] as? String) == "failed"
            let output = jsonText(part["output"])
            if !output.isEmpty || failed {
                result.append(.toolResult(toolUseId: id, text: output, isError: failed, integrationName: nil))
            }
            return result
        case "tool_call":
            return [.toolUse(id: part["toolCallId"] as? String ?? "", name: part["toolName"] as? String ?? "",
                             inputJSON: part["arguments"] as? String ?? "", integrationName: nil, iconName: nil)]
        case "tool_result":
            return [.toolResult(toolUseId: part["toolCallId"] as? String ?? "", text: jsonText(part["content"]),
                                isError: false, integrationName: nil)]
        case "search":
            return []
        default:
            warnings.unknownParts += 1
            return []
        }
    }

    /// kotlinx `LocalDateTime`：`yyyy-MM-ddTHH:mm`，秒、小数秒（1–9 位）可省。没有时区——按调用方给的时区算（plan D3）
    static func parseLocalDateTime(_ raw: String, in timeZone: TimeZone) -> Date? {
        let pattern = #/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?$/#
        guard let m = raw.wholeMatch(of: pattern) else { return nil }
        var components = DateComponents()
        components.year = Int(m.1)
        components.month = Int(m.2)
        components.day = Int(m.3)
        components.hour = Int(m.4)
        components.minute = Int(m.5)
        components.second = m.6.flatMap { Int($0) } ?? 0
        if let fraction = m.7 {
            components.nanosecond = Int(fraction.padding(toLength: 9, withPad: "0", startingAt: 0))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == components.month,
              calendar.component(.day, from: date) == components.day else { return nil }
        return date
    }

    private static func jsonText(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func sourceMetadata(_ object: [String: Any]) -> Data? {
        var kept: [String: Any] = [:]
        for key in ["createdAt", "finishedAt", "modelSnapshot", "usage", "translation"] {
            if let value = object[key], !(value is NSNull) { kept[key] = value }
        }
        if let annotations = object["annotations"] as? [Any], !annotations.isEmpty { kept["annotations"] = annotations }
        if (object["isContextCheckpoint"] as? Bool) == true { kept["isContextCheckpoint"] = true }
        guard !kept.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["rikkahub": kept], options: [.sortedKeys])
    }
}
