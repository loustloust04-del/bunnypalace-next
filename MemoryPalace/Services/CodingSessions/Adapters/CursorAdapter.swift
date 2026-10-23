#if os(macOS)
import Foundation

/// Cursor CLI：`~/.cursor/projects/<slug>/agent-transcripts/<uuid>/<uuid>.jsonl` 明文（Wake `adapters/cursor.rs`）。
/// 行结构 `{role, message:{content:[{type:text|tool_use}]}}` + `{type:"turn_ended"}`；user 正文包在 `<timestamp>` / `<user_query>`
/// 壳里；transcript 不含 cwd，从有损 slug 目录名按磁盘真实目录 DFS 反推；工具结果不落盘（output 恒空）。IDE chats（加密）不做
struct CursorAdapter: CodingSessionAdapter {
    let root: URL

    init(home: URL) {
        root = home.appendingPathComponent(".cursor/projects", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
    }

    var agent: CodingAgent { .cursor }
    var dataRoots: [URL] { [root] }

    func listSessionFiles() -> [CodingSessionFileRef] {
        let fm = FileManager.default
        var refs: [CodingSessionFileRef] = []
        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let transcripts = project.appendingPathComponent("agent-transcripts", isDirectory: true)
            for session in (try? fm.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: CodingParse.refKeys)) ?? []
                where file.pathExtension == "jsonl" {
                    if let ref = CodingParse.defaultFileRef(.cursor, file) { refs.append(ref) }
                }
            }
        }
        return refs
    }

    /// 只认 transcript 主文件；subagents 转录不是独立会话
    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        guard url.path.contains("/agent-transcripts/"), !url.path.contains("/subagents/") else { return nil }
        return CodingParse.defaultFileRef(.cursor, url)
    }

    /// 会话是 `<uuid>/` 整个目录（含 subagents/），删除时整目录进废纸篓
    func sessionPaths(_ meta: CodingSessionMeta) -> [String] {
        [URL(fileURLWithPath: meta.filePath).deletingLastPathComponent().path]
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let parsed = try Self.parse(URL(fileURLWithPath: ref.filePath))
        return CodingParsedSession(meta: meta(ref, parsed), units: CodingParse.units(parsed.messages), unknownLines: parsed.unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let parsed = try CodingImageBudget.decoding { try Self.parse(URL(fileURLWithPath: ref.filePath)) }
        // subagents/ 与 Claude 同构，但无 meta 边车、主线 Task 调用无 id，挂不上具体 tool_use——只列出来供导出携带
        let subagents = Self.subagentsDir(ref)
        let sidechains = ((try? FileManager.default.contentsOfDirectory(atPath: subagents.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .map { CodingSidechain(id: String($0.dropLast(6))) }
        return CodingParsedTranscript(meta: meta(ref, parsed), mainline: parsed.messages, sidechains: sidechains, unknownLines: parsed.unknown)
    }

    func loadSidechain(_ ref: CodingSessionFileRef, id: String) throws -> [CodingMessage] {
        let file = Self.subagentsDir(ref).appendingPathComponent("\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try CodingImageBudget.decoding { try Self.parse(file).messages }
    }

    private static func subagentsDir(_ ref: CodingSessionFileRef) -> URL {
        URL(fileURLWithPath: ref.filePath).deletingLastPathComponent().appendingPathComponent("subagents", isDirectory: true)
    }

    struct Parse {
        var messages: [CodingMessage] = []
        var createdAt: Int64 = 0
        var updatedAt: Int64 = 0
        var unknown = 0
    }

    private struct PendingAssistant {
        var content = CodingParse.Content()
        var toolCalls: [CodingToolCall] = []
    }

    static func parse(_ url: URL) throws -> Parse {
        var p = Parse()
        var pending: PendingAssistant?

        func flush() {
            guard let a = pending else { return }
            pending = nil
            if a.content.text.isEmpty && a.toolCalls.isEmpty && a.content.images.isEmpty { return }
            let (text, truncated) = CodingParse.clip(a.content.text, CodingLimits.maxMessageText)
            p.messages.append(CodingMessage(seq: 0, role: .assistant, kind: .text, text: text, truncated: truncated,
                                            toolCalls: a.toolCalls, imageCount: a.content.imageCount, images: a.content.images))
        }

        try CodingParse.forEachLine(url) { row in
            guard let row else {
                p.unknown += 1
                return
            }
            guard let role = row["role"] as? String else {
                if row["type"] as? String == "turn_ended" { flush() } else { p.unknown += 1 }
                return
            }
            let blocks = ((row["message"] as? CodingParse.JSON)?["content"] as? [Any]) ?? []
            switch role {
            case "user":
                flush()
                var parsed = CodingParse.Content()
                var ts: Int64 = 0
                for case let block as CodingParse.JSON in blocks {
                    if block["type"] as? String == "text" {
                        guard let raw = block["text"] as? String else { continue }
                        if let stamp = CodingParse.extractTag(raw, "timestamp") {
                            let parsedTs = timestampMs(stamp)
                            if parsedTs > 0 { ts = parsedTs }
                        }
                        // 真实输入在 <user_query> 壳内；没有壳的行原样保留
                        let body = CodingParse.extractTag(raw, "user_query") ?? raw
                        if !CodingParse.isBlank(body) { parsed.push(body) }
                    } else if CodingParse.isImagePart(block) {
                        parsed.append(CodingParse.contentParts(block))
                    }
                }
                if CodingParse.isBlank(parsed.text) && parsed.images.isEmpty { return }
                if ts > 0 {
                    if p.createdAt == 0 { p.createdAt = ts }
                    p.updatedAt = max(p.updatedAt, ts)
                }
                var message = CodingParse.textMessage(.user, parsed.text, ts: ts)
                message.images = parsed.images
                message.imageCount = parsed.imageCount
                p.messages.append(message)
            case "assistant":
                // Cursor 逐块落行且无消息 id：连续 assistant 行并成一条，turn_ended / user 处 flush
                var a = pending ?? PendingAssistant()
                for case let block as CodingParse.JSON in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !CodingParse.isBlank(t) { a.content.push(t) }
                    case "tool_use":
                        a.toolCalls.append(CodingParse.toolCall(id: "", name: block["name"] as? String ?? "tool", input: block["input"] ?? NSNull()))
                    default:
                        if CodingParse.isImagePart(block) { a.content.append(CodingParse.contentParts(block)) }
                    }
                }
                pending = a
            default:
                p.unknown += 1
            }
        }
        flush()
        CodingParse.assignSeq(&p.messages)
        return p
    }

    /// "Thursday, Jul 23, 2026, 4:00 PM (UTC+8)" → epoch ms；解析失败 = 0。星期名要与日期对得上（chrono `%A` 解析会校验，
    /// 全称或缩写、不分大小写）
    static func timestampMs(_ s: String) -> Int64 {
        guard let open = s.range(of: " (", options: .backwards) else { return 0 }
        let datePart = String(s[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard let comma = datePart.range(of: ", ") else { return 0 }
        let weekday = datePart[..<comma.lowerBound].lowercased()
        let withoutWeekday = String(datePart[comma.upperBound...])
        var offset = String(s[open.upperBound...])
        while offset.hasSuffix(")") { offset.removeLast() }
        guard offset.hasPrefix("UTC") else { return 0 }
        offset = String(offset.dropFirst(3))
        guard let first = offset.first else { return 0 }
        var sign = 1
        var rest = Substring(offset)
        if first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            rest = rest.dropFirst()
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard let hours = Int(parts[0]) else { return 0 }
        var seconds = hours * 3600
        if parts.count > 1 {
            guard let minutes = Int(parts[1]) else { return 0 }
            seconds += minutes * 60
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        formatter.timeZone = TimeZone(secondsFromGMT: sign * seconds)
        guard let date = formatter.date(from: withoutWeekday) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let day = calendar.component(.weekday, from: date) - 1
        guard weekday == formatter.weekdaySymbols[day].lowercased() || weekday == formatter.shortWeekdaySymbols[day].lowercased() else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// "Users-corey-Github-image-translate" → "/Users/corey/Github/image-translate"：`-` 既可能是路径分隔也可能是目录名字符，
    /// 按磁盘真实存在的目录 DFS（优先短段）；项目目录已删时回退直译
    static func decodeSlug(_ slug: String) -> String {
        let parts = slug.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func dfs(_ base: String, _ rest: ArraySlice<String>) -> String? {
            if rest.isEmpty { return base }
            var segment = ""
            for i in rest.indices {
                segment += (i == rest.startIndex ? "" : "-") + rest[i]
                let candidate = (base == "/" ? "" : base) + "/" + segment
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue,
                   let hit = dfs(candidate, rest[(i + 1)...]) {
                    return hit
                }
            }
            return nil
        }
        return dfs("/", parts[...]) ?? "/" + slug.replacingOccurrences(of: "-", with: "/")
    }

    private func meta(_ ref: CodingSessionFileRef, _ p: Parse) -> CodingSessionMeta {
        // …/projects/<slug>/agent-transcripts/<uuid>/<uuid>.jsonl → slug
        let slug = URL(fileURLWithPath: ref.filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        let cwd = slug.isEmpty ? "" : Self.decodeSlug(slug)
        return CodingSessionMeta(
            key: "cursor:\(ref.nativeId)", nativeId: ref.nativeId, agent: .cursor,
            title: CodingParse.titleFromMessages(p.messages) ?? CodingLimits.untitled,
            projectPath: cwd, projectName: CodingParse.projectName(cwd), filePath: ref.filePath,
            createdAt: p.createdAt > 0 ? p.createdAt : ref.mtimeMs, updatedAt: p.updatedAt > 0 ? p.updatedAt : ref.mtimeMs,
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil
        )
    }
}
extension CursorAdapter {
    /// 选中 `~/.cursor`（含 projects/）或直接选中 projects 目录都认
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let nested = dir.appendingPathComponent("projects", isDirectory: true)
        return CursorAdapter(root: CodingLocations.isDirectory(nested) ? nested : dir)
    }
}
#endif
