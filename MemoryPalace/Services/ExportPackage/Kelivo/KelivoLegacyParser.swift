import Foundation

/// 旧版 Kelivo（v1.1.17 及以前）备份里的 `chats.json` → 中间模型（#049）。
/// 旧版导出本身会带重复 / 悬空 / 归属错的消息，修复按上游新版导入旧包的规则（docs/research-import-kelivo-format.md §B3）：
/// 会话 / 消息 id 重复留第一个；按 `messageIds` 走，悬空的丢、同一消息第二次被引用丢、`conversationId` 不符改成引用者；
/// 选中版本存的是组内序号，换成 version 值。
enum KelivoLegacyParser {
    enum ParseError: LocalizedError, Equatable {
        case notRecognized

        var errorDescription: String? { "chats.json 认不出来（不是 Kelivo 的聊天备份）" }
    }

    struct Result {
        var conversations: [KelivoBackup.Conversation] = []
        var counts = KelivoBackup.Counts()
    }

    static func parse(data: Data, timeZone: TimeZone = .current) throws -> Result {
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        guard let root = try? JSONSerialization.jsonObject(with: body), KelivoBackup.isLegacyChats(root),
              let dict = root as? [String: Any] else { throw ParseError.notRecognized }
        var result = Result()

        var messages: [String: [String: Any]] = [:]
        for case let message as [String: Any] in dict["messages"] as? [Any] ?? [] {
            guard let id = message["id"] as? String, !id.isEmpty else { continue }
            if messages[id] != nil { result.counts.duplicateIds += 1; continue }
            messages[id] = message
        }
        let toolEvents = dict["toolEvents"] as? [String: Any] ?? [:]

        var seenConversations = Set<String>()
        var referenced = Set<String>()
        for case let conv as [String: Any] in dict["conversations"] as? [Any] ?? [] {
            guard let id = conv["id"] as? String, !id.isEmpty else { continue }
            guard seenConversations.insert(id).inserted else { result.counts.duplicateIds += 1; continue }
            result.conversations.append(conversation(conv, id: id, messages: messages, toolEvents: toolEvents,
                                                     referenced: &referenced, timeZone: timeZone, counts: &result.counts))
        }
        result.counts.unreferencedMessages = Set(messages.keys).subtracting(referenced).count
        return result
    }

    private static func conversation(_ conv: [String: Any], id: String, messages: [String: [String: Any]],
                                     toolEvents: [String: Any], referenced: inout Set<String>, timeZone: TimeZone,
                                     counts: inout KelivoBackup.Counts) -> KelivoBackup.Conversation {
        var out = KelivoBackup.Conversation(
            id: id, title: conv["title"] as? String ?? "",
            createdAt: KelivoBackup.date(iso: conv["createdAt"] as? String, timeZone: timeZone, counts: &counts),
            updatedAt: KelivoBackup.date(iso: conv["updatedAt"] as? String, timeZone: timeZone, counts: &counts))
        out.assistantId = conv["assistantId"] as? String
        for key in ["isPinned", "summary", "truncateIndex", "mcpServerIds", "chatSuggestions", "assistantId", "versionSelections", "lastSummarizedMessageCount"] {
            if let value = conv[key], !(value is NSNull) { out.metadata[key] = value }
        }

        // 选中序号要连重复引用一起数（上游同此），先记下每组被引用到的 version
        var versionsByGroup: [String: [Int]] = [:]
        var usedVersions: [String: Set<Int>] = [:]
        var versionOf: [String: Int] = [:]
        var order = 0
        for case let messageId as String in conv["messageIds"] as? [Any] ?? [] {
            guard var message = messages[messageId] else { counts.danglingIds += 1; continue }
            let explicitGroup = (message["groupId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let groupKey = explicitGroup ?? messageId
            if !referenced.insert(messageId).inserted {
                if let v = versionOf[messageId] { versionsByGroup[groupKey, default: []].append(v) }
                counts.duplicateReferences += 1
                continue
            }
            if let owner = message["conversationId"] as? String, owner != id {
                counts.rehomedMessages += 1
                message["conversationId"] = id
            }
            var version = max(0, message["version"] as? Int ?? 0)
            if explicitGroup != nil, usedVersions[groupKey]?.contains(version) == true {
                version = (usedVersions[groupKey]?.max() ?? 0) + 1
            }
            usedVersions[groupKey, default: []].insert(version)
            versionOf[messageId] = version
            versionsByGroup[groupKey, default: []].append(version)

            var revision = KelivoBackup.Revision(
                id: messageId, role: (message["role"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "user",
                groupKey: groupKey, version: version, order: order,
                time: KelivoBackup.date(iso: message["timestamp"] as? String, timeZone: timeZone, counts: &counts))
            revision.parts = parts(of: message, toolEvents: toolEvents[messageId] as? [Any] ?? [])
            for key in ["modelId", "providerId", "totalTokens", "promptTokens", "completionTokens", "cachedTokens",
                        "durationMs", "translation", "isStreaming", "reasoningSegmentsJson", "reasoningStartAt", "reasoningFinishedAt"] {
                if let value = message[key], !(value is NSNull) { revision.metadata[key] = value }
            }
            out.revisions.append(revision)
            order += 1
        }

        for (groupKey, ordinal) in conv["versionSelections"] as? [String: Any] ?? [:] {
            guard let versions = versionsByGroup[groupKey]?.sorted(), let last = versions.last else { continue }
            let index = (ordinal as? Int) ?? -1
            out.selections[groupKey] = versions.indices.contains(index) ? versions[index] : last
        }
        return out
    }

    /// 旧版消息：有 `parts` 用 parts；否则正文里独占一行的 `[image:…]` / `[file:…|名|mime]` 拆成附件
    private static func parts(of message: [String: Any], toolEvents: [Any]) -> [KelivoBackup.Part] {
        if let parts = message["parts"] as? [[String: Any]] {
            return parts.compactMap { p in
                guard let kind = p["kind"] as? String else { return nil }
                let payload = p["payload"] as? String ?? (p["payload"].map { KelivoBackup.jsonString($0) } ?? "")
                return KelivoBackup.part(kind: kind, payload: payload)
            }
        }
        // 顺序跟 Kelivo 1.3 自己迁移旧数据一致（真导出核过）：思考 → 正文 / 附件 → 工具调用，同一份数据两代导出来一样
        var out: [KelivoBackup.Part] = []
        if let reasoning = reasoningText(message) { out.append(.reasoning(reasoning)) }
        out += contentParts(message["content"] as? String ?? "")
        for case let event as [String: Any] in toolEvents {
            let arguments = event["arguments"].map { KelivoBackup.jsonString($0) } ?? "{}"
            let result = event["content"] as? String
            out.append(.tool(id: event["id"] as? String ?? "", name: event["name"] as? String ?? "tool",
                             argumentsJSON: arguments, result: result?.isEmpty == true ? nil : result))
        }
        return out
    }

    /// `reasoningText` 和 `reasoningSegmentsJson` 内容重复，取其一：有全文用全文，否则拼分段
    private static func reasoningText(_ message: [String: Any]) -> String? {
        if let text = message["reasoningText"] as? String, !text.isEmpty { return text }
        let parsed = KelivoBackup.jsonObject(message["reasoningSegmentsJson"] as? String)
        let segments = (parsed as? [[String: Any]]) ?? ((parsed as? [String: Any])?["segments"] as? [[String: Any]]) ?? []
        let joined = segments.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private static let imageLine = try! Regex(#"^\[image:(.*)\]$"#)
    private static let fileLine = try! Regex(#"^\[file:([^|\]]+)\|([^|\]]+)\|([^|\]]*)\]$"#)

    /// 只认整行恰好是标记的；代码围栏里的行一律是文本。标记两侧的文本中间保留一个换行
    static func contentParts(_ content: String) -> [KelivoBackup.Part] {
        var out: [KelivoBackup.Part] = []
        var buffer = ""
        var fence: (char: Character, count: Int)?
        func flush() {
            let text = buffer.hasSuffix("\n") ? String(buffer.dropLast()) : buffer
            if !text.isEmpty { out.append(.text(text)) }
            buffer = ""
        }
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() {
            let newline = i + 1 < lines.count ? "\n" : ""
            if let marker = fenceMarker(line) {
                if let current = fence {
                    // 闭围栏后面只能有空白（CommonMark），带文字的是代码内容（sol #13）
                    if marker.char == current.char && marker.count >= current.count
                        && marker.rest.allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
                } else {
                    fence = (marker.char, marker.count)
                }
                buffer += line + newline
                continue
            }
            if fence == nil, let m = try? imageLine.wholeMatch(in: line),
               let uri = m.output[1].substring.map({ String($0).trimmingCharacters(in: .whitespaces) }), !uri.isEmpty {
                flush()
                out.append(.image(.init(uri: uri)))
                continue
            }
            if fence == nil, let m = try? fileLine.wholeMatch(in: line),
               let uri = m.output[1].substring.map(String.init), let name = m.output[2].substring.map(String.init) {
                flush()
                let mime = m.output[3].substring.map(String.init)
                out.append(.file(.init(uri: uri, name: name, mime: mime?.isEmpty == true ? nil : mime)))
                continue
            }
            buffer += line + newline
        }
        flush()
        return out
    }

    /// CommonMark 代码围栏：0–3 个空格缩进 + 至少 3 个 ` 或 ~；`rest` 是围栏符后面的部分
    private static func fenceMarker(_ line: String) -> (char: Character, count: Int, rest: Substring)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let run = rest.prefix { $0 == c }.count
        return run >= 3 ? (c, run, rest.dropFirst(run)) : nil
    }
}
