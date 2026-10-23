#if os(macOS)
import XCTest
@testable import 记忆花园

/// N1-e 列表：筛选 / 任意排序键的 keyset 翻页 / Pinned + 日历分组 / 时间视图与范围 / ⌘K 命中清筛选。全在 tmp。
@MainActor
final class CodingSessionListTests: XCTestCase {
    private var dir: URL!
    private var home: URL { dir.appendingPathComponent("home") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-list-\(UUID().uuidString)")
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

    private func openIndex() throws -> CodingSessionIndex {
        try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
    }

    // MARK: - 索引

    func testKeysetPagingMatchesFullListForEverySort() async throws {
        await makeLibrary().refresh()?.value
        let index = try openIndex()
        for sort in CodingSortKey.allCases {
            for ascending in [false, true] {
                var filter = CodingListFilter()
                filter.sort = sort
                filter.ascending = ascending
                let all = try index.listSessions(projectPath: nil, filter: filter, limit: 1000)
                XCTAssertGreaterThan(all.count, 3)
                var paged: [CodingSessionMeta] = []
                for _ in 0..<100 {
                    let page = try index.listSessions(projectPath: nil, filter: filter, limit: 3, after: paged.last)
                    paged += page
                    if page.count < 3 { break }
                }
                XCTAssertEqual(paged.map(\.key), all.map(\.key), "\(sort) ascending=\(ascending)")
                for (a, b) in zip(all, all.dropFirst()) {
                    let va = filter.sortValue(a), vb = filter.sortValue(b)
                    XCTAssertTrue(ascending ? va <= vb : va >= vb, "\(sort) ascending=\(ascending)")
                    if va == vb { XCTAssertLessThan(a.key, b.key, "同值按 key 升序") }
                }
            }
        }
    }

    func testAgentKeysAndTitleFilters() async throws {
        await makeLibrary().refresh()?.value
        let index = try openIndex()

        var codex = CodingListFilter()
        codex.agents = [.codex]
        let codexRows = try index.listSessions(projectPath: nil, filter: codex, limit: 1000)
        XCTAssertFalse(codexRows.isEmpty)
        XCTAssertTrue(codexRows.allSatisfy { $0.agent == .codex })
        XCTAssertEqual(try index.countSessions(filter: codex), codexRows.count)

        let all = try index.listSessions(projectPath: nil, limit: 1000)
        let pick = try XCTUnwrap(all.first { $0.title.count >= 4 && $0.title != CodingLimits.untitled })
        var title = CodingListFilter()
        title.titleQuery = "  " + String(pick.title.prefix(4)).uppercased() + " "
        let titleRows = try index.listSessions(projectPath: nil, filter: title, limit: 1000)
        XCTAssertTrue(titleRows.contains { $0.key == pick.key }, "两端空白去掉、ASCII 不分大小写")
        XCTAssertTrue(titleRows.allSatisfy(title.matches))

        var byProject = CodingListFilter()
        byProject.titleQuery = pick.projectName
        XCTAssertTrue(try index.listSessions(projectPath: nil, filter: byProject, limit: 1000).contains { $0.key == pick.key }, "项目名也筛")

        var percent = CodingListFilter()
        percent.titleQuery = "%"
        XCTAssertTrue(try index.listSessions(projectPath: nil, filter: percent, limit: 1000)
            .allSatisfy { $0.title.contains("%") || $0.projectName.contains("%") }, "% 当字面量")

        var none = CodingListFilter()
        none.onlyKeys = []
        XCTAssertTrue(try index.listSessions(projectPath: nil, filter: none, limit: 10).isEmpty)
        XCTAssertEqual(try index.countSessions(filter: none), 0)
        XCTAssertTrue(try index.listProjects(filter: none).isEmpty)

        var one = CodingListFilter()
        one.onlyKeys = [pick.key]
        XCTAssertEqual(try index.listSessions(projectPath: nil, filter: one, limit: 10).map(\.key), [pick.key])
        XCTAssertEqual(try index.listProjects(filter: one).map(\.path), [pick.projectPath])
        XCTAssertEqual(try index.listProjects(filter: one).first?.sessionCount, 1, "项目会话数按筛选算")
        XCTAssertFalse(try index.listSessions(projectPath: nil, excludeKeys: [pick.key], limit: 1000).contains { $0.key == pick.key })
    }

    // MARK: - 分组

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 1  // 系统周首日是周日也照样周一起算
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func ms(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
        Int64(date(y, m, d).timeIntervalSince1970 * 1000)
    }

    func testGroupLabelsFollowMondayWeeks() {
        let wednesday = date(2026, 9, 2)
        XCTAssertEqual(CodingSessionGroup.label(ms(2026, 9, 2), now: wednesday, calendar: calendar), "今天")
        XCTAssertEqual(CodingSessionGroup.label(ms(2026, 9, 1), now: wednesday, calendar: calendar), "昨天")
        XCTAssertEqual(CodingSessionGroup.label(ms(2026, 8, 31), now: wednesday, calendar: calendar), "本周")
        XCTAssertEqual(CodingSessionGroup.label(ms(2026, 8, 30), now: wednesday, calendar: calendar), "8月")

        let monday = date(2026, 9, 7)
        XCTAssertEqual(CodingSessionGroup.label(ms(2026, 9, 6), now: monday, calendar: calendar), "昨天")
        XCTAssertEqual(CodingSessionGroup.label(ms(2026, 9, 5), now: monday, calendar: calendar), "9月")
        XCTAssertEqual(CodingSessionGroup.label(ms(2025, 12, 1), now: monday, calendar: calendar), "2025年12月")
    }

    func testGroupsPinnedThenCalendarAndFlatOtherwise() {
        func meta(_ key: String, _ updated: Int64) -> CodingSessionMeta {
            CodingSessionMeta(key: key, nativeId: key, agent: .codex, title: key, projectPath: "/p", projectName: "p", filePath: "/f",
                              createdAt: updated, updatedAt: updated, messageCount: 1, sizeBytes: 1,
                              gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil)
        }
        let sessions = [meta("pinned", ms(2025, 1, 1)), meta("today", ms(2026, 9, 2)), meta("yesterday", ms(2026, 9, 1)),
                        meta("week", ms(2026, 8, 31)), meta("month", ms(2026, 8, 30))]
        let now = date(2026, 9, 2)
        let groups = CodingSessionGroup.build(sessions, pinnedCount: 1, filter: CodingListFilter(), now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.label), ["Pinned", "今天", "昨天", "本周", "8月"])
        XCTAssertEqual(groups[0].range, 0..<1)
        XCTAssertEqual(groups[3].range, 3..<4)

        var byMessages = CodingListFilter()
        byMessages.sort = .messages
        var ascending = CodingListFilter()
        ascending.ascending = true
        for filter in [byMessages, ascending] {
            XCTAssertEqual(CodingSessionGroup.build(sessions, pinnedCount: 1, filter: filter, now: now, calendar: calendar),
                           [CodingSessionGroup(label: "", range: 0..<5)], "按消息数 / 升序平铺")
        }
    }

    // MARK: - Library

    func testTimelinePinsFirstScopesAndPersistsPrefs() async throws {
        let library = makeLibrary()
        await library.refresh()?.value
        library.setListMode(.timeline)
        let all = library.timeline.all
        XCTAssertEqual(all.count, library.filteredTotal)
        let target = try XCTUnwrap(all.last)

        library.togglePin(target.key)
        XCTAssertEqual(library.timeline.pinned.map(\.key), [target.key])
        XCTAssertEqual(library.timeline.all.first?.key, target.key, "置顶排最前")
        XCTAssertEqual(library.timeline.all.count, all.count, "置顶不在后面重复出现")

        library.setScope(.favorites)
        XCTAssertEqual(library.filteredTotal, 0)
        XCTAssertTrue(library.timeline.all.isEmpty)
        library.toggleFavorite(target.key)
        XCTAssertEqual(library.timeline.all.map(\.key), [target.key])

        library.setScope(.agent(.codex))
        XCTAssertFalse(library.timeline.all.isEmpty)
        XCTAssertTrue(library.timeline.all.allSatisfy { $0.agent == .codex })

        library.setSort(.messages, ascending: true)
        let counts = library.timeline.rows.map(\.messageCount)
        XCTAssertEqual(counts, counts.sorted())
        let saved = CodingSessionState(url: dir.appendingPathComponent("state.json")).snapshot
        XCTAssertEqual(saved.listMode, "timeline")
        XCTAssertEqual(saved.sort, "messages")
        XCTAssertEqual(saved.ascending, true)
        XCTAssertEqual(CodingSessionLibrary(indexURL: dir.appendingPathComponent("index.sqlite"), adapters: [],
                                            state: CodingSessionState(url: dir.appendingPathComponent("state.json"))).listMode, .timeline)
    }

    func testProjectViewFiltersProjectsAndPinsInsideProject() async throws {
        let library = makeLibrary()
        await library.refresh()?.value
        library.setScope(.agent(.codex))
        XCTAssertFalse(library.projects.isEmpty)
        let project = try XCTUnwrap(library.projects.first)
        library.loadMore(project: project.path)
        let rows = library.sessions(in: project.path)
        XCTAssertEqual(rows.count, project.sessionCount)
        XCTAssertTrue(rows.allSatisfy { $0.agent == .codex })

        let last = try XCTUnwrap(rows.last)
        library.togglePin(last.key)
        XCTAssertEqual(library.sessions(in: project.path).first?.key, last.key)
        XCTAssertEqual(library.sessions(in: project.path).count, rows.count)
    }

    func testSearchHitOutsideFilterClearsIt() async throws {
        let library = makeLibrary()
        await library.refresh()?.value
        library.setListMode(.timeline)
        library.setScope(.agent(.codex))
        library.setTitleQuery("zzz-no-such-title")
        let claude = try XCTUnwrap(try openIndex().listSessions(projectPath: nil, limit: 100).first { $0.agent == .claudeCode })
        library.open(CodingSessionIndex.SearchHit(meta: claude, seq: 0, role: "user", snippet: "", timestamp: nil))
        XCTAssertEqual(library.scope, .all)
        XCTAssertEqual(library.titleQuery, "")
        XCTAssertTrue(library.timeline.all.contains { $0.key == claude.key })
        XCTAssertEqual(library.revealKey, claude.key)
    }
}
#endif
