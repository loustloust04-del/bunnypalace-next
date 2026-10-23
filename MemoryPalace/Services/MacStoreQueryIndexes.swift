#if os(macOS)
import Foundation
import SQLite3

/// Repair indexes absent from older macOS stores before SwiftData opens them.
/// Additive only: never change Core Data tables, rows, or migration metadata.
/// Validate the store layout; an unknown layout leaves the store untouched.
enum MacStoreQueryIndexes {
    private struct Definition {
        let table: String
        let columns: [String]
        let name: String
    }
    private static let definitions = [
        Definition(table: "ZMESSAGENODE", columns: ["ZCONVERSATIONID"], name: "mp_node_conversation_v1"),
        Definition(table: "ZMESSAGENODE", columns: ["ZPROFILEID", "ZCONVERSATIONID", "ZISTRASHED"], name: "mp_node_profile_conversation_v1"),
        Definition(table: "ZCONVERSATION", columns: ["ZPROFILEID", "ZISTRASHED"], name: "mp_conversation_profile_v1")
    ]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// No CREATE flag: a missing store is left for SwiftData to create normally.
    @discardableResult
    static func repair(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open store"
            if let db { sqlite3_close(db) }
            throw Failure(message: message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
        }
        func strings(_ sql: String, column: Int32) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, column) { result.append(String(cString: text)) }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            return result
        }
        // All identifiers below come from our fixed definitions or SQLite's index metadata.
        func quoted(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var missing: [Definition] = []
        for definition in definitions {
            let columns = try strings("PRAGMA table_info(\(definition.table))", column: 1)
            guard definition.columns.allSatisfy(columns.contains) else {
                throw Failure(message: "Unknown store layout: \(definition.table)")
            }
            let names = try strings("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='\(definition.table)' AND sql NOT LIKE '% WHERE %'", column: 0)
            var covered = false
            for name in names {
                let indexed = try strings("PRAGMA index_info(\(quoted(name)))", column: 2)
                if Array(indexed.prefix(definition.columns.count)) == definition.columns { covered = true; break }
            }
            if !covered { missing.append(definition) }
        }
        guard !missing.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE")
        do {
            for definition in missing {
                // Do not silently accept a same-name index with the wrong definition.
                try execute("CREATE INDEX \(definition.name) ON \(definition.table)(\(definition.columns.joined(separator: ",")))")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return missing.count
    }
}
#endif
