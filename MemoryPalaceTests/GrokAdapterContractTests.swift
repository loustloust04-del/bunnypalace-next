#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-d Grok：照抄 Wake `grok_parse_contract` + seq 契约 + `grok_group.rs` 的归组单测（普通 cwd / 临时 worktree 跟本地 origin /
/// 同一计划归一处 / 登记表映射源仓库 / 嵌套子代理扁平到根 / 从会话树读父链）
final class GrokAdapterContractTests: XCTestCase {
    private var fixtures: URL { CodingSessionAdapterTests.fixtures.appendingPathComponent("grok") }
    private var sessionDir: URL {
        fixtures.appendingPathComponent("sessions/%2FUsers%2Ftester%2FGithub%2Fwakefx/77777777-aaaa-bbbb-cccc-000000000007")
    }

    func testGrokParseContract() throws {
        let adapter = GrokAdapter(root: fixtures.appendingPathComponent("sessions"), grokHome: fixtures)
        adapter.beginScan()
        XCTAssertTrue(adapter.managesParentLinks)
        XCTAssertTrue(adapter.parentLinks().contains { $0.child == "grok:aaaaaaaa-aaaa-bbbb-cccc-0000000000aa" && $0.parent == "grok:77777777-aaaa-bbbb-cccc-000000000007" })
        XCTAssertTrue(adapter.isParentLinkEvent(sessionDir.appendingPathComponent("subagents/child-fixture/meta.json").path))
        let path = sessionDir.appendingPathComponent("updates.jsonl")
        XCTAssertFalse(adapter.isParentLinkEvent(path.path))
        let r = try XCTUnwrap(adapter.fileRef(path), "fileRef 只认 updates.jsonl，native id 取会话目录名")
        XCTAssertEqual(r.nativeId, "77777777-aaaa-bbbb-cccc-000000000007")
        XCTAssertNil(adapter.fileRef(sessionDir.appendingPathComponent("chat_history.jsonl")))

        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)
        XCTAssertEqual(s.meta.title, "Grok QR scan cleanup", "summary.json 标题优先")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx", "info.cwd")
        XCTAssertEqual(s.meta.gitBranch, "feat/qr")
        XCTAssertEqual(s.meta.model, "grok-composer-2.5-fast")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-06T11:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-06T11:20:00Z"))
        XCTAssertEqual(s.meta.messageCount, 2)
        XCTAssertEqual(s.unknownLines, 1, "wibble_update；auto_compact_started 不计")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text"],
                       "chunk 流按角色段合并：两条 user chunk 拼成一条，thought / message / tool 全并入一条 assistant")
        XCTAssertEqual(t.mainline[0].text, "Grok 看看二维码扫描,重点 useEffect() 清理")
        XCTAssertEqual(t.mainline[0].timestamp, 1_786_014_300_000)
        let a = t.mainline[1]
        XCTAssertEqual(a.text, "已定位泄漏,补了清理回调。")
        XCTAssertTrue(a.thinking?.contains("effect 泄漏") ?? false)
        XCTAssertEqual(a.toolCalls.count, 1)
        XCTAssertEqual(a.toolCalls.first?.name, "Grep")
        XCTAssertTrue(a.toolCalls.first?.output?.contains("found 2 matches") ?? false, "tool_call_update 的 content 文本回填；字节数组 rawOutput 不碰")
        XCTAssertEqual(a.toolCalls.first?.isError, false)
        XCTAssertEqual(s.units.map(\.seq), [0, 1])
        try CodingContract.assertSeqContract(adapter, r)
        XCTAssertEqual(adapter.sessionPaths(s.meta), [sessionDir.path], "删整个会话目录")
    }

    private let grokHome = URL(fileURLWithPath: "/Users/tester/.grok")

    func testOrdinaryCwdIsUnchanged() {
        let project = CodingGrokGroup.canonicalProject(cwd: "/Users/tester/Github/wakefx", remotes: [], grokHome: grokHome, childId: "", ctx: .init())
        XCTAssertEqual(project.path, "/Users/tester/Github/wakefx")
        XCTAssertEqual(project.name, "wakefx")
    }

    func testEphemeralWorktreeFollowsLocalOriginRemote() {
        let project = CodingGrokGroup.canonicalProject(cwd: "/var/folders/xx/T/grok-501/wt-abcd1234-pr-9",
                                                       remotes: ["/Users/tester/Github/wakefx.origin.git"], grokHome: grokHome, childId: "", ctx: .init())
        XCTAssertEqual(project.path, "/Users/tester/Github/wakefx")
        XCTAssertEqual(project.name, "wakefx")
    }

    func testEphemeralWorktreesForOnePlanGroupTogether() {
        let first = CodingGrokGroup.canonicalProject(cwd: "/var/folders/xx/T/grok-501/wt-abcd1234-pr-9", remotes: [], grokHome: grokHome, childId: "", ctx: .init())
        let second = CodingGrokGroup.canonicalProject(cwd: "/var/folders/xx/T/grok-501/wt-abcd1234-pr-15", remotes: [], grokHome: grokHome, childId: "", ctx: .init())
        XCTAssertEqual(first.path, second.path)
        XCTAssertEqual(first.path, "/var/folders/xx/T/grok-501/wt-abcd1234")
    }

    func testRegistryMapsNamedWorktreeToSourceRepo() {
        var ctx = CodingGrokGroup.Context()
        ctx.worktrees = [.init(path: "/Users/tester/.grok/worktrees/works-app/branch", sourceRepo: "/Users/tester/Works/app", repoName: "app")]
        let project = CodingGrokGroup.canonicalProject(cwd: "/Users/tester/.grok/worktrees/works-app/branch/subagent", remotes: [],
                                                       grokHome: grokHome, childId: "", ctx: ctx)
        XCTAssertEqual(project.path, "/Users/tester/Works/app")
        XCTAssertEqual(project.name, "app")
    }

    func testNestedSubagentFlattensToRootParent() {
        var ctx = CodingGrokGroup.Context()
        ctx.parents = ["child-2": .init(parentId: "child-1", parentCwd: "/var/folders/xx/wt"),
                       "child-1": .init(parentId: "orchestrator", parentCwd: "/Users/tester/Desktop/AI/Grok")]
        let project = CodingGrokGroup.canonicalProject(cwd: "/var/folders/xx/wt", remotes: [], grokHome: grokHome, childId: "child-2", ctx: ctx)
        XCTAssertEqual(project.path, "/Users/tester/Desktop/AI/Grok")
        XCTAssertEqual(project.name, "Grok")
        let links = Set(CodingGrokGroup.parentLinks(ctx).map { "\($0.child)>\($0.parent)" })
        XCTAssertEqual(links, ["grok:child-2>grok:child-1", "grok:child-1>grok:orchestrator"])
    }

    func testLoadsParentRelationFromSessionTree() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-grok-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let metaDir = temp.appendingPathComponent("%2FUsers%2Ftester%2FDesktop%2FAI%2FGrok/orchestrator/subagents/child")
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try #"{"parent_session_id":"orchestrator","child_session_id":"child"}"#.write(to: metaDir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        let ctx = CodingGrokGroup.load(sessionsRoot: temp, grokHome: temp)
        XCTAssertTrue(CodingGrokGroup.parentLinks(ctx).contains { $0.child == "grok:child" && $0.parent == "grok:orchestrator" })
        XCTAssertEqual(ctx.parents["child"]?.parentCwd, "/Users/tester/Desktop/AI/Grok", "组目录名 percent-decode 成父会话 cwd")
        XCTAssertEqual(CodingGrokGroup.percentDecode("%2FUsers%2Ftester"), "/Users/tester")
        XCTAssertEqual(CodingGrokGroup.percentDecode("%zz%2"), "%zz%2", "非法序列原样保留")
    }
}
#endif
