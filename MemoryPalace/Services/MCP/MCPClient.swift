import Foundation

@MainActor
final class MCPClient {
    private let name: String
    private let version: String
    private let requestTimeout: TimeInterval
    private let protocolVersion = "2025-03-26"

    private var transport: MCPTransport?
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private(set) var initialized = false
    private(set) var serverInfo: [String: Any] = [:]
    private(set) var serverCapabilities: [String: Any] = [:]

    init(name: String = "MemoryPalace MCP", version: String = "1.0.0", requestTimeout: TimeInterval = 30) {
        self.name = name
        self.version = version
        self.requestTimeout = requestTimeout
    }

    func connect(transport: MCPTransport) async throws {
        if self.transport != nil {
            throw MCPError.protocolError("client 已连接")
        }
        self.transport = transport
        transport.onMessage = { [weak self] raw in
            Task { @MainActor in
                self?.handleMessage(raw)
            }
        }
        transport.onClose = { [weak self] error in
            Task { @MainActor in
                self?.handleClose(error)
            }
        }
        try await transport.connect()
        try await initialize()
    }

    func disconnect() {
        transport?.close()
        transport = nil
        initialized = false
        for continuation in pending.values {
            continuation.resume(throwing: MCPError.connectionClosed)
        }
        pending.removeAll()
    }

    func listTools() async throws -> [MCPTool] {
        guard initialized else { throw MCPError.protocolError("client 未初始化") }
        let response = try await sendRequest(method: "tools/list", params: [:])
        let rawTools = response["tools"] as? [[String: Any]] ?? []
        return rawTools.compactMap { raw in
            guard let name = raw["name"] as? String else { return nil }
            let description = raw["description"] as? String ?? ""
            let schema = raw["inputSchema"] as? [String: Any] ?? raw["input_schema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            return MCPTool(name: name, description: description, inputSchema: schema)
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPCallToolResult {
        guard initialized else { throw MCPError.protocolError("client 未初始化") }
        let response = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        let content = response["content"] as? [[String: Any]] ?? []
        let isError = response["isError"] as? Bool ?? response["is_error"] as? Bool ?? false
        return MCPCallToolResult(content: content, isError: isError)
    }

    private func initialize() async throws {
        let response = try await sendRequest(method: "initialize", params: [
            "protocolVersion": protocolVersion,
            "clientInfo": ["name": name, "version": version],
            "capabilities": [:],
        ])
        serverInfo = response["serverInfo"] as? [String: Any] ?? [:]
        serverCapabilities = response["capabilities"] as? [String: Any] ?? [:]
        try await sendNotification(method: "notifications/initialized", params: [:])
        initialized = true
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let transport else { throw MCPError.connectionClosed }
        let id = nextRequestId
        nextRequestId += 1

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        // 超时实现注意（P0-3）：不能用「TaskGroup 双子任务、超时子任务 throw」的惯用模式——
        // group 以 throw 退出后要**等全部子任务结束**，而 cancel 不会 resume 卡在 checked
        // continuation 里的等待子任务（它只在回包/断连/send 失败时被 resume）→ server 收下
        // 请求但不回包时整个函数永挂：工具回合卡死、心跳卡死、重连永不触发。
        // 正确做法：超时方主动 resume。resume 权唯一通过 `pending.removeValue(forKey:)`
        // 获取（@MainActor 串行），五条路径（回包/断连/disconnect/send失败/超时）天然互斥，
        // 不会 double-resume。
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.requestTimeout ?? 30) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pending.removeValue(forKey: id)?.resume(throwing: MCPError.requestTimeout(method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            self.pending[id] = continuation
            Task { @MainActor in
                do {
                    try await transport.send(request)
                } catch {
                    self.pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        guard let transport else { throw MCPError.connectionClosed }
        try await transport.send([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    private func handleMessage(_ raw: Any) {
        let message: [String: Any]?
        if let dict = raw as? [String: Any] {
            message = dict
        } else if let string = raw as? String,
                  let data = string.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = dict
        } else {
            message = nil
        }
        guard let message else { return }

        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                let code = error["code"].map { "\($0)" } ?? ""
                let text = error["message"] as? String ?? "MCP error"
                continuation.resume(throwing: MCPError.serverError(code.isEmpty ? text : "\(text) (\(code))"))
            } else if let result = message["result"] as? [String: Any] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(returning: [:])
            }
        }
    }

    private func handleClose(_ error: Error?) {
        transport = nil
        initialized = false
        for continuation in pending.values {
            continuation.resume(throwing: error ?? MCPError.connectionClosed)
        }
        pending.removeAll()
    }
}
