#if os(macOS)
import XCTest
@testable import 记忆花园

/// N1-k 续跑目标：命令 / 深链拼装、UUID 门卫、Claude 桌面版归属扫描（假家目录）。不真的拉起外部 app。
final class CodingSessionTerminalTests: XCTestCase {
    private func meta(_ agent: CodingAgent, id: String, project: String = "") -> CodingSessionMeta {
        CodingSessionMeta(key: "\(agent.rawValue):\(id)", nativeId: id, agent: agent, title: "t", projectPath: project,
                          projectName: "p", filePath: "/f", createdAt: 0, updatedAt: 0, messageCount: 0, sizeBytes: 0,
                          gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil)
    }

    func testShellCommandIsSingleLineAndQuoted() {
        let dir = FileManager.default.temporaryDirectory.path
        XCTAssertEqual(CodingSessionResume.shellCommand(for: meta(.claudeCode, id: "u-1", project: dir)),
                       "cd '\(dir)' && claude '--resume' 'u-1'")
        XCTAssertEqual(CodingSessionResume.shellCommand(for: meta(.codex, id: "t'1", project: "/nonexistent")),
                       "codex 'resume' 't'\\''1'")
    }

    func testUUIDGateAndAppleScriptQuote() {
        XCTAssertTrue(CodingSessionResume.isUUID("11111111-aaaa-BBBB-cccc-000000000001"))
        XCTAssertFalse(CodingSessionResume.isUUID("session_88888888-aaaa-bbbb-cccc-000000000008"))
        XCTAssertFalse(CodingSessionResume.isUUID("11111111-aaaa-bbbb-cccc-00000000000g"))
        XCTAssertEqual(CodingSessionResume.appleScriptQuote(#"say "hi" \ bye"#), #"say \"hi\" \\ bye"#)
    }

    func testDesktopTargetsOnlyTheirOwnAgent() {
        XCTAssertTrue(CodingResumeTarget.claudeDesktop.supports(.claudeCode))
        XCTAssertFalse(CodingResumeTarget.claudeDesktop.supports(.codex))
        XCTAssertTrue(CodingResumeTarget.codexDesktop.supports(.codex))
        XCTAssertFalse(CodingResumeTarget.codexDesktop.supports(.kimi))
        XCTAssertTrue(CodingResumeTarget.iterm.supports(.kimi))
        if case .success = CodingSessionResume.desktopURL(for: meta(.kimi, id: "session_1"), target: .codexDesktop) {
            XCTFail("Kimi 会话不能走 Codex 桌面版")
        }
    }

    func testCodexDeepLinkNeedsUUID() {
        let good = CodingSessionResume.desktopURL(for: meta(.codex, id: "22222222-aaaa-bbbb-cccc-000000000002"), target: .codexDesktop)
        XCTAssertEqual(try good.get().absoluteString, "codex://threads/22222222-aaaa-bbbb-cccc-000000000002")
        if case .success = CodingSessionResume.desktopURL(for: meta(.codex, id: "not-a-uuid"), target: .codexDesktop) {
            XCTFail("非 UUID 必须就地报错")
        }
    }

    func testClaudeDesktopOwnershipScanPrefersNewestRecord() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-claude-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = "11111111-aaaa-bbbb-cccc-000000000001"
        let oldStem = "aaaaaaaa-0000-4000-8000-000000000001"
        let newStem = "bbbbbbbb-0000-4000-8000-000000000002"
        func write(_ account: String, _ stem: String, _ body: [String: Any], age: TimeInterval) throws {
            let dir = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/\(account)/org")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("local_\(stem).json")
            var json = body
            json["sessionId"] = "local_\(stem)"
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        try write("acct-old", oldStem, ["cliSessionId": cli], age: 3600)
        try write("acct-new", newStem, ["priorCliSessionIds": ["x", cli]], age: 10)
        try write("acct-other", "cccccccc-0000-4000-8000-000000000003", ["cliSessionId": "someone-else"], age: 0)

        XCTAssertEqual(CodingSessionResume.claudeDesktopOwnedStem(cliId: cli, home: home), newStem, "多份命中取 mtime 最新")
        let url = CodingSessionResume.desktopURL(for: meta(.claudeCode, id: cli), target: .claudeDesktop, home: home)
        XCTAssertEqual(try url.get().absoluteString, "claude://resume?session=\(newStem)")

        let unowned = CodingSessionResume.desktopURL(for: meta(.claudeCode, id: "99999999-aaaa-bbbb-cccc-000000000009"), target: .claudeDesktop, home: home)
        XCTAssertEqual(try unowned.get().absoluteString, "claude://resume?session=99999999-aaaa-bbbb-cccc-000000000009", "没被收编就发原 id")
    }
}
#endif
