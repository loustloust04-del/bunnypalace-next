import Foundation
import SQLite3

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case sqlite(String)
    case tooOld(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "SQLite 打不开：\(m)"
        case .sqlite(let m): return "SQLite：\(m)"
        case .tooOld(let v): return "系统 SQLite \(v) 太旧"
        }
    }
}

/// 两端共用的最小 SQLite C API 封装（从 CodingSessionIndex 的私有封装抽出，那边不动）。
/// 一个实例 = 一条连接，不跨线程并发用：调用方自己串行（写者队列 / 每次查询短借）。
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError.open(message)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        sqlite3_close(handle)
    }

    static var libVersionNumber: Int32 { sqlite3_libversion_number() }
    static var libVersion: String { String(cString: sqlite3_libversion()) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(db: handle, sql: sql)
    }

    func scalarText(_ sql: String) throws -> String? {
        let s = try prepare(sql)
        return try s.step() ? s.text(0) : nil
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        let s = try prepare(sql)
        return try s.step() ? s.int64(0) : 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    final class Statement {
        private var handle: OpaquePointer?
        private let db: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(db: OpaquePointer?, sql: String) throws {
            self.db = db
            guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
                throw SQLiteError.sqlite(String(cString: sqlite3_errmsg(db)))
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

        func bind(_ i: Int32, _ value: Double?) {
            if let value {
                sqlite3_bind_double(handle, i, value)
            } else {
                sqlite3_bind_null(handle, i)
            }
        }

        func step() throws -> Bool {
            let rc = sqlite3_step(handle)
            if rc == SQLITE_ROW { return true }
            if rc == SQLITE_DONE { return false }
            throw SQLiteError.sqlite(String(cString: sqlite3_errmsg(db)))
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

        func optionalDouble(_ i: Int32) -> Double? {
            sqlite3_column_type(handle, i) == SQLITE_NULL ? nil : sqlite3_column_double(handle, i)
        }
    }
}
