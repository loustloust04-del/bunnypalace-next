import Foundation

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            let intValue = Int(value)
            return Double(intValue) == value ? intValue : value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.anyValue)
        case .array(let value): return value.map(\.anyValue)
        case .null: return NSNull()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    static func fromAny(_ value: Any) -> JSONValue {
        switch value {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as Float:
            return .number(Double(value))
        case let value as [String: Any]:
            return .object(value.mapValues { JSONValue.fromAny($0) })
        case let value as [Any]:
            return .array(value.map { JSONValue.fromAny($0) })
        default:
            return .null
        }
    }
}

enum MCPTransportType: String, Codable, CaseIterable {
    case sse
    case streamableHTTP
    /// 本地命令（stdio）：MP 起子进程、按行收发 JSON-RPC。只在 Mac 上能连（plan-wake-mcp）
    case stdio

    var displayName: String {
        switch self {
        case .sse: return "SSE"
        case .streamableHTTP: return "Streamable HTTP"
        case .stdio: return "本地命令"
        }
    }

    /// 编辑表单的可选项：iOS 起不了子进程，不出「本地命令」
    static var pickerCases: [MCPTransportType] {
        #if os(macOS)
        allCases
        #else
        [.sse, .streamableHTTP]
        #endif
    }
}

enum MCPConnectionStatus: String, Codable {
    case idle
    case connecting
    case connected
    case error
}

struct MCPParamSpec: Identifiable, Codable {
    var id: String { name }
    var name: String
    var required: Bool
    var type: String?
    var defaultValue: JSONValue?
}

struct MCPToolConfig: Identifiable, Codable {
    var id: String { name }
    var enabled: Bool
    var name: String
    var description: String
    var params: [MCPParamSpec]
    var schema: [String: JSONValue]

    func schemaAny() -> [String: Any] {
        schema.mapValues(\.anyValue)
    }
}

struct MCPServerConfig: Identifiable, Codable {
    var id: String
    var enabled: Bool
    var name: String
    var transport: MCPTransportType
    var url: String
    var headers: [String: String]
    var oauthClientId: String
    var oauthClientSecret: String
    /// stdio：一行 shell 命令（`/bin/zsh -c "exec <command>"`）
    var command: String
    /// stdio：追加给子进程的环境变量（可能含密钥 → 与 headers 同走 Keychain）
    var env: [String: String]
    var tools: [MCPToolConfig]

    enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case name
        case transport
        case url
        case headers
        case oauthClientId
        case oauthClientSecret
        case command
        case env
        case tools
    }

    init(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        name: String,
        transport: MCPTransportType = .sse,
        url: String,
        headers: [String: String] = [:],
        oauthClientId: String = "",
        oauthClientSecret: String = "",
        command: String = "",
        env: [String: String] = [:],
        tools: [MCPToolConfig] = []
    ) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.transport = transport
        self.url = url
        self.headers = headers
        self.oauthClientId = oauthClientId
        self.oauthClientSecret = oauthClientSecret
        self.command = command
        self.env = env
        self.tools = tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        oauthClientId = try container.decodeIfPresent(String.self, forKey: .oauthClientId) ?? ""
        oauthClientSecret = try container.decodeIfPresent(String.self, forKey: .oauthClientSecret) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        tools = try container.decodeIfPresent([MCPToolConfig].self, forKey: .tools) ?? []

        let rawTransport = try container.decodeIfPresent(String.self, forKey: .transport) ?? MCPTransportType.sse.rawValue
        switch rawTransport {
        case MCPTransportType.sse.rawValue:
            transport = .sse
        case MCPTransportType.streamableHTTP.rawValue, "http", "streamable_http", "streamable-http":
            transport = .streamableHTTP
        case MCPTransportType.stdio.rawValue:
            transport = .stdio
        default:
            transport = .sse
        }
    }
}

struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

struct MCPCallToolResult {
    let content: [[String: Any]]
    let isError: Bool

    var flattenedText: String {
        var lines: [String] = []
        for item in content {
            guard let type = item["type"] as? String else {
                if let data = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    lines.append(json)
                }
                continue
            }

            switch type {
            case "text":
                if let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(text)
                }
            case "resource":
                if let resource = item["resource"] as? [String: Any] {
                    if let text = resource["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append(text)
                    } else if let uri = resource["uri"] as? String, !uri.isEmpty {
                        lines.append("resource: \(uri)")
                    }
                } else if let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(text)
                } else if let uri = item["uri"] as? String, !uri.isEmpty {
                    lines.append("resource: \(uri)")
                }
            case "image":
                if let url = item["url"] as? String, !url.isEmpty {
                    lines.append("[image:\(url)]")
                } else if let mimeType = item["mimeType"] as? String {
                    lines.append("[image:\(mimeType)]")
                } else {
                    lines.append("[image]")
                }
            default:
                if let data = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    lines.append(json)
                }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MCPResolvedTool {
    let serverId: String
    let serverName: String
    let tool: MCPToolConfig
}

struct MCPToolExecutionResult {
    let text: String
    let isError: Bool
    let serverName: String?
}

enum MCPError: LocalizedError {
    case invalidURL(String)
    case connectionClosed
    case endpointTimeout
    case requestTimeout(String)
    case serverError(String)
    case protocolError(String)
    case unsupportedTransport

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "无效的 MCP 地址: \(value)"
        case .connectionClosed: return "MCP 连接已关闭"
        case .endpointTimeout: return "等待 MCP SSE endpoint 超时"
        case .requestTimeout(let method): return "MCP 请求超时: \(method)"
        case .serverError(let message): return message
        case .protocolError(let message): return "MCP 协议错误: \(message)"
        case .unsupportedTransport: return "当前不支持该 MCP transport"
        }
    }
}
