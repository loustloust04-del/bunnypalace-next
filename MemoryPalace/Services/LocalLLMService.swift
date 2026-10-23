import Foundation
#if os(iOS)
import UIKit
#endif
#if !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

// MARK: - 本机模型推理（plan-小芽-v3 §1；前身是小芽 v2 P4 的 AssistantLocalBackend）
// 全 app 一个：小芽和主聊天都从这里跑。GPU 只有一块，所以**串行排队**——后来的等前面的跑完，
// 谁也不掐断谁（旧实现是新请求直接 cancel 旧的，两边同时用会互相打断）。
// iOS 模拟器里初始化 MLX 必崩（Metal 设备没有架构名，strlen(NULL)）→ 模拟器编成空壳。

@MainActor
final class LocalLLMService {
    static let shared = LocalLLMService()

    nonisolated static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// 一次排队的请求。调用方 cancel 之后不再收到任何事件
    @MainActor
    final class Job {
        fileprivate var task: Task<Void, Never>?
        fileprivate(set) var cancelledByCaller = false

        func cancel() {
            cancelledByCaller = true
            task?.cancel()
        }
    }

    private var tail: Task<Void, Never>?
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var observers: [NSObjectProtocol] = []

    /// 还有请求在跑或在排队
    var isBusy: Bool { !jobs.isEmpty }

    private init() {
        #if os(iOS)
        // 进后台不能再用 GPU；内存吃紧先放模型。两种情况都把在跑的停掉，并告诉调用方为什么停
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LocalLLMService.shared.unload() }
            })
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    private var container: ModelContainer?
    private var loadedDirectory: URL?
    #endif

    @discardableResult
    func run(modelId: String, request: AssistantBackendRequest,
             onEvent: @escaping @MainActor (AssistantBackendEvent) -> Void) -> Job {
        let job = Job()
        #if targetEnvironment(simulator)
        onEvent(.failed("模拟器里跑不了本机模型"))
        #else
        guard let directory = AssistantModelStore.installedDirectory(modelId: modelId) else {
            onEvent(.failed("本机模型还没下载——去「设置 › API › 本机模型」下载"))
            return job
        }
        let previous = tail
        let key = ObjectIdentifier(job)
        jobs[key] = job
        let task = Task { [weak self] in
            await previous?.value
            defer { self?.jobs[key] = nil }
            guard let self, !Task.isCancelled else { return }
            await self.runModel(directory: directory, request: request, job: job, onEvent: onEvent)
        }
        job.task = task
        tail = task
        #endif
        return job
    }

    /// 进后台 / 内存警告 / 本机开关关掉：停掉全部请求（没被调用方取消的会收到 failed），放掉模型
    func unload() {
        for job in jobs.values { job.task?.cancel() }
        releaseModel()
    }

    /// 小芽面板关了、mac 右栏切走：别人还在用就不动
    func unloadIfIdle() {
        if jobs.isEmpty { releaseModel() }
    }

    private func releaseModel() {
        #if !targetEnvironment(simulator)
        container = nil
        loadedDirectory = nil
        MLX.GPU.clearCache()
        #endif
    }

    #if !targetEnvironment(simulator)
    private func runModel(directory: URL, request: AssistantBackendRequest, job: Job,
                          onEvent: @escaping @MainActor (AssistantBackendEvent) -> Void) async {
        let chat = Self.chat(for: request)
        let tools = request.tools.map(Self.sendable).compactMap { $0 as? [String: any Sendable] }
        let maxTokens = request.maxTokens
        do {
            let loadStart = Date()
            let wasLoaded = container != nil && loadedDirectory == directory
            let container = try await load(directory)
            let loadSecs = wasLoaded ? nil : Date().timeIntervalSince(loadStart)
            let (tokens, continuation) = AsyncStream<String>.makeStream()
            // token 从推理线程经 AsyncStream 回主线程，不把主线程闭包带进 Sendable 闭包
            let relay = Task { @MainActor in
                for await token in tokens where !job.cancelledByCaller { onEvent(.token(token)) }
            }
            let input = UserInput(chat: chat, tools: tools.isEmpty ? nil : tools, additionalContext: ["enable_thinking": request.enableThinking])
            let (turn, timing) = try await container.perform { context -> (AssistantLocalTurn, LocalTiming) in
                var turn = AssistantLocalTurn()
                var timing = LocalTiming(start: Date())
                let lm = try await context.processor.prepare(input: input)
                // 3.31.3 的 generate 没有 tools 参数：工具定义只经 UserInput 进对话模板，解析器按模型配置认 Qwen 的格式（实测可用）
                let stream = try MLXLMCommon.generate(input: lm, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.6),
                                          context: context)
                for await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let text):
                        if timing.firstChunk == nil { timing.firstChunk = Date() }
                        turn.append(chunk: text)
                        if !AssistantLocalTurn.looksLikeToolMarkup(turn.text) { continuation.yield(text) }
                    case .toolCall(let call):
                        if timing.firstChunk == nil { timing.firstChunk = Date() }
                        turn.append(call: call.function.name, argumentsJSON: Self.json(call.function.arguments))
                    case .info(let info):
                        timing.info = info
                    }
                }
                return (turn, timing)
            }
            continuation.finish()
            await relay.value
            BreadcrumbLog.shared.add("🌱", timing.summary(model: directory.lastPathComponent, loadSecs: loadSecs))
            guard !job.cancelledByCaller else { return }
            onEvent(Task.isCancelled ? .failed(Self.interruptedMessage) : turn.terminal)
        } catch {
            guard !job.cancelledByCaller else { return }
            onEvent(.failed(Task.isCancelled ? Self.interruptedMessage : "本机模型出错了：\(error.localizedDescription)"))
        }
    }

    private static let interruptedMessage = "本机模型被停下了（app 进了后台或内存不够），再发一次试试"

    private func load(_ directory: URL) async throws -> ModelContainer {
        if let container, loadedDirectory == directory { return container }
        container = nil
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)
        let loaded = try await loadModelContainer(from: directory, using: LocalTokenizerLoader())
        container = loaded
        loadedDirectory = directory
        return loaded
    }

    // MARK: 转换

    /// 历史（user / assistant）+ 工具回合（astra A7）。3.31.3 的消息不带工具调用 / id，
    /// 所以按 Qwen 原生格式写：assistant 正文里放 <tool_call>{…}</tool_call>，结果用 tool 角色按顺序跟在后面
    nonisolated static func chat(for request: AssistantBackendRequest) -> [Chat.Message] {
        var messages: [Chat.Message] = [.system(request.system)]
        for item in request.history {
            messages.append(item.role == "user" ? .user(item.content) : .assistant(item.content))
        }
        for (index, turn) in request.toolTurns.enumerated() {
            if let nudge = request.nudge, nudge.afterTurns == index {
                messages += [.assistant(nudge.reply), .user(AssistantNudge.note)]
            }
            messages.append(.assistant(turn.calls.map(toolCallText).joined(separator: "\n")))
            for result in turn.results {
                messages.append(.tool((result.isError ? "[error] " : "") + result.text))
            }
        }
        if let nudge = request.nudge, nudge.afterTurns >= request.toolTurns.count {
            messages += [.assistant(nudge.reply), .user(AssistantNudge.note)]
        }
        return messages
    }

    nonisolated static func toolCallText(_ call: ToolCallBlock) -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) ?? [String: Any]()
        let payload: [String: Any] = ["name": call.name, "arguments": arguments]
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "<tool_call>\n\(json)\n</tool_call>"
    }

    nonisolated static func json(_ arguments: [String: MLXLMCommon.JSONValue]) -> String {
        let object = arguments.mapValues(\.anyValue)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    #endif

    /// 我们的工具定义是 [String: Any]，MLX 要 [String: any Sendable]：递归转，不用 as!
    nonisolated static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dict as [String: Any]: return dict.mapValues { sendable($0) }
        case let array as [Any]: return array.map { sendable($0) }
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let d as Double: return d
        default: return String(describing: value)
        }
    }
}

#if !targetEnvironment(simulator)
/// 本机一轮的耗时打点（plan-小芽-v3 P0）：进反馈页的操作记录，Air 上实测用
private struct LocalTiming: Sendable {
    let start: Date
    var firstChunk: Date?
    var info: GenerateCompletionInfo?

    func summary(model: String, loadSecs: TimeInterval?) -> String {
        let load = loadSecs.map { String(format: "加载 %.1fs · ", $0) } ?? ""
        let first = firstChunk.map { String(format: "首字 %.1fs", $0.timeIntervalSince(start)) } ?? "无输出"
        guard let info else { return "本机 \(model) · \(load)\(first)" }
        return String(format: "本机 %@ · %@prompt %d tok 预填 %.1fs(%.0f/s) · %@ · 生成 %d tok %.0f/s",
                      model, load, info.promptTokenCount, info.promptTime, info.promptTokensPerSecond,
                      first, info.generationTokenCount, info.tokensPerSecond)
    }
}

/// swift-transformers 的分词器接到 MLX 的协议上（照 MLXHuggingFaceMacros 的 TokenizerBridge 展开，不引宏）
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}
#endif

// MARK: - 主聊天用的本机 provider（ProviderRouter 碰到「本机模型」卡转到这里）
// 不下发工具（联网 / MCP 那套 schema 太大，小模型扛不住）；上下文按字数封顶（中文约一字一 token）：
// system 截 3000 字，历史从新往旧装到总共 6000 字；图片看不见，如实告诉模型。

@Observable
final class LocalChatProvider {
    var isStreaming = false
    var streamingContent = ""
    var error: String?
    @ObservationIgnored private var job: LocalLLMService.Job?

    static let systemBudget = 3000
    static let totalBudget = 6000

    static func trimmed(system: String, messages: [(role: String, content: String)], hasImages: Bool)
        -> (system: String, history: [(role: String, content: String)]) {
        var system = system.count > systemBudget ? String(system.prefix(systemBudget)) + "…" : system
        if hasImages { system += "\n\n（用户发了图片，但你看不到图片内容；问题要靠图片才能答的话，直说看不到。）" }
        var budget = max(totalBudget - system.count, 500)
        var history: [(role: String, content: String)] = []
        for message in messages.reversed() {
            if message.content.count <= budget {
                history.insert(message, at: 0)
                budget -= message.content.count
            } else {
                if history.isEmpty { history.insert((message.role, String(message.content.suffix(budget))), at: 0) }
                break
            }
        }
        return (system, history)
    }

    func send(modelId: String, messages: [(role: String, content: String)], systemPrompt: String?, hasImages: Bool,
              thinking: Bool = false,
              onToken: @escaping (String) -> Void,
              onComplete: @escaping (String, TokenUsage?) -> Void,
              onError: @escaping (String) -> Void) {
        let (system, history) = Self.trimmed(system: systemPrompt ?? "", messages: messages, hasImages: hasImages)
        var request = AssistantBackendRequest(system: system, history: history, tools: [], toolTurns: [],
                                              maxTokens: thinking ? 4096 : 2048)   // 想的部分也吃上限
        request.enableThinking = thinking
        // 开思考时模型吐 <think>…</think>：换成 [thinking]…[/thinking]，收进思考气泡
        let converter = ThinkTagConverter()
        Task { @MainActor in
            self.job?.cancel()
            self.isStreaming = true
            self.streamingContent = ""
            self.error = nil
            self.job = LocalLLMService.shared.run(modelId: modelId, request: request) { [weak self] event in
                guard let self else { return }
                switch event {
                case .token(let raw):
                    let token = thinking ? converter.feed(raw) : raw
                    guard !token.isEmpty else { return }
                    self.streamingContent += token
                    onToken(token)
                case .finished(let text):
                    self.isStreaming = false
                    if thinking {
                        let whole = ThinkTagConverter()
                        onComplete(whole.feed(text) + whole.flush(), nil)
                    } else {
                        onComplete(text, nil)
                    }
                case .toolCalls:
                    self.isStreaming = false
                    onComplete(self.streamingContent, nil)
                case .failed(let message):
                    self.isStreaming = false
                    self.error = message
                    onError(message)
                }
            }
        }
    }

    func cancel() {
        Task { @MainActor in
            self.job?.cancel()
            self.job = nil
            self.isStreaming = false
        }
    }
}
