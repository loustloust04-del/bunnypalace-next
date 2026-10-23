#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-c OpenCode：照抄 Wake `opencode_parse_contract` / `opencode_v2_parse_contract` / `opencode_next_real_schema_contract`
/// （现建库，同 `tests/common::build_opencode_db` / `build_opencode_next_db`）+ seq 契约 + 根解析 / 子代理与空会话过滤 / 归档。
/// `opencode_default_databases_can_be_removed_individually` 属位置 sheet（N3-e）。全在 tmp
final class OpenCodeAdapterContractTests: XCTestCase {
    private var home: URL!
    private var dir: URL { home.appendingPathComponent(".local/share/opencode") }
    private var stableDB: URL { dir.appendingPathComponent("opencode.db") }
    private var nextDB: URL { dir.appendingPathComponent("opencode-next.db") }

    static let stableSQL = """
        CREATE TABLE session (
            id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
            time_created INTEGER, time_updated INTEGER, model TEXT,
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            time_archived INTEGER, version TEXT
        );
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT, time_created INTEGER);
        CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, data TEXT);
        INSERT INTO session VALUES
            ('oc-0001', NULL, '/Users/tester/Github/wakefx', 'OpenCode 二维码排查',
             1786000000000, 1786000600000, '{"providerID":"anthropic","id":"claude-sonnet-4-5"}',
             100, 50, 25, NULL, '1.14.50');
        INSERT INTO message VALUES
            ('msg-a','oc-0001','{"id":"msg-a","role":"user","time":{"created":1786000050000}}',1786000050000),
            ('msg-b','oc-0001','{"id":"msg-b","role":"user","time":{"created":1786000100000}}',1786000100000),
            ('msg-c','oc-0001','{"id":"msg-c","role":"assistant","time":{"created":1786000200000}}',1786000200000);
        INSERT INTO part VALUES
            ('prt-a-01','oc-0001','msg-a','{"type":"text","text":"editor context: QrScanner.tsx is open","synthetic":true}'),
            ('prt-b-01','oc-0001','msg-b','{"type":"text","text":"OpenCode 查一下二维码组件的 useEffect() 泄漏"}'),
            ('prt-c-01','oc-0001','msg-c','{"type":"step-start"}'),
            ('prt-c-02','oc-0001','msg-c','{"type":"reasoning","text":"先查 effect 依赖和清理函数"}'),
            ('prt-c-03','oc-0001','msg-c','{"type":"tool","callID":"oc_call_1","tool":"grep","state":{"status":"completed","input":{"pattern":"useEffect"},"output":"src/QrScanner.tsx: useEffect(() => watch())"}}'),
            ('prt-c-04','oc-0001','msg-c','{"type":"text","text":"找到泄漏点,已在清理回调里停止扫描。"}'),
            ('prt-c-05','oc-0001','msg-c','{"type":"wibble-part"}');
        CREATE TABLE session_v2 (
            id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
            time_created INTEGER, time_updated INTEGER, model TEXT,
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            time_archived INTEGER, version TEXT
        );
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
            time_created INTEGER, time_updated INTEGER, data TEXT
        );
        INSERT INTO session_v2 VALUES
            ('ocv2-0001', NULL, '/Users/tester/Github/wakefx', 'OpenCode v2 greeting',
             1786100000000, 1786100300000, '{"id":"nemotron-3.5-lightning-free","providerID":"opencode"}',
             10, 5, 2, NULL, '0.0.0-beta-17639');
        INSERT INTO session_message VALUES
            ('m2-0','ocv2-0001','user',0,1786100000000,1786100000000,
             '{"text":"OpenCode v2 看看二维码组件","time":{"created":1786100000000},"files":[],"agents":[]}'),
            ('m2-1','ocv2-0001','synthetic',1,1786100001000,1786100001000,
             '{"text":"<system-reminder>Note: the user opened QrScanner.tsx</system-reminder>","time":{"created":1786100001000}}'),
            ('m2-2','ocv2-0001','assistant',2,1786100002000,1786100002000,
             '{"agent":"build","model":{"id":"nemotron-3.5-lightning-free","providerID":"opencode","variant":"default"},"time":{"created":1786100002000},"content":[{"type":"reasoning","text":"用户要看扫描组件"},{"type":"text","text":"看完了,组件没有泄漏。"},{"type":"wibble-block"}]}'),
            ('m2-3','ocv2-0001','wibble-row',3,1786100003000,1786100003000,'{}');
        """

    static let nextSQL = """
        CREATE TABLE session (
            id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
            time_created INTEGER, time_updated INTEGER, model TEXT,
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            time_archived INTEGER, version TEXT
        );
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT, time_created INTEGER);
        CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, data TEXT);
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
            time_created INTEGER, time_updated INTEGER, data TEXT
        );
        INSERT INTO session VALUES
            ('ocnext-0001', NULL, '/Users/tester/Github/wakefx', 'OpenCode next real schema',
             1786200000000, 1786200300000,
             '{"id":"gpt-5.6","providerID":"openai","variant":"default"}',
             20, 8, 4, NULL, '0.0.0-next-202606270058');
        INSERT INTO session_message VALUES
            ('next-m0','ocnext-0001','user',0,1786200000000,1786200000000,
             '{"text":"OpenCode next 检查二维码组件","time":{"created":1786200000000},"files":[],"agents":[]}'),
            ('next-m1','ocnext-0001','synthetic',1,1786200001000,1786200001000,
             '{"sessionID":"ocnext-0001","text":"editor context: QrScanner.tsx","time":{"created":1786200001000}}'),
            ('next-m2','ocnext-0001','assistant',2,1786200002000,1786200002000,
             '{"agent":"build","model":{"id":"gpt-5.6","providerID":"openai","variant":"default"},"time":{"created":1786200002000},"content":[{"type":"reasoning","id":"rsn-1","text":"检查 effect 清理"},{"type":"tool","id":"tool-1","name":"grep","state":{"status":"completed","input":{"pattern":"useEffect"},"structured":{},"content":[{"type":"text","text":"src/QrScanner.tsx:42"}],"result":{"matches":1}},"time":{"created":1786200002100,"completed":1786200002200}},{"type":"text","id":"txt-1","text":"next schema 解析成功。"}]}'),
            ('next-m3','ocnext-0001','system',3,1786200003000,1786200003000,
             '{"text":"system notice","time":{"created":1786200003000}}'),
            ('next-m4','ocnext-0001','shell',4,1786200004000,1786200004000,
             '{"callID":"shell-1","command":"cargo test","output":"ok","time":{"created":1786200004000,"completed":1786200004100}}'),
            ('next-m5','ocnext-0001','compaction',5,1786200005000,1786200005000,
             '{"reason":"auto","summary":"保留二维码排查上下文","recent":"","time":{"created":1786200005000}}'),
            ('next-m6','ocnext-0001','agent-switched',6,1786200006000,1786200006000,
             '{"agent":"build","time":{"created":1786200006000}}'),
            ('next-m7','ocnext-0001','wibble-next',7,1786200007000,1786200007000,'{}');
        """

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CodingContract.execSQL(stableDB, Self.stableSQL)
        CodingContract.execSQL(nextDB, Self.nextSQL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var adapter: OpenCodeAdapter { OpenCodeAdapter.make(home: home, environment: [:]) }

    private func ref(_ db: URL, _ id: String) -> CodingSessionFileRef {
        CodingSessionFileRef(agent: .opencode, nativeId: id, filePath: CodingVirtualPath.make(db: db.path, id: id), mtimeMs: 1, size: 1)
    }

    func testOpenCodeParseContract() throws {
        let adapter = adapter
        let r = ref(stableDB, "oc-0001")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)

        XCTAssertEqual(s.meta.title, "OpenCode 二维码排查", "session 表自带标题")
        XCTAssertEqual(s.meta.projectName, "wakefx")
        XCTAssertEqual(s.meta.model, "claude-sonnet-4-5", "model json 的 id")
        XCTAssertEqual(s.meta.tokensUsed, 175, "input + output + reasoning")
        XCTAssertFalse(s.meta.archived, "time_archived NULL")
        XCTAssertEqual(s.meta.createdAt, 1_786_000_000_000)
        XCTAssertEqual(s.meta.updatedAt, 1_786_000_600_000)
        XCTAssertEqual(s.meta.messageCount, 2)
        XCTAssertEqual(s.unknownLines, 1, "wibble-part")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/meta", "user/text", "assistant/text"], "只有 synthetic part 的归 Meta")
        let a = t.mainline[2]
        XCTAssertTrue(a.thinking?.contains("先查 effect 依赖") ?? false)
        XCTAssertEqual(a.toolCalls.count, 1)
        XCTAssertEqual(a.toolCalls.first?.name, "grep")
        XCTAssertTrue(a.toolCalls.first?.output?.contains("QrScanner") ?? false)
        XCTAssertEqual(a.toolCalls.first?.isError, false)
        XCTAssertEqual(s.units.map(\.seq), [1, 2])
        try CodingContract.assertSeqContract(adapter, r)
    }

    func testV2ParseContract() throws {
        let adapter = adapter
        let ids = Set(adapter.listSessionFiles().map(\.nativeId))
        XCTAssertTrue(ids.contains("ocv2-0001"), "v2 会话在列表")
        XCTAssertTrue(ids.contains("oc-0001"), "只存在于 v1 表的会话被 UNION 回捞")

        let r = ref(stableDB, "ocv2-0001")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)
        XCTAssertEqual(s.meta.title, "OpenCode v2 greeting")
        XCTAssertEqual(s.meta.model, "nemotron-3.5-lightning-free")
        XCTAssertEqual(s.meta.source, "opencode2", "beta 版本号 → 徽章 / 续跑换二进制")
        XCTAssertEqual(s.meta.tokensUsed, 17)
        XCTAssertEqual(s.meta.createdAt, 1_786_100_000_000)
        XCTAssertEqual(s.unknownLines, 2, "wibble-row（未知消息 type）+ wibble-block（未知内容块）各一次")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "user/meta", "assistant/text"])
        XCTAssertEqual(t.mainline[0].text, "OpenCode v2 看看二维码组件")
        let a = t.mainline[2]
        XCTAssertEqual(a.text, "看完了,组件没有泄漏。")
        XCTAssertTrue(a.thinking?.contains("扫描组件") ?? false)
        XCTAssertEqual(a.model, "nemotron-3.5-lightning-free")
        XCTAssertEqual(s.units.map(\.seq), [0, 2])
        try CodingContract.assertSeqContract(adapter, r)

        XCTAssertNil(try adapter.parseSession(ref(stableDB, "oc-0001")).meta.source, "只存在于 v1 表的会话不带 v2 标记（续跑走 v1 二进制）")
    }

    func testNextRealSchemaContract() throws {
        let adapter = adapter
        XCTAssertTrue(adapter.dataRoots.contains(stableDB), "stable 库路径保留")
        XCTAssertTrue(adapter.dataRoots.contains(nextDB), "next 库路径一起扫")

        let refs = adapter.listSessionFiles()
        let r = try XCTUnwrap(refs.first { $0.nativeId == "ocnext-0001" }, "真实 session + session_message 会话被列出")
        XCTAssertTrue(r.filePath.hasPrefix(nextDB.path))
        XCTAssertEqual(adapter.quickMeta(refs)?[r.filePath]?.source, "opencode2", "列表快路径也带 preview 标记")

        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)
        XCTAssertEqual(s.meta.title, "OpenCode next real schema")
        XCTAssertEqual(s.meta.model, "gpt-5.6")
        XCTAssertEqual(s.meta.tokensUsed, 32)
        XCTAssertEqual(s.meta.source, "opencode2")
        XCTAssertEqual(s.meta.messageCount, 3, "user + assistant + 只有 shell 工具的消息")
        XCTAssertEqual(s.unknownLines, 1, "只有 wibble-next；状态切换是已知元数据")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline),
                       ["user/text", "user/meta", "assistant/text", "system/meta", "assistant/text", "system/compact-summary"])
        let assistant = t.mainline[2]
        XCTAssertEqual(assistant.text, "next schema 解析成功。")
        XCTAssertTrue(assistant.thinking?.contains("effect 清理") ?? false)
        XCTAssertEqual(assistant.toolCalls.count, 1)
        XCTAssertEqual(assistant.toolCalls.first?.id, "tool-1")
        XCTAssertEqual(assistant.toolCalls.first?.name, "grep")
        XCTAssertEqual(assistant.toolCalls.first?.output, "src/QrScanner.tsx:42")
        XCTAssertEqual(t.mainline[4].toolCalls.first?.name, "shell")
        XCTAssertEqual(t.mainline[5].kind, .compactSummary)
        XCTAssertEqual(s.units.map(\.seq), [0, 2, 4])
        try CodingContract.assertSeqContract(adapter, r)
    }

    func testChildEmptyAndArchivedSessions() throws {
        CodingContract.execSQL(stableDB, """
            INSERT INTO session VALUES
                ('oc-child','oc-0001','/p','子代理',1,2,NULL,0,0,0,NULL,'1.14.50'),
                ('oc-empty',NULL,'/p','空会话',1,2,NULL,0,0,0,NULL,'1.14.50');
            INSERT INTO part VALUES ('prt-x','oc-child','msg-x','{"type":"text","text":"child"}');
            UPDATE session SET time_archived = 5 WHERE id = 'oc-0001';
            """)
        let adapter = adapter
        let ids = Set(adapter.listSessionFiles().map(\.nativeId))
        XCTAssertFalse(ids.contains("oc-child"), "parent_id 非空 = 子代理，不进列表")
        XCTAssertFalse(ids.contains("oc-empty"), "正文长度 0 不列")
        XCTAssertTrue(try adapter.parseSession(ref(stableDB, "oc-0001")).meta.archived)
        XCTAssertThrowsError(try adapter.parseSession(ref(URL(fileURLWithPath: "/elsewhere/opencode.db"), "oc-0001")), "库不在数据根里")
        XCTAssertThrowsError(try adapter.parseSession(ref(stableDB, "no-such")))
    }

    func testRootResolution() throws {
        let defaults = OpenCodeAdapter.make(home: URL(fileURLWithPath: "/nonexistent-home"), environment: [:])
        XCTAssertEqual(defaults.dataRoots.map(\.path), ["/nonexistent-home/.local/share/opencode/opencode.db",
                                                        "/nonexistent-home/.local/share/opencode/opencode-next.db"], "两个固定候选常驻")
        XCTAssertTrue(defaults.listSessionFiles().isEmpty, "缺库降级为空")
        XCTAssertNil(defaults.quickMeta([]))

        let emptyXDG = home.appendingPathComponent("empty-xdg")
        XCTAssertEqual(OpenCodeAdapter.make(home: home, environment: ["XDG_DATA_HOME": emptyXDG.path]).dataRoots.map(\.path),
                       [stableDB.path, nextDB.path], "XDG 目录里没有库不采信")

        let xdg = home.appendingPathComponent("xdg")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("opencode"), withIntermediateDirectories: true)
        CodingContract.execSQL(xdg.appendingPathComponent("opencode/opencode.db"), "CREATE TABLE session (id TEXT);")
        XCTAssertEqual(OpenCodeAdapter.make(home: home, environment: ["XDG_DATA_HOME": xdg.path]).dataRoots.map(\.path),
                       [xdg.appendingPathComponent("opencode/opencode.db").path, xdg.appendingPathComponent("opencode/opencode-next.db").path,
                        stableDB.path, nextDB.path], "XDG 采信后默认目录里已有的库仍是候选")

        CodingContract.execSQL(dir.appendingPathComponent("custom.db"), "CREATE TABLE session (id TEXT);")
        XCTAssertEqual(OpenCodeAdapter.make(home: home, environment: ["OPENCODE_DB": "custom.db"]).dataRoots.map(\.path),
                       [dir.appendingPathComponent("custom.db").path, stableDB.path, nextDB.path], "OPENCODE_DB 相对当前数据目录，额外候选不压标准位置")
        XCTAssertEqual(OpenCodeAdapter.make(home: home, environment: ["OPENCODE_DB": ":memory:"]).dataRoots.count, 2)
        XCTAssertEqual(OpenCodeAdapter.make(home: home, environment: ["OPENCODE_DB": "/nonexistent.db"]).dataRoots.count, 2)
        XCTAssertTrue(CodingSessionRoster.adapters(home: home, environment: [:]).contains { $0.agent == .opencode && $0.dataRoots == [stableDB, nextDB] })
    }
}
#endif
