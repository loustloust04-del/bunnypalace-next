import Foundation
import SQLite3
import CryptoKit

// MARK: - SQLiteStoreVerifier (plan v2 F-B)
//
// 公共 SQLite 校验模块。staging（R-1）+ primary（R-4）双闸共用。
//
// 设计原则：
// 1. **不开 SwiftData ModelContainer**。验收 2 抓到 staging-store 数据漂移 bug
//    根因暂未坐实（详 docs/research-staging-data-leak.md）。如果用 SwiftData 二次
//    打开同 store 校验，可能再触发同款 bug → 用 system sqlite3 C API 直接读，
//    完全绕开 SwiftData。
// 2. SQLITE_OPEN_READONLY + SQLITE_OPEN_FULLMUTEX — 不写、线程安全
//    （codex Round 5 #9）
// 3. preflight 查 sqlite_master + PRAGMA table_info 确认 ZCONVERSATION.ZID /
//    ZMESSAGENODE 存在；schema 漂移时显式抛错，不静默通过
//
// 调用方：
// - GlobalImporter.verifyStagingStore（buildStagingContainer 后、WAL checkpoint 后、
//   文件区 staging 前、commitPendingImport 前）
// - PendingImportApplier.verifyPrimaryStore（P2.1 install store + P2.2 install external
//   完成后立刻，stickers/audiobooks/themes/floors 装之前 — codex Round 5 #1）

enum SQLiteStoreVerifier {

    struct Snapshot {
        let convCount: Int
        let nodeCount: Int
        let convIds: Set<String>        // ZCONVERSATION.ZID 全集（保大小写）
    }

    enum VerifierError: LocalizedError {
        case openFailed(URL, String)
        case schemaPreflightFailed(URL, String)
        case queryFailed(URL, String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let u, let m):
                return "无法打开 \(u.lastPathComponent): \(m)"
            case .schemaPreflightFailed(let u, let m):
                return "schema preflight 失败 \(u.lastPathComponent): \(m)"
            case .queryFailed(let u, let m):
                return "查询失败 \(u.lastPathComponent): \(m)"
            }
        }
    }

    /// 读 store 的 snapshot。READONLY + FULLMUTEX 打开，pre-flight 验
    /// ZCONVERSATION.ZID / ZMESSAGENODE 表存在再查 count + ids。
    static func snapshot(storeURL: URL) throws -> Snapshot {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw VerifierError.openFailed(storeURL, msg)
        }
        defer { sqlite3_close(db) }

        try preflight(db: db, storeURL: storeURL)

        let convCount = try scalar(db: db, sql: "SELECT COUNT(*) FROM ZCONVERSATION", storeURL: storeURL)
        let nodeCount = try scalar(db: db, sql: "SELECT COUNT(*) FROM ZMESSAGENODE", storeURL: storeURL)
        let convIds = try fetchStringSet(db: db, sql: "SELECT ZID FROM ZCONVERSATION", storeURL: storeURL)

        return Snapshot(convCount: convCount, nodeCount: nodeCount, convIds: convIds)
    }

    /// canonical conv ids hash（保大小写）：
    /// Swift String 稳定排序（按 Unicode scalars 自然顺序）+ `\n` 分隔 + SHA256(UTF-8)
    ///
    /// codex Round 5 #3 明确：ID 大小写敏感，不能 uppercase；用原始 UTF-8。
    /// 一处实现，GlobalImporter.commitPendingImport 写 flag + PendingImportApplier.verifyPrimaryStore 读 flag 都用同一算法。
    static func canonicalIdsHash(_ ids: Set<String>) -> String {
        let sorted = ids.sorted()  // Swift String < 用 Unicode scalars 自然顺序，保大小写
        let joined = sorted.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Internal Helpers

    private static func preflight(db: OpaquePointer?, storeURL: URL) throws {
        // 1. 验 ZCONVERSATION / ZMESSAGENODE 表存在
        let tablesSQL = """
            SELECT name FROM sqlite_master
            WHERE type='table' AND name IN ('ZCONVERSATION','ZMESSAGENODE')
        """
        let tables = try fetchStringSet(db: db, sql: tablesSQL, storeURL: storeURL)
        guard tables.contains("ZCONVERSATION") else {
            throw VerifierError.schemaPreflightFailed(storeURL, "缺 ZCONVERSATION 表")
        }
        guard tables.contains("ZMESSAGENODE") else {
            throw VerifierError.schemaPreflightFailed(storeURL, "缺 ZMESSAGENODE 表")
        }

        // 2. 验 ZCONVERSATION.ZID 列存在
        let colsSQL = "PRAGMA table_info(ZCONVERSATION)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, colsSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw VerifierError.schemaPreflightFailed(storeURL, "PRAGMA table_info(ZCONVERSATION) prepare 失败")
        }
        defer { sqlite3_finalize(stmt) }

        var hasZID = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1) {
                if String(cString: cName) == "ZID" {
                    hasZID = true
                    break
                }
            }
        }
        guard hasZID else {
            throw VerifierError.schemaPreflightFailed(storeURL, "ZCONVERSATION 缺 ZID 列")
        }
    }

    private static func scalar(db: OpaquePointer?, sql: String, storeURL: URL) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VerifierError.queryFailed(storeURL, "prepare: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw VerifierError.queryFailed(storeURL, "step: \(sql)")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func fetchStringSet(db: OpaquePointer?, sql: String, storeURL: URL) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VerifierError.queryFailed(storeURL, "prepare: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out.insert(String(cString: c))
            }
        }
        return out
    }
}
