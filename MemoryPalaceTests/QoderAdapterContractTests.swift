#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-b Qoder：逐条照抄 Wake `qoder_parse_contract` / `qoder_explicit_null_active_leaf_is_empty` + 全局 seq 契约 + 根解析
final class QoderAdapterContractTests: XCTestCase {
    private var root: URL { CodingSessionAdapterTests.fixtures.appendingPathComponent("qoder/projects") }
    private var project: URL { root.appendingPathComponent("-Users-tester-Github-wakefx") }

    private func ref(_ id: String) throws -> CodingSessionFileRef {
        try XCTUnwrap(QoderAdapter(root: root).fileRef(project.appendingPathComponent("\(id).jsonl")))
    }

    func testQoderParseContract() throws {
        let adapter = QoderAdapter(root: root)
        let r = try ref("abababab-aaaa-bbbb-cccc-000000000014")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)

        XCTAssertEqual(s.meta.key, "qoder:abababab-aaaa-bbbb-cccc-000000000014")
        XCTAssertEqual(s.meta.title, "Qoder active branch title", "custom-title 压过 ai-title / last-prompt")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx-relocated", "worktree-state 被后一条 null 清掉 → relocated")
        XCTAssertEqual(s.meta.projectName, "wakefx-relocated")
        XCTAssertEqual(s.meta.gitBranch, "feature/qoder")
        XCTAssertEqual(s.meta.model, "qoder-performance", "消息里的 model 压过 runtime-config")
        XCTAssertEqual(s.meta.tokensUsed, 160, "同 message.id 的分片 usage 只计一次；废弃分支不计")
        XCTAssertEqual(s.meta.messageCount, 4)
        XCTAssertEqual(s.unknownLines, 1, "qoder-future-metadata")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/meta", "user/text", "assistant/text", "user/text", "assistant/text"])
        XCTAssertTrue(t.mainline.allSatisfy { !$0.text.contains("废弃") }, "active-leaf 之外的分支不出现")
        let host = t.mainline[2]
        XCTAssertTrue(host.text.contains("我先定位相关 effect"))
        XCTAssertEqual(host.toolCalls.count, 1)
        XCTAssertEqual(host.toolCalls.first?.name, "Grep")
        XCTAssertTrue(host.toolCalls.first?.output?.contains("QrScanner.tsx:42") ?? false, "兄弟分片下的 tool_result 收回并回填")
        XCTAssertTrue(host.thinking?.contains("清理回调") ?? false)
        XCTAssertEqual(s.units.map(\.seq), [1, 2, 3, 4])
        try CodingContract.assertSeqContract(adapter, r)

        let refs = adapter.listSessionFiles()
        XCTAssertEqual(refs.count, 2, "只枚举 project-key 直属会话，不吸入会话边车")
        XCTAssertTrue(refs.contains { $0.nativeId == r.nativeId })
        XCTAssertEqual(adapter.sessionPaths(s.meta).count, 2, "会话文件 + 同名边车目录")
        XCTAssertNil(adapter.fileRef(project.appendingPathComponent("abababab-aaaa-bbbb-cccc-000000000014/subagents/agent-child.jsonl")))
    }

    func testExplicitNullActiveLeafIsEmpty() throws {
        let adapter = QoderAdapter(root: root)
        let r = try ref("cdcdcdcd-aaaa-bbbb-cccc-000000000015")
        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)

        XCTAssertEqual(s.meta.title, "Qoder empty rewind")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx-null")
        XCTAssertEqual(s.meta.messageCount, 0)
        XCTAssertNil(s.meta.tokensUsed)
        XCTAssertTrue(s.units.isEmpty)
        XCTAssertTrue(t.mainline.isEmpty, "显式 null = 已回退成空会话，不退回磁盘上最后一条分支")
        XCTAssertEqual(s.unknownLines, 0)
    }

    func testRootResolutionAndDegrade() {
        let home = URL(fileURLWithPath: "/nonexistent-home")
        XCTAssertEqual(QoderAdapter.make(home: home, environment: [:]).root.path, "/nonexistent-home/.qoder/projects")
        XCTAssertEqual(QoderAdapter.make(home: home, environment: ["QODER_CONFIG_DIR": "/nonexistent-env"]).root.path,
                       "/nonexistent-home/.qoder/projects", "没有会话的候选不遮掉默认根")
        XCTAssertEqual(QoderAdapter.make(home: home, environment: ["QODER_CONFIG_DIR": root.deletingLastPathComponent().path]).root.path,
                       root.path, "有会话的 QODER_CONFIG_DIR/projects 生效")
        XCTAssertTrue(QoderAdapter.make(home: home, environment: [:]).listSessionFiles().isEmpty, "缺根降级为空")
        XCTAssertNil(QoderAdapter(root: root).fileRef(URL(fileURLWithPath: "/elsewhere/x.jsonl")), "根外文件不认")
    }
}
#endif
