#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-d OpenClaw：照抄 Wake `openclaw_parse_contract`（现建库同 `tests/common::build_openclaw_db`，旧版 jsonl 用检入夹具，两代放同一个
/// agent 目录）+ seq 契约 + 缺表回溯 / topic 转录 / 状态目录判序 / 缺根降级。自定义位置整形随 N3-e。全在 tmp
final class OpenClawAdapterContractTests: XCTestCase {
    private var home: URL!
    private var agentDir: URL { home.appendingPathComponent(".openclaw/agents/main") }
    private var db: URL { agentDir.appendingPathComponent("agent/openclaw-agent.sqlite") }
    private var sessions: URL { agentDir.appendingPathComponent("sessions") }
    private static let legacyId = "cccccccc-aaaa-bbbb-cccc-000000000017"

    static let fixtureSQL = #"""
        CREATE TABLE session_nodes (
            session_key TEXT NOT NULL PRIMARY KEY, current_session_id TEXT NOT NULL,
            entry_json TEXT NOT NULL, updated_at INTEGER NOT NULL, label TEXT,
            display_name TEXT, spawned_by TEXT, parent_session_key TEXT, archived_at INTEGER
        );
        CREATE TABLE session_windows (
            session_id TEXT NOT NULL PRIMARY KEY, session_key TEXT NOT NULL,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            transcript_updated_at INTEGER, started_at INTEGER, model TEXT,
            model_provider TEXT, channel TEXT, chat_type TEXT, spawned_by TEXT,
            parent_session_key TEXT, display_name TEXT
        );
        CREATE TABLE transcript_events (
            session_id TEXT NOT NULL, seq INTEGER NOT NULL, event_json TEXT NOT NULL,
            created_at INTEGER NOT NULL, PRIMARY KEY (session_id, seq)
        );
        CREATE TABLE session_transcript_active_events (
            session_id TEXT NOT NULL, active_position INTEGER NOT NULL,
            event_seq INTEGER NOT NULL, message_position INTEGER,
            PRIMARY KEY (session_id, active_position)
        );
        INSERT INTO session_nodes VALUES
            ('agent:main:main', 'claw-0001',
             '{"sessionId":"claw-0001","updatedAt":1786266030000,"model":"claude-opus-5","totalTokens":7300,"label":"Node label"}',
             1786266030000, 'Node label', NULL, NULL, NULL, NULL),
            ('agent:main:subagent:sub1', 'claw-0002',
             '{"sessionId":"claw-0002","updatedAt":1786266100000,"spawnedBy":"agent:main:main"}',
             1786266100000, NULL, NULL, 'agent:main:main', 'agent:main:main', NULL);
        INSERT INTO session_windows VALUES
            ('claw-0001', 'agent:main:main', 1786266000000, 1786266030000, 1786266030000, 1786266000000,
             'claude-opus-5', 'anthropic', 'telegram', 'direct', NULL, NULL, NULL),
            ('claw-0002', 'agent:main:subagent:sub1', 1786266100000, 1786266100000, 1786266100000, 1786266100000,
             'claude-opus-5', 'anthropic', NULL, NULL, 'agent:main:main', 'agent:main:main', NULL),
            ('claw-0003', 'agent:main:main', 1786176000000, 1786176030000, 1786176030000, 1786176000000,
             'gpt-5.5', 'openai', 'cli', 'direct', NULL, NULL, NULL);
        INSERT INTO transcript_events VALUES
            ('claw-0001', 0, '{"type":"session","version":3,"id":"claw-0001","timestamp":"2026-08-08T09:00:00.000Z","cwd":"/Users/tester/Github/wakefx"}', 1786266000000),
            ('claw-0001', 1, '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-08-08T09:00:05.000Z","message":{"role":"user","content":"OpenClaw 库里的会话:查二维码组件 useEffect() 清理","timestamp":1786266005000}}', 1786266005000),
            ('claw-0001', 2, '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-08-08T09:00:08.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_db_1","name":"exec","arguments":{"command":"rg useEffect src/"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-opus-5","usage":{"input":100,"output":20,"cacheRead":0,"cacheWrite":0,"totalTokens":7100},"timestamp":1786266008000}}', 1786266008000),
            ('claw-0001', 3, '{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-08-08T09:00:09.000Z","message":{"role":"toolResult","toolCallId":"call_db_1","toolName":"exec","content":[{"type":"text","text":"src/QrScanner.tsx: useEffect(() => watch())"}],"isError":true,"timestamp":1786266009000}}', 1786266009000),
            ('claw-0001', 4, '{"type":"message","id":"a2-dead","parentId":"r1","timestamp":"2026-08-08T09:00:11.000Z","message":{"role":"assistant","content":[{"type":"text","text":"死分支,不该出现"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-opus-5","timestamp":1786266011000}}', 1786266011000),
            ('claw-0001', 5, '{"type":"message","id":"a2","parentId":"r1","timestamp":"2026-08-08T09:00:12.000Z","message":{"role":"assistant","content":[{"type":"text","text":"找到泄漏点,已补清理回调。"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-opus-5","usage":{"input":200,"output":30,"cacheRead":0,"cacheWrite":0,"totalTokens":7300},"timestamp":1786266012000}}', 1786266012000),
            ('claw-0001', 6, '{"type":"message","id":"u2","parentId":"a2","timestamp":"2026-08-08T09:00:30.000Z","message":{"role":"user","content":"谢谢,合并了","timestamp":1786266030000}}', 1786266030000),
            ('claw-0002', 0, '{"type":"session","version":3,"id":"claw-0002","timestamp":"2026-08-08T09:01:40.000Z","cwd":"/Users/tester/Github/wakefx"}', 1786266100000),
            ('claw-0002', 1, '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-08-08T09:01:41.000Z","message":{"role":"user","content":"child task","timestamp":1786266101000}}', 1786266101000),
            ('claw-0003', 0, '{"type":"session","version":3,"id":"claw-0003","timestamp":"2026-08-07T08:00:00.000Z","cwd":"/Users/tester/Github/wakefx"}', 1786176000000),
            ('claw-0003', 1, '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-08-07T08:00:05.000Z","message":{"role":"user","content":"reset 之前的老窗口","timestamp":1786176005000}}', 1786176005000),
            ('claw-0003', 2, '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-08-07T08:00:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"收到。"}],"api":"openai-responses","provider":"openai","model":"gpt-5.5","timestamp":1786176030000}}', 1786176030000);
        INSERT INTO session_transcript_active_events VALUES
            ('claw-0001', 0, 1, 0), ('claw-0001', 1, 2, 1), ('claw-0001', 2, 3, 2),
            ('claw-0001', 3, 5, 3), ('claw-0001', 4, 6, 4);
        """#

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-openclaw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures.appendingPathComponent("openclaw/agents/main/sessions"), to: sessions)
        CodingContract.execSQL(db, Self.fixtureSQL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var adapter: OpenClawAdapter { OpenClawAdapter.make(home: home, environment: [:]) }

    private func dbRef(_ id: String) -> CodingSessionFileRef {
        CodingSessionFileRef(agent: .openclaw, nativeId: id, filePath: CodingVirtualPath.make(db: db.path, id: id), mtimeMs: 1, size: 1)
    }

    func testOpenClawParseContract() throws {
        let adapter = adapter
        XCTAssertEqual(adapter.listSessionFiles().map(\.nativeId).sorted(), [Self.legacyId, "claw-0001", "claw-0003"],
                       "库里的活跃窗口 + reset 前旧窗口 + 旧版 jsonl；子代理与 checkpoint 快照不列")

        // 现版 SQLite：active_events 给出可见分支，死分支 a2-dead 不出现
        let r = dbRef("claw-0001")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)
        XCTAssertEqual(s.meta.key, "openclaw:claw-0001")
        XCTAssertEqual(s.meta.title, "Node label", "没有 session_info 时取 node label")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx", "header cwd")
        XCTAssertEqual(s.meta.model, "claude-opus-5")
        XCTAssertEqual(s.meta.tokensUsed, 7300)
        XCTAssertEqual(s.meta.source, "telegram")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-08T09:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-08T09:00:30Z"))
        XCTAssertEqual(s.meta.messageCount, 3)
        XCTAssertEqual(s.unknownLines, 0)
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text", "user/text"])
        let a = t.mainline[1]
        XCTAssertEqual(a.text, "找到泄漏点,已补清理回调。")
        XCTAssertEqual(a.toolCalls.count, 1)
        XCTAssertEqual(a.toolCalls.first?.name, "exec")
        XCTAssertEqual(a.toolCalls.first?.isError, true)
        XCTAssertTrue(a.toolCalls.first?.output?.contains("QrScanner") ?? false)
        XCTAssertEqual(s.units.map(\.seq), [0, 1, 2])
        try CodingContract.assertSeqContract(adapter, r)

        // 旧窗口：没有 active_events 退回树回溯；node 的 totalTokens 不归它
        let s3 = try adapter.parseSession(dbRef("claw-0003"))
        XCTAssertEqual(s3.meta.title, "Node label")
        XCTAssertEqual(s3.meta.model, "gpt-5.5")
        XCTAssertNil(s3.meta.tokensUsed)
        XCTAssertNil(s3.meta.source, "cli 不打徽章")
        XCTAssertEqual(s3.meta.messageCount, 2)

        // 旧版 jsonl：fileRef 只认 agents/<id>/sessions/ 下的活转录
        let path = sessions.appendingPathComponent("\(Self.legacyId).jsonl")
        let legacy = try XCTUnwrap(adapter.fileRef(path))
        XCTAssertEqual(legacy.nativeId, Self.legacyId)
        XCTAssertNil(adapter.fileRef(sessions.appendingPathComponent("\(Self.legacyId).checkpoint.1.jsonl")))
        XCTAssertNil(adapter.fileRef(sessions.appendingPathComponent("sessions.json")))

        let ls = try adapter.parseSession(legacy)
        let lt = try adapter.parseTranscript(legacy)
        XCTAssertEqual(ls.meta.title, "OpenClaw QR cleanup", "session_info 压过 sessions.json 的 label")
        XCTAssertEqual(ls.meta.projectPath, "/Users/tester/Github/wakefx")
        XCTAssertEqual(ls.meta.model, "claude-opus-5")
        XCTAssertEqual(ls.meta.tokensUsed, 5200)
        XCTAssertEqual(ls.meta.createdAt, CodingContract.ms("2026-08-07T09:00:00Z"))
        XCTAssertEqual(ls.meta.updatedAt, CodingContract.ms("2026-08-07T09:00:30Z"))
        XCTAssertEqual(ls.unknownLines, 1, "wibble-entry 是叶：回溯经 u3→c1→a2→r1→a1→u2→u1→i1→m1，未知类型计 1")
        XCTAssertEqual(CodingContract.rolesKinds(lt.mainline),
                       ["user/meta", "user/text", "assistant/text", "system/compact-summary", "user/text"], "runtimeContextCarrier 归 Meta")
        XCTAssertEqual(ls.meta.messageCount, 3)
        let la = lt.mainline[2]
        XCTAssertEqual(la.text, "找到泄漏点,已补清理回调。")
        XCTAssertEqual(la.thinking, "先搜一下 useEffect")
        XCTAssertEqual(la.toolCalls.count, 1)
        XCTAssertEqual(la.toolCalls.first?.isError, false)
        XCTAssertTrue(lt.mainline[3].text.contains("useEffect 泄漏"))
        XCTAssertFalse(lt.mainline.contains { $0.text.contains("旧分支") }, "回滚掉的旧分支不出现")
        try CodingContract.assertSeqContract(adapter, legacy)

        XCTAssertNil(CodingSessionResume.invocation(for: ls.meta), "OpenClaw 没有续跑形制")
    }

    func testMissingActiveTableTopicTranscriptsAndRoots() throws {
        CodingContract.execSQL(db, "DROP TABLE session_transcript_active_events;")
        let noActive = try adapter.parseTranscript(dbRef("claw-0001"))
        XCTAssertEqual(CodingContract.rolesKinds(noActive.mainline), ["user/text", "assistant/text", "user/text"],
                       "缺表退回「最后一条为叶」回溯，死分支照样不在链上")
        XCTAssertFalse(noActive.mainline.contains { $0.text.contains("死分支") })

        let topic = "\(Self.legacyId)-topic-5"
        try #"{"type":"session","version":3,"id":"t","timestamp":"2026-08-07T11:00:00.000Z","cwd":"/p"}"# .appending("\n")
            .appending(#"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-08-07T11:00:05.000Z","message":{"role":"user","content":"topic 里的一问"}}"#)
            .write(to: sessions.appendingPathComponent("\(topic).jsonl"), atomically: true, encoding: .utf8)
        try #"{"type":"session","version":3,"id":"d","timestamp":"2026-08-07T11:00:00.000Z","cwd":"/p"}"#
            .write(to: sessions.appendingPathComponent("dddddddd-aaaa-bbbb-cccc-000000000018-topic-1.jsonl"), atomically: true, encoding: .utf8)
        let adapter = adapter
        let ids = Set(adapter.listSessionFiles().map(\.nativeId))
        XCTAssertTrue(ids.contains(topic), "topic 转录跟父会话走")
        XCTAssertFalse(ids.contains("dddddddd-aaaa-bbbb-cccc-000000000018-topic-1"), "子代理的 topic 转录也不列")
        let topicMeta = try adapter.parseSession(try XCTUnwrap(adapter.fileRef(sessions.appendingPathComponent("\(topic).jsonl")))).meta
        XCTAssertEqual(topicMeta.title, "legacy label loses to session_info", "没有 session_info 时回退父会话索引项的 label")
        XCTAssertEqual(topicMeta.tokensUsed, 5200)

        XCTAssertEqual(OpenClawAdapter.make(home: home, environment: [:]).root.path, home.appendingPathComponent(".openclaw/agents").path)
        XCTAssertEqual(OpenClawAdapter.make(home: home, environment: ["OPENCLAW_STATE_DIR": home.appendingPathComponent(".openclaw").path]).root.path,
                       home.appendingPathComponent(".openclaw/agents").path, "有 agents/ 的状态目录采信")
        XCTAssertEqual(OpenClawAdapter.make(home: home, environment: ["OPENCLAW_STATE_DIR": "/nonexistent-state"]).root.path,
                       home.appendingPathComponent(".openclaw/agents").path, "没有 agents/ 的候选不采信")
        let oldHome = home.appendingPathComponent("old-home")
        try FileManager.default.createDirectory(at: oldHome.appendingPathComponent(".clawdbot"), withIntermediateDirectories: true)
        XCTAssertEqual(OpenClawAdapter.make(home: oldHome, environment: [:]).root.path, oldHome.appendingPathComponent(".clawdbot/agents").path,
                       "只装过老版本（没有 .openclaw、有 .clawdbot）回落旧名")
        let missing = OpenClawAdapter.make(home: URL(fileURLWithPath: "/nonexistent-home"), environment: [:])
        XCTAssertTrue(missing.listSessionFiles().isEmpty, "缺根降级为空")
        XCTAssertTrue(CodingSessionRoster.adapters(home: home, environment: [:])
            .contains { $0.agent == .openclaw && $0.dataRoots.map(\.path) == [home.appendingPathComponent(".openclaw/agents").path] })
    }
}
#endif
