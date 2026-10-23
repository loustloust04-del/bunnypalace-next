import XCTest
import SwiftData
import SQLite3
@testable import 记忆花园

@MainActor
final class MacStoreIndexTests: XCTestCase {
    func testMacStoreUsesIndexesForProfileAndConversationQueries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-store-index-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema([Conversation.self, MessageNode.self])
        let config = ModelConfiguration("index-test", schema: schema, url: url,
                                        allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.insert(Conversation(id: "c", title: "fixture", createTime: Date(), updateTime: Date(),
                                    currentNodeId: "", profileId: "p"))
        try context.save()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        let queries = [
            "SELECT Z_PK FROM ZMESSAGENODE WHERE ZPROFILEID='p' AND ZCONVERSATIONID='c'",
            "SELECT Z_PK FROM ZCONVERSATION WHERE ZPROFILEID='p' AND ZISTRASHED=0"
        ]
        for query in queries {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + query, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            var details: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 3) { details.append(String(cString: text)) }
            }
            let plan = details.joined(separator: " ")
            XCTAssertTrue(plan.contains("SEARCH"), plan)
            XCTAssertTrue(plan.contains("INDEX"), plan)
            XCTAssertFalse(plan.contains("SCAN"), plan)
        }
    }
    #if os(macOS)
    func testLegacyIndexRepairIsAtomicIdempotentAndPreservesRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-index-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE ZMESSAGENODE (Z_PK INTEGER PRIMARY KEY, ZCONVERSATIONID TEXT, ZPROFILEID TEXT, ZISTRASHED INTEGER, ZCONTENT TEXT);
        CREATE TABLE ZCONVERSATION (Z_PK INTEGER PRIMARY KEY, ZPROFILEID TEXT, ZISTRASHED INTEGER);
        INSERT INTO ZMESSAGENODE VALUES(1, 'c', 'p', 0, 'preserved');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try MacStoreQueryIndexes.repair(at: url), 3)
        XCTAssertEqual(try MacStoreQueryIndexes.repair(at: url), 0)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT ZCONTENT FROM ZMESSAGENODE WHERE Z_PK=1", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "preserved")
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN SELECT Z_PK FROM ZMESSAGENODE WHERE ZCONVERSATIONID='c'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertTrue(String(cString: sqlite3_column_text(statement, 3)).contains("SEARCH"))
        sqlite3_finalize(statement)
    }

    func testUnknownLegacySchemaRemainsUntouched() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-index-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ZMESSAGENODE (ZCONVERSATIONID TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try MacStoreQueryIndexes.repair(at: url))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='index'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
    }
    #endif

}
