#if os(macOS)
import XCTest
@testable import 记忆花园

/// N6-b2：照抄 Wake `cli.rs` 21 条单测（命令表 ↔ 工具参数双射 / 旗标一致 / 无重名 / argv → JSON / 数字留字符串 / 开关是布尔 / 重复与逗号 agents
/// 合一 / `=` 形式与全局旗标任意位置 / `--` / 旗标归属报错 / 缺值与未知选项 / 位置参数个数 / 相对 project 拒绝 / help 与 version 短路 / help 列全 /
/// report 分流退出码 / emit 至多补一个换行 / 关管道是错误不是崩 / setup 文本 / PATH 命令两条）+ `mcp/mod.rs` 的片段引号（R-WN6 I4）
final class CodingCLITests: XCTestCase {
    /// 故意不给 CLI 子命令的工具（现在没有）。加工具时要么进 commands，要么在这里写明白为什么不进
    private let notInCLI: [String] = []

    private func parse(_ argv: [String]) -> Result<CodingCLI.Invocation, CodingCLI.CLIError> {
        CodingCLI.parse(argv)
    }

    private func args(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) -> [String: AnyHashable] {
        guard case .success(let invocation) = parse(argv), case .tool(_, let args) = invocation.action else {
            XCTFail("expected a tool call for \(argv)", file: file, line: line)
            return [:]
        }
        return args
    }

    private func error(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) -> CodingCLI.CLIError {
        guard case .failure(let error) = parse(argv) else {
            XCTFail("should not parse: \(argv)", file: file, line: line)
            return CodingCLI.CLIError(message: "", withUsage: false)
        }
        return error
    }

    private func message(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) -> String {
        error(argv, file: file, line: line).message
    }

    private func action(_ argv: [String]) -> CodingCLI.Action? {
        if case .success(let invocation) = parse(argv) { return invocation.action }
        return nil
    }

    /// 看家测试：CLI 的旗标表与 MCP 工具的 inputSchema 必须双射。工具加参数、改名、改类型、加第五个，这里就红
    func testEveryToolParameterHasExactlyOneFlag() throws {
        let defs = CodingTools.definitions(.mcp)
        for d in defs where !notInCLI.contains(d.name) {
            let cmd = try XCTUnwrap(CodingCLI.commands.first { $0.tool == d.name }, "\(d.name) 没有 mp-code 子命令；加进 commands 或写进 notInCLI")
            var mine = cmd.flags.map(\.key)
            if let positional = cmd.positional { mine.append(positional.key) }
            XCTAssertEqual(mine.sorted(), d.properties.keys.sorted(), "\(d.name)：CLI 旗标与工具参数对不上")
            // required 只能是位置参数——旗标是可选的
            for required in d.required {
                XCTAssertEqual(required, cmd.positional?.key, "\(d.name)：必填参数 \(required) 在 CLI 里不是位置参数")
            }
            for f in cmd.flags {
                let type = (d.properties[f.key] as? [String: Any])?["type"] as? String ?? ""
                let ok: Bool
                switch f.arity {
                case .flag: ok = type == "boolean"
                case .repeated: ok = type == "array"
                case .value: ok = ["string", "integer", "number"].contains(type)
                }
                XCTAssertTrue(ok, "\(d.name).\(f.key)：arity \(f.arity) 配不上 schema 的 \(type)")
            }
        }
        for c in CodingCLI.commands {
            XCTAssertTrue(defs.contains { $0.name == c.tool }, "commands 里的 \(c.tool) 在定义里不存在")
        }
    }

    func testFlagSpecsAreConsistentAcrossCommands() {
        let all = CodingCLI.commands.flatMap(\.flags)
        for f in all {
            for other in all where other.long == f.long {
                XCTAssertEqual(other.key, f.key, "\(f.long) 在两处映到不同的键")
                XCTAssertEqual(other.arity, f.arity, "\(f.long) 在两处 arity 不同")
                XCTAssertEqual(other.help, f.help, "\(f.long) 在两处说明不同")
            }
        }
    }

    func testNoDuplicateFlagOrCommandNames() {
        let names = CodingCLI.commands.map(\.name) + CodingCLI.plain.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "命令重名")
        for c in CodingCLI.commands {
            let longs = c.flags.map(\.long)
            XCTAssertEqual(Set(longs).count, longs.count, "\(c.name) 的旗标重名")
        }
    }

    func testArgvMapsToTheToolArgumentsObject() {
        XCTAssertEqual(args(["search", "qr login", "--project", "/w", "--agent", "codex", "--limit", "3"]),
                       ["query": "qr login", "project": "/w", "agents": "codex", "limit": "3"])
        XCTAssertEqual(args(["show", "k", "--tools", "--from", "7"]), ["key": "k", "include_tools": true, "from_seq": "7"])
        // 路由 + args 内容 + 「args 恒为对象」一次比完
        XCTAssertEqual(action(["projects"]), .tool(name: CodingTools.listProjects, args: [:]))
        XCTAssertEqual(action(["sessions"]), .tool(name: CodingTools.listSessions, args: [:]))
    }

    /// 整个设计压在这条上：数字不解析，交给工具去认字符串并裁剪
    func testNumericValuesStayStrings() {
        for c in CodingCLI.commands {
            for f in c.flags where f.arity == .value {
                var argv = [c.name]
                if c.positional != nil { argv.append("x") }
                argv += [f.long, "7"]
                XCTAssertEqual(args(argv)[f.key], AnyHashable("7"), "\(c.name) \(f.long) 应当原样传字符串")
            }
        }
    }

    func testSwitchesAreJSONBooleans() {
        XCTAssertEqual(args(["sessions", "--starred"])["starred"], AnyHashable(true))
        XCTAssertEqual(args(["show", "k", "--thinking"])["include_thinking"], AnyHashable(true))
    }

    func testRepeatedAndCommaSeparatedAgentsBecomeOneString() {
        let repeated = args(["search", "x", "--agent", "codex", "--agent", "claude"])
        XCTAssertEqual(repeated["agents"], AnyHashable("codex,claude"))
        XCTAssertEqual(repeated, args(["search", "x", "--agent", "codex,claude"]))
    }

    func testEqualsFormAndGlobalFlagsAnywhere() throws {
        XCTAssertEqual(args(["sessions", "--limit=5"]), args(["sessions", "--limit", "5"]))
        for argv in [["--index=/x", "sessions"], ["sessions", "--index", "/x"]] {
            XCTAssertEqual(try parse(argv).get().index, "/x")
        }
        for argv in [["--state=/s", "sessions"], ["sessions", "--state", "/s"], ["mcp", "--state", "/s"]] {
            XCTAssertEqual(try parse(argv).get().state, "/s")
        }
    }

    func testDoubleDashEndsOptionParsing() {
        XCTAssertEqual(args(["search", "--", "--dry-run"])["query"], AnyHashable("--dry-run"))
    }

    func testFlagsAreRejectedByNameWhenTheyBelongElsewhere() {
        let m = message(["search", "x", "--starred"])
        XCTAssertTrue(m.contains("only valid for `sessions`"), m)
        XCTAssertTrue(message(["--limit", "5", "sessions"]).contains("must come after the command"))
        XCTAssertTrue(message(["projects", "--starred"]).contains("only valid for"))
    }

    /// 缺值的错不附 USAGE、形状错附——有意的不对称
    func testMissingValuesAndUnknownOptionsAreParseErrors() {
        XCTAssertFalse(error(["--index"]).withUsage)
        XCTAssertFalse(error(["--state"]).withUsage)
        XCTAssertFalse(error(["sessions", "--limit"]).withUsage)
        XCTAssertTrue(error(["sessions", "--nope"]).withUsage)
        XCTAssertTrue(message(["sessions", "--nope"]).contains("unknown option"))
        XCTAssertTrue(message(["sessions", "--starred=false"]).contains("takes no value"))
    }

    func testPositionalCountErrors() {
        XCTAssertTrue(message(["search"]).contains("needs a QUERY"))
        XCTAssertTrue(message(["search", "a", "b"]).contains("quote it"))
        XCTAssertTrue(message(["show"]).contains("needs a KEY"))
        XCTAssertTrue(message(["sessions", "x"]).contains("takes no arguments"))
        for plain in ["setup", "index", "mcp"] {
            XCTAssertTrue(message([plain, "x"]).contains("takes no arguments"), plain)
        }
        // 不走工具的子命令不收旗标（全局的除外）
        XCTAssertTrue(message(["index", "--limit", "5"]).contains("takes no options"))
        XCTAssertTrue(message([]).contains("needs a command"))
        XCTAssertTrue(message(["nope"]).contains("unknown command"))
    }

    func testRelativeProjectPathsAreRefusedWithAdvice() {
        for value in [".", "./x", "..", "../x"] {
            XCTAssertTrue(message(["sessions", "--project", value]).contains("$PWD"), "\(value) 应当被拒并给出 $PWD 的写法")
        }
        for value in ["/abs", "~/x", "myname", ".hidden"] {
            XCTAssertEqual(args(["sessions", "--project", value])["project"], AnyHashable(value), "\(value) 应当原样传下去")
        }
    }

    func testHelpAndVersionShortCircuit() {
        XCTAssertEqual(action(["--help", "--nonsense"]), .help)
        XCTAssertEqual(action(["sessions", "-h"]), .help)
        XCTAssertEqual(action(["-V"]), .version)
        XCTAssertEqual(action(["setup"]), .setup)
        XCTAssertEqual(action(["index"]), .index)
        XCTAssertEqual(action(["mcp"]), .mcp)
        XCTAssertLessThan(CodingCLI.usage.split(separator: "\n", omittingEmptySubsequences: false).count, 15, "USAGE 不该长回参考手册")
        XCTAssertFalse(CodingCLI.usage.hasSuffix("\n"))
    }

    func testHelpListsEveryCommandFlagAndAgent() throws {
        let h = CodingCLI.help()
        for c in CodingCLI.commands {
            XCTAssertTrue(h.contains(c.name), "help 缺命令 \(c.name)")
            XCTAssertTrue(h.contains(c.summary))
            for f in c.flags { XCTAssertTrue(h.contains(f.long), "help 缺旗标 \(f.long)") }
        }
        for p in CodingCLI.plain {
            XCTAssertTrue(h.contains(p.name), "help 缺命令 \(p.name)")
            XCTAssertTrue(h.contains(p.summary), "help 缺 \(p.name) 的说明")
        }
        for agent in CodingAgent.allCases { XCTAssertTrue(h.contains(agent.rawValue), "help 缺 agent \(agent.rawValue)") }
        XCTAssertTrue(h.contains("code://session/"))
        XCTAssertTrue(h.contains("EXIT CODES:"))
        // 默认值与取值区间现渲染（MCP 定义 = Wake 限额），不是手写进散文里的
        XCTAssertTrue(h.contains("default 10, 1–30"), "search --limit 的区间没渲染出来")
        XCTAssertTrue(h.contains("default 60, 1–200"), "show --messages 的区间没渲染出来")
        XCTAssertTrue(h.contains("default 20000, 200–100000"), "show --chars 的下界没渲染出来")
        // AGENT IDS 必须落在 WHEN 与 KEYS 之间，不能被甩到文末
        let when = try XCTUnwrap(h.range(of: "\nWHEN:")).lowerBound
        let ids = try XCTUnwrap(h.range(of: "\nAGENT IDS:")).lowerBound
        let keys = try XCTUnwrap(h.range(of: "\nKEYS AND REFERENCES:")).lowerBound
        XCTAssertTrue(when < ids && ids < keys, "help 的段落顺序错了")
        XCTAssertFalse(h.hasSuffix("\n"), "emit 负责补最后那个换行")
        XCTAssertFalse(h.lowercased().contains("wake"), "Wake 的名字都换掉")
    }

    func testReportSplitsArgumentErrorsFromReadFailures() {
        XCTAssertEqual(CodingCLI.report(.init(text: "body", kind: .ok)), CodingCLI.Report(stream: .stdout, text: "body", code: 0))
        XCTAssertEqual(CodingCLI.report(.init(text: "x", kind: .invalidParams)), CodingCLI.Report(stream: .stderr, text: "mp-code: x", code: 2))
        XCTAssertEqual(CodingCLI.report(.init(text: "x", kind: .failed)), CodingCLI.Report(stream: .stderr, text: "mp-code: x", code: 1))
        XCTAssertEqual(CodingCLI.report(.init(text: "x", kind: .internal)), CodingCLI.Report(stream: .stderr, text: "mp-code: x", code: 1))
        XCTAssertEqual(CodingCLI.CLIError(message: "m", withUsage: false).report, CodingCLI.Report(stream: .stderr, text: "mp-code: m", code: 2))
        XCTAssertTrue(CodingCLI.CLIError(message: "m", withUsage: true).report.text.hasSuffix("\n\n" + CodingCLI.usage))
    }

    func testEmitAddsAtMostOneTrailingNewline() {
        for (input, want) in [("a", "a\n"), ("a\n", "a\n"), ("a\n\n", "a\n\n"), ("", "\n")] {
            XCTAssertEqual(String(decoding: CodingCLI.emitBytes(input), as: UTF8.self), want, "input \(input.debugDescription)")
        }
        // 真走一遍 write：读回来的字节就是 emitBytes
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        XCTAssertEqual(CodingCLI.emit("中文 ok", to: fds[1]), 0)
        close(fds[1])
        let out = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "中文 ok\n")
    }

    /// 下游关掉管道要浮成错误让入口去分类，不能崩。写端设 NOSIGPIPE，等同 mp-code 启动时的 SIG_IGN
    func testAClosedPipeSurfacesAsAnErrorNotACrash() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        close(fds[0])
        XCTAssertEqual(CodingCLI.emit("x", to: fds[1]), EPIPE)
        close(fds[1])
    }

    func testSetupTextNamesTheBinaryAndTheGap() {
        let bin = "/Apps/记忆花园.app/Contents/MacOS/mp-code"
        var text = CodingCLI.setupText(.init(binary: bin, index: "/tmp/coding-index.sqlite", state: "/tmp/state.json", home: "/tmp/home",
                                             indexError: nil))
        for needle in [bin, "/tmp/coding-index.sqlite", "/tmp/state.json", "/tmp/home", "--project \"$PWD\"", "claude mcp add",
                       "[mcp_servers.mp-code]", "\"mcpServers\"", "sudo ln -sf"] {
            XCTAssertTrue(text.contains(needle), "setup 缺 \(needle)：\n\(text)")
        }
        XCTAssertFalse(text.contains("Note:"))
        XCTAssertFalse(text.lowercased().contains("wake"))
        text = CodingCLI.setupText(.init(binary: bin, index: "/tmp/x", state: "/tmp/s", home: "/tmp/h",
                                         indexError: "no coding-session index at /tmp/x"))
        XCTAssertTrue(text.trimmingCharacters(in: .newlines).hasSuffix("Note: no coding-session index at /tmp/x"), text)
    }

    func testPathCommandIsPasteableOrAbsent() throws {
        let command = try XCTUnwrap(CodingCLI.pathCommand(binary: "/Apps/记忆花园.app/Contents/MacOS/mp-code"), "包里要给命令")
        XCTAssertTrue(command.contains("mp-code"), command)
        XCTAssertEqual(command.split(separator: "\n").count, 1, "要能一行粘进终端：\(command)")
        XCTAssertNil(CodingCLI.pathCommand(binary: "/usr/bin/mp-code"), "已经在 …/bin 里就不必说了")
        XCTAssertNil(CodingCLI.pathCommand(binary: "mp-code"), "裸名兜底没有目录可言")
    }

    func testPathCommandQuotesSpacesAndSkipsBinDirs() {
        XCTAssertNil(CodingCLI.pathCommand(binary: "/home/me/.local/bin/mp-code"))
        let hint = CodingCLI.pathCommand(binary: "/Apps/My 记忆花园.app/Contents/MacOS/mp-code") ?? ""
        XCTAssertTrue(hint.contains("'/Apps/My 记忆花园.app/Contents/MacOS/mp-code'"), hint)
    }

    /// Wake `snippets_quote_paths_for_every_client`：路径带空格带中文；一个二进制兼任 CLI 与 MCP，三家都带 `mcp` 参数；斜杠不转义
    func testSnippetsQuotePathsForEveryClient() throws {
        let bin = "/Applications/My Apps/记忆花园.app/Contents/MacOS/mp-code"
        let snippets = CodingCLI.setupSnippets(binary: bin)
        XCTAssertEqual(snippets.map(\.client), ["Claude Code", "Codex", "Cursor"])
        XCTAssertEqual(snippets[0].text, "claude mcp add --scope user mp-code -- \"\(bin)\" mcp")
        XCTAssertTrue(snippets[1].text.hasPrefix("[mcp_servers.mp-code]\ncommand = \"/Applications/My Apps/"), snippets[1].text)
        XCTAssertTrue(snippets[1].text.hasSuffix("\nargs = [\"mcp\"]"), snippets[1].text)
        let cursor = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snippets[2].text.utf8)) as? [String: Any], "cursor 片段是合法 JSON")
        let entry = try XCTUnwrap((cursor["mcpServers"] as? [String: Any])?["mp-code"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, bin)
        XCTAssertEqual(entry["args"] as? [String], ["mcp"])
        XCTAssertFalse(snippets.contains { $0.text.contains("\\/") }, "斜杠不转义")
    }

    /// N6-d：接入页复制出去的文本与 `mp-code setup` 同源，界面里不另写一份
    @MainActor
    func testConnectPaneItemsComeFromTheCLI() {
        let bin = "/Applications/记忆花园.app/Contents/MacOS/mp-code"
        let items = CodingConnectPane.items(binary: bin)
        XCTAssertEqual(items.map(\.title), ["Claude Code", "Codex", "Cursor", "放进 PATH"])
        XCTAssertEqual(items.prefix(3).map(\.text), CodingCLI.setupSnippets(binary: bin).map(\.text))
        XCTAssertEqual(items.last?.text, CodingCLI.pathCommand(binary: bin))
        XCTAssertEqual(CodingConnectPane.items(binary: "/usr/local/bin/mp-code").count, 3, "已经在 …/bin 里就不给 PATH 那行")
    }
}
#endif
