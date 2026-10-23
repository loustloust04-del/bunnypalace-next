#if os(macOS)
import Foundation

/// Hermes Agent（Nous Research）：`~/.hermes/state.db` 全明文 SQLite（`HERMES_HOME` 可改道；`profiles/<name>/state.db` 是多档案，
/// 同扫——Wake `adapters/hermes.rs`）。sessions(id,source,model,title,started_at,ended_at,token 各列) + messages(role,content,
/// tool_calls,tool_call_id,tool_name,reasoning,timestamp)。时间戳恒为 unix **秒**（REAL）；tool_calls 是 JSON 数组，写端两种形状
/// 并存：Hermes 精简版 `[{name,arguments}]`（arguments 多为 JSON 字符串）与 OpenAI 原样 `[{id,type,function:{name,arguments}}]`；
/// 工具结果是独立 `role="tool"` 行，按 tool_call_id 回填，精简形状没有 id 时按 tool_name 顺位回填。`source` 是启动面
/// （cli / telegram / …），`tool` 是 session_search 内部起的检索会话、不列。会话行没有 cwd（通用助手，不按项目分桶）。
/// `/branch`、压缩续段、子代理委派会设 parent_session_id：照常列出，父子关系交 parentLinks 快照由扫描器同步（各档案库独立，跨库不成立）
struct HermesAdapter: CodingSessionAdapter {
    let dbs: [URL]
    private let caches: [String: CodingStampCache<[Row]>]

    init(dbs: [URL]) {
        self.dbs = dbs
        caches = Dictionary(dbs.map { ($0.path, CodingStampCache<[Row]>()) }, uniquingKeysWith: { first, _ in first })
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// 一个 Hermes home 下的全部库：主库 + `profiles/<name>/state.db`（构造时刻快照，档案不会静默缺失）。档案路径按根的原写法拼——
    /// 枚举给的是 /private/var 形态，直接用会和主库、数据根前缀对不上
    static func dbs(under root: URL) -> [URL] {
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        let extra = ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [])
            .map { profiles.appendingPathComponent($0).appendingPathComponent("state.db") }
            .filter(isFile)
            .sorted { $0.path < $1.path }
        return [root.appendingPathComponent("state.db")] + extra
    }

    /// HERMES_HOME 只是候选：指向的目录里有 state.db 才采信，否则回落 ~/.hermes
    static func make(home: URL, environment: [String: String]) -> HermesAdapter {
        var root = home.appendingPathComponent(".hermes", isDirectory: true)
        if let custom = environment["HERMES_HOME"], !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom, isDirectory: true)
            if isFile(dir.appendingPathComponent("state.db")) { root = dir }
        }
        return HermesAdapter(dbs: dbs(under: root))
    }

    var agent: CodingAgent { .hermes }
    var dataRoots: [URL] { dbs }

    struct Row: Sendable {
        var id: String
        var source: String?
        var model: String?
        var title: String
        var startedMs: Int64
        var updatedMs: Int64
        var tokens: Int64
        var messageCount: Int64
        var contentLength: Int64
        var parentId: String?
    }

    /// 秒 → 毫秒，四舍五入、不做秒 / 毫秒猜测；非有限值 / 负数 = 0
    static func secondsToMs(_ seconds: Double) -> Int64 {
        let ms = (seconds * 1000).rounded()
        guard ms.isFinite, ms > 0 else { return 0 }
        return ms >= 9.2e18 ? Int64.max : Int64(ms)
    }

    /// Hermes 库按 schema_version 逐版 ALTER 上来：title 列 v3、cache_* / reasoning_tokens v5、messages.reasoning v6。老版本写出的库
    /// 没升过就没有这些列，硬引用会让 prepare 失败、整家会话消失——缺列一律用默认表达式顶上。任一行读坏整份作废
    static func queryRows(_ reader: CodingSQLiteReader) -> [Row]? {
        let columns = reader.columns(of: "sessions")
        func tokens(_ name: String) -> String { columns.contains(name) ? "COALESCE(s.\(name),0)" : "0" }
        let title = columns.contains("title") ? "COALESCE(s.title, '')" : "''"
        let sql = """
            SELECT s.id, s.source, s.model, \(title), s.started_at, s.ended_at,
                   COALESCE(s.input_tokens,0) + COALESCE(s.output_tokens,0) + \(tokens("cache_read_tokens")) + \(tokens("cache_write_tokens")) + \(tokens("reasoning_tokens")),
                   COUNT(m.id), COALESCE(MAX(m.timestamp), 0),
                   COALESCE(SUM(LENGTH(COALESCE(m.content,'')) + LENGTH(COALESCE(m.tool_calls,''))), 0),
                   s.parent_session_id
            FROM sessions s LEFT JOIN messages m ON m.session_id = s.id
            GROUP BY s.id
            """
        var rows: [Row] = []
        var broken = false
        let ok = reader.query(sql) { r in
            guard let id = r.text(0), let messageCount = r.int64(7), let contentLength = r.int64(9) else {
                broken = true
                return
            }
            let started = r.double(4) ?? 0
            rows.append(Row(id: id, source: r.text(1), model: r.text(2), title: r.text(3) ?? "", startedMs: secondsToMs(started),
                            updatedMs: secondsToMs(max(r.double(5) ?? 0, r.double(8) ?? 0, started)), tokens: r.int64(6) ?? 0,
                            messageCount: messageCount, contentLength: contentLength,
                            parentId: r.text(10).flatMap { $0.isEmpty ? nil : $0 }))
        }
        return ok && !broken ? rows : nil
    }

    private func rows(_ db: URL) -> [Row]? {
        let stamp = CodingSQLiteReader.cacheStamp(db)
        if let cached = caches[db.path]?.get(stamp) { return cached }
        guard let reader = CodingSQLiteReader.open(db, tag: "hermes"), let rows = Self.queryRows(reader) else { return nil }
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
            // 空会话（刚起就退）与 session_search 工具内部的检索会话不列
            return (rows(db) ?? []).filter { $0.messageCount > 0 && $0.source != "tool" }.map {
                CodingSessionFileRef(agent: .hermes, nativeId: $0.id, filePath: CodingVirtualPath.make(db: base, id: $0.id),
                                     mtimeMs: $0.updatedMs, size: $0.contentLength)
            }
        }
    }

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? {
        var out: [String: CodingSessionMeta] = [:]
        for db in dbs {
            guard let rows = rows(db) else { continue }
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let base = CodingParse.canonicalPath(db.path)
            for ref in refs where CodingParse.canonicalPath(CodingVirtualPath.strip(ref.filePath)) == base {
                if let row = byId[ref.nativeId] { out[ref.filePath] = Self.meta(ref, row, messages: []) }
            }
        }
        return out
    }

    var managesParentLinks: Bool { true }

    /// (child, parent) 全量快照：跨档案的父指针不成立（各库独立），只在库内配对
    func parentLinks() -> [(child: String, parent: String)] {
        dbs.flatMap { db -> [(child: String, parent: String)] in
            let rows = rows(db) ?? []
            let ids = Set(rows.map(\.id))
            return rows.compactMap { row in
                guard let parent = row.parentId, ids.contains(parent) else { return nil }
                return (child: "hermes:\(row.id)", parent: "hermes:\(parent)")
            }
        }
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let (meta, messages) = try parse(ref)
        return CodingParsedSession(meta: meta, units: CodingParse.units(messages), unknownLines: 0)
    }

    /// 不开图片解码：Hermes 库里的图片是路径不是数据，一律退占位
    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let (meta, messages) = try parse(ref)
        return CodingParsedTranscript(meta: meta, mainline: messages, sidechains: [], unknownLines: 0)
    }

    /// 单会话：会话行取缓存的聚合表，只有消息按会话查
    private func parse(_ ref: CodingSessionFileRef) throws -> (CodingSessionMeta, [CodingMessage]) {
        guard let db = db(for: ref) else { throw CodingSessionError.unreadable("Hermes 库不在这个实例的数据根里") }
        guard let rows = rows(db), let row = rows.first(where: { $0.id == ref.nativeId }) else {
            throw CodingSessionError.unreadable("Hermes 库里没有会话 \(ref.nativeId)")
        }
        guard let reader = CodingSQLiteReader.open(db, tag: "hermes") else { throw CodingSessionError.unreadable("打不开 Hermes 库") }
        let reasoning = reader.columns(of: "messages").contains("reasoning") ? "reasoning" : "NULL"
        var messages: [CodingMessage] = []
        // tool_call_id → (消息下标, 调用下标)
        var byId: [String: (Int, Int)] = [:]
        // 精简形状没有 id：尚未回填的调用按出现顺序排队，tool 行按 tool_name 认领
        var pending: [(Int, Int)] = []
        let ok = reader.query("""
            SELECT id, role, content, tool_call_id, tool_calls, tool_name, \(reasoning), timestamp
            FROM messages WHERE session_id = ? ORDER BY timestamp, id
            """, [ref.nativeId]) { m in
            guard let messageId = m.int64(0) else { return }
            let ts = Self.secondsToMs(m.double(7) ?? 0)
            switch m.text(1) ?? "" {
            case "user":
                let text = Self.contentText(m.text(2))
                if !text.isEmpty { messages.append(CodingParse.textMessage(.user, text, ts: ts)) }
            case "assistant":
                let text = Self.contentText(m.text(2))
                let calls = Self.toolCalls(m.text(4), messageId: messageId)
                let thinking = m.text(6).map(CodingParse.trimmed).flatMap { $0.isEmpty ? nil : $0 }
                if text.isEmpty && calls.isEmpty && thinking == nil { return }
                // 连续 assistant 行（中间只隔 tool 行）合并成一条，与 Pi 同款
                if messages.last?.role != .assistant { messages.append(CodingParse.textMessage(.assistant, "", ts: ts)) }
                let base = messages.count - 1
                if !text.isEmpty {
                    messages[base].text = messages[base].text.isEmpty ? text : messages[base].text + "\n\n" + text
                    if messages[base].text.utf8.count > CodingLimits.maxMessageText {
                        messages[base].text = CodingParse.clip(messages[base].text, CodingLimits.maxMessageText).0
                        messages[base].truncated = true
                    }
                }
                if let thinking {
                    let merged = messages[base].thinking.map { "\($0)\n\n\(thinking)" } ?? thinking
                    messages[base].thinking = CodingParse.clip(merged, CodingLimits.maxToolIO).0
                }
                for (hasId, call) in calls {
                    let slot = (base, messages[base].toolCalls.count)
                    if hasId { byId[call.id] = slot }
                    pending.append(slot)
                    messages[base].toolCalls.append(call)
                }
            case "tool":
                let output = Self.contentText(m.text(2))
                let name = m.text(5) ?? ""
                let unfilled = { (slot: (Int, Int)) in messages[slot.0].toolCalls[slot.1].output == nil }
                // 有 id 按 id；没有：同名的最早待回填项，再退最早的待回填项
                let slot = m.text(3).flatMap { byId[$0] }
                    ?? pending.first { unfilled($0) && (name.isEmpty || messages[$0.0].toolCalls[$0.1].name == name) }
                    ?? pending.first(where: unfilled)
                if let (mi, ti) = slot {
                    messages[mi].toolCalls[ti].output = CodingParse.clip(output, CodingLimits.maxToolIO).0
                    pending.removeAll { $0 == (mi, ti) }
                }
            case "system":
                let text = Self.contentText(m.text(2))
                if !text.isEmpty {
                    var message = CodingParse.textMessage(.system, text, ts: ts)
                    message.kind = .meta
                    messages.append(message)
                }
            default:
                break
            }
        }
        guard ok else { throw CodingSessionError.unreadable("读不了 Hermes 会话 \(ref.nativeId) 的消息") }
        CodingParse.assignSeq(&messages)
        return (Self.meta(ref, row, messages: messages), messages)
    }

    /// content 多为纯文本；多模态时写端存 JSON 块数组字符串，认出来走 contentParts（图片退占位）
    static func contentText(_ content: String?) -> String {
        let trimmed = CodingParse.trimmed(content ?? "")
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{"), let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            let parsed = CodingParse.contentParts(value)
            if !parsed.text.isEmpty { return parsed.text }
        }
        return trimmed
    }

    /// tool_calls JSON → (是否自带 id, 调用)。两种写端形状都认；arguments 是 JSON 字符串先解成对象，预览与详情才不是一坨转义；
    /// 没有 id 的给稳定合成 id `hermes-<消息 id>-<序号>`
    static func toolCalls(_ raw: String?, messageId: Int64) -> [(Bool, CodingToolCall)] {
        guard let raw, let items = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any] else { return [] }
        return items.enumerated().map { index, element in
            let item = element as? CodingParse.JSON ?? [:]
            let function: Any = item["function"] ?? item
            let name = (function as? CodingParse.JSON)?["name"] as? String ?? ""
            let arguments = (function as? CodingParse.JSON)?["arguments"] ?? NSNull()
            let input = (arguments as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
                ?? arguments
            if let id = item["id"] as? String, !id.isEmpty {
                return (true, CodingParse.toolCall(id: id, name: name, input: input))
            }
            return (false, CodingParse.toolCall(id: "hermes-\(messageId)-\(index)", name: name, input: input))
        }
    }

    private static func meta(_ ref: CodingSessionFileRef, _ row: Row, messages: [CodingMessage]) -> CodingSessionMeta {
        let cleaned = CodingParse.cleanTitleCandidate(row.title)
        return CodingSessionMeta(
            key: "hermes:\(row.id)", nativeId: row.id, agent: .hermes,
            title: !cleaned.isEmpty ? cleaned : (CodingParse.titleFromMessages(messages) ?? CodingLimits.untitled),
            projectPath: "", projectName: CodingParse.projectName(""), filePath: ref.filePath,
            createdAt: row.startedMs > 0 ? row.startedMs : ref.mtimeMs, updatedAt: row.updatedMs > 0 ? row.updatedMs : ref.mtimeMs,
            messageCount: messages.filter { $0.kind == .text }.count, sizeBytes: ref.size, gitBranch: nil,
            model: row.model.flatMap { $0.isEmpty ? nil : $0 }, tokensUsed: row.tokens > 0 ? row.tokens : nil, archived: false,
            // cli 是默认启动面，徽章只给非 cli 的（telegram / discord / …）
            source: row.source.flatMap { $0.isEmpty || $0 == "cli" ? nil : $0 }
        )
    }
}
extension HermesAdapter {
    /// 选中库文件本身、Hermes home（连同 profiles/*）或单个档案目录都认；目录不存在时也落到 <dir>/state.db
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        HermesAdapter(dbs: CodingLocations.isFile(dir) ? [dir] : Self.dbs(under: dir))
    }

    /// 多档案时可以单独移除某个档案库
    var supportsIndividualRootRemoval: Bool { dbs.count > 1 }

    func excludingDataRoots(_ roots: [URL]) -> CodingSessionAdapter? {
        let paths = Set(roots.map(\.path))
        return HermesAdapter(dbs: dbs.filter { !paths.contains($0.path) })
    }
}
#endif
