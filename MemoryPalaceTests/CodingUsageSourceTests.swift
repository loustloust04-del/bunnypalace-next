#if os(macOS)
import XCTest
@testable import 记忆花园

/// 用量页「Code」筛选的数据源：Code 会话索引里的会话级 token → UsageRecord（kind = .code，tokensOnly）。
final class CodingUsageSourceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func meta(_ key: String, agent: CodingAgent, model: String?, tokens: Int64?, updated: Int64,
                      archived: Bool = false) -> CodingSessionMeta {
        CodingSessionMeta(key: key, nativeId: key, agent: agent, title: key, projectPath: "/tmp/p", projectName: "p",
                          filePath: "/tmp/\(key).jsonl", createdAt: updated - 1000, updatedAt: updated,
                          messageCount: 1, sizeBytes: 1, gitBranch: nil, model: model, tokensUsed: tokens,
                          archived: archived, source: nil)
    }

    func testTokenRowsBecomeCodeRecords() throws {
        let url = dir.appendingPathComponent("index.sqlite")
        let index = try CodingSessionIndex(url: url)
        let t0: Int64 = 1_780_000_000_000
        try index.writeSession(meta("claude-code:a", agent: .claudeCode, model: "claude-opus-4-7", tokens: 1200, updated: t0), fileMtime: 1, units: [])
        try index.writeSession(meta("codex:b", agent: .codex, model: nil, tokens: 300, updated: t0 + 5000), fileMtime: 1, units: [])
        try index.writeSession(meta("codex:c", agent: .codex, model: "gpt-5", tokens: nil, updated: t0), fileMtime: 1, units: [])
        try index.writeSession(meta("codex:d", agent: .codex, model: "gpt-5", tokens: 99, updated: t0, archived: true), fileMtime: 1, units: [])
        try index.writeSession(meta("codex:e", agent: .codex, model: "gpt-5", tokens: 77, updated: t0 - 10_000), fileMtime: 1, units: [])

        let rows = try index.tokenUsageRows(sinceMs: t0 - 1)
        XCTAssertEqual(rows.map(\.tokens), [1200, 300], "没 token / 已归档 / 窗外的不要；按时间升序")

        let records = CodeUsageSource.records(indexURL: url, since: Date(timeIntervalSince1970: Double(t0 - 1) / 1000))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].kind, .code)
        XCTAssertTrue(records[0].tokensOnly)
        XCTAssertEqual(records[0].model, "claude-opus-4-7")
        XCTAssertEqual(records[0].providerId, "claude-code")
        XCTAssertEqual(records[0].providerName, "Claude Code")
        XCTAssertEqual(records[0].input, 1200)
        XCTAssertEqual(records[1].model, "(未知模型)")
        XCTAssertEqual(records[0].time, Date(timeIntervalSince1970: Double(t0) / 1000))
    }

    func testMissingIndexYieldsNothing() {
        XCTAssertEqual(CodeUsageSource.records(indexURL: dir.appendingPathComponent("nope/index.sqlite"), since: nil), [])
    }
}
#endif
