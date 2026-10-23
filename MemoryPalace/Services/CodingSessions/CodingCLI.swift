#if os(macOS)
import Foundation

/// `mp-code` 命令行（W-N N6：Wake `cli.rs` + `bin/wake_cli.rs` + `bin/wake_mcp.rs` 合成一个二进制）：argv → 一次工具调用 / MCP server / setup /
/// index。解析、帮助、setup、退出码映射全在这里（也编进 app，单测 `@testable` 直接测）；`mp-code/main.swift` 只调 `main()`。文案恒英文。
///
/// **值一律原样当字符串传**：数字不解析、范围不裁剪、agent 名不认、since 文法不懂——校验与裁剪只在 `CodingTools` 一家。同一个坏参数在 CLI 与
/// MCP 两条路上给同一句话，两条路的输出也才可能逐字节相同（端到端卡着）。命令表与 `CodingTools.definitions(.mcp)` 必须双射（单测卡）
enum CodingCLI {
    static let binaryName = "mp-code"

    /// 与 app 同包同版本：包里起时 Bundle.main 就是 app，单独起读嵌进二进制的 Info.plist（两处都来自 MARKETING_VERSION）
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - 命令表

    enum Arity: Equatable {
        /// 取一个值，重复出现后来者覆盖
        case value
        /// 可重复；拼成逗号串一次写入（agents 参数自己切分 / 去重 / 校验）
        case repeated
        /// 出现即 JSON true；不出现就不写这个键，让工具的默认值生效
        case flag
    }

    struct FlagSpec {
        /// 含前导 `--`
        let long: String
        /// 工具的参数名，必须与 inputSchema 的 property 同名（单测卡）
        let key: String
        let arity: Arity
        /// 帮助里的值占位符；开关用 ""
        let placeholder: String
        /// 帮助里的说明。不写默认值 / 取值区间的数字——那些由定义现渲染
        let help: String
        /// 取值检查（出错时返回整句）。CLI 仅有的值语义只能长在这张表里，别在 parse 里按 key 名写 if
        var validate: ((String) -> String?)?
    }

    struct CommandSpec {
        let name: String
        /// 恒取 `CodingTools` 的常量，不写字面量
        let tool: String
        /// 位置参数的（JSON 键，占位符）；nil = 不收位置参数
        let positional: (key: String, placeholder: String)?
        let flags: [FlagSpec]
        let summary: String
    }

    /// 不走工具的子命令：不收位置参数、不收旗标，因此也不参与双射。Action 就在表里，parse 不必在末尾按名字再认一遍
    struct PlainSpec {
        let name: String
        let action: Action
        let summary: String
    }

    /// 加一个子命令只在这里加一行
    static let plain: [PlainSpec] = [
        PlainSpec(name: "mcp", action: .mcp, summary: "serve these tools over MCP on stdio (what MCP clients run)"),
        PlainSpec(name: "setup", action: .setup, summary: "print this binary's path and how to point an agent at it"),
        PlainSpec(name: "index", action: .index, summary: "build the index once, when \(CodingTools.appName) has never built it here"),
    ]

    private static let fProject = FlagSpec(long: "--project", key: "project", arity: .value, placeholder: "PATH",
                                           help: "one project: an absolute path (use \"$PWD\") or a project name", validate: checkProject)
    private static let fAgent = FlagSpec(long: "--agent", key: "agents", arity: .repeated, placeholder: "ID",
                                         help: "only this agent; repeat the flag or comma-separate")
    private static let fSince = FlagSpec(long: "--since", key: "since", arity: .value, placeholder: "WHEN",
                                         help: "only what was updated at or after WHEN")
    private static let fLimit = FlagSpec(long: "--limit", key: "limit", arity: .value, placeholder: "N", help: "maximum rows to return")
    private static let fStarred = FlagSpec(long: "--starred", key: "starred", arity: .flag, placeholder: "",
                                           help: "only sessions starred in \(CodingTools.appName)")
    private static let fFrom = FlagSpec(long: "--from", key: "from_seq", arity: .value, placeholder: "SEQ",
                                        help: "start at this message seq (a code://…#N reference sets it too)")
    private static let fMessages = FlagSpec(long: "--messages", key: "max_messages", arity: .value, placeholder: "N", help: "messages per page")
    private static let fChars = FlagSpec(long: "--chars", key: "max_chars", arity: .value, placeholder: "N", help: "character budget for the page")
    private static let fMessageChars = FlagSpec(long: "--message-chars", key: "max_message_chars", arity: .value, placeholder: "N",
                                                help: "truncate each message to this many characters")
    private static let fTools = FlagSpec(long: "--tools", key: "include_tools", arity: .flag, placeholder: "",
                                         help: "include tool inputs and outputs")
    private static let fThinking = FlagSpec(long: "--thinking", key: "include_thinking", arity: .flag, placeholder: "",
                                            help: "include the assistant's thinking where the agent recorded it")

    /// 子命令与工具一一对应。加一个工具就在这里加一行，否则单测红
    static let commands: [CommandSpec] = [
        CommandSpec(name: "search", tool: CodingTools.search, positional: (key: "query", placeholder: "QUERY"),
                    flags: [fProject, fAgent, fSince, fLimit], summary: "search transcripts across every indexed session"),
        CommandSpec(name: "sessions", tool: CodingTools.listSessions, positional: nil,
                    flags: [fProject, fAgent, fSince, fLimit, fStarred], summary: "list the most recently updated sessions"),
        CommandSpec(name: "show", tool: CodingTools.getSession, positional: (key: "key", placeholder: "KEY"),
                    flags: [fFrom, fMessages, fChars, fMessageChars, fTools, fThinking], summary: "print one transcript as compact Markdown"),
        CommandSpec(name: "projects", tool: CodingTools.listProjects, positional: nil,
                    flags: [fSince, fLimit], summary: "list projects that have session history"),
    ]

    // MARK: - 类型

    enum Action: Equatable {
        case help, version, mcp, setup
        /// 从零建一次索引。只在索引不存在时——已存在的库归 app 管
        case index
        /// 一次工具调用。args 恒为 JSON 对象，值只有字符串与布尔
        case tool(name: String, args: [String: AnyHashable])
    }

    struct Invocation: Equatable {
        /// `--index`；nil = 默认（用到才求值）
        var index: String?
        /// `--state`；nil = `MP_CODE_STATE` 或默认
        var state: String?
        var action: Action
    }

    enum Stream: Equatable { case stdout, stderr }

    struct Report: Equatable {
        let stream: Stream
        let text: String
        let code: Int32
    }

    /// 已经是给人看的整句（小写开头、不带 `mp-code: ` 前缀）
    struct CLIError: Error, Equatable {
        let message: String
        /// 命令级的错（没给命令 / 命令不认识 / 选项不认识 / 位置参数缺或多）附短 USAGE；「这个选项缺值」一类本身已完整，不附
        let withUsage: Bool

        var report: Report {
            var text = "\(binaryName): \(message)"
            if withUsage { text += "\n\n" + usage }
            return Report(stream: .stderr, text: text, code: 2)
        }
    }

    /// 结果 → 写哪条流、什么退出码。CLI 唯一的这份映射，工具调用与 index 都从这里收场：值不对 = 命令行敲错了，退 2；
    /// 读不出 / 查询炸了 = 跑起来然后失败，退 1
    static func report(_ result: CodingTools.Result) -> Report {
        switch result.kind {
        case .ok: return Report(stream: .stdout, text: result.text, code: 0)
        case .invalidParams: return Report(stream: .stderr, text: "\(binaryName): \(result.text)", code: 2)
        case .failed, .internal: return Report(stream: .stderr, text: "\(binaryName): \(result.text)", code: 1)
        }
    }

    // MARK: - 输出

    /// 文本 → 字节：末尾没换行补一个（search / sessions / projects 收在新鲜度句上、无换行，get_session 自带），除此之外一个字节不加不减
    static func emitBytes(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
        return bytes
    }

    /// 唯一的输出出口：POSIX write 直写（FileHandle 遇 EPIPE 抛 ObjC 异常、Swift 接不住，R-WN6 S4）。0 = 写完，否则 errno
    static func emit(_ text: String, to fd: Int32) -> Int32 {
        writeAll(emitBytes(text), to: fd)
    }

    static func writeAll(_ bytes: [UInt8], to fd: Int32) -> Int32 {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                return errno
            }
            offset += written
        }
        return 0
    }

    /// 报告写出去、给出退出码。下游关掉管道（`mp-code show K | head`）是正常收场，保持原退出码
    static func finish(_ report: Report) -> Int32 {
        let err = emit(report.text, to: report.stream == .stdout ? STDOUT_FILENO : STDERR_FILENO)
        if err == 0 || err == EPIPE { return report.code }
        _ = emit("\(binaryName): \(String(cString: strerror(err)))", to: STDERR_FILENO)
        return 1
    }

    // MARK: - 解析

    private static func fail(_ message: String, usage: Bool) -> CLIError {
        CLIError(message: message, withUsage: usage)
    }

    /// 这个旗标归哪些命令（给「只对 sessions 有效」「要放在命令之后」用）
    private static func flagOwners(_ long: String) -> [String] {
        commands.filter { $0.flags.contains { $0.long == long } }.map(\.name)
    }

    /// 旗标放错地方或根本不认识——三句话一个出口
    private static func misplaced(_ name: String, inCommand: Bool) -> CLIError {
        let owners = flagOwners(name)
        if owners.isEmpty { return fail("unknown option \(name)", usage: true) }
        if !inCommand { return fail("\(name) must come after the command", usage: true) }
        return fail("\(name) is only valid for `\(owners.joined(separator: "` and `"))`", usage: true)
    }

    /// CLI 仅有的取值检查（挂在 --project 上）：`--project .` 在工具那边不算路径，会静默降级成项目名匹配、报「没有匹配的项目」；
    /// 相对路径这边也解不对（符号链接下 getcwd 与 $PWD 不是一回事），干脆直说
    static func checkProject(_ value: String) -> String? {
        let head = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false).first ?? ""
        guard head == "." || head == ".." else { return nil }
        return "--project needs an absolute path or a project name; pass --project \"$PWD\" for the current directory"
    }

    /// 解析途中已经认出的东西：存表行、不存名字，下游不必再认一遍
    private enum Seen {
        case nothing
        case plain(PlainSpec)
        case command(CommandSpec)
    }

    /// argv（不含 argv[0]）→ 一次调用。纯函数：不读环境、不碰文件系统、不退出
    static func parse(_ argv: [String]) -> Result<Invocation, CLIError> {
        var index: String?
        var state: String?
        var seen = Seen.nothing
        var args: [String: AnyHashable] = [:]
        var positional: String?
        var onlyPositional = false
        var it = argv.makeIterator()
        while let a = it.next() {
            if !onlyPositional {
                // 1) 全局：位置无关。--index / --state 后面那个词恒被吃掉（`--index --help` 把 --help 当路径）
                if a == "--index" || a == "--state" {
                    guard let value = it.next() else { return .failure(fail("\(a) needs a path", usage: false)) }
                    if a == "--index" { index = value } else { state = value }
                    continue
                }
                if a.hasPrefix("--index=") {
                    index = String(a.dropFirst("--index=".count))
                    continue
                }
                if a.hasPrefix("--state=") {
                    state = String(a.dropFirst("--state=".count))
                    continue
                }
                if a == "--help" || a == "-h" { return .success(Invocation(index: index, state: state, action: .help)) }
                if a == "--version" || a == "-V" { return .success(Invocation(index: index, state: state, action: .version)) }
                if a == "--" {
                    onlyPositional = true
                    continue
                }
                if a.hasPrefix("-"), a != "-" {
                    var name = a
                    var inline: String?
                    if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                        name = String(a[..<eq])
                        inline = String(a[a.index(after: eq)...])
                    }
                    // 2) 子命令旗标。命令还没出现 = 位置写反了，直说
                    let command: CommandSpec
                    switch seen {
                    case .command(let c): command = c
                    case .plain(let p): return .failure(fail("\(p.name) takes no options (got \(name))", usage: true))
                    case .nothing: return .failure(misplaced(name, inCommand: false))
                    }
                    guard let flag = command.flags.first(where: { $0.long == name }) else {
                        return .failure(misplaced(name, inCommand: true))
                    }
                    let value: String
                    switch (flag.arity, inline) {
                    case (.flag, .some):
                        return .failure(fail("\(name) takes no value", usage: true))
                    case (.flag, .none):
                        args[flag.key] = true
                        continue
                    case (_, .some(let v)):
                        value = v
                    case (_, .none):
                        guard let v = it.next() else { return .failure(fail("\(name) needs a value", usage: false)) }
                        value = v
                    }
                    if let check = flag.validate, let message = check(value) { return .failure(fail(message, usage: false)) }
                    // 就地拼成逗号串：`--agent a --agent b` 与 `--agent a,b` 同义
                    if flag.arity == .repeated, let previous = args[flag.key] as? String {
                        args[flag.key] = previous + "," + value
                        continue
                    }
                    // 原样当字符串传，校验与裁剪交给 CodingTools
                    args[flag.key] = value
                    continue
                }
            }
            // 3) 位置参数：第一个是命令名
            switch seen {
            case .nothing:
                if let p = plain.first(where: { $0.name == a }) {
                    seen = .plain(p)
                } else if let c = commands.first(where: { $0.name == a }) {
                    seen = .command(c)
                } else {
                    return .failure(fail("unknown command \(a)", usage: true))
                }
            case .plain(let p):
                return .failure(fail("\(p.name) takes no arguments (got `\(a)`)", usage: true))
            case .command(let c):
                guard let spec = c.positional else {
                    return .failure(fail("\(c.name) takes no arguments (got `\(a)`)", usage: true))
                }
                if positional != nil {
                    return .failure(fail("\(c.name) takes one \(spec.placeholder) — quote it: \(binaryName) \(c.name) \"…\"", usage: true))
                }
                positional = a
            }
        }
        let command: CommandSpec
        switch seen {
        case .plain(let p): return .success(Invocation(index: index, state: state, action: p.action))
        case .nothing: return .failure(fail("needs a command", usage: true))
        case .command(let c): command = c
        }
        if let spec = command.positional {
            guard let value = positional else { return .failure(fail("\(command.name) needs a \(spec.placeholder)", usage: true)) }
            args[spec.key] = value
        }
        return .success(Invocation(index: index, state: state, action: .tool(name: command.tool, args: args)))
    }

    // MARK: - 帮助

    /// 短用法：命令级错误后附在 stderr。全文另有 `help()`——把几十行参考手册贴在「--limit needs a value」后面是骚扰（单测卡这份的行数）
    static let usage = """
        mp-code — query your 记忆花园 coding-session index from the terminal

        USAGE:
          mp-code search QUERY [OPTIONS]
          mp-code sessions [OPTIONS]
          mp-code show KEY [OPTIONS]
          mp-code projects [OPTIONS]
          mp-code mcp
          mp-code setup
          mp-code --help | --version

        Run `mp-code --help` for every option.
        """

    private static let helpHead = """
        mp-code — query your 记忆花园 coding-session index from the terminal

        记忆花园 indexes every coding-agent session on this machine (Claude Code, Codex,
        Cursor, Gemini CLI and more). This reads that index; it never writes to it.

        USAGE:
          mp-code <command> [ARGS] [OPTIONS]

        COMMANDS:
        """

    private static let helpGlobals = """

        GLOBAL OPTIONS:
          --index PATH        index database (default: 记忆花园's own, ~/Library/Caches/MemoryPalace/coding-index.sqlite)
          --state PATH        session locations, remote hosts and stars (default: ~/Library/Application Support/MemoryPalace/coding-sessions.json)
          --help, -h          print this help
          --version, -V       print the version
          --                  treat everything after it as arguments, not options

        ENVIRONMENT:
          MP_CODE_HOME        read the agents' data under this directory instead of your home
          MP_CODE_STATE       same as --state

        """

    private static let helpWhen = """

        WHEN:
          Relative: 30m, 24h, 7d, 2w. Absolute: 2026-09-01, "2026-09-01 09:30",
          2026-09-01T09:30:00Z. Date-times without a zone are read in local time.
          Values outside a flag's range are clamped, not rejected.

        """

    private static let helpTail = """

        KEYS AND REFERENCES:
          A session key is <agent>:<id>, or <agent>:<host>:<id> for a session mirrored
          from a remote host. `sessions` and `search` print the key of every session
          they list; `search` also prints a reference under each snippet:

              ref: code://session/claude-code:1b2c…#42

          Pass a reference to `show` and the page starts at that message.

        EXAMPLES:
          mp-code sessions --project "$PWD" --limit 5
          mp-code search "useEffect(" --project "$PWD" --since 7d
          mp-code search "rate limiter" --agent codex --agent claude-code
          mp-code show 'code://session/claude-code:1b2c…#42' --tools
          mp-code search -- --dry-run          # a query that starts with a dash

        EXIT CODES:
          0  it ran — including "no matches" and "no such project"
          1  a session could not be read (unknown key, or a transcript that would not parse)
          2  the command line was wrong, or the index is missing / unreadable / too old

        Everything is read-only.
        """

    /// 命令块与选项块的说明列起始列
    private static let commandColumn = 36
    private static let optionColumn = 22

    /// 左列补空格到 width，左列过长时至少留两格
    private static func row(_ left: String, _ right: String, _ width: Int) -> String {
        left + String(repeating: " ", count: max(width - left.count, 2)) + right + "\n"
    }

    /// 某个参数的默认值与取值区间，现从 MCP 定义（Wake 限额）取：帮助里最容易烂掉的就是这些数字，渲染出来至少不会与定义各说各话
    private static func limits(of tool: String, _ key: String, in defs: [ToolDefinition]) -> String {
        guard let spec = defs.first(where: { $0.name == tool })?.properties[key] as? [String: Any] else { return "" }
        var bits: [String] = []
        if let fallback = spec["default"] as? Int { bits.append("default \(fallback)") }
        // 上下界成对才写：from_seq 只有 minimum 0，"at least 0" 是废话
        if let lo = spec["minimum"] as? Int, let hi = spec["maximum"] as? Int { bits.append("\(lo)–\(hi)") }
        return bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))"
    }

    /// 逗号分隔、缩进两格、贪心折到 width 列
    static func wrapped(_ items: [String], width: Int) -> String {
        var out = ""
        var line = "  "
        for (i, item) in items.enumerated() {
            let piece = i + 1 == items.count ? item : item + ","
            if line.count > 2 {
                if line.count + 1 + piece.count > width {
                    out += line + "\n"
                    line = "  "
                } else {
                    line += " "
                }
            }
            line += piece
        }
        return out + line
    }

    /// `--help` 的全文。命令块、各命令的选项块、默认值与取值区间、agent id 全部由命令表与 MCP 定义现渲染，静态散文只剩不含事实的几段
    static func help() -> String {
        let defs = CodingTools.definitions(.mcp)
        var out = helpHead + "\n"
        for c in commands {
            let arg = c.positional.map { " \($0.placeholder)" } ?? ""
            out += row("  \(binaryName) \(c.name)\(arg)", c.summary, commandColumn)
        }
        for p in plain { out += row("  \(binaryName) \(p.name)", p.summary, commandColumn) }
        out += helpGlobals
        for c in commands {
            out += "\n\(c.name) OPTIONS:\n"
            for f in c.flags {
                let left = f.placeholder.isEmpty ? "  \(f.long)" : "  \(f.long) \(f.placeholder)"
                out += row(left, f.help + limits(of: c.tool, f.key, in: defs), optionColumn)
            }
        }
        out += helpWhen
        out += "\nAGENT IDS:\n\(wrapped(CodingAgent.allCases.map(\.rawValue), width: 76))\n"
        out += "  Display names (\"Claude Code\") and a few aliases work too.\n"
        return out + helpTail
    }

    // MARK: - setup

    /// 贴进 CLAUDE.md / AGENTS.md 的那段（Wake AGENT_MEMO 换名）
    static let agentMemo = """
        Earlier sessions with every coding agent on this machine are searchable with
        mp-code. Reach for it when the user asks about an earlier conversation, a past
        decision, why something was done a certain way, where previous work stopped, or
        whether an error has been seen before — git history does not hold that.

            mp-code sessions --project "$PWD" --limit 10
            mp-code search "<terms>" --project "$PWD"
            mp-code show <key>

        `sessions` and `search` print a key for every session; `search` also prints a
        `code://session/<key>#<seq>` reference that `show` accepts. Always pass
        --project "$PWD" — without it every project on the machine is in scope.
        Everything is read-only.
        """

    /// 一段可复制的接入配置
    struct SetupSnippet: Equatable {
        /// 客户端名（"Claude Code"）
        let client: String
        /// 怎么用这段（"Run in a terminal" / "Add to ~/.codex/config.toml"）
        let hint: String
        /// 复制按钮文案——接入页只给按钮不展示片段
        let copyLabel: String
        let text: String
    }

    /// 三家客户端的接入片段（接入页与 `mp-code setup` 同源）。一个二进制兼任 CLI 与 MCP，片段都带 `mcp` 参数；路径按 JSON 串转义
    /// （TOML basic string 与 JSON 的转义子集兼容，含空格与中文的路径都安全），斜杠不转义（R-WN6 I4 / S6）
    static func setupSnippets(binary: String) -> [SetupSnippet] {
        let quoted = jsonQuoted(binary)
        return [
            SetupSnippet(client: "Claude Code", hint: "Run in a terminal", copyLabel: "Copy command",
                         text: "claude mcp add --scope user \(binaryName) -- \(quoted) mcp"),
            SetupSnippet(client: "Codex", hint: "Add to ~/.codex/config.toml", copyLabel: "Copy config",
                         text: "[mcp_servers.\(binaryName)]\ncommand = \(quoted)\nargs = [\"mcp\"]"),
            SetupSnippet(client: "Cursor", hint: "Merge into ~/.cursor/mcp.json", copyLabel: "Copy config",
                         text: "{\n  \"mcpServers\": {\n    \"\(binaryName)\": { \"command\": \(quoted), \"args\": [\"mcp\"] }\n  }\n}"),
        ]
    }

    static func jsonQuoted(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\(s)\""
    }

    /// 把 CLI 放进 PATH 的那一条可粘命令（接入页的复制按钮与 setup 同源）。已经装在 `…/bin` 里、或只剩裸文件名（没有目录可说）时不给
    static func pathCommand(binary: String) -> String? {
        let dir = (binary as NSString).deletingLastPathComponent
        guard !dir.isEmpty, (dir as NSString).lastPathComponent != "bin" else { return nil }
        // 出厂 macOS 的 /usr/local/bin 是 root:wheel，而且可能压根不存在——不带 sudo 的 ln 在干净机器上必然 Permission denied
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \(CodingShellQuote.posix(binary)) /usr/local/bin/\(binaryName)"
    }

    /// `mp-code setup` 要说的事实（调用方查好传进来，函数本身是纯的）
    struct SetupFacts {
        let binary: String
        let index: String
        let state: String
        let home: String
        /// 库打不开的原因；能打开是 nil
        let indexError: String?
    }

    /// 前四行是解析出来的路径（端到端据此自证隔离：home / state / index 三者都在 tmp）
    static func setupText(_ f: SetupFacts) -> String {
        var out = "\(binaryName) binary: \(f.binary)\nIndex database: \(f.index)\nState file: \(f.state)\nAgent data home: \(f.home)\n"
        if let command = pathCommand(binary: f.binary) {
            out += "\n## Put it on your PATH — Run in a terminal\n\n\(command)\n"
        }
        out += "\n## Teach an agent to use it — Paste into the project's CLAUDE.md or AGENTS.md\n\n\(agentMemo)\n"
        out += "\n## Tool-calling clients: prefer MCP — `\(binaryName) mcp` serves the same tools over stdio\n"
        for s in setupSnippets(binary: f.binary) {
            out += "\n### \(s.client) — \(s.hint)\n\n\(s.text)\n"
        }
        if let error = f.indexError { out += "\nNote: \(error)\n" }
        return out
    }

    // MARK: - 改道三件（R-WN6 B1）：`MP_CODE_HOME` / `--state`（`MP_CODE_STATE`）/ `--index`，用到才求值——`--help` / `--version` 不碰文件系统

    static func home(_ environment: [String: String]) -> URL {
        if let custom = environment["MP_CODE_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func stateURL(_ invocation: Invocation, _ environment: [String: String]) -> URL {
        if let path = invocation.state { return URL(fileURLWithPath: path) }
        if let path = environment["MP_CODE_STATE"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return CodingSessionState.defaultURL
    }

    static func indexURL(_ invocation: Invocation) -> URL {
        invocation.index.map { URL(fileURLWithPath: $0) } ?? CodingSessionIndex.defaultURL
    }

    /// 只读解码用户状态（不经 @MainActor 类）：文件不在 = 默认；读不了 / 解不开 = 默认 + 一句提示（R-WN6 I2）
    static func loadState(_ url: URL) -> (snapshot: CodingSessionState.Snapshot, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (CodingSessionState.Snapshot(), nil) }
        do {
            return (try JSONDecoder().decode(CodingSessionState.Snapshot.self, from: Data(contentsOf: url)), nil)
        } catch {
            return (CodingSessionState.Snapshot(), "could not read \(url.path) (\(error.localizedDescription)); using the default session locations")
        }
    }

    /// 状态 → roster：与 app 同一个构造点、同一份映射（位置覆盖 + 启用的远程主机 + 索引旁的远程缓存）——否则自定义根与远程缓存里的会话
    /// 找不到能读它的 adapter
    static func adapters(home: URL, environment: [String: String], snapshot: CodingSessionState.Snapshot, indexURL: URL) -> [CodingSessionAdapter] {
        CodingSessionRoster.configured(home: home, environment: environment, overrides: snapshot.locationOverrides,
                                       remoteHosts: snapshot.enabledRemoteHostNames, cacheRoot: CodingRemote.cacheRoot(indexURL: indexURL)).active
    }

    /// 库打不开时给人看的一句（缺库 / 没建好 / 版本不对 / 系统 SQLite 太旧）
    static func indexProblem(_ error: Error, _ url: URL) -> String {
        switch error {
        case CodingSessionError.indexMissing:
            return "no coding-session index at \(url.path) — open the Code group in \(CodingTools.appName) once to build it, or run `\(binaryName) index`"
        case CodingSessionError.sqliteTooOld(let version):
            return "the system SQLite \(version) is too old (full-text search needs 3.34 or later)"
        default:
            return "the coding-session index at \(url.path) could not be opened or is out of date — open the Code group in \(CodingTools.appName) once to rebuild it"
        }
    }

    /// 本进程可执行文件的真实路径（过软链：从 /usr/local/bin 的链接起的也报包里那份，R-WN6 S5）
    static func executablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return binaryName }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - 执行

    static func setup(_ invocation: Invocation, _ environment: [String: String]) -> String {
        let url = indexURL(invocation)
        var problem: String?
        // 只探库，不必为一行提示把十六家 roster 建起来
        do { _ = try CodingSessionIndex(url: url, readOnly: true) } catch { problem = indexProblem(error, url) }
        return setupText(SetupFacts(binary: executablePath(), index: url.path, state: stateURL(invocation, environment).path,
                                    home: home(environment).path, indexError: problem))
    }

    /// 一次工具调用：只读打开（缺库退 2）→ 读状态 → 与 app 同一条 roster → 与 MCP 同一个入口
    static func runTool(_ name: String, _ args: [String: AnyHashable], _ invocation: Invocation, _ environment: [String: String],
                        warn: (String) -> Void) -> Report {
        let url = indexURL(invocation)
        let index: CodingSessionIndex
        do {
            index = try CodingSessionIndex(url: url, readOnly: true)
        } catch {
            return Report(stream: .stderr, text: "\(binaryName): \(indexProblem(error, url))", code: 2)
        }
        let (snapshot, warning) = loadState(stateURL(invocation, environment))
        if let warning { warn(warning) }
        let roster = adapters(home: home(environment), environment: environment, snapshot: snapshot, indexURL: url)
        let context = CodingTools.Context(index: index, adapters: roster, favorites: snapshot.favorites, nowMs: nowMs(),
                                          cache: CodingTools.TranscriptCache(), limits: .wake)
        return report(CodingTools.invoke(name: name, arguments: args.mapValues(\.base), context: context))
    }

    /// `mp-code mcp`：库打不开直接以一句 stderr 退 2，让客户端的日志说明白
    static func serveMCP(_ invocation: Invocation, _ environment: [String: String], warn: (String) -> Void) -> Int32 {
        let url = indexURL(invocation)
        let index: CodingSessionIndex
        do {
            index = try CodingSessionIndex(url: url, readOnly: true)
        } catch {
            warn(indexProblem(error, url))
            return 2
        }
        let (snapshot, warning) = loadState(stateURL(invocation, environment))
        if let warning { warn(warning) }
        let roster = adapters(home: home(environment), environment: environment, snapshot: snapshot, indexURL: url)
        return CodingMCPServer(index: index, adapters: roster, favorites: snapshot.favorites).serve()
    }

    /// `mp-code index`：建一次，然后说一句人话。建不建、凭什么敢建全在 `indexIfMissing`；失败按内部错误退 1，与工具调用失败同一条出口
    static func runIndex(_ invocation: Invocation, _ environment: [String: String], warn: (String) -> Void) -> Report {
        let url = indexURL(invocation)
        let (snapshot, warning) = loadState(stateURL(invocation, environment))
        if let warning { warn(warning) }
        let roster = adapters(home: home(environment), environment: environment, snapshot: snapshot, indexURL: url)
        let tombstones = (paths: snapshot.tombstonePaths, keys: snapshot.tombstoneKeys)
        do {
            guard let counts = try indexIfMissing(at: url, adapters: roster,
                                                  isTombstoned: { tombstones.paths.contains($0) || tombstones.keys.contains($1) }) else {
                return report(CodingTools.Result(
                    text: "An index already exists at \(url.path). Open the Code group in \(CodingTools.appName) to update or rebuild it.", kind: .ok))
            }
            return report(CodingTools.Result(
                text: "Indexed \(counts.sessions) session\(counts.sessions == 1 ? "" : "s") from \(counts.agents) agent\(counts.agents == 1 ? "" : "s") into \(url.path).\n"
                    + "Open the Code group in \(CodingTools.appName) to keep it current — it watches the agents' files while it runs.",
                kind: .ok))
        } catch {
            return report(CodingTools.Result(text: error.localizedDescription, kind: .internal))
        }
    }

    /// 从零建一次索引（Wake `scanner::build_index`）：**只在库文件不存在时**建，已有库原样留给 app（回 nil；建成回会话数与 agent 家数）。场景是「装了记忆花园但从没
    /// 打开过 code 组」。扫在旁边的 `<库>.build-<pid>`，扫完才用 link(2) 占位——先拿到名字再动任何东西：
    /// ① 中途报错 / 被 agent 超时杀掉，目标路径一个字节都没出现过，下次还能重试；② app 在这几秒里首次建了库，link 直接 EEXIST，丢掉自己那份
    /// 退让，绝不往对方的库里写；③ 不用 rename：rename 无条件覆盖，给不出「已存在即失败」。个别文件系统不给硬链接才退回 rename（只在目标仍空时）。
    /// 名字到手才清孤儿 -wal / -shm（主库被手删留下的旧日志，留着新库会接着读）
    static func indexIfMissing(at url: URL, adapters: [CodingSessionAdapter],
                               isTombstoned: (String, String) -> Bool) throws -> (sessions: Int, agents: Int)? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return nil }
        let staging = url.path + ".build-\(getpid())"
        // 正常收尾、提前抛错两条路都把临时库连同边车删干净；开头先扫一次：pid 会重用，上次被 SIGKILL 留下的同名残骸
        func clearStaging() {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: staging + suffix) }
        }
        clearStaging()
        defer { clearStaging() }
        let counts: (sessions: Int, agents: Int)
        do {
            let index = try CodingSessionIndex(url: URL(fileURLWithPath: staging))
            _ = try CodingSessionScanner(index: index, adapters: adapters).run(full: true, isTombstoned: isTombstoned)
            counts = (try index.countSessions(filter: CodingListFilter()), try index.agentCount())
        } // 关掉最后一个连接即 checkpoint，-wal / -shm 消失，临时库自成一体
        if link(staging, url.path) != 0 {
            let code = errno
            // 有人抢先了（app 首扫 / 另一个 mp-code index）：他的库归他，退让
            if code == EEXIST { return nil }
            guard !fm.fileExists(atPath: url.path) else { return nil }
            try fm.moveItem(atPath: staging, toPath: url.path)
        }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        // 不在本进程里用第二个名字重开这份库：同一 inode 两个名字，SQLite 按 inode 记在进程里的锁 / 共享内存状态会串（实测只读重开报 disk
        // I/O error，另起进程读没事）。收尾那句要的两个数在关连接前就数好了；「建完就能查」由下一个进程验
        return counts
    }

    // MARK: - 进程入口

    /// `mp-code/main.swift` 调这里。argv 走 unsafeArgv + validatingCString：`CommandLine.arguments` 会把非 UTF-8 修成 U+FFFD，而目录名可以
    /// 不是 UTF-8、`--project "$PWD"` 正是主用法（R-WN6 S4）
    static func main() -> Int32 {
        var argv: [String] = []
        for i in stride(from: 1, to: Int(CommandLine.argc), by: 1) {
            guard let raw = CommandLine.unsafeArgv[i] else { continue }
            guard let arg = String(validatingCString: raw) else {
                return finish(CLIError(message: "argument is not valid UTF-8: \(String(cString: raw))", withUsage: false).report)
            }
            argv.append(arg)
        }
        let invocation: Invocation
        switch parse(argv) {
        case .success(let parsed): invocation = parsed
        case .failure(let error): return finish(error.report)
        }
        let environment = ProcessInfo.processInfo.environment
        let warn: (String) -> Void = { _ = emit("\(binaryName): \($0)", to: STDERR_FILENO) }
        switch invocation.action {
        case .help: return finish(Report(stream: .stdout, text: help(), code: 0))
        case .version: return finish(Report(stream: .stdout, text: "\(binaryName) \(version)", code: 0))
        case .setup: return finish(Report(stream: .stdout, text: setup(invocation, environment), code: 0))
        case .index: return finish(runIndex(invocation, environment, warn: warn))
        case .mcp: return serveMCP(invocation, environment, warn: warn)
        case .tool(let name, let args): return finish(runTool(name, args, invocation, environment, warn: warn))
        }
    }
}
#endif
