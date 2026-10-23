#if os(macOS)
import SQLite3
import XCTest
@testable import 记忆花园

/// N3-a2：别家 SQLite 只读三级（Wake `sqlite_ro`）+ 缓存戳 + 表 / 列探测。全在 tmp，不碰任何 agent 真库。
final class CodingSQLiteReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-sqlite-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDB(_ name: String, _ sql: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }

    func testReadsRowsAndProbesTables() throws {
        let url = try makeDB("a.db", """
            CREATE TABLE sessions (id TEXT, n INTEGER, t REAL, note TEXT);
            INSERT INTO sessions VALUES ('s1', 3, 1.5, NULL), ('s2', 7, 2.25, 'x');
            """)
        let reader = try XCTUnwrap(CodingSQLiteReader.open(url, tag: "test"))
        var rows: [(String?, Int64?, Double?, String?)] = []
        XCTAssertTrue(reader.query("SELECT id, n, t, note FROM sessions WHERE n > ? ORDER BY id", [Int64(1)]) { r in
            rows.append((r.text(0), r.int64(1), r.double(2), r.text(3)))
        })
        XCTAssertEqual(rows.map(\.0), ["s1", "s2"])
        XCTAssertEqual(rows.map(\.1), [3, 7])
        XCTAssertEqual(rows.map(\.2), [1.5, 2.25])
        XCTAssertNil(rows[0].3, "NULL → nil")
        XCTAssertTrue(reader.hasTable("sessions"))
        XCTAssertFalse(reader.hasTable("turns"))
        XCTAssertEqual(reader.columns(of: "sessions"), ["id", "n", "t", "note"])
        XCTAssertFalse(reader.query("SELECT * FROM nope") { _ in }, "坏查询回 false 不崩")
    }

    func testMissingAndNonSQLiteFilesGiveNil() throws {
        XCTAssertNil(CodingSQLiteReader.open(dir.appendingPathComponent("none.db"), tag: "test"))
        let junk = dir.appendingPathComponent("junk.db")
        try Data("not a database at all".utf8).write(to: junk)
        XCTAssertNil(CodingSQLiteReader.open(junk, tag: "test"), "直开探测失败 → 拷贝再探测也失败 → 放弃")
    }

    func testReaderNeverWritesTheSourceDatabase() throws {
        let url = try makeDB("w.db", "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1);")
        let before = try Data(contentsOf: url)
        let reader = try XCTUnwrap(CodingSQLiteReader.open(url, tag: "test"))
        XCTAssertFalse(reader.query("INSERT INTO t VALUES (2)") { _ in }, "只读连接写不进去")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCacheStampTakesNewerOfDBAndWAL() throws {
        let url = try makeDB("c.db", "CREATE TABLE t (x INTEGER);")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        XCTAssertEqual(CodingSQLiteReader.cacheStamp(url), 1_700_000_000_000)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        try Data().write(to: wal)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: wal.path)
        XCTAssertEqual(CodingSQLiteReader.cacheStamp(url), 1_800_000_000_000, "新写入常只落 -wal")
    }
}
#endif
