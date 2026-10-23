#if os(macOS)
import XCTest
@testable import 记忆花园

/// N6-b4：起包里真的 `记忆花园.app/Contents/MacOS/mp-code`（Wake `tests/cli.rs` 逐条 + `tests/mcp_stdio.rs` 的 stdio 往返，母 plan 验收「stdio
/// 往返测试」）。整套假 home + tmp 索引 + tmp 状态文件，与进程内 `CodingTools.invoke` 同参数的输出**逐字节**比对。
///
/// 隔离（R-WN6 B1）：子进程环境走白名单（不继承；各家的改道 env 一律不带），`--index` / `--state` 显式指 tmp，`MP_CODE_HOME` 与 `HOME` 都指假 home；
/// setup 解析出的三条路径必须都落在 tmp——隔离破了这条先红。参照侧喂自然形态 JSON（数字、布尔、数组），CLI 侧喂字符串与逗号串，
/// 同一条断言顺带卡住工具层认字符串 / 认逗号串这两处宽容
final class CodingCLIEndToEndTests: XCTestCase {
    private static let claudeKey = "claude-code:11111111-aaaa-bbbb-cccc-000000000001"
    private static let project = CodingFakeHome.project
    /// 绝对日期，不用 7d 这类相对量：夹具 mtime 随拷贝时间走
    private static let always = "2000-01-01"
    private static let never = "2999-01-01"

    private struct Fixture {
        let root: URL
        let home: URL
        let index: URL
        let state: URL
        let snapshot: CodingSessionState.Snapshot
    }

    private static var fixture: Fixture?
    private static var fixtureError: Error?

    /// 包里那份（测试宿主就是 app）
    private var binary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(CodingCLI.binaryName)")
    }

    override class func setUp() {
        super.setUp()
        do { fixture = try makeFixture() } catch { fixtureError = error }
    }

    override class func tearDown() {
        if let root = fixture?.root { try? FileManager.default.removeItem(at: root) }
        fixture = nil
        super.tearDown()
    }

    /// 假 home 只建一次、全类共用；状态文件里写一个收藏，让 `--starred` 真有差可比
    private static func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-code-e2e-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try CodingFakeHome.stage(home)
        var snapshot = CodingSessionState.Snapshot()
        snapshot.favorites = [claudeKey]
        let state = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(snapshot).write(to: state)
        let index = root.appendingPathComponent("index.sqlite")
        do {
            let writable = try CodingSessionIndex(url: index)
            let roster = CodingCLI.adapters(home: home, environment: [:], snapshot: snapshot, indexURL: index)
            _ = try CodingSessionScanner(index: writable, adapters: roster).run(full: true)
        } // 块尾关写连接：checkpoint 之后只读打开与字节快照才稳定
        return Fixture(root: root, home: home, index: index, state: state, snapshot: snapshot)
    }

    private func env() throws -> Fixture {
        if let error = Self.fixtureError { throw error }
        let f = try XCTUnwrap(Self.fixture)
        XCTAssertGreaterThan(try CodingSessionIndex(url: f.index, readOnly: true).countSessions(filter: CodingListFilter(), includeArchived: true), 10,
                             "假 home 应当索引出很多会话")
        return f
    }

    /// 白名单环境：不继承测试进程的任何东西
    private func whitelist(_ f: Fixture) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": f.home.path, "MP_CODE_HOME": f.home.path, "LANG": "en_US.UTF-8"]
    }

    /// 唯一的 spawn 实现
    private func run(_ args: [String], environment: [String: String]) throws -> (stdout: String, stderr: String, code: Int32) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // 先读尽再等：输出比管道缓冲大时先 wait 会互等
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), process.terminationStatus)
    }

    /// 冲着夹具库与夹具状态跑
    private func cli(_ f: Fixture, _ args: [String], state: URL? = nil) throws -> (stdout: String, stderr: String, code: Int32) {
        try run(["--index", f.index.path, "--state", (state ?? f.state).path] + args, environment: whitelist(f))
    }

    /// 参照侧：与 CLI 同一条 roster（同一份状态）、同一个工具入口
    private func reference(_ f: Fixture, _ tool: String, _ natural: [String: Any]) throws -> CodingTools.Result {
        let context = CodingTools.Context(index: try CodingSessionIndex(url: f.index, readOnly: true),
                                          adapters: CodingCLI.adapters(home: f.home, environment: [:], snapshot: f.snapshot, indexURL: f.index),
                                          favorites: f.snapshot.favorites, nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                                          cache: CodingTools.TranscriptCache(), limits: .wake)
        return CodingTools.invoke(name: tool, arguments: natural, context: context)
    }

    /// argv 跑出来的东西必须与同参数的工具文本逐字节相同。CLI 最多补一个换行：用算出来的期望值精确相等，不 trim
    private func assertSame(_ f: Fixture, _ argv: [String], _ tool: String, _ natural: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let want = try reference(f, tool, natural)
        XCTAssertEqual(want.kind, .ok, want.text, file: file, line: line)
        let expected = want.text.hasSuffix("\n") ? want.text : want.text + "\n"
        let (stdout, stderr, code) = try cli(f, argv)
        XCTAssertEqual(code, 0, "argv \(argv) 应当成功：\(stderr)", file: file, line: line)
        XCTAssertEqual(stderr, "", "argv \(argv) 跑通时 stderr 必须一个字节都没有", file: file, line: line)
        XCTAssertEqual(stdout, expected, "argv \(argv) 必须原样吐工具文本", file: file, line: line)
    }

    /// 每条 argv 与它对应的自然形态参数；覆盖率那条走这张表
    private func cases() -> [(argv: [String], tool: String, natural: [String: Any])] {
        let reference = "code://session/\(Self.claudeKey)#3"
        return [
            (["search", "二维码", "--limit", "3"], CodingTools.search, ["query": "二维码", "limit": 3]),
            (["search", "二维码", "--project", Self.project, "--agent", "claude", "--since", Self.always, "--limit", "2"], CodingTools.search,
             ["query": "二维码", "project": Self.project, "agents": ["claude"], "since": Self.always, "limit": 2]),
            (["sessions", "--limit", "5"], CodingTools.listSessions, ["limit": 5]),
            (["sessions", "--project", Self.project, "--agent", "claude,codex", "--starred", "--since", Self.always, "--limit", "3"],
             CodingTools.listSessions, ["project": Self.project, "agents": ["claude", "codex"], "starred": true, "since": Self.always, "limit": 3]),
            (["show", Self.claudeKey, "--from", "1", "--messages", "2", "--chars", "5000", "--message-chars", "500", "--tools", "--thinking"],
             CodingTools.getSession, ["key": Self.claudeKey, "from_seq": 1, "max_messages": 2, "max_chars": 5000, "max_message_chars": 500,
                                      "include_tools": true, "include_thinking": true]),
            (["show", reference], CodingTools.getSession, ["key": reference]),
            (["projects", "--since", Self.always, "--limit", "10"], CodingTools.listProjects, ["since": Self.always, "limit": 10]),
        ]
    }

    func testBinaryShipsInsideTheApp() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "包里没有可执行的 \(binary.path)")
    }

    func testEveryCommandPrintsTheToolTextVerbatim() throws {
        let f = try env()
        for c in cases() { try assertSame(f, c.argv, c.tool, c.natural) }
    }

    /// 每个命令、每个旗标都被上面那张表真正跑过一次。与双射单测合起来，「工具新增参数不可能未经测试地发版」才是真的
    func testEveryCommandAndFlagIsExercisedEndToEnd() {
        let table = cases()
        for c in CodingCLI.commands {
            let used = table.filter { $0.argv.first == c.name }.map(\.argv)
            XCTAssertFalse(used.isEmpty, "命令 \(c.name) 没有端到端用例")
            for flag in c.flags {
                XCTAssertTrue(used.contains { $0.contains(flag.long) }, "\(c.name) 的 \(flag.long) 没有端到端用例")
            }
        }
    }

    /// 隔离自证：setup 报出的三条路径都在 tmp 里；二进制路径就是包里那份（过软链）
    func testSetupProvesIsolationAndNeverFails() throws {
        let f = try env()
        let (stdout, stderr, code) = try cli(f, ["setup"])
        XCTAssertEqual(code, 0, stderr)
        func value(_ label: String) -> String? {
            stdout.split(separator: "\n").first { $0.hasPrefix(label) }.map { String($0.dropFirst(label.count)) }
        }
        for label in ["Index database: ", "State file: ", "Agent data home: "] {
            let path = try XCTUnwrap(value(label), "setup 缺 \(label)")
            XCTAssertTrue(path.hasPrefix(f.root.path), "\(label)\(path) 不在 tmp 里——隔离破了")
        }
        XCTAssertEqual(value("mp-code binary: "), binary.resolvingSymlinksInPath().path)
        XCTAssertTrue(stdout.contains("--project \"$PWD\""), stdout)
        XCTAssertTrue(stdout.contains("claude mcp add"), stdout)
        XCTAssertFalse(stdout.contains("Note:"), stdout)
        // 库缺失也照样退 0：「还没装好」正是跑 setup 的人的处境
        let missing = f.root.appendingPathComponent("nope.sqlite")
        let (bare, _, bareCode) = try run(["--index", missing.path, "--state", f.state.path, "setup"], environment: whitelist(f))
        XCTAssertEqual(bareCode, 0)
        XCTAssertTrue(bare.trimmingCharacters(in: .newlines).hasSuffix("or run `mp-code index`"), bare)
    }

    /// 退出码那道决定的全部：argv 敲错与工具认为值不对，对用户是同一件事，都退 2
    func testBadArgumentsExitTwoAndNameTheProblem() throws {
        let f = try env()
        let table: [([String], String)] = [
            (["sessions", "--since", "yesterday"], "`since` not understood"),
            (["sessions", "--agent", "chatgpt"], "unknown agent"),
            (["sessions", "--limit", "abc"], "must be an integer"),
            (["nope"], "unknown command"),
            (["sessions", "--nope"], "unknown option"),
            (["sessions", "--starred=false"], "takes no value"),
            (["search"], "needs a QUERY"),
            (["show"], "needs a KEY"),
            (["search", "x", "--starred"], "only valid for `sessions`"),
            (["sessions", "--project", "."], "$PWD"),
            (["sessions", "myproj"], "takes no arguments"),
        ]
        for (argv, needle) in table {
            let (stdout, stderr, code) = try cli(f, argv)
            XCTAssertEqual(code, 2, "argv \(argv) 应当退 2：\(stderr)")
            XCTAssertTrue(stdout.isEmpty, "argv \(argv) 出错时 stdout 必须为空")
            XCTAssertTrue(stderr.contains(needle), "argv \(argv) 的 stderr 应当提到 \(needle)，实际是 \(stderr)")
            XCTAssertTrue(stderr.hasPrefix("mp-code: "), stderr)
        }
        let (_, stderr, code) = try cli(f, [])
        XCTAssertEqual(code, 2)
        XCTAssertTrue(stderr.contains("needs a command"), stderr)
    }

    /// 读不出来的会话是「跑起来了然后失败」，退 1，且文本与工具同源
    func testUnreadableSessionExitsOne() throws {
        let f = try env()
        let want = try reference(f, CodingTools.getSession, ["key": "claude-code:nope"])
        XCTAssertEqual(want.kind, .failed)
        let (stdout, stderr, code) = try cli(f, ["show", "claude-code:nope"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(stdout.isEmpty)
        XCTAssertEqual(stderr, "mp-code: \(want.text)\n")
    }

    /// 空结果不是错误：`mp-code search x || fallback` 不能因为「这事没讨论过」就触发
    func testNoResultsIsSuccess() throws {
        let f = try env()
        for (argv, prefix) in [(["search", "zzqqxx-no-such-term"], "No matches for"), (["sessions", "--project", "/nope/nope"], "No indexed project matches"),
                               (["sessions", "--since", Self.never], "No sessions"), (["projects", "--since", Self.never], "No projects")] {
            let (stdout, stderr, code) = try cli(f, argv)
            XCTAssertEqual(code, 0, "argv \(argv)：\(stderr)")
            XCTAssertTrue(stdout.hasPrefix(prefix), "argv \(argv) 输出是 \(stdout)")
        }
        let (stdout, _, code) = try cli(f, ["show", Self.claudeKey, "--from", "9999"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.contains("No messages at or after seq 9999"), stdout)
    }

    /// 超范围的数字由工具层裁剪，不是 CLI 拒绝——CLI 若自己校验就会与 MCP 分家
    func testOutOfRangeLimitsAreClampedNotRejected() throws {
        let f = try env()
        try assertSame(f, ["sessions", "--limit", "999"], CodingTools.listSessions, ["limit": 100])
        try assertSame(f, ["search", "二维码", "--limit", "0"], CodingTools.search, ["query": "二维码", "limit": 1])
    }

    /// 状态文件真的在起作用：收藏决定 `--starred`，停用的位置让那家的会话读不出来（R-WN6 B1 / I2）
    func testStateFileDrivesStarsAndLocations() throws {
        let f = try env()
        let (starred, _, code) = try cli(f, ["sessions", "--starred"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(starred.contains(Self.claudeKey), starred)
        let (unstarred, _, noStateCode) = try cli(f, ["sessions", "--starred"], state: f.root.appendingPathComponent("no-state.json"))
        XCTAssertEqual(noStateCode, 0, "状态文件缺失 = 默认")
        XCTAssertFalse(unstarred.contains(Self.claudeKey), unstarred)

        var disabled = f.snapshot
        disabled.disabledLocations = [CodingLocationEntry(agent: CodingAgent.claudeCode.rawValue,
                                                          path: f.home.appendingPathComponent(".claude/projects", isDirectory: true).path)]
        let disabledState = f.root.appendingPathComponent("state-disabled.json")
        try JSONEncoder().encode(disabled).write(to: disabledState)
        let (_, stderr, disabledCode) = try cli(f, ["show", Self.claudeKey], state: disabledState)
        XCTAssertEqual(disabledCode, 1, "claude 的位置停用了，这份会话就没有 adapter 能读")
        XCTAssertTrue(stderr.contains("No adapter can read"), stderr)
        XCTAssertEqual(try cli(f, ["show", Self.claudeKey]).code, 0)

        // 状态文件坏了：照默认跑，stderr 说一句
        let broken = f.root.appendingPathComponent("state-broken.json")
        try Data("{not json".utf8).write(to: broken)
        let (_, brokenErr, brokenCode) = try cli(f, ["projects"], state: broken)
        XCTAssertEqual(brokenCode, 0)
        XCTAssertTrue(brokenErr.contains("using the default session locations"), brokenErr)
    }

    /// 这几条不碰夹具：--help / --version 根本不开库，缺库那条在建 roster 之前就退了
    func testMissingIndexAndHelpNeedNoFixtureHome() throws {
        let f = try env()
        let missing = f.root.appendingPathComponent("nope.sqlite")
        let (stdout, stderr, code) = try run(["--index", missing.path, "sessions"], environment: whitelist(f))
        XCTAssertEqual(code, 2)
        XCTAssertTrue(stdout.isEmpty)
        XCTAssertTrue(stderr.contains("run `mp-code index`"), stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "查询绝不建库")

        let (help, helpErr, helpCode) = try run(["--help"], environment: [:])
        XCTAssertEqual(helpCode, 0)
        XCTAssertEqual(helpErr, "")
        XCTAssertEqual(help, CodingCLI.help() + "\n")

        let (version, _, versionCode) = try run(["--version"], environment: [:])
        XCTAssertEqual(versionCode, 0)
        XCTAssertEqual(version, "mp-code \(CodingCLI.version)\n", "与 app 同版本")
    }

    /// `CommandLine.arguments` 会把非 UTF-8 修成 U+FFFD，而 `--project "$PWD"` 正是主用法：必须退 2 而不是拿修过的串去查
    func testNonUTF8ArgumentsExitTwoInsteadOfBeingRepaired() throws {
        let f = try env()
        let (stderr, code) = try runRaw([Array("sessions".utf8), Array("--project".utf8), Array("/tmp/caf".utf8) + [0xE9]], environment: whitelist(f))
        XCTAssertEqual(code, 2)
        XCTAssertTrue(stderr.hasPrefix("mp-code: argument is not valid UTF-8"), stderr)
    }

    /// 一旦有人把可写打开摸进查询路径，或者把 `index` 那道口子放宽到已存在的库上，这条就红
    func testTheCLINeverWritesAnIndexThatExists() throws {
        let f = try env()
        let before = try Data(contentsOf: f.index)
        for argv in [["sessions", "--limit", "3"], ["search", "二维码"], ["show", Self.claudeKey], ["projects"], ["index"]] {
            let (stdout, stderr, code) = try cli(f, argv)
            XCTAssertEqual(code, 0, "\(argv)：\(stderr)")
            if argv == ["index"] { XCTAssertTrue(stdout.hasPrefix("An index already exists"), stdout) }
        }
        XCTAssertEqual(try Data(contentsOf: f.index), before, "mp-code 绝不写已存在的索引")
    }

    /// 这条口子存在的唯一理由：装了记忆花园但从没建过索引。库不存在时建一次、建完立刻可查；认状态里停用的位置与墓碑；库已存在就退让
    func testIndexBuildsOneFromScratchThenDefers() throws {
        let f = try env()
        let fixtureIndex = try CodingSessionIndex(url: f.index, readOnly: true)
        let codex = try XCTUnwrap(fixtureIndex.listSessions(projectPath: nil, filter: CodingListFilter(agents: [.codex]), includeArchived: true,
                                                            limit: 50).first, "夹具里有 codex 会话")
        XCTAssertNotNil(try fixtureIndex.session(key: Self.claudeKey))

        var snapshot = f.snapshot
        snapshot.disabledLocations = [CodingLocationEntry(agent: CodingAgent.claudeCode.rawValue,
                                                          path: f.home.appendingPathComponent(".claude/projects", isDirectory: true).path)]
        snapshot.tombstoneKeys = [codex.key]
        snapshot.tombstonePaths = [codex.filePath]
        let dir = f.root.appendingPathComponent("fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = dir.appendingPathComponent("state.json")
        try JSONEncoder().encode(snapshot).write(to: state)
        let fresh = dir.appendingPathComponent("fresh.sqlite")
        // 主库不在、边车还躺着（主库被手删）：留下任何一个，新库都会接着读旧日志
        for suffix in ["-wal", "-shm"] { try Data("stale".utf8).write(to: URL(fileURLWithPath: fresh.path + suffix)) }

        let (stdout, stderr, code) = try run(["--index", fresh.path, "--state", state.path, "index"], environment: whitelist(f))
        XCTAssertEqual(code, 0, stderr)
        XCTAssertTrue(stdout.hasPrefix("Indexed "), stdout)
        XCTAssertTrue(stdout.contains("into \(fresh.path)"), stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "应当真的建出库来")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.contains(".build-") }, "临时库没收干净：\(names)")
        for suffix in ["-wal", "-shm"] {
            if let bytes = FileManager.default.contents(atPath: fresh.path + suffix) {
                XCTAssertNotEqual(bytes, Data("stale".utf8), "\(suffix) 还是那份孤儿日志")
            }
        }
        let built = try CodingSessionIndex(url: fresh, readOnly: true)
        XCTAssertNil(try built.session(key: Self.claudeKey), "停用的位置不进库")
        XCTAssertNil(try built.session(key: codex.key), "墓碑不复活")
        XCTAssertGreaterThan(try built.countSessions(filter: CodingListFilter(), includeArchived: true), 5, "其余各家照常入库")

        // 建完就能查，不必先打开 app
        let (projects, _, projectsCode) = try run(["--index", fresh.path, "--state", state.path, "projects"], environment: whitelist(f))
        XCTAssertEqual(projectsCode, 0)
        XCTAssertTrue(projects.contains(Self.project), projects)
        // 第二次是退让，不是重建
        let (again, _, againCode) = try run(["--index", fresh.path, "--state", state.path, "index"], environment: whitelist(f))
        XCTAssertEqual(againCode, 0)
        XCTAssertTrue(again.hasPrefix("An index already exists"), again)
    }

    /// 远程主机的会话经状态文件里的主机表进 roster：镜像缓存在索引旁 `remotes/<host>/`（N4 布局）；状态里没有这台主机，这份会话就没有
    /// adapter 能读——证明 CLI 读的是同一份主机表
    func testRemoteHostSessionsComeFromTheStateFile() throws {
        let f = try env()
        let dir = f.root.appendingPathComponent("remote-\(UUID().uuidString)")
        let index = dir.appendingPathComponent("index.sqlite")
        let cache = CodingRemote.hostCacheDir(CodingRemote.cacheRoot(indexURL: index), host: "devbox")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.home.appendingPathComponent(".claude/projects"), to: cache.appendingPathComponent(".claude/projects"))
        var snapshot = CodingSessionState.Snapshot()
        snapshot.remoteHosts = [CodingRemoteHost(name: "devbox", enabled: true, addedAt: 0, lastSyncAt: nil, lastSyncError: nil)]
        let state = dir.appendingPathComponent("state.json")
        try JSONEncoder().encode(snapshot).write(to: state)
        do {
            let writable = try CodingSessionIndex(url: index)
            let roster = CodingCLI.adapters(home: f.home, environment: [:], snapshot: snapshot, indexURL: index)
            _ = try CodingSessionScanner(index: writable, adapters: roster).run(full: true)
        }
        let remoteKey = "claude-code:devbox:11111111-aaaa-bbbb-cccc-000000000001"
        XCTAssertNotNil(try CodingSessionIndex(url: index, readOnly: true).session(key: remoteKey), "远端那份没入库")

        let (shown, shownErr, shownCode) = try run(["--index", index.path, "--state", state.path, "show", remoteKey], environment: whitelist(f))
        XCTAssertEqual(shownCode, 0, shownErr)
        XCTAssertTrue(shown.contains(remoteKey), shown)
        let (listed, _, listedCode) = try run(["--index", index.path, "--state", state.path, "sessions", "--agent", "claude", "--limit", "50"],
                                              environment: whitelist(f))
        XCTAssertEqual(listedCode, 0)
        XCTAssertTrue(listed.contains(remoteKey), listed)

        let noHosts = f.root.appendingPathComponent("no-state.json")
        let (_, missingErr, missingCode) = try run(["--index", index.path, "--state", noHosts.path, "show", remoteKey], environment: whitelist(f))
        XCTAssertEqual(missingCode, 1, "状态里没有这台主机：roster 里没有 @devbox 的实例")
        XCTAssertTrue(missingErr.contains("No adapter can read"), missingErr)
    }

    /// 母 plan 验收「stdio 往返」：用 MP 自己的 MCP 客户端（W-M 的本地命令传输）起包里的 `mp-code mcp`，走握手 / tools/list / tools/call
    @MainActor
    func testMCPClientRoundTripOverStdio() async throws {
        let f = try env()
        let command = [binary.path, "mcp", "--index", f.index.path, "--state", f.state.path].map(CodingShellQuote.single).joined(separator: " ")
        // 这条传输会继承登录 shell 的环境：各家改道 env 一律清空，home 指假 home
        var extra = ["MP_CODE_HOME": f.home.path, "HOME": f.home.path]
        for key in ["CODEX_HOME", "XDG_DATA_HOME", "QODER_CONFIG_DIR", "HERMES_HOME", "OPENCLAW_STATE_DIR", "OPENCODE_DB"] { extra[key] = "" }
        let transport = try MCPStdioTransport(command: command, env: extra)
        let client = MCPClient(name: "mp-code-e2e", version: "0", requestTimeout: 20)
        try await client.connect(transport: transport)
        defer { client.disconnect() }
        XCTAssertEqual(client.serverInfo["name"] as? String, "mp-code")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), [CodingTools.search, CodingTools.listSessions, CodingTools.getSession, CodingTools.listProjects])
        let hit = try await client.callTool(name: CodingTools.search, arguments: ["query": "二维码", "agents": ["claude"], "project": Self.project])
        XCTAssertFalse(hit.isError, hit.flattenedText)
        XCTAssertTrue(hit.flattenedText.contains("ref: code://session/\(Self.claudeKey)#"), hit.flattenedText)
        let missing = try await client.callTool(name: CodingTools.getSession, arguments: ["key": "claude-code:nope"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.flattenedText.contains("No session with key"), missing.flattenedText)
    }

    /// Foundation 的 Process 只收 String 参数，送不出非 UTF-8 的字节：这条用 posix_spawn 直接起
    private func runRaw(_ args: [[UInt8]], environment: [String: String]) throws -> (stderr: String, code: Int32) {
        func cString(_ bytes: [UInt8]) -> UnsafeMutablePointer<CChar>? {
            (bytes + [0]).withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { strdup($0) }
            }
        }
        var errPipe: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&errPipe), 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, errPipe[0])
        let argv = ([Array(binary.path.utf8)] + args).map(cString) + [nil]
        let envp = environment.map { cString(Array("\($0.key)=\($0.value)".utf8)) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary.path, &actions, nil, argv, envp)
        close(errPipe[1])
        guard rc == 0 else {
            close(errPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        let data = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (String(decoding: data, as: UTF8.self), (status >> 8) & 0xff)
    }
}
#endif
