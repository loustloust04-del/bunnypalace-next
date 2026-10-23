#if os(macOS)
import SQLite3
import XCTest
@testable import 记忆花园

/// 全局契约（Wake `adapter_contracts.rs` `assert_seq_contract`）：mainline seq 从 0 严格递增；每个 FTS 单元在 mainline 找得到
/// 同号同角色的消息；parseSession 与 parseTranscript 两径 meta 一致。每家契约测试都要过
enum CodingContract {
    static func assertSeqContract(_ adapter: CodingSessionAdapter, _ ref: CodingSessionFileRef,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let session = try adapter.parseSession(ref)
        let transcript = try adapter.parseTranscript(ref)
        XCTAssertEqual(transcript.mainline.map(\.seq), Array(0..<transcript.mainline.count), "mainline seq 从 0 严格递增", file: file, line: line)
        for unit in session.units {
            XCTAssertTrue(transcript.mainline.contains { $0.seq == unit.seq && $0.role == unit.role },
                          "FTS 单元 seq \(unit.seq) 在 mainline 找得到同号同角色", file: file, line: line)
        }
        XCTAssertEqual(session.meta, transcript.meta, "两径 meta 一致", file: file, line: line)
    }

    /// 在 url 建库 / 追加行（SQLite 型夹具测试现造，Wake `tests/common::stage_sidecars` 同款）
    static func execSQL(_ url: URL, _ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK, file: file, line: line)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK, error.map { String(cString: $0) } ?? "", file: file, line: line)
        sqlite3_free(error)
    }

    static func rolesKinds(_ messages: [CodingMessage]) -> [String] {
        messages.map { "\($0.role.rawValue)/\($0.kind.rawValue)" }
    }

    static func ms(_ iso: String) -> Int64 {
        CodingParse.isoMs(iso)
    }
}
#endif
