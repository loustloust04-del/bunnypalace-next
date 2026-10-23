#if os(macOS)
import XCTest
@testable import 记忆花园

/// N5-b 接线（R-WN5 裁决）：精确四名进权限域（同前缀 MCP 工具不被劫持）、默认不允许 = 不下发、授权只在本机、跳过结果外置、弹卡详情、
/// 缺库清楚报错；远程 @host / starred / 整行格式。**只读她的 UserDefaults，不写**
@MainActor
final class CodingToolsWiringTests: XCTestCase {
    func testPermissionMappingUsesExactNames() {
        for name in CodingTools.names { XCTAssertEqual(PermissionDomain.forTool(named: name), .codingSessions, name) }
        XCTAssertEqual(PermissionDomain.forTool(named: "code_review"), .toolsMaster, "同前缀的 MCP 工具不能被劫持")
        XCTAssertEqual(PermissionDomain.forTool(named: "code_interpreter"), .toolsMaster)
        XCTAssertEqual(PermissionDomain.codingSessions.defaultLevel, .notAllowed, "母 plan：默认关")
        XCTAssertTrue(PermissionDomain.injectionDomains.contains(.codingSessions))
        XCTAssertTrue(ConfigSchema.allScalarEntries.contains { $0.key == "perm.codingSessions" && !$0.aiWritable }, "AI 不可写黑名单")
    }

    func testGrantDoesNotTravelInBackup() {
        XCTAssertEqual(PermissionGrants.strippingDeviceLocal("codingSessions:allow,calendar:allow"), "calendar:allow")
        XCTAssertFalse(PermissionGrants(raw: PermissionGrants.strippingDeviceLocal("codingSessions:allow")).isAllowed(.codingSessions))
    }

    func testRegistryFollowsLevel() {
        XCTAssertTrue(CodingTools.names.isSubset(of: Set(ToolRegistry.all.map(\.definition.name))), "注册表里恒有四条，门控在 enabledIf")
        let names = Set(ToolRegistry.enabledDefinitions(ToolGateContext(family: .anthropic, deferMCP: false)).map(\.name))
        if PermissionCenter.level(.codingSessions) == .notAllowed {
            XCTAssertTrue(names.isDisjoint(with: CodingTools.names), "不允许 = 不下发")
        } else {
            XCTAssertTrue(CodingTools.names.isSubset(of: names), "每次询问 / 自动允许 = 下发")
        }
    }

    func testCodingToolsSkipOffload() {
        for name in CodingTools.names { XCTAssertTrue(ConversationViewModel.skipsOffload(name), name) }
        XCTAssertFalse(ConversationViewModel.skipsOffload("code_review"))
        XCTAssertFalse(ConversationViewModel.skipsOffload("fs_list"))
    }

    func testPermissionDetail() {
        XCTAssertEqual(CodingTools.permissionDetail(name: CodingTools.search, argumentsJSON: #"{"query":"二维码"}"#), "搜索「二维码」")
        XCTAssertEqual(CodingTools.permissionDetail(name: CodingTools.getSession, argumentsJSON: #"{"key":"claude-code:x"}"#), "读会话 claude-code:x")
        XCTAssertEqual(CodingTools.permissionDetail(name: CodingTools.listSessions, argumentsJSON: #"{"project":"/p"}"#), "列最近会话 · /p")
        XCTAssertEqual(CodingTools.permissionDetail(name: CodingTools.search, argumentsJSON: "{\"query\":\"\(String(repeating: "长", count: 200))\"}")?.count, 80)
        XCTAssertNil(CodingTools.permissionDetail(name: "code_review", argumentsJSON: "{}"))
    }

    func testMissingIndexIsAClearError() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/index.sqlite")
        let result = CodingTools.run(name: CodingTools.listSessions, argumentsJSON: "{}", indexURL: missing, adapters: [], favorites: [])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("open the Code group"), result.text)
        XCTAssertThrowsError(try CodingSessionIndex(url: missing, readOnly: true)) { error in
            guard case CodingSessionError.indexMissing = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path), "只读打开不建目录")
    }

    func testInAppLimitsAreTighterThanWake() throws {
        XCTAssertEqual(CodingTools.Limits.inApp.maxCharsDefault, 8_000)
        XCTAssertEqual(CodingTools.Limits.inApp.maxCharsMax, 20_000)
        XCTAssertEqual(CodingTools.Limits.wake, CodingTools.Limits(maxCharsDefault: 20_000, maxCharsMax: 100_000))
        let definition = try XCTUnwrap(CodingTools.definitions.first { $0.name == CodingTools.getSession })
        let maxChars = try XCTUnwrap(definition.properties["max_chars"] as? [String: Any])
        XCTAssertEqual(maxChars["default"] as? Int, 8_000, "app 内下发给模型的 schema 用收紧后的数")
        XCTAssertEqual(maxChars["maximum"] as? Int, 20_000)
    }

    /// 远程 @host（会话行 / 歧义列表）、starred（空 / 非空）、整行格式——本机与「远端缓存」各摆一份 claude 夹具（不经 ssh，直接放进缓存）
    func testStarredRemoteHostAndWholeLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-code-tools-more-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let home = dir.appendingPathComponent("home")
        let indexURL = dir.appendingPathComponent("index.sqlite")
        let cacheRoot = CodingRemote.cacheRoot(indexURL: indexURL)
        for target in [home.appendingPathComponent(".claude/projects"),
                       CodingRemote.hostCacheDir(cacheRoot, host: "devbox").appendingPathComponent(".claude/projects")] {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: CodingSessionAdapterTests.fixtures.appendingPathComponent("claude/projects"), to: target)
        }
        let adapters = CodingSessionRoster.configured(home: home, environment: [:], overrides: CodingLocationOverrides(),
                                                      remoteHosts: ["devbox"], cacheRoot: cacheRoot).active
        do {
            let index = try CodingSessionIndex(url: indexURL)
            _ = try CodingSessionScanner(index: index, adapters: adapters).run(full: true)
        }
        let native = "11111111-aaaa-bbbb-cccc-000000000001"
        let localKey = "claude-code:\(native)"
        func call(_ name: String, _ args: [String: Any], favorites: Set<String> = []) throws -> CodingTools.Result {
            let context = CodingTools.Context(index: try CodingSessionIndex(url: indexURL, readOnly: true), adapters: adapters,
                                              favorites: favorites, nowMs: Int64(Date().timeIntervalSince1970 * 1000), cache: CodingTools.TranscriptCache())
            return CodingTools.invoke(name: name, arguments: args, context: context)
        }

        let noStars = try call(CodingTools.listSessions, ["starred": true])
        XCTAssertTrue(noStars.text.hasPrefix("No sessions (starred)."), noStars.text)
        let starred = try call(CodingTools.listSessions, ["starred": true], favorites: [localKey])
        XCTAssertTrue(starred.text.hasPrefix("1 session (starred) — showing the 1 most recently updated.\n"), starred.text)
        XCTAssertTrue(starred.text.contains("`\(localKey)`") && starred.text.contains("★ starred"), starred.text)

        let listed = try call(CodingTools.listSessions, ["agents": ["claude"]])
        let header = try XCTUnwrap(listed.text.components(separatedBy: "\n").first)
        XCTAssertNotNil(header.range(of: #"^\d+ sessions \(agents claude-code\) — showing the \d+ most recently updated\.$"#, options: .regularExpression), header)
        XCTAssertTrue(listed.text.contains("`claude-code:devbox:\(native)`"), listed.text)
        XCTAssertTrue(listed.text.contains(" · @devbox"), "远程会话行带 @host")

        let ambiguous = try call(CodingTools.getSession, ["key": native])
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("`\(native)` is ambiguous — 2 sessions share that id:"), ambiguous.text)
        XCTAssertTrue(ambiguous.text.contains("(Claude Code @devbox)"), ambiguous.text)

        let projects = try call(CodingTools.listProjects, [:])
        XCTAssertTrue(projects.text.components(separatedBy: "\n").contains { line in
            line.range(of: #"^- /Users/tester/Github/wakefx — wakefx · \d+ sessions? · last active \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil
        }, projects.text)

        let page = try call(CodingTools.getSession, ["key": localKey])
        XCTAssertEqual(page.text.components(separatedBy: "\n").filter { !$0.isEmpty }.last, "End of transcript.", page.text)
    }
}
#endif
