import Foundation

@MainActor
@Observable
final class MCPProvider {
    static let shared = MCPProvider()

    private static let serversKey = "mcp_servers_v1"
    private static let timeoutKey = "mcp_request_timeout_seconds_v1"

    private(set) var servers: [MCPServerConfig] = []
    private(set) var statuses: [String: MCPConnectionStatus] = [:]
    private(set) var errors: [String: String] = [:]

    private var clients: [String: MCPClient] = [:]
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]
    private var reconnecting: Set<String> = []
    private var requestTimeout: TimeInterval
    private var didLoad = false

    private init() {
        let savedTimeout = UserDefaults.standard.double(forKey: Self.timeoutKey)
        requestTimeout = savedTimeout > 0 ? savedTimeout : 30
    }

    var connectedServers: [MCPServerConfig] {
        servers.filter { status(for: $0.id) == .connected }
    }

    var hasAnyEnabled: Bool {
        servers.contains(where: \.enabled)
    }

    /// 全局启用的 server id —— enabled 的 server 对所有对话生效（不再按对话隔离）。
    /// enabledTools(for:) 会进一步只取 connected + tool.enabled 的工具。
    var activeServerIds: [String] {
        servers.filter(\.enabled).map(\.id)
    }

    func loadAndConnectEnabledServers() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.quietNetwork { PerfGuardrails.suppress("mcp"); return }   // 测量角色不连 MCP server（perf P0 §3.1）
        #endif
        if TestHostIsolation.blocks(.mcp) { return }   // #035：测试宿主不连她启用的 MCP
        guard !didLoad else { return }
        didLoad = true
        load()
        for server in servers where server.enabled {
            Task { await connect(server.id) }
        }
    }

    func status(for serverId: String) -> MCPConnectionStatus {
        statuses[serverId] ?? .idle
    }

    func error(for serverId: String) -> String? {
        errors[serverId]
    }

    func serverName(for serverId: String) -> String? {
        servers.first(where: { $0.id == serverId })?.name
    }

    func addServer(
        name: String,
        url: String,
        transport: MCPTransportType,
        enabled: Bool,
        headers: [String: String],
        oauthClientId: String,
        oauthClientSecret: String,
        command: String = "",
        env: [String: String] = [:]
    ) {
        let server = MCPServerConfig(
            enabled: enabled,
            name: name,
            transport: transport,
            url: url,
            headers: headers,
            oauthClientId: oauthClientId,
            oauthClientSecret: oauthClientSecret,
            command: command,
            env: env
        )
        servers.append(server)
        persist()
        if enabled {
            Task { await connect(server.id) }
        }
    }

    func updateServer(_ server: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        persist()
        Task {
            await disconnect(server.id)
            if server.enabled {
                await connect(server.id)
            }
        }
    }

    func deleteServer(_ serverId: String) {
        servers.removeAll { $0.id == serverId }
        removeSecrets(serverId)
        persist()
        Task { await disconnect(serverId) }
    }

    func replaceServers(_ newServers: [MCPServerConfig]) {
        let oldIds = Set(servers.map(\.id))
        let newIds = Set(newServers.map(\.id))
        for removed in oldIds.subtracting(newIds) { removeSecrets(removed) }
        servers = newServers
        persist()
        Task {
            for id in oldIds.subtracting(newIds) {
                await disconnect(id)
            }
            for server in newServers {
                await disconnect(server.id)
                if server.enabled {
                    await connect(server.id)
                }
            }
        }
    }

    func setToolEnabled(serverId: String, toolName: String, enabled: Bool) {
        guard let serverIndex = servers.firstIndex(where: { $0.id == serverId }) else { return }
        var server = servers[serverIndex]
        server.tools = server.tools.map { tool in
            var next = tool
            if tool.name == toolName {
                next.enabled = enabled
            }
            return next
        }
        servers[serverIndex] = server
        persist()
    }

    func connect(_ serverId: String) async {
        guard let server = servers.first(where: { $0.id == serverId }) else { return }
        guard server.enabled else { return }
        if clients[serverId] != nil {
            statuses[serverId] = .connected
            errors.removeValue(forKey: serverId)
            return
        }
        // 并发 connect 挡板：本函数在 client.connect 的 await 悬挂点可被重入
        // （启动加载/updateServer/心跳重连/工具调用兜底都可能同时发起），
        // 没挡板会建出两个 client，先建的 SSE 流无人 close（连接泄漏）。
        if statuses[serverId] == .connecting { return }

        statuses[serverId] = .connecting
        errors.removeValue(forKey: serverId)

        do {
            let transport = try MCPTransportFactory.makeTransport(for: server)
            let client = MCPClient(requestTimeout: requestTimeout)
            do {
                try await client.connect(transport: transport)
            } catch {
                // 失败时必须关掉已建立的连接：client.connect 先开 transport 再 initialize，
                // initialize 失败/超时后 SSE 长连接还活着，不 close 就是悬挂泄漏
                client.disconnect()
                throw error
            }
            clients[serverId] = client
            statuses[serverId] = .connected
            errors.removeValue(forKey: serverId)
            await refreshTools(serverId)
            startHeartbeat(serverId)
        } catch {
            statuses[serverId] = .error
            errors[serverId] = error.localizedDescription
            clients.removeValue(forKey: serverId)
            stopHeartbeat(serverId)
        }
    }

    func disconnect(_ serverId: String) async {
        clients.removeValue(forKey: serverId)?.disconnect()
        statuses[serverId] = .idle
        errors.removeValue(forKey: serverId)
        stopHeartbeat(serverId)
    }

    func reconnect(_ serverId: String) async {
        await disconnect(serverId)
        await connect(serverId)
    }

    /// last-known-good 防缩守卫（SC-B5 批注3）：server 抖动时"成功"返回空/大幅缩水的列表
    /// 不能冲掉缓存——工具数组一变，发给模型的 tools 跟着变 → 前缀 cache bust + 工具时有时无。
    /// 空列表或缩水超半 → 保旧。真要收缩：禁用再启用 server 重置缓存。
    nonisolated static func shouldKeepCachedTools(remoteCount: Int, cachedCount: Int) -> Bool {
        guard cachedCount > 0 else { return false }
        if remoteCount == 0 { return true }
        return remoteCount * 2 < cachedCount
    }

    func refreshTools(_ serverId: String) async {
        guard let client = clients[serverId],
              let serverIndex = servers.firstIndex(where: { $0.id == serverId }) else { return }
        do {
            let remoteTools = try await client.listTools()
            if Self.shouldKeepCachedTools(remoteCount: remoteTools.count, cachedCount: servers[serverIndex].tools.count) {
                CacheDiagLog.shared.log("🔌 MCP \(servers[serverIndex].name) 工具列表疑似抖动（\(servers[serverIndex].tools.count)→\(remoteTools.count)），保留 last-known-good")
                statuses[serverId] = .connected
                errors.removeValue(forKey: serverId)
                return
            }
            let existing = Dictionary(uniqueKeysWithValues: servers[serverIndex].tools.map { ($0.name, $0) })
            var merged: [MCPToolConfig] = []
            for tool in remoteTools {
                let schema = tool.inputSchema.mapValues { JSONValue.fromAny($0) }
                let prior = existing[tool.name]
                merged.append(MCPToolConfig(
                    enabled: prior?.enabled ?? true,
                    name: tool.name,
                    description: tool.description,
                    params: Self.params(from: tool.inputSchema),
                    schema: schema.isEmpty ? ["type": .string("object"), "properties": .object([:])] : schema
                ))
            }
            servers[serverIndex].tools = merged
            statuses[serverId] = .connected
            errors.removeValue(forKey: serverId)
            persist()
        } catch {
            errors[serverId] = error.localizedDescription
        }
    }

    func enabledTools(for serverIds: [String]) -> [MCPResolvedTool] {
        var result: [MCPResolvedTool] = []
        for serverId in serverIds {
            // 不要求 live connected：用已缓存（首次 listTools 后持久化）的工具列表。
            // iOS 切后台会让连接抖动，若要求"发送那刻必须 connected"，工具会从模型眼前
            // 时有时无 → 模型"没调用"。实际调用时 callToolText 会按需重连。
            guard let server = servers.first(where: { $0.id == serverId }),
                  server.enabled else { continue }
            for tool in server.tools where tool.enabled {
                result.append(MCPResolvedTool(serverId: server.id, serverName: server.name, tool: tool))
            }
        }
        return result
    }

    func openAITools(for serverIds: [String]) -> [[String: Any]] {
        enabledTools(for: serverIds).map { resolved in
            [
                "type": "function",
                "function": [
                    "name": resolved.tool.name,
                    "description": resolved.tool.description,
                    "parameters": resolved.tool.schemaAny(),
                ],
            ]
        }
    }

    func anthropicTools(for serverIds: [String]) -> [[String: Any]] {
        enabledTools(for: serverIds).map { resolved in
            [
                "name": resolved.tool.name,
                "description": resolved.tool.description,
                "input_schema": resolved.tool.schemaAny(),
            ]
        }
    }

    func callToolText(serverIds: [String], toolName: String, argumentsJSON: String) async -> MCPToolExecutionResult {
        guard let resolved = enabledTools(for: serverIds).first(where: { $0.tool.name == toolName }) else {
            return MCPToolExecutionResult(text: "未知或未启用的 MCP 工具: \(toolName)", isError: true, serverName: nil)
        }

        let arguments = Self.arguments(from: argumentsJSON)
        do {
            guard let client = clients[resolved.serverId] else {
                await reconnectWithBackoff(resolved.serverId)
                guard let client = clients[resolved.serverId] else {
                    return MCPToolExecutionResult(text: "MCP server 未连接: \(resolved.serverName)", isError: true, serverName: resolved.serverName)
                }
                let result = try await client.callTool(name: toolName, arguments: arguments)
                return MCPToolExecutionResult(text: result.flattenedText, isError: result.isError, serverName: resolved.serverName)
            }
            let result = try await client.callTool(name: toolName, arguments: arguments)
            return MCPToolExecutionResult(text: result.flattenedText, isError: result.isError, serverName: resolved.serverName)
        } catch {
            statuses[resolved.serverId] = .error
            errors[resolved.serverId] = error.localizedDescription
            await reconnectWithBackoff(resolved.serverId)
            do {
                guard let client = clients[resolved.serverId] else { throw MCPError.connectionClosed }
                let result = try await client.callTool(name: toolName, arguments: arguments)
                statuses[resolved.serverId] = .connected
                errors.removeValue(forKey: resolved.serverId)
                return MCPToolExecutionResult(text: result.flattenedText, isError: result.isError, serverName: resolved.serverName)
            } catch {
                return MCPToolExecutionResult(
                    text: renderToolError(serverName: resolved.serverName, tool: resolved.tool, arguments: arguments, error: error),
                    isError: true,
                    serverName: resolved.serverName
                )
            }
        }
    }

    func prettyJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(servers),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decodeServersJSON(_ text: String) throws -> [MCPServerConfig] {
        let data = Data(text.utf8)
        return try JSONDecoder().decode([MCPServerConfig].self, from: data)
    }

    // MARK: - 凭证 Keychain（P1-20）

    /// headers 常含 Authorization: Bearer——与 API key 同标准走 Keychain，不落明文 plist
    private struct MCPSecrets: Codable {
        var headers: [String: String]
        var oauthClientSecret: String
        /// stdio 环境变量（plan-wake-mcp R-WM #1）；可选 → 老条目照解
        var env: [String: String]?
    }

    private static func secretsAccount(_ serverId: String) -> String { "mcp-\(serverId)" }

    private func removeSecrets(_ serverId: String) {
        KeychainStore.remove(account: Self.secretsAccount(serverId))
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.serversKey),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            servers = []
            return
        }
        servers = decoded
        // Keychain 回填；JSON 里还有旧明文（迁移前数据）的，下一次 persist 自动清洗入 Keychain
        var hasLegacyPlaintext = false
        for i in servers.indices {
            if let raw = KeychainStore.get(account: Self.secretsAccount(servers[i].id)),
               let secretData = raw.data(using: .utf8),
               let secrets = try? JSONDecoder().decode(MCPSecrets.self, from: secretData) {
                servers[i].headers = secrets.headers
                servers[i].oauthClientSecret = secrets.oauthClientSecret
                servers[i].env = secrets.env ?? [:]
            } else if !servers[i].headers.isEmpty || !servers[i].oauthClientSecret.isEmpty || !servers[i].env.isEmpty {
                hasLegacyPlaintext = true
            }
        }
        if hasLegacyPlaintext { persist() }
    }

    private func persist() {
        let split = Self.splitSecrets(servers)
        for entry in split.secrets {
            if let json = entry.json {
                KeychainStore.set(json, account: Self.secretsAccount(entry.id), sync: false)
            } else {
                removeSecrets(entry.id)
            }
        }
        if let data = try? JSONEncoder().encode(split.stored) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
    }

    /// 落盘拆分（纯函数）：写 UserDefaults 的去密钥副本 + 每条 Keychain 值（nil = 删）。
    /// headers / OAuth secret / stdio env 三样都不落明文。
    static func splitSecrets(_ servers: [MCPServerConfig]) -> (stored: [MCPServerConfig], secrets: [(id: String, json: String?)]) {
        var stored = servers
        var secrets: [(id: String, json: String?)] = []
        for i in stored.indices {
            let s = stored[i]
            if s.headers.isEmpty && s.oauthClientSecret.isEmpty && s.env.isEmpty {
                secrets.append((s.id, nil))
            } else {
                let payload = MCPSecrets(headers: s.headers, oauthClientSecret: s.oauthClientSecret, env: s.env.isEmpty ? nil : s.env)
                let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
                secrets.append((s.id, json))
            }
            stored[i].headers = [:]
            stored[i].oauthClientSecret = ""
            stored[i].env = [:]
        }
        return (stored, secrets)
    }

    private func startHeartbeat(_ serverId: String) {
        stopHeartbeat(serverId)
        heartbeatTasks[serverId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.heartbeat(serverId)
            }
        }
    }

    private func stopHeartbeat(_ serverId: String) {
        heartbeatTasks.removeValue(forKey: serverId)?.cancel()
    }

    private func heartbeat(_ serverId: String) async {
        guard status(for: serverId) == .connected,
              let client = clients[serverId] else { return }
        do {
            _ = try await client.listTools()
        } catch {
            statuses[serverId] = .error
            errors[serverId] = error.localizedDescription
            await reconnectWithBackoff(serverId)
        }
    }

    private func reconnectWithBackoff(_ serverId: String, attempts: Int = 3) async {
        guard !reconnecting.contains(serverId) else { return }
        reconnecting.insert(serverId)
        defer { reconnecting.remove(serverId) }
        for attempt in 0..<attempts {
            await reconnect(serverId)
            if status(for: serverId) == .connected { return }
            let delay = UInt64(600 * (1 << attempt)) * 1_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func renderToolError(serverName: String, tool: MCPToolConfig, arguments: [String: Any], error: Error) -> String {
        var payload: [String: Any] = [
            "type": "tool_error",
            "tool": tool.name,
            "server": serverName,
            "message": error.localizedDescription,
            "lastArguments": arguments,
            "instruction": "Revise arguments to satisfy parametersSchema, then call the same tool again.",
        ]
        payload["parametersSchema"] = tool.schemaAny()
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return error.localizedDescription
    }

    private static func params(from schema: [String: Any]) -> [MCPParamSpec] {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set((schema["required"] as? [Any] ?? []).map { "\($0)" })
        return properties.keys.sorted().map { key in
            let raw = properties[key] as? [String: Any] ?? [:]
            let typeValue = raw["type"]
            let type: String?
            if let typeString = typeValue as? String {
                type = typeString
            } else if let types = typeValue as? [Any] {
                type = types.map { "\($0)" }.joined(separator: "|")
            } else {
                type = nil
            }
            return MCPParamSpec(
                name: key,
                required: required.contains(key),
                type: type,
                defaultValue: raw["default"].map { JSONValue.fromAny($0) }
            )
        }
    }

    private static func arguments(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
