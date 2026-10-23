#if os(macOS)
import XCTest
@testable import 记忆花园

/// N1-j 子代理：Claude `<会话>/subagents/<id>.jsonl` + meta 关联到工具调用、懒加载侧链、Library 从当前详情读；
/// R-WN1 #1 Codex review 输出可读且不重复（移植 Wake `codex_review_output_is_readable_and_not_duplicated`）
@MainActor
final class CodingSessionSidechainTests: XCTestCase {
    private var root: URL!
    private let id = "13131313-aaaa-bbbb-cccc-000000000013"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-sidechain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var projectsDir: URL { root.appendingPathComponent("claude/projects") }

    private func writeSession() throws -> URL {
        let projectDir = projectsDir.appendingPathComponent("-tmp-side")
        let subagents = projectDir.appendingPathComponent(id).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func row(_ type: String, _ uuid: String, _ second: Int, sidechain: Bool = false, _ message: [String: Any]) -> [String: Any] {
            ["type": type, "uuid": uuid, "sessionId": id, "cwd": "/tmp/side", "isSidechain": sidechain,
             "timestamp": "2026-09-01T10:00:0\(second).000Z", "message": message]
        }
        let main = [
            row("user", "u1", 0, ["role": "user", "content": "帮我查一下"]),
            row("assistant", "a1", 1, ["id": "m1", "role": "assistant", "model": "claude-x", "content": [
                ["type": "text", "text": "派个子代理"],
                ["type": "tool_use", "id": "toolu_1", "name": "Task", "input": ["description": "查资料", "prompt": "查一下"]],
            ]]),
            row("user", "u2", 2, ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "查完了"]]]),
        ]
        let file = projectDir.appendingPathComponent("\(id).jsonl")
        try (try main.map(line).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let side = [
            row("user", "s1", 3, sidechain: true, ["role": "user", "content": "查一下"]),
            row("assistant", "s2", 4, sidechain: true, ["id": "m2", "role": "assistant", "model": "claude-x",
                                                        "content": [["type": "text", "text": "子代理的回答"]]]),
        ]
        try (try side.map(line).joined(separator: "\n") + "\n")
            .write(to: subagents.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["agentType": "general-purpose", "description": "查资料", "toolUseId": "toolu_1"])
            .write(to: subagents.appendingPathComponent("agent-a1.meta.json"))
        return file
    }

    func testClaudeSidechainLinksToToolCallAndLoadsLazily() throws {
        let file = try writeSession()
        let adapter = ClaudeCodeAdapter(root: projectsDir)
        let ref = try XCTUnwrap(adapter.fileRef(file))
        XCTAssertNil(adapter.fileRef(file.deletingLastPathComponent().appendingPathComponent("\(id)/subagents/agent-a1.jsonl")),
                     "子代理文件不单独成会话")
        let transcript = try adapter.parseTranscript(ref)
        XCTAssertEqual(transcript.sidechains.map(\.id), ["agent-a1"])
        XCTAssertEqual(transcript.sidechains.first?.description, "查资料")
        let host = try XCTUnwrap(transcript.mainline.first { !$0.toolCalls.isEmpty })
        XCTAssertEqual(host.toolCalls.first?.sidechainRef, "agent-a1")
        XCTAssertEqual(host.toolCalls.first?.output, "查完了")

        let side = try adapter.loadSidechain(ref, id: "agent-a1")
        XCTAssertEqual(side.map(\.role), [.user, .assistant])
        XCTAssertEqual(side.last?.text, "子代理的回答")
        XCTAssertTrue(try adapter.loadSidechain(ref, id: "nope").isEmpty)
    }

    func testLibraryLoadsSidechainOfCurrentDetail() async throws {
        _ = try writeSession()
        let library = CodingSessionLibrary(indexURL: root.appendingPathComponent("index.sqlite"),
                                           adapters: [ClaudeCodeAdapter(root: projectsDir)],
                                           state: CodingSessionState(url: root.appendingPathComponent("state.json")))
        await library.refresh()?.value
        if case .failure = await library.loadSidechain(id: "agent-a1") {} else { XCTFail("没选中会话时应回失败") }
        library.select("claude-code:\(id)")
        for _ in 0..<60 {
            if case .loaded = library.detail { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .loaded = library.detail else { return XCTFail("详情没加载") }
        XCTAssertEqual(library.sidechainInfo("agent-a1")?.agentType, "general-purpose")
        let result = await library.loadSidechain(id: "agent-a1")
        XCTAssertEqual(try result.get().last?.text, "子代理的回答")
    }

    func testCodexReviewOutputIsReadableAndNotDuplicated() throws {
        let fixtures = CodingSessionAdapterTests.fixtures
        let adapter = CodexAdapter(sessionsDir: fixtures.appendingPathComponent("codex/sessions"),
                                   archivedDir: fixtures.appendingPathComponent("codex/archived_sessions"),
                                   stateDB: fixtures.appendingPathComponent("codex/state_5.sqlite"))
        let url = fixtures.appendingPathComponent(
            "codex/sessions/2026/08/09/rollout-2026-08-09T10-30-00-44444444-aaaa-bbbb-cccc-000000000004.jsonl")
        let ref = try XCTUnwrap(adapter.fileRef(url))
        let transcript = try adapter.parseTranscript(ref)
        XCTAssertEqual(transcript.mainline.count, 1)
        let review = try XCTUnwrap(transcript.mainline.first)
        XCTAssertEqual(review.role, .assistant)
        XCTAssertEqual(review.kind, .text)
        for needle in ["## Code review", "Changes requested", "[P2] Keep the selected row", "workbench.rs:42–44", "98%"] {
            XCTAssertTrue(review.text.contains(needle), needle)
        }
        for banned in ["Fallback review text", "\"findings\"", "<user_action>"] {
            XCTAssertFalse(review.text.contains(banned), banned)
        }
        XCTAssertEqual(transcript.unknownLines, 0)

        let session = try adapter.parseSession(ref)
        XCTAssertEqual(session.meta.messageCount, 1)
        XCTAssertEqual(session.meta.title, CodingLimits.untitled)
        XCTAssertEqual(session.units.count, 1)
        XCTAssertTrue(session.units.first?.text.contains("Keep the selected row") == true)
    }
}
#endif
