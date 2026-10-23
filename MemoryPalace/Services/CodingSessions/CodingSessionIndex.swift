#if os(macOS)
import Foundation
import SQLite3

/// 列表排序键（Wake `SortKey`）
enum CodingSortKey: String, CaseIterable, Sendable {
    case updated, created, messages

    var column: String {
        switch self {
        case .updated: return "updated_at"
        case .created: return "created_at"
        case .messages: return "message_count"
        }
    }

    var displayName: String {
        switch self {
        case .updated: return "更新时间"
        case .created: return "创建时间"
        case .messages: return "消息数"
        }
    }
}

/// 列表筛选（Wake `SessionFilter` 的 MP 子集）：agent / 只看这些 key（收藏）/ 标题或项目名 / 排序
struct CodingListFilter: Equatable, Sendable {
    var agents: [CodingAgent] = []
    /// nil = 不限；空集 = 什么都不要
    var onlyKeys: Set<String>?
    var titleQuery = ""
    /// 改过名、改后的名字命中 titleQuery 的 key（原名不命中也要列出来）
    var titleMatchKeys: Set<String> = []
    var sort: CodingSortKey = .updated
    /// false = 降序（新到旧 / 多到少）
    var ascending = false
    /// 只列根会话、子会话挂在根下展开；收藏范围平铺（Wake `roots_only = !favorite_only`）
    var rootsOnly = false
    /// 限定到这些项目路径（AI 工具的 project 参数解析结果，N5；空 = 不限）
    var projectPaths: [String] = []
    /// 只要更新时间 ≥ 这个时刻的（epoch ms，N5）；只列根时比子树聚合更新时间，与排序同口径（Wake `updated_since`）
    var updatedSince: Int64?

    /// Pinned 与时间分组只在按时间倒序时成立；按消息数或升序平铺（Wake `build_row_groups_at`）
    var isTimeDescending: Bool { !ascending && sort != .messages }

    func sortValue(_ meta: CodingSessionMeta) -> Int64 {
        switch sort {
        case .updated: return meta.updatedAt
        case .created: return meta.createdAt
        case .messages: return Int64(meta.messageCount)
        }
    }

    /// 与 SQL 同口径的内存判定（⌘K 命中是否落在当前筛选里；Wake `session_matches_filter`）。只供界面筛选用：不认 AI 工具专用的
    /// projectPaths / updatedSince（工具不走这里）
    func matches(_ meta: CodingSessionMeta) -> Bool {
        if meta.archived { return false }
        if !agents.isEmpty && !agents.contains(meta.agent) { return false }
        if let onlyKeys, !onlyKeys.contains(meta.key) { return false }
        let query = titleQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty || meta.title.lowercased().contains(query) || meta.projectName.lowercased().contains(query)
            || titleMatchKeys.contains(meta.key)
    }
}

/// 编程会话索引（Wake `db.rs` 的 sessions / messages / messages_fts 三表）。
/// 放 `~/Library/Caches/MemoryPalace/coding-index.sqlite`：可随时重建、不进 MP 备份 / iCloud。
/// 一个实例 = 一条连接，只在持有者那边用（扫描器写、界面读各开一个，WAL 并发）。
final class CodingSessionIndex {
    /// v2（N3-a4）：sessions 加 parent_key。版本不符整库 drop 重建 → 首启全量重扫
    static let schemaVersion = "2"
    /// 进程内迁移锁：读连接 / 扫描器 / 监听各开一条，首启时不能两条同时 drop 重建（会读到半空库，R-WN3 N0 缺陷 3）
    private static let migrationLock = NSLock()

    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("coding-index.sqlite")
    }

    let url: URL
    private var db: OpaquePointer?

    /// - Parameter readOnly: AI 工具用（N5，Wake `open_read_only`）：不建目录、不切 WAL、不跑迁移，绝不写库；库还没建好或版本不对直接报错
    init(url: URL = CodingSessionIndex.defaultURL, readOnly: Bool = false) throws {
        self.url = url
        let version = String(cString: sqlite3_libversion())
        guard sqlite3_libversion_number() >= 3_034_000 else { throw CodingSessionError.sqliteTooOld(version) }
        if !readOnly { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        // 只读打开不存在的库，sqlite 回的是原始错误；先判，给一句清楚的（Wake `open_read_only`）
        if readOnly, !FileManager.default.fileExists(atPath: url.path) { throw CodingSessionError.indexMissing(url.path) }
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil
            throw CodingSessionError.sqlite(message)
        }
        sqlite3_busy_timeout(db, 5000)
        if readOnly {
            if !schemaReady(), !FileManager.default.fileExists(atPath: url.path + "-wal") {
                // 干净关闭的 WAL 库没有 -wal / -shm：系统 SQLite 的只读连接建不了边车，第一条查询就 CANTOPEN（Wake 捆绑的新版 SQLite 会自己建
                // -shm，这里不会）。没有 -wal = 此刻没有写者开着它，主文件自成一体：改用 immutable 只读重开（不加锁、不建边车、绝不写）
                sqlite3_close(db)
                db = nil
                guard let uri = Self.immutableURI(url),
                      sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                    sqlite3_close(db)
                    db = nil
                    throw CodingSessionError.sqlite(message)
                }
            }
            guard schemaReady() else {
                throw CodingSessionError.sqlite("编程会话索引还没建好——先在记忆花园里打开 code 组")
            }
            return
        }
        // 切 WAL 要排他锁：新库上几条连接同时切，SQLite 可能不走 busy handler 直接回 BUSY（并发首开 30 次挂 9 次）——跟迁移一起串行
        Self.migrationLock.lock()
        defer { Self.migrationLock.unlock() }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrate() throws {
        try exec("CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT)")
        let current = try scalarText("SELECT value FROM schema_meta WHERE key = 'version'")
        if current != Self.schemaVersion {
            try exec("DROP TABLE IF EXISTS messages_fts")
            try exec("DROP TABLE IF EXISTS messages")
            try exec("DROP TABLE IF EXISTS sessions")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS sessions (
              key TEXT PRIMARY KEY, agent_id TEXT NOT NULL, native_id TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '', project_path TEXT NOT NULL DEFAULT '', project_name TEXT NOT NULL DEFAULT '',
              git_branch TEXT, created_at INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0, message_count INTEGER DEFAULT 0,
              tokens_used INTEGER, model TEXT, source TEXT, archived INTEGER DEFAULT 0,
              file_path TEXT NOT NULL UNIQUE, file_size INTEGER DEFAULT 0, file_mtime INTEGER DEFAULT 0,
              parent_key TEXT NOT NULL DEFAULT '', host TEXT NOT NULL DEFAULT ''
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_key)")
        // host（N4，Wake 同）：老 v2 库 ALTER 加列、既有行落 ''（= 本机），不 bump 版本、不重建；部分索引须在列就位后建
        if try !columnExists("sessions", "host") {
            try exec("ALTER TABLE sessions ADD COLUMN host TEXT NOT NULL DEFAULT ''")
        }
        try exec("CREATE INDEX IF NOT EXISTS idx_sessions_host ON sessions(host) WHERE host != ''")
        try exec("CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(updated_at DESC)")
        try exec("CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_path, updated_at DESC)")
        try exec("""
            CREATE TABLE IF NOT EXISTS messages (
              id INTEGER PRIMARY KEY, session_key TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT, ts INTEGER, text TEXT NOT NULL
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_key)")
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
              text, content='messages', content_rowid='id', tokenize="trigram case_sensitive 0"
            )
            """)
        try exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES ('version', '\(Self.schemaVersion)')")
    }

    // MARK: - 写

    /// 一条会话整体替换（外部内容型 FTS 要显式删旧行）；同路径旧 key 先清（Codex 线程 id 改名）
    /// 写一条会话（先删旧消息再插）。`guarded`：同 key 已有**另一份**副本、它比这份新（同 mtime 则路径更小）且文件还在盘上
    /// → 不覆盖（Wake `write_session_guarded`：监听增量与全量并发交错时，败方不得后发落库）。回是否写了
    @discardableResult
    func writeSession(_ meta: CodingSessionMeta, fileMtime: Int64, units: [CodingIndexUnit], guarded: Bool = false) throws -> Bool {
        var wrote = false
        try transaction {
            if guarded, let existing = try existingCopy(key: meta.key), existing.path != meta.filePath,
               existing.mtime > fileMtime || (existing.mtime == fileMtime && existing.path < meta.filePath),
               FileManager.default.fileExists(atPath: CodingVirtualPath.strip(existing.path)) {
                return
            }
            for stale in try keys("SELECT key FROM sessions WHERE file_path = ? AND key != ?", [meta.filePath, meta.key]) {
                try deleteSessionRows(stale)
            }
            try deleteMessages(meta.key)
            try upsert(meta, fileMtime: fileMtime)
            let insert = try prepare("INSERT INTO messages(session_key, seq, role, ts, text) VALUES (?, ?, ?, ?, ?)")
            let insertFTS = try prepare("INSERT INTO messages_fts(rowid, text) VALUES (?, ?)")
            for unit in units {
                insert.reset()
                insert.bind(1, meta.key)
                insert.bind(2, Int64(unit.seq))
                insert.bind(3, unit.role.rawValue)
                insert.bind(4, unit.timestamp)
                insert.bind(5, unit.text)
                try insert.run()
                let rowid = sqlite3_last_insert_rowid(db)
                insertFTS.reset()
                insertFTS.bind(1, rowid)
                insertFTS.bind(2, unit.text)
                try insertFTS.run()
            }
            wrote = true
        }
        return wrote
    }

    private func existingCopy(key: String) throws -> (path: String, mtime: Int64)? {
        let s = try prepare("SELECT file_path, file_mtime FROM sessions WHERE key = ?")
        s.bind(1, key)
        return try s.step() ? (s.text(0) ?? "", s.int64(1)) : nil
    }

    /// 快路径：只写 meta（file_mtime 0 → 下轮仍会全量解析）
    func writeMetaOnly(_ metas: [CodingSessionMeta]) throws {
        try transaction {
            for meta in metas {
                for stale in try keys("SELECT key FROM sessions WHERE file_path = ? AND key != ?", [meta.filePath, meta.key]) {
                    try deleteSessionRows(stale)
                }
                try upsert(meta, fileMtime: 0)
            }
        }
    }

    func removeSessions(_ keys: [String]) throws {
        guard !keys.isEmpty else { return }
        try transaction {
            for key in keys { try deleteSessionRows(key) }
        }
    }

    func removeAll() throws {
        try transaction {
            try exec("DELETE FROM messages")
            try exec("INSERT INTO messages_fts(messages_fts) VALUES ('delete-all')")
            try exec("DELETE FROM sessions")
        }
    }

    /// parent_key 只在新行写入：已有行的父子关系归扫描器的父链同步管（Wake 同款——重解析不能把同步好的关系冲掉）
    private func upsert(_ m: CodingSessionMeta, fileMtime: Int64) throws {
        let s = try prepare("""
            INSERT INTO sessions(key, agent_id, native_id, title, project_path, project_name, git_branch, created_at, updated_at,
              message_count, tokens_used, model, source, archived, file_path, file_size, file_mtime, parent_key, host)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET
              title=excluded.title, project_path=excluded.project_path, project_name=excluded.project_name,
              git_branch=excluded.git_branch, created_at=excluded.created_at, updated_at=excluded.updated_at,
              message_count=excluded.message_count, tokens_used=excluded.tokens_used, model=excluded.model,
              source=excluded.source, archived=excluded.archived, file_path=excluded.file_path,
              file_size=excluded.file_size, file_mtime=excluded.file_mtime, host=excluded.host
            """)
        s.bind(1, m.key); s.bind(2, m.agent.rawValue); s.bind(3, m.nativeId); s.bind(4, m.title)
        s.bind(5, m.projectPath); s.bind(6, m.projectName); s.bind(7, m.gitBranch); s.bind(8, m.createdAt)
        s.bind(9, m.updatedAt); s.bind(10, Int64(m.messageCount)); s.bind(11, m.tokensUsed); s.bind(12, m.model)
        s.bind(13, m.source); s.bind(14, Int64(m.archived ? 1 : 0)); s.bind(15, m.filePath); s.bind(16, m.sizeBytes)
        s.bind(17, fileMtime); s.bind(18, m.parentKey); s.bind(19, m.host)
        try s.run()
    }

    private func deleteMessages(_ key: String) throws {
        let select = try prepare("SELECT id, text FROM messages WHERE session_key = ?")
        select.bind(1, key)
        let delete = try prepare("INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', ?, ?)")
        while try select.step() {
            delete.reset()
            delete.bind(1, select.int64(0))
            delete.bind(2, select.text(1) ?? "")
            try delete.run()
        }
        let s = try prepare("DELETE FROM messages WHERE session_key = ?")
        s.bind(1, key)
        try s.run()
    }

    private func deleteSessionRows(_ key: String) throws {
        try deleteMessages(key)
        let s = try prepare("DELETE FROM sessions WHERE key = ?")
        s.bind(1, key)
        try s.run()
    }

    // MARK: - 读

    struct KnownFile: Equatable {
        var mtime: Int64
        var size: Int64
        var key: String
    }

    func key(forPath path: String) throws -> String? {
        let s = try prepare("SELECT key FROM sessions WHERE file_path = ?")
        s.bind(1, path)
        return try s.step() ? s.text(0) : nil
    }

    /// 每个远程主机的库内会话数（远程主机页；不滤归档，与位置页计数同口径；Wake `host_counts`）
    func hostCounts() throws -> [String: Int] {
        let s = try prepare("SELECT host, COUNT(*) FROM sessions WHERE host != '' GROUP BY host")
        var out: [String: Int] = [:]
        while try s.step() { out[s.text(0) ?? ""] = Int(s.int64(1)) }
        return out
    }

    /// 库里有会话的 agent 家数（`mp-code index` 收尾那句；Wake `agent_counts().len()`）
    func agentCount() throws -> Int {
        let s = try prepare("SELECT COUNT(DISTINCT agent_id) FROM sessions")
        return try s.step() ? Int(s.int64(0)) : 0
    }

    /// 只读打开的校验：版本对、N4 的 host 列在
    private func schemaReady() -> Bool {
        (try? scalarText("SELECT value FROM schema_meta WHERE key = 'version'")) == Self.schemaVersion
            && (try? columnExists("sessions", "host")) == true
    }

    /// `file:` URI（路径按 URI 规则转义：空格、中文、#、? 都安全）
    private static func immutableURI(_ url: URL) -> String? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        return components.string
    }

    private func columnExists(_ table: String, _ column: String) throws -> Bool {
        let s = try prepare("PRAGMA table_info(\(table))")
        while try s.step() {
            if s.text(1) == column { return true }
        }
        return false
    }

    func knownFiles() throws -> [String: KnownFile] {
        let s = try prepare("SELECT file_path, file_mtime, file_size, key FROM sessions")
        var out: [String: KnownFile] = [:]
        while try s.step() {
            out[s.text(0) ?? ""] = KnownFile(mtime: s.int64(1), size: s.int64(2), key: s.text(3) ?? "")
        }
        return out
    }

    // MARK: - 父子关系（Wake `session_sources_for_agent` / `parent_links_for_agent` / `replace_parent_links`）

    /// 某家全部会话的 (key, file_path)：父链同步按胜出文件找归属实例
    func sessionSources(agent: CodingAgent) throws -> [(key: String, filePath: String)] {
        let s = try prepare("SELECT key, file_path FROM sessions WHERE agent_id = ? ORDER BY key")
        s.bind(1, agent.rawValue)
        var out: [(key: String, filePath: String)] = []
        while try s.step() { out.append((s.text(0) ?? "", s.text(1) ?? "")) }
        return out
    }

    /// 某家现有的父子关系 child → parent
    func parentLinks(agent: CodingAgent) throws -> [String: String] {
        try parentLinkRows(agent).reduce(into: [:]) { $0[$1.child] = $1.parent }
    }

    private func parentLinkRows(_ agent: CodingAgent) throws -> [(child: String, parent: String)] {
        let s = try prepare("SELECT key, parent_key FROM sessions WHERE agent_id = ? AND parent_key != '' ORDER BY key")
        s.bind(1, agent.rawValue)
        var out: [(child: String, parent: String)] = []
        while try s.step() { out.append((s.text(0) ?? "", s.text(1) ?? "")) }
        return out
    }

    /// 用一家的全量快照原子替换父子关系：只接受库里存在、同家、非自指的；子会话项目覆写成父项目（父项目非空时）——同一棵树归同一个
    /// 项目。返回是否真有行变了
    @discardableResult
    func replaceParentLinks(agent: CodingAgent, links: [(child: String, parent: String)]) throws -> Bool {
        var changed = false
        try transaction {
            let before = try parentLinkRows(agent)
            let clear = try prepare("UPDATE sessions SET parent_key = '' WHERE agent_id = ? AND parent_key != ''")
            clear.bind(1, agent.rawValue)
            try clear.run()
            let update = try prepare("""
                UPDATE sessions AS child SET
                  parent_key = ?1,
                  project_path = COALESCE((SELECT NULLIF(parent.project_path, '') FROM sessions parent WHERE parent.key = ?1), child.project_path),
                  project_name = COALESCE((SELECT NULLIF(parent.project_name, '') FROM sessions parent WHERE parent.key = ?1), child.project_name)
                WHERE child.key = ?2 AND child.agent_id = ?3 AND child.key != ?1
                  AND EXISTS (SELECT 1 FROM sessions parent WHERE parent.key = ?1 AND parent.agent_id = child.agent_id)
                """)
            var seen = Set<String>()
            for link in links where seen.insert(link.child).inserted {
                update.reset()
                update.bind(1, link.parent)
                update.bind(2, link.child)
                update.bind(3, agent.rawValue)
                try update.run()
            }
            let after = try parentLinkRows(agent)
            changed = !before.elementsEqual(after) { $0.child == $1.child && $0.parent == $1.parent }
        }
        return changed
    }

    /// 项目（按最近活动倒序）；会话数按当前筛选算，筛完没会话的项目不出现
    func listProjects(filter: CodingListFilter = CodingListFilter(), includeArchived: Bool = false) throws -> [CodingProjectInfo] {
        let (wheres, args) = Self.listWheres(filter, projectPath: nil, excludeKeys: [], includeArchived: includeArchived)
        // 只列根时：会话数数根，活动时间取子树聚合（Wake `list_projects`）
        let activity = filter.rootsOnly ? Self.rootUpdated(includeArchived) : "updated_at"
        let s = try prepare("""
            SELECT project_path, MAX(project_name), COUNT(*), MAX(\(activity)) AS activity FROM sessions s
            \(Self.whereSQL(wheres)) GROUP BY project_path ORDER BY activity DESC
            """)
        _ = Self.bindList(s, args)
        var out: [CodingProjectInfo] = []
        while try s.step() {
            out.append(CodingProjectInfo(path: s.text(0) ?? "", name: s.text(1) ?? "", sessionCount: Int(s.int64(2)), lastActive: s.int64(3)))
        }
        return out
    }

    /// 有（未归档）会话的 agent，按声明序
    func presentAgents() throws -> [CodingAgent] {
        let s = try prepare("SELECT DISTINCT agent_id FROM sessions WHERE archived = 0")
        var found = Set<String>()
        while try s.step() {
            if let agent = s.text(0) { found.insert(agent) }
        }
        return CodingAgent.allCases.filter { found.contains($0.rawValue) }
    }

    /// 列表角标 / 项目会话数：只列根时数根（统计页数全部，不走这里）
    func countSessions(projectPath: String? = nil, filter: CodingListFilter, includeArchived: Bool = false) throws -> Int {
        let (wheres, args) = Self.listWheres(filter, projectPath: projectPath, excludeKeys: [], includeArchived: includeArchived)
        let s = try prepare("SELECT COUNT(*) FROM sessions s \(Self.whereSQL(wheres))")
        _ = Self.bindList(s, args)
        return try s.step() ? Int(s.int64(0)) : 0
    }

    private enum ListArg {
        case text(String)
        case int(Int64)
    }

    private static func bindList(_ s: Statement, _ args: [ListArg], from start: Int32 = 1) -> Int32 {
        var i = start
        for arg in args {
            switch arg {
            case .text(let value): s.bind(i, value)
            case .int(let value): s.bind(i, value)
            }
            i += 1
        }
        return i
    }

    private static func whereSQL(_ wheres: [String]) -> String {
        wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
    }

    /// 列表谓词（Wake `push_session_filters` 的子集）；标题词两端去空白，LIKE 转义后同时匹配标题与项目名
    private static func listWheres(_ filter: CodingListFilter, projectPath: String?, excludeKeys: Set<String>,
                                   includeArchived: Bool) -> (wheres: [String], args: [ListArg]) {
        var wheres: [String] = []
        var args: [ListArg] = []
        if let projectPath {
            wheres.append("project_path = ?")
            args.append(.text(projectPath))
        }
        if !includeArchived { wheres.append("archived = 0") }
        if !filter.agents.isEmpty {
            wheres.append("agent_id IN (\(placeholders(filter.agents.count)))")
            args += filter.agents.map { .text($0.rawValue) }
        }
        if let only = filter.onlyKeys {
            if only.isEmpty {
                wheres.append("0")
            } else {
                wheres.append("key IN (\(placeholders(only.count)))")
                args += only.sorted().map { .text($0) }
            }
        }
        if !excludeKeys.isEmpty {
            wheres.append("key NOT IN (\(placeholders(excludeKeys.count)))")
            args += excludeKeys.sorted().map { .text($0) }
        }
        let title = filter.titleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            let like = "%" + escapeLike(title) + "%"
            if filter.titleMatchKeys.isEmpty {
                wheres.append("(title LIKE ? ESCAPE '\\' OR project_name LIKE ? ESCAPE '\\')")
                args += [.text(like), .text(like)]
            } else {
                wheres.append("(title LIKE ? ESCAPE '\\' OR project_name LIKE ? ESCAPE '\\' OR key IN (\(placeholders(filter.titleMatchKeys.count))))")
                args += [.text(like), .text(like)] + filter.titleMatchKeys.sorted().map { .text($0) }
            }
        }
        if !filter.projectPaths.isEmpty {
            wheres.append("project_path IN (\(placeholders(filter.projectPaths.count)))")
            args += filter.projectPaths.map { .text($0) }
        }
        if let since = filter.updatedSince {
            wheres.append("\(filter.rootsOnly ? rootUpdated(includeArchived) : "updated_at") >= ?")
            args.append(.int(since))
        }
        if filter.rootsOnly { wheres.append(rootCondition(includeArchived)) }
        return (wheres, args)
    }

    // MARK: - 父子树（Wake `ROOT_*` 常量）：查询表别名固定为 s

    /// 根：没有父，或父不在（隐藏归档时父被归档也算不在）——子会话提升为根
    private static func rootCondition(_ includeArchived: Bool) -> String {
        "(s.parent_key = '' OR NOT EXISTS (SELECT 1 FROM sessions p WHERE p.key = s.parent_key\(includeArchived ? "" : " AND p.archived = 0")))"
    }

    /// 根会话的活动时间连子会话一起聚合（父旧子新的整棵树按子会话的时间排）
    private static func rootUpdated(_ includeArchived: Bool) -> String {
        "MAX(s.updated_at, COALESCE((SELECT MAX(c.updated_at) FROM sessions c WHERE c.parent_key = s.key\(includeArchived ? "" : " AND c.archived = 0")), 0))"
    }

    private static func rootMessages(_ includeArchived: Bool) -> String {
        "(s.message_count + COALESCE((SELECT SUM(c.message_count) FROM sessions c WHERE c.parent_key = s.key\(includeArchived ? "" : " AND c.archived = 0")), 0))"
    }

    /// 排序列：只列根时「更新时间 / 消息数」换成子树聚合——排序、keyset 游标、行上显示的值同一口径
    private static func sortExpression(_ filter: CodingListFilter, includeArchived: Bool) -> String {
        guard filter.rootsOnly else { return filter.sort.column }
        switch filter.sort {
        case .updated: return rootUpdated(includeArchived)
        case .messages: return rootMessages(includeArchived)
        case .created: return "created_at"
        }
    }

    /// 同 sessionColumns 的列序，更新时间 / 消息数换成子树聚合
    private static func rootColumns(_ includeArchived: Bool) -> String {
        """
        key, native_id, agent_id, title, project_path, project_name, file_path, created_at, \(rootUpdated(includeArchived)),
        \(rootMessages(includeArchived)), file_size, git_branch, model, tokens_used, archived, source, parent_key, host
        """
    }

    /// 当前筛选下各根会话看得见的直接子会话数（关系同步时已扁平到根，一次 GROUP BY 覆盖任意嵌套深度；Wake `child_counts`）
    func childCounts(filter: CodingListFilter, includeArchived: Bool = false) throws -> [String: Int] {
        var childFilter = filter
        childFilter.rootsOnly = false
        var (wheres, args) = Self.listWheres(childFilter, projectPath: nil, excludeKeys: [], includeArchived: includeArchived)
        wheres.append("s.parent_key != ''")
        let s = try prepare("SELECT s.parent_key, COUNT(*) FROM sessions s \(Self.whereSQL(wheres)) GROUP BY s.parent_key")
        _ = Self.bindList(s, args)
        var out: [String: Int] = [:]
        while try s.step() {
            if let key = s.text(0), !key.isEmpty { out[key] = Int(s.int64(1)) }
        }
        return out
    }

    /// 某根会话的直接子会话，筛选与排序同列表（置顶由调用方在内存里提前；Wake `list_children`）
    func listChildren(of parentKey: String, filter: CodingListFilter, includeArchived: Bool = false) throws -> [CodingSessionMeta] {
        var childFilter = filter
        childFilter.rootsOnly = false
        var (wheres, args) = Self.listWheres(childFilter, projectPath: nil, excludeKeys: [], includeArchived: includeArchived)
        wheres.append("s.parent_key = ?")
        args.append(.text(parentKey))
        let s = try prepare("""
            SELECT \(Self.sessionColumns) FROM sessions s \(Self.whereSQL(wheres))
            ORDER BY \(filter.sort.column) \(filter.ascending ? "ASC" : "DESC"), key ASC
            """)
        _ = Self.bindList(s, args)
        var out: [CodingSessionMeta] = []
        while try s.step() { if let meta = Self.meta(s) { out.append(meta) } }
        return out
    }

    /// 删除确认用：不受列表筛选与归档影响，递归取完整子树（Wake `all_descendants`）
    func allDescendants(of key: String) throws -> [CodingSessionMeta] {
        let s = try prepare("""
            WITH RECURSIVE descendants(key) AS (
              SELECT key FROM sessions WHERE parent_key = ?
              UNION
              SELECT child.key FROM sessions child JOIN descendants parent ON child.parent_key = parent.key
            )
            SELECT \(Self.sessionColumns) FROM sessions WHERE key IN (SELECT key FROM descendants) ORDER BY created_at, key
            """)
        s.bind(1, key)
        var out: [CodingSessionMeta] = []
        while try s.step() { if let meta = Self.meta(s) { out.append(meta) } }
        return out
    }

    /// 各位置下的会话数（位置 sheet）：一次扫表按（家, 数据根）归属，第一条认领的算；不过滤归档——停用 / 归档目录也该显示自己的量
    /// （Wake `counts_by_path_prefix`）
    func counts(byLocation sources: [(agent: CodingAgent, root: String)]) throws -> [Int] {
        let roots = sources.map { (agent: $0.agent.rawValue, root: CodingParse.canonicalPath($0.root)) }
        let s = try prepare("SELECT agent_id, file_path FROM sessions")
        var counts = Array(repeating: 0, count: sources.count)
        while try s.step() {
            let agent = s.text(0) ?? "", path = s.text(1) ?? ""
            if let i = roots.firstIndex(where: { $0.agent == agent && CodingLocations.pathOwns($0.root, path) }) { counts[i] += 1 }
        }
        return counts
    }

    /// 看得见的父会话：父存在且没归档（Wake `visible_parent_key`）
    func visibleParentKey(of key: String) throws -> String? {
        let s = try prepare("SELECT p.key FROM sessions c JOIN sessions p ON p.key = c.parent_key WHERE c.key = ? AND p.archived = 0")
        s.bind(1, key)
        return try s.step() ? s.text(0) : nil
    }

    private static let sessionColumns = """
        key, native_id, agent_id, title, project_path, project_name, file_path, created_at, updated_at,
        message_count, file_size, git_branch, model, tokens_used, archived, source, parent_key, host
        """

    /// 列表分页（Wake `list_sessions`）：按筛选的排序键与方向，同值以 key 升序稳定；projectPath nil = 全部项目。
    /// `after` = 上一页最后一条（keyset：扫描中途排序值变了也不漏不重，R-WN1 #4）；置顶由调用方另查，这里用 excludeKeys 排掉
    func listSessions(projectPath: String?, filter: CodingListFilter = CodingListFilter(), excludeKeys: Set<String> = [],
                      includeArchived: Bool = false, limit: Int, after cursor: CodingSessionMeta? = nil) throws -> [CodingSessionMeta] {
        var (wheres, args) = Self.listWheres(filter, projectPath: projectPath, excludeKeys: excludeKeys, includeArchived: includeArchived)
        let column = Self.sortExpression(filter, includeArchived: includeArchived)
        if let cursor {
            let value = filter.sortValue(cursor)
            wheres.append("(\(column) \(filter.ascending ? ">" : "<") ? OR (\(column) = ? AND key > ?))")
            args += [.int(value), .int(value), .text(cursor.key)]
        }
        let columns = filter.rootsOnly ? Self.rootColumns(includeArchived) : Self.sessionColumns
        let s = try prepare("""
            SELECT \(columns) FROM sessions s \(Self.whereSQL(wheres))
            ORDER BY \(column) \(filter.ascending ? "ASC" : "DESC"), key ASC LIMIT ?
            """)
        s.bind(Self.bindList(s, args), Int64(limit))
        var out: [CodingSessionMeta] = []
        while try s.step() { if let meta = Self.meta(s) { out.append(meta) } }
        return out
    }

    /// 索引覆盖到的最近活动（AI 工具的新鲜度提示；Wake `latest_activity`）；空库 / 全 0 回 nil
    func latestActivity() throws -> Int64? {
        let s = try prepare("SELECT MAX(updated_at) FROM sessions")
        guard try s.step(), let latest = s.optionalInt64(0), latest > 0 else { return nil }
        return latest
    }

    /// 按原生 id 反查（AI 工具拿到的只是续跑用的那个 id；同一 UUID 跨主机会多于一条；Wake `find_by_native_id`）
    func sessions(nativeId: String) throws -> [CodingSessionMeta] {
        let s = try prepare("SELECT \(Self.sessionColumns) FROM sessions WHERE native_id = ? ORDER BY key")
        s.bind(1, nativeId)
        var out: [CodingSessionMeta] = []
        while try s.step() { if let meta = Self.meta(s) { out.append(meta) } }
        return out
    }

    func session(key: String) throws -> CodingSessionMeta? {
        let s = try prepare("SELECT \(Self.sessionColumns) FROM sessions WHERE key = ?")
        s.bind(1, key)
        return try s.step() ? Self.meta(s) : nil
    }

    func sessionCount(includeArchived: Bool = false) throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM sessions \(includeArchived ? "" : "WHERE archived = 0")"))
    }

    /// 某会话入索引的消息 seq（测试核 seq 契约）
    func messageSeqs(key: String) throws -> [Int] {
        let s = try prepare("SELECT seq FROM messages WHERE session_key = ? ORDER BY seq")
        s.bind(1, key)
        var out: [Int] = []
        while try s.step() { out.append(Int(s.int64(0))) }
        return out
    }

    /// trigram 全文命中的 (key, seq)（N1 搜索面板在此之上加 LIKE 降级 / 片段 / 筛选）
    func matchingMessages(_ query: String, limit: Int = 60) throws -> [(key: String, seq: Int)] {
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let s = try prepare("""
            SELECT m.session_key, m.seq FROM messages_fts f JOIN messages m ON m.id = f.rowid
            WHERE messages_fts MATCH ? ORDER BY bm25(messages_fts) LIMIT ?
            """)
        s.bind(1, phrase)
        s.bind(2, Int64(limit))
        var out: [(key: String, seq: Int)] = []
        while try s.step() { out.append((s.text(0) ?? "", Int(s.int64(1)))) }
        return out
    }

    // MARK: - 全文搜索（N1-b，Wake `db.rs` search_with）

    struct SearchHit: Equatable, Sendable {
        var meta: CodingSessionMeta
        var seq: Int
        var role: String
        /// 片段；命中处用 `highlightOpen` / `highlightClose` 哨兵包住（界面层换成高亮样式）
        var snippet: String
        var timestamp: Int64?
    }

    static let highlightOpen: Character = "\u{E000}"
    static let highlightClose: Character = "\u{E001}"

    /// 按空白分段；任一段 < 3 码点 → 整查降级 LIKE（按时间倒序），否则每段加引号 AND 起来走 trigram MATCH（bm25）。
    /// 消息级一行一条，默认 60 条；archived 不排除。返回 (命中, 是否降级)
    func search(_ query: String, agents: [CodingAgent] = [], projectPaths: [String] = [], updatedSince: Int64? = nil,
                limit: Int = 60) throws -> (hits: [SearchHit], degraded: Bool) {
        let segments = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !segments.isEmpty else { return ([], false) }
        let degraded = segments.contains { $0.unicodeScalars.count < 3 }

        var filterSQL = ""
        var filterArgs: [String] = []
        if !agents.isEmpty {
            filterSQL += " AND s.agent_id IN (\(Self.placeholders(agents.count)))"
            filterArgs += agents.map(\.rawValue)
        }
        if !projectPaths.isEmpty {
            filterSQL += " AND s.project_path IN (\(Self.placeholders(projectPaths.count)))"
            filterArgs += projectPaths
        }
        // since（N5，Wake `SearchFilter.updated_since`）：按会话的更新时间，不按命中消息的时间
        if let updatedSince {
            filterSQL += " AND s.updated_at >= \(updatedSince)"
        }

        var raw: [(key: String, seq: Int, role: String, ts: Int64?, snippet: String)] = []
        if !degraded {
            let match = segments.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            let s = try prepare("""
                SELECT m.session_key, m.seq, m.role, m.ts, snippet(messages_fts, 0, ?, ?, '…', 16)
                FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid JOIN sessions s ON s.key = m.session_key
                WHERE messages_fts MATCH ?\(filterSQL) ORDER BY bm25(messages_fts) LIMIT ?
                """)
            s.bind(1, String(Self.highlightOpen))
            s.bind(2, String(Self.highlightClose))
            s.bind(3, match)
            var i: Int32 = 4
            for arg in filterArgs {
                s.bind(i, arg)
                i += 1
            }
            s.bind(i, Int64(limit))
            while try s.step() {
                raw.append((s.text(0) ?? "", Int(s.int64(1)), s.text(2) ?? "", s.optionalInt64(3), s.text(4) ?? ""))
            }
        } else {
            let likeWhere = segments.map { _ in "m.text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            let s = try prepare("""
                SELECT m.session_key, m.seq, m.role, m.ts, m.text FROM messages m JOIN sessions s ON s.key = m.session_key
                WHERE \(likeWhere)\(filterSQL) ORDER BY m.ts DESC LIMIT ?
                """)
            var i: Int32 = 1
            for segment in segments {
                s.bind(i, "%" + Self.escapeLike(segment) + "%")
                i += 1
            }
            for arg in filterArgs {
                s.bind(i, arg)
                i += 1
            }
            s.bind(i, Int64(limit))
            while try s.step() {
                raw.append((s.text(0) ?? "", Int(s.int64(1)), s.text(2) ?? "", s.optionalInt64(3), Self.likeSnippet(s.text(4) ?? "", first: segments[0])))
            }
        }

        // 每个会话的 meta 只查一次（一个会话常占几十行命中）
        var metas: [String: CodingSessionMeta?] = [:]
        var hits: [SearchHit] = []
        for row in raw {
            let meta: CodingSessionMeta?
            if let cached = metas[row.key] {
                meta = cached
            } else {
                meta = try session(key: row.key)
                metas[row.key] = meta
            }
            if let meta {
                hits.append(SearchHit(meta: meta, seq: row.seq, role: row.role, snippet: row.snippet, timestamp: row.ts))
            }
        }
        return (hits, degraded)
    }

    /// LIKE 转义：先 `\` 再 `%` `_`（配 `ESCAPE '\'`）
    // MARK: - 统计（N2，Wake `Store::insights` 逐字移植）

    /// 「一条提问」的行集（主线用户消息，archived 不计）——两遍消息扫描共用这一个片段，谓词不会漂移
    private static let promptRows = "FROM messages m JOIN sessions s ON s.key = m.session_key WHERE s.archived = 0 AND m.role = 'user'"

    /// 统计快照。`today` = 本地「今天」（streak / 热力图末列 / 最近 7 天共用）。
    /// 无 ts（`ts > 0` 判空：NULL / 0 / 负数）与未来日期的行只计总数；榜单求和不看日期；脏 created_at（0 或 date() 为 NULL）跳过
    func insights(today: CodingDay) throws -> CodingInsightsData {
        var data = CodingInsightsData(asOf: today)
        func dayOf(_ text: String?) -> CodingDay? {
            guard let text, let day = CodingDay(sqlite: text), day <= today else { return nil }
            return day
        }

        let overview = try prepare("""
            SELECT COUNT(*), COALESCE(SUM(tokens_used),0), COALESCE(MIN(NULLIF(created_at,0)),0),
                   COUNT(DISTINCT NULLIF(project_path,'')) FROM sessions WHERE archived = 0
            """)
        if try overview.step() {
            data.sessions = overview.int64(0)
            data.tokens = overview.int64(1)
            data.firstTs = overview.int64(2)
            data.projectCount = overview.int64(3)
        }

        // 第一遍：按（本地日, 本地时）分桶；weekday / monthly 由日期派生
        let byDayHour = try prepare("""
            SELECT CASE WHEN m.ts > 0 THEN date(m.ts/1000,'unixepoch','localtime') END d,
                   CASE WHEN m.ts > 0 THEN CAST(strftime('%H', m.ts/1000,'unixepoch','localtime') AS INTEGER) END h,
                   COUNT(*)
            \(Self.promptRows) GROUP BY d, h ORDER BY d
            """)
        while try byDayHour.step() {
            let n = byDayHour.int64(2)
            data.prompts += n
            guard let day = dayOf(byDayHour.text(0)) else { continue }
            if let hour = byDayHour.optionalInt64(1), (0..<24).contains(hour) { data.hourly[Int(hour)] += n }
            data.weekday[day.weekdayFromMonday] += n
            data.monthly[day.month - 1] += n
            if let last = data.daily.last, last.day == day {
                data.daily[data.daily.count - 1].count += n
            } else {
                data.daily.append(CodingDayCount(day: day, count: n))
            }
        }

        // 第二遍：榜单 prompts 按（agent, 项目, 模型, 日）一次分组；求和不看日期，只有 agent 周桶收趋势窗内的日
        var promptsByAgent: [String: Int64] = [:]
        var promptsByProject: [String: Int64] = [:]
        var promptsByModel: [String: Int64] = [:]
        var weeklyByAgent: [String: [Int64]] = [:]
        let byGroup = try prepare("""
            SELECT s.agent_id, s.project_path, COALESCE(s.model,''),
                   CASE WHEN m.ts > 0 THEN date(m.ts/1000,'unixepoch','localtime') END d, COUNT(*)
            \(Self.promptRows) GROUP BY 1, 2, 3, 4
            """)
        while try byGroup.step() {
            let agent = byGroup.text(0) ?? ""
            let model = byGroup.text(2) ?? ""
            let n = byGroup.int64(4)
            promptsByAgent[agent, default: 0] += n
            promptsByProject[byGroup.text(1) ?? "", default: 0] += n
            if !model.isEmpty { promptsByModel[model, default: 0] += n }
            guard let day = dayOf(byGroup.text(3)), let week = CodingInsightsData.trendWeekIndex(asOf: today, day: day) else { continue }
            weeklyByAgent[agent, default: [Int64](repeating: 0, count: CodingInsightsData.trendWeeks)][week] += n
        }
        data.trendAgents = weeklyByAgent.map { CodingTrendSeries(name: $0.key, weekly: $0.value) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }

        // 榜单主体只查 sessions；项目按 path 分组、按名展示，空 path 不计（与概览 project_count 同谓词）；全量不截断
        func usage(display: String, group: String, filter: String, prompts: [String: Int64]) throws -> [CodingUsageTally] {
            let s = try prepare("""
                SELECT \(display), \(group), COUNT(*), COALESCE(SUM(s.tokens_used),0) FROM sessions s
                WHERE s.archived = 0\(filter) GROUP BY \(group) ORDER BY COUNT(*) DESC, \(display)
                """)
            var out: [CodingUsageTally] = []
            while try s.step() {
                out.append(CodingUsageTally(name: s.text(0) ?? "", sessions: s.int64(2),
                                            prompts: prompts[s.text(1) ?? ""] ?? 0, tokens: s.int64(3)))
            }
            return out
        }
        data.agents = try usage(display: "s.agent_id", group: "s.agent_id", filter: "", prompts: promptsByAgent)
        data.projects = try usage(display: "s.project_name", group: "s.project_path",
                                  filter: " AND s.project_path != ''", prompts: promptsByProject)
        data.models = try usage(display: "s.model", group: "s.model",
                                filter: " AND s.model IS NOT NULL AND s.model != ''", prompts: promptsByModel)

        // 会话按创建日分桶：created_at > 0 与 date() 为 NULL 两层防脏值
        let created = try prepare("""
            SELECT date(created_at/1000,'unixepoch','localtime'), COUNT(*) FROM sessions
            WHERE archived = 0 AND created_at > 0 GROUP BY 1 ORDER BY 1
            """)
        while try created.step() {
            if let day = dayOf(created.text(0)) { data.dailySessions.append(CodingDayCount(day: day, count: created.int64(1))) }
        }

        (data.currentStreak, data.longestStreak) = CodingInsightsData.streaks(data.daily, today: today)
        return data
    }

    // MARK: - 用量页「Code」数据源（research-magpie 2.1）

    struct TokenUsageRow: Equatable, Sendable {
        var agentId: String
        var model: String?
        var tokens: Int64
        var updatedAtMs: Int64
    }

    /// 会话级 token（只有总数），按最后活动时刻；archived 不计、没 token 的不要。时间升序
    func tokenUsageRows(sinceMs: Int64?) throws -> [TokenUsageRow] {
        let s = try prepare("""
            SELECT agent_id, NULLIF(model,''), tokens_used, updated_at FROM sessions
            WHERE archived = 0 AND tokens_used > 0 AND updated_at >= \(sinceMs ?? 0) ORDER BY updated_at
            """)
        var out: [TokenUsageRow] = []
        while try s.step() {
            out.append(TokenUsageRow(agentId: s.text(0) ?? "", model: s.text(1), tokens: s.int64(2), updatedAtMs: s.int64(3)))
        }
        return out
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// LIKE 路径片段：只按第一段定位，命中前 40 字 + 命中 + 后 80 字；找不到兜底前 120 字
    static func likeSnippet(_ text: String, first: String) -> String {
        guard let range = text.range(of: first, options: .caseInsensitive) else { return String(text.prefix(120)) }
        let chars = Array(text)
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = min(chars.count, start + text.distance(from: range.lowerBound, to: range.upperBound))
        let from = max(0, start - 40)
        let to = min(chars.count, end + 80)
        var out = from > 0 ? "…" : ""
        out += String(chars[from..<start])
        out.append(highlightOpen)
        out += String(chars[start..<end])
        out.append(highlightClose)
        out += String(chars[end..<to])
        if to < chars.count { out += "…" }
        return out
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    private static func meta(_ s: Statement) -> CodingSessionMeta? {
        guard let agent = CodingAgent(rawValue: s.text(2) ?? "") else { return nil }
        return CodingSessionMeta(
            key: s.text(0) ?? "", nativeId: s.text(1) ?? "", agent: agent, title: s.text(3) ?? "",
            projectPath: s.text(4) ?? "", projectName: s.text(5) ?? "", filePath: s.text(6) ?? "",
            createdAt: s.int64(7), updatedAt: s.int64(8), messageCount: Int(s.int64(9)), sizeBytes: s.int64(10),
            gitBranch: s.text(11), model: s.text(12), tokensUsed: s.optionalInt64(13), archived: s.int64(14) == 1,
            source: s.text(15), parentKey: s.text(16) ?? "", host: s.text(17) ?? ""
        )
    }

    // MARK: - SQLite 小封装

    final class Statement {
        private var handle: OpaquePointer?
        private let db: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(db: OpaquePointer?, sql: String) throws {
            self.db = db
            guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
                throw CodingSessionError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }

        deinit {
            sqlite3_finalize(handle)
        }

        func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        func bind(_ i: Int32, _ value: String?) {
            if let value {
                sqlite3_bind_text(handle, i, value, -1, Self.transient)
            } else {
                sqlite3_bind_null(handle, i)
            }
        }

        func bind(_ i: Int32, _ value: Int64?) {
            if let value {
                sqlite3_bind_int64(handle, i, value)
            } else {
                sqlite3_bind_null(handle, i)
            }
        }

        func step() throws -> Bool {
            let rc = sqlite3_step(handle)
            if rc == SQLITE_ROW { return true }
            if rc == SQLITE_DONE { return false }
            throw CodingSessionError.sqlite(String(cString: sqlite3_errmsg(db)))
        }

        func run() throws {
            _ = try step()
        }

        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(handle, i) != SQLITE_NULL, let c = sqlite3_column_text(handle, i) else { return nil }
            return String(cString: c)
        }

        func int64(_ i: Int32) -> Int64 {
            sqlite3_column_int64(handle, i)
        }

        func optionalInt64(_ i: Int32) -> Int64? {
            sqlite3_column_type(handle, i) == SQLITE_NULL ? nil : sqlite3_column_int64(handle, i)
        }
    }

    private func prepare(_ sql: String) throws -> Statement {
        try Statement(db: db, sql: sql)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CodingSessionError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalarText(_ sql: String) throws -> String? {
        let s = try prepare(sql)
        return try s.step() ? s.text(0) : nil
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let s = try prepare(sql)
        return try s.step() ? s.int64(0) : 0
    }

    private func keys(_ sql: String, _ args: [String]) throws -> [String] {
        let s = try prepare(sql)
        for (i, arg) in args.enumerated() { s.bind(Int32(i + 1), arg) }
        var out: [String] = []
        while try s.step() { if let key = s.text(0) { out.append(key) } }
        return out
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
#endif
