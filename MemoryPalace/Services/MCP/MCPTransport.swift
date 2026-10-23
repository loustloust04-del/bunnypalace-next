import Foundation

protocol MCPTransport: AnyObject {
    var onMessage: ((Any) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }

    func connect() async throws
    func send(_ message: [String: Any]) async throws
    func close()
}

enum MCPTransportFactory {
    static func makeTransport(for config: MCPServerConfig) throws -> MCPTransport {
        switch config.transport {
        case .sse:
            return try MCPSSETransport(serverURL: config.url, headers: config.headers)
        case .streamableHTTP:
            return try MCPStreamableHTTPTransport(serverURL: config.url, headers: config.headers)
        case .stdio:
            #if os(macOS)
            return try MCPStdioTransport(command: config.command, env: config.env)
            #else
            throw MCPError.serverError("本地命令型 MCP 只在 Mac 上可用")
            #endif
        }
    }
}
