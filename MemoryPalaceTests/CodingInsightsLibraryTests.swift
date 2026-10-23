#if os(macOS)
import XCTest
@testable import 记忆花园

/// N2-b：统计整页态——打开即后台算、选会话 / 离开 code 组即关、整页开着时刷新会静默重算。全在 tmp。
@MainActor
final class CodingInsightsLibraryTests: XCTestCase {
    private var dir: URL!
    private var home: URL { dir.appendingPathComponent("home") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-insights-lib-\(UUID().uuidString)")
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
        return CodingSessionLibrary(indexURL: dir.appendingPathComponent("index.sqlite"), adapters: adapters,
                                    state: CodingSessionState(url: dir.appendingPathComponent("state.json")))
    }

    private func waitForInsights(_ library: CodingSessionLibrary, sessions: Int64? = nil) async {
        for _ in 0..<100 {
            if let data = library.insights, !library.insightsLoading, sessions.map({ data.sessions == $0 }) ?? true { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func testToggleComputesAndSelectionOrDeactivateCloses() async throws {
        let library = makeLibrary()
        await library.refresh()?.value
        XCTAssertNil(library.insights, "没打开不算")
        library.toggleInsights()
        XCTAssertTrue(library.isInsightsPresented)
        await waitForInsights(library)
        let data = try XCTUnwrap(library.insights)
        XCTAssertEqual(data.sessions, Int64(library.totalSessions), "与列表同口径（archived 不计）")
        XCTAssertGreaterThan(data.prompts, 0)
        XCTAssertFalse(library.insightsLoading)

        library.toggleInsights()
        XCTAssertFalse(library.isInsightsPresented, "再点入口关")
        library.toggleInsights()
        let key = try XCTUnwrap(library.projects.first.flatMap { project -> String? in
            library.loadMore(project: project.path)
            return library.sessions(in: project.path).first?.key
        })
        library.select(key)
        XCTAssertFalse(library.isInsightsPresented, "选会话回详情")

        library.toggleInsights()
        library.deactivate()
        XCTAssertFalse(library.isInsightsPresented, "离开 code 组关掉")
    }

    func testRefreshWhilePresentedRecomputesSilently() async throws {
        let library = makeLibrary()
        await library.refresh()?.value
        library.toggleInsights()
        await waitForInsights(library)
        let before = try XCTUnwrap(library.insights?.sessions)

        // 删掉一条会话文件 → 刷新 → 整页开着就静默重算（不回到转圈）
        let file = home.appendingPathComponent("claude/projects/-Users-tester-Github-wakefx/44444444-aaaa-bbbb-cccc-000000000004.jsonl")
        try FileManager.default.removeItem(at: file)
        await library.refresh()?.value
        XCTAssertFalse(library.insightsLoading, "已有数据时重算不转圈")
        await waitForInsights(library, sessions: before - 1)
        XCTAssertEqual(library.insights?.sessions, before - 1)
    }
}
#endif
