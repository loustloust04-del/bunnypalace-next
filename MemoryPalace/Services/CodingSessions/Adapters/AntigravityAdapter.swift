#if os(macOS)
import Foundation

/// Antigravity CLI（Google，二进制 `agy`）：会话正文是加密 .pb，唯一明文是 `~/.gemini/antigravity-cli/conversation_summaries.db`
/// （WAL）——只能做元数据级会话卡片：标题（title 列常空、回退 preview）、时间、workspace（Wake `adapters/antigravity.rs`）。
/// 详情由一条 System 消息承载 preview 与「正文加密」说明，全文检索也只搜得到它。没有每会话文件，引用用虚拟路径
struct AntigravityAdapter: CodingSessionAdapter {
    let db: URL
    private let cache = CodingStampCache<[Row]>()

    init(home: URL) {
        db = home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
    }

    init(db: URL) {
        self.db = db
    }

    var agent: CodingAgent { .antigravity }
    var dataRoots: [URL] { [db] }

    static let encryptedNotice = "Antigravity 的会话正文是加密存储的，这里只能看到这段摘要。"

    struct Row: Sendable {
        var id: String
        var title: String
        var preview: String
        var stepCount: Int64
        var modifiedMs: Int64
        var cwd: String
    }

    /// 只列根会话（子会话 parent_conversation_id 非空）；任一行读坏整份作废；读不了 = nil
    private func rows() -> [Row]? {
        let stamp = CodingSQLiteReader.cacheStamp(db)
        if let cached = cache.get(stamp) { return cached }
        guard let reader = CodingSQLiteReader.open(db, tag: "antigravity") else { return nil }
        var rows: [Row] = []
        var broken = false
        let ok = reader.query("""
            SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris
            FROM conversation_summaries
            WHERE parent_conversation_id = '' AND nesting_depth = 0
            """) { r in
            guard let id = r.text(0) else {
                broken = true
                return
            }
            rows.append(Row(id: id, title: r.text(1) ?? "", preview: r.text(2) ?? "", stepCount: r.int64(3) ?? 0,
                            modifiedMs: CodingParse.sqliteDateMs(CodingParse.trimmed(r.text(4) ?? "")),
                            cwd: Self.firstWorkspace(r.text(5) ?? "")))
        }
        guard ok, !broken else { return nil }
        cache.set(stamp, rows)
        return rows
    }

    /// workspace_uris JSON 数组（`["file:///Users/…"]`）首项 → 本地路径（file:// 路径里空格 / 中文是 %XX）
    static func firstWorkspace(_ raw: String) -> String {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any], let uri = array.first as? String else { return "" }
        return percentDecode(uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri)
    }

    /// 最小 percent-decode：解不了的 % 原样保留，非法 UTF-8 按替换字符（Wake `from_utf8_lossy`）
    static func percentDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let byte = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(byte)
                i += 3
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    func listSessionFiles() -> [CodingSessionFileRef] {
        let base = CodingParse.canonicalPath(db.path)
        // 正文不可读：标题 + preview 的长度就是内容指纹（增量扫描判「变没变」）
        return (rows() ?? []).map {
            CodingSessionFileRef(agent: .antigravity, nativeId: $0.id, filePath: CodingVirtualPath.make(db: base, id: $0.id),
                                 mtimeMs: $0.modifiedMs, size: Int64($0.title.utf8.count + $0.preview.utf8.count))
        }
    }

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? {
        guard let rows = rows() else { return nil }
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var out: [String: CodingSessionMeta] = [:]
        for ref in refs {
            if let row = byId[ref.nativeId] { out[ref.filePath] = meta(ref, row) }
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

    private func parse(_ ref: CodingSessionFileRef) throws -> (CodingSessionMeta, [CodingMessage]) {
        guard let rows = rows() else { throw CodingSessionError.unreadable("打不开 Antigravity 摘要库") }
        guard let row = rows.first(where: { $0.id == ref.nativeId }) else {
            throw CodingSessionError.unreadable("Antigravity 摘要库里没有会话 \(ref.nativeId)")
        }
        // 正文加密不可读：一条 System 消息承载 preview，详情与全文检索都有着落
        let preview = CodingParse.trimmed(row.preview)
        let text = (preview.isEmpty ? "" : preview + "\n\n") + Self.encryptedNotice
        var messages = [CodingParse.textMessage(.system, text, ts: row.modifiedMs)]
        CodingParse.assignSeq(&messages)
        return (meta(ref, row), messages)
    }

    private func meta(_ ref: CodingSessionFileRef, _ row: Row) -> CodingSessionMeta {
        let title = [row.title, row.preview].lazy.map(CodingParse.cleanTitleCandidate).first { !$0.isEmpty } ?? CodingLimits.untitled
        // 库里只有 last_modified 一个时间：created / updated 同源
        let ts = row.modifiedMs > 0 ? row.modifiedMs : ref.mtimeMs
        return CodingSessionMeta(
            key: "antigravity:\(row.id)", nativeId: row.id, agent: .antigravity, title: title,
            projectPath: row.cwd, projectName: CodingParse.projectName(row.cwd), filePath: ref.filePath,
            createdAt: ts, updatedAt: ts, messageCount: Int(row.stepCount), sizeBytes: ref.size,
            gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil
        )
    }
}
extension AntigravityAdapter {
    /// 选中 `~/.gemini`（含 antigravity-cli/）、库所在目录，或直接给库文件都认
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        if CodingLocations.isFile(dir) { return AntigravityAdapter(db: dir) }
        let nested = dir.appendingPathComponent("antigravity-cli/conversation_summaries.db")
        if CodingLocations.isFile(nested) { return AntigravityAdapter(db: nested) }
        return AntigravityAdapter(db: dir.appendingPathComponent("conversation_summaries.db"))
    }
}
#endif
