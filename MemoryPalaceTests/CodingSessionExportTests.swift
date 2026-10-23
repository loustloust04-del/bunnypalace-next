#if os(macOS)
import XCTest
@testable import 记忆花园

/// N1-g 导出 Markdown（Wake `exporter.rs` 格式逐项对齐，R-WN1 #9）
final class CodingSessionExportTests: XCTestCase {
    private let claudeFile = CodingSessionAdapterTests.fixtures
        .appendingPathComponent("claude/projects/-Users-tester-Github-wakefx/11111111-aaaa-bbbb-cccc-000000000001.jsonl")

    func testClaudeFixtureMarkdown() throws {
        let adapter = ClaudeCodeAdapter(root: CodingSessionAdapterTests.fixtures.appendingPathComponent("claude/projects"))
        let ref = try XCTUnwrap(adapter.fileRef(claudeFile))
        let meta = try adapter.parseSession(ref).meta
        let md = try CodingSessionExport.render(adapter: adapter, meta: meta)

        XCTAssertTrue(md.hasPrefix("# QR login revamp\n\n"))
        XCTAssertTrue(md.contains("> **Agent**: Claude Code · **Project**: /Users/tester/Github/wakefx(main) · **Time**: "))
        XCTAssertTrue(md.contains("· **Messages**: 3 · **Tokens**: 160\n\n---\n\n"))
        XCTAssertTrue(md.contains("### 👤 User · \(CodingSessionExport.formatTime(CodingParse.isoMs("2026-08-01T10:00:00Z")))\n\n"))
        XCTAssertTrue(md.contains("### 🤖 Assistant"))
        XCTAssertTrue(md.contains("<details><summary>🧠 Thinking</summary>\n\n"))
        XCTAssertTrue(md.contains("<details><summary>🔧 Read — "))
        XCTAssertTrue(md.contains("Input:\n\n```\n"))
        XCTAssertTrue(md.contains("Output:\n\n```\n"))
        XCTAssertTrue(md.contains("### ⚙️ System"))
        XCTAssertTrue(md.contains("> ── Context compacted ──\n\n"))
        XCTAssertEqual(md.components(separatedBy: "### 👤 User").count - 1, 1, "Meta（isMeta caveat）不导出")
    }

    func testTokensAndTimeFormatting() {
        XCTAssertEqual(CodingSessionExport.formatTokens(nil), "-")
        XCTAssertEqual(CodingSessionExport.formatTokens(0), "-")
        XCTAssertEqual(CodingSessionExport.formatTokens(999), "999")
        XCTAssertEqual(CodingSessionExport.formatTokens(1_500), "1.5K")
        XCTAssertEqual(CodingSessionExport.formatTokens(2_300_000), "2.3M")
        XCTAssertEqual(CodingSessionExport.formatTokens(4_000_000_000), "4.0B")
        XCTAssertEqual(CodingSessionExport.formatTime(0), "")
    }

    func testDefaultFileName() {
        var meta = CodingSessionMeta(key: "codex:x", nativeId: "x", agent: .codex, title: "修 a/b: \"登录\" <bug>?  很长的标题",
                                     projectPath: "", projectName: "", filePath: "", createdAt: 0,
                                     updatedAt: CodingParse.isoMs("2026-08-02T12:00:00Z"), messageCount: 0, sizeBytes: 0,
                                     gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil)
        let name = CodingSessionExport.defaultFileName(meta)
        XCTAssertTrue(name.hasPrefix("codex-修 ab 登录 bug 很长的标题-2026080"), name)
        XCTAssertTrue(name.hasSuffix(".md"))
        meta.title = "///"
        XCTAssertTrue(CodingSessionExport.defaultFileName(meta).hasPrefix("codex-session-"))
    }

    func testToolPreviewEscapesAngleBracket() {
        var message = CodingMessage.make(.assistant, .text, "", ts: 0, clip: false)
        message.toolCalls = [CodingToolCall(id: "1", name: "Bash", inputPreview: "echo <x>", input: nil, output: nil, isError: false)]
        let meta = CodingSessionMeta(key: "k", nativeId: "n", agent: .claudeCode, title: "t", projectPath: "", projectName: "",
                                     filePath: "", createdAt: 0, updatedAt: 0, messageCount: 0, sizeBytes: 0, gitBranch: nil,
                                     model: nil, tokensUsed: nil, archived: false, source: nil)
        let md = CodingSessionExport.markdown(meta: meta, messages: [message])
        XCTAssertTrue(md.contains("<summary>🔧 Bash — echo &lt;x></summary>"))
        XCTAssertTrue(md.contains("**Project**: (unknown)"))
    }
}
#endif
