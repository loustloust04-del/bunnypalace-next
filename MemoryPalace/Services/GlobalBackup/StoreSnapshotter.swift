import Foundation
import SQLite3

// MARK: - StoreSnapshotter（research-backup-while-open §3.2，A0 spike 定用手写 sqlite3_backup）
//
// app 开着时给活库做一份一致快照：只读连接开读事务钉住 T0 → 逐个克隆外置文件 → 同一读事务里 backup_step(-1)
// → 产物切 journal_mode=DELETE（单文件）→ quick_check / 消息条数 / 外置引用核对 → snapshot.json → rename 成品。
// 读不挡写：SwiftData 照常存，只是这几秒 WAL 不能回绕。
// 只用系统 libsqlite3（`import SQLite3`），和 Core Data 同一份库实例，同进程多连接的 POSIX 锁才不会互相释放。

enum StoreSnapshotter {

    struct Manifest: Codable, Equatable {
        var id: String
        var createdAt: String
        var createdAtEpoch: Double
        var appBuild: String
        var schemaFingerprint: String
        var storeBytes: Int64
        var externalFiles: Int
        var externalBytes: Int64
        var externalRefs: Int
        var messageCount: Int
        var attempts: Int
        var durationMs: Int
    }

    enum SnapshotError: LocalizedError, Equatable {
        case noStore(String)
        case insufficientSpace(need: Int64, free: Int64)
        case sqlite(String)
        case missingExternal([String])
        case badSnapshot(String)

        var errorDescription: String? {
            switch self {
            case .noStore(let p): return "没有活库：\(p)"
            case .insufficientSpace(let need, let free): return "设备空间不够：可用 \(free) 字节 < 需要 \(need) 字节（库 + WAL × 1.2）"
            case .sqlite(let m): return "SQLite：\(m)"
            case .missingExternal(let names): return "外置文件缺 \(names.count) 个（重做一次还缺）：\(names.prefix(5).joined(separator: ", "))"
            case .badSnapshot(let m): return "快照自检没过：\(m)"
            }
        }
    }

    static let storeName = "unified.store"
    static let externalName = ".unified_SUPPORT"
    static let manifestName = "snapshot.json"
    static let tmpPrefix = ".tmp-"
    static let spaceFactor = 1.2

    /// 在 root/.tmp-<id>/ 里做，完成后 rename 成 root/<id>/（rename 即「完成」信号）：
    /// unified.store（journal_mode=DELETE 单文件）+ .unified_SUPPORT/ + snapshot.json。失败时 .tmp 删掉、抛错。
    /// afterPin：测试钩子，读快照钉住之后、克隆外置目录之前调用。
    static func snapshot(store: URL, external: URL, root: URL, id: String, appBuild: String, fingerprint: String,
                         freeBytes: (URL) -> Int64? = volumeFreeBytes,
                         afterPin: (() -> Void)? = nil) throws -> Manifest {
        let fm = FileManager.default
        let started = Date()
        guard fm.fileExists(atPath: store.path) else { throw SnapshotError.noStore(store.path) }
        let need = Int64(Double(fileSize(store) + fileSize(URL(fileURLWithPath: store.path + "-wal"))) * spaceFactor)
        if let free = freeBytes(store.deletingLastPathComponent()), free < need {
            throw SnapshotError.insufficientSpace(need: need, free: free)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(tmpPrefix + id, isDirectory: true)
        let final = root.appendingPathComponent(id, isDirectory: true)
        do {
            var attempts = 0
            var result: (refs: Int, messages: Int)
            while true {
                attempts += 1
                try? fm.removeItem(at: tmp)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                result = try copyConsistent(store: store, external: external, into: tmp, afterPin: attempts == 1 ? afterPin : nil)
                let missing = try missingExternal(in: tmp)
                if missing.isEmpty { break }
                // T0 之后、克隆之前被删的外置文件：整份重做一次，还缺就判失败
                if attempts >= 2 { throw SnapshotError.missingExternal(missing) }
            }
            let ext = externalStats(tmp.appendingPathComponent(externalName, isDirectory: true))
            let now = Date()
            let manifest = Manifest(
                id: id,
                createdAt: isoString(started),
                createdAtEpoch: started.timeIntervalSince1970,
                appBuild: appBuild,
                schemaFingerprint: fingerprint,
                storeBytes: fileSize(tmp.appendingPathComponent(storeName)),
                externalFiles: ext.files,
                externalBytes: ext.bytes,
                externalRefs: result.refs,
                messageCount: result.messages,
                attempts: attempts,
                durationMs: Int(now.timeIntervalSince(started) * 1000)
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(manifest).write(to: tmp.appendingPathComponent(manifestName), options: .atomic)
            var tmpURL = tmp
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? tmpURL.setResourceValues(values)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: tmp, to: final)
            return manifest
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - 一次拷贝

    /// 读事务钉住 T0 → 克隆外置目录 → backup → 提交读事务 → 产物切 DELETE + 自检。返回 (外置引用数, 消息条数)。
    private static func copyConsistent(store: URL, external: URL, into dir: URL,
                                       afterPin: (() -> Void)?) throws -> (refs: Int, messages: Int) {
        let destURL = dir.appendingPathComponent(storeName)
        var src: OpaquePointer?
        guard sqlite3_open_v2(store.path, &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            defer { sqlite3_close(src) }
            throw SnapshotError.sqlite("只读打开活库失败：\(message(src))")
        }
        defer { sqlite3_close(src) }
        sqlite3_busy_timeout(src, 5000)
        try exec(src, "BEGIN")
        _ = try scalarInt(src, "SELECT count(*) FROM sqlite_master")
        afterPin?()
        try cloneExternal(from: external, to: dir.appendingPathComponent(externalName, isDirectory: true))

        var dst: OpaquePointer?
        guard sqlite3_open_v2(destURL.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            defer { sqlite3_close(dst) }
            throw SnapshotError.sqlite("建快照库失败：\(message(dst))")
        }
        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            defer { sqlite3_close(dst) }
            throw SnapshotError.sqlite("backup_init：\(message(dst))")
        }
        let rc = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else {
            defer { sqlite3_close(dst) }
            throw SnapshotError.sqlite("backup_step 返回 \(rc)：\(message(dst))")
        }
        try? exec(src, "COMMIT")

        let result: (refs: Int, messages: Int)
        do {
            defer { sqlite3_close(dst) }
            let mode = try scalarText(dst, "PRAGMA journal_mode=DELETE")
            guard mode.lowercased() == "delete" else { throw SnapshotError.badSnapshot("journal_mode 切不成 delete（\(mode)）") }
            let check = try scalarText(dst, "PRAGMA quick_check")
            guard check == "ok" else { throw SnapshotError.badSnapshot("quick_check：\(check)") }
            result = (try externalRefs(dst).count, try scalarInt(dst, "SELECT count(*) FROM ZMESSAGENODE"))
        }
        // 已是 DELETE 单文件、连接已关：切模式时系统 SQLite 可能留下的 -wal / -shm 不属于快照
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: destURL.path + suffix) }
        return result
    }

    /// 逐个文件克隆（同卷 APFS clonefile，近乎零成本）。跳过 Core Data 写到一半的 `.interim`，
    /// 拷的过程中消失的文件忽略——缺的引用由 missingExternal 兜底。
    private static func cloneExternal(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(atPath: src.path) else { return }
        while let rel = walker.nextObject() as? String {
            let from = src.appendingPathComponent(rel)
            let to = dst.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            } else if !rel.hasSuffix(".interim") {
                do {
                    try fm.copyItem(at: from, to: to)
                } catch where !fm.fileExists(atPath: from.path) {
                    continue
                }
            }
        }
    }

    // MARK: - 外置引用（A0：0x02 + 36 字符 UUID + 0x00）

    /// 快照目录里库引用、但 _EXTERNAL_DATA 里没有的文件名
    static func missingExternal(in dir: URL) throws -> [String] {
        var db: OpaquePointer?
        let path = dir.appendingPathComponent(storeName).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw SnapshotError.sqlite("只读打开快照失败：\(message(db))")
        }
        defer { sqlite3_close(db) }
        let data = dir.appendingPathComponent(externalName, isDirectory: true).appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        return try externalRefs(db).filter { !FileManager.default.fileExists(atPath: data.appendingPathComponent($0).path) }.sorted()
    }

    /// 所有 BLOB 列里的外置引用（文件名）
    static func externalRefs(_ db: OpaquePointer?) throws -> Set<String> {
        var refs = Set<String>()
        for (table, column) in try blobColumns(db) {
            let sql = "SELECT \(quoted(column)) FROM \(quoted(table)) WHERE length(\(quoted(column))) = 38 AND substr(\(quoted(column)), 1, 1) = x'02'"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SnapshotError.sqlite("prepare：\(sql)：\(message(db))")
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard sqlite3_column_bytes(stmt, 0) == 38, let raw = sqlite3_column_blob(stmt, 0) else { continue }
                let bytes = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: 38)
                guard bytes[37] == 0 else { continue }
                let name = String(decoding: bytes[1..<37], as: UTF8.self)
                if UUID(uuidString: name) != nil { refs.insert(name) }
            }
        }
        return refs
    }

    private static func blobColumns(_ db: OpaquePointer?) throws -> [(String, String)] {
        var tables: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &stmt, nil) == SQLITE_OK else {
            throw SnapshotError.sqlite("列表：\(message(db))")
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { tables.append(String(cString: c)) }
        }
        sqlite3_finalize(stmt)
        var out: [(String, String)] = []
        for table in tables {
            var info: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(quoted(table)))", -1, &info, nil) == SQLITE_OK else { continue }
            while sqlite3_step(info) == SQLITE_ROW {
                guard let name = sqlite3_column_text(info, 1), let type = sqlite3_column_text(info, 2) else { continue }
                if String(cString: type).uppercased() == "BLOB" { out.append((table, String(cString: name))) }
            }
            sqlite3_finalize(info)
        }
        return out
    }

    // MARK: - Helpers

    static func volumeFreeBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func externalStats(_ dir: URL) -> (files: Int, bytes: Int64) {
        var files = 0, bytes: Int64 = 0
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return (0, 0) }
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(v?.fileSize ?? 0)
        }
        return (files, bytes)
    }

    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func message(_ db: OpaquePointer?) -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SnapshotError.sqlite("\(sql)：\(message(db))")
        }
    }

    private static func scalarText(_ db: OpaquePointer?, _ sql: String) throws -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SnapshotError.sqlite("prepare：\(sql)：\(message(db))")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else {
            throw SnapshotError.sqlite("step：\(sql)：\(message(db))")
        }
        return String(cString: c)
    }

    private static func scalarInt(_ db: OpaquePointer?, _ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SnapshotError.sqlite("prepare：\(sql)：\(message(db))")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SnapshotError.sqlite("step：\(sql)：\(message(db))")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
