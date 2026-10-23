#if os(macOS)
import Foundation

/// Grok Build（xAI 的 coding CLI）：`~/.grok/sessions/<url 编码 cwd>/<uuid>/` 一目录一会话（Wake `adapters/grok.rs`）。主文件
/// `updates.jsonl` 是 ACP 风格完整流水（{timestamp 秒, method:"session/update", params:{update:{sessionUpdate:…}}}），chunk 流式落盘
/// 要按角色段合并；`chat_history.jsonl` 是压缩过的上下文快照，不能当全量。`summary.json` 边车给 cwd / 标题 / git 信息。同级
/// `session_search.sqlite` 是 Grok 自己的索引、`prompt_history.jsonl` 在 cwd 目录级——都不是会话文件。子代理登记在主会话的
/// `subagents/*/meta.json`：父子关系与项目归组见 `CodingGrokGroup`，一轮扫描共享一份快照
struct GrokAdapter: CodingSessionAdapter {
    let root: URL
    let grokHome: URL
    private let group = GroupHolder()

    init(home: URL) {
        grokHome = home.appendingPathComponent(".grok", isDirectory: true)
        root = grokHome.appendingPathComponent("sessions", isDirectory: true)
    }

    init(root: URL, grokHome: URL) {
        self.root = root
        self.grokHome = grokHome
    }

    private final class GroupHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var context: CodingGrokGroup.Context?

        func get(_ load: () -> CodingGrokGroup.Context) -> CodingGrokGroup.Context {
            lock.lock()
            defer { lock.unlock() }
            if let context { return context }
            let loaded = load()
            context = loaded
            return loaded
        }

        func set(_ context: CodingGrokGroup.Context) {
            lock.lock()
            self.context = context
            lock.unlock()
        }
    }

    var agent: CodingAgent { .grok }
    var dataRoots: [URL] { [root] }

    private var groupContext: CodingGrokGroup.Context {
        group.get { CodingGrokGroup.load(sessionsRoot: root, grokHome: grokHome) }
    }

    func beginScan() {
        group.set(CodingGrokGroup.load(sessionsRoot: root, grokHome: grokHome))
    }

    var managesParentLinks: Bool { true }

    func parentLinks() -> [(child: String, parent: String)] {
        CodingGrokGroup.parentLinks(groupContext)
    }

    func isParentLinkEvent(_ path: String) -> Bool {
        let base = CodingParse.canonicalPath(root.path)
        let file = CodingParse.canonicalPath(path)
        guard file.hasPrefix(base + "/") else { return false }
        return file.dropFirst(base.count + 1).split(separator: "/").contains("subagents")
    }

    /// 两层：<cwd 组目录>/<会话目录>/updates.jsonl；根级 session_search.sqlite 等文件读目录自然失败跳过
    func listSessionFiles() -> [CodingSessionFileRef] {
        let fm = FileManager.default
        var refs: [CodingSessionFileRef] = []
        for cwdDir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for session in (try? fm.contentsOfDirectory(at: cwdDir, includingPropertiesForKeys: nil)) ?? [] {
                if let ref = fileRef(session.appendingPathComponent("updates.jsonl")) { refs.append(ref) }
            }
        }
        return refs
    }

    /// 只认会话目录里的 updates.jsonl（prompt_history / chat_history / events 都不是主文件）；native id = 会话目录名
    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        guard url.lastPathComponent == "updates.jsonl", var ref = CodingParse.defaultFileRef(.grok, url) else { return nil }
        ref.nativeId = url.deletingLastPathComponent().lastPathComponent
        return ref
    }

    /// 会话是 <uuid>/ 整个目录（summary / events / plan 等边车），整目录进废纸篓
    func sessionPaths(_ meta: CodingSessionMeta) -> [String] {
        [URL(fileURLWithPath: meta.filePath).deletingLastPathComponent().path]
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let (messages, unknown) = try Self.parseUpdates(URL(fileURLWithPath: ref.filePath))
        return CodingParsedSession(meta: meta(ref, messages), units: CodingParse.units(messages), unknownLines: unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let (messages, unknown) = try CodingImageBudget.decoding { try Self.parseUpdates(URL(fileURLWithPath: ref.filePath)) }
        return CodingParsedTranscript(meta: meta(ref, messages), mainline: messages, sidechains: [], unknownLines: unknown)
    }

    // MARK: - summary.json 边车

    struct Summary {
        var cwd = ""
        var title = ""
        var createdMs: Int64 = 0
        var updatedMs: Int64 = 0
        var gitBranch: String?
        var model: String?
        var gitRemotes: [String] = []
    }

    static func summary(_ updates: URL) -> Summary {
        var s = Summary()
        guard let data = try? Data(contentsOf: updates.deletingLastPathComponent().appendingPathComponent("summary.json")),
              let v = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON else { return s }
        if let cwd = (v["info"] as? CodingParse.JSON)?["cwd"] as? String { s.cwd = cwd }
        // generated_title 与 session_summary 通常同值，前者更语义化
        for key in ["generated_title", "session_summary"] {
            if let title = v[key] as? String, !CodingParse.isBlank(title) {
                s.title = title
                break
            }
        }
        if let t = v["created_at"] as? String { s.createdMs = CodingParse.isoMs(t) }
        if let t = v["updated_at"] as? String { s.updatedMs = CodingParse.isoMs(t) }
        s.gitBranch = (v["head_branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        s.model = (v["current_model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        s.gitRemotes = ((v["git_remotes"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        return s
    }

    // MARK: - 流水重放

    /// 段状态：一个用户回合断一次，assistant 期间 thought / message / tool 交错全并入同一条助手消息
    private struct Replay {
        var messages: [CodingMessage] = []
        var toolIndex: [String: (Int, Int)] = [:]
        var role: CodingRole?
        var text = ""
        var thinking = ""
        var tools: [CodingToolCall] = []
        var images: [CodingImage] = []
        var imageCount = 0
        var ts: Int64 = 0

        mutating func flush() {
            guard let role else { return }
            self.role = nil
            let (text, thinking, tools, images, imageCount) = (self.text, self.thinking, self.tools, self.images, self.imageCount)
            self.text = ""
            self.thinking = ""
            self.tools = []
            self.images = []
            self.imageCount = 0
            if CodingParse.isBlank(text) && CodingParse.isBlank(thinking) && tools.isEmpty && images.isEmpty { return }
            var message = CodingParse.textMessage(role, text, ts: ts)
            let trimmedThinking = CodingParse.trimmed(thinking)
            if !trimmedThinking.isEmpty { message.thinking = CodingParse.clip(trimmedThinking, CodingLimits.maxToolIO).0 }
            message.images = images
            message.imageCount = imageCount
            let base = messages.count
            for (ix, call) in tools.enumerated() { toolIndex[call.id] = (base, ix) }
            message.toolCalls = tools
            messages.append(message)
        }

        /// 进入（或延续）一个角色段
        mutating func ensure(_ role: CodingRole, _ ts: Int64) {
            guard self.role != role else { return }
            flush()
            self.role = role
            self.ts = ts
        }
    }

    private static func chunkText(_ update: CodingParse.JSON) -> String {
        ((update["content"] as? CodingParse.JSON)?["text"] as? String) ?? ""
    }

    /// 内容里有没有图片块（Wake `has_image_content`）：本身是图片、数组里有、或 content / data 往下有
    static func hasImageContent(_ value: Any?) -> Bool {
        if let object = value as? CodingParse.JSON {
            if CodingParse.isImagePart(object) { return true }
            return hasImageContent(object["content"] ?? object["data"])
        }
        if let array = value as? [Any] { return array.contains(where: hasImageContent) }
        return false
    }

    /// Grok 的文本 chunk 是增量片段，不能过 contentParts 的 trim / 拼接（模型在 token 边界写的空格会被吃掉）；只有图片块走通用附件解析
    private static func appendChunk(_ rp: inout Replay, _ update: CodingParse.JSON, _ role: CodingRole, _ ts: Int64) {
        rp.ensure(role, ts)
        let content = update["content"]
        if hasImageContent(content) {
            let parsed = CodingParse.contentParts(content)
            rp.text += parsed.text
            rp.images += parsed.images
            rp.imageCount += parsed.imageCount
        } else {
            rp.text += chunkText(update)
        }
    }

    /// tool_call_update 回填：完成态带 content（文本输出，覆盖式取最终态）、status failed 置错；初始 tool_call 缺 rawInput 时由 update 补
    private static func applyToolUpdate(_ call: inout CodingToolCall, _ update: CodingParse.JSON) -> CodingParse.Content {
        var media = CodingParse.Content()
        if let content = update["content"] {
            let parsed = CodingParse.contentParts(content)
            if !parsed.text.isEmpty { call.output = CodingParse.clip(parsed.text, CodingLimits.maxToolIO).0 }
            media.images = parsed.images
            media.imageCount = parsed.imageCount
        }
        if update["status"] as? String == "failed" { call.isError = true }
        if call.input == nil, let raw = update["rawInput"], !(raw is NSNull) {
            call.inputPreview = CodingParse.makePreview(raw)
            if let json = CodingParse.prettyJSON(raw) { call.input = CodingParse.clip(json, CodingLimits.maxToolIO).0 }
        }
        return media
    }

    static func parseUpdates(_ url: URL) throws -> ([CodingMessage], Int) {
        var rp = Replay()
        var unknown = 0
        try CodingParse.forEachLine(url) { row in
            guard let row else {
                unknown += 1
                return
            }
            let ts = CodingParse.epochMs(row["timestamp"])
            guard let update = (row["params"] as? CodingParse.JSON)?["update"] as? CodingParse.JSON else {
                unknown += 1
                return
            }
            switch update["sessionUpdate"] as? String {
            case "user_message_chunk":
                appendChunk(&rp, update, .user, ts)
            case "agent_message_chunk":
                appendChunk(&rp, update, .assistant, ts)
            case "agent_thought_chunk":
                rp.ensure(.assistant, ts)
                rp.thinking += chunkText(update)
            case "tool_call":
                rp.ensure(.assistant, ts)
                rp.tools.append(CodingParse.toolCall(id: update["toolCallId"] as? String ?? "", name: update["title"] as? String ?? "",
                                                     input: update["rawInput"] ?? NSNull()))
            case "tool_call_update":
                guard let id = update["toolCallId"] as? String else { return }
                // 目标工具可能还在当前没 flush 的段里，也可能已经进了 messages
                if let ix = rp.tools.firstIndex(where: { $0.id == id }) {
                    let media = applyToolUpdate(&rp.tools[ix], update)
                    rp.images += media.images
                    rp.imageCount += media.imageCount
                } else if let (mi, ti) = rp.toolIndex[id] {
                    let media = applyToolUpdate(&rp.messages[mi].toolCalls[ti], update)
                    rp.messages[mi].images += media.images
                    rp.messages[mi].imageCount += media.imageCount
                }
            case "task_backgrounded", "task_completed", "auto_compact_started", "auto_compact_completed", "compaction_checkpoint",
                 "plan", "current_mode_update":
                break // 已知的非内容更新：任务后台化 / 压缩等
            default:
                unknown += 1
            }
        }
        rp.flush()
        var messages = rp.messages
        CodingParse.assignSeq(&messages)
        return (messages, unknown)
    }

    private func meta(_ ref: CodingSessionFileRef, _ messages: [CodingMessage]) -> CodingSessionMeta {
        let side = Self.summary(URL(fileURLWithPath: ref.filePath))
        let cleaned = CodingParse.cleanTitleCandidate(side.title)
        let project = CodingGrokGroup.canonicalProject(cwd: side.cwd, remotes: side.gitRemotes, grokHome: grokHome,
                                                       childId: ref.nativeId, ctx: groupContext)
        let updated = max(side.updatedMs, messages.compactMap(\.timestamp).max() ?? 0)
        return CodingSessionMeta(
            key: "grok:\(ref.nativeId)", nativeId: ref.nativeId, agent: .grok,
            title: !cleaned.isEmpty ? cleaned : (CodingParse.titleFromMessages(messages) ?? CodingLimits.untitled),
            projectPath: project.path, projectName: project.name, filePath: ref.filePath,
            createdAt: side.createdMs > 0 ? side.createdMs : ref.mtimeMs, updatedAt: updated > 0 ? updated : ref.mtimeMs,
            messageCount: messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: side.gitBranch, model: side.model, tokensUsed: nil, archived: false, source: nil
        )
    }
}
extension GrokAdapter {
    /// 选中 `~/.grok`（含 sessions/）或 sessions 目录本身都认；都不像时 dir 自己就是 sessions 根——没有结构证据不越界去父目录读边车
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        if CodingLocations.isDirectory(sessions) { return GrokAdapter(root: sessions, grokHome: dir) }
        if dir.lastPathComponent == "sessions" { return GrokAdapter(root: dir, grokHome: dir.deletingLastPathComponent()) }
        return GrokAdapter(root: dir, grokHome: dir)
    }
}
#endif
