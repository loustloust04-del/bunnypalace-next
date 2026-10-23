#if os(macOS)
import XCTest
@testable import 记忆花园

/// N1-h 删除 + N1-f 收藏置顶：全在 tmp，废纸篓换成直接删（别把 fixture 挪进她真的废纸篓）。
@MainActor
final class CodingSessionDeleteTests: XCTestCase {
    private var dir: URL!
    private var home: URL { dir.appendingPathComponent("home") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures, to: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeLibrary() -> CodingSessionLibrary {
        let adapters: [CodingSessionAdapter] = [
            ClaudeCodeAdapter(root: home.appendingPathComponent("claude/projects")),
            CodexAdapter(sessionsDir: home.appendingPathComponent("codex/sessions"),
                         archivedDir: home.appendingPathComponent("codex/archived_sessions"),
                         stateDB: home.appendingPathComponent("codex/state_5.sqlite")),
        ]
        let library = CodingSessionLibrary(indexURL: dir.appendingPathComponent("index.sqlite"), adapters: adapters,
                                           state: CodingSessionState(url: dir.appendingPathComponent("state.json")))
        library.recycle = { urls, done in
            for url in urls { try? FileManager.default.removeItem(at: url) }
            done(nil)
        }
        return library
    }

    private let claudeKey = "claude-code:11111111-aaaa-bbbb-cccc-000000000001"

    private func waitForDelete(_ library: CodingSessionLibrary, _ meta: CodingSessionMeta) async -> String?? {
        var result: String??
        library.delete(meta) { result = .some($0) }
        for _ in 0..<60 where result == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return result
    }

    func testDeleteBuriesRemovesAndSelectsNeighbor() async throws {
        let library = makeLibrary()
        await library.refresh()?.value
        let project = "/Users/tester/Github/wakefx"
        library.loadMore(project: project)
        let meta = try XCTUnwrap(library.sessions(in: project).first { $0.key == claudeKey })
        library.select(claudeKey)
        library.toggleFavorite(claudeKey)

        let paths = library.deletionPaths(for: meta)
        XCTAssertEqual(paths, [meta.filePath])
        let result = await waitForDelete(library, meta)
        XCTAssertEqual(result, .some(nil), "删除应成功")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meta.filePath))
        XCTAssertTrue(library.state.tombstoneCheck(meta.filePath, meta.key))
        XCTAssertFalse(library.state.isFavorite(claudeKey), "删了顺手出收藏")
        XCTAssertFalse(library.sessions(in: project).contains { $0.key == claudeKey })
        XCTAssertNotEqual(library.selectedKey, claudeKey, "选中移到同项目的邻居")

        // 同一文件再出现（别的副本 / 恢复）也不复活
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures.appendingPathComponent(
            "claude/projects/-Users-tester-Github-wakefx/11111111-aaaa-bbbb-cccc-000000000001.jsonl"), to: URL(fileURLWithPath: meta.filePath))
        await library.refresh()?.value
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        XCTAssertNil(try index.session(key: claudeKey))
    }

    func testFailedRecycleLeavesEverythingAlone() async throws {
        let library = makeLibrary()
        library.recycle = { _, done in done(NSError(domain: "test", code: 1)) }
        await library.refresh()?.value
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let meta = try XCTUnwrap(try index.session(key: claudeKey))
        let result = await waitForDelete(library, meta)
        XCTAssertNotNil(result ?? nil, "失败要回说明")
        XCTAssertFalse(library.state.tombstoneCheck(meta.filePath, meta.key), "失败不写墓碑")
        XCTAssertNotNil(try index.session(key: claudeKey), "失败不删索引")
        XCTAssertTrue(FileManager.default.fileExists(atPath: meta.filePath))
    }

    func testFavoriteAndPinTogglePersist() {
        let library = makeLibrary()
        library.toggleFavorite("a")
        library.togglePin("b")
        let reloaded = CodingSessionState(url: dir.appendingPathComponent("state.json"))
        XCTAssertTrue(reloaded.isFavorite("a"))
        XCTAssertTrue(reloaded.isPinned("b"))
        library.toggleFavorite("a")
        XCTAssertFalse(CodingSessionState(url: dir.appendingPathComponent("state.json")).isFavorite("a"))
    }
}
#endif
