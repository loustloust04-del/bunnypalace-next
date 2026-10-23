import Foundation

// MARK: - 小芽 v2 · P4 后端抽层（plan-小芽-v2 §6.1 v1.1，astra A7）
// 引擎只认这一层的事件：云端 = 现有 ProviderRouter（行为不变），本机 = MLX（AssistantLocalBackend）。
// 契约：一次 run 只有一个终止事件——toolCalls(本轮全部) 或 finished(全文) 或 failed；token 在终止前任意多个。

enum AssistantBackendEvent {
    case token(String)
    case toolCalls([ToolCallBlock])
    case finished(String)
    case failed(String)
}

struct AssistantBackendRequest {
    var system: String
    var history: [(role: String, content: String)]
    var tools: [[String: Any]]
    var toolTurns: [ToolTurn]
    /// 本机推理生成上限（小芽 800；主聊天长一些）
    var maxTokens = 800
    /// 本地大脑嘴上说交了提案、其实没调工具时追的一句（只本机用；插在第 afterTurns 个工具回合之后）
    var nudge: AssistantNudge? = nil
    /// 本机 Qwen3 开思考（主聊天的思考强度选「开」，research-reasoning-effort §2.3）；小芽不开
    var enableThinking = false
}

struct AssistantNudge {
    var afterTurns: Int
    var reply: String
    static let note = "（系统提醒，不是用户说的：你刚才没有调用任何工具，所以其实没有提案卡。现在直接调用对应的 propose_ 工具，把你刚才说的内容作为参数交成提案；不要再问用户。）"
}

@MainActor
protocol AssistantBackend: AnyObject {
    /// onEvent 一律在主线程回调
    func run(_ request: AssistantBackendRequest, onEvent: @escaping @MainActor (AssistantBackendEvent) -> Void)
    func cancel()
}

// MARK: - 云端：包住现有 ProviderRouter，行为不变

@MainActor
final class AssistantCloudBackend: AssistantBackend {
    private let router = ProviderRouter(usageContext: UsageContext(kind: .assistant))
    private let model: ProviderModel
    private let providerManager: ProviderManager

    init(model: ProviderModel, providerManager: ProviderManager) {
        self.model = model
        self.providerManager = providerManager
    }

    func run(_ request: AssistantBackendRequest, onEvent: @escaping @MainActor (AssistantBackendEvent) -> Void) {
        router.sendStreaming(
            model: model,
            messages: request.history,
            systemPrompt: request.system,
            providerManager: providerManager,
            tools: request.tools,
            toolTurns: request.toolTurns,
            onToken: { token in Task { @MainActor in onEvent(.token(token)) } },
            onComplete: { fullText, _ in Task { @MainActor in onEvent(.finished(fullText)) } },
            onError: { error in Task { @MainActor in onEvent(.failed("\(error)")) } },
            onToolCalls: { calls, _ in Task { @MainActor in onEvent(.toolCalls(calls)) } }
        )
    }

    func cancel() { router.cancel() }
}

// MARK: - 本地一轮的收集器（纯逻辑，测试不用加载模型）

/// 把 MLX 流里陆续来的文本块 / 工具调用收齐，流结束时只给一个终止事件（astra A7）。
/// 解析失败时 MLX 会把残缺的工具调用当普通文本吐出来——这里拦下，换成一句「没弄懂」，不把半截 JSON 显示给她。
extension ToolCallBlock: @unchecked Sendable {}

struct AssistantLocalTurn: Sendable {
    private(set) var text = ""
    private(set) var calls: [ToolCallBlock] = []

    mutating func append(chunk: String) { text += chunk }

    mutating func append(call name: String, argumentsJSON: String) {
        calls.append(ToolCallBlock(id: "local-\(calls.count)-\(UUID().uuidString.prefix(8))", name: name, argumentsJSON: argumentsJSON))
    }

    /// 流里途中能不能把这块文本直接显示（残缺工具调用的开头不显示）
    static func looksLikeToolMarkup(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("<tool_call>") || t.hasPrefix("{\"name\"") || t.hasPrefix("<|")
    }

    static let garbledReply = "唔…我没弄懂，换个说法再跟我说一次？"

    var terminal: AssistantBackendEvent {
        if !calls.isEmpty { return .toolCalls(calls) }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeToolMarkup(t) { return .failed(Self.garbledReply) }   // 舞台出 Sob，不把半截 JSON 显示出来
        return .finished(t)
    }
}
