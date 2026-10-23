#if os(macOS)
import Foundation
import SQLite3

/// Codex：`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` + `archived_sessions/`（Wake `adapters/codex.rs`）。
/// state DB（`state_5.sqlite`，只读）给快路径 meta；用户在 Codex 里手动起的名字优先于首条消息推导。
struct CodexAdapter: CodingSessionAdapter {
    let sessionsDir: URL
    let archivedDir: URL
    let stateDB: URL
    /// 两个数据根可以分别停用（位置 sheet 的开关）；默认都扫
    var scanSessions = true
    var scanArchived = true

    /// 认 `CODEX_HOME`（探到真会话目录才采信），否则 `~/.codex`
    static func make(home: URL, environment: [String: String]) -> CodexAdapter {
        var root = home.appendingPathComponent(".codex", isDirectory: true)
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            let fm = FileManager.default
            if fm.fileExists(atPath: url.appendingPathComponent("sessions").path)
                || fm.fileExists(atPath: url.appendingPathComponent("archived_sessions").path) {
                root = url
            }
        }
        return CodexAdapter(sessionsDir: root.appendingPathComponent("sessions", isDirectory: true),
                            archivedDir: root.appendingPathComponent("archived_sessions", isDirectory: true),
                            stateDB: root.appendingPathComponent("state_5.sqlite"))
    }

    var agent: CodingAgent { .codex }
    var dataRoots: [URL] { (scanSessions ? [sessionsDir] : []) + (scanArchived ? [archivedDir] : []) }

    func listSessionFiles() -> [CodingSessionFileRef] {
        (scanSessions ? CodingParse.listJSONLRefs(sessionsDir, .codex, nativeId: Self.rolloutNativeId) : [])
            + (scanArchived ? CodingParse.listJSONLRefs(archivedDir, .codex, nativeId: Self.rolloutNativeId) : [])
    }

    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        guard var ref = CodingParse.defaultFileRef(.codex, url) else { return nil }
        ref.nativeId = Self.rolloutNativeId(ref.nativeId)
        return ref
    }

    /// rollout-2026-08-14T11-47-18-<uuid> → uuid
    static func rolloutNativeId(_ stem: String) -> String {
        guard stem.hasPrefix("rollout-") else { return stem }
        let rest = Array(stem.utf8.dropFirst(8))
        if rest.count > 20, rest[10] == UInt8(ascii: "T") {
            return String(decoding: rest[20...], as: UTF8.self)
        }
        return stem
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let parsed = try Self.parseRollout(URL(fileURLWithPath: ref.filePath))
        return CodingParsedSession(meta: meta(ref, parsed), units: CodingParse.units(parsed.messages), unknownLines: parsed.unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let parsed = try CodingImageBudget.decoding { try Self.parseRollout(URL(fileURLWithPath: ref.filePath)) }
        return CodingParsedTranscript(meta: meta(ref, parsed), mainline: parsed.messages, sidechains: [], unknownLines: parsed.unknown)
    }

    // MARK: - state DB 快路径

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? {
        guard let rows = Self.readThreads(stateDB) else { return nil }
        // rollout_path 是写库那台机器上的绝对路径 → 按文件名匹配
        var byName: [String: ThreadRow] = [:]
        for row in rows { byName[(row.rolloutPath as NSString).lastPathComponent] = row }
        var out: [String: CodingSessionMeta] = [:]
        for ref in refs {
            guard let row = byName[(ref.filePath as NSString).lastPathComponent] else { continue }
            var title = CodingLimits.untitled
            if let name = row.name, !CodingParse.isBlank(name) {
                title = name
            } else if !CodingParse.isInjectedUserContent(row.title) {
                let cleaned = CodingParse.cleanTitleCandidate(row.title)
                if !cleaned.isEmpty { title = cleaned }
            }
            out[ref.filePath] = CodingSessionMeta(
                key: "codex:\(row.id)", nativeId: row.id, agent: .codex, title: title,
                projectPath: row.cwd, projectName: CodingParse.projectName(row.cwd), filePath: ref.filePath,
                createdAt: row.createdAtMs ?? ref.mtimeMs, updatedAt: row.updatedAtMs ?? ref.mtimeMs,
                messageCount: 0, sizeBytes: ref.size, gitBranch: row.gitBranch, model: row.model,
                tokensUsed: row.tokensUsed, archived: row.archived, source: row.source
            )
        }
        return out
    }

    /// state DB 的 title 是用户手动命名，压过首条消息推导；key / id 以 state 线程 id 为准；
    /// source 相反（rollout originator 更精确，quick 只兜底）
    func mergeQuickMeta(_ parsed: CodingSessionMeta, _ quick: CodingSessionMeta) -> CodingSessionMeta {
        var merged = parsed
        if !quick.title.isEmpty && quick.title != CodingLimits.untitled { merged.title = quick.title }
        merged.key = quick.key
        merged.nativeId = quick.nativeId
        if merged.source == nil { merged.source = quick.source }
        if merged.model == nil { merged.model = quick.model }
        if merged.tokensUsed == nil { merged.tokensUsed = quick.tokensUsed }
        return merged
    }

    struct ThreadRow {
        var id: String
        var rolloutPath: String
        var cwd: String
        var title: String
        var name: String?
        var tokensUsed: Int64?
        var archived: Bool
        var gitBranch: String?
        var model: String?
        var source: String?
        var createdAtMs: Int64?
        var updatedAtMs: Int64?
    }

    /// 只读读 state DB（`CodingSQLiteReader` 三级：readonly 直开 + 探测 → 拷三件套 → 放弃）
    static func readThreads(_ db: URL) -> [ThreadRow]? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        var rows: [ThreadRow] = []
        let sql = """
            SELECT id, rollout_path, cwd, title, name, tokens_used, archived,
                   git_branch, model, source, created_at_ms, updated_at_ms FROM threads
            """
        guard let reader = CodingSQLiteReader.open(db, tag: "codex-state"), reader.query(sql, row: { r in
            rows.append(ThreadRow(id: r.text(0) ?? "", rolloutPath: r.text(1) ?? "", cwd: r.text(2) ?? "", title: r.text(3) ?? "",
                                  name: r.text(4), tokensUsed: r.int64(5), archived: r.int64(6) == 1, gitBranch: r.text(7),
                                  model: r.text(8), source: r.text(9), createdAtMs: r.int64(10), updatedAtMs: r.int64(11)))
        }) else {
            CodingDiagnostics.log("🧭 Codex state DB 读不了（直开与拷贝都失败），标题退回首条消息推导：\(db.path)")
            return nil
        }
        return rows
    }

    // MARK: - rollout 解析

    struct Parse {
        var messages: [CodingMessage]
        var cwd: String
        var gitBranch: String?
        var model: String?
        var source: String?
        var tokens: Int64
        var created: Int64
        var updated: Int64
        var unknown: Int
    }

    private static func friendlySource(_ originator: String) -> String? {
        switch originator {
        case "codex_cli_rs", "codex-tui": return "CLI"
        case "codex_exec": return "exec"
        case "codex_vscode": return "IDE extension"
        case "codex_work_desktop": return "Codex Desktop"
        case "": return nil
        default: return originator
        }
    }

    private static func cleanUserText(_ text: String) -> String {
        CodingParse.trimmed(CodingParse.stripImageTags(CodingParse.unwrapFilePreamble(text) ?? text))
    }

    static func parseRollout(_ url: URL) throws -> Parse {
        var messages: [CodingMessage] = []
        var eventFallback: [CodingMessage] = []
        var toolIndex: [String: (Int, Int)] = [:]
        var pendingReviewMessage: Int?
        var cwd = ""
        var gitBranch: String?, model: String?, source: String?
        var tokens: Int64 = 0, created: Int64 = 0, updated: Int64 = 0
        var unknown = 0
        var sawSessionMeta = false

        try CodingParse.forEachLine(url) { row in
            guard let row else {
                unknown += 1
                return
            }
            let ts = CodingParse.epochMs(row["timestamp"])
            if ts > 0 {
                if created == 0 { created = ts }
                if ts > updated { updated = ts }
            }
            let type = row["type"] as? String ?? ""
            guard let payloadValue = row["payload"] else {
                if type != "compacted" && type != "world_state" { unknown += 1 }
                return
            }
            let payload = payloadValue as? CodingParse.JSON ?? [:]

            switch type {
            case "session_meta":
                guard !sawSessionMeta else { break }
                sawSessionMeta = true
                if let c = payload["cwd"] as? String { cwd = c }
                if let o = payload["originator"] as? String { source = friendlySource(o) }
                if let branch = (payload["git"] as? CodingParse.JSON)?["branch"] as? String { gitBranch = branch }
            case "turn_context":
                if cwd.isEmpty, let c = payload["cwd"] as? String { cwd = c }
                if let m = payload["model"] as? String { model = m }
            case "response_item":
                switch payload["type"] as? String ?? "" {
                case "message":
                    let role = payload["role"] as? String ?? ""
                    let content = payload["content"]
                    let blocks: [Any?] = (content as? [Any]).map { $0.map { Optional($0) } } ?? [content]
                    var parsedMessage = CodingParse.Content()
                    for block in blocks {
                        var parsed = CodingParse.contentParts(block)
                        parsed.text = role == "user" ? cleanUserText(parsed.text) : CodingParse.trimmed(parsed.text)
                        parsedMessage.append(parsed)
                    }
                    if parsedMessage.text.isEmpty && parsedMessage.imageCount == 0 { break }
                    let text = parsedMessage.text
                    var message: CodingMessage
                    switch role {
                    case "user":
                        if let results = reviewResultsFromUserAction(text) {
                            pendingReviewMessage = messages.count
                            message = .make(.assistant, .text, results, ts: ts, clip: true)
                        } else {
                            message = .make(.user, CodingParse.userKind(text), text, ts: ts, clip: true)
                        }
                    case "assistant":
                        message = .make(.assistant, .text, formatReviewJSON(text) ?? text, ts: ts, clip: true)
                    default:
                        message = .make(.system, .meta, text, ts: ts, clip: true)
                    }
                    message.imageCount = parsedMessage.imageCount
                    message.images = parsedMessage.images
                    messages.append(message)
                case "reasoning":
                    var parts: [String] = []
                    if let summary = payload["summary"] as? [Any] {
                        for case let item as CodingParse.JSON in summary {
                            if let t = item["text"] as? String { parts.append(t) }
                        }
                    }
                    guard !parts.isEmpty else { break }
                    let thinking = CodingParse.clip(parts.joined(separator: "\n\n"), CodingLimits.maxToolIO).0
                    if let last = messages.indices.last, messages[last].role == .assistant,
                       messages[last].text.isEmpty, messages[last].thinking == nil {
                        messages[last].thinking = thinking
                    } else {
                        var message = CodingMessage.make(.assistant, .text, "", ts: ts, clip: true)
                        message.thinking = thinking
                        messages.append(message)
                    }
                case "function_call", "custom_tool_call", "local_shell_call":
                    let callId = (payload["call_id"] ?? payload["id"]) as? String ?? ""
                    let name = payload["name"] as? String ?? "exec"
                    let rawInput: String
                    if let arguments = payload["arguments"] as? String {
                        rawInput = arguments
                    } else if let input = payload["input"] as? String {
                        rawInput = input
                    } else if let action = payload["action"] {
                        rawInput = CodingParse.compactJSON(action) ?? ""
                    } else {
                        rawInput = ""
                    }
                    let previewSource: Any = (try? JSONSerialization.jsonObject(with: Data(rawInput.utf8), options: .fragmentsAllowed)) ?? rawInput
                    let call = CodingToolCall(id: callId, name: name, inputPreview: CodingParse.makePreview(previewSource),
                                              input: rawInput.isEmpty ? nil : CodingParse.clip(rawInput, CodingLimits.maxToolIO).0,
                                              output: nil, isError: false, sidechainRef: nil)
                    let needHost = !(messages.last.map { $0.role == .assistant && $0.kind == .text } ?? false)
                    if needHost { messages.append(.make(.assistant, .text, "", ts: ts, clip: true)) }
                    let hostIndex = messages.count - 1
                    messages[hostIndex].toolCalls.append(call)
                    if !callId.isEmpty { toolIndex[callId] = (hostIndex, messages[hostIndex].toolCalls.count - 1) }
                case "function_call_output", "custom_tool_call_output":
                    let callId = payload["call_id"] as? String ?? ""
                    if let (mi, ti) = toolIndex[callId] {
                        let output = payload["output"]
                        let content = (output as? CodingParse.JSON)?["content"] ?? output
                        let parsed = CodingParse.toolResultParts(content)
                        messages[mi].toolCalls[ti].output = CodingParse.clip(parsed.text, CodingLimits.maxToolIO).0
                        messages[mi].imageCount += parsed.imageCount
                        messages[mi].images += parsed.images
                    }
                default:
                    break
                }
            case "event_msg":
                switch payload["type"] as? String ?? "" {
                case "token_count":
                    if let usage = ((payload["info"] as? CodingParse.JSON)?["total_token_usage"] as? CodingParse.JSON),
                       usage["total_tokens"] != nil {
                        tokens = CodingParse.int64(usage["total_tokens"])
                    }
                case "user_message":
                    if let m = payload["message"] as? String {
                        let cleaned = cleanUserText(m)
                        if !CodingParse.isBlank(cleaned) {
                            if let results = reviewResultsFromUserAction(cleaned) {
                                eventFallback.append(.make(.assistant, .text, results, ts: ts, clip: true))
                            } else {
                                eventFallback.append(.make(.user, CodingParse.userKind(cleaned), CodingParse.trimmed(cleaned), ts: ts, clip: true))
                            }
                        }
                    }
                case "agent_message":
                    if let m = payload["message"] as? String, !CodingParse.isBlank(m) {
                        eventFallback.append(.make(.assistant, .text, formatReviewJSON(m) ?? CodingParse.trimmed(m), ts: ts, clip: true))
                    }
                case "item_completed":
                    let item = payload["item"] as? CodingParse.JSON
                    if item?["type"] as? String == "ExitedReviewMode",
                       let review = item?["review_output"] as? CodingParse.JSON, let markdown = formatReviewOutput(review) {
                        let reviewMessage = CodingMessage.make(.assistant, .text, markdown, ts: ts, clip: true)
                        if let index = pendingReviewMessage, index + 1 == messages.count {
                            pendingReviewMessage = nil
                            messages[index] = reviewMessage
                        } else {
                            pendingReviewMessage = nil
                            if !(messages.last.map { $0.role == .assistant && $0.text == markdown } ?? false) {
                                messages.append(reviewMessage)
                            }
                        }
                    }
                default:
                    break
                }
            case "compacted":
                messages.append(.make(.system, .compactSummary, "── Context compacted ──", ts: ts, clip: true))
            case "world_state":
                break
            default:
                unknown += 1
            }
        }

        // response_item 完全缺席的会话退回 event_msg 流
        let hasReal = messages.contains { $0.kind == .text && (!$0.text.isEmpty || $0.imageCount > 0) }
        var final = hasReal ? messages : (eventFallback.isEmpty ? messages : eventFallback)
        CodingParse.assignSeq(&final)
        return Parse(messages: final, cwd: cwd, gitBranch: gitBranch, model: model, source: source,
                     tokens: tokens, created: created, updated: updated, unknown: unknown)
    }

    private func meta(_ ref: CodingSessionFileRef, _ p: Parse) -> CodingSessionMeta {
        CodingSessionMeta(
            key: "codex:\(ref.nativeId)", nativeId: ref.nativeId, agent: .codex,
            title: CodingParse.titleFromMessages(p.messages) ?? CodingLimits.untitled,
            projectPath: p.cwd, projectName: CodingParse.projectName(p.cwd), filePath: ref.filePath,
            createdAt: p.created > 0 ? p.created : ref.mtimeMs, updatedAt: p.updated > 0 ? p.updated : ref.mtimeMs,
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: p.gitBranch, model: p.model, tokensUsed: p.tokens > 0 ? p.tokens : nil,
            archived: ref.filePath.hasPrefix(archivedDir.path), source: p.source
        )
    }

    // MARK: - review（Codex Desktop 的代码审查输出转 Markdown）

    private static func reviewResultsFromUserAction(_ text: String) -> String? {
        let t = CodingParse.trimmed(text)
        guard t.hasPrefix("<user_action"), let action = CodingParse.extractTag(t, "action"),
              CodingParse.trimmed(action) == "review", let results = CodingParse.extractTag(t, "results"),
              !CodingParse.isBlank(results) else { return nil }
        return CodingParse.trimmed(results)
    }

    private static func reviewConfidence(_ value: Any?) -> String? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let v = number.doubleValue
        let percent = (0...1).contains(v) ? v * 100 : v
        guard percent.isFinite else { return nil }
        return "\(Int(percent.rounded()))%"
    }

    static func formatReviewOutput(_ review: CodingParse.JSON) -> String? {
        guard let findings = review["findings"] as? [Any] else { return nil }
        var out = "## Code review\n\n"
        var facts: [String] = []
        if let verdict = review["overall_correctness"] as? String {
            let label = verdict == "patch is correct" ? "Passed" : (verdict == "patch is incorrect" ? "Changes requested" : verdict)
            facts.append("**Result:** \(label)")
        }
        if let confidence = reviewConfidence(review["overall_confidence_score"]) { facts.append("**Confidence:** \(confidence)") }
        if !facts.isEmpty { out += facts.joined(separator: " · ") + "\n\n" }
        if let explanation = review["overall_explanation"] as? String, !CodingParse.isBlank(explanation) {
            out += CodingParse.trimmed(explanation) + "\n\n"
        }
        out += "### Findings\n\n"
        if findings.isEmpty { return out + "No findings." }
        for (index, item) in findings.enumerated() {
            let finding = item as? CodingParse.JSON ?? [:]
            var title = (finding["title"] as? String).map(CodingParse.trimmed) ?? ""
            if title.isEmpty { title = "Untitled finding" }
            title = title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            let heading: String
            if title.hasPrefix("[P") {
                heading = title
            } else if finding["priority"] is NSNumber {
                heading = "[P\(CodingParse.int64(finding["priority"]))] \(title)"
            } else {
                heading = title
            }
            out += "#### \(index + 1). \(heading)\n\n"
            if let body = finding["body"] as? String, !CodingParse.isBlank(body) { out += CodingParse.trimmed(body) + "\n\n" }
            if let location = finding["code_location"] as? CodingParse.JSON, let path = location["absolute_file_path"] as? String {
                let range = location["line_range"] as? CodingParse.JSON
                let start = range?["start"] is NSNumber ? CodingParse.int64(range?["start"]) : nil
                let end = range?["end"] is NSNumber ? CodingParse.int64(range?["end"]) : nil
                var suffix = ""
                if let start, let end, start != end {
                    suffix = ":\(start)–\(end)"
                } else if let start {
                    suffix = ":\(start)"
                }
                out += "**Location:** `\(path.replacingOccurrences(of: "`", with: "'"))\(suffix)`\n\n"
            }
            if let confidence = reviewConfidence(finding["confidence_score"]) { out += "**Confidence:** \(confidence)\n\n" }
        }
        return CodingParse.trimmed(out)
    }

    private static func formatReviewJSON(_ text: String) -> String? {
        let t = CodingParse.trimmed(text)
        guard t.hasPrefix("{") else { return nil }
        if let review = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? CodingParse.JSON {
            return formatReviewOutput(review)
        }
        let unescaped = t.replacingOccurrences(of: "\\_", with: "_")
        guard let review = (try? JSONSerialization.jsonObject(with: Data(unescaped.utf8))) as? CodingParse.JSON else { return nil }
        return formatReviewOutput(review)
    }
}
extension CodexAdapter {
    /// 没有 sessions / archived_sessions、顶层却有年份目录或 rollout 文件 = 直接选中了 rollout 存储本身
    static func isRolloutStore(_ dir: URL) -> Bool {
        guard !CodingLocations.isDirectory(dir.appendingPathComponent("sessions")),
              !CodingLocations.isDirectory(dir.appendingPathComponent("archived_sessions")) else { return false }
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).contains { entry in
            let name = entry.lastPathComponent
            return (CodingLocations.isDirectory(entry) && name.count == 4 && name.allSatisfy { $0.isASCII && $0.isNumber })
                || (name.hasPrefix("rollout-") && name.hasSuffix(".jsonl"))
        }
    }

    /// 入库前整形：直接选了数据目录（rollout 存储，或名字就叫 sessions / archived_sessions——空目录没有内容证据）且父目录呈家目录
    /// 形态（有 state_5.sqlite 或独立的兄弟数据目录）→ 存父目录，state DB 与两个数据根都找回来（Wake `normalize_custom_root`）
    static func normalizeCustomRoot(_ dir: URL) -> URL {
        let name = dir.lastPathComponent
        guard isRolloutStore(dir) || name == "sessions" || name == "archived_sessions" else { return dir }
        let parent = dir.deletingLastPathComponent()
        // 家目录的证据要独立于被选目录自身：目录名恰是 sessions 时 parent/sessions 就是它自己，不能算
        let sibling: Bool = switch name {
        case "sessions": CodingLocations.isDirectory(parent.appendingPathComponent("archived_sessions"))
        case "archived_sessions": CodingLocations.isDirectory(parent.appendingPathComponent("sessions"))
        default: CodingLocations.isDirectory(parent.appendingPathComponent("sessions"))
            || CodingLocations.isDirectory(parent.appendingPathComponent("archived_sessions"))
        }
        return CodingLocations.isFile(parent.appendingPathComponent("state_5.sqlite")) || sibling ? parent : dir
    }

    /// dir 当 CODEX_HOME 形态；没上提的孤立数据目录按目录名保角色：独立 archived 拷贝保住归档标记、空的独立 sessions 目录日后落盘的
    /// rollout 能被发现、没名可依的裸 rollout 树当活跃 sessions；侧档相对 dir 派生，不越界摸父目录（Wake `with_custom_root`）
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let (sessions, archived): (URL, URL) = switch dir.lastPathComponent {
        case "archived_sessions": (dir.appendingPathComponent("sessions"), dir)
        case "sessions": (dir, dir.appendingPathComponent("archived_sessions"))
        default: Self.isRolloutStore(dir) ? (dir, dir.appendingPathComponent("archived_sessions"))
            : (dir.appendingPathComponent("sessions"), dir.appendingPathComponent("archived_sessions"))
        }
        return CodexAdapter(sessionsDir: sessions, archivedDir: archived, stateDB: dir.appendingPathComponent("state_5.sqlite"))
    }

    /// sessions / archived 两行可以分别停用
    func excludingDataRoots(_ roots: [URL]) -> CodingSessionAdapter? {
        let paths = Set(roots.map(\.path))
        var copy = self
        copy.scanSessions = scanSessions && !paths.contains(sessionsDir.path)
        copy.scanArchived = scanArchived && !paths.contains(archivedDir.path)
        return copy
    }
}
#endif
