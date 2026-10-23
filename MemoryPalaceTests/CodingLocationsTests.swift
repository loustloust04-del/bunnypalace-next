#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-e 会话位置：照抄 Wake with_custom_root_contract / agent_id_all_matches_ord_and_roster / removed_defaults_suppress_instances /
/// codex_normalize_lifts_sessions_dir_to_home / create_adapters_for_honors_store_config / disabled_location_stays_configured /
/// codex_bare_data_dir_keeps_role / sqlite_custom_root_accepts_db_file / opencode_default_databases_can_be_removed_individually /
/// path_owns_boundaries / custom_roots_roundtrip / disabled_locations_roundtrip；再加 Library 停用出清、重开扫回、提交校验。全在 tmp
@MainActor
final class CodingLocationsTests: XCTestCase {
    private var dir: URL!
    private var home: URL { dir.appendingPathComponent("home") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-locations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func roster(_ overrides: CodingLocationOverrides) -> CodingSessionRoster.Configured {
        CodingSessionRoster.configured(home: home, environment: [:], overrides: overrides)
    }

    func testWithCustomRootContract() throws {
        let custom = dir.appendingPathComponent("somewhere-else")
        for base in CodingSessionRoster.adapters(home: home, environment: [:]) {
            let inst = base.withCustomRoot(custom)
            XCTAssertEqual(inst.agent, base.agent, "\(base.agent)：自定义实例换了家")
            XCTAssertFalse(inst.dataRoots.isEmpty, "\(base.agent)：自定义实例没有数据根")
            for root in inst.dataRoots {
                XCTAssertTrue(CodingLocations.pathOwns(custom.path, root.path), "\(base.agent)：数据根 \(root.path) 溢出自定义目录")
            }
            XCTAssertTrue(inst.listSessionFiles().isEmpty, "\(base.agent)：空目录读出了会话")
        }
        // 直接选中 rollout 日期树：顶层有 YYYY 目录时 dir 本身就是 sessions 根
        let tree = dir.appendingPathComponent("codex-sessions-copy")
        try mkdir(tree.appendingPathComponent("2026"))
        XCTAssertTrue(CodexAdapter.make(home: home, environment: [:]).withCustomRoot(tree).dataRoots.map(\.path).contains(tree.path))
    }

    func testAgentOrderMatchesRoster() {
        let agents = CodingSessionRoster.adapters(home: home, environment: [:]).map(\.agent)
        XCTAssertEqual(agents.count, 16)
        XCTAssertEqual(Set(agents), Set(CodingAgent.allCases), "声明序名单与 roster 的家集合一致")
    }

    func testRemovedDefaultsSuppressInstances() {
        var overrides = CodingLocationOverrides()
        overrides.removedDefaults = [.claudeCode]
        XCTAssertEqual(roster(overrides).active.count, 15)
        XCTAssertFalse(roster(overrides).active.contains { $0.agent == .claudeCode })
        let custom = dir.appendingPathComponent("claude-backup")
        overrides.customRoots = [CodingLocationEntry(agent: "claude-code", path: custom.path)]
        let claude = roster(overrides).active.filter { $0.agent == .claudeCode }
        XCTAssertEqual(claude.count, 1, "默认被压后只剩自定义实例（编辑默认 = 压默认 + 记自定义）")
        XCTAssertTrue(claude.allSatisfy { $0.dataRoots.allSatisfy { CodingLocations.pathOwns(custom.path, $0.path) } })
    }

    func testCodexNormalizeLiftsSessionsDirToHome() throws {
        let codexHome = dir.appendingPathComponent("codex-home")
        try mkdir(codexHome.appendingPathComponent("sessions/2026"))
        try mkdir(codexHome.appendingPathComponent("archived_sessions"))
        try Data("{}".utf8).write(to: codexHome.appendingPathComponent("archived_sessions/rollout-x.jsonl"))
        try Data("x".utf8).write(to: codexHome.appendingPathComponent("state_5.sqlite"))
        XCTAssertEqual(CodingLocations.normalizeCustomRoot(.codex, codexHome.appendingPathComponent("sessions")).path, codexHome.path)
        XCTAssertEqual(CodingLocations.normalizeCustomRoot(.codex, codexHome.appendingPathComponent("archived_sessions")).path, codexHome.path,
                       "平铺 archived 目录也上提到家")
        let bare = dir.appendingPathComponent("codex-copy")
        try mkdir(bare.appendingPathComponent("2026"))
        XCTAssertEqual(CodingLocations.normalizeCustomRoot(.codex, bare).path, bare.path, "裸树不上提")
        let home2 = dir.appendingPathComponent("codex-home-2")
        try mkdir(home2.appendingPathComponent("sessions"))
        try Data("x".utf8).write(to: home2.appendingPathComponent("state_5.sqlite"))
        XCTAssertEqual(CodingLocations.normalizeCustomRoot(.codex, home2.appendingPathComponent("sessions")).path, home2.path, "空 sessions 目录凭名字 + 父级证据上提")
        let lone = dir.appendingPathComponent("lone")
        try mkdir(lone.appendingPathComponent("sessions"))
        XCTAssertEqual(CodingLocations.normalizeCustomRoot(.codex, lone.appendingPathComponent("sessions")).path,
                       lone.appendingPathComponent("sessions").path, "父级没有家目录证据保持原样")
        let whatever = dir.appendingPathComponent("whatever")
        XCTAssertEqual(CodingLocations.normalizeCustomRoot(.claudeCode, whatever).path, whatever.path, "没有整形的家恒等")
    }

    func testConfiguredHonorsOverrides() {
        var overrides = CodingLocationOverrides()
        overrides.customRoots = [CodingLocationEntry(agent: "claude-code", path: "/tmp/claude-backup")]
        overrides.removedDefaults = [.codex]
        let active = roster(overrides).active
        XCTAssertFalse(active.contains { $0.agent == .codex }, "被移除的默认仍在 roster")
        XCTAssertEqual(active.filter { $0.agent == .claudeCode }.count, 2, "自定义位置没生效")
    }

    func testDisabledLocationStaysConfiguredButLeavesActiveRoster() throws {
        let codexHome = dir.appendingPathComponent("codex-copy")
        let sessions = codexHome.appendingPathComponent("sessions")
        let archived = codexHome.appendingPathComponent("archived_sessions")
        try mkdir(sessions)
        try mkdir(archived)
        var overrides = CodingLocationOverrides()
        overrides.customRoots = [CodingLocationEntry(agent: "codex", path: codexHome.path)]
        overrides.disabled = [CodingLocationEntry(agent: "codex", path: sessions.path)]
        let configured = roster(overrides)
        XCTAssertTrue(configured.locations.contains { $0.agent == .codex && $0.path == sessions.path && !$0.enabled })
        XCTAssertTrue(configured.locations.contains { $0.agent == .codex && $0.path == archived.path && $0.enabled })
        let roots = configured.active.filter { $0.agent == .codex }.flatMap(\.dataRoots).map(\.path)
        XCTAssertFalse(roots.contains(sessions.path), "停用的根仍进扫描 roster")
        XCTAssertTrue(roots.contains(archived.path), "同一位置的另一根被误关")
    }

    func testCodexBareDataDirKeepsRole() throws {
        let archived = dir.appendingPathComponent("archived_sessions")
        try mkdir(archived)
        let name = "rollout-2026-08-02T09-15-00-22222222-aaaa-bbbb-cccc-000000000002.jsonl"
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures.appendingPathComponent("codex/sessions/2026/08/02/\(name)"),
                                         to: archived.appendingPathComponent(name))
        let inst = CodexAdapter.make(home: home, environment: [:]).withCustomRoot(archived)
        let refs = inst.listSessionFiles()
        XCTAssertEqual(refs.count, 1, "独立 archived 目录以自身为数据根")
        XCTAssertTrue(try inst.parseSession(try XCTUnwrap(refs.first)).meta.archived, "archived 角色丢失，归档会话被标成活跃")
        let emptySessions = dir.appendingPathComponent("sessions")
        try mkdir(emptySessions)
        XCTAssertTrue(CodexAdapter.make(home: home, environment: [:]).withCustomRoot(emptySessions).dataRoots.map(\.path).contains(emptySessions.path))
    }

    func testSQLiteCustomRootAcceptsDBFile() {
        let db = dir.appendingPathComponent("store.db")
        CodingContract.execSQL(db, "CREATE TABLE t (a TEXT);")
        XCTAssertEqual(CopilotAdapter(home: home).withCustomRoot(db).dataRoots, [db])
        XCTAssertEqual(OpenCodeAdapter.make(home: home, environment: [:]).withCustomRoot(db).dataRoots, [db])
        XCTAssertEqual(AntigravityAdapter(home: home).withCustomRoot(db).dataRoots, [db])
        XCTAssertEqual(HermesAdapter.make(home: home, environment: [:]).withCustomRoot(db).dataRoots, [db])
    }

    func testOpencodeDefaultDatabasesCanBeRemovedIndividually() throws {
        let opencode = home.appendingPathComponent(".local/share/opencode")
        try mkdir(opencode)
        let stable = opencode.appendingPathComponent("opencode.db")
        let next = opencode.appendingPathComponent("opencode-next.db")
        CodingContract.execSQL(stable, OpenCodeAdapterContractTests.stableSQL)
        CodingContract.execSQL(next, OpenCodeAdapterContractTests.nextSQL)
        var overrides = CodingLocationOverrides()
        overrides.removedDefaultRoots = [CodingLocationEntry(agent: "opencode", path: next.path)]
        let adapter = try XCTUnwrap(roster(overrides).active.first { $0.agent == .opencode }, "移除 next 根后 stable 实例仍在")
        XCTAssertTrue(adapter.supportsIndividualRootRemoval)
        XCTAssertEqual(adapter.dataRoots.map(\.path), [stable.path])
        XCTAssertTrue(adapter.listSessionFiles().contains { $0.nativeId == "oc-0001" })
        overrides.removedDefaultRoots.append(CodingLocationEntry(agent: "opencode", path: stable.path))
        XCTAssertFalse(roster(overrides).active.contains { $0.agent == .opencode }, "两条默认库都被移除后不留空实例")
    }

    func testPathOwnsBoundaries() {
        XCTAssertTrue(CodingLocations.pathOwns("/a/sessions", "/a/sessions"))
        XCTAssertTrue(CodingLocations.pathOwns("/a/sessions", "/a/sessions/x.jsonl"))
        XCTAssertFalse(CodingLocations.pathOwns("/a/sessions", "/a/sessions-old/x.jsonl"))
        XCTAssertTrue(CodingLocations.pathOwns("/a/store.db", "/a/store.db#42"))
        XCTAssertTrue(CodingLocations.pathOwns("/", "/anything/below"))
        XCTAssertFalse(CodingLocations.pathOwns("/b", "/a/x"))
        XCTAssertFalse(CodingLocations.pathOwns("", "/a/x"), "空根不拥有任何东西")
        XCTAssertEqual(CodingLocations.expandTilde("~/x", home: "/Users/me"), "/Users/me/x")
        XCTAssertEqual(CodingLocations.expandTilde("~other", home: "/Users/me"), "~other")
        XCTAssertEqual(CodingLocations.tildePath("/Users/me/.claude", home: "/Users/me"), "~/.claude")
        XCTAssertEqual(CodingLocations.tildePath("/Users/me-data/x", home: "/Users/me"), "/Users/me-data/x", "同名前缀的兄弟目录不折")
    }

    func testLocationConfigRoundtrip() {
        let url = dir.appendingPathComponent("state.json")
        let state = CodingSessionState(url: url)
        state.addCustomRoot(agent: .codex, path: "/tmp/a")
        state.addCustomRoot(agent: .codex, path: "/tmp/a")
        state.addCustomRoot(agent: .claudeCode, path: "/tmp/b")
        XCTAssertEqual(Set(state.locationOverrides.customRoots),
                       [CodingLocationEntry(agent: "codex", path: "/tmp/a"), CodingLocationEntry(agent: "claude-code", path: "/tmp/b")], "添加幂等")
        state.removeCustomRoot(agent: .codex, path: "/tmp/a")
        XCTAssertEqual(state.locationOverrides.customRoots, [CodingLocationEntry(agent: "claude-code", path: "/tmp/b")])

        // 编辑的一次落盘：自定义换路径 / 默认改自定义（压整家）/ 可单独移除的默认只压这条根 / 换家
        state.addCustomRoot(agent: .grok, path: "/tmp/g1")
        state.replaceLocation(oldAgent: .grok, oldCustomPath: "/tmp/g1", oldDefaultRoot: nil, oldDataRoot: "/tmp/g1", newAgent: .grok, newPath: "/tmp/g2")
        XCTAssertTrue(state.locationOverrides.customRoots.contains(CodingLocationEntry(agent: "grok", path: "/tmp/g2")))
        XCTAssertFalse(state.locationOverrides.customRoots.contains(CodingLocationEntry(agent: "grok", path: "/tmp/g1")))
        state.replaceLocation(oldAgent: .kiro, oldCustomPath: nil, oldDefaultRoot: nil, oldDataRoot: "/tmp/kiro-default", newAgent: .kiro, newPath: "/tmp/k")
        XCTAssertTrue(state.locationOverrides.removedDefaults.contains(.kiro))
        state.replaceLocation(oldAgent: .opencode, oldCustomPath: nil, oldDefaultRoot: "/tmp/opencode.db", oldDataRoot: "/tmp/opencode.db",
                              newAgent: .opencode, newPath: "/tmp/opencode-copy")
        XCTAssertTrue(state.locationOverrides.removedDefaultRoots.contains(CodingLocationEntry(agent: "opencode", path: "/tmp/opencode.db")))
        state.replaceLocation(oldAgent: .grok, oldCustomPath: "/tmp/g2", oldDefaultRoot: nil, oldDataRoot: "/tmp/g2", newAgent: .cursor, newPath: "/tmp/cur")
        XCTAssertTrue(state.locationOverrides.customRoots.contains(CodingLocationEntry(agent: "cursor", path: "/tmp/cur")))
        XCTAssertFalse(state.locationOverrides.customRoots.contains { $0.agent == "grok" })

        // 停用：幂等、重开删标记、移除自定义连带清它派生根的标记、编辑停用的默认位置后不留旧状态
        state.addCustomRoot(agent: .codex, path: "/tmp/codex-copy")
        state.setLocationEnabled(agent: .codex, path: "/tmp/codex-copy/sessions", enabled: false)
        state.setLocationEnabled(agent: .codex, path: "/tmp/codex-copy/sessions", enabled: false)
        state.setLocationEnabled(agent: .claudeCode, path: "/tmp/claude", enabled: false)
        XCTAssertEqual(state.locationOverrides.disabled.count, 2)
        state.setLocationEnabled(agent: .claudeCode, path: "/tmp/claude", enabled: true)
        XCTAssertEqual(state.locationOverrides.disabled.count, 1)
        state.removeCustomRoot(agent: .codex, path: "/tmp/codex-copy")
        XCTAssertTrue(state.locationOverrides.disabled.isEmpty)
        state.setLocationEnabled(agent: .gemini, path: "/tmp/gemini-default", enabled: false)
        state.replaceLocation(oldAgent: .gemini, oldCustomPath: nil, oldDefaultRoot: nil, oldDataRoot: "/tmp/gemini-default", newAgent: .gemini, newPath: "/tmp/gemini-copy")
        XCTAssertTrue(state.locationOverrides.disabled.isEmpty, "编辑停用的默认位置后遗留了旧状态")

        XCTAssertEqual(CodingSessionState(url: url).locationOverrides, state.locationOverrides, "落盘后重读一致")
        state.clearLocationOverrides()
        XCTAssertEqual(state.locationOverrides, CodingLocationOverrides(), "恢复默认四类一起清")
    }

    func testOldStateFileWithoutLocationFieldsKeepsFavorites() throws {
        let url = dir.appendingPathComponent("old.json")
        try #"{"favorites":["claude-code:x"],"pins":[],"tombstonePaths":[],"tombstoneKeys":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        let state = CodingSessionState(url: url)
        XCTAssertTrue(state.isFavorite("claude-code:x"), "老文件没有位置字段也照常解码")
        XCTAssertEqual(state.locationOverrides, CodingLocationOverrides())
    }

    private func makeLibrary() throws -> (CodingSessionLibrary, CodingSessionState) {
        let claude = home.appendingPathComponent(".claude/projects")
        try mkdir(claude.deletingLastPathComponent())
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures.appendingPathComponent("claude/projects"), to: claude)
        let state = CodingSessionState(url: dir.appendingPathComponent("state.json"))
        let library = CodingSessionLibrary(indexURL: dir.appendingPathComponent("index.sqlite"), state: state, home: home, environment: [:])
        return (library, state)
    }

    func testDisableLocationPrunesRowsAndReenableScansBack() async throws {
        let (library, state) = try makeLibrary()
        await library.refresh()?.value
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let before = try index.countSessions(filter: CodingListFilter())
        XCTAssertGreaterThan(before, 0)
        let row = try XCTUnwrap(library.locationRows().first { $0.agent == .claudeCode })
        XCTAssertEqual(row.count, before)
        XCTAssertTrue(row.exists)
        XCTAssertNil(row.custom)
        XCTAssertFalse(library.locationsDiverged)

        await library.setLocationEnabled(row, enabled: false)?.value
        XCTAssertEqual(try index.countSessions(filter: CodingListFilter()), 0, "停用 = 下轮扫描按磁盘已删出清")
        XCTAssertEqual(library.locationRows().first { $0.agent == .claudeCode }?.enabled, false, "停用的行仍列着")
        XCTAssertTrue(library.locationsDiverged)
        let key = "claude-code:11111111-aaaa-bbbb-cccc-000000000001"
        XCTAssertFalse(state.tombstoneCheck("", key), "出清不写墓碑")

        await library.setLocationEnabled(row, enabled: true)?.value
        XCTAssertEqual(try index.countSessions(filter: CodingListFilter()), before, "重开 = 增量扫回")
        XCTAssertFalse(library.locationsDiverged)
    }

    func testCommitLocationValidation() async throws {
        let (library, state) = try makeLibrary()
        await library.refresh()?.value
        XCTAssertEqual(library.commitLocation(editing: nil, agent: .claudeCode, path: "relative/path"), "请填绝对路径（以 / 或 ~ 开头）")
        XCTAssertEqual(library.commitLocation(editing: nil, agent: .claudeCode, path: home.appendingPathComponent(".claude/projects/sub").path),
                       "这个文件夹已经在会话位置里了", "同家嵌套 = 重复读取")
        let backup = dir.appendingPathComponent("claude-backup")
        try mkdir(backup)
        XCTAssertNil(library.commitLocation(editing: nil, agent: .claudeCode, path: backup.path + "/"))
        XCTAssertTrue(library.locations.contains { $0.agent == .claudeCode && $0.path == backup.path }, "去尾分隔符后记成自定义位置")
        let custom = try XCTUnwrap(library.locationRows().first { $0.custom == backup.path })
        XCTAssertNil(library.commitLocation(editing: custom, agent: .claudeCode, path: backup.path), "没改就算了")
        await library.removeLocation(custom)?.value
        XCTAssertFalse(library.locations.contains { $0.path == backup.path })

        let codexHome = dir.appendingPathComponent("codex-home")
        try mkdir(codexHome.appendingPathComponent("sessions"))
        try Data("x".utf8).write(to: codexHome.appendingPathComponent("state_5.sqlite"))
        XCTAssertNil(library.commitLocation(editing: nil, agent: .codex, path: codexHome.appendingPathComponent("sessions").path))
        XCTAssertEqual(state.locationOverrides.customRoots.last?.path, codexHome.path, "Codex 直选 sessions 上提到家存")

        let claudeDefault = try XCTUnwrap(library.locationRows().first { $0.agent == .claudeCode && $0.custom == nil })
        XCTAssertEqual(library.editPrefill(claudeDefault), claudeDefault.path)
        await library.restoreDefaultLocations()?.value
        XCTAssertEqual(state.locationOverrides, CodingLocationOverrides())
    }
}
#endif
