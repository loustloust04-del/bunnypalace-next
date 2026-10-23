#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-a1：16 家枚举（声明序 / 显示名同 Wake `AgentId`）、续跑命令表（Wake `services/terminal/mod.rs` agent_bin + resume_args）、
/// 无形制三家不出续跑、有会话的 agent 才出筛选胶囊。
final class CodingSessionAgentsTests: XCTestCase {
    private func meta(_ agent: CodingAgent, id: String = "id-1", file: String = "/f", source: String? = nil) -> CodingSessionMeta {
        CodingSessionMeta(key: "\(agent.rawValue):\(id)", nativeId: id, agent: agent, title: "t", projectPath: "", projectName: "",
                          filePath: file, createdAt: 1, updatedAt: 1, messageCount: 1, sizeBytes: 1,
                          gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: source)
    }

    func testSixteenAgentsInWakeDeclarationOrder() {
        XCTAssertEqual(CodingAgent.allCases.map(\.rawValue), [
            "claude-code", "codex", "grok", "dsh", "cursor", "opencode", "pi", "omp",
            "kiro", "kimi", "gemini", "copilot", "antigravity", "qoder", "hermes", "openclaw",
        ])
        XCTAssertEqual(CodingAgent.allCases.map(\.displayName), [
            "Claude Code", "Codex", "Grok Build", "DeepSeek Harness", "Cursor", "OpenCode", "Pi", "Oh My Pi",
            "Kiro", "Kimi Code", "Gemini CLI", "Copilot CLI", "Antigravity CLI", "Qoder CLI", "Hermes Agent", "OpenClaw",
        ])
        XCTAssertEqual(Set(CodingAgent.allCases.map(\.shortName)).count, 16, "胶囊短名互不相同")
        XCTAssertEqual(CodingAgent.claudeCode.shortName, "Claude")
        XCTAssertNil(CodingSessionFormat.colorHex(.kimi), "Kimi 沿用弱色灰")
        XCTAssertEqual(Set(CodingAgent.allCases.compactMap { CodingSessionFormat.colorHex($0) }).count, 15, "其余各家色值不重")
    }

    func testResumeTableMatchesWake() {
        func inv(_ m: CodingSessionMeta) -> [String]? {
            CodingSessionResume.invocation(for: m).map { [$0.bin] + $0.args }
        }
        XCTAssertEqual(inv(meta(.claudeCode)), ["claude", "--resume", "id-1"])
        XCTAssertEqual(inv(meta(.codex)), ["codex", "resume", "id-1"])
        XCTAssertEqual(inv(meta(.grok)), ["grok", "--resume", "id-1"])
        XCTAssertEqual(inv(meta(.dsh)), ["npx", "@deepseek-ai/dsh", "web"], "dsh 拉起 web，不是按会话定点续跑")
        XCTAssertEqual(inv(meta(.cursor)), ["cursor-agent", "--resume", "id-1"])
        XCTAssertEqual(inv(meta(.opencode)), ["opencode", "--session", "id-1"])
        XCTAssertEqual(inv(meta(.opencode, source: "opencode2")), ["opencode2", "--session", "id-1"], "v2 会话换 opencode2")
        XCTAssertEqual(inv(meta(.pi)), ["pi", "--session", "id-1"])
        XCTAssertEqual(inv(meta(.omp)), ["omp", "--resume", "id-1"])
        XCTAssertEqual(inv(meta(.kimi)), ["kimi", "--session", "id-1"])
        XCTAssertEqual(inv(meta(.copilot)), ["copilot", "--resume=id-1"])
        XCTAssertEqual(inv(meta(.antigravity)), ["agy", "--conversation=id-1"])
        XCTAssertEqual(inv(meta(.qoder)), ["qoder", "--resume", "id-1"])
        XCTAssertEqual(inv(meta(.hermes, file: "/h/.hermes/state.db#id-1")), ["hermes", "--profile", "default", "--resume", "id-1"])
        XCTAssertEqual(inv(meta(.hermes, file: "/h/.hermes/profiles/work/state.db#id-1")),
                       ["hermes", "--profile", "work", "--resume", "id-1"], "档案库带 profile 名")
        for agent in [CodingAgent.kiro, .gemini, .openclaw] {
            XCTAssertNil(inv(meta(agent)), "\(agent) 没有按会话续跑的形制")
            XCTAssertFalse(CodingSessionResume.canResume(agent))
            XCTAssertNil(CodingSessionResume.script(for: meta(agent)))
            XCTAssertNil(CodingSessionResume.shellCommand(for: meta(agent)))
            XCTAssertFalse(CodingResumeTarget.terminal.supports(agent))
            XCTAssertFalse(CodingResumeTarget.iterm.supports(agent))
        }
        XCTAssertTrue(CodingResumeTarget.terminal.supports(.grok))
        XCTAssertFalse(CodingResumeTarget.claudeDesktop.supports(.grok), "桌面深链只接自家")
        XCTAssertEqual(CodingSessionResume.resumeLabel(.dsh), "打开 DeepSeek Harness")
        XCTAssertEqual(CodingSessionResume.resumeLabel(.claudeCode), "在终端继续")
    }

    func testVirtualPathStripsOnlyWhenMissing() throws {
        XCTAssertEqual(CodingVirtualPath.make(db: "/a/state.db", id: "x"), "/a/state.db#x")
        XCTAssertEqual(CodingVirtualPath.strip("/nonexistent/state.db#x"), "/nonexistent/state.db")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-vpath-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("a#b.jsonl")
        try Data("x".utf8).write(to: real)
        XCTAssertEqual(CodingVirtualPath.strip(real.path), real.path, "真实存在的路径原样返回（文件名里本来就有 #）")
    }

    func testPresentAgentsComeFromIndex() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        func write(_ agent: CodingAgent, _ id: String, archived: Bool = false) throws {
            var m = meta(agent, id: id, file: "/tmp/\(agent.rawValue)-\(id).jsonl")
            m.archived = archived
            try index.writeSession(m, fileMtime: 1, units: [])
        }
        try write(.qoder, "q1")
        try write(.claudeCode, "c1")
        try write(.hermes, "h1", archived: true)
        XCTAssertEqual(try index.presentAgents(), [.claudeCode, .qoder], "按声明序、归档不算")
    }
}
#endif
