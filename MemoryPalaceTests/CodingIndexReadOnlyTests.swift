#if os(macOS)
import SQLite3
import XCTest
@testable import 记忆花园

/// N6-b3 取证出的坑：干净关闭的 WAL 库没有 -wal / -shm，系统 SQLite 的只读连接第一条查询就 CANTOPEN（Wake 捆绑的 SQLite 会自己建 -shm）。
/// app 里搜索 / 统计的写连接随开随关，最后一个关掉就是这个形态——mp-code 与聊天里的工具都得照样读得出来，而且一个边车都不留
final class CodingIndexReadOnlyTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("中文 目录#1/index.sqlite") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-index-ro-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 建库 → 截断式 checkpoint → 删掉两个边车，得到「干净关闭」的样子（不依赖写连接何时真正关掉）
    private func makeCleanlyClosedWALIndex() throws {
        do { _ = try CodingSessionIndex(url: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    func testReadOnlyOpensACleanlyClosedWALIndexWithoutWritingSidecars() throws {
        try makeCleanlyClosedWALIndex()
        let before = try Data(contentsOf: url)
        let index = try CodingSessionIndex(url: url, readOnly: true)
        XCTAssertEqual(try index.countSessions(filter: CodingListFilter(), includeArchived: true), 0)
        XCTAssertNil(try index.latestActivity())
        for suffix in ["-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix), "只读兜底不该建 \(suffix)")
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "绝不写")
    }

    func testReadOnlyStillRefusesAMissingOrUnbuiltIndex() throws {
        XCTAssertThrowsError(try CodingSessionIndex(url: url, readOnly: true), "库不存在") { error in
            guard case CodingSessionError.indexMissing = error else { return XCTFail("\(error)") }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE other(x)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try CodingSessionIndex(url: url, readOnly: true), "别家的库 / 没建好的库照样拒")
    }
}
#endif
