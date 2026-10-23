#if os(macOS)
import XCTest
@testable import 记忆花园

/// 编程会话改名（plan-mac-code-mode-gaps §1）：只存在 coding-sessions.json，老文件照读，筛选按改后的名字也命中。全在 tmp
@MainActor
final class CodingTitleOverrideTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("title-override-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func meta(_ key: String, title: String) -> CodingSessionMeta {
        CodingSessionMeta(key: key, nativeId: key, agent: .claudeCode, title: title, projectPath: "/tmp/proj", projectName: "proj",
                          filePath: "/tmp/\(key).jsonl", createdAt: 0, updatedAt: 0, messageCount: 1, sizeBytes: 1,
                          gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil)
    }

    func testOldFileWithoutOverridesDecodes() throws {
        let url = dir.appendingPathComponent("old.json")
        try #"{"favorites":["claude-code:x"],"pins":[],"tombstonePaths":[],"tombstoneKeys":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        let state = CodingSessionState(url: url)
        XCTAssertTrue(state.isFavorite("claude-code:x"), "老文件没有 titleOverrides 也照常解码")
        XCTAssertNil(state.titleOverride("claude-code:x"))
    }

    func testRenameRoundtripAndClear() {
        let url = dir.appendingPathComponent("state.json")
        let state = CodingSessionState(url: url)
        state.setTitle("  液态玻璃  ", for: "k1")
        XCTAssertEqual(state.titleOverride("k1"), "液态玻璃", "去首尾空白")
        XCTAssertEqual(CodingSessionState(url: url).titleOverride("k1"), "液态玻璃", "落盘后重读一致")
        state.setTitle("", for: "k1")
        XCTAssertNil(state.titleOverride("k1"), "空串 = 回到原名")
        XCTAssertNil(state.snapshot.titleOverrides, "清空后不留空字典")
    }

    func testBuryClearsOverride() {
        let state = CodingSessionState(url: dir.appendingPathComponent("s.json"))
        state.setTitle("新名字", for: "k1")
        state.bury(path: "/tmp/k1.jsonl", key: "k1")
        XCTAssertNil(state.titleOverride("k1"))
    }

    func testFilterMatchesRenamedTitle() {
        let state = CodingSessionState(url: dir.appendingPathComponent("s.json"))
        state.setTitle("液态玻璃网页", for: "k1")
        XCTAssertEqual(state.keysWithTitle(matching: "玻璃"), ["k1"])
        XCTAssertEqual(state.keysWithTitle(matching: "  "), [])
        var filter = CodingListFilter()
        filter.titleQuery = "玻璃"
        filter.titleMatchKeys = state.keysWithTitle(matching: "玻璃")
        XCTAssertTrue(filter.matches(meta("k1", title: "做一个网页")), "原名不含关键词，改后的名字含 → 命中")
        XCTAssertFalse(filter.matches(meta("k2", title: "别的")))
    }

    func testFormatPrefersOverride() {
        let m = meta("k1", title: "原名")
        XCTAssertEqual(CodingSessionFormat.title(m, override: "改名"), "改名")
        XCTAssertEqual(CodingSessionFormat.title(m, override: nil), "原名")
        XCTAssertEqual(CodingSessionFormat.title(meta("k2", title: ""), override: nil), "未命名会话")
    }
}
#endif
