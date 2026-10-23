#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-c Copilot：照抄 Wake `copilot_parse_contract`（现建库，同 `tests/common::build_copilot_db`）+ seq 契约 +
/// 列表 / 快路径 / 缓存戳 / 缺库降级 / 虚拟路径归属。全在 tmp
final class CopilotAdapterContractTests: XCTestCase {
    private var home: URL!
    private var db: URL { home.appendingPathComponent(".copilot/session-store.db") }

    static let fixtureSQL = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, cwd TEXT, branch TEXT, summary TEXT,
            created_at TEXT, updated_at TEXT
        );
        CREATE TABLE turns (
            id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER,
            user_message TEXT, assistant_response TEXT, timestamp TEXT
        );
        INSERT INTO sessions VALUES
            ('cop-0001','/Users/tester/Github/wakefx','main','Copilot QR fix','2026-08-05 09:00:00','2026-08-05 09:30:00'),
            ('cop-0002','/Users/tester/Github/wakefx','','','2026-08-05 10:00:00','2026-08-05 10:05:00');
        INSERT INTO turns VALUES
            (1,'cop-0001',0,'Copilot 看看二维码扫描为何闪退,是不是 useEffect() 的问题','是依赖数组问题,我给出了修复补丁。','2026-08-05 09:05:00'),
            (2,'cop-0001',1,'谢谢,合并了',NULL,'2026-08-05 09:30:00'),
            (3,'cop-0002',0,'空 summary 会话的兜底标题应取这句','好的。','2026-08-05 10:05:00');
        """

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-copilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        CodingContract.execSQL(db, Self.fixtureSQL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func ref(_ id: String) -> CodingSessionFileRef {
        CodingSessionFileRef(agent: .copilot, nativeId: id, filePath: CodingVirtualPath.make(db: db.path, id: id), mtimeMs: 1, size: 1)
    }

    func testCopilotParseContract() throws {
        let adapter = CopilotAdapter(home: home)
        let s = try adapter.parseSession(ref("cop-0001"))
        let t = try adapter.parseTranscript(ref("cop-0001"))

        XCTAssertEqual(s.meta.title, "Copilot QR fix", "summary 优先")
        XCTAssertEqual(s.meta.gitBranch, "main")
        XCTAssertEqual(s.meta.projectName, "wakefx")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-05T09:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-05T09:30:00Z"))
        XCTAssertEqual(s.meta.messageCount, 3)
        XCTAssertTrue(s.meta.filePath.hasSuffix("#cop-0001"), "虚拟路径原样保留")
        XCTAssertEqual(s.unknownLines, 0)
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text", "user/text"],
                       "turn = user + assistant 两条；第二轮 assistant 为 NULL 只出 user")
        XCTAssertEqual(t.mainline[0].timestamp, CodingContract.ms("2026-08-05T09:05:00Z"))
        XCTAssertEqual(s.units.map(\.seq), [0, 1, 2])
        try CodingContract.assertSeqContract(adapter, ref("cop-0001"))

        let s2 = try adapter.parseSession(ref("cop-0002"))
        XCTAssertEqual(s2.meta.title, "空 summary 会话的兜底标题应取这句", "summary 为空回退首条用户消息")
        XCTAssertNil(s2.meta.gitBranch, "空 branch 当没有")
    }

    func testListingQuickMetaCacheAndDegrade() throws {
        let adapter = CopilotAdapter(home: home)
        CodingContract.execSQL(db, "INSERT INTO sessions VALUES ('cop-empty','/p','','没有 turn','2026-08-05 11:00:00','2026-08-05 11:00:00');")
        let refs = adapter.listSessionFiles().sorted { $0.nativeId < $1.nativeId }
        XCTAssertEqual(refs.map(\.nativeId), ["cop-0001", "cop-0002"], "turn_count > 0 才列")
        let first = try XCTUnwrap(refs.first)
        XCTAssertEqual(first.filePath, CodingVirtualPath.make(db: db.path, id: "cop-0001"))
        XCTAssertEqual(first.mtimeMs, CodingContract.ms("2026-08-05T09:30:00Z"), "mtime = 行内 updated_at")
        let text = "Copilot 看看二维码扫描为何闪退,是不是 useEffect() 的问题" + "是依赖数组问题,我给出了修复补丁。" + "谢谢,合并了"
        XCTAssertEqual(first.size, Int64(text.unicodeScalars.count), "size = turns 正文总长（SQLite LENGTH 按字符）")

        let quick = try XCTUnwrap(adapter.quickMeta(refs))
        XCTAssertEqual(quick[first.filePath]?.title, "Copilot QR fix")
        XCTAssertEqual(quick[first.filePath]?.messageCount, 0, "快路径不数消息")
        XCTAssertEqual(CodingSessionRoster.ownerIndex(of: first.filePath, in: [KiroAdapter(home: home), adapter]), 1,
                       "虚拟路径剥回库路径后归这个实例")

        CodingContract.execSQL(db, """
            INSERT INTO sessions VALUES ('cop-0003','/p','','新会话','2026-08-06 09:00:00','2026-08-06 09:00:00');
            INSERT INTO turns VALUES (4,'cop-0003',0,'新的一问','新的一答','2026-08-06 09:00:00');
            """)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: db.path)
        XCTAssertEqual(adapter.listSessionFiles().count, 3, "库缓存戳变了就重读")

        XCTAssertThrowsError(try adapter.parseSession(ref("no-such")), "库里没有的会话报错，不造空会话")
        let missing = CopilotAdapter(home: URL(fileURLWithPath: "/nonexistent-home"))
        XCTAssertTrue(missing.listSessionFiles().isEmpty, "缺库降级为空")
        XCTAssertNil(missing.quickMeta([first]))
        XCTAssertTrue(CodingSessionRoster.adapters(home: home, environment: [:]).contains { $0.agent == .copilot && $0.dataRoots == [db] })
    }
}
#endif
