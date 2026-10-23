#if os(macOS)
import SQLite3
import XCTest
@testable import 记忆花园

/// N3-a4：schema v2（parent_key）——全字段往返（upsert / 列清单 / 行映射三处手对应，错位即静默错数据）、
/// v1 库整库重建、多连接并发首开只迁移一次。全在 tmp。
final class CodingSessionIndexSchemaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-index-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("index.sqlite") }

    func testEveryColumnRoundTrips() throws {
        let index = try CodingSessionIndex(url: url)
        let meta = CodingSessionMeta(key: "grok:child-1", nativeId: "child-1", agent: .grok, title: "子会话标题", projectPath: "/p/q",
                                     projectName: "q", filePath: "/p/q/updates.jsonl", createdAt: 111, updatedAt: 222, messageCount: 33,
                                     sizeBytes: 444, gitBranch: "feat/x", model: "grok-4", tokensUsed: 5555, archived: true,
                                     source: "cli", parentKey: "grok:parent-1")
        try index.writeSession(meta, fileMtime: 9, units: [])
        XCTAssertEqual(try index.session(key: meta.key), meta, "每一列都原样读回（含 parent_key）")

        var root = meta
        root.key = "grok:root"
        root.nativeId = "root"
        root.filePath = "/p/q/root.jsonl"
        root.parentKey = ""
        root.tokensUsed = nil
        root.gitBranch = nil
        try index.writeSession(root, fileMtime: 9, units: [])
        XCTAssertEqual(try index.session(key: root.key), root, "空 parent_key / NULL 列也对得上")
    }

    func testVersionOneDatabaseIsRebuilt() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO schema_meta VALUES ('version', '1');
            CREATE TABLE sessions (key TEXT PRIMARY KEY, agent_id TEXT NOT NULL, native_id TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
              project_path TEXT NOT NULL DEFAULT '', project_name TEXT NOT NULL DEFAULT '', git_branch TEXT, created_at INTEGER DEFAULT 0,
              updated_at INTEGER DEFAULT 0, message_count INTEGER DEFAULT 0, tokens_used INTEGER, model TEXT, source TEXT,
              archived INTEGER DEFAULT 0, file_path TEXT NOT NULL UNIQUE, file_size INTEGER DEFAULT 0, file_mtime INTEGER DEFAULT 0);
            INSERT INTO sessions(key, agent_id, native_id, file_path) VALUES ('claude-code:old', 'claude-code', 'old', '/old.jsonl');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let index = try CodingSessionIndex(url: url)
        XCTAssertNil(try index.session(key: "claude-code:old"), "版本不符整库重建，首启全量重扫")
        XCTAssertEqual(try index.sessionCount(), 0)
        var meta = CodingSessionMeta(key: "grok:c", nativeId: "c", agent: .grok, title: "t", projectPath: "", projectName: "",
                                     filePath: "/c.jsonl", createdAt: 1, updatedAt: 1, messageCount: 1, sizeBytes: 1,
                                     gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil)
        meta.parentKey = "grok:p"
        try index.writeSession(meta, fileMtime: 1, units: [])
        XCTAssertEqual(try index.session(key: "grok:c")?.parentKey, "grok:p", "新库有 parent_key 列")
    }

    func testConcurrentFirstOpensMigrateOnce() throws {
        let target = url
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do {
                _ = try CodingSessionIndex(url: target)
            } catch {
                lock.lock()
                failures.append(error.localizedDescription)
                lock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        let index = try CodingSessionIndex(url: target)
        try index.writeSession(CodingSessionMeta(key: "pi:x", nativeId: "x", agent: .pi, title: "t", projectPath: "", projectName: "",
                                                 filePath: "/x.jsonl", createdAt: 1, updatedAt: 1, messageCount: 1, sizeBytes: 1,
                                                 gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil),
                               fileMtime: 1, units: [])
        XCTAssertEqual(try index.sessionCount(), 1)
    }
}
#endif
