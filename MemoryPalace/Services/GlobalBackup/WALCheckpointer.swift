import Foundation
import SQLite3

// MARK: - WAL Checkpointer
//
// SwiftData 用 SQLite + WAL 模式。staging container build 完后 ARC 释放可能不及时
// 触发 wal checkpoint（codex Round 3 必改 #3）。
//
// 我们独立打开 staging-store SQLite 跑 `PRAGMA wal_checkpoint(TRUNCATE);` 把 WAL 收进
// store 文件。完成后验证 staging-store-wal 不存在或 size==0，否则抛错。
//
// 用 system sqlite3 C API（Swift 内置），不依赖 SwiftData。autoreleasepool 之外调，
// 此时 SwiftData container 已 deinit 文件句柄理论已释放。
//
// 注意：truncate 模式会把 wal 文件截断到 0 字节但**不删除**（SQLite 行为）。
// 我们后续 phase 2 install 时把这个 0 字节 wal 跟 store 一起 move 即可。
// 或者验证 size==0 后显式删掉。

enum WALCheckpointer {

    enum Mode: String {
        case truncate = "TRUNCATE"
        case full = "FULL"
        case restart = "RESTART"
    }

    /// 对 store 跑 wal checkpoint。返回 (busy:Int, log:Int, checkpointed:Int)。
    /// throws GlobalBackupError.walCheckpointFailed 或 walStillExistsAfterCheckpoint。
    @discardableResult
    static func checkpoint(storeURL: URL, mode: Mode = .truncate) throws -> (busy: Int, log: Int, checkpointed: Int) {
        var db: OpaquePointer?

        // 打开
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, openFlags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw GlobalBackupError.walCheckpointFailed(storeURL)
        }
        defer { sqlite3_close(db) }

        // wal_checkpoint(TRUNCATE) 通过 pragma 函数走，能拿三个返回列
        let sql = "PRAGMA wal_checkpoint(\(mode.rawValue));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GlobalBackupError.walCheckpointFailed(storeURL)
        }
        defer { sqlite3_finalize(stmt) }

        var busy: Int = -1
        var log: Int = -1
        var ckpt: Int = -1
        if sqlite3_step(stmt) == SQLITE_ROW {
            busy = Int(sqlite3_column_int(stmt, 0))
            log = Int(sqlite3_column_int(stmt, 1))
            ckpt = Int(sqlite3_column_int(stmt, 2))
        }

        // busy != 0 表示有页未能 checkpoint（仍有连接锁住 WAL）
        if busy != 0 {
            throw GlobalBackupError.walCheckpointFailed(storeURL)
        }

        return (busy, log, ckpt)
    }

    /// checkpoint 后验证 wal/shm 状态。
    /// truncate 模式后：wal 应该不存在或 size==0；shm 可能仍存在但是元数据小文件，可接受。
    static func verifyWALClean(storeURL: URL) throws {
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let fm = FileManager.default
        guard fm.fileExists(atPath: walURL.path) else {
            return  // 不存在 OK
        }
        let attrs = try fm.attributesOfItem(atPath: walURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        if size > 0 {
            throw GlobalBackupError.walStillExistsAfterCheckpoint(walURL)
        }
    }

    /// 一键：checkpoint + verify。staging build 收尾调这个。
    static func checkpointAndVerify(storeURL: URL) throws {
        _ = try checkpoint(storeURL: storeURL, mode: .truncate)
        try verifyWALClean(storeURL: storeURL)
    }
}
