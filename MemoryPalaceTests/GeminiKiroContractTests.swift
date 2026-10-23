#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-b Gemini / Kiro：逐条照抄 Wake `gemini_parse_contract` / `kiro_parse_contract` + 全局 seq 契约
final class GeminiKiroContractTests: XCTestCase {
    private var fixtures: URL { CodingSessionAdapterTests.fixtures }
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-gemini-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGeminiParseContract() throws {
        // 同 Wake 测试的假 HOME：projects.json 路径→slug
        let projects = dir.appendingPathComponent("projects.json")
        try Data(#"{"projects":{"/Users/tester/Github/wakefx":"wakefx-gem"}}"#.utf8).write(to: projects)
        let adapter = GeminiAdapter(root: fixtures.appendingPathComponent("gemini/tmp"), projectsJSON: projects)
        let ref = try XCTUnwrap(adapter.listSessionFiles().first)
        let s = try adapter.parseSession(ref)
        let t = try adapter.parseTranscript(ref)

        XCTAssertEqual(t.mainline.count, 2, "$set 是覆盖式快照：只认最后一条")
        XCTAssertFalse(t.mainline.contains { $0.text.contains("旧快照") })
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text"])
        XCTAssertEqual(s.meta.nativeId, "55555555-aaaa-bbbb-cccc-000000000005", "id 取 header 的 sessionId（非文件名 stem）")
        XCTAssertEqual(s.meta.key, "gemini:55555555-aaaa-bbbb-cccc-000000000005")
        XCTAssertEqual(s.meta.title, "Gemini 帮我调试二维码解码,顺带看 useEffect()")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx", "cwd 经 projects.json 路径→slug 反查")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-04T12:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-04T12:20:00Z"))
        XCTAssertEqual(s.meta.messageCount, 2)
        XCTAssertEqual(s.unknownLines, 1)
        XCTAssertEqual(s.units.map(\.seq), [0, 1])
        try CodingContract.assertSeqContract(adapter, ref)
        XCTAssertNil(adapter.fileRef(fixtures.appendingPathComponent("gemini/tmp/wakefx-gem/other.jsonl")), "只认 chats/session-*.jsonl")
    }

    func testKiroParseContract() throws {
        let adapter = KiroAdapter(root: fixtures.appendingPathComponent("kiro/sessions/cli"))
        let ref = try XCTUnwrap(adapter.listSessionFiles().first)
        let s = try adapter.parseSession(ref)
        let t = try adapter.parseTranscript(ref)

        XCTAssertEqual(s.meta.title, "Kiro QR session", ".json 边车给标题")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx")
        XCTAssertEqual(s.meta.model, "claude-sonnet-4", "session_state.rts_model_state.model_info")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-03T08:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-03T08:30:00Z"), "边车晚于消息时间")
        XCTAssertEqual(s.meta.messageCount, 2)
        XCTAssertEqual(s.unknownLines, 1, "ToolLog")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text"])
        XCTAssertEqual(t.mainline[0].timestamp, 1_785_744_300_000, "jsonl 的 timestamp 是 unix 秒，换算成 ms")
        XCTAssertEqual(t.mainline[1].timestamp, 1_785_744_360_000)
        XCTAssertEqual(s.units.map(\.seq), [0, 1])
        try CodingContract.assertSeqContract(adapter, ref)
    }

    func testDefaultRoots() {
        let home = URL(fileURLWithPath: "/h")
        XCTAssertEqual(GeminiAdapter(home: home).root.path, "/h/.gemini/tmp")
        XCTAssertEqual(GeminiAdapter(home: home).projectsJSON.path, "/h/.gemini/projects.json")
        XCTAssertEqual(KiroAdapter(home: home).root.path, "/h/.kiro/sessions/cli")
        XCTAssertTrue(GeminiAdapter(home: URL(fileURLWithPath: "/nonexistent")).listSessionFiles().isEmpty, "缺根降级为空")
        XCTAssertTrue(KiroAdapter(home: URL(fileURLWithPath: "/nonexistent")).listSessionFiles().isEmpty)
    }
}
#endif
