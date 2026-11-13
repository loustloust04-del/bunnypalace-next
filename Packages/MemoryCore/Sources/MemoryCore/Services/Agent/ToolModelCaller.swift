import Foundation

// 能带工具的模型调用口（plan-organize-agent §3.1）。和只有「一次 system + user」的 `ModelCaller` 并列，不替它。
// 这里只有值类型和协议；真去调模型的实现在外面（memoryd 直连 HTTP，app 接 `AssistantBackend`）。

/// 一个工具的说明：名字、给模型看的描述、参数的 JSON Schema（文本）
public struct AgentToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let schema: String

    public init(name: String, description: String, schema: String) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

/// 模型要调的一次工具：arguments 是 JSON 文本（模型给的原样）
public struct AgentToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AgentToolResult: Sendable, Equatable, Codable {
    public let callId: String
    public let content: String
    public let isError: Bool

    public init(callId: String, content: String, isError: Bool = false) {
        self.callId = callId
        self.content = content
        self.isError = isError
    }
}

/// 对话里的一段。assistant 的 reasoning 是有的接口要求原样带回去的思考（没有就 nil）
public enum AgentTurn: Sendable, Equatable {
    case user(String)
    case assistant(text: String, calls: [AgentToolCall], reasoning: String?)
    case toolResults([AgentToolResult])
}

public struct AgentUsage: Sendable, Equatable, Codable {
    public var input: Int
    public var output: Int
    /// 命中缓存的输入（接口没报 = nil）
    public var cacheRead: Int?

    public init(input: Int, output: Int, cacheRead: Int? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }
}

/// 模型这一轮回了什么：文字和 / 或工具调用
public struct AgentStep: Sendable, Equatable {
    public var text: String
    public var calls: [AgentToolCall]
    public var reasoning: String?
    public var usage: AgentUsage?
    /// 接口给的停止原因（原样，排查用）
    public var stop: String?

    public init(text: String = "", calls: [AgentToolCall] = [], reasoning: String? = nil, usage: AgentUsage? = nil, stop: String? = nil) {
        self.text = text
        self.calls = calls
        self.reasoning = reasoning
        self.usage = usage
        self.stop = stop
    }

    public var turn: AgentTurn { .assistant(text: text, calls: calls, reasoning: reasoning) }

    /// 写到输出上限被截断，而且什么都没交上（Anthropic 报 max_tokens，OpenAI 兼容报 length）
    public var truncated: Bool { calls.isEmpty && (stop == "max_tokens" || stop == "length") }
}

public protocol ToolModelCaller: Sendable {
    /// 一轮：系统提示 + 到目前为止的对话（含之前的工具调用和结果）+ 可用工具 → 这一轮的回复
    func step(system: String, turns: [AgentTurn], tools: [AgentToolSpec]) async throws -> AgentStep
}

/// 拿闭包当 `ToolModelCaller`（测试里放脚本化的假模型）
public struct ClosureToolModelCaller: ToolModelCaller, @unchecked Sendable {
    public typealias Body = (_ system: String, _ turns: [AgentTurn], _ tools: [AgentToolSpec]) async throws -> AgentStep

    private let body: Body

    public init(_ body: @escaping Body) {
        self.body = body
    }

    public func step(system: String, turns: [AgentTurn], tools: [AgentToolSpec]) async throws -> AgentStep {
        try await body(system, turns, tools)
    }
}
