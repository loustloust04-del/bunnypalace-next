#if os(macOS)
import Foundation

/// `mp-code mcp`：把编程会话索引以 MCP（stdio、JSON-RPC 2.0、一行一条）只读暴露给别的 coding agent（W-N N6，Wake `mcp/mod.rs` 逐条）。
/// 协议层手写：只实现 initialize / notifications/initialized / ping / tools/list / tools/call；stdout 只写协议，日志一律 stderr。
/// 索引只读打开、不扫描；新鲜度靠 app 常驻的监听，每个工具返回都带「索引覆盖到的最新活动时间」
final class CodingMCPServer {
    /// 本方声明的协议版本（客户端请求的版本在 supported 里就回显它，否则回这个）
    static let protocolVersion = "2025-06-18"
    /// 已知且工具子集完全兼容的版本
    static let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// 随 initialize 下发给客户端的使用说明（模型会读）。重点是「什么时候该用」：模型对陌生工具默认不碰，问「最近在做什么」会去翻 git log
    static let instructions = "\(CodingTools.appName) indexes every coding-agent session on this machine (Claude Code, Codex, Cursor, Gemini CLI, OpenCode and more) and exposes them read-only. Use these tools whenever the user refers to earlier conversations or sessions with any AI coding agent: what was discussed, decided or tried, why something was done a certain way, where previous work stopped, or whether an error was seen before. Git history and the working tree do not contain that; \(CodingTools.appName) does. Start with \(CodingTools.listSessions) (pass the current working directory as `project`) or \(CodingTools.search), then read the relevant transcript with \(CodingTools.getSession). Nothing here can modify a session."

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603

    private struct RPCError: Error {
        let code: Int
        let message: String
    }

    private let index: CodingSessionIndex
    private let adapters: [CodingSessionAdapter]
    private let favorites: Set<String>
    /// 转录缓存随 server 进程长驻（翻页连读同一份会话不重解析）
    private let cache = CodingTools.TranscriptCache()
    var log: (String) -> Void = { _ = CodingCLI.emit("\(CodingCLI.binaryName): \($0)", to: STDERR_FILENO) }

    init(index: CodingSessionIndex, adapters: [CodingSessionAdapter], favorites: Set<String>) {
        self.index = index
        self.adapters = adapters
        self.favorites = favorites
    }

    /// 阻塞服务到 stdin EOF，每行一条消息；空行跳过。客户端先走一步、管道断开是正常收场（0），其余写错 1
    func serve(next: () -> String? = { Swift.readLine(strippingNewline: true) }, fd: Int32 = STDOUT_FILENO) -> Int32 {
        while let line = next() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let reply = handleLine(line) else { continue }
            let err = CodingCLI.writeAll(Array((reply + "\n").utf8), to: fd)
            if err == EPIPE { return 0 }
            if err != 0 {
                log(String(cString: strerror(err)))
                return 1
            }
        }
        return 0
    }

    /// 一行进、至多一行出（通知无回包）。批量数组逐条处理、按数组回；测试直接喂它，不经 stdio
    func handleLine(_ line: String) -> String? {
        let message: Any
        do {
            message = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
        } catch {
            return Self.encode(Self.errorResponse(NSNull(), Self.parseError, "Parse error: \(error.localizedDescription)"))
        }
        if let items = message as? [Any] {
            if items.isEmpty { return Self.encode(Self.errorResponse(NSNull(), Self.invalidRequest, "Invalid Request")) }
            let replies = items.compactMap(handleMessage)
            return replies.isEmpty ? nil : Self.encode(replies)
        }
        return handleMessage(message).map(Self.encode)
    }

    private func handleMessage(_ message: Any) -> [String: Any]? {
        guard let object = message as? [String: Any] else {
            return Self.errorResponse(NSNull(), Self.invalidRequest, "Invalid Request")
        }
        let rawId = object["id"]
        let id: Any? = rawId is NSNull ? nil : rawId
        guard let method = object["method"] as? String else {
            // 没有 method 的是「响应」：本 server 从不向客户端发请求，静默丢；带 id 却既无 result 也无 error 的才回 Invalid Request
            guard let id, object["result"] == nil, object["error"] == nil else { return nil }
            return Self.errorResponse(id, Self.invalidRequest, "Invalid Request")
        }
        let params = object["params"]
        // 通知（无 id）不回包，不管认不认识
        guard let id else {
            if method == "notifications/initialized" { log("client initialized") }
            return nil
        }
        let result: Result<Any, RPCError>
        switch method {
        case "initialize": result = .success(initialize(params))
        case "ping": result = .success([String: Any]())
        case "tools/list": result = .success(["tools": CodingTools.mcpDefinitions] as [String: Any])
        case "tools/call": result = callTool(params)
        default: result = .failure(RPCError(code: Self.methodNotFound, message: "Method not found: \(method)"))
        }
        switch result {
        case .success(let value): return ["jsonrpc": "2.0", "id": id, "result": value]
        case .failure(let error): return Self.errorResponse(id, error.code, error.message)
        }
    }

    private func initialize(_ params: Any?) -> [String: Any] {
        let requested = (params as? [String: Any])?["protocolVersion"] as? String ?? ""
        let version = Self.supported.contains(requested) ? requested : Self.protocolVersion
        let capabilities: [String: Any] = ["tools": ["listChanged": false] as [String: Any]]
        let serverInfo: [String: Any] = ["name": CodingCLI.binaryName, "title": CodingTools.appName, "version": CodingCLI.version]
        return ["protocolVersion": version, "capabilities": capabilities, "serverInfo": serverInfo, "instructions": Self.instructions]
    }

    private func callTool(_ params: Any?) -> Result<Any, RPCError> {
        let object = params as? [String: Any]
        guard let name = object?["name"] as? String else {
            return .failure(RPCError(code: Self.invalidParams, message: "tools/call needs a string `name`"))
        }
        var arguments: [String: Any] = [:]
        switch object?["arguments"] {
        case nil, is NSNull: break
        case let dict as [String: Any]: arguments = dict
        default: return .failure(RPCError(code: Self.invalidParams, message: "`arguments` must be an object"))
        }
        let context = CodingTools.Context(index: index, adapters: adapters, favorites: favorites,
                                          nowMs: Int64(Date().timeIntervalSince1970 * 1000), cache: cache, limits: .wake)
        let result = CodingTools.invoke(name: name, arguments: arguments, context: context)
        switch result.kind {
        case .ok: return .success(Self.toolResult(result.text, isError: false))
        // 参数形状错（含未知工具名）是协议错误；执行失败（坏 key、解析失败）是给模型看的结果；查询炸了是内部错误
        case .invalidParams: return .failure(RPCError(code: Self.invalidParams, message: result.text))
        case .failed: return .success(Self.toolResult(result.text, isError: true))
        case .internal: return .failure(RPCError(code: Self.internalError, message: result.text))
        }
    }

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        let content: [[String: Any]] = [["type": "text", "text": text]]
        return ["content": content, "isError": isError]
    }

    private static func errorResponse(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        let error: [String: Any] = ["code": code, "message": message]
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }

    /// 一行 JSON：字符串里的换行被转义；斜杠不转义（与 serde_json 同形）
    private static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
