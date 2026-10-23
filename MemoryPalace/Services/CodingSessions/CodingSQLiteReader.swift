#if os(macOS)
import Foundation
import SQLite3

/// SQLite 型数据源没有每会话独立文件：用 `<库路径>#<会话 id>` 作虚拟 file_path（Wake `sqlite_ro::virtual_path`）。
/// 磁盘上不存在：删除只写墓碑、监听不追踪；Finder 显示 / Hermes 档案名要先剥回库路径。
enum CodingVirtualPath {
    static func make(db: String, id: String) -> String {
        "\(db)#\(id)"
    }

    /// 磁盘上不存在的路径剥掉最后一个 `#<id>`；真实存在的原样返回（文件名里本来就可能有 #）
    static func strip(_ path: String) -> String {
        guard !FileManager.default.fileExists(atPath: path), let hash = path.lastIndex(of: "#") else { return path }
        return String(path[..<hash])
    }
}

/// SQLite 型 adapter 的行缓存：按库缓存戳（`CodingSQLiteReader.cacheStamp`）存一份，戳变了才重读——一轮扫描里 listSessionFiles
/// 与 quickMeta 各做一次全表聚合（Wake `MtimeCache`）。读失败不缓存
final class CodingStampCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (stamp: Int64, value: Value)?

    func get(_ stamp: Int64) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return entry?.stamp == stamp ? entry?.value : nil
    }

    func set(_ stamp: Int64, _ value: Value) {
        lock.lock()
        entry = (stamp, value)
        lock.unlock()
    }
}

/// 只读读别家 SQLite（Wake `sqlite_ro::open_sqlite_ro`）：readonly 直开 + 探测查询 → 拷主库与 `-wal` / `-shm`
/// 到临时目录再开 → 放弃。绝不写、绝不 `immutable=1`（对方 WAL 并发写时不安全）。走了拷贝的临时目录随实例释放清掉。
/// 一个实例 = 一条连接，只在创建它的线程上用
final class CodingSQLiteReader {
    private var db: OpaquePointer?
    private let tmp: URL?

    private init(db: OpaquePointer, tmp: URL?) {
        self.db = db
        self.tmp = tmp
    }

    deinit {
        sqlite3_close(db)
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    static func open(_ url: URL, tag: String) -> CodingSQLiteReader? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let handle = openReadOnly(url.path), probe(handle) {
            return CodingSQLiteReader(db: handle, tmp: nil)
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(tag)-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return nil }
        let copy = tmp.appendingPathComponent("db.sqlite")
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: url.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
        }
        guard let handle = openReadOnly(copy.path), probe(handle) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return CodingSQLiteReader(db: handle, tmp: tmp)
    }

    private static func openReadOnly(_ path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private static func probe(_ handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_finalize(statement) }
        let ok = sqlite3_step(statement) == SQLITE_ROW
        if !ok { sqlite3_close(handle) }
        return ok
    }

    /// 一行：按列号取值（NULL → nil）
    struct Row {
        fileprivate let statement: OpaquePointer?

        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }

        func text(_ i: Int32) -> String? {
            guard !isNull(i), let c = sqlite3_column_text(statement, i) else { return nil }
            return String(cString: c)
        }

        func int64(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(statement, i) }

        func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(statement, i) }
    }

    /// 跑一条查询（参数只收 String / Int64 / nil）；prepare 或 step 出错回 false（调用方当「这家这次读不了」）
    @discardableResult
    func query(_ sql: String, _ args: [Any?] = [], row: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, transient)
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return true }
            guard rc == SQLITE_ROW else { return false }
            row(Row(statement: statement))
        }
    }

    func hasTable(_ name: String) -> Bool {
        var found = false
        query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]) { _ in found = true }
        return found
    }

    /// 表的列名（老版本库缺列时用默认表达式顶上，Wake hermes / opencode 同款）
    func columns(of table: String) -> Set<String> {
        var out = Set<String>()
        query("SELECT name FROM pragma_table_info(?)", [table]) { row in
            if let name = row.text(0) { out.insert(name) }
        }
        return out
    }

    /// 行缓存的失效戳：主库与 `-wal` 的 mtime 取新者（新写入常只落 -wal，Wake `db_cache_stamp`）
    static func cacheStamp(_ url: URL) -> Int64 {
        func stamp(_ path: String) -> Int64 {
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return CodingParse.mtimeMs(date)
        }
        return max(stamp(url.path), stamp(url.path + "-wal"))
    }
}
#endif
