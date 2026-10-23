#if os(macOS)
import Foundation

// Portions adapted from Wake v0.6.3 (MIT, Copyright (c) 2026 Corey Chiu, github.com/iAmCorey/Wake) — see THIRD_PARTY_LICENSES.md
/// 编程会话的 AI 工具（N5，Wake `mcp/tools.rs`）：四个只读工具的定义与执行。输出全是 Markdown 文本，**逐字照 Wake 的英文格式**（给模型读，
/// 不是界面文案；N6 的 mp-code 复用同一套渲染），只换三处：工具名 `code_*`、引用 scheme `code://session/`、新鲜度句里的应用名。
/// 错误三类（Wake `ToolError`）：参数形状不对 / 执行失败（坏 key、解析失败）/ 内部错误（查询失败）；app 内一律回 isError 让模型重发或换参数，mp-code 按类别分退出码与协议错误码；「没匹配上项目」「没有结果」不是错误，
/// 照常回带提示的文本。全程只读：索引走只读连接，转录现场从各家文件解析
enum CodingTools {
    static let search = "code_search"
    static let listSessions = "code_list_sessions"
    static let getSession = "code_get_session"
    static let listProjects = "code_list_projects"
    static let names: Set<String> = [search, listSessions, getSession, listProjects]
    static let refPrefix = "code://session/"
    static let appName = "记忆花园"

    static let maxSearchSessions = 30
    static let maxListSessions = 100
    static let maxListProjects = 200
    static let snippetsPerSession = 3

    /// get_session 的 max_chars 默认 / 上限：外部 agent（N6 的 MCP / CLI）照 Wake；app 内 tool loop 一轮最多 8 次、每轮重发前面全部结果，
    /// 收紧（R-WN5 #5：按 Wake 默认页连翻 8 页单回合约 25 万输入 token）
    struct Limits: Equatable {
        var maxCharsDefault: Int
        var maxCharsMax: Int
        static let wake = Limits(maxCharsDefault: 20_000, maxCharsMax: 100_000)
        static let inApp = Limits(maxCharsDefault: 8_000, maxCharsMax: 20_000)
    }

    /// 进程级单槽转录缓存（Wake 的缓存随 server 进程长驻；app 内每次调用都新建等于没有缓存）
    static let sharedCache = TranscriptCache()

    /// app 内执行入口（W-N N5，后台线程调）：新开只读连接（NOMUTEX 单连接不跨线程共享）；库不存在 / 没建好回英文 isError（给模型读）
    static func run(name: String, argumentsJSON: String, indexURL: URL, adapters: [CodingSessionAdapter], favorites: Set<String>,
                    nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Result {
        let index: CodingSessionIndex
        do {
            index = try CodingSessionIndex(url: indexURL, readOnly: true)
        } catch {
            return Result(text: "The coding-session index is not available yet — open the Code group in \(appName) once to build it.", kind: .failed)
        }
        let context = Context(index: index, adapters: adapters, favorites: favorites, nowMs: nowMs, cache: sharedCache, limits: .inApp)
        return invoke(name: name, argumentsJSON: argumentsJSON, context: context)
    }

    /// 「每次询问」弹卡的详情：模型这次要查什么（截 80 字，R-WN5 #10）
    static func permissionDetail(name: String, argumentsJSON: String) -> String? {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let text: String
        switch name {
        case search: text = "搜索「\((args["query"] as? String) ?? "")」"
        case listSessions: text = "列最近会话" + ((args["project"] as? String).map { " · \($0)" } ?? "")
        case getSession: text = "读会话 " + ((args["key"] as? String) ?? "")
        case listProjects: text = "列项目"
        default: return nil
        }
        return String(text.prefix(80))
    }

    /// 类别决定 mp-code 怎么收场（Wake `ToolError`）：参数错 = CLI 退 2 / MCP -32602，执行失败 = 退 1 / isError 结果，内部错误 = 退 1 / -32603；
    /// app 内分发只看 isError
    struct Result: Equatable {
        enum Kind: Equatable { case ok, invalidParams, failed, `internal` }
        let text: String
        let kind: Kind
        var isError: Bool { kind != .ok }
    }

    /// 一次调用要的东西：只读索引连接、当前 roster（按会话找实例解析转录，含远程）、收藏快照、此刻、单槽转录缓存
    struct Context {
        let index: CodingSessionIndex
        let adapters: [CodingSessionAdapter]
        let favorites: Set<String>
        let nowMs: Int64
        let cache: TranscriptCache
        var limits: Limits = .wake
    }

    enum ToolError: Error {
        case invalidParams(String)
        case failed(String)
    }

    // MARK: - 定义（参数名是契约，与 Wake 一致）
    // 两份定义出自同一组参数 builder（R-WN6 S8）：app 内下发给模型的是中文描述 + app 内限额（N5），mp-code 的 MCP 定义是 Wake 英文原文
    // （换工具名、引用 scheme、应用名）+ Wake 限额（N6）。两份只差描述、title 与 get_session 的 max_chars 上限 / 默认

    enum Flavor { case app, mcp }

    private struct Texts {
        let project, agents, since: String
        let searchQuery, searchLimit, search: String
        let starred, listSessions: String
        let key, fromSeq, maxMessages, maxChars, maxMessageChars, includeTools, includeThinking, getSession: String
        let listProjects: String
    }

    /// 中文，写清「什么时候用」
    private static let appTexts = Texts(
        project: "限定到一个项目。最好传绝对路径——当前工作目录就行：会匹配包含它的已索引项目，或它下面的全部项目；也可以传项目名。不传 = 全部项目。",
        agents: "只看这些编程 agent 的会话（取值见列表）。不传 = 全部。",
        since: "只看这个时间之后更新过的会话：相对量（30m、24h、7d、2w）或 ISO 日期 / 时间（2026-09-01、2026-09-01T09:30:00Z）。",
        searchQuery: "搜索词。短于 3 个字符的词会退回较慢的子串扫描。",
        searchLimit: "最多返回多少个会话。",
        search: "全文搜索这台 Mac 上索引过的全部编程 agent 会话（Claude Code、Codex、Cursor、Gemini CLI 等：用户提问、助手回复、工具名与输入）。用户问某件事以前讨论过 / 试过 / 解决过没有，或者要找关于某个话题、报错、文件、决定的那段对话时用它——这些 git 历史里没有。多个词取交集；中文与 `useEffect(` 这类代码片段都能搜。返回匹配的会话，每个最多 3 条片段，每条片段带一个 `code://session/<key>#<seq>` 引用，可以交给 code_get_session 读。",
        starred: "只看用户收藏的会话。",
        listSessions: "最近更新的编程 agent 会话，可限定项目、agent、时间窗或收藏。用户问最近在做什么、想接着以前的活继续、提到「昨天那个会话」「上次」「Codex 在这做了什么」时用它——把当前工作目录当 project 传。返回 code_get_session 需要的会话 key。子代理会话折进父会话；不含归档。",
        key: "会话 key，如 `claude-code:1b2c…`，或 code://session/… 引用。",
        fromSeq: "从这个消息 seq 开始（含）。默认从头。",
        maxMessages: "每页消息数。",
        maxChars: "每页字符预算。",
        maxMessageChars: "单条消息超过这么多字符就截断。",
        includeTools: "带上工具调用的输入与输出（很长）。",
        includeThinking: "带上助手记录下来的思考过程。",
        getSession: "读一条会话的转录（现场从该 agent 自己的文件解析），输出紧凑 Markdown：用户与助手消息带 `[seq N]` 标记，工具调用折成一行，注入的上下文省略。在 code_search 或 code_list_sessions 之后用它看以前那次会话到底发生了什么——推理、决定和具体步骤。分页：回复末尾有 `from_seq` 提示时带上它再调一次接着读。key 可以是会话 key，也可以是 `code://session/<key>#<seq>` 引用（seq 作为起点）。",
        listProjects: "有编程 agent 会话记录的项目（工作目录），最近活跃的在前，带会话数。用户泛泛地问最近在忙哪些项目（「这个月碰过哪些项目？」），或者要给别的工具找对的 `project` 值时用它。")

    /// Wake `definitions()` 原文逐字，只换 `wake_*` → `code_*`、`wake://` → `code://`、Wake → 应用名
    private static let mcpTexts = Texts(
        project: "Scope to one project. Pass an absolute path — your current working directory is ideal: \(appName) matches the enclosing indexed project, or every project below a parent directory — or a project name. Omit to cover all projects.",
        agents: "Only sessions from these agents (ids as listed). Omit for all agents.",
        since: "Only sessions updated at or after this time: relative (30m, 24h, 7d, 2w) or an ISO date/time (2026-09-01, 2026-09-01T09:30:00Z).",
        searchQuery: "Search terms. Terms shorter than 3 characters fall back to a slower substring scan.",
        searchLimit: "Maximum sessions to return.",
        search: "Full-text search across every indexed coding-agent session on this machine (user prompts, assistant replies, tool names and inputs). Use it when the user asks whether something was discussed, tried or solved before, or wants the conversation about a topic, an error message, a file or a decision — git history does not hold that. Terms are ANDed; CJK text and code substrings like `useEffect(` work. Returns matching sessions with up to three snippets each, plus a `code://session/<key>#<seq>` reference per snippet that you can read with code_get_session.",
        starred: "Only sessions the user starred in \(appName).",
        listSessions: "Most recently updated coding-agent sessions, optionally scoped to a project, to some agents, to a time window, or to starred sessions. Use it when the user asks what they or an agent worked on recently, wants to resume or continue earlier work, or refers to \"yesterday's session\", \"last time\", \"what Codex did here\" — pass the current working directory as `project`. It returns the session keys code_get_session needs. Subagent sessions are folded into their parents; archived sessions are excluded.",
        key: "Session key such as `claude-code:1b2c…`, or a code://session/… reference.",
        fromSeq: "Start at this message seq (inclusive). Default: the beginning.",
        maxMessages: "Messages per page.",
        maxChars: "Character budget per page.",
        maxMessageChars: "Longer messages are truncated to this many characters.",
        includeTools: "Include tool-call inputs and outputs (verbose).",
        includeThinking: "Include the assistant's thinking/reasoning text where the agent recorded it.",
        getSession: "Read one session's transcript, parsed live from the agent's own files, as compact Markdown: user and assistant messages with `[seq N]` markers, tool calls folded to one line each, injected context omitted. Use it after code_search or code_list_sessions to see what actually happened — the reasoning, the decisions and the exact steps of an earlier session. Paginated: when the reply ends with a `from_seq` hint, call again with it to continue. Accepts a session key or a `code://session/<key>#<seq>` reference (the seq becomes the starting point).",
        listProjects: "Projects (working directories) that have coding-agent session history, most recently active first, with session counts. Use it when the user asks broadly what they have been working on (\"which projects did I touch this month?\") or to find the right `project` value for the other tools.")

    static let mcpTitles: [String: String] = [
        search: "Search session history", listSessions: "List recent sessions",
        getSession: "Read a session transcript", listProjects: "List indexed projects",
    ]

    private static func texts(_ flavor: Flavor) -> Texts { flavor == .app ? appTexts : mcpTexts }

    private static func projectParam(_ t: Texts) -> [String: Any] { ["type": "string", "description": t.project] }

    private static func agentsParam(_ t: Texts) -> [String: Any] {
        ["type": "array", "items": ["type": "string", "enum": CodingAgent.allCases.map(\.rawValue)], "description": t.agents]
    }

    private static func sinceParam(_ t: Texts) -> [String: Any] { ["type": "string", "description": t.since] }

    /// 分开写、显式类型：一整个 [String: Any] 嵌套字面量会让类型检查超时
    private static func intParam(_ lo: Int, _ hi: Int, _ fallback: Int, _ description: String?) -> [String: Any] {
        var param: [String: Any] = ["type": "integer", "minimum": lo, "maximum": hi, "default": fallback]
        if let description { param["description"] = description }
        return param
    }

    private static func boolParam(_ description: String?) -> [String: Any] {
        var param: [String: Any] = ["type": "boolean", "default": false]
        if let description { param["description"] = description }
        return param
    }

    private static func searchDefinition(_ flavor: Flavor) -> ToolDefinition {
        let t = texts(flavor)
        var properties: [String: Any] = ["project": projectParam(t), "agents": agentsParam(t), "since": sinceParam(t)]
        properties["query"] = ["type": "string", "description": t.searchQuery] as [String: Any]
        properties["limit"] = intParam(1, maxSearchSessions, 10, t.searchLimit)
        return ToolDefinition(name: search, description: t.search, properties: properties, required: ["query"])
    }

    private static func listSessionsDefinition(_ flavor: Flavor) -> ToolDefinition {
        let t = texts(flavor)
        var properties: [String: Any] = ["project": projectParam(t), "agents": agentsParam(t), "since": sinceParam(t)]
        properties["starred"] = boolParam(t.starred)
        properties["limit"] = intParam(1, maxListSessions, 20, nil)
        return ToolDefinition(name: listSessions, description: t.listSessions, properties: properties, required: [])
    }

    private static func getSessionDefinition(_ flavor: Flavor) -> ToolDefinition {
        let t = texts(flavor)
        let limits: Limits = flavor == .app ? .inApp : .wake
        var properties: [String: Any] = [:]
        properties["key"] = ["type": "string", "description": t.key] as [String: Any]
        properties["from_seq"] = ["type": "integer", "minimum": 0, "description": t.fromSeq] as [String: Any]
        properties["max_messages"] = intParam(1, 200, 60, t.maxMessages)
        properties["max_chars"] = intParam(200, limits.maxCharsMax, limits.maxCharsDefault, t.maxChars)
        properties["max_message_chars"] = intParam(100, 50_000, 4_000, t.maxMessageChars)
        properties["include_tools"] = boolParam(t.includeTools)
        properties["include_thinking"] = boolParam(t.includeThinking)
        return ToolDefinition(name: getSession, description: t.getSession, properties: properties, required: ["key"])
    }

    private static func listProjectsDefinition(_ flavor: Flavor) -> ToolDefinition {
        let t = texts(flavor)
        var properties: [String: Any] = ["since": sinceParam(t)]
        properties["limit"] = intParam(1, maxListProjects, 50, nil)
        return ToolDefinition(name: listProjects, description: t.listProjects, properties: properties, required: [])
    }

    /// 顺序 = Wake `definitions()`
    static func definitions(_ flavor: Flavor) -> [ToolDefinition] {
        [searchDefinition(flavor), listSessionsDefinition(flavor), getSessionDefinition(flavor), listProjectsDefinition(flavor)]
    }

    /// app 内下发给模型（N5）
    static var definitions: [ToolDefinition] { definitions(.app) }

    /// mp-code 的 `tools/list`（N6，Wake `definitions()` 的形状）：title + inputSchema + 只读注解；没有必填参数就不写 required（同 Wake）
    static var mcpDefinitions: [[String: Any]] {
        definitions(.mcp).map { d in
            var schema: [String: Any] = ["type": "object", "properties": d.properties]
            if !d.required.isEmpty { schema["required"] = d.required }
            let annotations: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
            return ["name": d.name, "title": mcpTitles[d.name] ?? d.name, "description": d.description, "inputSchema": schema,
                    "annotations": annotations]
        }
    }

    // MARK: - 执行

    static func invoke(name: String, argumentsJSON: String, context: Context) -> Result {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String: Any] = [:]
        if !trimmed.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
                return Result(text: "Arguments must be a JSON object.", kind: .invalidParams)
            }
            args = object
        }
        return invoke(name: name, arguments: args, context: context)
    }

    static func invoke(name: String, arguments args: [String: Any], context ctx: Context) -> Result {
        do {
            switch name {
            case search: return Result(text: try runSearch(args, ctx), kind: .ok)
            case listSessions: return Result(text: try runListSessions(args, ctx), kind: .ok)
            case getSession: return Result(text: try runGetSession(args, ctx), kind: .ok)
            case listProjects: return Result(text: try runListProjects(args, ctx), kind: .ok)
            default: return Result(text: "Unknown tool: \(name)", kind: .invalidParams)
            }
        } catch ToolError.invalidParams(let message) {
            return Result(text: message, kind: .invalidParams)
        } catch ToolError.failed(let message) {
            return Result(text: message, kind: .failed)
        } catch {
            return Result(text: "\(error.localizedDescription)", kind: .internal)
        }
    }

    // MARK: - 参数读取（宽松：数字串、整数值浮点、"true" / "false"、逗号分隔的 agents 都认）

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func stringArg(_ args: [String: Any], _ name: String) throws -> String? {
        switch args[name] {
        case nil, is NSNull: return nil
        case let s as String: return s
        default: throw ToolError.invalidParams("`\(name)` must be a string")
        }
    }

    static func intArg(_ args: [String: Any], _ name: String, _ fallback: Int, _ lo: Int, _ hi: Int) throws -> Int {
        let raw = args[name]
        let value: Int
        switch raw {
        case nil, is NSNull:
            return fallback
        case let s as String:
            guard let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ToolError.invalidParams("`\(name)` must be an integer") }
            value = n
        case let n as NSNumber where !isBool(n):
            let d = n.doubleValue
            guard d.rounded() == d, abs(d) < 9.2e18 else { throw ToolError.invalidParams("`\(name)` must be an integer") }
            value = Int(d)
        default:
            throw ToolError.invalidParams("`\(name)` must be an integer")
        }
        return min(max(value, lo), hi)
    }

    static func boolArg(_ args: [String: Any], _ name: String, _ fallback: Bool) throws -> Bool {
        switch args[name] {
        case nil, is NSNull: return fallback
        case let n as NSNumber where isBool(n): return n.boolValue
        case let s as String where s == "true" || s == "false": return s == "true"
        default: throw ToolError.invalidParams("`\(name)` must be a boolean")
        }
    }

    static func agentsArg(_ args: [String: Any]) throws -> [CodingAgent] {
        let raw: [String]
        switch args["agents"] {
        case nil, is NSNull: return []
        case let s as String: raw = s.components(separatedBy: ",")
        case let items as [Any]:
            raw = try items.map { item in
                guard let s = item as? String else { throw ToolError.invalidParams("`agents` must be an array of agent ids") }
                return s
            }
        default: throw ToolError.invalidParams("`agents` must be an array of agent ids")
        }
        var out: [CodingAgent] = []
        for item in raw {
            let s = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            guard let agent = parseAgent(s) else {
                throw ToolError.invalidParams("unknown agent `\(s)`; valid ids: \(CodingAgent.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            if !out.contains(agent) { out.append(agent) }
        }
        return out
    }

    /// agent 名宽松解析：正式 id 优先，其次展示名（大小写 / 空格 / 连字符不敏感），再加几个常见简称
    static func parseAgent(_ s: String) -> CodingAgent? {
        if let agent = CodingAgent(rawValue: s) { return agent }
        func norm(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let wanted = norm(s)
        if let agent = CodingAgent.allCases.first(where: { norm($0.rawValue) == wanted || norm($0.displayName) == wanted }) { return agent }
        switch wanted {
        case "claude": return .claudeCode
        case "deepseek": return .dsh
        case "opencode2", "opencodenext": return .opencode
        default: return nil
        }
    }

    private static func sinceArg(_ args: [String: Any], _ ctx: Context) throws -> Int64? {
        guard let raw = try stringArg(args, "since"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let since = CodingContext.parseSince(raw, nowMs: ctx.nowMs) else {
            throw ToolError.invalidParams("`since` not understood: `\(raw)` (use 30m / 24h / 7d / 2w or an ISO date/time)")
        }
        return since
    }

    /// project 参数的三种结局；noMatch 带的是给模型的完整回复（含已知项目清单）——没匹配上不是错误
    private enum ProjectScope {
        case all
        case paths([String])
        case noMatch(String)
    }

    private static func projectArg(_ args: [String: Any], _ ctx: Context) throws -> ProjectScope {
        guard let arg = try stringArg(args, "project")?.trimmingCharacters(in: .whitespacesAndNewlines), !arg.isEmpty else { return .all }
        // 含归档：搜索覆盖归档会话，只剩归档会话的项目不能在这一步被挡掉
        var roots = CodingListFilter()
        roots.rootsOnly = true
        let projects = try ctx.index.listProjects(filter: roots, includeArchived: true)
        let paths = CodingContext.resolveProjectPaths(arg, projects: projects)
        if !paths.isEmpty { return .paths(paths) }
        var text = "No indexed project matches `\(arg)`.\n\n"
        if projects.isEmpty {
            text += "The index has no projects yet."
        } else {
            text += "Known projects (most recently active first):\n"
            for p in projects.filter({ !$0.path.isEmpty }).prefix(15) {
                text += "- \(p.path) — \(p.name) · \(p.sessionCount) session\(plural(p.sessionCount))\n"
            }
            text += "\nPass one of these paths (or the project name), or omit `project` to cover everything."
        }
        return .noMatch(text)
    }

    // MARK: - 输出小工具

    static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    /// 空白压成单个空格，超过 max 个字符截断加「…」（Wake `one_line`）
    static func oneLine(_ s: String, _ max: Int) -> String {
        let flat = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let scalars = flat.unicodeScalars
        guard scalars.count > max else { return flat }
        return String(String.UnicodeScalarView(scalars.prefix(max))) + "…"
    }

    static func fmt(_ ms: Int64) -> String { CodingSessionExport.formatTime(ms) }

    private static func indexNote(_ index: CodingSessionIndex) -> String {
        do {
            if let latest = try index.latestActivity() {
                return "Index covers activity up to \(fmt(latest)) (local time); \(appName) keeps it fresh while it is running."
            }
            return "The index is empty — open the Code group in \(appName) to build it."
        } catch {
            return "Index freshness unknown: \(error.localizedDescription)"
        }
    }

    private static func scopeNote(_ project: [String]?, _ agents: [CodingAgent], _ since: Int64?, _ starred: Bool) -> String {
        var parts: [String] = []
        if let project { parts.append(project.count == 1 ? "project \(project[0])" : "\(project.count) projects") }
        if !agents.isEmpty { parts.append("agents \(agents.map(\.rawValue).joined(separator: ", "))") }
        if let since { parts.append("since \(fmt(since))") }
        if starred { parts.append("starred") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    static func sessionLine(_ s: CodingSessionMeta, favorites: Set<String>) -> String {
        var tags: [String] = []
        if !s.host.isEmpty { tags.append("@\(s.host)") }
        if let source = s.source, !source.isEmpty { tags.append("via \(source)") }
        if favorites.contains(s.key) { tags.append("★ starred") }
        if s.archived { tags.append("archived") }
        let tagText = tags.isEmpty ? "" : " · " + tags.joined(separator: " · ")
        let project = s.projectPath.isEmpty ? "(unknown project)" : s.projectPath
        let model = s.model.map { $0.isEmpty ? "" : " · \($0)" } ?? ""
        return "`\(s.key)` · \(s.agent.displayName) · \"\(oneLine(s.title, 120))\"\n  \(project) · updated \(fmt(s.updatedAt)) · \(s.messageCount) message\(plural(s.messageCount))\(model)\(tagText)\n"
    }

    static func cleanSnippet(_ s: String) -> String {
        let marked = s.replacingOccurrences(of: String(CodingSessionIndex.highlightOpen), with: "**")
            .replacingOccurrences(of: String(CodingSessionIndex.highlightClose), with: "**")
            .replacingOccurrences(of: "****", with: "")
        return oneLine(marked, 240)
    }

    private static func sessionRef(_ key: String, _ seq: Int) -> String { "\(refPrefix)\(key)#\(seq)" }

    // MARK: - 四个工具

    private static func runSearch(_ args: [String: Any], _ ctx: Context) throws -> String {
        guard let query = try stringArg(args, "query")?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ToolError.invalidParams("`query` is required")
        }
        let agents = try agentsArg(args)
        let since = try sinceArg(args, ctx)
        let limit = try intArg(args, "limit", 10, 1, maxSearchSessions)
        let project: [String]?
        switch try projectArg(args, ctx) {
        case .all: project = nil
        case .paths(let paths): project = paths
        case .noMatch(let text): return text
        }
        // 命中是消息级、按相关度排；一个会话能占掉前几十行，多取一些再按会话归组
        let fetch = min(max(limit * 8, 60), 400)
        let (hits, degraded) = try ctx.index.search(query, agents: agents, projectPaths: project ?? [], updatedSince: since, limit: fetch)
        var order: [String] = []
        var groups: [String: (meta: CodingSessionMeta, hits: [CodingSessionIndex.SearchHit])] = [:]
        for hit in hits {
            if groups[hit.meta.key] == nil {
                order.append(hit.meta.key)
                groups[hit.meta.key] = (hit.meta, [])
            }
            if groups[hit.meta.key]!.hits.count < snippetsPerSession { groups[hit.meta.key]!.hits.append(hit) }
        }
        let scope = scopeNote(project, agents, since, false)
        var out = ""
        if order.isEmpty {
            out += "No matches for `\(query)`\(scope).\n"
            if degraded { out += "Note: terms shorter than 3 characters use a substring scan; try a longer or more specific term.\n" }
            out += "Try fewer or different terms, drop the project/agent/since filters, or list sessions with \(listSessions).\n\n"
            out += indexNote(ctx.index)
            return out
        }
        let shown = min(order.count, limit)
        out += "\(order.count) session\(plural(order.count)) match `\(query)`\(scope)\(hits.count >= fetch ? " (more may exist)" : "") — showing \(shown), best matches first.\n"
        if degraded { out += "Note: terms shorter than 3 characters use a slower substring scan.\n" }
        out += "\n"
        for (ix, key) in order.prefix(shown).enumerated() {
            guard let group = groups[key] else { continue }
            out += "\(ix + 1). " + sessionLine(group.meta, favorites: ctx.favorites)
            for hit in group.hits {
                let when = hit.timestamp.flatMap { $0 > 0 ? ", \(fmt($0))" : nil } ?? ""
                out += "  - seq \(hit.seq) (\(hit.role)\(when)): \(cleanSnippet(hit.snippet))\n    ref: \(sessionRef(group.meta.key, hit.seq))\n"
            }
            out += "\n"
        }
        out += "Read a session with \(getSession) (pass the key, or a ref to start at that message).\n"
        out += indexNote(ctx.index)
        return out
    }

    private static func runListSessions(_ args: [String: Any], _ ctx: Context) throws -> String {
        let agents = try agentsArg(args)
        let since = try sinceArg(args, ctx)
        let starred = try boolArg(args, "starred", false)
        let limit = try intArg(args, "limit", 20, 1, maxListSessions)
        let project: [String]?
        switch try projectArg(args, ctx) {
        case .all: project = nil
        case .paths(let paths): project = paths
        case .noMatch(let text): return text
        }
        // 「最近」就是最近：不管置顶（界面的置顶优先在这里会让 limit 先被旧置顶占掉）
        var filter = CodingListFilter()
        filter.agents = agents
        filter.rootsOnly = true
        filter.sort = .updated
        filter.ascending = false
        filter.projectPaths = project ?? []
        filter.updatedSince = since
        if starred { filter.onlyKeys = ctx.favorites }
        let sessions = try ctx.index.listSessions(projectPath: nil, filter: filter, includeArchived: false, limit: limit)
        let total = try ctx.index.countSessions(filter: filter)
        let scope = scopeNote(project, agents, since, starred)
        var out = ""
        if sessions.isEmpty {
            out += "No sessions\(scope).\n\n"
            out += indexNote(ctx.index)
            return out
        }
        out += "\(total) session\(plural(total))\(scope) — showing the \(sessions.count) most recently updated.\n\n"
        for s in sessions { out += "- " + sessionLine(s, favorites: ctx.favorites) }
        out += "\nRead one with \(getSession) using its key.\n"
        out += indexNote(ctx.index)
        return out
    }

    private static func runListProjects(_ args: [String: Any], _ ctx: Context) throws -> String {
        let since = try sinceArg(args, ctx)
        let limit = try intArg(args, "limit", 50, 1, maxListProjects)
        var roots = CodingListFilter()
        roots.rootsOnly = true
        let projects = try ctx.index.listProjects(filter: roots, includeArchived: false).filter { since == nil || $0.lastActive >= since! }
        let window = since.map { " active since \(fmt($0))" } ?? ""
        var out = ""
        if projects.isEmpty {
            out += "No projects\(window).\n\n"
            out += indexNote(ctx.index)
            return out
        }
        out += "\(projects.count) project\(plural(projects.count))\(window) — most recently active first\(projects.count > limit ? ", showing \(limit)" : "").\n\n"
        for p in projects.prefix(limit) {
            let path = p.path.isEmpty ? "(unknown project)" : p.path
            out += "- \(path) — \(p.name.isEmpty ? "?" : p.name) · \(p.sessionCount) session\(plural(p.sessionCount)) · last active \(fmt(p.lastActive))\n"
        }
        out += "\nUse a path as `project` in \(listSessions) or \(search).\n"
        out += indexNote(ctx.index)
        return out
    }

    /// `key` 也接受 `code://session/<key>#<seq>`（与 Wake 的 `wake://session/…`）引用，seq 成为默认起点
    static func parseKeyArg(_ raw: String) -> (key: String, seq: Int?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [refPrefix, "wake://session/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        if let hash = s.lastIndex(of: "#"), let seq = Int(s[s.index(after: hash)...]) {
            return (String(s[..<hash]), seq)
        }
        return (s, nil)
    }

    private static func findSession(_ ctx: Context, _ key: String) throws -> CodingSessionMeta {
        if let meta = try ctx.index.session(key: key) { return meta }
        // 兜底：对方只拿到原生 id（续跑用的那个），按列反查；同一 UUID 跨主机会多于一条
        let candidates = try ctx.index.sessions(nativeId: key)
        switch candidates.count {
        case 1:
            return candidates[0]
        case 0:
            throw ToolError.failed("No session with key `\(key)`. Keys look like `claude-code:<id>` (or `<agent>:<host>:<id>` for remote hosts); get one from \(search) or \(listSessions).")
        default:
            let lines = candidates.map { "- `\($0.key)` (\($0.agent.displayName)\($0.host.isEmpty ? "" : " @\($0.host)"))" }
            throw ToolError.failed("`\(key)` is ambiguous — \(candidates.count) sessions share that id:\n" + lines.joined(separator: "\n"))
        }
    }

    private static func runGetSession(_ args: [String: Any], _ ctx: Context) throws -> String {
        guard let raw = try stringArg(args, "key")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ToolError.invalidParams("`key` is required")
        }
        let (key, refSeq) = parseKeyArg(raw)
        let fromSeq = try intArg(args, "from_seq", refSeq ?? 0, 0, Int.max)
        let options = CodingCompact.Options(
            fromSeq: fromSeq,
            maxMessages: try intArg(args, "max_messages", 60, 1, 200),
            maxChars: try intArg(args, "max_chars", ctx.limits.maxCharsDefault, 200, ctx.limits.maxCharsMax),
            maxMessageChars: try intArg(args, "max_message_chars", 4_000, 100, 50_000),
            includeTools: try boolArg(args, "include_tools", false),
            includeThinking: try boolArg(args, "include_thinking", false))
        let meta = try findSession(ctx, key)
        guard let adapter = CodingSessionRoster.owner(of: meta, in: ctx.adapters) else {
            throw ToolError.failed("No adapter can read `\(meta.key)` (\(meta.agent.displayName)) — its data location may be disabled in \(appName)'s session locations.")
        }
        let transcript: CodingParsedTranscript
        do {
            transcript = try ctx.cache.transcript(adapter: adapter, meta: meta)
        } catch {
            throw ToolError.failed("Could not read the transcript of `\(meta.key)` from \(meta.filePath): \(error.localizedDescription)")
        }
        let live = transcript.meta
        let totalVisible = transcript.mainline.filter { $0.kind != .meta }.count
        let lastSeq = transcript.mainline.last?.seq
        let page = CodingCompact.render(transcript.mainline, options)

        var out = "# \(live.title.isEmpty ? CodingLimits.untitled : live.title)\n"
        var facts = ["key: `\(meta.key)`", "agent: \(meta.agent.displayName)"]
        if !meta.host.isEmpty { facts.append("host: @\(meta.host)") }
        if !live.projectPath.isEmpty {
            let branch = live.gitBranch.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            facts.append("project: \(live.projectPath)\(branch)")
        }
        if let model = live.model, !model.isEmpty { facts.append("model: \(model)") }
        if let source = meta.source, !source.isEmpty { facts.append("via \(source)") }
        facts.append("\(fmt(live.createdAt)) – \(fmt(live.updatedAt))")
        facts.append("\(totalVisible) message\(plural(totalVisible))")
        out += facts.joined(separator: " · ") + "\n\n"

        guard page.rendered > 0 else {
            if let lastSeq {
                out += "No messages at or after seq \(fromSeq) (the transcript ends at seq \(lastSeq)).\n"
            } else {
                out += "This transcript has no messages.\n"
            }
            return out
        }
        out += page.text
        out += "—\n"
        let first = page.firstSeq ?? fromSeq
        let last = page.lastSeq ?? fromSeq
        var summary = "Showing seq \(first)–\(last): \(page.rendered) message\(plural(page.rendered))"
        if page.skippedMeta > 0 {
            summary += "; \(page.skippedMeta) injected-context message\(plural(page.skippedMeta)) omitted"
        }
        if !transcript.sidechains.isEmpty {
            summary += "; \(transcript.sidechains.count) subagent transcript\(plural(transcript.sidechains.count)) not included"
        }
        out += summary + ".\n"
        if let next = page.nextSeq {
            out += "More follows — call \(getSession) again with from_seq=\(next).\n"
        } else {
            out += "End of transcript.\n"
        }
        return out
    }

    /// 单槽转录缓存：分页读同一会话时不必每页整文件重解析（默认 2 万字符一页，大会话几十页）。键 = (路径, 戳, 大小)，文件一变即失效；
    /// SQLite 型的 `库#id` 虚拟路径 stat 不到，戳改用库文件与 `-wal` 的 mtime（Wake `TranscriptCache`）
    /// 工具路径的错误给模型读，用英文（R-WN5 #7）
    private struct GoneError: LocalizedError {
        var errorDescription: String? { "the session file is gone" }
    }

    final class TranscriptCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (path: String, stamp: Int64, size: Int64, transcript: CodingParsedTranscript)?

        func transcript(adapter: CodingSessionAdapter, meta: CodingSessionMeta) throws -> CodingParsedTranscript {
            guard let ref = adapter.fileRef(URL(fileURLWithPath: meta.filePath)) ?? CodingSessionFileRef.fromMeta(meta) else {
                throw GoneError()
            }
            let stamp = FileManager.default.fileExists(atPath: ref.filePath)
                ? ref.mtimeMs
                : CodingSQLiteReader.cacheStamp(URL(fileURLWithPath: CodingVirtualPath.strip(ref.filePath)))
            lock.lock()
            if let entry, entry.path == ref.filePath, entry.stamp == stamp, entry.size == ref.size {
                lock.unlock()
                return entry.transcript
            }
            lock.unlock()
            let transcript = try adapter.parseTranscript(ref)
            lock.lock()
            entry = (ref.filePath, stamp, ref.size, transcript)
            lock.unlock()
            return transcript
        }
    }
}
#endif
