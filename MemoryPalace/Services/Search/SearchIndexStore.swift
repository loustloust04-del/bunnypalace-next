import Foundation

/// 进索引的一条消息：body 是「看得见的文字」（ContentCleaner.visibleText），FTS 里存的是它切词后的形态
struct SearchIndexDoc: Equatable {
    let nodeId: String
    let conversationId: String
    let profileId: String
    let role: String
    let created: Date?
    let trashed: Bool
    let body: String
    /// PersistentIdentifier 的编码：didSave 的 deleted 只给 identifier，靠它反查 node
    let identifierKey: String?
}

struct SearchIndexHit: Equatable {
    let nodeId: String
    let conversationId: String
    let role: String
    let created: Date?
}

struct SearchIndexStats: Equatable {
    let count: Int
    /// 毫秒取整，避免 Double 往返的尾差
    let maxCreatedMillis: Int64?
}

/// S5 全文索引边车（plan-search-s5 设计 1）。缓存不是真相：坏了 / 版本不对就删文件重建。
/// 写：一条独占写连接，所有写在串行队列里、doc 与 fts 同一事务；每批带 epoch，epoch 变了的旧批直接丢。
/// 读：独立连接（query_only），每次查询从池里短借。
final class SearchIndexStore: @unchecked Sendable {
    static let schemaVersion = "2"
    /// contentless_delete 要 3.43+
    static let minimumSQLiteVersion: Int32 = 3_043_000

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("search-index.sqlite")
    }

    static func removeFiles(at url: URL = defaultURL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    enum OpenError: Error { case versionMismatch, integrityFailed(String) }

    let url: URL
    private let writer: SQLiteDB
    private let writeQueue = DispatchQueue(label: "com.susu.MemoryPalace.search-index.writer", qos: .utility)
    private var epochValue: Int64 = 0
    private let readerLock = NSLock()
    private var idleReaders: [SQLiteDB] = []

    /// 打开；版本不符 / 打不开 / 完整性检查失败 → 删文件重建一次
    static func open(at url: URL = defaultURL) throws -> SearchIndexStore {
        guard SQLiteDB.libVersionNumber >= minimumSQLiteVersion else { throw SQLiteError.tooOld(SQLiteDB.libVersion) }
        do {
            return try SearchIndexStore(url: url)
        } catch {
            print("[search-index] 打开失败，删文件重建：\(error)")
            removeFiles(at: url)
            return try SearchIndexStore(url: url)
        }
    }

    private init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        writer = try SQLiteDB(url: url)
        try writer.exec("PRAGMA journal_mode=WAL")
        try writer.exec("PRAGMA synchronous=NORMAL")
        if !isNew {
            let check = try writer.scalarText("PRAGMA quick_check") ?? ""
            guard check == "ok" else { throw OpenError.integrityFailed(check) }
            let version = try? writer.scalarText("SELECT value FROM meta WHERE key = 'version'")
            guard version == Self.schemaVersion else { throw OpenError.versionMismatch }
        }
        try writer.exec("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS doc (
                id INTEGER PRIMARY KEY,
                node_id TEXT NOT NULL UNIQUE,
                conversation_id TEXT NOT NULL,
                profile_id TEXT NOT NULL,
                role TEXT NOT NULL,
                created REAL,
                node_trashed INTEGER NOT NULL,
                body TEXT NOT NULL,
                identifier_key TEXT
            );
            CREATE INDEX IF NOT EXISTS doc_conversation ON doc(conversation_id);
            CREATE INDEX IF NOT EXISTS doc_profile ON doc(profile_id);
            CREATE INDEX IF NOT EXISTS doc_identifier ON doc(identifier_key);
            CREATE TABLE IF NOT EXISTS dirty (conversation_id TEXT PRIMARY KEY);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                body, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2'
            );
            INSERT OR IGNORE INTO meta(key, value) VALUES ('version', '\(Self.schemaVersion)');
            INSERT OR IGNORE INTO meta(key, value) VALUES ('epoch', '0');
            """)
        epochValue = Int64(try writer.scalarText("SELECT value FROM meta WHERE key = 'epoch'") ?? "0") ?? 0
    }

    // MARK: - Meta

    var epoch: Int64 { writeQueue.sync { epochValue } }

    func meta(_ key: String) -> String? {
        writeQueue.sync { try? metaLocked(key) }
    }

    private func metaLocked(_ key: String) throws -> String? {
        let s = try writer.prepare("SELECT value FROM meta WHERE key = ?")
        s.bind(1, key)
        return try s.step() ? s.text(0) : nil
    }

    private func setMetaLocked(_ key: String, _ value: String?) throws {
        if let value {
            let s = try writer.prepare("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
            s.bind(1, key)
            s.bind(2, value)
            try s.run()
        } else {
            let s = try writer.prepare("DELETE FROM meta WHERE key = ?")
            s.bind(1, key)
            try s.run()
        }
    }

    private func bumpEpochLocked() throws {
        epochValue += 1
        try setMetaLocked("epoch", String(epochValue))
    }

    // MARK: - 写

    /// 一批增删改（同一事务）。epoch 已变 → 整批丢弃，返回 false（调用方按新 epoch 重读再来）
    @discardableResult
    func apply(upserts: [SearchIndexDoc], deleteNodeIds: [String] = [], meta: [String: String?] = [:],
               epoch: Int64) throws -> Bool {
        try writeQueue.sync {
            guard epoch == epochValue else { return false }
            try writer.transaction {
                for nodeId in deleteNodeIds { try deleteNodeLocked(nodeId) }
                for doc in upserts { try upsertLocked(doc) }
                for (k, v) in meta { try setMetaLocked(k, v) }
            }
            return true
        }
    }

    /// 整对话重建（对账 / 标脏）：先删该对话全部行再插；同时清掉它的脏标记
    @discardableResult
    func replaceConversation(_ conversationId: String, with docs: [SearchIndexDoc], epoch: Int64) throws -> Bool {
        try writeQueue.sync {
            guard epoch == epochValue else { return false }
            try writer.transaction {
                let del = try writer.prepare("DELETE FROM fts WHERE rowid IN (SELECT id FROM doc WHERE conversation_id = ?)")
                del.bind(1, conversationId)
                try del.run()
                let delDoc = try writer.prepare("DELETE FROM doc WHERE conversation_id = ?")
                delDoc.bind(1, conversationId)
                try delDoc.run()
                for doc in docs { try upsertLocked(doc) }
                let clean = try writer.prepare("DELETE FROM dirty WHERE conversation_id = ?")
                clean.bind(1, conversationId)
                try clean.run()
            }
            return true
        }
    }

    /// 删楼层：该楼层 doc + fts 同事务删，epoch + 1（在途旧批作废）
    func deleteProfile(_ profileId: String) throws {
        try writeQueue.sync {
            try writer.transaction {
                let del = try writer.prepare("DELETE FROM fts WHERE rowid IN (SELECT id FROM doc WHERE profile_id = ?)")
                del.bind(1, profileId)
                try del.run()
                let delDoc = try writer.prepare("DELETE FROM doc WHERE profile_id = ?")
                delDoc.bind(1, profileId)
                try delDoc.run()
                try bumpEpochLocked()
            }
        }
    }

    /// 清空重建：全删 + epoch + 1，回填游标 / 完成标记一并清
    func reset() throws {
        try writeQueue.sync {
            try writer.transaction {
                try writer.exec("INSERT INTO fts(fts) VALUES('delete-all')")
                try writer.exec("DELETE FROM doc")
                try writer.exec("DELETE FROM dirty")
                try writer.exec("DELETE FROM meta WHERE key NOT IN ('version', 'epoch')")
                try bumpEpochLocked()
            }
        }
    }

    func markDirty(_ conversationIds: [String]) throws {
        guard !conversationIds.isEmpty else { return }
        try writeQueue.sync {
            try writer.transaction {
                let s = try writer.prepare("INSERT OR IGNORE INTO dirty(conversation_id) VALUES (?)")
                for id in conversationIds {
                    s.reset()
                    s.bind(1, id)
                    try s.run()
                }
            }
        }
    }

    func dirtyConversations() -> [String] {
        writeQueue.sync {
            guard let s = try? writer.prepare("SELECT conversation_id FROM dirty") else { return [] }
            var out: [String] = []
            while (try? s.step()) == true { if let id = s.text(0) { out.append(id) } }
            return out
        }
    }

    private func upsertLocked(_ doc: SearchIndexDoc) throws {
        let find = try writer.prepare("SELECT id, body FROM doc WHERE node_id = ?")
        find.bind(1, doc.nodeId)
        let created = doc.created?.timeIntervalSince1970
        if try find.step() {
            let rowid = find.int64(0)
            let bodyChanged = find.text(1) != doc.body
            let up = try writer.prepare("""
                UPDATE doc SET conversation_id = ?, profile_id = ?, role = ?, created = ?, node_trashed = ?,
                body = ?, identifier_key = COALESCE(?, identifier_key) WHERE id = ?
                """)
            up.bind(1, doc.conversationId)
            up.bind(2, doc.profileId)
            up.bind(3, doc.role)
            up.bind(4, created)
            up.bind(5, Int64(doc.trashed ? 1 : 0))
            up.bind(6, doc.body)
            up.bind(7, doc.identifierKey)
            up.bind(8, rowid)
            try up.run()
            if bodyChanged {
                try deleteFTSLocked(rowid)
                try insertFTSLocked(rowid, doc.body)
            }
        } else {
            let ins = try writer.prepare("""
                INSERT INTO doc(node_id, conversation_id, profile_id, role, created, node_trashed, body, identifier_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            ins.bind(1, doc.nodeId)
            ins.bind(2, doc.conversationId)
            ins.bind(3, doc.profileId)
            ins.bind(4, doc.role)
            ins.bind(5, created)
            ins.bind(6, Int64(doc.trashed ? 1 : 0))
            ins.bind(7, doc.body)
            ins.bind(8, doc.identifierKey)
            try ins.run()
            try insertFTSLocked(writer.lastInsertRowID, doc.body)
        }
    }

    private func deleteNodeLocked(_ nodeId: String) throws {
        let find = try writer.prepare("SELECT id FROM doc WHERE node_id = ?")
        find.bind(1, nodeId)
        guard try find.step() else { return }
        let rowid = find.int64(0)
        try deleteFTSLocked(rowid)
        let del = try writer.prepare("DELETE FROM doc WHERE id = ?")
        del.bind(1, rowid)
        try del.run()
    }

    private func insertFTSLocked(_ rowid: Int64, _ body: String) throws {
        let s = try writer.prepare("INSERT INTO fts(rowid, body) VALUES (?, ?)")
        s.bind(1, rowid)
        s.bind(2, SearchTextSegmenter.segment(body))
        try s.run()
    }

    private func deleteFTSLocked(_ rowid: Int64) throws {
        let s = try writer.prepare("DELETE FROM fts WHERE rowid = ?")
        s.bind(1, rowid)
        try s.run()
    }

    // MARK: - 读

    /// 一个词的命中消息（节点级过滤：node_trashed = 0、role ∈ roles、created 在区间内——有区间时 created 为 nil 的排除，
    /// 与 SearchService 旧路径一致；scope 非 nil 只留这些对话，空 scope 直接空）。按 created 倒序。
    /// 词里没有可索引字符（纯 emoji / 标点）→ nil，调用方退回旧扫描。
    func hits(word: String, profileId: String, roles: Set<String>,
              interval: (start: Date, end: Date)? = nil, scope: Set<String>? = nil) throws -> [SearchIndexHit]? {
        guard let match = SearchTextSegmenter.ftsQuery(for: word) else { return nil }
        if roles.isEmpty { return [] }
        if let scope, scope.isEmpty { return [] }
        let roleList = roles.sorted()
        var sql = """
            SELECT d.node_id, d.conversation_id, d.role, d.created FROM fts JOIN doc d ON d.id = fts.rowid
            WHERE fts MATCH ? AND d.profile_id = ? AND d.node_trashed = 0
            AND d.role IN (\(Array(repeating: "?", count: roleList.count).joined(separator: ",")))
            """
        if interval != nil { sql += " AND d.created IS NOT NULL AND d.created >= ? AND d.created <= ?" }
        sql += " ORDER BY d.created DESC"
        return try withReader { db in
            let s = try db.prepare(sql)
            var i: Int32 = 1
            s.bind(i, match); i += 1
            s.bind(i, profileId); i += 1
            for role in roleList { s.bind(i, role); i += 1 }
            if let interval {
                s.bind(i, interval.start.timeIntervalSince1970); i += 1
                s.bind(i, interval.end.timeIntervalSince1970)
            }
            var out: [SearchIndexHit] = []
            while try s.step() {
                guard let nodeId = s.text(0), let convId = s.text(1) else { continue }
                if let scope, !scope.contains(convId) { continue }
                out.append(SearchIndexHit(nodeId: nodeId, conversationId: convId, role: s.text(2) ?? "",
                                          created: s.optionalDouble(3).map(Date.init(timeIntervalSince1970:))))
            }
            return out
        }
    }

    /// 按对话聚合的命中：[convId: [nodeId]]（顺序同 hits）
    func conversations(word: String, profileId: String, roles: Set<String>,
                       interval: (start: Date, end: Date)? = nil, scope: Set<String>? = nil) throws -> [String: [String]]? {
        guard let hits = try hits(word: word, profileId: profileId, roles: roles, interval: interval, scope: scope) else { return nil }
        var out: [String: [String]] = [:]
        for hit in hits { out[hit.conversationId, default: []].append(hit.nodeId) }
        return out
    }

    /// 清洗后的原文（片段 / 多词复核 / 字面分用）
    func bodies(nodeIds: [String]) throws -> [String: String] {
        guard !nodeIds.isEmpty else { return [:] }
        return try withReader { db in
            var out: [String: String] = [:]
            for start in stride(from: 0, to: nodeIds.count, by: 500) {
                let chunk = nodeIds[start..<min(start + 500, nodeIds.count)]
                let s = try db.prepare("SELECT node_id, body FROM doc WHERE node_id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))")
                for (i, id) in chunk.enumerated() { s.bind(Int32(i + 1), id) }
                while try s.step() {
                    if let id = s.text(0), let body = s.text(1) { out[id] = body }
                }
            }
            return out
        }
    }

    /// identifier 编码 → (nodeId, conversationId)；didSave 的删除走这里
    func nodes(forIdentifierKeys keys: [String]) throws -> [String: (nodeId: String, conversationId: String)] {
        guard !keys.isEmpty else { return [:] }
        return try withReader { db in
            var out: [String: (nodeId: String, conversationId: String)] = [:]
            let s = try db.prepare("SELECT node_id, conversation_id FROM doc WHERE identifier_key = ?")
            for key in keys {
                s.reset()
                s.bind(1, key)
                if try s.step(), let nodeId = s.text(0), let convId = s.text(1) { out[key] = (nodeId, convId) }
            }
            return out
        }
    }

    func docCount() -> Int {
        (try? withReader { Int(try $0.scalarInt("SELECT COUNT(*) FROM doc")) }) ?? 0
    }

    /// 对账用：每楼层 节点数 + 最大 createTime
    func profileStats() throws -> [String: SearchIndexStats] {
        try stats("SELECT profile_id, COUNT(*), MAX(created) FROM doc GROUP BY profile_id", bind: nil)
    }

    /// 对账用：某楼层每个对话 节点数 + 最大 createTime
    func conversationStats(profileId: String) throws -> [String: SearchIndexStats] {
        try stats("SELECT conversation_id, COUNT(*), MAX(created) FROM doc WHERE profile_id = ? GROUP BY conversation_id", bind: profileId)
    }

    private func stats(_ sql: String, bind: String?) throws -> [String: SearchIndexStats] {
        try withReader { db in
            let s = try db.prepare(sql)
            if let bind { s.bind(1, bind) }
            var out: [String: SearchIndexStats] = [:]
            while try s.step() {
                guard let key = s.text(0) else { continue }
                out[key] = SearchIndexStats(count: Int(s.int64(1)), maxCreatedMillis: s.optionalDouble(2).map(Self.millis))
            }
            return out
        }
    }

    static func millis(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }

    func fileSizeBytes() -> Int64 {
        ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    /// 回填完做一次：合并 FTS 段、收缩体积
    func optimize() throws {
        try writeQueue.sync {
            try writer.exec("INSERT INTO fts(fts) VALUES('optimize')")
            try writer.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private func withReader<T>(_ body: (SQLiteDB) throws -> T) throws -> T {
        readerLock.lock()
        let pooled = idleReaders.popLast()
        readerLock.unlock()
        let db: SQLiteDB
        if let pooled {
            db = pooled
        } else {
            db = try SQLiteDB(url: url)
            try db.exec("PRAGMA query_only=1")
        }
        defer {
            readerLock.lock()
            if idleReaders.count < 4 { idleReaders.append(db) }
            readerLock.unlock()
        }
        return try body(db)
    }
}
