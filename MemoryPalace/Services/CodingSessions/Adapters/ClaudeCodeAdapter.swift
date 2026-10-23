#if os(macOS)
import Foundation

/// Claude Code：`~/.claude/projects/<dir>/<uuid>.jsonl`（Wake `adapters/claude.rs`）。
/// 同 message.id 的逐块行合并成一条；tool_result 在后续 user 行，回填到 tool_use；
/// 子代理转录在 `<dir>/<uuid>/subagents/`。
struct ClaudeCodeAdapter: CodingSessionAdapter {
    let root: URL

    var agent: CodingAgent { .claudeCode }
    var dataRoots: [URL] { [root] }

    private static let knownSkipTypes: Set<String> = [
        "queue-operation", "mode", "last-prompt", "permission-mode", "file-history-snapshot",
        "file-history-delta", "pr-link", "frame-link", "attachment", "summary",
    ]

    func listSessionFiles() -> [CodingSessionFileRef] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var refs: [CodingSessionFileRef] = []
        for project in projects {
            guard let entries = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: CodingParse.refKeys) else { continue }
            for entry in entries where entry.pathExtension == "jsonl" {
                if let ref = CodingParse.defaultFileRef(.claudeCode, entry) { refs.append(ref) }
            }
        }
        return refs
    }

    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        let path = url.path
        if path.contains("/subagents/") || path.contains("/memory/") { return nil }
        return CodingParse.defaultFileRef(.claudeCode, url)
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let parsed = try Self.parse(URL(fileURLWithPath: ref.filePath), includeSidechain: false)
        return CodingParsedSession(meta: meta(ref, parsed), units: CodingParse.units(parsed.messages), unknownLines: parsed.unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let parsed = try CodingImageBudget.decoding { try Self.parse(URL(fileURLWithPath: ref.filePath), includeSidechain: false) }
        let sidechains = Self.listSidechains(ref)
        var mainline = parsed.messages
        let byToolUse = Dictionary(sidechains.compactMap { s in s.toolUseId.map { ($0, s.id) } }, uniquingKeysWith: { a, _ in a })
        for i in mainline.indices {
            for j in mainline[i].toolCalls.indices {
                if let sidechain = byToolUse[mainline[i].toolCalls[j].id] {
                    mainline[i].toolCalls[j].sidechainRef = sidechain
                }
            }
        }
        return CodingParsedTranscript(meta: meta(ref, parsed), mainline: mainline, sidechains: sidechains, unknownLines: parsed.unknown)
    }

    func loadSidechain(_ ref: CodingSessionFileRef, id: String) throws -> [CodingMessage] {
        let file = Self.subagentsDir(ref).appendingPathComponent("\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try CodingImageBudget.decoding { try Self.parse(file, includeSidechain: true).messages }
    }

    func sessionPaths(_ meta: CodingSessionMeta) -> [String] {
        var paths = [meta.filePath]
        let sidecar = URL(fileURLWithPath: meta.filePath).deletingLastPathComponent().appendingPathComponent(meta.nativeId)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDir), isDir.boolValue {
            paths.append(sidecar.path)
        }
        return paths
    }

    // MARK: - 解析

    private struct Pending {
        var messageId: String?
        var content = CodingParse.Content()
        var thinking: [String] = []
        var toolCalls: [CodingToolCall] = []
        var timestamp: Int64?
        var model: String?
    }

    struct Parse {
        var messages: [CodingMessage]
        var title: String
        var cwd: String
        var gitBranch: String?
        var model: String?
        var tokens: Int64
        var created: Int64
        var updated: Int64
        var unknown: Int
    }

    static func parse(_ url: URL, includeSidechain: Bool) throws -> Parse {
        var messages: [CodingMessage] = []
        var toolIndex: [String: (Int, Int)] = [:]
        var customTitle = "", fallbackTitle = "", cwd = ""
        var gitBranch: String?, model: String?
        var tokens: Int64 = 0, created: Int64 = 0, updated: Int64 = 0
        var unknown = 0
        var pending: Pending?

        func flush() {
            guard let p = pending else { return }
            pending = nil
            if p.content.text.isEmpty && p.thinking.isEmpty && p.toolCalls.isEmpty && p.content.imageCount == 0 { return }
            let (text, truncated) = CodingParse.clip(p.content.text, CodingLimits.maxMessageText)
            let thinking = p.thinking.isEmpty ? nil : CodingParse.clip(p.thinking.joined(separator: "\n\n"), CodingLimits.maxToolIO).0
            let index = messages.count
            for (ti, call) in p.toolCalls.enumerated() where !call.id.isEmpty {
                toolIndex[call.id] = (index, ti)
            }
            messages.append(CodingMessage(seq: 0, role: .assistant, kind: .text, text: text, truncated: truncated,
                                          toolCalls: p.toolCalls, thinking: thinking, timestamp: p.timestamp,
                                          model: p.model, imageCount: p.content.imageCount, images: p.content.images))
        }

        try CodingParse.forEachLine(url) { row in
            guard let row else {
                unknown += 1
                return
            }
            let type = row["type"] as? String ?? ""
            if type == "custom-title" {
                if let t = row["customTitle"] as? String, !CodingParse.isBlank(t) { customTitle = CodingParse.trimmed(t) }
                return
            }
            if type != "user" && type != "assistant" && type != "system" {
                if type.isEmpty || !knownSkipTypes.contains(type) { unknown += 1 }
                return
            }
            if cwd.isEmpty, let c = row["cwd"] as? String { cwd = c }
            if let branch = row["gitBranch"] as? String, !branch.isEmpty { gitBranch = branch }
            let ts = CodingParse.epochMs(row["timestamp"])
            if ts > 0 {
                if created == 0 { created = ts }
                if ts > updated { updated = ts }
            }
            if CodingParse.bool(row["isSidechain"]) && !includeSidechain { return }
            let message = row["message"] as? CodingParse.JSON

            if type == "system" {
                flush()
                if row["subtype"] as? String == "compact_boundary" {
                    messages.append(.make(.system, .compactSummary, "── Context compacted ──", ts: ts, clip: false))
                } else if let content = row["content"] as? String, !content.isEmpty {
                    let (text, truncated) = CodingParse.clip(content, CodingLimits.maxToolIO)
                    messages.append(CodingMessage(seq: 0, role: .system, kind: .meta, text: text, truncated: truncated, timestamp: ts > 0 ? ts : nil))
                }
                return
            }

            if type == "user" {
                flush()
                guard let message else { return }
                var parsed = CodingParse.Content()
                if let text = message["content"] as? String {
                    parsed.push(text)
                } else if let blocks = message["content"] as? [Any] {
                    for case let block as CodingParse.JSON in blocks {
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String { parsed.push(t) }
                        case "tool_result":
                            let id = block["tool_use_id"] as? String ?? ""
                            if let (mi, ti) = toolIndex[id] {
                                let result = CodingParse.toolResultParts(block["content"])
                                messages[mi].toolCalls[ti].output = CodingParse.clip(result.text, CodingLimits.maxToolIO).0
                                if CodingParse.bool(block["is_error"]) { messages[mi].toolCalls[ti].isError = true }
                                messages[mi].imageCount += result.imageCount
                                messages[mi].images += result.images
                            }
                        default:
                            if CodingParse.isImagePart(block) { parsed.append(CodingParse.contentParts(block)) }
                        }
                    }
                }
                if parsed.text.isEmpty && parsed.imageCount == 0 { return }
                let kind: CodingMessageKind
                if CodingParse.bool(row["isCompactSummary"]) {
                    kind = .compactSummary
                } else if CodingParse.bool(row["isMeta"]) || CodingParse.isInjectedUserContent(parsed.text) {
                    kind = .meta
                } else {
                    kind = .text
                }
                if kind == .text && fallbackTitle.isEmpty { fallbackTitle = CodingParse.cleanTitleCandidate(parsed.text) }
                let (text, truncated) = CodingParse.clip(parsed.text, CodingLimits.maxMessageText)
                messages.append(CodingMessage(seq: 0, role: .user, kind: kind, text: text, truncated: truncated,
                                              timestamp: ts > 0 ? ts : nil, imageCount: parsed.imageCount, images: parsed.images))
                return
            }

            // assistant
            guard let message else { return }
            let messageId = message["id"] as? String
            let needNew: Bool
            switch (pending, messageId) {
            case (nil, _): needNew = true
            case let (p?, id?): needNew = p.messageId.map { $0 != id } ?? false
            case (_?, nil): needNew = false
            }
            if needNew {
                flush()
                pending = Pending(messageId: messageId, timestamp: ts > 0 ? ts : nil)
            }
            if pending?.messageId == nil { pending?.messageId = messageId }
            if let m = message["model"] as? String, !m.isEmpty, m != "<synthetic>" {
                pending?.model = m
                model = m
            }
            if let usage = message["usage"] as? CodingParse.JSON {
                tokens += CodingParse.int64(usage["input_tokens"]) + CodingParse.int64(usage["output_tokens"])
                    + CodingParse.int64(usage["cache_creation_input_tokens"])
            }
            if let blocks = message["content"] as? [Any] {
                for case let block as CodingParse.JSON in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !CodingParse.isBlank(t) { pending?.content.push(t) }
                    case "thinking":
                        if let t = block["thinking"] as? String, !CodingParse.isBlank(t) { pending?.thinking.append(t) }
                    case "tool_use":
                        let call = CodingParse.toolCall(id: block["id"] as? String ?? "",
                                                        name: block["name"] as? String ?? "tool",
                                                        input: block["input"] ?? NSNull())
                        pending?.toolCalls.append(call)
                    default:
                        if CodingParse.isImagePart(block) { pending?.content.append(CodingParse.contentParts(block)) }
                    }
                }
            } else if let text = message["content"] as? String, !CodingParse.isBlank(text) {
                pending?.content.push(text)
            }
        }
        flush()
        CodingParse.assignSeq(&messages)
        let title = !customTitle.isEmpty ? customTitle : (!fallbackTitle.isEmpty ? fallbackTitle : CodingLimits.untitled)
        return Parse(messages: messages, title: title, cwd: cwd, gitBranch: gitBranch, model: model,
                     tokens: tokens, created: created, updated: updated, unknown: unknown)
    }

    private func meta(_ ref: CodingSessionFileRef, _ p: Parse) -> CodingSessionMeta {
        CodingSessionMeta(
            key: "claude-code:\(ref.nativeId)", nativeId: ref.nativeId, agent: .claudeCode, title: p.title,
            projectPath: p.cwd, projectName: CodingParse.projectName(p.cwd), filePath: ref.filePath,
            createdAt: p.created > 0 ? p.created : ref.mtimeMs, updatedAt: p.updated > 0 ? p.updated : ref.mtimeMs,
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: p.gitBranch, model: p.model, tokensUsed: p.tokens > 0 ? p.tokens : nil,
            archived: false, source: nil
        )
    }

    private static func subagentsDir(_ ref: CodingSessionFileRef) -> URL {
        URL(fileURLWithPath: ref.filePath).deletingLastPathComponent()
            .appendingPathComponent(ref.nativeId).appendingPathComponent("subagents")
    }

    private static func listSidechains(_ ref: CodingSessionFileRef) -> [CodingSidechain] {
        let dir = subagentsDir(ref)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [CodingSidechain] = []
        for name in entries where name.hasSuffix(".jsonl") {
            let id = String(name.dropLast(6))
            var info = CodingSidechain(id: id)
            if let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).meta.json")),
               let meta = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON {
                info.agentType = meta["agentType"] as? String
                info.description = meta["description"] as? String
                info.toolUseId = meta["toolUseId"] as? String
            }
            out.append(info)
        }
        return out
    }
}
extension ClaudeCodeAdapter {
    /// 选中 `~/.claude` 形态（含 projects/）或直接选中 projects 目录都认
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let nested = dir.appendingPathComponent("projects", isDirectory: true)
        return ClaudeCodeAdapter(root: CodingLocations.isDirectory(nested) ? nested : dir)
    }
}
#endif
