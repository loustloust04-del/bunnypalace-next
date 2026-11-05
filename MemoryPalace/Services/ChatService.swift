import Foundation

// MARK: - Cache Diagnostic Log（app 内常驻探针，设置→调试 可看）

/// 每轮请求/usage 的缓存诊断记录，环形 60 条。粟粟验收缓存不用挂 console。
@Observable
final class CacheDiagLog {
    static let shared = CacheDiagLog()
    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }
    private(set) var entries: [Entry] = []

    func log(_ text: String) {
        DispatchQueue.main.async {
            self.entries.append(Entry(text: text))
            if self.entries.count > 60 { self.entries.removeFirst(self.entries.count - 60) }
        }
    }

    var fullText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return entries.map { "\(f.string(from: $0.time)) \($0.text)" }.joined(separator: "\n")
    }
}

// MARK: - Chat Provider Protocol

@Observable
class BaseChatProvider: NSObject {
    /// 缓存标：默认 1 小时（粟粟 10-15：隔几分钟回一条时 5 分钟存不住，每条都全价重写）；预设选了 5 分钟就用 API 默认
    static func cacheMark(_ samplingParams: SamplingParams?) -> [String: Any] {
        samplingParams?.cacheLongTTL ?? true ? ["type": "ephemeral", "ttl": "1h"] : ["type": "ephemeral"]
    }

    /// 请求体序列化一律排序键：Swift 字典每个实例遍历顺序不同，不排序 = 工具 schema / 历史 tool_use 的 input 每轮换顺序，
    /// 提示缓存前缀从头对不上、每轮只写不读（10-14 起，docs/research-cache-miss-1015.md）
    static func encodeBody(_ body: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    var isStreaming = false
    var streamingContent = ""
    var error: String?

    internal var currentTask: URLSessionDataTask?
    internal var urlSession: URLSession?
    internal var sseDecoder = SSELineDecoder()
    internal var errorBytes = Data()
    internal var errorBody: String { String(decoding: errorBytes, as: UTF8.self) }
    internal var httpStatusCode: Int = 0
    internal var receivedDone = false
    /// 流内 error 事件已分发（同步记，不等排队回调落地）：兜底结算见到它就不再收尾；不碰 receivedDone（它管 usage 完整性）
    internal var terminatedByError = false
    /// 错误归类用（plan-model-compat-p0 §7.3）：响应头（小写键）、流内 error 那一片的原始 JSON、网络错误码
    internal var responseHeaders: [String: String] = [:]
    internal var streamErrorBody: String?
    internal var urlErrorCode: Int?
    /// 非流式回包（research-nonstream-chat）：按服务器实际回的 Content-Type 判 SSE 还是整包 JSON
    /// （中转可能无视 stream:false），整包攒在 rawBody，完成时解析 + 假流式吐出
    internal var isEventStream = false
    internal var rawBody = Data()
    /// 假流式代际：cancel / 新请求即 +1，吐块 Task 每块前核对，陈旧回调不落地
    internal var pacedGeneration = 0
    @ObservationIgnored private var budgetPreflightTask: Task<Void, Never>?
    @ObservationIgnored var tokenCounter = OfficialTokenCounter()
    @ObservationIgnored var budgetState: () -> BudgetPreflight.State = { .current }
    internal var sessionGeneration: Int? = nil
    internal private(set) var requestPending = false
    internal var requestWasSent = false
    internal var onToken: ((String) -> Void)?
    internal var onComplete: ((String, TokenUsage?) -> Void)?
    internal var onError: ((String) -> Void)?
    internal var onToolCalls: (([ToolCallBlock]) -> Void)?
    /// 流式过程中累积的 token 用量。usage 信息常在 stream 末尾或分事件到来。
    internal var accumulatedInputTokens: Int = 0
    internal var accumulatedOutputTokens: Int = 0
    internal var accumulatedCacheReadTokens: Int? = nil
    internal var accumulatedCacheWriteTokens: Int? = nil
    internal var accumulatedReasoningTokens: Int? = nil
    internal var accumulatedReportedCostUSD: Double? = nil
    internal var accumulatedCacheWrite1hTokens: Int? = nil
    internal var accumulatedWebSearches: Int? = nil
    internal var accumulatedResponseId: String? = nil
    internal var usageBaseURL = ""
    internal var usageCacheWriteIs1h = false
    /// #089 P0-c：过了保险闸、真发出去那一刻回调一次（router 按对话存真实请求体）
    var onRequestSent: ((URLRequest) -> Void)?
    internal var requestEstimatedCost: Double? = nil
    internal var nonStreamUsageState: UsageCompleteness? = nil
    internal var finalEventUsageState: UsageCompleteness? = nil
    internal var gotUsage = false
    /// 本次回复停在输出上限（OpenAI finish_reason=length / Anthropic stop_reason=max_tokens）
    internal(set) var hitOutputLimit = false
    /// #094：这次实发 body 的顶层键 + 几个值（400 自愈只认真发了的字段）
    internal var sentShape = ParamErrorClassifier.SentShape()
    /// thinking 回传 astra #3：这次请求回传的思考块按输入计（保险闸用）
    internal var echoedThinking = BudgetPreflight.EchoedThinking()
    /// OpenAI 兼容路这一次回复的思考（plan-model-compat-p0 §4）；别家不填
    internal var reasoning = ReasoningCapture()

    /// 这一次已经开始输出（正文 / 思考 / 工具调用，Q11）：出错不再自动重发
    var hasEmittedOutput: Bool { !streamingContent.isEmpty || receivedDone }

    internal var finalUsage: TokenUsage? {
        (gotUsage || accumulatedResponseId != nil || accumulatedReportedCostUSD != nil) ? TokenUsage(inputTokens: accumulatedInputTokens, outputTokens: accumulatedOutputTokens,
                              cacheReadTokens: accumulatedCacheReadTokens, cacheWriteTokens: accumulatedCacheWriteTokens,
                              reasoningTokens: accumulatedReasoningTokens,
                              reportedCostUSD: accumulatedReportedCostUSD, cacheWrite1hTokens: accumulatedCacheWrite1hTokens,
                              webSearches: accumulatedWebSearches, responseId: accumulatedResponseId,
                              completeness: nonStreamUsageState ?? finalEventUsageState ?? (gotUsage ? (receivedDone ? .complete : .snapshot) : .missing)) : nil
    }

    internal func enqueueCallback(_ callback: @escaping () -> Void) {
        let generation = pacedGeneration
        DispatchQueue.main.async { [self] in
            guard pacedGeneration == generation else { return }
            callback()
        }
    }

    /// SSE 行分发（processData 和流结束 flush 共用）
    func handle(_ fields: [SSELineDecoder.Field]) {}

    /// 没收到 [DONE] 就结束的流：子类把压着没吐的正文排队吐出（返回 true = 排了回调，结算要排在它后面）
    func flushHeldContent() -> Bool { false }

    func sendStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        samplingParams: SamplingParams? = nil,
        imageMap: [String: [PendingChatAttachment]] = [:],
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        ordered: [PromptMessage]? = nil,   // ④b：有序消息序列；非 nil 时 OpenAI 兼容 / Anthropic 按它构造请求体，其余 provider 忽略（仍用 messages / systemPrompt）
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void,
        onToolCalls: (([ToolCallBlock]) -> Void)? = nil
    ) {
        fatalError("Subclass must implement")
    }

    func cancel() {
        budgetPreflightTask?.cancel()
        budgetPreflightTask = nil
        currentTask?.cancel()
        currentTask = nil
        urlSession = nil
        sessionGeneration = nil
        requestPending = false
        isStreaming = false
        pacedGeneration += 1
    }

    // MARK: - 非流式回包（research-nonstream-chat）

    struct NonStreamResult {
        var text: String
        var toolCalls: [ToolCallBlock]
        var usage: TokenUsage?
        var hitOutputLimit = false
        var reasoning = ReasoningCapture()
    }

    /// 子类按各家格式解析整包；字段对齐流式路径已支持的（文本 / 工具调用 / usage / 联网来源）
    func parseNonStreamBody(_ data: Data) throws -> NonStreamResult {
        throw Self.unparsableBody(data)
    }

    /// 整包 → JSON 对象。Foundation 整包拒收落单的 \uD800–\uDFFF 转义（JS 的 JSON.stringify 会原样吐出来，
    /// claude-proxy 就是 node），解不开就把落单的换成 � 再解一次
    static func nonStreamObject(_ data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        return (try? JSONSerialization.jsonObject(with: replacingLoneSurrogateEscapes(data))) as? [String: Any]
    }

    static func replacingLoneSurrogateEscapes(_ data: Data) -> Data {
        let b = [UInt8](data)
        func escape(at i: Int) -> UInt16? {
            guard i + 5 < b.count, b[i] == 0x5C, b[i + 1] == 0x75,
                  let v = UInt16(String(decoding: b[(i + 2)..<(i + 6)], as: UTF8.self), radix: 16) else { return nil }
            return v
        }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            guard b[i] == 0x5C, i + 1 < b.count else { out.append(b[i]); i += 1; continue }
            guard let v = escape(at: i) else { out.append(contentsOf: b[i...i + 1]); i += 2; continue }
            if (0xD800...0xDBFF).contains(v), let low = escape(at: i + 6), (0xDC00...0xDFFF).contains(low) {
                out.append(contentsOf: b[i..<(i + 12)]); i += 12
            } else if (0xD800...0xDFFF).contains(v) {
                out.append(contentsOf: Array("\\ufffd".utf8)); i += 6
            } else {
                out.append(contentsOf: b[i..<(i + 6)]); i += 6
            }
        }
        return Data(out)
    }

    /// 解不开的整包：错误里带回包开头 200 字（设置页 / 健康状态直接看得到），诊断日志也记一份
    static func unparsableBody(_ data: Data) -> NSError {
        let head = String(String(decoding: data.prefix(800), as: UTF8.self).prefix(200))
        CacheDiagLog.shared.log("⚠️ 非流式回包解析失败（\(data.count) 字节）：\(head)")
        let detail = head.isEmpty ? "回包是空的" : "回包开头：\(head)"
        return NSError(domain: "ChatService", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法解析响应（\(detail)）"])
    }

    /// 主线程。解析失败走 onError；成功 → 假流式吐文本 → onToolCalls / onComplete
    internal func handleNonStreamBody() {
        let result: NonStreamResult
        do {
            result = try parseNonStreamBody(rawBody)
        } catch {
            let msg = error.localizedDescription
            self.error = msg
            onError?(msg)
            return
        }
        emitPaced(result)
    }

    /// 假流式：整包文本切块经 onToken 吐（块 = max(20, len/40) 字符、150ms 一块 → 最长 ~6s），
    /// 节拍器把空档填成连续打字；VM / 工具循环 / view 零改动。吐完再 onToolCalls / onComplete。
    private func emitPaced(_ result: NonStreamResult) {
        if let usage = result.usage {
            nonStreamUsageState = usage.completeness
            accumulatedInputTokens = usage.inputTokens
            accumulatedOutputTokens = usage.outputTokens
            accumulatedCacheReadTokens = usage.cacheReadTokens
            accumulatedCacheWriteTokens = usage.cacheWriteTokens
            accumulatedReasoningTokens = usage.reasoningTokens
            accumulatedReportedCostUSD = usage.reportedCostUSD
            accumulatedCacheWrite1hTokens = usage.cacheWrite1hTokens
            accumulatedWebSearches = usage.webSearches
            accumulatedResponseId = usage.responseId
            gotUsage = true
        }
        hitOutputLimit = result.hitOutputLimit
        reasoning = result.reasoning
        let gen = pacedGeneration
        let text = result.text
        // 关闭流式档：整包一次显示（一块）；假流式档：max(20, len/40) 字/块
        let chunkLen = StreamingPreference.instantDisplay ? max(1, text.count) : max(20, text.count / 40)
        var chunks: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: chunkLen, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[idx..<end]))
            idx = end
        }
        isStreaming = true
        #if DEBUG
        #if DEBUG
        print("[NonStream] body=\(rawBody.count)B text=\(text.count) chunks=\(chunks.count)x\(chunkLen) tools=\(result.toolCalls.count) usage=\(String(describing: result.usage))")
        #endif
        #endif
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (i, c) in chunks.enumerated() {
                guard gen == self.pacedGeneration else { return }
                self.streamingContent += c
                self.onToken?(c)
                if i < chunks.count - 1 { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
            guard gen == self.pacedGeneration else { return }
            self.isStreaming = false
            if !result.toolCalls.isEmpty, let cb = self.onToolCalls {
                cb(result.toolCalls)
            } else {
                self.onComplete?(self.streamingContent, result.usage)
            }
        }
    }


    internal func resetState(onToken: @escaping (String) -> Void, onComplete: @escaping (String, TokenUsage?) -> Void, onError: @escaping (String) -> Void) {
        cancel()
        self.onToken = onToken
        self.onComplete = onComplete
        self.onError = onError
        self.streamingContent = ""
        self.error = nil
        self.isStreaming = true
        self.sseDecoder.reset()
        self.errorBytes = Data()
        self.httpStatusCode = 0
        self.receivedDone = false
        self.terminatedByError = false
        self.responseHeaders = [:]
        self.streamErrorBody = nil
        self.urlErrorCode = nil
        self.isEventStream = false
        self.rawBody = Data()
        self.accumulatedInputTokens = 0
        self.accumulatedOutputTokens = 0
        self.accumulatedCacheReadTokens = nil
        self.accumulatedCacheWriteTokens = nil
        self.accumulatedReasoningTokens = nil
        self.accumulatedReportedCostUSD = nil
        self.accumulatedCacheWrite1hTokens = nil
        self.accumulatedWebSearches = nil
        self.accumulatedResponseId = nil
        self.requestEstimatedCost = nil
        self.requestWasSent = false
        self.nonStreamUsageState = nil
        self.finalEventUsageState = nil
        self.gotUsage = false
        self.hitOutputLimit = false
        self.sentShape = ParamErrorClassifier.SentShape()
        self.echoedThinking = BudgetPreflight.EchoedThinking()
        self.reasoning = ReasoningCapture()
    }

    internal func startRequest(_ request: URLRequest) {
        let generation = pacedGeneration
        requestPending = true
        if let decision = BudgetPreflight.immediateDecision(request, echoed: echoedThinking, state: budgetState) {
            finishBudgetPreflight(decision, request: request)
            return
        }
        budgetPreflightTask = Task { @MainActor [self] in
            defer {
                if self.pacedGeneration == generation { self.budgetPreflightTask = nil }
            }
            let decision = await BudgetPreflight.decision(request, counter: self.tokenCounter, echoed: self.echoedThinking, state: self.budgetState)
            guard !Task.isCancelled, self.pacedGeneration == generation else { return }
            self.finishBudgetPreflight(decision, request: request)
        }
    }

    private func finishBudgetPreflight(_ decision: BudgetPreflight.Decision, request: URLRequest) {
        requestPending = false
        requestEstimatedCost = decision.estimatedCost
        guard decision.allowed else {
            isStreaming = false
            onError?(FixJump.budgetPreflightMessage)
            return
        }
        startBudgetCheckedRequest(request)
    }

    internal func startBudgetCheckedRequest(_ request: URLRequest) {
        let generation = pacedGeneration
        let delegate = ChatRequestDelegate(owner: self, generation: generation)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        sessionGeneration = generation
        self.urlSession = session
        let task = session.dataTask(with: request)
        currentTask = task
        requestWasSent = true
        onRequestSent?(request)
        task.resume()
    }

    internal func handleErrorBody() -> String {
        Self.errorMessage(from: Data(errorBody.utf8), statusCode: httpStatusCode)
    }

    /// 出错正文 → 一句话：`{"error":{"message"}}` / `{"error":"…"}`；
    /// #094 补形状：顶层数组（Gemini 兼容口）、`detail`（FastAPI / vLLM，字符串或 `[{loc, msg}]`）、
    /// OpenRouter 的 `error.metadata.raw`（上游原文接在「Provider returned error」后面）。都取不到才是「API 错误 (状态码)」
    static func errorMessage(from data: Data, statusCode: Int) -> String {
        let fallback = "API 错误 (\(statusCode))"
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let obj = (parsed as? [String: Any]) ?? ((parsed as? [Any])?.first as? [String: Any]) else { return fallback }
        if let err = obj["error"] as? [String: Any], let detail = err["message"] as? String {
            let msg = readableError(type: err["type"] as? String, message: detail)
            if let raw = (err["metadata"] as? [String: Any])?["raw"] as? String {
                let inner = errorMessage(from: Data(raw.utf8), statusCode: statusCode)
                let upstream = inner == fallback ? String(raw.prefix(300)) : inner
                if !upstream.isEmpty, upstream != detail { return msg + "：" + upstream }
            }
            return msg
        }
        if let err = obj["error"] as? String { return err }
        if let detail = obj["detail"] as? String { return detail }
        if let details = obj["detail"] as? [[String: Any]] {
            let lines = details.compactMap { item -> String? in
                guard let msg = item["msg"] as? String else { return nil }
                let loc = (item["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".")
                return loc.map { "\($0): \(msg)" } ?? msg
            }
            if !lines.isEmpty { return lines.joined(separator: "；") }
        }
        if let message = obj["message"] as? String { return message }
        return fallback
    }

    /// 非流式调用 — 用于 memory agent 等后台任务。images 用于图片转述（M7），text-only 调用传空。
    func sendNonStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        images: [PendingChatAttachment] = []
    ) async throws -> (String, TokenUsage?) {
        fatalError("Subclass must implement")
    }

    /// 从非流式响应体中提取错误信息
    fileprivate static func extractError(from data: Data, statusCode: Int) -> String {
        errorMessage(from: data, statusCode: statusCode)
    }

    /// Anthropic 模型下线 / 没开通只回一句「model: xxx」，看着像没回话 → 说人话
    static func readableError(type: String?, message: String) -> String {
        guard type == "not_found_error", message.hasPrefix("model: ") else { return message }
        return "这个 key 用不了模型 \(message.dropFirst(7))（已下线或没开通），换一个模型试试"
    }
}

/// URLSession 持有的不可变代际；delegate 与解析、快照、终止结算都在主线程串行执行。
final class ChatRequestDelegate: NSObject, URLSessionDataDelegate {
    let owner: BaseChatProvider
    let generation: Int
    init(owner: BaseChatProvider, generation: Int) { self.owner = owner; self.generation = generation }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard owner.accepts(session, generation: generation) else { return }
        owner.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        guard owner.accepts(session, generation: generation) else { return }
        owner.urlSession(session, task: task, didCompleteWithError: error)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard owner.accepts(session, generation: generation) else { completionHandler(.cancel); return }
        owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
}

extension BaseChatProvider: URLSessionDataDelegate {
    /// 陈旧回调守卫（2026-08-25）：工具循环里同一个 provider 实例跨轮复用，每轮 `startRequest` 建新
    /// URLSession。上一轮的连接常常在**下一轮已经开始后**才回调（TCP 关闭有延迟），此时读到的全是新一轮
    /// 的状态：`receivedDone` 已被 startStreaming 重置、`isStreaming` 是新轮的、内容还空 →
    /// 误报「未收到回复」，并顺手把新轮的 isStreaming 置 false、urlSession 清 nil（取消按钮失效）。
    /// 症状：工具调用明明成功、正文也出来了，气泡里却挂着 ⚠️ 未收到回复（粟粟 08-25 设备工具首验实拍）。
    internal func accepts(_ session: URLSession, generation: Int) -> Bool {
        urlSession === session && sessionGeneration == generation && pacedGeneration == generation && !requestPending
    }

    private func isStale(_ session: URLSession) -> Bool {
        guard let generation = sessionGeneration else { return true }
        return !accepts(session, generation: generation)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isStale(session) { return }
        if httpStatusCode == 200, !isEventStream {
            // 没标 event-stream 但 body 长得像 SSE（缺头的中转）→ 按 SSE 走
            let head = String(decoding: data.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawBody.isEmpty, head.hasPrefix("data:") || head.hasPrefix("event:") || head.hasPrefix(":") {
                isEventStream = true
            } else {
                rawBody.append(data)
                return
            }
        }
        processData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if isStale(session) { return }
        let wasStreaming = isStreaming
        isStreaming = false
        urlSession = nil

        if let error = error as? NSError, error.code != NSURLErrorCancelled {
            // 流内 error 已经排了 onError（终态只报一次）：随后的连接异常不再报第二次
            if terminatedByError { return }
            let msg = error.localizedDescription
            urlErrorCode = error.code
            self.error = msg
            onError?(msg)
            return
        }

        let tail = isEventStream && httpStatusCode == 200 ? sseDecoder.finish() : []
        if !tail.isEmpty { handle(tail) }

        if receivedDone { return }

        if httpStatusCode != 0 && httpStatusCode != 200 {
            onHTTPError()
            let msg = handleErrorBody()
            self.error = msg
            onError?(msg)
            return
        }

        if !isEventStream, !rawBody.isEmpty {
            handleNonStreamBody()
            return
        }

        if wasStreaming {
            let flushed = !terminatedByError && flushHeldContent()
            let settle = { [self] in
                if terminatedByError { return }
                if streamingContent.isEmpty {
                    let msg = "未收到回复"
                    self.error = msg
                    onError?(msg)
                } else {
                    onComplete?(streamingContent, finalUsage)
                }
            }
            // 末行里的正文 / 压着的正文是排队落地的，等它落完再结算
            if tail.isEmpty, !flushed { settle() } else { enqueueCallback(settle) }
        }
    }


    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if isStale(session) { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse {
            httpStatusCode = http.statusCode
            responseHeaders = Dictionary(http.allHeaderFields.map { ("\($0.key)".lowercased(), "\($0.value)") }) { _, last in last }
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            isEventStream = ct.contains("text/event-stream")
        }
        completionHandler(.allow)
    }

    /// Override in subclass for provider-specific SSE parsing
    @objc func processData(_ data: Data) {
        // default: no-op
    }

    /// 喂解码器；一行超上限就断流报错
    internal func feedSSE(_ data: Data) -> [SSELineDecoder.Field] {
        do {
            return try sseDecoder.feed(data)
        } catch {
            let msg = "回包一行太长（超过 32 MB），已停止接收"
            // 走 cancel 的代际失效：已排队的正文 / 完成回调一律作废，onError 是本轮最后一个回调
            cancel()
            self.error = msg
            onError?(msg)
            return []
        }
    }

    /// HTTP 非 200 完成时的子类 hook（如 Anthropic 的 cache_control 黑名单自愈）
    @objc func onHTTPError() {
        // default: no-op
    }

}

// MARK: - 有序序列 → 线上消息（④b）

/// provider adapter 共用的纯函数：定 system 前缀；非前缀 system 原位保留或降级；降级时按序合并相邻同 role。
enum PromptWire {
    /// 降级边界：不支持序列内 system 的接口把它转成 user 文本块，包这层标明是系统注入（语义降级，不等价于 system 权限）
    static let systemNoteOpen = "<system_note>"
    static let systemNoteClose = "</system_note>"

    enum SystemStrategy { case interleaved, degradeToUserNote }

    /// 一条线上消息：按序的文本块，每块带自己的附件（合并后块与附件保持原顺序）
    struct Message {
        let role: String
        var chunks: [(text: String, attachments: [PendingChatAttachment])]
        /// #089 P0-b：assistant 历史的工具回合（chunks = 最后的正文）
        var toolRounds: [ToolReplayRound] = []
    }

    struct Plan {
        let systemPrompt: String?
        let messages: [Message]
        /// 非前缀 system 段数（原位发 / 被降级）
        let inPlaceSystemCount: Int
        let degradedSystemCount: Int
    }

    static func plan(_ ordered: [PromptMessage], strategy: SystemStrategy) -> Plan {
        let firstNonSystem = ordered.firstIndex { $0.role != "system" } ?? ordered.count
        var prefix: [String] = []
        var rest: [PromptMessage] = []
        for (index, message) in ordered.enumerated() {
            if message.role == "system" && (index < firstNonSystem || message.pinnedToSystemPrefix) {
                prefix.append(message.content)
            } else {
                rest.append(message)
            }
        }
        let inPlace = rest.filter { $0.role == "system" }.count
        let degrade = strategy == .degradeToUserNote && inPlace > 0
        var messages = rest.map { message -> Message in
            if degrade && message.role == "system" {
                return Message(role: "user", chunks: [(text: systemNoteOpen + "\n" + message.content + "\n" + systemNoteClose, attachments: [])])
            }
            return Message(role: message.role, chunks: [(text: message.content, attachments: message.attachments)],
                           toolRounds: message.toolRounds)
        }
        if degrade {
            var merged: [Message] = []
            for message in messages {
                // 带工具回合的不并（回合必须排在正文前，并进别的消息顺序就乱了）
                if let last = merged.last, last.role == message.role, last.toolRounds.isEmpty, message.toolRounds.isEmpty {
                    merged[merged.count - 1].chunks += message.chunks
                } else {
                    merged.append(message)
                }
            }
            messages = merged
        }
        return Plan(systemPrompt: prefix.isEmpty ? nil : prefix.joined(separator: "\n\n"), messages: messages,
                    inPlaceSystemCount: inPlace, degradedSystemCount: degrade ? inPlace : 0)
    }
}

// MARK: - OpenAI Compatible Provider

final class OpenAICompatibleProvider: BaseChatProvider {
    /// 流式累积的 tool_calls（按 index）：(id, name, arguments 分片拼接)
    private var toolCallAccum: [Int: (id: String, name: String, args: String)] = [:]
    /// 正文开头的 <think> 拆成思考（ResolvedCompat.splitsLeadingThinkTag，Q3）
    internal var splitsLeadingThinkTag = false
    private var thinkSplitter = LeadingThinkTagSplitter()

    override var hasEmittedOutput: Bool { super.hasEmittedOutput || !reasoning.isEmpty || !toolCallAccum.isEmpty }

    /// 前缀分歧探针：按 session 存上一轮请求的展平文本，下一轮逐字对比找出谁动了缓存前缀
    private static var lastCanonBySession: [String: String] = [:]

    private static func canonicalMessages(_ body: [String: Any]) -> String {
        guard let messages = body["messages"] as? [[String: Any]] else { return "" }
        return messages.map { m -> String in
            let role = m["role"] as? String ?? "?"
            if let s = m["content"] as? String { return role + "|" + s }
            if let parts = m["content"] as? [[String: Any]] {
                return role + "|" + parts.compactMap { $0["text"] as? String }.joined()
            }
            return role + "|<blocks>"
        }.joined(separator: "\n§\n")
    }

    private static func logPrefixDiff(sessionId: String, body: [String: Any]) {
        let canon = canonicalMessages(body)
        defer { lastCanonBySession[sessionId] = canon }
        guard let prev = lastCanonBySession[sessionId] else { return }
        let prevChars = Array(prev), newChars = Array(canon)
        var common = 0
        while common < prevChars.count && common < newChars.count && prevChars[common] == newChars[common] { common += 1 }
        let pct = prev.isEmpty ? 0 : Int(Double(common) / Double(prevChars.count) * 100)
        func ctx(_ chars: [Character]) -> String {
            String(chars[max(0, common - 12)..<min(chars.count, common + 28)])
                .replacingOccurrences(of: "\n", with: "⏎")
        }
        CacheDiagLog.shared.log("前缀对比: 共同 \(common) 字（上轮的 \(pct)%）｜分歧点 旧『\(ctx(prevChars))』新『\(ctx(newChars))』")
    }

    override func sendStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        samplingParams: SamplingParams? = nil,
        imageMap: [String: [PendingChatAttachment]] = [:],
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        ordered: [PromptMessage]? = nil,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void,
        onToolCalls: (([ToolCallBlock]) -> Void)? = nil
    ) {
        resetState(onToken: onToken, onComplete: onComplete, onError: onError)
        self.onToolCalls = onToolCalls
        toolCallAccum = [:]
        thinkSplitter = LeadingThinkTagSplitter()

        usageBaseURL = baseURL
        let compat = ResolvedCompat.resolve(providerType: .openaiCompatible, baseURL: baseURL, modelId: model, sampling: samplingParams)
        splitsLeadingThinkTag = compat.splitsLeadingThinkTag
        let orCC = compat.orCacheControl
        usageCacheWriteIs1h = orCC && Self.cacheMark(samplingParams)["ttl"] != nil
        let body: [String: Any]
        if let ordered {
            body = Self.buildRequestBody(
                ordered: ordered, model: model, samplingParams: samplingParams,
                tools: tools, toolTurns: toolTurns, compat: compat
            )
        } else {
            body = Self.buildRequestBody(
                messages: messages, model: model, systemPrompt: systemPrompt,
                samplingParams: samplingParams, imageMap: imageMap,
                tools: tools, toolTurns: toolTurns, compat: compat
            )
        }
        sentShape = ParamErrorClassifier.SentShape(body: body)
        #if DEBUG
        RequestBodyTap.emit(body)
        print("[PROBE] OAI 请求: model=\(model) cacheFriendly=\(samplingParams?.cacheFriendly == true) orBlocks=\(orCC) providerOrder=\((body["provider"] as? [String: Any])?["order"] ?? "无") sessionId=\(extraHeaders["x-session-id"] ?? "无")")
        #endif
        CacheDiagLog.shared.log("→ \(model) 挂标=\(orCC ? "✓" : "✗") session=\(extraHeaders["x-session-id"]?.suffix(8) ?? "无")")
        if let sid = extraHeaders["x-session-id"] {
            Self.logPrefixDiff(sessionId: sid, body: body)
        }

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            onError("无效的 API 地址: \(baseURL)")
            isStreaming = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if samplingParams?.streaming == false { request.timeoutInterval = 600 }
        request.httpBody = Self.encodeBody(body)

        startRequest(request)
    }

    /// ④b：有序消息序列 → 请求 body。开头连续 system（+ 锚定前缀的段）并成首条 system；
    /// 其余 system 支持交错时原位 role:system，否则降级成 <system_note> user 块并按序合并相邻同 role。
    /// 没有非前缀 system 时与旧 buildRequestBody 逐字节一致（ProviderOrderingTests 夹具）。
    static func buildRequestBody(
        ordered: [PromptMessage],
        model: String,
        samplingParams: SamplingParams?,
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        compat: ResolvedCompat = .permissive
    ) -> [String: Any] {
        // #089 P0-b：没下发客户端工具时历史退回纯文字 + 〔系统记录〕
        let toolNames = ToolReplay.clientToolNames(tools)
        let plan = PromptWire.plan(ToolReplay.wireOrdered(ordered, toolNames: toolNames),
                                   strategy: compat.interleavedSystem ? .interleaved : .degradeToUserNote)
        return buildRequestBody(
            messages: [], model: model, systemPrompt: plan.systemPrompt,
            samplingParams: samplingParams, tools: tools, toolTurns: toolTurns,
            wireMessages: openAIWire(plan.messages, toolNames: toolNames),
            compat: compat
        )
    }

    /// #089 P0-b：带工具回合的 assistant 展开成 assistant{tool_calls} + role:tool 结果 + … + assistant 最后的正文；
    /// ask_user 的 Q/A 已在 tool 结果里，紧随的用户消息里同一段不再发
    static func openAIWire(_ messages: [PromptWire.Message], toolNames: Set<String>) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pendingAsk: String?
        for message in messages {
            guard message.role == "assistant", !message.toolRounds.isEmpty else {
                var message = message
                // 中间夹着的注入段（[动态上下文] 等）不消费：等到真的那条 Q/A 用户消息去掉才清；碰到 assistant 才放弃
                if message.role == "user", let ask = pendingAsk {
                    let stripped = ToolReplay.strippingAskAnswer(message.chunks, ask: ask)
                    message.chunks = stripped.chunks
                    if stripped.matched { pendingAsk = nil }
                } else {
                    pendingAsk = nil
                }
                if !message.chunks.isEmpty { out.append(openAIWireMessage(message)) }
                continue
            }
            pendingAsk = nil
            for round in message.toolRounds {
                out.append([
                    "role": "assistant", "content": round.text,
                    "tool_calls": round.calls.map { ToolReplay.wireCall($0, toolNames: toolNames) }.map { [
                        "id": $0.id, "type": "function",
                        "function": ["name": $0.name, "arguments": $0.argumentsJSON]
                    ] }
                ])
                for result in round.results {
                    out.append(["role": "tool", "tool_call_id": result.toolUseId, "content": result.text])
                }
            }
            if message.chunks.allSatisfy({ $0.text.isEmpty }) {
                pendingAsk = message.toolRounds.last?.askAnswer
            } else {
                out.append(openAIWireMessage(PromptWire.Message(role: "assistant", chunks: message.chunks)))
            }
        }
        return out
    }

    private static func openAIWireMessage(_ message: PromptWire.Message) -> [String: Any] {
        let hasAttachments = message.role == "user" && message.chunks.contains { !$0.attachments.isEmpty }
        guard hasAttachments else {
            return ["role": message.role, "content": message.chunks.map(\.text).joined(separator: "\n\n")]
        }
        return ["role": message.role, "content": message.chunks.flatMap { openAIContentParts(text: $0.text, images: $0.attachments) }]
    }

    /// 构造发给 OpenAI 兼容 API 的请求 body。实际发送 + 上下文检查器预览共用，杜绝两条路径分叉。
    static func buildRequestBody(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        samplingParams: SamplingParams?,
        imageMap: [String: [PendingChatAttachment]] = [:],
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        wireMessages: [[String: Any]]? = nil,   // ④b：有序序列排好的、system 前缀之后的消息（给了就不用 messages / imageMap）
        compat: ResolvedCompat = .permissive   // 这个端点 × 模型怎么发：收哪些参数（#094）+ OR 挂标 / 路由 / 思考档格式
    ) -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            apiMessages.append(["role": "system", "content": sys])
        }
        if let wireMessages {
            apiMessages += wireMessages
        } else {
            for msg in messages {
                if msg.role == "user", let images = imageMap[msg.content], !images.isEmpty {
                    apiMessages.append(["role": msg.role, "content": openAIContentParts(text: msg.content, images: images)])
                } else {
                    apiMessages.append(["role": msg.role, "content": msg.content])
                }
            }
        }
        // 追加工具回合（assistant.tool_calls + role:tool 结果），按序接在历史后
        for turn in toolTurns {
            var assistant: [String: Any] = [
                "role": "assistant", "content": turn.text.flatMap { $0.isEmpty ? nil : $0 } ?? (compat.requiresAssistantContentForToolCalls ? "." : ""),
                "tool_calls": turn.calls.map { [
                    "id": $0.id, "type": "function",
                    "function": ["name": $0.name, "arguments": $0.argumentsJSON]
                ] }
            ]
            if compat.requiresReasoningContentForToolCalls, let reasoning = turn.reasoning {
                replayReasoning(reasoning, fallbackField: compat.reasoningContentField, into: &assistant)
            }
            apiMessages.append(assistant)
            for result in turn.results {
                apiMessages.append(["role": "tool", "tool_call_id": result.toolUseId, "content": result.text])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true,
            // 让流式响应最后一个 chunk 带上 usage 字段（保险闸回填用）
            "stream_options": ["include_usage": true],
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            WebSearchProbe.log("[openai-body] tools=\(WebSearchProbe.summarizeTools(tools))")
        } else {
            WebSearchProbe.log("[openai-body] tools=<nil-or-empty>")
        }
        let params = compat.params
        if let p = samplingParams {
            if params.sendsSampling {
                if p.temperature != 1.0 { body["temperature"] = p.temperature }
                // Anthropic 血统（OpenRouter / 中转上的 claude-sonnet-4.5 之类）temperature 和 top_p 只收一个
                if p.topP != 1.0, params.sendsTopP(temperatureSent: p.temperature != 1.0) { body["top_p"] = p.topP }
                if p.frequencyPenalty != 0 { body["frequency_penalty"] = p.frequencyPenalty }
                if p.presencePenalty != 0 { body["presence_penalty"] = p.presencePenalty }
            }
            body[params.maxTokensKey] = p.maxTokens
            if p.seed >= 0, !params.dropped.contains(ParamCompat.Group.seed) { body["seed"] = p.seed }
            if !params.dropped.contains(ParamCompat.Group.reasoning) {
                ReasoningEffort.applyChatCompletions(route: compat.reasoningRoute, effort: p.reasoningEffort, to: &body)   // OpenRouter 用 reasoning.effort
            }
            body["stream"] = p.streaming
        }
        if params.dropped.contains(ParamCompat.Group.streamOptions) { body["stream_options"] = nil }
        if compat.orCacheControl {
            // OR 上 Anthropic 系：显式 per-block 挂标（BP=system 块 + 末 assistant 块，动态段留断点外）。
            // 不用顶层自动模式——它把断点挂到最后一个可缓存块，而[动态上下文]伪段在末尾每轮变，
            // 断点前缀永远对不上 → 每轮写 1.25× 读 0（OR log 实测坐实，比不开还贵 25%）
            // ttl 默认 1h：5min 在"隔几分钟回一条"的真实聊天节奏下存不住（实测 8 分钟空档全量重写 1.25×）。
            // 1h 写 2× 但 rolling 增量写很小，隔断回来稳赚（教程同款取舍）；预设里能改回 5 分钟（粟粟 10-15）
            let mark = Self.cacheMark(samplingParams)
            if let idx = apiMessages.firstIndex(where: { ($0["role"] as? String) == "system" }),
               let sys = apiMessages[idx]["content"] as? String {
                apiMessages[idx]["content"] = [["type": "text", "text": sys, "cache_control": mark] as [String: Any]]
            }
            if let idx = apiMessages.lastIndex(where: { ($0["role"] as? String) == "assistant" }),
               let text = apiMessages[idx]["content"] as? String {
                apiMessages[idx]["content"] = [["type": "text", "text": text, "cache_control": mark] as [String: Any]]
            }
            body["messages"] = apiMessages
        }
        if let order = compat.orProviderOrder {
            // OR 缓存路由：默认负载均衡常落到不缓存/贵 3 倍的转售商（实测 GMICloud 读写全 0），
            // 显式指定一方提供商优先（DeepSeek 官方缓存读 ≈1% 原价），不可用再 fallback
            body["provider"] = ["order": order, "allow_fallbacks": true]
        }
        return body
    }

    /// C1 回传（plan-model-compat-p0 §5.2）：从哪个字段来写回哪个字段；reasoning_details 原样整串（不能改顺序）；
    /// <think> 拆出来的写 fallbackField。这一轮没抓到思考就不写（不编占位，Q5）
    static func replayReasoning(_ reasoning: ReasoningCapture, fallbackField: String, into message: inout [String: Any]) {
        guard let field = reasoning.field else { return }
        if field == ReasoningCapture.detailsField {
            if !reasoning.details.isEmpty { message[field] = reasoning.details }
        } else if !reasoning.text.isEmpty {
            message[field == ReasoningCapture.thinkTag ? fallbackField : field] = reasoning.text
        }
    }

    private static func openAIContentParts(text: String, images: [PendingChatAttachment]) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        for image in images where image.isImage {
            guard let data = image.imageData, let mime = image.mimeType else { continue }
            let url = "data:\(mime);base64,\(data.base64EncodedString())"
            parts.append(["type": "image_url", "image_url": ["url": url]])
        }
        return parts
    }

    override func sendNonStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        images: [PendingChatAttachment] = []
    ) async throws -> (String, TokenUsage?) {
        var apiMessages: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            apiMessages.append(["role": "system", "content": sys])
        }
        for (i, msg) in messages.enumerated() {
            // 图片挂在最后一条 user 上（图片转述用）
            if i == messages.count - 1, msg.role == "user", !images.isEmpty {
                apiMessages.append(["role": msg.role, "content": Self.openAIContentParts(text: msg.content, images: images)])
            } else {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": false,
        ]

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw NSError(domain: "ChatService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = Self.encodeBody(body)

        let budgetDecision = await BudgetPreflight.decision(request)
        requestEstimatedCost = budgetDecision.estimatedCost
        guard budgetDecision.allowed else {
            throw NSError(domain: "BudgetGate", code: -1, userInfo: [NSLocalizedDescriptionKey: FixJump.budgetPreflightMessage])
        }
        requestWasSent = true
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            throw NSError(domain: "ChatService", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: ParamErrorClassifier.redacted(
                              Self.extractError(from: data, statusCode: statusCode), secrets: ParamErrorClassifier.secrets(apiKey: apiKey, headers: extraHeaders))])
        }

        // 和聊天的非流式同一个解析：content 是数组 / null 也认（以前只认字符串，记忆写手直接报「无法解析响应」）
        usageBaseURL = baseURL
        usageCacheWriteIs1h = APIUsageParser.isOpenRouter(baseURL) && model.lowercased().contains("claude")
        let parsed = try parseNonStreamBody(data)
        return (parsed.text, parsed.usage)
    }

    /// 非流式整包：choices[0].message.content（string 或 [{type:text}]）+ tool_calls + usage
    override func parseNonStreamBody(_ data: Data) throws -> NonStreamResult {
        guard let obj = Self.nonStreamObject(data),
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw Self.unparsableBody(data)
        }
        var text = ""
        if let s = message["content"] as? String {
            text = s
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
        }
        var calls: [ToolCallBlock] = []
        if let tcs = message["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                guard let id = tc["id"] as? String, let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String, !name.isEmpty else { continue }
                calls.append(ToolCallBlock(id: id, name: name, argumentsJSON: fn["arguments"] as? String ?? "{}"))
            }
        }
        let hit = choices.first?["finish_reason"] as? String == "length"
        let usage = APIUsageParser.openAI(obj, baseURL: usageBaseURL, cacheWriteIs1h: usageCacheWriteIs1h)
        var reasoning = ReasoningCapture()
        reasoning.absorbMessage(message)
        if splitsLeadingThinkTag {
            var splitter = LeadingThinkTagSplitter()
            text = splitter.feed(text, into: &reasoning, enabled: !reasoning.hasNative) + splitter.flush(into: &reasoning)
        }

        return NonStreamResult(text: text, toolCalls: calls.markingLastTruncated(hit), usage: usage, hitOutputLimit: hit,
                               reasoning: reasoning)
    }

    override func processData(_ data: Data) {
        if httpStatusCode != 0 && httpStatusCode != 200 {
            errorBytes.append(data)
            return
        }
        handle(feedSSE(data))
    }

    override func handle(_ fields: [SSELineDecoder.Field]) {
        for field in fields {
            // 流内报错已终止：之后的 [DONE] / 正文一概不吐、不再派完成（同批、跨批都一样）
            if terminatedByError { return }
            if case .data(let payload) = field {
                if payload == "[DONE]" {
                    receivedDone = true
                    _ = flushHeldContent()
                    enqueueCallback { [self] in
                        isStreaming = false
                        if !toolCallAccum.isEmpty, let cb = onToolCalls {
                            let calls = toolCallAccum.sorted { $0.key < $1.key }.map {
                                ToolCallBlock(id: $0.value.id, name: $0.value.name, argumentsJSON: $0.value.args)
                            }
                            cb(calls.markingLastTruncated(hitOutputLimit))
                        } else {
                            onComplete?(streamingContent, finalUsage)
                        }
                    }
                    return
                }
                parseOpenAIChunk(payload)
            }
        }
    }

    override func flushHeldContent() -> Bool {
        let held = thinkSplitter.flush(into: &reasoning)
        guard !held.isEmpty else { return false }
        emitContent(held)
        return true
    }

    private func emitContent(_ content: String) {
        enqueueCallback { [self] in
            streamingContent += content
            onToken?(content)
        }
    }

    private func parseOpenAIChunk(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if APIUsageParser.isOpenRouter(usageBaseURL), let id = obj["id"] as? String {
            accumulatedResponseId = id
        }
        if let usage = APIUsageParser.openAI(obj, baseURL: usageBaseURL, cacheWriteIs1h: usageCacheWriteIs1h) {
            if let cost = usage.reportedCostUSD { accumulatedReportedCostUSD = cost }
            if let reasoning = usage.reasoningTokens { accumulatedReasoningTokens = reasoning }
            if let read = usage.cacheReadTokens { accumulatedCacheReadTokens = read }
            if let write = usage.cacheWriteTokens { accumulatedCacheWriteTokens = write }
            if let write = usage.cacheWrite1hTokens { accumulatedCacheWrite1hTokens = write }
        }

        // usage 字段可能出现在任何 chunk（通常是最后一个，include_usage=true 时）
        if let u = obj["usage"] as? [String: Any],
           let pt = u["prompt_tokens"] as? Int,
           let ct = u["completion_tokens"] as? Int {
            #if DEBUG
            if let d = try? JSONSerialization.data(withJSONObject: u), let s = String(data: d, encoding: .utf8) {
                print("[PROBE] OAI usage 原始: \(s) | 上游 provider=\(obj["provider"] as? String ?? "未知")")
            }
            #endif
            let details = u["prompt_tokens_details"] as? [String: Any]
            CacheDiagLog.shared.log("← prompt \(pt) · 读 \(details?["cached_tokens"] as? Int ?? 0) · 写 \(details?["cache_write_tokens"] as? Int ?? 0) · \(obj["provider"] as? String ?? "?")")
            accumulatedInputTokens = pt
            accumulatedOutputTokens = APIUsageParser.openAI(obj, baseURL: usageBaseURL)?.outputTokens ?? ct
            if let cached = u["prompt_cache_hit_tokens"] as? Int ?? (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int {
                accumulatedCacheReadTokens = cached
            }
            gotUsage = true
        }

        let choices = obj["choices"] as? [[String: Any]]
        if choices?.first?["finish_reason"] as? String == "length" { hitOutputLimit = true }
        guard let delta = choices?.first?["delta"] as? [String: Any] else {
            if let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String {
                terminatedByError = true
                streamErrorBody = json
                enqueueCallback { [self] in
                    isStreaming = false
                    error = message
                    onError?(message)
                }
            }
            return
        }

        // 思考字段在正文之前读：同一片里先有思考（Kimi 文档：思考总在正文前）；流式中不实时显示（Q9），回复完由 router 挂段
        reasoning.absorbDelta(delta)
        if let content = delta["content"] as? String {
            if splitsLeadingThinkTag {
                let body = thinkSplitter.feed(content, into: &reasoning, enabled: !reasoning.hasNative)
                if !body.isEmpty { emitContent(body) }
            } else {
                emitContent(content)
            }
        }

        // 工具调用增量：按 index 累积 id/name/arguments（arguments 分片拼接）
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let idx = tc["index"] as? Int ?? 0
                var entry = toolCallAccum[idx] ?? (id: "", name: "", args: "")
                // 非空才覆盖：部分 provider（如 DeepSeek）在后续分片里把 id/name 发成 ""，
                // 不 guard 会把首片抓到的真名清空 → 工具名变空 → 调用失败。
                if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty { entry.name = name }
                    if let args = fn["arguments"] as? String { entry.args += args }
                }
                toolCallAccum[idx] = entry
            }
        }
    }
}

// MARK: - Anthropic Provider

final class AnthropicProvider: BaseChatProvider {
    private var currentEventType = ""
    /// 流式累积的 tool_use（按 index）：(id, name, input_json 分片拼接)
    private var toolUseAccum: [Int: (id: String, name: String, json: String)] = [:]
    private var stopReason = ""
    /// 流式累积的 server-side web_search_tool_result 解析出来的 sources。
    /// 每条 web_search_tool_result block 出现就 append；finalize 时 ConversationVM 读出来写 MessageNode.webSourcesData。
    @MainActor @Published var streamingWebSources: [WebSearchSource] = []
    /// 本次请求挂了 cache_control 的 host（4xx 自愈用）
    private var cacheMarkedHost: String? = nil
    /// 本次挂的是 1 小时缓存标（4xx 提到 ttl 时只退回 5 分钟）
    private var cacheLongTTLSent = false
    /// 这一次被拒正是因为 1 小时缓存（已记成这个地址用 5 分钟；路由层据此立刻按 5 分钟重发这一条）
    private(set) var longTTLRejected = false
    /// thinking 回传（plan-thinking §3.1）：这一次回复的全部内容块，按 index 原样记（思考 / redacted / 正文 / tool_use / server 块）
    private var blockAccum: [Int: ReplyBlock] = [:]
    /// tool_use / server_tool_use 的 input 分片（按 index 拼，content_block_stop 时解析回块里）
    private var blockInputJSON: [Int: String] = [:]
    /// `stop_reason: refusal` 时的 `stop_details.category`（如 reasoning_extraction）
    private(set) var refusalCategory: String?

    /// 这一次回复的块，按回复顺序（停止 / 出错时也读得到已收的部分）
    var replyBlocks: [ReplyBlock] {
        blockAccum.sorted { $0.key < $1.key }.map(\.value)
    }

    /// 收到了思考 / 工具 / 联网块，或非空正文块
    override var hasEmittedOutput: Bool {
        super.hasEmittedOutput || blockAccum.values.contains { $0.type != "text" || !($0.raw["text"] as? String ?? "").isEmpty }
    }

    // MARK: cache_control 黑名单（有些中转对 cache_control 报 4xx，记下来之后降级无标透传）

    private static let cacheBlacklistKey = "anthropicCacheHostBlacklist"

    /// 两边都过 BaseURLNormalizer：#092 之前拉黑的是原样地址，卡读出来已规整，原样比会对不上
    private static func cacheBlacklistForm(_ baseURL: String) -> String {
        BaseURLNormalizer.normalize(baseURL, type: .anthropic)
    }

    static func cacheBlacklistContains(_ baseURL: String) -> Bool {
        let key = cacheBlacklistForm(baseURL)
        return (UserDefaults.standard.stringArray(forKey: cacheBlacklistKey) ?? [])
            .contains { cacheBlacklistForm($0) == key }
    }

    static func addToCacheBlacklist(_ baseURL: String) {
        guard !cacheBlacklistContains(baseURL) else { return }
        var list = UserDefaults.standard.stringArray(forKey: cacheBlacklistKey) ?? []
        list.append(cacheBlacklistForm(baseURL))
        UserDefaults.standard.set(list, forKey: cacheBlacklistKey)
    }

    // 1 小时缓存不认的中转（报 4xx 且提到 ttl）：只退回 5 分钟，缓存照开（粟粟 10-15）
    private static let longTTLBlacklistKey = "anthropicCacheLongTTLHostBlacklist"

    static func longTTLBlacklistContains(_ baseURL: String) -> Bool {
        let key = cacheBlacklistForm(baseURL)
        return (UserDefaults.standard.stringArray(forKey: longTTLBlacklistKey) ?? []).contains { cacheBlacklistForm($0) == key }
    }

    static func addToLongTTLBlacklist(_ baseURL: String) {
        guard !longTTLBlacklistContains(baseURL) else { return }
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: longTTLBlacklistKey) ?? []) + [cacheBlacklistForm(baseURL)],
                                  forKey: longTTLBlacklistKey)
    }

    /// 实发 / 预览同口径：这个地址不认 1 小时就按 5 分钟组 body
    static func samplingForHost(_ samplingParams: SamplingParams?, baseURL: String) -> SamplingParams? {
        guard var p = samplingParams, longTTLBlacklistContains(baseURL) else { return samplingParams }
        p.cacheLongTTL = false
        return p
    }

    /// sticky 路由 id：固定不变，防中转负载均衡把缓存写/读打到不同后端（只写不读 = 命中永远 0）
    static var cacheUserId: String {
        let key = "anthropicCacheUserId"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = "memorypalace-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    enum CacheRejection: Equatable { case longTTL, cacheControl }

    /// 挂了标的请求报 4xx：400 / 422 且单独出现 ttl 这个词、发的是 1 小时 → 只退回 5 分钟；否则提到 cache → 这个地址不吃 cache_control。
    /// astra：「throttled」「ThrottlingException」里也有 ttl 三个字母，限流不能记成不认 1 小时
    static func cacheRejection(status: Int, body: String, longTTLSent: Bool) -> CacheRejection? {
        guard (400...499).contains(status) else { return nil }
        let message = body.lowercased()
        if longTTLSent, ParamErrorClassifier.isParamRejection(status: status),
           message.range(of: #"(?<![a-z])ttl(?![a-z])"#, options: .regularExpression) != nil { return .longTTL }
        return message.contains("cache") ? .cacheControl : nil
    }

    override func onHTTPError() {
        guard let host = cacheMarkedHost else { return }
        switch Self.cacheRejection(status: httpStatusCode, body: errorBody, longTTLSent: cacheLongTTLSent) {
        case .longTTL:
            longTTLRejected = true
            Self.addToLongTTLBlacklist(host)
            CacheDiagLog.shared.log("⚠️ 这个地址不认 1 小时缓存，之后改用 5 分钟：\(host)")
        case .cacheControl:
            Self.addToCacheBlacklist(host)   // 拉黑降级（下次请求无标）
        case nil:
            break
        }
    }

    override func sendStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        samplingParams: SamplingParams? = nil,
        imageMap: [String: [PendingChatAttachment]] = [:],
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        ordered: [PromptMessage]? = nil,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void,
        onToolCalls: (([ToolCallBlock]) -> Void)? = nil
    ) {
        resetState(onToken: onToken, onComplete: onComplete, onError: onError)
        self.onToolCalls = onToolCalls
        currentEventType = ""
        toolUseAccum = [:]
        stopReason = ""
        blockAccum = [:]
        blockInputJSON = [:]
        refusalCategory = nil
        enqueueCallback { [self] in MainActor.assumeIsolated { streamingWebSources = [] } }

        usageBaseURL = baseURL
        let allowCache = !Self.cacheBlacklistContains(baseURL)
        let samplingParams = Self.samplingForHost(samplingParams, baseURL: baseURL)
        let compat = ResolvedCompat.resolve(providerType: .anthropic, baseURL: baseURL, modelId: model, sampling: samplingParams)
        let body: [String: Any]
        if let ordered {
            body = Self.buildRequestBody(
                ordered: ordered, model: model, samplingParams: samplingParams,
                tools: tools, toolTurns: toolTurns, allowCacheControl: allowCache, compat: compat
            )
        } else {
            body = Self.buildRequestBody(
                messages: messages, model: model, systemPrompt: systemPrompt,
                samplingParams: samplingParams, imageMap: imageMap,
                tools: tools, toolTurns: toolTurns, allowCacheControl: allowCache, compat: compat
            )
        }
        sentShape = ParamErrorClassifier.SentShape(body: body)
        echoedThinking = BudgetPreflight.EchoedThinking(toolTurns)
        #if DEBUG
        RequestBodyTap.emit(body)
        #endif
        cacheMarkedHost = (samplingParams?.cacheFriendly == true && allowCache) ? baseURL : nil
        cacheLongTTLSent = cacheMarkedHost != nil && samplingParams?.cacheLongTTL ?? true
        longTTLRejected = false

        guard let url = URL(string: "\(baseURL)/messages") else {
            onError("无效的 API 地址: \(baseURL)")
            isStreaming = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if samplingParams?.streaming == false { request.timeoutInterval = 600 }
        request.httpBody = Self.encodeBody(body)

        startRequest(request)
    }

    /// ④b：有序消息序列 → 请求 body。Anthropic 只有顶层 system：开头连续 system（+ 锚定前缀的段）按序进顶层；
    /// 其余 system 原位转成 <system_note> user 文本块（不上移、不丢），再按序合并相邻同 role 的内容块（附件块顺序不变）。
    /// 序列以 assistant 结尾（depth=0 assistant 注入）时 Anthropic 当 prefill 续写——维持现状，不删。
    /// 没有非前缀 system 时与旧 buildRequestBody 逐字节一致（ProviderOrderingTests 夹具）。
    static func buildRequestBody(
        ordered: [PromptMessage],
        model: String,
        samplingParams: SamplingParams?,
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        allowCacheControl: Bool = true,
        compat: ResolvedCompat? = nil
    ) -> [String: Any] {
        // #089 P0-b：没下发客户端工具时 API 不收工具块 → 历史退回纯文字 + 〔系统记录〕
        let toolNames = ToolReplay.clientToolNames(tools)
        let plan = PromptWire.plan(ToolReplay.wireOrdered(ordered, toolNames: toolNames), strategy: .degradeToUserNote)
        return buildRequestBody(
            messages: [], model: model, systemPrompt: plan.systemPrompt,
            samplingParams: samplingParams, tools: tools, toolTurns: toolTurns,
            allowCacheControl: allowCacheControl,
            wireMessages: anthropicWire(plan.messages, toolNames: toolNames),
            compat: compat
        )
    }

    /// #089 P0-b：带工具回合的 assistant 展开成 assistant[正文?, tool_use…] → user[tool_result…] → … → assistant[最后的正文]。
    /// 最后的正文为空时，紧随的用户消息并进 tool_result 那条（tool_result 排最前）；ask_user 的 Q/A 已在 tool_result 里，用户消息里同一段不再发
    static func anthropicWire(_ messages: [PromptWire.Message], toolNames: Set<String>) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pendingAsk: String?
        for message in messages {
            guard message.role == "assistant", !message.toolRounds.isEmpty else {
                var message = message
                // 中间夹着的注入段（[动态上下文] 等）不消费：等到真的那条 Q/A 用户消息去掉才清；碰到 assistant 才放弃
                if message.role == "user", let ask = pendingAsk {
                    let stripped = ToolReplay.strippingAskAnswer(message.chunks, ask: ask)
                    message.chunks = stripped.chunks
                    if stripped.matched { pendingAsk = nil }
                } else {
                    pendingAsk = nil
                }
                guard !message.chunks.isEmpty else { continue }
                let wire = anthropicWireMessage(message)
                if message.role == "user", let last = out.last, last["role"] as? String == "user",
                   var blocks = last["content"] as? [[String: Any]], blocks.first?["type"] as? String == "tool_result" {
                    if let text = wire["content"] as? String {
                        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                    } else if let parts = wire["content"] as? [[String: Any]] {
                        blocks += parts
                    }
                    out[out.count - 1]["content"] = blocks
                } else {
                    out.append(wire)
                }
                continue
            }
            pendingAsk = nil
            for round in message.toolRounds {
                var blocks: [[String: Any]] = []
                if !round.text.isEmpty { blocks.append(["type": "text", "text": round.text]) }
                for call in round.calls.map({ ToolReplay.wireCall($0, toolNames: toolNames) }) {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                out.append(["role": "assistant", "content": blocks])
                out.append(["role": "user", "content": round.results.map { result -> [String: Any] in
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": result.toolUseId, "content": result.text]
                    if result.isError { block["is_error"] = true }
                    return block
                }])
            }
            if message.chunks.allSatisfy({ $0.text.isEmpty }) {
                pendingAsk = message.toolRounds.last?.askAnswer
            } else {
                out.append(anthropicWireMessage(PromptWire.Message(role: "assistant", chunks: message.chunks)))
            }
        }
        return out
    }

    private static func anthropicWireMessage(_ message: PromptWire.Message) -> [String: Any] {
        if message.chunks.count == 1, let chunk = message.chunks.first {
            if message.role == "user", !chunk.attachments.isEmpty {
                return ["role": message.role, "content": anthropicContentParts(text: chunk.text, images: chunk.attachments)]
            }
            return ["role": message.role, "content": chunk.text]
        }
        return ["role": message.role, "content": message.chunks.flatMap {
            anthropicContentParts(text: $0.text, images: message.role == "user" ? $0.attachments : [])
        }]
    }

    /// 构造发给 Anthropic Messages API 的请求 body。实际发送 + 上下文检查器预览共用。
    static func buildRequestBody(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        samplingParams: SamplingParams?,
        imageMap: [String: [PendingChatAttachment]] = [:],
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        allowCacheControl: Bool = true,
        wireMessages: [[String: Any]]? = nil,   // ④b：有序序列排好的消息（给了就不用 messages / imageMap）
        compat: ResolvedCompat? = nil   // #094：nil = 只按血统认（测试 / 老调用点）
    ) -> [String: Any] {
        let params = compat?.params
        var apiMessages: [[String: Any]] = []
        if let wireMessages {
            apiMessages = wireMessages
        } else {
            for msg in messages {
                if msg.role == "user", let images = imageMap[msg.content], !images.isEmpty {
                    apiMessages.append(["role": msg.role, "content": anthropicContentParts(text: msg.content, images: images)])
                } else {
                    apiMessages.append(["role": msg.role, "content": msg.content])
                }
            }
        }
        // 追加工具回合（assistant.tool_use blocks + user.tool_result blocks）
        for turn in toolTurns {
            apiMessages.append([
                "role": "assistant",
                "content": toolTurnAssistantContent(turn)
            ])
            apiMessages.append([
                "role": "user",
                "content": turn.results.map { result -> [String: Any] in
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": result.toolUseId, "content": result.text]
                    if result.isError { block["is_error"] = true }
                    return block
                }
            ])
        }

        // 思考强度（research-reasoning-effort §2.3）：4.7+ / 5 系用 adaptive + output_config.effort，老模型用 budget_tokens
        // thinking 回传 §3.5：「默认」档的新模型显式 adaptive + 默认档余量；display 跟「思考过程」设置
        let limits = ReasoningEffort.anthropicThinking(
            route: (params?.anthropicAdaptive ?? ReasoningEffort.needsAdaptive(model)) ? .anthropicAdaptive : .anthropicBudget,
            effort: samplingParams?.reasoningEffort ?? "auto",
            visible: samplingParams?.maxTokens ?? OutputTokenCap.fallback,
            limit: OutputTokenCap.modelLimit(model),
            modelId: model, summarize: ReasoningEffort.wantsThinkingSummary,
            thinkingAllowed: params?.dropped.contains(ParamCompat.Group.reasoning) != true,
            displayAllowed: params?.dropped.contains(ParamCompat.Group.thinkingDisplay) != true
        )
        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": limits.maxTokens,
            "stream": true,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = ToolSchemaRenderer.anthropic(tools)
            WebSearchProbe.log("[anthropic-body] tools=\(WebSearchProbe.summarizeTools(tools))")
        } else {
            WebSearchProbe.log("[anthropic-body] tools=<nil-or-empty>")
        }
        if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        if let p = samplingParams {
            // Opus 4.7+ / 5 系：temperature / top_p / top_k 一律 400「deprecated for this model」（10-11 实测，开不开思考都拒）；
            // #094 起按 ParamCompat（学到的 / 目录 / 血统），点号写法也认
            let samplingDeprecated = params.map { !$0.sendsSampling } ?? (ModelLineage.rejectsSampling(model) == true)
            if let thinking = limits.thinking {
                body["thinking"] = thinking
                if let config = limits.outputConfig, params?.dropped.contains(ParamCompat.Group.outputConfig) != true {
                    body["output_config"] = config
                }
                if !samplingDeprecated, p.topP >= 0.95 && p.topP < 1.0 { body["top_p"] = p.topP }
            } else if !samplingDeprecated {
                // opus ≥4.1 / sonnet ≥4.5 / haiku ≥4.5：temperature 和 top_p 只收一个，留 temperature（思考分支本来就只发 top_p，不动）
                let singleSampler = params?.singleSampler ?? ModelLineage.singleSampler(model)
                if p.temperature != 1.0 { body["temperature"] = p.temperature }
                if p.topP != 1.0, !(singleSampler && p.temperature != 1.0) { body["top_p"] = p.topP }
                if p.topK > 0 { body["top_k"] = p.topK }
            }
            body["stream"] = p.streaming
        }

        // ── prompt cache 显式挂标（cacheFriendly 开关，缓存读 0.1×）──
        if samplingParams?.cacheFriendly == true && allowCacheControl {
            // BP1：整段 system。易变内容已被组装层下沉进 messages 的[动态上下文]段，system 全段逐轮稳定
            if let sys = body["system"] as? String, !sys.isEmpty {
                body["system"] = [["type": "text", "text": sys, "cache_control": cacheMark(samplingParams)] as [String: Any]]
            }
            // BP4 rolling：最后一条 assistant 消息末块挂标，把之前全部历史纳进缓存（长会话命中主力）。
            // 不挂倒数第二条 user——cacheFriendly 下那是每轮都变的[动态上下文]伪段，挂上等于没挂。
            // 思考块不能直接挂 cache_control（thinking 回传 §3.3）：挂到它前面最后一个非思考块，整条都是思考就不挂
            if let idx = apiMessages.lastIndex(where: { ($0["role"] as? String) == "assistant" }) {
                var msg = apiMessages[idx]
                if let text = msg["content"] as? String {
                    msg["content"] = [["type": "text", "text": text, "cache_control": cacheMark(samplingParams)] as [String: Any]]
                } else if var blocks = msg["content"] as? [[String: Any]],
                          let at = blocks.lastIndex(where: { !ReplyBlock.isThinking($0) }) {
                    blocks[at]["cache_control"] = cacheMark(samplingParams)
                    msg["content"] = blocks
                }
                apiMessages[idx] = msg
                body["messages"] = apiMessages
            }
            // sticky 路由：user_id 固定，防中转负载均衡缓存只写不读
            body["metadata"] = ["user_id": cacheUserId]
        }
        return body
    }

    /// 当轮工具回合的 assistant 消息（plan-thinking §3.3，Q2-A）：有这一次回复的原样块就整条照发（思考 / redacted / 正文 / server 块一个字节不动），
    /// 只把 tool_use 的 input 换成发出去的那份（审批卡改过的，按 id 对）；没有原样块、或对不上 id = 只发 tool_use（老形状）。
    /// astra #2：改过 input 的 tool_use 后面的思考 / redacted 块签名覆盖了改前的内容，从第一个改过的 tool_use 起往后的思考块都去掉（前面的照留）
    static func toolTurnAssistantContent(_ turn: ToolTurn) -> [[String: Any]] {
        func input(_ call: ToolCallBlock) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        }
        let byId = Dictionary(turn.calls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let content = turn.assistantContent {
            let useIds = Set(content.compactMap { $0["type"] as? String == "tool_use" ? $0["id"] as? String : nil })
            if useIds == Set(byId.keys) {
                var out: [[String: Any]] = []
                var edited = false
                for block in content {
                    if edited, ReplyBlock.isThinking(block) { continue }
                    guard block["type"] as? String == "tool_use", let id = block["id"] as? String, let call = byId[id] else {
                        out.append(block)
                        continue
                    }
                    let sent = input(call)
                    if !NSDictionary(dictionary: block["input"] as? [String: Any] ?? [:]).isEqual(to: sent) { edited = true }
                    var b = block
                    b["input"] = sent
                    out.append(b)
                }
                return out
            }
        }
        let text: [[String: Any]] = turn.text.flatMap { $0.isEmpty ? nil : [["type": "text", "text": $0]] } ?? []
        return text + turn.calls.map { call in ["type": "tool_use", "id": call.id, "name": call.name, "input": input(call)] }
    }

    private static func anthropicContentParts(text: String, images: [PendingChatAttachment]) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        for image in images where image.isImage {
            guard let data = image.imageData, let mime = image.mimeType else { continue }
            parts.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mime,
                    "data": data.base64EncodedString()
                ]
            ])
        }
        return parts
    }

    override func sendNonStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        images: [PendingChatAttachment] = []
    ) async throws -> (String, TokenUsage?) {
        var apiMessages: [[String: Any]] = []
        for (i, msg) in messages.enumerated() {
            if i == messages.count - 1, msg.role == "user", !images.isEmpty {
                apiMessages.append(["role": msg.role, "content": Self.anthropicContentParts(text: msg.content, images: images)])
            } else {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": min(OutputTokenCap.retryCap, OutputTokenCap.modelLimit(model) ?? OutputTokenCap.retryCap),
        ]
        if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }

        guard let url = URL(string: "\(baseURL)/messages") else {
            throw NSError(domain: "ChatService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = Self.encodeBody(body)

        let budgetDecision = await BudgetPreflight.decision(request)
        requestEstimatedCost = budgetDecision.estimatedCost
        guard budgetDecision.allowed else {
            throw NSError(domain: "BudgetGate", code: -1, userInfo: [NSLocalizedDescriptionKey: FixJump.budgetPreflightMessage])
        }
        requestWasSent = true
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            throw NSError(domain: "ChatService", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: ParamErrorClassifier.redacted(
                              Self.extractError(from: data, statusCode: statusCode), secrets: ParamErrorClassifier.secrets(apiKey: apiKey, headers: extraHeaders))])
        }

        // 和聊天的非流式同一个解析：拼全部 text 块（以前只取第一块，第一块是 thinking 就报「无法解析响应」）
        let parsed = try parseNonStreamBody(data)
        return (parsed.text, parsed.usage)
    }

    /// 非流式整包：content[] 的 text / tool_use / web_search_tool_result + usage（含 cache 两字段）+ stop_reason；
    /// 全部块原样另记一份（thinking 回传，和流式同一份 replyBlocks）
    override func parseNonStreamBody(_ data: Data) throws -> NonStreamResult {
        guard let obj = Self.nonStreamObject(data),
              let blocks = obj["content"] as? [[String: Any]] else {
            throw Self.unparsableBody(data)
        }
        blockAccum = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { i, raw in
            (i, ReplyBlock(raw: raw, complete: Self.blockIsComplete(raw)))
        })
        refusalCategory = obj["stop_reason"] as? String == "refusal" ? Self.refusalCategoryIn(obj) : nil
        var text = ""
        var calls: [ToolCallBlock] = []
        var picked: [WebSearchSource] = []
        for cb in blocks {
            switch cb["type"] as? String {
            case "text":
                text += cb["text"] as? String ?? ""
            case "tool_use":
                guard let id = cb["id"] as? String, let name = cb["name"] as? String, !name.isEmpty else { continue }
                let input = cb["input"] ?? [String: Any]()
                let json = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                calls.append(ToolCallBlock(id: id, name: name, argumentsJSON: json))
            case "web_search_tool_result":
                for item in cb["content"] as? [[String: Any]] ?? [] {
                    if item["type"] as? String == "web_search_result",
                       let url = item["url"] as? String, let title = item["title"] as? String {
                        picked.append(WebSearchSource(title: title, url: url, pageAge: item["page_age"] as? String))
                    }
                }
            default:
                continue
            }
        }
        if !picked.isEmpty {
            let sources = picked
            enqueueCallback { [self] in MainActor.assumeIsolated { streamingWebSources.append(contentsOf: sources) } }
        }
        let usage = (obj["usage"] as? [String: Any]).flatMap(APIUsageParser.anthropic)
        let stop = obj["stop_reason"] as? String
        let hit = stop == "max_tokens"
        if stop != "tool_use" && !hit { calls = [] }
        return NonStreamResult(text: text, toolCalls: calls.markingLastTruncated(hit), usage: usage, hitOutputLimit: hit)
    }

    override func processData(_ data: Data) {
        if httpStatusCode != 0 && httpStatusCode != 200 {
            errorBytes.append(data)
            return
        }
        handle(feedSSE(data))
    }

    override func handle(_ fields: [SSELineDecoder.Field]) {
        for field in fields {
            switch field {
            case .event(let name):
                currentEventType = name.trimmingCharacters(in: .whitespaces)
            case .data(let payload):
                handleAnthropicEvent(type: currentEventType, data: payload)
            case .comment, .other:
                break
            }
        }
    }

    /// 思考块要有签名才算完整（停在中途 / 中转剥了签名的不回传）；其余块收到就算
    static func blockIsComplete(_ raw: [String: Any]) -> Bool {
        guard raw["type"] as? String == "thinking" else { return true }
        return !(raw["signature"] as? String ?? "").isEmpty
    }

    /// `stop_details.category`：流式在 message_delta.delta 里，非流式在顶层（两处都看）
    static func refusalCategoryIn(_ obj: [String: Any]) -> String? {
        let details = (obj["stop_details"] as? [String: Any]) ?? ((obj["delta"] as? [String: Any])?["stop_details"] as? [String: Any])
        return details?["category"] as? String
    }

    /// nonZeroOnly：message_delta 只拿非零值覆盖 message_start（中转的 start 是占位 1、真值在 delta；delta 里的 0 不抹掉 start 的真值，R10）。
    /// 只给非官方地址开；官方直连字段在就覆盖（0 也是真值）
    private func captureBillingDimensions(_ usage: [String: Any], nonZeroOnly: Bool = false) {
        func value(_ v: Any?) -> Int? {
            guard let n = v as? Int, !(nonZeroOnly && n == 0) else { return nil }
            return n
        }
        if let input = value(usage["input_tokens"]) { accumulatedInputTokens = input }
        if let thinking = value((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]) {
            accumulatedReasoningTokens = thinking
        }
        if let read = value(usage["cache_read_input_tokens"]) { accumulatedCacheReadTokens = read }
        if let write = value(usage["cache_creation_input_tokens"]) { accumulatedCacheWriteTokens = write }
        let buckets = usage["cache_creation"] as? [String: Any]
        let five = value(buckets?["ephemeral_5m_input_tokens"])
        let hour = value(buckets?["ephemeral_1h_input_tokens"])
        if let hour { accumulatedCacheWrite1hTokens = hour }
        if five != nil || hour != nil {
            accumulatedCacheWriteTokens = value(usage["cache_creation_input_tokens"]) ?? (five ?? 0) + (hour ?? 0)
        }
        if let searches = (usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int {
            accumulatedWebSearches = searches
        }
    }

    private func handleAnthropicEvent(type: String, data: String) {
        guard let jsonData = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return }

        switch type {
        case "message_start":
            // { "type": "message_start", "message": { "usage": { "input_tokens": N, "output_tokens": 0 } } }
            if let msg = obj["message"] as? [String: Any],
               let u = msg["usage"] as? [String: Any],
               let it = u["input_tokens"] as? Int {
                #if DEBUG
                print("[PROBE] Anthropic message_start usage 原始: \(u)")
                #endif
                CacheDiagLog.shared.log("← anthropic直连 prompt \(it) · 读 \(u["cache_read_input_tokens"] as? Int ?? 0) · 写 \(u["cache_creation_input_tokens"] as? Int ?? 0)")
                captureBillingDimensions(u)
                accumulatedInputTokens = it
                if let cr = u["cache_read_input_tokens"] as? Int { accumulatedCacheReadTokens = cr }
                if let cw = u["cache_creation_input_tokens"] as? Int { accumulatedCacheWriteTokens = cw }
                gotUsage = true
            }

        case "content_block_start":
            // tool_use 块开始：记 id/name，input 靠后续 input_json_delta 拼接
            if let cb = obj["content_block"] as? [String: Any] {
                blockAccum[obj["index"] as? Int ?? 0] = ReplyBlock(raw: cb, complete: false)
                let type = cb["type"] as? String
                if type == "tool_use", let id = cb["id"] as? String, let name = cb["name"] as? String {
                    let idx = obj["index"] as? Int ?? 0
                    toolUseAccum[idx] = (id: id, name: name, json: "")
                } else if type == "web_search_tool_result", let content = cb["content"] as? [[String: Any]] {
                    // Anthropic server-side web search 返回：content 数组里是 web_search_result 项
                    // 直接 in content_block_start 携带，不走 delta
                    var picked: [WebSearchSource] = []
                    for item in content {
                        if item["type"] as? String == "web_search_result",
                           let url = item["url"] as? String,
                           let title = item["title"] as? String {
                            picked.append(WebSearchSource(
                                title: title, url: url,
                                pageAge: item["page_age"] as? String
                            ))
                        }
                    }
                    if !picked.isEmpty {
                        enqueueCallback { [self] in
                            MainActor.assumeIsolated { self.streamingWebSources.append(contentsOf: picked) }
                        }
                    }
                }
            }

        case "content_block_delta":
            if let delta = obj["delta"] as? [String: Any] {
                let idx = obj["index"] as? Int ?? 0
                if let text = delta["text"] as? String {
                    appendToBlock(idx, key: "text", text)
                    enqueueCallback { [self] in
                        streamingContent += text
                        onToken?(text)
                    }
                } else if let partial = delta["partial_json"] as? String {
                    if var entry = toolUseAccum[idx] { entry.json += partial; toolUseAccum[idx] = entry }
                    blockInputJSON[idx, default: ""] += partial
                } else if let thinking = delta["thinking"] as? String {
                    appendToBlock(idx, key: "thinking", thinking)
                } else if let signature = delta["signature"] as? String {
                    blockAccum[idx]?.raw["signature"] = signature
                } else if let citation = delta["citation"] {
                    if var block = blockAccum[idx] {
                        block.raw["citations"] = (block.raw["citations"] as? [Any] ?? []) + [citation]
                        blockAccum[idx] = block
                    }
                }
            }

        case "content_block_stop":
            let idx = obj["index"] as? Int ?? 0
            if var block = blockAccum[idx] {
                if let json = blockInputJSON[idx], !json.isEmpty {
                    block.raw["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
                }
                block.complete = Self.blockIsComplete(block.raw)
                blockAccum[idx] = block
            }

        case "message_delta":
            // { "type": "message_delta", "delta": { "stop_reason": ... }, "usage": { "output_tokens": N } }
            if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                stopReason = sr
                hitOutputLimit = sr == "max_tokens"
                if sr == "refusal" { refusalCategory = Self.refusalCategoryIn(obj) }
            }
            if let u = obj["usage"] as? [String: Any] {
                captureBillingDimensions(u, nonZeroOnly: KnownHost.detect(usageBaseURL) != .anthropic)
                if let output = u["output_tokens"] as? Int { accumulatedOutputTokens = output }
                gotUsage = true
            }

        case "message_stop":
            receivedDone = true
            enqueueCallback { [self] in
                isStreaming = false
                if stopReason == "tool_use" || stopReason == "max_tokens", !toolUseAccum.isEmpty, let cb = onToolCalls {
                    let calls = toolUseAccum.sorted { $0.key < $1.key }.map {
                        ToolCallBlock(id: $0.value.id, name: $0.value.name,
                                      argumentsJSON: $0.value.json.isEmpty ? "{}" : $0.value.json)
                    }
                    cb(calls.markingLastTruncated(stopReason == "max_tokens"))
                } else {
                    onComplete?(streamingContent, finalUsage)
                }
            }

        case "error":
            if let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String {
                terminatedByError = true
                streamErrorBody = data
                enqueueCallback { [self] in
                    isStreaming = false
                    error = message
                    onError?(message)
                }
            }

        default:
            break
        }
    }

    private func appendToBlock(_ idx: Int, key: String, _ piece: String) {
        guard var block = blockAccum[idx] else { return }
        block.raw[key] = (block.raw[key] as? String ?? "") + piece
        blockAccum[idx] = block
    }
}

// MARK: - Provider Router

private final class ToolCallTerminalState {
    var didEmitToolCalls = false
}

/// 每次上游调用的终止快照只生成一次；完成 / 错误 / 取消重复到达时返回同一收据。
@MainActor
final class RequestUsageSettlement {
    let requestId = UUID().uuidString
    private(set) var keyIdentity: String?
    private(set) var recoveryKey: String?

    func freezeKey(_ key: String, host: String) {
        guard recoveryKey == nil else { return }
        recoveryKey = key
        keyIdentity = BillingKeyIdentity.hash(key, host: host)
    }

    private(set) var receipt: TokenUsage?
    var isSettled: Bool { receipt != nil }
    /// #094：400 / 422 参数拒收、马上要自愈重发的那次——账本照记 .error，但预算扣 0（没生成，不能把重试那次挤出闸）
    var budgetWaived = false

    func settle(_ usage: TokenUsage?, build: (TokenUsage?) -> TokenUsage) -> TokenUsage {
        if let receipt { return receipt }
        let frozen = build(usage)
        receipt = frozen
        return frozen
    }
}

@Observable
final class ProviderRouter {
    /// 这个 router 发的请求记在谁名下（用量账本，research-magpie 2.1）。共用 router 的一方在每次发送前改它。
    @ObservationIgnored var usageContext: UsageContext
    @ObservationIgnored var ledger: UsageLedger = .shared
    @ObservationIgnored private(set) var lastUsageRecord: UsageRecord?
    @ObservationIgnored private var pendingUsageOnCancel: (() -> Void)?

    init(usageContext: UsageContext = UsageContext()) {
        self.usageContext = usageContext
    }

    /// 上一次回复停在输出上限（VM 在 onComplete 里读，同 currentWebSources 的模式）；只认通用分支
    @ObservationIgnored private(set) var lastReplyHitOutputLimit = false
    /// 上一次实发的可见输出上限（越界重试后是 8192）；没带采样参数的请求为 nil
    @ObservationIgnored private(set) var lastRequestedMaxTokens: Int?
    /// #094：这一回合 400 自愈学到了东西（「这个模型不收 temperature / top_p，已自动去掉」）；目录 / 血统本来就知道的不提示。
    /// VM 在 onComplete / onError / onToolCalls 里取（取一次就清），出聊天页小灰字
    @ObservationIgnored private(set) var lastParamAdaptation: String?

    /// 5xx / 429 / 连接断开的自动重试正在等（plan-model-compat-p0 §7.4）：停止按钮要能取消它
    private var pendingRetry: DispatchWorkItem?
    /// 重试代际（审查 #1）：cancel() / 新一轮 sendStreaming 都 +1；排好的重试执行前核对，对不上就作废（不靠可被覆盖的 pendingRetry）
    @ObservationIgnored private var retryGeneration = 0
    /// 重试前等多久（单测换成 0）
    @ObservationIgnored var retryDelay: (TimeInterval) -> TimeInterval = { $0 }

    func consumeParamAdaptation() -> String? {
        defer { lastParamAdaptation = nil }
        return lastParamAdaptation
    }

    /// 每次 sendStreaming 一进来就 +1（在任何提前失败之前）；Anthropic provider 真开始这一次请求时记下它（astra #7）
    @ObservationIgnored private var requestSerial = 0
    /// anthropicProvider 里那份块属于第几次请求（换卡 / 没 key 提前失败 / 别的卡都对不上 → 读到空）
    @ObservationIgnored private var anthropicBlocksSerial = -1

    /// thinking 回传（plan-thinking §3.1）：这一次请求的 Anthropic 回复全部内容块，按回复顺序；VM 在 onComplete / onToolCalls / onError / 停止 时读。
    /// 这一次不是 Anthropic、或还没真发出去就失败了 = 空
    var lastAssistantBlocks: [ReplyBlock] {
        anthropicBlocksSerial == requestSerial ? anthropicProvider.replyBlocks : []
    }

    /// openAIProvider 里那份思考属于第几次请求（同 anthropicBlocksSerial）
    @ObservationIgnored private var openAIReasoningSerial = -1

    /// OpenAI 兼容路这一次回复的思考（plan-model-compat-p0 §4.3）；不是这一次的 / 没有 = nil
    var lastReasoning: ReasoningCapture? {
        guard openAIReasoningSerial == requestSerial, !openAIProvider.reasoning.isEmpty else { return nil }
        return openAIProvider.reasoning
    }

    /// 这一次回复要存的思考段：Anthropic 块 + OpenAI 兼容路的思考（两者不会同时有）
    var lastThinkingSegments: [MessageSegment] {
        lastAssistantBlocks.thinkingSegments + (lastReasoning?.segment.map { [$0] } ?? [])
    }

    /// 这一次请求是「思考块被拒、去块重发」那一次（astra #1）：VM 后面几轮的 toolTurns 要沿用去块的版本，不能把被拒的块再带回来
    @ObservationIgnored private var thinkingStrippedSerial = -1
    var lastRequestDroppedThinking: Bool { thinkingStrippedSerial == requestSerial }

    /// 这一次 Anthropic 回复 `stop_reason: refusal` 的 `stop_details.category`
    var lastRefusalCategory: String? {
        anthropicBlocksSerial == requestSerial ? anthropicProvider.refusalCategory : nil
    }

    private var openAIProvider = OpenAICompatibleProvider()
    private var anthropicProvider = AnthropicProvider()
    private var ccBridgeProvider = CCBridgeProvider()
    private var chatgptOAuthProvider = ChatGPTOAuthProvider()
    private var localProvider = LocalChatProvider()
    #if (DEBUG || PERF_BENCH) && os(macOS)
    @ObservationIgnored private var perfMacStream: PerfHarnessMacStream?
    private static let perfMacRequested: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["MP_PERF_RUN"] == "1" || environment["MP_PERF_UI"] == "1"
    }()
    #endif
    #if (DEBUG || PERF_BENCH) && os(iOS)
    /// 纵切 6 脚本流（perf P0 §6.6）：只在严格测量角色下创建（let 不进观察）；对象本身可观察，进 isStreaming 的 OR 链
    let perfScripted: PerfScriptedStream? = PerfHarness.strictMeasure ? PerfScriptedStream() : nil
    #endif

    var isStreaming: Bool {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.active, Self.perfMacRequested,
           MainActor.assumeIsolated({ PerfHarnessMac.streamEnabled && perfMacStream?.isStreaming == true }) { return true }
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure, perfScripted?.isStreaming == true { return true }
        #endif
        return openAIProvider.isStreaming || anthropicProvider.isStreaming || ccBridgeProvider.isStreaming || chatgptOAuthProvider.isStreaming
            || localProvider.isStreaming || pendingRetry != nil
    }

    /// 当前 anthropic 流累积的 web search sources（server tool 解出来的）。
    /// finalize 时 CV 取这里写 MessageNode.webSourcesData。
    @MainActor
    var currentWebSources: [WebSearchSource] {
        anthropicProvider.streamingWebSources
    }

    var streamingContent: String {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.active, Self.perfMacRequested,
           let content = MainActor.assumeIsolated({ PerfHarnessMac.streamEnabled ? perfMacStream?.content : nil }) { return content }
        #endif
        if openAIProvider.isStreaming || !openAIProvider.streamingContent.isEmpty {
            return openAIProvider.streamingContent
        }
        if anthropicProvider.isStreaming || !anthropicProvider.streamingContent.isEmpty {
            return anthropicProvider.streamingContent
        }
        if chatgptOAuthProvider.isStreaming || !chatgptOAuthProvider.streamingContent.isEmpty {
            return chatgptOAuthProvider.streamingContent
        }
        if localProvider.isStreaming || !localProvider.streamingContent.isEmpty {
            return localProvider.streamingContent
        }
        return ccBridgeProvider.streamingContent
    }

    var error: String? {
        openAIProvider.error ?? anthropicProvider.error ?? chatgptOAuthProvider.error ?? ccBridgeProvider.error ?? localProvider.error
    }

    /// #089 P0-c：主聊天的请求真发出去那一刻按对话存一份（摘要 / 标题等别的用途不存）。round = 本回合第几次请求
    private func sentRequestRecorder(model: ProviderModel, round: Int, secrets: [String]) -> ((URLRequest) -> Void)? {
        guard usageContext.kind == .chat, let conversationId = usageContext.conversationId else { return nil }
        let turnId = usageContext.messageNodeId
        return { request in
            MainActor.assumeIsolated {
                SentRequestStore.shared.record(conversationId: conversationId, turnId: turnId, round: round, model: model.modelId,
                                               request: request, secrets: secrets)
            }
        }
    }

    func sendStreaming(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        providerManager: ProviderManager,
        samplingParams: SamplingParams? = nil,
        imageMap: [String: [PendingChatAttachment]] = [:],
        additionalHeaders: [String: String] = [:],
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        ordered: [PromptMessage]? = nil,
        attempt: Int = 0,   // #094：400 自愈的重试那次传 1，不再进自愈（只重试一次）
        transientRetry: Int = 0,   // 5xx / 429 / 连接断开已经自动重试了几次（§7.4），和 attempt 互不重置
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void,
        onToolCalls: (([ToolCallBlock], TokenUsage?) -> Void)? = nil,
        onRetry: ((String) -> Void)? = nil
    ) {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.active, Self.perfMacRequested,
           MainActor.assumeIsolated({ PerfHarnessMac.streamEnabled && model.credentialId == PerfHarnessMacStream.credentialID }) {
            MainActor.assumeIsolated {
                lastUsageRecord = nil
                lastReplyHitOutputLimit = false
                lastRequestedMaxTokens = nil
                lastParamAdaptation = nil
                requestSerial += 1
                if perfMacStream == nil { perfMacStream = PerfHarnessMacStream() }
                perfMacStream?.play(modelID: model.modelId, onToken: onToken, onComplete: onComplete, onError: onError)
            }
            return
        }
        if BenchIsolation.active, Self.perfMacRequested {
            MainActor.assumeIsolated {
                perfMacStream?.stop()
                perfMacStream = nil
            }
        }
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure {
            // 严格测量角色（plan-chat-list-perf-p0 §3.1 / §6.6）：perf-scripted 在 provider 查找与陷阱之前交给脚本流；其它凭据 = 意外外发，记录并停轮
            if model.credentialId == PerfChatCore.StreamScript.credentialId, let scripted = perfScripted {
                scripted.play(modelId: model.modelId, onToken: onToken, onComplete: onComplete, onError: onError)
                return
            }
            PerfGuardrails.tripOutbound("router.stream", model.credentialId)
            onError("[PERF] 严格测量角色拒绝外发")
            return
        }
        #endif
        let capped = samplingParams.map { OutputTokenCap.resolved($0, modelId: model.modelId) }
        lastUsageRecord = nil
        lastReplyHitOutputLimit = false
        lastRequestedMaxTokens = capped?.maxTokens
        if attempt == 0 && transientRetry == 0 { lastParamAdaptation = nil }
        pendingRetry?.cancel()
        pendingRetry = nil
        retryGeneration += 1
        requestSerial += 1
        guard let provider = providerManager.provider(for: model) else {
            onError(FixJump.missingProviderMessage(model.credentialId))
            return
        }
        let samplingParams = Self.adaptedSampling(capped, provider: provider, modelId: model.modelId)

        // 用量账本：每个请求的终止事件（完成 / 出错 / 工具轮）各记一条。发请求前就失败的（没 key 等）不记。
        let started = Date()
        let usageContext = self.usageContext
        let ledger = self.ledger
        let estimatedCost = BudgetCalculator.estimateCost(provider: provider, modelId: model.modelId,
            messages: messages, systemPrompt: systemPrompt,
            maxOutputTokens: samplingParams.map { OutputTokenCap.budgetEstimate($0, modelId: model.modelId) } ?? OutputTokenCap.budgetExpected,
            estimator: HeuristicEstimator())
        let settlement = MainActor.assumeIsolated { RequestUsageSettlement() }
        let record: (TokenUsage?, UsageRecord.Status) -> TokenUsage? = { [weak self] usage, status in
            MainActor.assumeIsolated {
                settlement.settle(usage) { usage in
                    let sent: Bool
                    switch provider.type {
                    case .openaiCompatible: sent = self?.openAIProvider.requestWasSent ?? false
                    case .anthropic: sent = self?.anthropicProvider.requestWasSent ?? false
                    default: sent = true
                    }
                    var row = UsageRecord(provider: provider, modelId: model.modelId, usage: usage,
                                          started: started, ended: Date(), status: status, context: usageContext, requestSent: sent)
                    row.requestId = settlement.requestId
                    row.keyIdentity = settlement.keyIdentity
                    let wireEstimate = provider.type == .anthropic ? self?.anthropicProvider.requestEstimatedCost : self?.openAIProvider.requestEstimatedCost
                    row.budgetChargeUSD = settlement.budgetWaived ? 0 : row.budgetCost(estimatedCost: wireEstimate ?? estimatedCost)
                    self?.lastUsageRecord = row
                    ledger.append(row)
                    if usageContext.kind == .chat { CacheHitMeter.shared.record(conversationId: usageContext.conversationId, usage: usage) }
                    GlobalBudgetStore.shared.commitSpend(row.budgetChargeUSD ?? 0)
                    if APIUsageParser.isOpenRouter(provider.baseURL), row.responseId != nil, row.costSource != .reported,
                       let key = settlement.recoveryKey {
                        Task {
                            if let correction = await OpenRouterCostRecovery().recover(row, apiKey: key, ledger: ledger) {
                                await MainActor.run { UsageCostSettlement.shared.apply(correction, original: row) }
                            }
                        }
                    }
                    var usage = usage ?? TokenUsage(inputTokens: 0, outputTokens: 0, completeness: .missing)
                    usage.ledgerCostUSD = row.costUSD
                    usage.ledgerCostRecorded = true
                    usage.ledgerSpendRecorded = true
                    usage.ledgerRecord = row
                    usage.completeness = row.usageState ?? .missing
                    return usage
                }
            }
        }
        let finished: (String, TokenUsage?) -> Void = { text, usage in
            guard MainActor.assumeIsolated({ !settlement.isSettled }) else { return }
            onComplete(text, record(usage, .ok))
        }
        let requestFailed: (String) -> Void = { [weak self] message in
            guard MainActor.assumeIsolated({ !settlement.isSettled }) else { return }
            let usage: TokenUsage?
            switch provider.type {
            case .openaiCompatible: usage = self?.openAIProvider.finalUsage
            case .anthropic: usage = self?.anthropicProvider.finalUsage
            default: usage = nil
            }
            _ = record(usage, .error)
            onError(message)
        }
        let toolRoundFinished: (([ToolCallBlock], TokenUsage?) -> Void)? = onToolCalls.map { callback in
            { calls, usage in
                guard MainActor.assumeIsolated({ !settlement.isSettled }) else { return }
                callback(calls, record(usage, .ok))
            }
        }

        // 本机模型：不走网络、不记账（不花钱）；工具不下发，见 LocalChatProvider
        if provider.type == .localMLX {
            BreadcrumbLog.shared.add("🌱", "请求 本机/\(model.modelId) · \(messages.count)条 · sys \(systemPrompt?.count ?? 0)字")
            let effort = samplingParams?.reasoningEffort ?? ReasoningEffort.auto
            localProvider.send(modelId: model.modelId, messages: messages, systemPrompt: systemPrompt,
                               hasImages: !imageMap.isEmpty, thinking: effort != ReasoningEffort.auto && effort != "none",
                               onToken: onToken, onComplete: onComplete, onError: onError)
            return
        }

        // chatgptOAuth：apiKey 是 OAuth JSON，要先解码 + 必要时刷新 → 拿干净 access_token
        if provider.type == .chatgptOAuth {
            let raw = providerManager.apiKey(for: provider.id) ?? ""
            guard let token = OAuthTokenSet.fromKeychainString(raw) else {
                onError("ChatGPT 账号未登录")
                return
            }
            BreadcrumbLog.shared.add("🌐", "请求 \(provider.name)/\(model.modelId) · \(messages.count)条 · 工具\(tools?.count ?? 0) · sys \(systemPrompt?.count ?? 0)字")
            let mergedHeaders = provider.extraHeaders.merging(additionalHeaders) { _, new in new }
            let terminalState = ToolCallTerminalState()
            Task { @MainActor in
                do {
                    let access = try await Self.ensureFreshAccessToken(token, credentialId: provider.id, providerManager: providerManager)
                    let oauthProvider = self.chatgptOAuthProvider
                    oauthProvider.onRequestSent = self.sentRequestRecorder(model: model, round: toolTurns.count, secrets: [access])
                    self.chatgptOAuthProvider.sendStreaming(
                        messages: messages,
                        model: model.modelId,
                        systemPrompt: systemPrompt,
                        apiKey: access,
                        baseURL: provider.baseURL,
                        extraHeaders: mergedHeaders,
                        samplingParams: samplingParams,
                        imageMap: imageMap,
                        tools: tools,
                        toolTurns: toolTurns,
                        onToken: onToken,
                        onComplete: { text, usage in
                            guard !terminalState.didEmitToolCalls, !settlement.isSettled else { return }
                            _ = record(usage, .ok)
                            onComplete(text, usage)
                        },
                        onError: requestFailed,
                        onToolCalls: onToolCalls.map { callback in
                            { [weak oauthProvider] calls in
                                MainActor.assumeIsolated {
                                    guard !terminalState.didEmitToolCalls, !settlement.isSettled else { return }
                                    terminalState.didEmitToolCalls = true
                                    let usage = oauthProvider?.finalUsage
                                    _ = record(usage, .ok)
                                    callback(calls, usage)
                                }
                            }
                        }
                    )
                } catch {
                    await MainActor.run { onError("ChatGPT 登录已过期，请重新登录：\(error.localizedDescription)") }
                }
            }
            return
        }

        // ccBridge 用 keychain value 当 token（loopback 可空，LAN 必填）
        let apiKey: String
        if provider.type == .ccBridge {
            apiKey = providerManager.apiKey(for: provider.id) ?? ""
        } else {
            guard let key = providerManager.apiKey(for: provider.id) else {
                onError(FixJump.noKeyMessage(provider.name))
                return
            }
            apiKey = key
        }

        let chatProvider: BaseChatProvider
        switch provider.type {
        case .openaiCompatible:
            chatProvider = openAIProvider
        case .anthropic:
            chatProvider = anthropicProvider
        case .ccBridge:
            chatProvider = ccBridgeProvider
        case .chatgptOAuth, .localMLX:
            return  // 上面已 return
        case .unsupported:
            // 本版本不认识的卡类型：明确报错，绝不降级成 openaiCompatible
            // （那会把用户的 key 发到错误端点——对比线洞 4 的次生伤害）
            onError(FixJump.unsupportedCardMessage(provider.unknownTypeRaw))
            return
        }

        BreadcrumbLog.shared.add("🌐", "请求 \(provider.name)/\(model.modelId) · \(messages.count)条 · 工具\(tools?.count ?? 0) · sys \(systemPrompt?.count ?? 0)字")
        let mergedHeaders = provider.extraHeaders.merging(additionalHeaders) { _, new in new }
        let forwardedToolCalls = toolRoundFinished.map { callback in
            { [weak chatProvider] calls in
                callback(calls, chatProvider?.finalUsage)
            }
        }
        // #094 400 自愈（plan-param-autoadapt §3.5，把原 R8 越界重试并进来）：报错点名了这次真发的参数 → 立刻记进记忆表（Q3），
        // 第一次、还没收到任何输出时同参数再发一次（重新走 ParamCompat，自然不发了）；上限越界照旧降 8192，可同一次重试一起做
        let adaptiveFailed: (String) -> Void = { [weak self, weak chatProvider] message in
            // 终态去重（审查 #1）：这一次已经结算过（报过错 / 排过重试 / 停止了）就不再进，重复的错误回调不会多排一个重试
            guard MainActor.assumeIsolated({ !settlement.isSettled }) else { return }
            let safe = { (text: String) in ParamErrorClassifier.redacted(text, secrets: ParamErrorClassifier.secrets(apiKey: apiKey, headers: mergedHeaders)) }
            guard let self, let chatProvider else { requestFailed(safe(message)); return }
            let status = chatProvider.httpStatusCode
            let host = URL(string: provider.baseURL)?.host ?? provider.baseURL
            var fixes: [ParamErrorClassifier.Fix] = []
            if provider.type == .openaiCompatible || provider.type == .anthropic,
               case .fix(let found) = ParamErrorClassifier.classify(status: status, body: chatProvider.errorBody,
                                                                    sent: chatProvider.sentShape, host: host) {
                fixes = found
            }
            let learned = ParamErrorClassifier.learned(from: fixes)
            if learned != ParamCompat.Learned() {
                let safeBody = safe(chatProvider.errorBody)
                ParamAdaptStore.shared.learn(providerType: provider.type, baseURL: provider.baseURL, modelId: model.modelId, adding: learned, rawError: safeBody)
                CacheDiagLog.shared.log("✂️ 参数自适配 \(host) · \(model.modelId)：\(learned.summary)｜原文 \(safeBody.prefix(300))")
            }
            // 原 R8：没认成改键名、正文提到输出上限也算（老判断），只在上限 > 8192 时降。
            // astra #5：整个重试决策只认 400 / 422（429 / 500 正文提到 max_tokens 不降不重发）
            let wantsLowerCap = fixes.contains(.lowerOutputCap)
                || (!fixes.contains(where: \.isRename) && OutputTokenCap.mentionsOutputLimit(message))
            // 中转按 max_tokens 预扣额度（R2）：402 / 403 insufficient_user_quota 也先降上限重发一次，不学。
            // 按实发上限（Anthropic 含思考余量）判断、按实发算重发值
            let prepaid = ChatErrorClassifier.isPrepaidQuota(.init(status: status, body: chatProvider.errorBody))
            let prepaidRetry = prepaid ? capped.flatMap {
                OutputTokenCap.prepaidRetry($0, sentMaxTokens: chatProvider.sentShape.sentMaxTokens ?? $0.maxTokens)
            } : nil
            let lowerCap = ParamErrorClassifier.isParamRejection(status: status) && wantsLowerCap
                && (capped?.maxTokens ?? 0) > OutputTokenCap.retryCap
            let noOutput = !chatProvider.hasEmittedOutput
            // thinking 回传 §3.6：当轮思考块被拒（多半是中转改了 body）→ 不学不记，这一次去掉思考块重发一次（缺块时 API 降级、不报错，R6）
            if attempt == 0, noOutput, provider.type == .anthropic, toolTurns.contains(where: { $0.thinkingBlockCount > 0 }),
               ParamErrorClassifier.isParamRejection(status: status),
               ParamErrorClassifier.classify(status: status, body: chatProvider.errorBody, sent: chatProvider.sentShape, host: host) == .thinkingBlocksRejected {
                MainActor.assumeIsolated { settlement.budgetWaived = true }
                _ = record(nil, .error)
                CacheDiagLog.shared.log("🧠 思考块没被接受 \(host) · \(model.modelId)，这一次去掉重发｜原文 \(safe(chatProvider.errorBody).prefix(300))")
                BreadcrumbLog.shared.add("🧠", "思考块没被接受，这一次没带，重试")
                self.lastParamAdaptation = "思考块没被接受，这一次没带"
                self.sendStreaming(
                    model: model, messages: messages, systemPrompt: systemPrompt, providerManager: providerManager,
                    samplingParams: capped, imageMap: imageMap, additionalHeaders: additionalHeaders,
                    tools: tools, toolTurns: toolTurns.map { $0.droppingThinking() }, ordered: ordered, attempt: 1,
                    transientRetry: transientRetry,
                    onToken: onToken, onComplete: onComplete, onError: onError, onToolCalls: onToolCalls, onRetry: onRetry
                )
                self.thinkingStrippedSerial = self.requestSerial   // 上面同步开了重发那一次（serial 已 +1）
                return
            }
            // 中转不认 1 小时缓存（粟粟 10-15）：provider 已把这个地址记成 5 分钟，这一条就按 5 分钟重发，不报错。
            // 不占 400 自愈那一次（astra：先去 temperature 再撞 ttl 也要能过）；地址进了黑名单下一次必发 5 分钟，不会再进这里
            if noOutput, (chatProvider as? AnthropicProvider)?.longTTLRejected == true,
               AnthropicProvider.longTTLBlacklistContains(provider.baseURL) {
                MainActor.assumeIsolated { settlement.budgetWaived = true }
                _ = record(nil, .error)
                BreadcrumbLog.shared.add("📦", "这个地址不认 1 小时缓存，改 5 分钟重试")
                let droppedThinking = self.lastRequestDroppedThinking
                self.sendStreaming(
                    model: model, messages: messages, systemPrompt: systemPrompt, providerManager: providerManager,
                    samplingParams: capped, imageMap: imageMap, additionalHeaders: additionalHeaders,
                    tools: tools, toolTurns: toolTurns, ordered: ordered, attempt: attempt,
                    transientRetry: transientRetry,
                    onToken: onToken, onComplete: onComplete, onError: onError, onToolCalls: onToolCalls, onRetry: onRetry
                )
                if droppedThinking { self.thinkingStrippedSerial = self.requestSerial }
                return
            }
            // 思考预算比上限大（R4）：不降上限，这一次把思考档压到 low 重发（Anthropic 预算路是 1024；OpenAI 兼容只发 low，中转怎么折算不保证），不学
            if attempt == 0, noOutput, fixes.contains(.fitThinkingBudget), let effort = capped?.reasoningEffort,
               (ReasoningEffort.headroom(effort) ?? 0) > ReasoningEffort.headroom("low") ?? 0 {
                MainActor.assumeIsolated { settlement.budgetWaived = true }
                _ = record(nil, .error)
                CacheDiagLog.shared.log("🧠 思考预算比上限大 \(host) · \(model.modelId)，这一次压到最低档重发｜原文 \(safe(chatProvider.errorBody).prefix(300))")
                BreadcrumbLog.shared.add("🧠", "思考预算比上限大，压到最低档重试")
                self.lastParamAdaptation = "思考预算比输出上限大，这一次把思考压到最低档"
                var retry = capped
                retry?.reasoningEffort = "low"
                self.sendStreaming(
                    model: model, messages: messages, systemPrompt: systemPrompt, providerManager: providerManager,
                    samplingParams: retry, imageMap: imageMap, additionalHeaders: additionalHeaders,
                    tools: tools, toolTurns: toolTurns, ordered: ordered, attempt: 1,
                    transientRetry: transientRetry,
                    onToken: onToken, onComplete: onComplete, onError: onError, onToolCalls: onToolCalls, onRetry: onRetry
                )
                return
            }
            // 学到「要回传思考」但这次续轮里没有可回传的思考（中转剥了 / 不是续轮）：重发也一样，不重发
            var retryLearned = learned
            if !toolTurns.contains(where: { !($0.reasoning?.isEmpty ?? true) }) {
                retryLearned.groups.remove(ParamCompat.Group.reasoningReplayRequired)
            }
            if attempt == 0, noOutput, retryLearned != ParamCompat.Learned() || lowerCap || prepaidRetry != nil {
                MainActor.assumeIsolated { settlement.budgetWaived = true }
                _ = record(nil, .error)
                var retry = prepaidRetry ?? capped
                if learned != ParamCompat.Learned() {
                    BreadcrumbLog.shared.add("✂️", "参数自适配：\(learned.summary)，重试")
                    self.lastParamAdaptation = ParamErrorClassifier.notice(fixes)
                }
                if prepaidRetry != nil {
                    BreadcrumbLog.shared.add("✂️", "按输出上限预扣被拒，实发上限降到 \(OutputTokenCap.retryCap) 以内重试")
                } else if lowerCap, let cap = retry?.maxTokens {
                    BreadcrumbLog.shared.add("✂️", "输出上限 \(cap) 被拒，降到 \(OutputTokenCap.retryCap) 重试")
                    retry?.maxTokens = OutputTokenCap.retryCap
                }
                self.sendStreaming(
                    model: model, messages: messages, systemPrompt: systemPrompt, providerManager: providerManager,
                    samplingParams: retry, imageMap: imageMap, additionalHeaders: additionalHeaders,
                    tools: tools, toolTurns: toolTurns, ordered: ordered, attempt: 1,
                    transientRetry: transientRetry,
                    onToken: onToken, onComplete: onComplete, onError: onError, onToolCalls: onToolCalls, onRetry: onRetry
                )
                return
            }
            // §7.4：服务器忙 / 限流 / 连接中途断开，还没出字 → 等一会儿原样再发（最多 2 次）
            let errorInput = ChatErrorClassifier.Input(status: status, body: chatProvider.errorBody, streamError: chatProvider.streamErrorBody,
                                                       headers: chatProvider.responseHeaders, urlErrorCode: chatProvider.urlErrorCode,
                                                       host: KnownHost.detect(provider.baseURL))
            let kind = ChatErrorClassifier.classify(errorInput)
            let compatPath = provider.type == .openaiCompatible || provider.type == .anthropic
            // 明确被拒、没生成 → 预算扣 0，和重不重试、是不是最后一次无关（审查 #3）；连接断开处理状态不明，照估算记
            if compatPath, noOutput, ChatErrorClassifier.isExplicitRejection(errorInput) {
                MainActor.assumeIsolated { settlement.budgetWaived = true }
            }
            if compatPath, noOutput, let wait = ChatErrorClassifier.retryWait(kind, retry: transientRetry) {
                _ = record(nil, .error)
                let jittered = if case .rateLimited(.some) = kind { wait + Double.random(in: 0...0.5) } else { wait }
                CacheDiagLog.shared.log("⏳ \(host) · \(model.modelId) 第 \(transientRetry + 1) 次自动重试（\(kind)，等 \(jittered) 秒）｜原文 \(safe(message).prefix(300))")
                BreadcrumbLog.shared.add("⏳", "\(status > 0 ? "HTTP \(status)" : "连接断开")，\(ChatErrorClassifier.wholeSeconds(wait)) 秒后自动重试")
                let droppedThinking = self.lastRequestDroppedThinking
                let generation = self.retryGeneration
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.retryGeneration == generation else { return }
                    self.pendingRetry = nil
                    self.sendStreaming(
                        model: model, messages: messages, systemPrompt: systemPrompt, providerManager: providerManager,
                        samplingParams: capped, imageMap: imageMap, additionalHeaders: additionalHeaders,
                        tools: tools, toolTurns: toolTurns, ordered: ordered, attempt: attempt,
                        transientRetry: transientRetry + 1,
                        onToken: onToken, onComplete: onComplete, onError: onError, onToolCalls: onToolCalls, onRetry: onRetry
                    )
                    if droppedThinking { self.thinkingStrippedSerial = self.requestSerial }
                }
                self.pendingRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay(jittered), execute: work)
                onRetry?(ChatErrorClassifier.retryNotice(kind, wait: wait, retry: transientRetry))
                return
            }
            requestFailed(safe(Self.failureMessage(message, status: status, host: host, modelId: model.modelId,
                                                   cap: samplingParams?.maxTokens, sent: chatProvider.sentShape,
                                                   errorBody: chatProvider.errorBody, providerType: provider.type,
                                                   learnedNow: attempt > 0 ? learned : ParamCompat.Learned(),
                                                   kind: kind, retried: transientRetry)))
        }
        MainActor.assumeIsolated { settlement.freezeKey(apiKey, host: URL(string: provider.baseURL)?.host ?? "") }
        chatProvider.onRequestSent = sentRequestRecorder(model: model, round: toolTurns.count, secrets: [apiKey])
        pendingUsageOnCancel = { [weak chatProvider] in
            _ = record(chatProvider?.finalUsage, .error)
        }
        // 下面这一下清空 provider 的块；从这里起读到的块才是这一次的
        if provider.type == .anthropic { anthropicBlocksSerial = requestSerial }
        if provider.type == .openaiCompatible { openAIReasoningSerial = requestSerial }
        chatProvider.sendStreaming(
            messages: messages,
            model: model.modelId,
            systemPrompt: systemPrompt,
            apiKey: apiKey,
            baseURL: provider.baseURL,
            extraHeaders: mergedHeaders,
            samplingParams: samplingParams,
            imageMap: imageMap,
            tools: tools,
            toolTurns: toolTurns,
            ordered: ordered,
            onToken: onToken,
            onComplete: { [weak self, weak chatProvider] text, usage in
                self?.lastReplyHitOutputLimit = chatProvider?.hitOutputLimit ?? false
                finished(text, usage)
            },
            onError: adaptiveFailed,
            onToolCalls: forwardedToolCalls
        )
    }

    /// chatgptOAuth：拿 token，若快过期/已过期则刷新 + 写回 ProviderManager。返回干净的 access_token。
    static func ensureFreshAccessToken(
        _ token: OAuthTokenSet,
        credentialId: String,
        providerManager: ProviderManager
    ) async throws -> String {
        if !token.isExpired() { return token.accessToken }
        let fresh = try await ChatGPTOAuthExchange.refresh(refreshToken: token.refreshToken)
        await MainActor.run { providerManager.setOAuthToken(fresh, for: credentialId) }
        return fresh.accessToken
    }

    /// 非流式调用 — 用于 memory agent 等后台任务。images 给图片转述（M7）。
    func sendNonStreaming(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        providerManager: ProviderManager,
        images: [PendingChatAttachment] = []
    ) async throws -> (String, TokenUsage?) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure {
            // 严格测量角色：非流式（摘要 / 转写 / 记忆 / 标题等）一律拒绝 + 记录 + 停轮（§3.1）
            PerfGuardrails.tripOutbound("router.nonStreaming", model.credentialId)
            throw NSError(domain: PerfGuardrails.trapErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "[PERF] 严格测量角色拒绝外发"])
        }
        #endif
        guard let provider = providerManager.provider(for: model) else {
            throw NSError(domain: "ProviderRouter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: FixJump.missingProviderMessage(model.credentialId)])
        }

        // 后台任务不跑本机模型（plan-小芽-v3 D1：会和聊天抢 GPU；等 app 保活做了再放开）
        if provider.type == .localMLX {
            throw NSError(domain: "ProviderRouter", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "本机模型只在聊天里用，后台任务不跑"])
        }

        // chatgptOAuth：先解 token + 必要时刷新
        let apiKey: String
        if provider.type == .chatgptOAuth {
            let raw = providerManager.apiKey(for: provider.id) ?? ""
            guard let token = OAuthTokenSet.fromKeychainString(raw) else {
                throw NSError(domain: "ProviderRouter", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "ChatGPT 账号未登录"])
            }
            apiKey = try await Self.ensureFreshAccessToken(token, credentialId: provider.id, providerManager: providerManager)
        } else if provider.type == .ccBridge {
            apiKey = providerManager.apiKey(for: provider.id) ?? ""
        } else {
            guard let key = providerManager.apiKey(for: provider.id) else {
                throw NSError(domain: "ProviderRouter", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: FixJump.noKeyMessage(provider.name)])
            }
            apiKey = key
        }

        let chatProvider: BaseChatProvider
        switch provider.type {
        case .openaiCompatible:
            chatProvider = OpenAICompatibleProvider() // 独立实例，避免干扰流式
        case .anthropic:
            chatProvider = AnthropicProvider()
        case .ccBridge:
            chatProvider = CCBridgeProvider() // 独立实例（内部用 shared WS singleton）
        case .chatgptOAuth:
            chatProvider = ChatGPTOAuthProvider()
        case .localMLX:
            throw NSError(domain: "ProviderRouter", code: -4, userInfo: [NSLocalizedDescriptionKey: "本机模型只在聊天里用，后台任务不跑"])
        case .unsupported:
            // 不认识的卡类型：抛错，绝不降级成某个默认 provider（那会把 key 发到错误端点）
            throw NSError(domain: "ProviderRouter", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: FixJump.unsupportedCardMessage(provider.unknownTypeRaw)])
        }

        let started = Date()
        let usageContext = self.usageContext
        do {
            let result = try await chatProvider.sendNonStreaming(
                messages: messages,
                model: model.modelId,
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                baseURL: provider.baseURL,
                extraHeaders: provider.extraHeaders,
                images: images
            )
            var row = UsageRecord(provider: provider, modelId: model.modelId, usage: result.1,
                                  started: started, ended: Date(), status: .ok, context: usageContext, requestSent: true)
            let estimatedCost = BudgetCalculator.estimateCost(provider: provider, modelId: model.modelId,
                messages: messages, systemPrompt: systemPrompt,
                maxOutputTokens: OutputTokenCap.budgetExpected,
                estimator: HeuristicEstimator())
            row.requestId = UUID().uuidString
            row.keyIdentity = BillingKeyIdentity.hash(apiKey, host: URL(string: provider.baseURL)?.host ?? "")
            row.budgetChargeUSD = row.budgetCost(estimatedCost: chatProvider.requestEstimatedCost ?? estimatedCost)
            ledger.append(row)
            let charge = row.budgetChargeUSD ?? 0
            await MainActor.run { GlobalBudgetStore.shared.commitSpend(charge) }
            if APIUsageParser.isOpenRouter(provider.baseURL), row.responseId != nil, row.costSource != .reported {
                let original = row
                Task {
                    if let correction = await OpenRouterCostRecovery().recover(original, apiKey: apiKey, ledger: self.ledger) {
                        await MainActor.run { UsageCostSettlement.shared.apply(correction, original: original) }
                    }
                }
            }
            var usage = result.1 ?? TokenUsage(inputTokens: 0, outputTokens: 0, completeness: .missing)
            usage.ledgerCostUSD = row.costUSD
            usage.ledgerCostRecorded = true
            usage.ledgerSpendRecorded = true
            usage.ledgerRecord = row
            return (result.0, usage)
        } catch {
            var row = UsageRecord(provider: provider, modelId: model.modelId, usage: nil,
                                  started: started, ended: Date(), status: .error, context: usageContext,
                                  requestSent: chatProvider.requestWasSent)
            row.requestId = UUID().uuidString
            row.keyIdentity = BillingKeyIdentity.hash(apiKey, host: URL(string: provider.baseURL)?.host ?? "")
            row.budgetChargeUSD = row.budgetCost(estimatedCost: chatProvider.requestEstimatedCost ?? 0)
            ledger.append(row)
            let charge = row.budgetChargeUSD ?? 0
            await MainActor.run { GlobalBudgetStore.shared.commitSpend(charge) }
            throw error
        }
    }

    /// #094 §3.7：自愈不了的 400 / 422 说人话。值不对 / 预填 / 推理档某档不收 → 「人话。原文：…」；
    /// 401 / 403 / 404 前面补一句人话（plan-api-draft-and-fix-jump §3.3）；有 HTTP 状态码的失败一律带（host · 模型 · HTTP n）尾巴
    /// ——「去改」按钮靠它认 401 / 404；重试那次又学到了新的 → 再说一声下次不发
    static func failureMessage(_ message: String, status: Int, host: String, modelId: String, cap: Int?,
                               sent: ParamErrorClassifier.SentShape, errorBody: String, providerType: ProviderType,
                               learnedNow: ParamCompat.Learned, kind: ChatErrorClassifier.Kind = .other, retried: Int = 0) -> String {
        var text = OutputTokenCap.annotateLimitError(message, cap: cap)
        var explained = false
        if ParamErrorClassifier.isParamRejection(status: status), providerType == .openaiCompatible || providerType == .anthropic {
            explained = true
            switch ParamErrorClassifier.classify(status: status, body: errorBody, sent: sent, host: host) {
            case .explain(let plain):
                text = plain + "。原文：" + text
            case .thinkingBlocksRejected:
                text = "当轮回传的思考块没被接受（多半是中转改了请求）。原文：" + text
            case .fix(let fixes) where fixes.contains(.require(ParamCompat.Group.reasoningReplay)):
                text = "这个接口要求把模型上一步的思考原样传回去，但这一轮没拿到可以回传的思考（可能被中转去掉了）。原文：" + text
            case .fix(let fixes) where fixes.contains(.fitThinkingBudget):
                text = FixJump.thinkingBudgetMessage(sentThinking: sent.sendsAnyThinking) + "。原文：" + text
            case .unknown, .fix:
                explained = false
            }
        }
        let plain = ChatErrorClassifier.plainReason(kind, retried: retried, modelId: modelId)
            .map { kind == .quota && ChatErrorClassifier.isPrepaidQuota(.init(status: status, body: errorBody)) ? $0 + FixJump.prepaidQuotaNote : $0 }
        switch status {
        case 401, 403:
            // 分组无权 / 403 余额不足（中转，R2 / R5）不是 key 填错
            if kind == .groupDenied || (status == 403 && kind == .quota), let plain {
                text = plain + "。原文：" + text
            } else {
                text = FixJump.badKeyPhrase + "。原文：" + text
            }
        case 404: text = FixJump.badURLPhrase + "。原文：" + text
        default:
            if !explained, let plain { text = plain + "。原文：" + text }
        }
        if status > 0, !text.contains("HTTP \(status)）") {
            text += FixJump.statusTail(host: host, modelId: modelId, status: status)
        }
        if learnedNow != ParamCompat.Learned() { text += "\n（\(FixJump.learnedPrefix)\(learnedNow.summary)，下次自动照办）" }
        return text
    }

    /// #094：组 body 前统一剥一次不收的参数（抄 oh-my-pi withSupportedSamplingParams）。实发和预览走同一个函数 → 预览 = 实发。
    /// 只管 OpenAI 兼容 / Anthropic 两类；ChatGPT 登录 / 本机 / CC 原样
    static func adaptedSampling(_ s: SamplingParams?, provider: APICredential, modelId: String) -> SamplingParams? {
        guard let s, provider.type == .openaiCompatible || provider.type == .anthropic else { return s }
        return ParamCompat.resolve(providerType: provider.type, baseURL: provider.baseURL, modelId: modelId,
                                   reasoningEffort: s.reasoningEffort).supported(s)
    }

    /// 上下文检查器用：返回**实际会发出去**的请求 body，复用各 provider 的 buildRequestBody。
    /// 与发送链路共用同一构造函数，杜绝预览和实发分叉。ccBridge 不支持（只发最后一条）→ 返回 nil。
    static func previewRequestBody(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        providerManager: ProviderManager,
        samplingParams: SamplingParams?,
        tools: [[String: Any]]? = nil,
        ordered: [PromptMessage]? = nil   // ④b：给了就和实发一样按有序序列构造（OpenAI 兼容 / Anthropic）
    ) -> [String: Any]? {
        previewRequest(model: model, messages: messages, systemPrompt: systemPrompt, providerManager: providerManager,
                       samplingParams: samplingParams, tools: tools, ordered: ordered).body
    }

    /// 同 previewRequestBody，另交出这次预览 resolve 的 compat，给检查器「实发」说明共用（不跨请求缓存）
    static func previewRequest(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        providerManager: ProviderManager,
        samplingParams: SamplingParams?,
        tools: [[String: Any]]? = nil,
        ordered: [PromptMessage]? = nil
    ) -> (body: [String: Any]?, compat: ResolvedCompat?) {
        guard let provider = providerManager.provider(for: model) else { return (nil, nil) }
        let samplingParams = adaptedSampling(samplingParams.map { OutputTokenCap.resolved($0, modelId: model.modelId) },
                                             provider: provider, modelId: model.modelId)
        switch provider.type {
        case .openaiCompatible:
            let compat = ResolvedCompat.resolve(providerType: .openaiCompatible, baseURL: provider.baseURL,
                                                modelId: model.modelId, sampling: samplingParams)
            if let ordered {
                return (OpenAICompatibleProvider.buildRequestBody(
                    ordered: ordered, model: model.modelId, samplingParams: samplingParams,
                    tools: tools, compat: compat
                ), compat)
            }
            return (OpenAICompatibleProvider.buildRequestBody(
                messages: messages, model: model.modelId,
                systemPrompt: systemPrompt, samplingParams: samplingParams,
                tools: tools, compat: compat
            ), compat)
        case .anthropic:
            // 与实发同口径：拉黑的中转不挂 cache_control；不认 1 小时的按 5 分钟
            let allowCache = !AnthropicProvider.cacheBlacklistContains(provider.baseURL)
            let samplingParams = AnthropicProvider.samplingForHost(samplingParams, baseURL: provider.baseURL)
            let compat = ResolvedCompat.resolve(providerType: .anthropic, baseURL: provider.baseURL,
                                                modelId: model.modelId, sampling: samplingParams)
            if let ordered {
                return (AnthropicProvider.buildRequestBody(
                    ordered: ordered, model: model.modelId, samplingParams: samplingParams, tools: tools,
                    allowCacheControl: allowCache, compat: compat), compat)
            }
            return (AnthropicProvider.buildRequestBody(
                messages: messages, model: model.modelId,
                systemPrompt: systemPrompt, samplingParams: samplingParams,
                tools: tools, allowCacheControl: allowCache, compat: compat
            ), compat)
        case .ccBridge, .localMLX:
            return (nil, nil)
        case .unsupported:
            return (nil, nil)   // 不支持的卡类型：预览也不构造 body（绝不降级到某个默认 provider）
        case .chatgptOAuth:
            return (ChatGPTOAuthProvider.buildRequestBody(
                messages: messages, model: model.modelId,
                systemPrompt: systemPrompt, samplingParams: samplingParams,
                tools: tools, toolTurns: []
            ), nil)
        }
    }

    /// 检查器「实发」说明（④b）：这个 provider 把非前缀 system 怎么发。nil = 没有非前缀 system（与旧形态一致）。
    /// compat = 同一次预览 previewRequest 交出的那份
    static func previewSystemPlacementNote(model: ProviderModel, ordered: [PromptMessage], providerManager: ProviderManager,
                                           compat: ResolvedCompat?) -> String? {
        guard let provider = providerManager.provider(for: model) else { return nil }
        let inPlace = PromptWire.plan(ordered, strategy: .interleaved).inPlaceSystemCount
        guard inPlace > 0 else { return nil }
        switch provider.type {
        case .openaiCompatible where compat?.interleavedSystem == true:
            return "实发：\(inPlace) 段 system 在历史中原位发（此接口支持序列内 system）"
        case .openaiCompatible, .anthropic:
            return "实发：\(inPlace) 段 system 不在开头，此接口不确认支持序列内 system → 原位降级为 \(PromptWire.systemNoteOpen) user 块，相邻同角色已合并（语义弱于 system）"
        case .chatgptOAuth, .localMLX:
            return "实发：此接口维持旧行为，\(inPlace) 段非开头 system 仍并进开头 system"
        case .ccBridge, .unsupported:
            return nil
        }
    }

    func cancel() {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.active, Self.perfMacRequested {
            MainActor.assumeIsolated { if PerfHarnessMac.streamEnabled { perfMacStream?.stop() } }
        }
        #endif
        pendingRetry?.cancel()
        pendingRetry = nil
        retryGeneration += 1
        pendingUsageOnCancel?()
        pendingUsageOnCancel = nil
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { perfScripted?.stop() }   // R7-14：测量角色下脚本流与真 provider 一样被取消（停 ticker、不再回调）
        #endif
        openAIProvider.cancel()
        anthropicProvider.cancel()
        ccBridgeProvider.cancel()
        chatgptOAuthProvider.cancel()
        localProvider.cancel()
    }
}

// MARK: - CC Bridge Provider

final class CCBridgeProvider: BaseChatProvider {
    // 收口即发（plan-跨对话排队）后 CC 不再走流式管线：发送在
    // ConversationViewModel.sendCCFireAndForget（WS 直发），回复走 proactive 落地。
    // 这里留防御 stub：任何残留/未来误路由进来立即报错，不注册 handler 干等。
    override func sendStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        samplingParams: SamplingParams? = nil,
        imageMap: [String: [PendingChatAttachment]] = [:],
        tools: [[String: Any]]? = nil,
        toolTurns: [ToolTurn] = [],
        ordered: [PromptMessage]? = nil,   // 有序序列（④b）不用：CC 不走 body
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void,
        onToolCalls: (([ToolCallBlock]) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            self.isStreaming = false
            self.error = "CC 对话已改直发（收口即发），不走流式管线"
            onError("CC 对话已改直发（收口即发），不走流式管线")
        }
    }

    override func sendNonStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        images: [PendingChatAttachment] = []
    ) async throws -> (String, TokenUsage?) {
        throw NSError(domain: "CCBridge", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "CC Bridge 不支持非流式调用"])
    }

    override func cancel() {
        // CC 在 tmux 里处理，无法从外部中断；本地只清流式状态
        isStreaming = false
    }
}
