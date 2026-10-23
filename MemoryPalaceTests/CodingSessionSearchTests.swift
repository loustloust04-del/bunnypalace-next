#if os(macOS)
import XCTest
@testable import 记忆花园

/// N1-b 全文搜索（Wake `db.rs` search_with 两条路径）：fixture 扫进 tmp 索引后查。
final class CodingSessionSearchTests: XCTestCase {
    private var dir: URL!
    private var index: CodingSessionIndex!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let home = dir.appendingPathComponent("home")
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures, to: home)
        index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let adapters: [CodingSessionAdapter] = [
            ClaudeCodeAdapter(root: home.appendingPathComponent("claude/projects")),
            CodexAdapter(sessionsDir: home.appendingPathComponent("codex/sessions"),
                         archivedDir: home.appendingPathComponent("codex/archived_sessions"),
                         stateDB: home.appendingPathComponent("codex/state_5.sqlite")),
            KimiCodeAdapter(root: home.appendingPathComponent("kimi/sessions"), indexPath: home.appendingPathComponent("kimi/session_index.jsonl")),
        ]
        _ = try CodingSessionScanner(index: index, adapters: adapters).run()
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private let claudeKey = "claude-code:11111111-aaaa-bbbb-cccc-000000000001"

    func testTrigramHitCarriesSeqAndHighlight() throws {
        let (hits, degraded) = try index.search("Login.tsx")
        XCTAssertFalse(degraded)
        let hit = try XCTUnwrap(hits.first { $0.meta.key == claudeKey })
        XCTAssertEqual(hit.seq, 2, "seq = 详情消息序号，⌘K 跳转靠它")
        XCTAssertTrue(hit.snippet.contains(CodingSessionIndex.highlightOpen))
        XCTAssertTrue(hit.snippet.contains(CodingSessionIndex.highlightClose))
    }

    func testMultipleSegmentsAreAnded() throws {
        let both = try index.search("useEffect 依赖数组").hits
        XCTAssertFalse(both.isEmpty)
        XCTAssertTrue(both.allSatisfy { $0.snippet.localizedCaseInsensitiveContains("useEffect") || $0.snippet.contains("依赖数组") })
        XCTAssertTrue(try index.search("useEffect 绝对不存在的词组合").hits.isEmpty)
    }

    func testShortSegmentDegradesToLike() throws {
        let (hits, degraded) = try index.search("QR")
        XCTAssertTrue(degraded)
        XCTAssertFalse(hits.isEmpty)
        let snippet = try XCTUnwrap(hits.first?.snippet)
        let open = try XCTUnwrap(snippet.firstIndex(of: CodingSessionIndex.highlightOpen))
        XCTAssertEqual(String(snippet[snippet.index(after: open)...].prefix(2)).uppercased(), "QR")
    }

    func testLikeEscapesWildcards() throws {
        XCTAssertEqual(CodingSessionIndex.escapeLike(#"a%b_c\d"#), #"a\%b\_c\\d"#)
        let (hits, degraded) = try index.search("%%")
        XCTAssertTrue(degraded)
        XCTAssertTrue(hits.allSatisfy { $0.snippet.contains("%%") }, "% 按字面匹配，不是通配")
    }

    func testAgentFilter() throws {
        let hits = try index.search("useEffect", agents: [.kimi]).hits
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.meta.agent == .kimi })
    }

    func testLikeSnippetWindow() {
        let text = String(repeating: "甲", count: 100) + "目标" + String(repeating: "乙", count: 100)
        let snippet = CodingSessionIndex.likeSnippet(text, first: "目标")
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertEqual(snippet.count, 1 + 40 + 1 + 2 + 1 + 80 + 1)
        XCTAssertEqual(CodingSessionIndex.likeSnippet("abc", first: "zz"), "abc")
    }
}
#endif
