#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-c Antigravity：照抄 Wake `antigravity_parse_contract`（现建库，同 `tests/common::build_antigravity_db`；DEFAULT 的空串用单引号，
/// 语义相同、不依赖 SQLite 的双引号字符串兼容开关）+ seq 契约 + title 优先 / URI 解码 / 指纹 / 缺库降级。全在 tmp
final class AntigravityAdapterContractTests: XCTestCase {
    private var home: URL!
    private var db: URL { home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db") }

    static let fixtureSQL = """
        CREATE TABLE conversation_summaries (
            conversation_id text, title text NOT NULL DEFAULT '',
            preview text NOT NULL DEFAULT '', step_count integer NOT NULL DEFAULT 0,
            last_modified_time datetime NOT NULL, workspace_uris text NOT NULL,
            parent_conversation_id text NOT NULL DEFAULT '',
            nesting_depth integer NOT NULL DEFAULT 0,
            last_user_input_time datetime NOT NULL,
            PRIMARY KEY (conversation_id)
        );
        INSERT INTO conversation_summaries
            (conversation_id, title, preview, step_count, last_modified_time,
             workspace_uris, parent_conversation_id, nesting_depth, last_user_input_time)
        VALUES
            ('ag-0001', '', 'QR overlay polish', 12, '2026-08-06 13:00:00.000000+00:00',
             '["file:///Users/tester/Github/wakefx"]', '', 0, '2026-08-06 13:00:00.000000+00:00'),
            ('ag-0002', '', 'Child convo', 3, '2026-08-06 13:05:00.000000+00:00',
             '["file:///Users/tester/Github/wakefx"]', 'ag-0001', 1, '0001-01-01 00:00:00+00:00');
        """

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        CodingContract.execSQL(db, Self.fixtureSQL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func ref(_ id: String) -> CodingSessionFileRef {
        CodingSessionFileRef(agent: .antigravity, nativeId: id, filePath: CodingVirtualPath.make(db: db.path, id: id), mtimeMs: 1, size: 1)
    }

    func testAntigravityParseContract() throws {
        let adapter = AntigravityAdapter(home: home)
        let refs = adapter.listSessionFiles()
        XCTAssertEqual(refs.map(\.nativeId), ["ag-0001"], "子会话（parent_conversation_id 非空）不进列表")

        let s = try adapter.parseSession(ref("ag-0001"))
        let t = try adapter.parseTranscript(ref("ag-0001"))
        XCTAssertEqual(s.meta.title, "QR overlay polish", "title 列空，标题在 preview 列")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx", "file:// URI 解码")
        XCTAssertEqual(s.meta.projectName, "wakefx")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-06T13:00:00Z"), "带 +00:00 偏移的 datetime 解析成功，不落 mtime 兜底")
        XCTAssertEqual(s.meta.updatedAt, s.meta.createdAt, "库里只有一个时间")
        XCTAssertEqual(s.meta.messageCount, 12, "step_count")
        XCTAssertTrue(s.meta.filePath.hasSuffix("#ag-0001"), "虚拟路径")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["system/text"], "正文加密：唯一一条 System 消息")
        XCTAssertTrue(t.mainline[0].text.contains("QR overlay polish"))
        XCTAssertTrue(t.mainline[0].text.contains("加密"))
        XCTAssertEqual(s.units.count, 1)
        XCTAssertTrue(s.units.first?.text.contains("QR overlay polish") ?? false, "全文检索搜得到 preview")
        try CodingContract.assertSeqContract(adapter, ref("ag-0001"))
    }

    func testTitlePriorityDecodingFingerprintAndDegrade() throws {
        CodingContract.execSQL(db, """
            INSERT INTO conversation_summaries
                (conversation_id, title, preview, step_count, last_modified_time,
                 workspace_uris, parent_conversation_id, nesting_depth, last_user_input_time)
            VALUES ('ag-0003', '真标题', '预览', 2, '2026-08-07 08:00:00',
                    '["file:///Users/tester/My%20Proj/%E4%B8%AD%E6%96%87"]', '', 0, '2026-08-07 08:00:00');
            """)
        let adapter = AntigravityAdapter(home: home)
        let refs = adapter.listSessionFiles()
        let third = try XCTUnwrap(refs.first { $0.nativeId == "ag-0003" })
        XCTAssertEqual(third.size, Int64("真标题".utf8.count + "预览".utf8.count), "标题 + preview 字节长 = 内容指纹")
        XCTAssertEqual(third.mtimeMs, CodingContract.ms("2026-08-07T08:00:00Z"), "无时区 datetime 按 UTC")
        let meta = try adapter.parseSession(ref("ag-0003")).meta
        XCTAssertEqual(meta.title, "真标题", "title 列有值优先")
        XCTAssertEqual(meta.projectPath, "/Users/tester/My Proj/中文")
        XCTAssertEqual(adapter.quickMeta(refs)?[third.filePath]?.messageCount, 2, "快路径 meta 就是完整 meta")

        XCTAssertEqual(AntigravityAdapter.percentDecode("a%2"), "a%2", "残缺的 % 原样保留")
        XCTAssertEqual(AntigravityAdapter.firstWorkspace("not json"), "")
        XCTAssertThrowsError(try adapter.parseSession(ref("ag-0002")), "子会话不在根会话集合里")
        let missing = AntigravityAdapter(home: URL(fileURLWithPath: "/nonexistent-home"))
        XCTAssertTrue(missing.listSessionFiles().isEmpty, "缺库降级为空")
        XCTAssertNil(missing.quickMeta([third]))
        XCTAssertTrue(CodingSessionRoster.adapters(home: home, environment: [:]).contains { $0.agent == .antigravity && $0.dataRoots == [db] })
    }
}
#endif
