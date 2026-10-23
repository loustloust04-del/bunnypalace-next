#if os(macOS)
import XCTest
import SQLite3
@testable import 记忆花园

// Portions adapted from Wake v0.6.3 (MIT, Copyright (c) 2026 Corey Chiu, github.com/iAmCorey/Wake) — see THIRD_PARTY_LICENSES.md
/// W-N N0 adapter 契约：fixture 与断言照 Wake v0.6.3 `tests/adapter_contracts.rs`（MIT）。
/// fixture 全是合成数据（`fixtures/coding-sessions`，测试包资源）；根路径全部注入，不碰真目录。
final class CodingSessionAdapterTests: XCTestCase {

    static var fixtures: URL {
        Bundle(for: CodingSessionAdapterTests.self).url(forResource: "coding-sessions", withExtension: nil)!
    }

    private static let project = "/Users/tester/Github/wakefx"

    private func ms(_ rfc3339: String) -> Int64 { CodingParse.isoMs(rfc3339) }

    private func ref(_ agent: CodingAgent, _ relative: String, _ nativeId: String) throws -> CodingSessionFileRef {
        let url = Self.fixtures.appendingPathComponent(relative)
        var r = try XCTUnwrap(CodingParse.defaultFileRef(agent, url), "fixture missing \(relative)")
        r.nativeId = nativeId
        return r
    }

    private func rolesKinds(_ messages: [CodingMessage]) -> [String] {
        messages.map { "\($0.role.rawValue)/\($0.kind.rawValue)" }
    }

    // MARK: - Claude Code

    func testClaudeParseContract() throws {
        let adapter = ClaudeCodeAdapter(root: Self.fixtures.appendingPathComponent("claude/projects"))
        let r = try ref(.claudeCode, "claude/projects/-Users-tester-Github-wakefx/11111111-aaaa-bbbb-cccc-000000000001.jsonl",
                        "11111111-aaaa-bbbb-cccc-000000000001")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)

        XCTAssertEqual(s.meta.title, "QR login revamp")
        XCTAssertEqual(s.meta.projectPath, Self.project)
        XCTAssertEqual(s.meta.projectName, "wakefx")
        XCTAssertEqual(s.meta.gitBranch, "main")
        XCTAssertEqual(s.meta.model, "claude-opus-4-1")
        XCTAssertEqual(s.meta.tokensUsed, 160)
        XCTAssertEqual(s.meta.messageCount, 3)
        XCTAssertEqual(s.meta.createdAt, ms("2026-08-01T09:59:00Z"))
        XCTAssertEqual(s.meta.updatedAt, ms("2026-08-01T10:02:00Z"))
        XCTAssertEqual(s.unknownLines, 1)

        XCTAssertEqual(rolesKinds(t.mainline), ["user/meta", "user/text", "assistant/text", "assistant/text", "system/compact-summary"])
        XCTAssertEqual(t.mainline[1].timestamp, ms("2026-08-01T10:00:00Z"))
        let a = t.mainline[2]
        XCTAssertEqual(a.text, "好的,我先查看现有代码。")
        XCTAssertTrue(a.thinking?.contains("二维码") == true)
        XCTAssertEqual(a.toolCalls.count, 1)
        XCTAssertEqual(a.toolCalls.first?.name, "Read")
        XCTAssertTrue(a.toolCalls.first?.output?.contains("useEffect") == true)
        XCTAssertFalse(a.toolCalls.first?.isError ?? true)

        XCTAssertEqual(s.units.map(\.seq), [1, 2, 3])
        XCTAssertTrue(s.units[1].text.contains("Login.tsx"))

        let untitled = try ref(.claudeCode, "claude/projects/-Users-tester-Github-wakefx/aaaaaaaa-0000-4000-8000-00000000000a.jsonl",
                               "aaaaaaaa-0000-4000-8000-00000000000a")
        let s2 = try adapter.parseSession(untitled)
        XCTAssertEqual(s2.meta.title, CodingLimits.untitled)
        XCTAssertEqual(s2.meta.messageCount, 1)
    }

    func testClaudeFileRefSkipsSubagentsAndMemory() {
        let adapter = ClaudeCodeAdapter(root: Self.fixtures)
        XCTAssertNil(adapter.fileRef(URL(fileURLWithPath: "/x/p/uuid/subagents/a.jsonl")))
        XCTAssertNil(adapter.fileRef(URL(fileURLWithPath: "/x/p/memory/a.jsonl")))
    }

    // MARK: - Codex

    private func codexAdapter(stateDB: URL? = nil) -> CodexAdapter {
        CodexAdapter(sessionsDir: Self.fixtures.appendingPathComponent("codex/sessions"),
                     archivedDir: Self.fixtures.appendingPathComponent("codex/archived_sessions"),
                     stateDB: stateDB ?? URL(fileURLWithPath: "/nonexistent/state_5.sqlite"))
    }

    private static let codexRollout = "codex/sessions/2026/08/02/rollout-2026-08-02T09-15-00-22222222-aaaa-bbbb-cccc-000000000002.jsonl"

    func testCodexParseContract() throws {
        let adapter = codexAdapter()
        let r = try XCTUnwrap(adapter.fileRef(Self.fixtures.appendingPathComponent(Self.codexRollout)))
        XCTAssertEqual(r.nativeId, "22222222-aaaa-bbbb-cccc-000000000002")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)

        XCTAssertEqual(s.meta.title, "扫码登录报错,帮我查一下 useEffect() 依赖数组")
        XCTAssertEqual(s.meta.key, "codex:22222222-aaaa-bbbb-cccc-000000000002")
        XCTAssertEqual(s.meta.projectPath, Self.project)
        XCTAssertEqual(s.meta.source, "CLI")
        XCTAssertEqual(s.meta.model, "gpt-5.2-codex")
        XCTAssertEqual(s.meta.gitBranch, "feat/qr")
        XCTAssertEqual(s.meta.tokensUsed, 4321)
        XCTAssertEqual(s.meta.messageCount, 3)
        XCTAssertFalse(s.meta.archived)
        XCTAssertEqual(s.meta.createdAt, ms("2026-08-02T09:15:00Z"))
        XCTAssertEqual(s.meta.updatedAt, ms("2026-08-02T09:15:21Z"))
        XCTAssertEqual(s.unknownLines, 1)

        XCTAssertEqual(rolesKinds(t.mainline), ["user/meta", "user/text", "assistant/text", "assistant/text", "system/compact-summary"])
        let host = t.mainline[2]
        let thinking = try XCTUnwrap(host.thinking)
        XCTAssertTrue(thinking.contains("先全局搜 useEffect"))
        XCTAssertFalse(thinking.contains("OPAQUE-CIPHERTEXT"))
        XCTAssertEqual(host.toolCalls.count, 1)
        XCTAssertEqual(host.toolCalls.first?.name, "shell")
        XCTAssertTrue(host.toolCalls.first?.output?.contains("QrScanner") == true)
        XCTAssertEqual(s.units.map(\.seq), [1, 2, 3])
    }

    func testCodexMergeQuickMetaPrefersStateTitle() {
        let codex = codexAdapter()
        let parsed = meta(.codex, key: "codex:file-uuid", id: "file-uuid", title: "首条消息推导标题", source: "IDE extension")
        var quick = meta(.codex, key: "codex:thread-1", id: "thread-1", title: "用户手动命名", source: "vscode")
        quick.model = "gpt-5.2"
        quick.tokensUsed = 999
        let merged = codex.mergeQuickMeta(parsed, quick)
        XCTAssertEqual(merged.title, "用户手动命名")
        XCTAssertEqual(merged.key, "codex:thread-1")
        XCTAssertEqual(merged.nativeId, "thread-1")
        XCTAssertEqual(merged.source, "IDE extension")
        XCTAssertEqual(merged.model, "gpt-5.2")
        XCTAssertEqual(merged.tokensUsed, 999)

        var placeholder = quick
        placeholder.title = CodingLimits.untitled
        XCTAssertEqual(codex.mergeQuickMeta(parsed, placeholder).title, "首条消息推导标题")

        // 默认实现（Claude）：标题 / key 不被 quick 覆盖，只补缺口
        let claude = ClaudeCodeAdapter(root: Self.fixtures)
        let cParsed = meta(.claudeCode, key: "claude-code:p", id: "p", title: "解析出来的标题", source: nil)
        let cMerged = claude.mergeQuickMeta(cParsed, meta(.claudeCode, key: "claude-code:q", id: "q", title: "手动改名", source: "state"))
        XCTAssertEqual(cMerged.title, "解析出来的标题")
        XCTAssertEqual(cMerged.key, "claude-code:p")
        XCTAssertEqual(cMerged.source, "state")
    }

    /// R-WN #6：state DB 有用户命名时，扫描出来的标题以它为准（quickMeta 读真 SQLite + merge）
    func testCodexStateDBTitleWinsThroughQuickMeta() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-codex-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state_5.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &handle), SQLITE_OK)
        let sql = """
            CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, title TEXT, name TEXT, tokens_used INTEGER,
              archived INTEGER, git_branch TEXT, model TEXT, source TEXT, created_at_ms INTEGER, updated_at_ms INTEGER);
            INSERT INTO threads VALUES ('22222222-aaaa-bbbb-cccc-000000000002',
              '/elsewhere/rollout-2026-08-02T09-15-00-22222222-aaaa-bbbb-cccc-000000000002.jsonl',
              '/Users/tester/Github/wakefx', 'ignored', '用户手动命名', 5000, 0, 'feat/qr', 'gpt-5.2-codex', 'vscode', 1, 2);
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let adapter = codexAdapter(stateDB: db)
        let r = try XCTUnwrap(adapter.fileRef(Self.fixtures.appendingPathComponent(Self.codexRollout)))
        let quick = try XCTUnwrap(adapter.quickMeta([r])?[r.filePath])
        XCTAssertEqual(quick.title, "用户手动命名")
        let merged = adapter.mergeQuickMeta(try adapter.parseSession(r).meta, quick)
        XCTAssertEqual(merged.title, "用户手动命名")
        XCTAssertEqual(merged.tokensUsed, 4321, "parsed 的 token 优先，state 只兜底")
    }

    func testRolloutNativeId() {
        XCTAssertEqual(CodexAdapter.rolloutNativeId("rollout-2026-08-14T11-47-18-abc-def"), "abc-def")
        XCTAssertEqual(CodexAdapter.rolloutNativeId("plain-id"), "plain-id")
    }

    // MARK: - Kimi Code

    func testKimiParseContract() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-kimi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let index = home.appendingPathComponent("session_index.jsonl")
        try #"{"sessionId":"session_88888888-aaaa-bbbb-cccc-000000000008","workDir":"/Users/tester/Github/wakefx"}"#
            .write(to: index, atomically: true, encoding: .utf8)
        let adapter = KimiCodeAdapter(root: Self.fixtures.appendingPathComponent("kimi/sessions"), indexPath: index)

        let wire = Self.fixtures.appendingPathComponent("kimi/sessions/wd_wakefx_abc123/session_88888888-aaaa-bbbb-cccc-000000000008/agents/main/wire.jsonl")
        let r = try XCTUnwrap(adapter.fileRef(wire))
        XCTAssertEqual(r.nativeId, "session_88888888-aaaa-bbbb-cccc-000000000008")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)
        XCTAssertEqual(s.meta.title, "Kimi QR fix")
        XCTAssertEqual(s.meta.projectPath, Self.project)
        XCTAssertEqual(s.meta.createdAt, ms("2026-08-06T12:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, ms("2026-08-06T12:30:00Z"))
        XCTAssertEqual(s.meta.messageCount, 2)
        XCTAssertEqual(s.unknownLines, 1)
        XCTAssertEqual(rolesKinds(t.mainline), ["user/text", "assistant/text"])
        XCTAssertEqual(t.mainline[0].text, "Kimi 修一下二维码组件的 useEffect() 内存泄漏")
        XCTAssertTrue(t.mainline[1].text.contains("QrScanner"))
        XCTAssertEqual(s.units.map(\.seq), [0, 1])

        let placeholder = Self.fixtures.appendingPathComponent("kimi/sessions/wd_wakefx_abc123/session_99999999-aaaa-bbbb-cccc-000000000009/agents/main/wire.jsonl")
        let s2 = try adapter.parseSession(try XCTUnwrap(adapter.fileRef(placeholder)))
        XCTAssertEqual(s2.meta.title, "占位标题会话应回退到这句")
        XCTAssertEqual(adapter.listSessionFiles().count, 2)
    }

    // MARK: - 工具

    func testIsoMsHandlesFractionsAndOffsets() {
        XCTAssertEqual(CodingParse.isoMs("1970-01-01T00:00:01Z"), 1000)
        XCTAssertEqual(CodingParse.isoMs("1970-01-01T00:00:01.5Z"), 1500)
        XCTAssertEqual(CodingParse.isoMs("1970-01-01T00:00:01.123456Z"), 1123)
        XCTAssertEqual(CodingParse.isoMs("1970-01-01T08:00:00+08:00"), 0)
        XCTAssertEqual(CodingParse.isoMs("1970-01-01T00:00:00"), 0, "缺时区 = 解析失败")
        XCTAssertEqual(CodingParse.isoMs("2026-08-01T10:00:00Z"), 1_785_578_400_000)
    }

    func testCleanTitleAndClip() {
        XCTAssertEqual(CodingParse.cleanTitleCandidate("<command-name>/review</command-name><command-args>看下登录</command-args>"), "看下登录")
        XCTAssertEqual(CodingParse.cleanTitleCandidate("<system-reminder>x</system-reminder>  你好\n世界 "), "你好 世界")
        XCTAssertEqual(CodingParse.cleanTitleCandidate(String(repeating: "长", count: 100)).count, 81)
        let (clipped, truncated) = CodingParse.clip("一二三", 4)
        XCTAssertTrue(truncated)
        XCTAssertTrue(clipped.hasPrefix("一"))
        XCTAssertFalse(clipped.hasPrefix("一二"))
    }

    private func meta(_ agent: CodingAgent, key: String, id: String, title: String, source: String?) -> CodingSessionMeta {
        CodingSessionMeta(key: key, nativeId: id, agent: agent, title: title, projectPath: "", projectName: "", filePath: "/f/\(id)",
                          createdAt: 0, updatedAt: 0, messageCount: 0, sizeBytes: 0, gitBranch: nil, model: nil,
                          tokensUsed: nil, archived: false, source: source)
    }
}

/// 索引往返 + 增量扫描（tmp 目录：fixture 拷一份再改 / 删）
final class CodingSessionIndexTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures, to: dir.appendingPathComponent("home"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var home: URL { dir.appendingPathComponent("home") }

    private func adapters() -> [CodingSessionAdapter] {
        [
            ClaudeCodeAdapter(root: home.appendingPathComponent("claude/projects")),
            CodexAdapter(sessionsDir: home.appendingPathComponent("codex/sessions"),
                         archivedDir: home.appendingPathComponent("codex/archived_sessions"),
                         stateDB: home.appendingPathComponent("codex/state_5.sqlite")),
            KimiCodeAdapter(root: home.appendingPathComponent("kimi/sessions"), indexPath: home.appendingPathComponent("kimi/session_index.jsonl")),
        ]
    }

    func testScanIndexesAllFixturesAndKeepsSeqContract() throws {
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let scanner = CodingSessionScanner(index: index, adapters: adapters())
        var progressEvents: [CodingSessionScanner.Progress] = []
        let report = try scanner.run { progressEvents.append($0) }
        XCTAssertEqual(report.parsed, 9)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try index.sessionCount(), 9)
        XCTAssertEqual(progressEvents.last?.scanning, false, "终态必发")
        XCTAssertTrue(try index.listProjects().contains { $0.path == "/Users/tester/Github/wakefx" })

        let claudeKey = "claude-code:11111111-aaaa-bbbb-cccc-000000000001"
        XCTAssertEqual(try index.messageSeqs(key: claudeKey), [1, 2, 3], "索引 seq = 详情 Text 消息 seq")
        XCTAssertEqual(try index.session(key: claudeKey)?.title, "QR login revamp")
        XCTAssertTrue(try index.matchingMessages("Login.tsx").contains { $0.key == claudeKey && $0.seq == 2 })

        // 无变化再扫：不重解析
        XCTAssertEqual(try scanner.run().parsed, 0)
    }

    func testIncrementalRescanAndPrune() throws {
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let scanner = CodingSessionScanner(index: index, adapters: adapters())
        _ = try scanner.run()

        let claudeFile = home.appendingPathComponent("claude/projects/-Users-tester-Github-wakefx/11111111-aaaa-bbbb-cccc-000000000001.jsonl")
        let handle = try FileHandle(forWritingTo: claudeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"custom-title\",\"customTitle\":\"改过的标题\"}\n".utf8))
        try handle.close()
        XCTAssertEqual(try scanner.run().parsed, 1)
        XCTAssertEqual(try index.session(key: "claude-code:11111111-aaaa-bbbb-cccc-000000000001")?.title, "改过的标题")

        try FileManager.default.removeItem(at: claudeFile)
        let report = try scanner.run()
        XCTAssertEqual(report.pruned, 1)
        XCTAssertNil(try index.session(key: "claude-code:11111111-aaaa-bbbb-cccc-000000000001"))
        XCTAssertEqual(try index.messageSeqs(key: "claude-code:11111111-aaaa-bbbb-cccc-000000000001"), [])
    }

    func testTombstonedSessionsAreNotIndexed() throws {
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let scanner = CodingSessionScanner(index: index, adapters: adapters())
        _ = try scanner.run(isTombstoned: { _, key in key.hasPrefix("kimi:") })
        XCTAssertEqual(try index.sessionCount(), 7)
    }

    func testSchemaVersionMismatchRebuilds() throws {
        let url = dir.appendingPathComponent("index.sqlite")
        do {
            let index = try CodingSessionIndex(url: url)
            _ = try CodingSessionScanner(index: index, adapters: adapters()).run()
            XCTAssertEqual(try index.sessionCount(), 9)
        }
        var handle: OpaquePointer?
        sqlite3_open(url.path, &handle)
        sqlite3_exec(handle, "UPDATE schema_meta SET value = 'old' WHERE key = 'version'", nil, nil, nil)
        sqlite3_close(handle)
        let reopened = try CodingSessionIndex(url: url)
        XCTAssertEqual(try reopened.sessionCount(), 0)
    }
}
#endif
