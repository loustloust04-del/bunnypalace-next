#if os(macOS)
import Foundation

/// OpenCode：stable `~/.local/share/opencode/opencode.db`，next 渠道另用同目录 `opencode-next.db`——两库可同时存在，必须一起扫
/// 而不是二选一（Wake `adapters/opencode.rs`）。v1：session 表 + 正文在 part 表（{type:text|reasoning|tool}，synthetic = 注入），
/// message 表只有角色与时间；OpenCode 2（二进制 `opencode2`）真实 next schema 仍用 session 表，正文改放 session_message
/// （type 列 user|synthetic|assistant|…，data JSON）；早期 preview 的 session_v2 表也兼容。parent_id 非空 = 子代理，不进列表
struct OpenCodeAdapter: CodingSessionAdapter {
    let dbs: [URL]
    private let caches: [String: CodingStampCache<[Row]>]

    init(dbs: [URL]) {
        self.dbs = dbs
        caches = Dictionary(dbs.map { ($0.path, CodingStampCache<[Row]>()) }, uniquingKeysWith: { first, _ in first })
    }

    static func knownDBs(_ dir: URL) -> [URL] {
        [dir.appendingPathComponent("opencode.db"), dir.appendingPathComponent("opencode-next.db")]
    }

    /// 数据目录服从 XDG（目录里真有库才采信）；两个固定候选常驻 roster，启动后才装 CLI 普通刷新也能发现；OPENCODE_DB 作额外候选，
    /// 绝不压掉两个标准位置；XDG 被采信时默认目录里已有的库仍留作候选，稳定版历史不消失
    static func make(home: URL, environment: [String: String]) -> OpenCodeAdapter {
        let fm = FileManager.default
        func isFile(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
        let defaultDir = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        var activeDir = defaultDir
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            let dir = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("opencode", isDirectory: true)
            if knownDBs(dir).contains(where: isFile) { activeDir = dir }
        }
        var paths: [URL] = []
        func push(_ url: URL) {
            if !paths.contains(where: { $0.path == url.path }) { paths.append(url) }
        }
        if let configured = environment["OPENCODE_DB"], !configured.isEmpty, configured != ":memory:" {
            let url = configured.hasPrefix("/") ? URL(fileURLWithPath: configured) : activeDir.appendingPathComponent(configured)
            if isFile(url) { push(url) }
        }
        knownDBs(activeDir).forEach(push)
        if activeDir.path != defaultDir.path { knownDBs(defaultDir).filter(isFile).forEach(push) }
        return OpenCodeAdapter(dbs: paths)
    }

    var agent: CodingAgent { .opencode }
    var dataRoots: [URL] { dbs }

    struct Row: Sendable {
        var id: String
        var directory: String
        var title: String
        var createdMs: Int64
        var updatedMs: Int64
        var modelJSON: String
        var tokens: Int64
        var archived: Bool
        /// 会话产生时的 CLI 版本（"1.14.50" / "0.0.0-beta-17639"），v2 迁移保留原值
        var version: String
        var contentLength: Int64
        /// 这条会话的正文实际来自 session_message，而不是旧 message + part
        var v2Messages: Bool
    }

    /// preview 会话在 UI 标 opencode2、续跑据此换二进制：next 库名是最强信号；共享库 / 早期 schema 回看 session.version 的渠道标记
    static func source(_ row: Row, db: URL) -> String? {
        let v2 = db.lastPathComponent == "opencode-next.db" || row.version.hasPrefix("2")
            || row.version.contains("beta") || row.version.contains("next")
        return v2 ? "opencode2" : nil
    }

    // MARK: - 行

    private static let rowColumns = """
        s.id, s.directory, s.title, s.time_created, s.time_updated, s.model,
        s.tokens_input + s.tokens_output + s.tokens_reasoning, s.time_archived, s.version
        """

    /// 按库里真实的表组合拼一次枚举 SQL。新版 next 与 v1 共用 session 表，必须逐会话看 session_message 有没有正文——
    /// 只查 session_v2 会把真实 next 会话误走 part 路径、content_len = 0 全被滤掉（Wake GitHub #2）
    static func rowsSQL(_ reader: CodingSQLiteReader) -> String? {
        let hasSession = reader.hasTable("session")
        let hasSessionV2 = reader.hasTable("session_v2")
        let hasParts = reader.hasTable("part")
        let hasMessagesV2 = reader.hasTable("session_message")
        guard hasSession || hasSessionV2 else { return nil }
        let partLength = "(SELECT COALESCE(SUM(LENGTH(p.data)), 0) FROM part p WHERE p.session_id = s.id)"
        let messageLength = "(SELECT COALESCE(SUM(LENGTH(m.data)), 0) FROM session_message m WHERE m.session_id = s.id)"
        let messageExists = "EXISTS(SELECT 1 FROM session_message m WHERE m.session_id = s.id)"
        func select(_ table: String, _ length: String, _ v2: String) -> String {
            "SELECT \(rowColumns), \(length) AS content_len, \(v2) AS v2_messages FROM \(table) s WHERE s.parent_id IS NULL"
        }
        var selects: [String] = []
        // 早期 preview schema：session_v2 是全集，session 只作 v1 回捞
        if hasSessionV2 { selects.append(select("session_v2", hasMessagesV2 ? messageLength : "0", "1")) }
        if hasSession {
            let (length, v2): (String, String) = switch (hasParts, hasMessagesV2) {
            case (true, true):
                ("CASE WHEN \(messageExists) THEN \(messageLength) ELSE \(partLength) END", "CASE WHEN \(messageExists) THEN 1 ELSE 0 END")
            case (true, false): (partLength, "0")
            case (false, true): (messageLength, "1")
            case (false, false): ("0", "0")
            }
            var sql = select("session", length, v2)
            if hasSessionV2 { sql += " AND s.id NOT IN (SELECT id FROM session_v2)" }
            selects.append(sql)
        }
        return selects.joined(separator: " UNION ALL ")
    }

    /// 任一行读坏整份作废（Wake `collect::<Result<Vec>>`）；没有 session 表 / 查询出错 = nil
    static func queryRows(_ reader: CodingSQLiteReader, id: String?) -> [Row]? {
        guard let sql = rowsSQL(reader) else { return nil }
        var rows: [Row] = []
        var broken = false
        let args: [Any?] = id.map { [$0] } ?? []
        let ok = reader.query(id == nil ? sql : "SELECT * FROM (\(sql)) WHERE id = ?", args) { r in
            guard let id = r.text(0), let contentLength = r.int64(9), let v2 = r.int64(10) else {
                broken = true
                return
            }
            rows.append(Row(id: id, directory: r.text(1) ?? "", title: r.text(2) ?? "", createdMs: r.int64(3) ?? 0,
                            updatedMs: r.int64(4) ?? 0, modelJSON: r.text(5) ?? "", tokens: r.int64(6) ?? 0,
                            archived: !r.isNull(7), version: r.text(8) ?? "", contentLength: contentLength, v2Messages: v2 != 0))
        }
        return ok && !broken ? rows : nil
    }

    private func rows(_ db: URL) -> [Row]? {
        let stamp = CodingSQLiteReader.cacheStamp(db)
        if let cached = caches[db.path]?.get(stamp) { return cached }
        guard let reader = CodingSQLiteReader.open(db, tag: "opencode"), let rows = Self.queryRows(reader, id: nil) else { return nil }
        caches[db.path]?.set(stamp, rows)
        return rows
    }

    private func db(for ref: CodingSessionFileRef) -> URL? {
        let path = CodingParse.canonicalPath(CodingVirtualPath.strip(ref.filePath))
        return dbs.first { CodingParse.canonicalPath($0.path) == path }
    }

    func listSessionFiles() -> [CodingSessionFileRef] {
        dbs.flatMap { db -> [CodingSessionFileRef] in
            let base = CodingParse.canonicalPath(db.path)
            return (rows(db) ?? []).filter { $0.contentLength > 0 }.map {
                CodingSessionFileRef(agent: .opencode, nativeId: $0.id, filePath: CodingVirtualPath.make(db: base, id: $0.id),
                                     mtimeMs: $0.updatedMs, size: $0.contentLength)
            }
        }
    }

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? {
        var out: [String: CodingSessionMeta] = [:]
        var opened = false
        for db in dbs {
            guard let rows = rows(db) else { continue }
            opened = true
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let base = CodingParse.canonicalPath(db.path)
            for ref in refs where CodingParse.canonicalPath(CodingVirtualPath.strip(ref.filePath)) == base {
                if let row = byId[ref.nativeId] { out[ref.filePath] = meta(ref, row, db: db, messageCount: 0) }
            }
        }
        return opened ? out : nil
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let (meta, messages, unknown) = try parse(ref)
        return CodingParsedSession(meta: meta, units: CodingParse.units(messages), unknownLines: unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let (meta, messages, unknown) = try CodingImageBudget.decoding { try parse(ref) }
        return CodingParsedTranscript(meta: meta, mainline: messages, sidechains: [], unknownLines: unknown)
    }

    /// 单会话：一次连接；行命中 v2 走 session_message，否则回落 v1 的 message + part 两表
    private func parse(_ ref: CodingSessionFileRef) throws -> (CodingSessionMeta, [CodingMessage], Int) {
        guard let db = db(for: ref) else { throw CodingSessionError.unreadable("OpenCode 库不在这个实例的数据根里") }
        guard let reader = CodingSQLiteReader.open(db, tag: "opencode") else { throw CodingSessionError.unreadable("打不开 OpenCode 库") }
        guard let rows = Self.queryRows(reader, id: ref.nativeId) else { throw CodingSessionError.unreadable("OpenCode 库读不了会话表") }
        guard let row = rows.first else { throw CodingSessionError.unreadable("OpenCode 库里没有会话 \(ref.nativeId)") }
        let (messages, unknown) = try row.v2Messages ? Self.parseV2(reader, ref.nativeId) : Self.parseV1(reader, ref.nativeId)
        return (meta(ref, row, db: db, messageCount: messages.filter { $0.kind == .text }.count), messages, unknown)
    }

    private static func jsonValue(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    // MARK: - 正文

    /// v1：message 表（角色 / 时间）+ part 表（内容块）按 message_id 分组；part id 前缀时间有序
    private static func parseV1(_ reader: CodingSQLiteReader, _ sid: String) throws -> ([CodingMessage], Int) {
        var partsByMessage: [String: [Any]] = [:]
        let partsOK = reader.query("SELECT message_id, data FROM part WHERE session_id = ? ORDER BY message_id, id", [sid]) { r in
            guard let mid = r.text(0), let data = r.text(1), let value = jsonValue(data) else { return }
            partsByMessage[mid, default: []].append(value)
        }
        guard partsOK else { throw CodingSessionError.unreadable("读不了 OpenCode part 表") }

        var messages: [CodingMessage] = []
        var unknown = 0
        let messagesOK = reader.query("SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created, id", [sid]) { r in
            guard let mid = r.text(0), let data = r.text(1) else { return }
            guard let value = jsonValue(data) else {
                unknown += 1
                return
            }
            let md = value as? CodingParse.JSON ?? [:]
            let role: CodingRole = switch md["role"] as? String {
            case "user": .user
            case "assistant": .assistant
            default: .system
            }
            var acc = BlockAcc()
            for part in partsByMessage.removeValue(forKey: mid) ?? [] {
                let p = part as? CodingParse.JSON ?? [:]
                switch p["type"] as? String {
                case "text":
                    let t = p["text"] as? String ?? ""
                    if CodingParse.isBlank(t) { continue }
                    if CodingParse.bool(p["synthetic"]) { acc.synthetic.append(CodingParse.trimmed(t)) } else { acc.content.push(t) }
                case "reasoning": acc.pushReasoning(p)
                case "tool": acc.pushTool(p)
                case "image": acc.pushImage(p)
                case "step-start", "step-finish", "snapshot", "patch": break
                case "file": if CodingParse.isImagePart(p) { acc.pushImage(p) }
                default: unknown += 1
                }
            }
            if let message = acc.message(role, ts: createdMs(md), model: nil) { messages.append(message) }
        }
        guard messagesOK else { throw CodingSessionError.unreadable("读不了 OpenCode message 表") }
        CodingParse.assignSeq(&messages)
        return (messages, unknown)
    }

    /// v2：session_message 单表按 seq 有序，type 列分 user / synthetic / assistant / …，data JSON——user 的 text 在顶层，
    /// assistant 的 content 是块数组
    private static func parseV2(_ reader: CodingSQLiteReader, _ sid: String) throws -> ([CodingMessage], Int) {
        var messages: [CodingMessage] = []
        var unknown = 0
        let ok = reader.query("SELECT type, data FROM session_message WHERE session_id = ? ORDER BY seq", [sid]) { r in
            guard let type = r.text(0), let data = r.text(1) else { return }
            guard let value = jsonValue(data) else {
                unknown += 1
                return
            }
            let md = value as? CodingParse.JSON ?? [:]
            let ts = createdMs(md)
            switch type {
            case "user":
                let text = CodingParse.trimmed(md["text"] as? String ?? "")
                var parsed = CodingParse.contentParts(md["content"] ?? md["attachments"])
                if text == CodingParse.trimmed(parsed.text) {
                    parsed.text = text
                } else if !text.isEmpty {
                    var combined = CodingParse.Content()
                    combined.push(text)
                    combined.append(parsed)
                    parsed = combined
                }
                if !parsed.text.isEmpty || !parsed.images.isEmpty {
                    var message = CodingParse.textMessage(.user, parsed.text, ts: ts)
                    message.images = parsed.images
                    message.imageCount = parsed.imageCount
                    messages.append(message)
                }
            case "synthetic", "system":
                // synthetic = 注入内容（编辑器上下文等），system = 系统提示：都归 Meta 折叠
                let text = CodingParse.trimmed(md["text"] as? String ?? "")
                if !text.isEmpty {
                    var message = CodingParse.textMessage(type == "synthetic" ? .user : .system, text, ts: ts)
                    message.kind = .meta
                    messages.append(message)
                }
            case "shell":
                let output = (md["output"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var acc = BlockAcc()
                acc.tools.append(CodingParse.toolCall(id: md["callID"] as? String ?? "", name: "shell",
                                                      input: ["command": md["command"] as? String ?? ""], output: output))
                if let message = acc.message(.assistant, ts: ts, model: nil) { messages.append(message) }
            case "assistant":
                var acc = BlockAcc()
                for item in md["content"] as? [Any] ?? [] {
                    let b = item as? CodingParse.JSON ?? [:]
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !CodingParse.isBlank(t) { acc.content.push(t) }
                    case "reasoning": acc.pushReasoning(b)
                    case "tool": acc.pushTool(b)
                    case "image": acc.pushImage(b)
                    case "step-start", "step-finish", "snapshot", "patch": break
                    case "file": if CodingParse.isImagePart(b) { acc.pushImage(b) }
                    default: unknown += 1
                    }
                }
                let model = (md["model"] as? CodingParse.JSON)?["id"] as? String
                if let message = acc.message(.assistant, ts: ts, model: model) { messages.append(message) }
            case "compaction":
                let summary = CodingParse.trimmed(md["summary"] as? String ?? "")
                if !summary.isEmpty {
                    var message = CodingParse.textMessage(.system, summary, ts: ts)
                    message.kind = .compactSummary
                    messages.append(message)
                }
            case "agent-switched", "model-switched":
                break // 纯状态切换不成对话消息，但是已知 schema，不计未知
            default:
                unknown += 1
            }
        }
        guard ok else { throw CodingSessionError.unreadable("读不了 OpenCode session_message 表") }
        CodingParse.assignSeq(&messages)
        return (messages, unknown)
    }

    private static func createdMs(_ md: CodingParse.JSON) -> Int64 {
        CodingParse.int64((md["time"] as? CodingParse.JSON)?["created"])
    }

    /// 一条消息的内容块累加器（text / synthetic / reasoning / tool），两代路径共用
    private struct BlockAcc {
        var content = CodingParse.Content()
        var synthetic: [String] = []
        var thinking: [String] = []
        var tools: [CodingToolCall] = []

        mutating func pushReasoning(_ b: CodingParse.JSON) {
            if let t = b["text"] as? String, !CodingParse.isBlank(t) { thinking.append(CodingParse.trimmed(t)) }
        }

        /// tool 块两种形态：preview 早期 `{callID,tool,state:{input,output}}`、真实 next `{id,name,state:{input,content,result,error}}`；
        /// state.content 里的图片挂到消息上
        mutating func pushTool(_ b: CodingParse.JSON) {
            let state = b["state"] as? CodingParse.JSON ?? [:]
            var output = OpenCodeAdapter.toolOutput(state)
            if let stateContent = state["content"] {
                let parsed = CodingParse.contentParts(stateContent)
                if !parsed.text.isEmpty { output = parsed.text }
                content.imageCount += parsed.imageCount
                content.images += parsed.images
            }
            tools.append(CodingParse.toolCall(id: (b["callID"] ?? b["id"]) as? String ?? "",
                                              name: (b["tool"] ?? b["name"]) as? String ?? "tool",
                                              input: state["input"] ?? NSNull(), output: output,
                                              isError: state["status"] as? String == "error"))
        }

        mutating func pushImage(_ b: CodingParse.JSON) {
            content.append(CodingParse.contentParts(b))
        }

        /// 全空 = nil；只有注入内容的消息归 Meta 折叠
        func message(_ role: CodingRole, ts: Int64, model: String?) -> CodingMessage? {
            var text = content.text
            var kind = CodingMessageKind.text
            if text.isEmpty && !synthetic.isEmpty {
                text = synthetic.joined(separator: "\n\n")
                kind = .meta
            }
            if text.isEmpty && thinking.isEmpty && tools.isEmpty && content.images.isEmpty { return nil }
            let (clipped, truncated) = CodingParse.clip(text, CodingLimits.maxMessageText)
            let joinedThinking = thinking.isEmpty ? nil : CodingParse.clip(thinking.joined(separator: "\n\n"), CodingLimits.maxToolIO).0
            return CodingMessage(seq: 0, role: role, kind: kind, text: clipped, truncated: truncated, toolCalls: tools,
                                 thinking: joinedThinking, timestamp: ts > 0 ? ts : nil, model: model,
                                 imageCount: content.imageCount, images: content.images)
        }
    }

    /// 工具输出：output（非空字符串原样，其它非 null 值转 JSON）→ content 数组渲染（text 原文、file 显示名）→ result → error.message
    static func toolOutput(_ state: CodingParse.JSON) -> String? {
        if let output = state["output"] {
            if let text = output as? String, !text.isEmpty { return text }
            return output is NSNull ? nil : CodingParse.compactJSON(output)
        }
        if let items = state["content"] as? [Any] {
            let rendered = items.compactMap { item -> String? in
                guard let item = item as? CodingParse.JSON else { return nil }
                switch item["type"] as? String {
                case "text": return item["text"] as? String
                case "file": return ((item["name"] ?? item["uri"]) as? String).map { "[file: \($0)]" }
                default: return nil
                }
            }.joined(separator: "\n")
            if !rendered.isEmpty { return rendered }
        }
        if let result = state["result"], !(result is NSNull) {
            return result as? String ?? CodingParse.compactJSON(result)
        }
        let message = (state["error"] as? CodingParse.JSON)?["message"] as? String
        return message?.isEmpty == false ? message : nil
    }

    private func meta(_ ref: CodingSessionFileRef, _ row: Row, db: URL, messageCount: Int) -> CodingSessionMeta {
        let title = CodingParse.cleanTitleCandidate(row.title)
        let model = (Self.jsonValue(row.modelJSON) as? CodingParse.JSON)?["id"] as? String
        return CodingSessionMeta(
            key: "opencode:\(row.id)", nativeId: row.id, agent: .opencode, title: title.isEmpty ? CodingLimits.untitled : title,
            projectPath: row.directory, projectName: CodingParse.projectName(row.directory), filePath: ref.filePath,
            createdAt: row.createdMs > 0 ? row.createdMs : ref.mtimeMs, updatedAt: row.updatedMs > 0 ? row.updatedMs : ref.mtimeMs,
            messageCount: messageCount, sizeBytes: ref.size, gitBranch: nil, model: model,
            tokensUsed: row.tokens > 0 ? row.tokens : nil, archived: row.archived, source: Self.source(row, db: db)
        )
    }
}
extension OpenCodeAdapter {
    /// 目录位置同时扫 stable + next，直接给库文件只认这个文件；选中 XDG data 根或 opencode 目录本身都归一（Wake `custom_db_paths`）
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        if CodingLocations.isFile(dir) { return OpenCodeAdapter(dbs: [dir]) }
        let nested = dir.appendingPathComponent("opencode", isDirectory: true)
        let dbDir = CodingLocations.isDirectory(nested) || Self.knownDBs(nested).contains(where: CodingLocations.isFile) ? nested : dir
        return OpenCodeAdapter(dbs: Self.knownDBs(dbDir))
    }

    /// stable / next 两个库彼此独立，可以单独移除其中一个
    var supportsIndividualRootRemoval: Bool { true }

    func excludingDataRoots(_ roots: [URL]) -> CodingSessionAdapter? {
        let paths = Set(roots.map(\.path))
        return OpenCodeAdapter(dbs: dbs.filter { !paths.contains($0.path) })
    }
}
#endif
