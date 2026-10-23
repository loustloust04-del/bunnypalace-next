#if os(macOS)
import Foundation

/// GitHub Copilot CLI：`~/.copilot/session-store.db` 全明文 SQLite（Wake `adapters/copilot.rs`）。
/// sessions(id,cwd,branch,summary) + turns(user_message,assistant_response)；没有每会话文件，引用用虚拟路径 `<库>#<id>`，
/// mtime 取行内 updated_at、size 取 turns 正文总长——两者一起构成增量扫描的「变没变」判断
struct CopilotAdapter: CodingSessionAdapter {
    let db: URL
    private let cache = CodingStampCache<[Row]>()

    init(home: URL) {
        db = home.appendingPathComponent(".copilot/session-store.db")
    }

    init(db: URL) {
        self.db = db
    }

    var agent: CodingAgent { .copilot }
    var dataRoots: [URL] { [db] }

    struct Row: Sendable {
        var id: String
        var cwd: String
        var branch: String?
        var summary: String
        var createdMs: Int64
        var updatedMs: Int64
        var contentLength: Int64
        var turnCount: Int64
    }

    private static let rowSQL = """
        SELECT s.id, s.cwd, s.branch, s.summary, s.created_at, s.updated_at,
               COALESCE(SUM(LENGTH(COALESCE(t.user_message,'')) + LENGTH(COALESCE(t.assistant_response,''))), 0),
               COUNT(t.id)
        FROM sessions s LEFT JOIN turns t ON t.session_id = s.id
        """

    private static func row(_ r: CodingSQLiteReader.Row) -> Row? {
        guard let id = r.text(0) else { return nil }
        return Row(id: id, cwd: r.text(1) ?? "", branch: r.text(2), summary: r.text(3) ?? "",
                   createdMs: CodingParse.sqliteDateMs(r.text(4) ?? ""), updatedMs: CodingParse.sqliteDateMs(r.text(5) ?? ""),
                   contentLength: r.int64(6) ?? 0, turnCount: r.int64(7) ?? 0)
    }

    /// 任一行读坏整份作废（Wake `collect::<Result<Vec>>`）；读不了 = nil
    private func rows() -> [Row]? {
        let stamp = CodingSQLiteReader.cacheStamp(db)
        if let cached = cache.get(stamp) { return cached }
        guard let reader = CodingSQLiteReader.open(db, tag: "copilot") else { return nil }
        var rows: [Row] = []
        var broken = false
        let ok = reader.query(Self.rowSQL + " GROUP BY s.id") { r in
            if let row = Self.row(r) { rows.append(row) } else { broken = true }
        }
        guard ok, !broken else { return nil }
        cache.set(stamp, rows)
        return rows
    }

    func listSessionFiles() -> [CodingSessionFileRef] {
        let base = CodingParse.canonicalPath(db.path)
        return (rows() ?? []).filter { $0.turnCount > 0 }.map {
            CodingSessionFileRef(agent: .copilot, nativeId: $0.id, filePath: CodingVirtualPath.make(db: base, id: $0.id),
                                 mtimeMs: $0.updatedMs, size: $0.contentLength)
        }
    }

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? {
        guard let rows = rows() else { return nil }
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [String: CodingSessionMeta] = [:]
        for ref in refs {
            if let row = byId[ref.nativeId] { out[ref.filePath] = meta(ref, row, messageCount: 0) }
        }
        return out
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let (meta, messages) = try parse(ref)
        return CodingParsedSession(meta: meta, units: CodingParse.units(messages), unknownLines: 0)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let (meta, messages) = try parse(ref)
        return CodingParsedTranscript(meta: meta, mainline: messages, sidechains: [], unknownLines: 0)
    }

    /// 单会话：一次连接，会话行与 turns 都只查本会话（不做全表聚合）；每个 turn 出 user + assistant 两条、共用 turn 时间
    private func parse(_ ref: CodingSessionFileRef) throws -> (CodingSessionMeta, [CodingMessage]) {
        guard let reader = CodingSQLiteReader.open(db, tag: "copilot") else { throw CodingSessionError.unreadable("打不开 Copilot 库") }
        var found: Row?
        reader.query(Self.rowSQL + " WHERE s.id = ? GROUP BY s.id", [ref.nativeId]) { found = Self.row($0) }
        guard let row = found else { throw CodingSessionError.unreadable("Copilot 库里没有会话 \(ref.nativeId)") }
        var messages: [CodingMessage] = []
        let ok = reader.query("SELECT user_message, assistant_response, timestamp FROM turns WHERE session_id = ? ORDER BY turn_index",
                              [ref.nativeId]) { t in
            let ts = CodingParse.sqliteDateMs(t.text(2) ?? "")
            if let user = t.text(0), !CodingParse.isBlank(user) { messages.append(CodingParse.textMessage(.user, user, ts: ts)) }
            if let reply = t.text(1), !CodingParse.isBlank(reply) { messages.append(CodingParse.textMessage(.assistant, reply, ts: ts)) }
        }
        guard ok else { throw CodingSessionError.unreadable("读不了 Copilot 会话 \(ref.nativeId) 的 turns") }
        CodingParse.assignSeq(&messages)
        var meta = meta(ref, row, messageCount: messages.filter { $0.kind == .text }.count)
        // summary 缺失时回退首条用户消息
        if meta.title == CodingLimits.untitled, let title = CodingParse.titleFromMessages(messages) { meta.title = title }
        return (meta, messages)
    }

    private func meta(_ ref: CodingSessionFileRef, _ row: Row, messageCount: Int) -> CodingSessionMeta {
        let title = CodingParse.cleanTitleCandidate(row.summary)
        return CodingSessionMeta(
            key: "copilot:\(row.id)", nativeId: row.id, agent: .copilot, title: title.isEmpty ? CodingLimits.untitled : title,
            projectPath: row.cwd, projectName: CodingParse.projectName(row.cwd), filePath: ref.filePath,
            createdAt: row.createdMs > 0 ? row.createdMs : ref.mtimeMs, updatedAt: row.updatedMs > 0 ? row.updatedMs : ref.mtimeMs,
            messageCount: messageCount, sizeBytes: ref.size,
            gitBranch: row.branch.flatMap { $0.isEmpty ? nil : $0 }, model: nil, tokensUsed: nil, archived: false, source: nil
        )
    }
}
extension CopilotAdapter {
    /// 手输 / 预填的就是库文件路径时直接认，不再往下拼（否则得到 <库>/<库> 死路径）
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        CopilotAdapter(db: CodingLocations.isFile(dir) ? dir : dir.appendingPathComponent("session-store.db"))
    }
}
#endif
