#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-c Hermes：照抄 Wake `hermes_parse_contract` / `hermes_legacy_schema_still_parses`（现建库，同 `tests/common::build_hermes_db`）
/// + seq 契约 + parentKey（Wake `parent_links` 在 MP 落成 meta 字段）+ 档案 / HERMES_HOME / 续跑档案名 / 缺库降级。全在 tmp
final class HermesAdapterContractTests: XCTestCase {
    private var home: URL!
    private var hermesHome: URL { home.appendingPathComponent(".hermes") }
    private var db: URL { hermesHome.appendingPathComponent("state.db") }

    static let fixtureSQL = #"""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT NOT NULL, user_id TEXT, model TEXT,
            model_config TEXT, system_prompt TEXT, parent_session_id TEXT,
            started_at REAL NOT NULL, ended_at REAL, end_reason TEXT,
            message_count INTEGER DEFAULT 0, tool_call_count INTEGER DEFAULT 0,
            input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0, title TEXT
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
            role TEXT NOT NULL, content TEXT, tool_call_id TEXT, tool_calls TEXT,
            tool_name TEXT, timestamp REAL NOT NULL, token_count INTEGER,
            finish_reason TEXT, reasoning TEXT, reasoning_details TEXT,
            codex_reasoning_items TEXT
        );
        INSERT INTO sessions (id, source, model, started_at, ended_at, message_count,
                              input_tokens, output_tokens, cache_read_tokens, title) VALUES
            ('hs-0001', 'cli', 'gpt-5.4', 1786172400.0, 1786172520.0, 4, 300, 50, 100, 'Hermes QR fix'),
            ('hs-0002', 'telegram', 'claude-opus-5', 1786176000.0, NULL, 3, 0, 0, 0, NULL),
            ('hs-0003', 'tool', 'gpt-5.4', 1786176100.0, 1786176101.0, 2, 0, 0, 0, NULL),
            ('hs-0004', 'cli', 'gpt-5.4', 1786176200.0, 1786176201.0, 0, 0, 0, 0, NULL);
        INSERT INTO sessions (id, source, model, started_at, ended_at, message_count, parent_session_id, title) VALUES
            ('hs-0005', 'cli', 'gpt-5.4', 1786176300.0, 1786176301.0, 1, 'hs-0001', 'Hermes QR fix #2');
        INSERT INTO messages (session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, reasoning) VALUES
            ('hs-0001', 'user', 'Hermes 看看二维码扫描为何闪退,是不是 useEffect() 的问题', NULL, NULL, NULL, 1786172405.0, NULL),
            ('hs-0001', 'assistant', NULL, NULL,
             '[{"id":"call_h1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"src/QrScanner.tsx\"}"}}]',
             NULL, 1786172408.0, '先读一下组件源码'),
            ('hs-0001', 'tool', 'useEffect(() => watch())', 'call_h1', NULL, 'read_file', 1786172409.0, NULL),
            ('hs-0001', 'assistant', '是依赖数组问题,我给出了修复补丁。', NULL, NULL, NULL, 1786172412.0, NULL),
            ('hs-0001', 'user', '谢谢,合并了', NULL, NULL, NULL, 1786172520.0, NULL),
            ('hs-0002', 'user', '[{"type":"text","text":"无标题会话的兜底标题应取这句"},{"type":"image_url","image_url":{"url":"file:///tmp/a.png"}}]', NULL, NULL, NULL, 1786176005.0, NULL),
            ('hs-0002', 'assistant', NULL, NULL, '[{"name":"terminal","arguments":"{\"command\":\"ls\"}"}]', NULL, 1786176006.0, NULL),
            ('hs-0002', 'tool', 'README.md', NULL, NULL, 'terminal', 1786176007.0, NULL),
            ('hs-0002', 'assistant', '好的。', NULL, NULL, NULL, 1786176008.0, NULL),
            ('hs-0003', 'user', 'internal search', NULL, NULL, NULL, 1786176100.5, NULL),
            ('hs-0005', 'user', 'branched from hs-0001', NULL, NULL, NULL, 1786176300.5, NULL),
            ('hs-0003', 'assistant', 'nothing', NULL, NULL, NULL, 1786176101.0, NULL);
        """#

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-hermes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        CodingContract.execSQL(db, Self.fixtureSQL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func ref(_ db: URL, _ id: String) -> CodingSessionFileRef {
        CodingSessionFileRef(agent: .hermes, nativeId: id, filePath: CodingVirtualPath.make(db: db.path, id: id), mtimeMs: 1, size: 1)
    }

    func testHermesParseContract() throws {
        let adapter = HermesAdapter.make(home: home, environment: [:])
        XCTAssertEqual(adapter.listSessionFiles().map(\.nativeId).sorted(), ["hs-0001", "hs-0002", "hs-0005"],
                       "tool 内部会话与零消息会话不列")
        XCTAssertTrue(adapter.managesParentLinks)
        XCTAssertEqual(adapter.parentLinks().map { "\($0.child)>\($0.parent)" }, ["hermes:hs-0005>hermes:hs-0001"],
                       "/branch 分支挂到父会话下（同库内配对）")

        let r = ref(db, "hs-0001")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)
        XCTAssertEqual(s.meta.key, "hermes:hs-0001")
        XCTAssertEqual(s.meta.title, "Hermes QR fix", "库内标题优先")
        XCTAssertEqual(s.meta.model, "gpt-5.4")
        XCTAssertEqual(s.meta.tokensUsed, 450)
        XCTAssertNil(s.meta.source, "cli 不打徽章")
        XCTAssertEqual(s.meta.projectPath, "", "库里没有 cwd")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-08T07:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-08T07:02:00Z"))
        XCTAssertEqual(s.meta.messageCount, 3)
        XCTAssertTrue(s.meta.filePath.hasSuffix("#hs-0001"))
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text", "user/text"],
                       "assistant(tool_calls) → tool → assistant(text) 合并成一条")
        let a = t.mainline[1]
        XCTAssertEqual(a.text, "是依赖数组问题,我给出了修复补丁。")
        XCTAssertEqual(a.thinking, "先读一下组件源码")
        XCTAssertEqual(a.timestamp, CodingContract.ms("2026-08-08T07:00:08Z"))
        XCTAssertEqual(a.toolCalls.count, 1)
        XCTAssertEqual(a.toolCalls.first?.name, "read_file")
        XCTAssertTrue(a.toolCalls.first?.inputPreview.contains("QrScanner") ?? false, "arguments 是 JSON 字符串，解开后预览才有路径")
        XCTAssertEqual(a.toolCalls.first?.output, "useEffect(() => watch())")
        XCTAssertEqual(s.units.map(\.seq), [0, 1, 2])
        try CodingContract.assertSeqContract(adapter, r)

        // 无标题 → 首条用户消息；telegram 启动面成徽章；精简形状 tool_calls 无 id 按 tool_name 顺位回填；多模态 content 只取文本
        let r2 = ref(db, "hs-0002")
        let s2 = try adapter.parseSession(r2)
        let t2 = try adapter.parseTranscript(r2)
        XCTAssertEqual(s2.meta.title, "无标题会话的兜底标题应取这句")
        XCTAssertEqual(s2.meta.source, "telegram")
        XCTAssertNil(s2.meta.tokensUsed)
        XCTAssertEqual(s2.meta.updatedAt, CodingContract.ms("2026-08-08T08:00:08Z"), "无 ended_at 取末条消息")
        let a2 = t2.mainline[1]
        XCTAssertEqual(a2.toolCalls.count, 1)
        XCTAssertEqual(a2.toolCalls.first?.name, "terminal")
        XCTAssertEqual(a2.toolCalls.first?.id, "hermes-7-0", "没有 id 的给稳定合成 id")
        XCTAssertEqual(a2.toolCalls.first?.output, "README.md")
        XCTAssertEqual(a2.text, "好的。")
        try CodingContract.assertSeqContract(adapter, r2)
    }

    func testProfilesHomeOverrideAndResumeProfile() throws {
        let profileDB = hermesHome.appendingPathComponent("profiles/coder/state.db")
        try FileManager.default.createDirectory(at: profileDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        CodingContract.execSQL(profileDB, Self.fixtureSQL)
        try FileManager.default.createDirectory(at: hermesHome.appendingPathComponent("profiles/empty"), withIntermediateDirectories: true)

        let adapter = HermesAdapter.make(home: home, environment: [:])
        XCTAssertEqual(adapter.dataRoots, [db, profileDB], "主库 + 有库的档案，空档案目录不算")
        XCTAssertEqual(adapter.listSessionFiles().count, 6, "两个库各列三条")
        let profileMeta = try adapter.parseSession(ref(profileDB, "hs-0001")).meta
        XCTAssertEqual(CodingSessionResume.hermesProfile(profileMeta.filePath), "coder", "续跑带所属档案")
        XCTAssertEqual(CodingSessionResume.hermesProfile(ref(db, "hs-0001").filePath), "default")
        XCTAssertEqual(CodingSessionResume.invocation(for: profileMeta)?.1, ["--profile", "coder", "--resume", "hs-0001"])

        let custom = home.appendingPathComponent("custom-hermes")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        CodingContract.execSQL(custom.appendingPathComponent("state.db"), Self.fixtureSQL)
        XCTAssertEqual(HermesAdapter.make(home: home, environment: ["HERMES_HOME": custom.path]).dataRoots,
                       [custom.appendingPathComponent("state.db")], "HERMES_HOME 有 state.db 才采信")
        XCTAssertEqual(HermesAdapter.make(home: home, environment: ["HERMES_HOME": home.appendingPathComponent("nope").path]).dataRoots,
                       [db, profileDB], "没有 state.db 的 HERMES_HOME 回落 ~/.hermes")

        let missing = HermesAdapter.make(home: URL(fileURLWithPath: "/nonexistent-home"), environment: [:])
        XCTAssertEqual(missing.dataRoots.map(\.path), ["/nonexistent-home/.hermes/state.db"])
        XCTAssertTrue(missing.listSessionFiles().isEmpty, "缺库降级为空")
        XCTAssertEqual(missing.quickMeta([])?.isEmpty, true)
        XCTAssertTrue(CodingSessionRoster.adapters(home: home, environment: [:]).contains { $0.agent == .hermes && $0.dataRoots == [db, profileDB] })
    }

    /// 没被新版 Hermes 迁移过的库（schema v2：无 title、无 cache / reasoning 列、messages 无 reasoning）照常枚举与解析
    func testLegacySchemaStillParses() throws {
        let legacy = home.appendingPathComponent("legacy/state.db")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        CodingContract.execSQL(legacy, """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, parent_session_id TEXT,
                started_at REAL NOT NULL, ended_at REAL, message_count INTEGER DEFAULT 0,
                input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0
            );
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL,
                content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT,
                timestamp REAL NOT NULL, finish_reason TEXT
            );
            INSERT INTO sessions VALUES ('old-1', 'cli', 'gpt-5.4', NULL, 1786172400.0, NULL, 2, 10, 5);
            INSERT INTO messages (session_id, role, content, timestamp) VALUES
                ('old-1', 'user', '老库里的会话', 1786172401.0),
                ('old-1', 'assistant', '仍要能解析', 1786172402.0);
            """)
        let adapter = HermesAdapter(dbs: [legacy])
        let refs = adapter.listSessionFiles()
        XCTAssertEqual(refs.count, 1)
        let s = try adapter.parseSession(try XCTUnwrap(refs.first))
        XCTAssertEqual(s.meta.title, "老库里的会话")
        XCTAssertEqual(s.meta.tokensUsed, 15)
        XCTAssertEqual(s.meta.messageCount, 2)
    }
}
#endif
