#if os(macOS)
import Foundation

/// Qoder CLI：`~/.qoder/projects/<project-key>/<session-id>.jsonl`（Wake `adapters/qoder.rs`）。
/// user/assistant/system/attachment 行以 uuid + parentUuid 组成可回退的消息树，尾部 `active-leaf` 指向当前分支（显式 null =
/// 已回退成空会话）；标题 / 工作目录 / 运行配置是独立追加的元数据行。会话同名目录是 state/subagents 边车，不是顶层会话
struct QoderAdapter: CodingSessionAdapter {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// `QODER_CONFIG_DIR/projects` 里真有会话才用——空候选不能遮掉默认根（Dock 启动与 shell 启动看到的环境常不同）
    static func make(home: URL, environment: [String: String]) -> QoderAdapter {
        if let custom = environment["QODER_CONFIG_DIR"], !custom.isEmpty {
            let candidate = QoderAdapter(root: URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("projects", isDirectory: true))
            if !candidate.listSessionFiles().isEmpty { return candidate }
        }
        return QoderAdapter(root: home.appendingPathComponent(".qoder/projects", isDirectory: true))
    }

    var agent: CodingAgent { .qoder }
    var dataRoots: [URL] { [root] }

    private static let knownMetadataTypes: Set<String> = [
        "summary", "custom-title", "ai-title", "last-prompt", "tag", "workspace-directories", "runtime-config", "mode",
        "content-replacement", "file-history-snapshot", "token-stats", "active-leaf", "relocated", "worktree-state",
    ]

    /// 根直属与下一层 project-key 目录直属两种形态都探（自定义位置可以直接选中某个 project-key 目录）
    func listSessionFiles() -> [CodingSessionFileRef] {
        let fm = FileManager.default
        func direct(_ dir: URL) -> [CodingSessionFileRef] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: CodingParse.refKeys)) ?? [])
                .compactMap { CodingParse.defaultFileRef(.qoder, $0) }
        }
        var refs = direct(root)
        for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            refs += direct(entry)
        }
        return refs.sorted { $0.filePath < $1.filePath }
    }

    /// root/<session>.jsonl 或 root/<project-key>/<session>.jsonl；更深的 state/subagents/memory 都是边车
    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        let base = CodingParse.canonicalPath(root.path)
        let path = CodingParse.canonicalPath(url.path)
        guard path.hasPrefix(base + "/"), path.dropFirst(base.count + 1).split(separator: "/").count <= 2 else { return nil }
        return CodingParse.defaultFileRef(.qoder, url)
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

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let parsed = try Self.parse(URL(fileURLWithPath: ref.filePath))
        return CodingParsedSession(meta: meta(ref, parsed), units: CodingParse.units(parsed.messages), unknownLines: parsed.unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let parsed = try CodingImageBudget.decoding { try Self.parse(URL(fileURLWithPath: ref.filePath)) }
        return CodingParsedTranscript(meta: meta(ref, parsed), mainline: parsed.messages, sidechains: [], unknownLines: parsed.unknown)
    }

    // MARK: - 解析

    private enum ActiveLeaf {
        case missing
        case empty
        case uuid(String)
    }

    private struct Node {
        var row: CodingParse.JSON
        var parent: String?
    }

    private struct Pending {
        var messageId: String?
        var content = CodingParse.Content()
        var thinking: [String] = []
        var toolCalls: [CodingToolCall] = []
        var timestamp: Int64?
        var model: String?
    }

    struct Parse {
        var messages: [CodingMessage] = []
        var customTitle = ""
        var aiTitle = ""
        var lastPrompt = ""
        var cwd = ""
        var gitBranch: String?
        var model: String?
        var tokens: Int64 = 0
        var created: Int64 = 0
        var updated: Int64 = 0
        var unknown = 0
    }

    /// trim 后非空
    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = CodingParse.trimmed(s)
        return t.isEmpty ? nil : t
    }

    /// total_tokens 优先；否则 Anthropic 四项和；再否则 OpenAI 两项和
    static func usageTokens(_ usage: CodingParse.JSON) -> Int64 {
        let total = CodingParse.int64(usage["total_tokens"])
        if total > 0 { return total }
        let anthropic = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(Int64(0)) { $0 + CodingParse.int64(usage[$1]) }
        if anthropic > 0 { return anthropic }
        return CodingParse.int64(usage["prompt_tokens"]) + CodingParse.int64(usage["completion_tokens"])
    }

    static func parse(_ url: URL) throws -> Parse {
        var p = Parse()
        var nodes: [String: Node] = [:]
        var order: [String] = []
        var leaf = ActiveLeaf.missing
        var relocatedCwd = ""
        var worktreeCwd = ""
        var worktreeBranch: String?
        var runtimeModel: String?

        try CodingParse.forEachLine(url) { row in
            guard let row else {
                p.unknown += 1
                return
            }
            let type = row["type"] as? String ?? ""
            switch type {
            case "custom-title":
                if let t = string(row["customTitle"]) { p.customTitle = t }
            case "ai-title":
                if let t = string(row["aiTitle"]) { p.aiTitle = t }
            case "last-prompt":
                if let t = string(row["lastPrompt"]) { p.lastPrompt = t }
            case "active-leaf":
                let value = row["leafUuid"]
                if value is NSNull {
                    leaf = .empty
                } else if let id = value as? String {
                    leaf = .uuid(id)
                } else {
                    p.unknown += 1
                }
            case "relocated":
                if let c = string(row["relocatedCwd"]) { relocatedCwd = c }
            case "worktree-state":
                let value = row["worktreeSession"]
                if value is NSNull {
                    worktreeCwd = ""
                    worktreeBranch = nil
                } else if let worktree = value as? CodingParse.JSON {
                    // 每条都是当前状态快照，缺字段也不沿用上一条
                    worktreeCwd = string(worktree["worktreePath"]) ?? ""
                    worktreeBranch = string(worktree["worktreeBranch"])
                } else {
                    p.unknown += 1
                }
            case "runtime-config":
                runtimeModel = string(row["model"]) ?? string((row["model"] as? CodingParse.JSON)?["name"])
            case "user", "assistant", "system", "attachment":
                // attachment 不展示，但会成为下一条消息的 parent，必须留在树里，否则 active-leaf 回溯在这里断链
                if CodingParse.bool(row["isSidechain"]) { return }
                guard let uuid = string(row["uuid"]) else {
                    p.unknown += 1
                    return
                }
                if nodes[uuid] == nil { order.append(uuid) }
                nodes[uuid] = Node(row: row, parent: string(row["logicalParentUuid"]) ?? string(row["parentUuid"]))
            default:
                if !knownMetadataTypes.contains(type) { p.unknown += 1 }
            }
        }

        let chain = activeChain(nodes, order, leaf, &p.unknown)
        var messages: [CodingMessage] = []
        var toolIndex: [String: (Int, Int)] = [:]
        var usageSeen = Set<String>()
        var pending: Pending?
        var cwd = ""
        var gitBranch: String?
        var model = runtimeModel

        func flush() {
            guard let a = pending else { return }
            pending = nil
            if CodingParse.isBlank(a.content.text) && a.toolCalls.isEmpty && a.thinking.isEmpty && a.content.images.isEmpty { return }
            let (text, truncated) = CodingParse.clip(CodingParse.trimmed(a.content.text), CodingLimits.maxMessageText)
            let thinking = a.thinking.isEmpty ? nil : CodingParse.clip(a.thinking.joined(separator: "\n\n"), CodingLimits.maxToolIO).0
            let index = messages.count
            for (ti, call) in a.toolCalls.enumerated() where !call.id.isEmpty {
                toolIndex[call.id] = (index, ti)
            }
            messages.append(CodingMessage(seq: 0, role: .assistant, kind: .text, text: text, truncated: truncated,
                                          toolCalls: a.toolCalls, thinking: thinking, timestamp: a.timestamp,
                                          model: a.model, imageCount: a.content.imageCount, images: a.content.images))
        }

        for row in chain {
            let type = row["type"] as? String ?? ""
            if let c = string(row["cwd"]) { cwd = c }
            if let b = string(row["gitBranch"]) { gitBranch = b }
            let ts = CodingParse.epochMs(row["timestamp"])
            if ts > 0 {
                if p.created == 0 { p.created = ts }
                p.updated = max(p.updated, ts)
            }

            if type == "system" {
                flush()
                if row["subtype"] as? String == "compact_boundary" {
                    messages.append(.make(.system, .compactSummary, "── Context compacted ──", ts: ts, clip: false))
                }
                continue
            }
            if type == "attachment" { continue }
            guard let rawMessage = row["message"] else {
                p.unknown += 1
                continue
            }
            let message = rawMessage as? CodingParse.JSON ?? [:]

            if type == "user" {
                flush()
                var parsed = CodingParse.Content()
                if let text = message["content"] as? String {
                    parsed.push(text)
                } else if let blocks = message["content"] as? [Any] {
                    for case let block as CodingParse.JSON in blocks {
                        let blockType = block["type"] as? String
                        if blockType == "text" {
                            if let t = block["text"] as? String { parsed.push(t) }
                        } else if CodingParse.isImagePart(block) {
                            parsed.append(CodingParse.contentParts(block))
                        } else if blockType == "tool_result", let (mi, ti) = toolIndex[block["tool_use_id"] as? String ?? ""] {
                            let result = CodingParse.toolResultParts(block["content"])
                            messages[mi].toolCalls[ti].output = CodingParse.clip(result.text, CodingLimits.maxToolIO).0
                            messages[mi].toolCalls[ti].isError = CodingParse.bool(block["is_error"])
                            messages[mi].imageCount += result.imageCount
                            messages[mi].images += result.images
                        }
                    }
                }
                if parsed.text.isEmpty && parsed.images.isEmpty { continue }
                let originKind = (row["origin"] as? CodingParse.JSON)?["kind"] as? String
                let isMeta = CodingParse.bool(row["isMeta"]) || CodingParse.bool(row["isVisibleInTranscriptOnly"])
                    || (originKind.map { $0 != "human" } ?? false) || CodingParse.isInjectedUserContent(parsed.text)
                let kind: CodingMessageKind = CodingParse.bool(row["isCompactSummary"]) ? .compactSummary : (isMeta ? .meta : .text)
                let (text, truncated) = CodingParse.clip(parsed.text, CodingLimits.maxMessageText)
                messages.append(CodingMessage(seq: 0, role: .user, kind: kind, text: text, truncated: truncated,
                                              timestamp: ts > 0 ? ts : nil, imageCount: parsed.imageCount, images: parsed.images))
                continue
            }

            // assistant：同 message.id 的分片合成一条
            let messageId = string(message["id"])
            let needNew: Bool
            switch (pending, messageId) {
            case (nil, _): needNew = true
            case let (current?, id?): needNew = current.messageId.map { $0 != id } ?? false
            case (_?, nil): needNew = false
            }
            if needNew {
                flush()
                pending = Pending(messageId: messageId, timestamp: ts > 0 ? ts : nil)
            }
            if pending?.messageId == nil { pending?.messageId = messageId }
            if let m = string(message["model"]), m != "<synthetic>" {
                pending?.model = m
                model = m
            }
            // 分片各自带同一份 usage：按 message.id（没有就 uuid）只计一次
            if usageSeen.insert(messageId ?? string(row["uuid"]) ?? "").inserted, let usage = message["usage"] as? CodingParse.JSON {
                p.tokens += usageTokens(usage)
            }
            if let text = message["content"] as? String {
                if !CodingParse.isBlank(text) { pending?.content.push(text) }
            } else if let blocks = message["content"] as? [Any] {
                for case let block as CodingParse.JSON in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !CodingParse.isBlank(t) { pending?.content.push(t) }
                    case "thinking":
                        if let t = block["thinking"] as? String, !CodingParse.isBlank(t) { pending?.thinking.append(t) }
                    case "tool_use":
                        pending?.toolCalls.append(CodingParse.toolCall(id: block["id"] as? String ?? "",
                                                                       name: block["name"] as? String ?? "tool",
                                                                       input: block["input"] ?? NSNull()))
                    default:
                        if CodingParse.isImagePart(block) { pending?.content.append(CodingParse.contentParts(block)) }
                    }
                }
            }
        }
        flush()
        CodingParse.assignSeq(&messages)
        p.messages = messages
        p.cwd = !worktreeCwd.isEmpty ? worktreeCwd : (!relocatedCwd.isEmpty ? relocatedCwd : cwd)
        p.gitBranch = worktreeBranch ?? gitBranch
        p.model = model
        return p
    }

    /// 从 active-leaf 沿 parent 回溯出当前分支（成环 / 断链各记一次 unknown）；再按文件顺序把同 message.id 的兄弟分片和挂在
    /// 分片下的 tool_result 行收回——只沿 parent 链只拿得到其中一个分片
    private static func activeChain(_ nodes: [String: Node], _ order: [String], _ leaf: ActiveLeaf, _ unknown: inout Int) -> [CodingParse.JSON] {
        var cursor: String
        switch leaf {
        case .empty:
            return []
        case .uuid(let id) where nodes[id] != nil:
            cursor = id
        case .missing, .uuid:
            // 老版本没有 active-leaf，或指向已被压缩 / 损坏的节点：保守取文件里最后一个消息节点
            guard let last = order.last else { return [] }
            cursor = last
        }
        var seen = Set<String>()
        var chainIds: [String] = []
        while true {
            guard seen.insert(cursor).inserted, let node = nodes[cursor] else {
                unknown += 1
                break
            }
            chainIds.append(cursor)
            guard let parent = node.parent else { break }
            cursor = parent
        }
        chainIds.reverse()

        var fragmentsByMessage: [String: [String]] = [:]
        var messageByFragment: [String: String] = [:]
        for id in order {
            guard let node = nodes[id], node.row["type"] as? String == "assistant",
                  let messageId = string((node.row["message"] as? CodingParse.JSON)?["id"]) else { continue }
            fragmentsByMessage[messageId, default: []].append(id)
            messageByFragment[id] = messageId
        }
        var resultsByMessage: [String: [String]] = [:]
        for id in order {
            guard let node = nodes[id], node.row["type"] as? String == "user",
                  let blocks = (node.row["message"] as? CodingParse.JSON)?["content"] as? [Any],
                  blocks.contains(where: { ($0 as? CodingParse.JSON)?["type"] as? String == "tool_result" }),
                  let parent = string(node.row["parentUuid"]), let messageId = messageByFragment[parent] else { continue }
            resultsByMessage[messageId, default: []].append(id)
        }

        var out: [CodingParse.JSON] = []
        var emitted = Set<String>()
        for id in chainIds where !emitted.contains(id) {
            guard let node = nodes[id] else { continue }
            guard let messageId = messageByFragment[id] else {
                emitted.insert(id)
                out.append(node.row)
                continue
            }
            for member in (fragmentsByMessage[messageId] ?? []) + (resultsByMessage[messageId] ?? []) {
                if emitted.insert(member).inserted, let row = nodes[member]?.row { out.append(row) }
            }
        }
        return out
    }

    private func meta(_ ref: CodingSessionFileRef, _ p: Parse) -> CodingSessionMeta {
        let title = [p.customTitle, p.aiTitle, p.lastPrompt].lazy.map(CodingParse.cleanTitleCandidate).first { !$0.isEmpty }
            ?? CodingParse.titleFromMessages(p.messages) ?? CodingLimits.untitled
        return CodingSessionMeta(
            key: "qoder:\(ref.nativeId)", nativeId: ref.nativeId, agent: .qoder, title: title,
            projectPath: p.cwd, projectName: CodingParse.projectName(p.cwd), filePath: ref.filePath,
            createdAt: p.created > 0 ? p.created : ref.mtimeMs, updatedAt: max(p.updated, ref.mtimeMs),
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: p.gitBranch, model: p.model, tokensUsed: p.tokens > 0 ? p.tokens : nil,
            archived: false, source: nil
        )
    }
}
extension QoderAdapter {
    /// 选中 `~/.qoder`（含 projects/）或 projects 目录、单个 project-key 目录都认（列举本来就探两层）
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let nested = dir.appendingPathComponent("projects", isDirectory: true)
        return QoderAdapter(root: CodingLocations.isDirectory(nested) ? nested : dir)
    }
}
#endif
