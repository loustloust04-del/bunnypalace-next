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
    var isStreaming = false
    var streamingContent = ""
    var error: String?

    internal var currentTask: URLSessionDataTask?
    internal var urlSession: URLSession?
    internal var buffer = ""
    internal var errorBody = ""
    internal var httpStatusCode: Int = 0
    internal var receivedDone = false
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
        self.buffer = ""
        self.errorBody = ""
        self.httpStatusCode = 0
        self.receivedDone = false
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
    }

    internal func startRequest(_ request: URLRequest) {
        let generation = pacedGeneration
        requestPending = true
        if let decision = BudgetPreflight.immediateDecision(request, state: budgetState) {
            finishBudgetPreflight(decision, request: request)
            return
        }
        budgetPreflightTask = Task { @MainActor [self] in
            defer {
                if self.pacedGeneration == generation { self.budgetPreflightTask = nil }
            }
            let decision = await BudgetPreflight.decision(request, counter: self.tokenCounter, state: self.budgetState)
            guard !Task.isCancelled, self.pacedGeneration == generation else { return }
            self.finishBudgetPreflight(decision, request: request)
        }
    }

    private func finishBudgetPreflight(_ decision: BudgetPreflight.Decision, request: URLRequest) {
        requestPending = false
        requestEstimatedCost = decision.estimatedCost
        guard decision.allowed else {
            isStreaming = false
            onError?("保险闸：本次预计花费超过剩余额度")
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
        var msg = "API 错误 (\(httpStatusCode))"
        if let data = errorBody.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let detail = err["message"] as? String {
                msg = Self.readableError(type: err["type"] as? String, message: detail)
            } else if let err = obj["error"] as? String {
                msg = err
            }
        }
        return msg
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
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return readableError(type: err["type"] as? String, message: msg)
            } else if let err = obj["error"] as? String {
                return err
            }
        }
        return "API 错误 (\(statusCode))"
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
            if rawBody.isEmpty, let head = String(data: data.prefix(16), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               head.hasPrefix("data:") || head.hasPrefix("event:") || head.hasPrefix(":") {
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
            let msg = error.localizedDescription
            self.error = msg
            onError?(msg)
            return
        }

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
            if streamingContent.isEmpty {
                let msg = "未收到回复"
                self.error = msg
                onError?(msg)
            } else {
                onComplete?(streamingContent, finalUsage)
            }
        }
    }


    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if isStale(session) { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse {
            httpStatusCode = http.statusCode
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            isEventStream = ct.contains("text/event-stream")
        }
        completionHandler(.allow)
    }

    /// Override in subclass for provider-specific SSE parsing
    @objc func processData(_ data: Data) {
        // default: no-op
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

        usageBaseURL = baseURL
        let orCC = Self.wantsORCacheControl(baseURL: baseURL, model: model, samplingParams: samplingParams)
        usageCacheWriteIs1h = orCC
        let tokenKey = Self.maxTokensKey(baseURL: baseURL)
        let dropTemp = Self.dropsSamplingTemperature(baseURL: baseURL, model: model, reasoningEffort: samplingParams?.reasoningEffort ?? "auto")
        let reasoningRouteHere = ReasoningEffort.route(providerType: .openaiCompatible, credentialId: "", baseURL: baseURL, modelId: model)
        let body: [String: Any]
        if let ordered {
            body = Self.buildRequestBody(
                ordered: ordered, model: model, samplingParams: samplingParams,
                tools: tools, toolTurns: toolTurns,
                orCacheControl: orCC,
                orProviderOrder: Self.orPreferredProviderOrder(baseURL: baseURL, model: model, samplingParams: samplingParams),
                interleavedSystem: Self.supportsInterleavedSystem(baseURL: baseURL, model: model),
                maxTokensKey: tokenKey, dropTemperature: dropTemp, reasoningRoute: reasoningRouteHere
            )
        } else {
            body = Self.buildRequestBody(
                messages: messages, model: model, systemPrompt: systemPrompt,
                samplingParams: samplingParams, imageMap: imageMap,
                tools: tools, toolTurns: toolTurns,
                orCacheControl: orCC,
                orProviderOrder: Self.orPreferredProviderOrder(baseURL: baseURL, model: model, samplingParams: samplingParams),
                maxTokensKey: tokenKey, dropTemperature: dropTemp, reasoningRoute: reasoningRouteHere
            )
        }
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        startRequest(request)
    }

    /// OpenAI 官方 Chat Completions：推理模型只认 max_completion_tokens（max_tokens 已弃用、对 o / GPT-5 系 400）
    static func maxTokensKey(baseURL: String) -> String {
        URL(string: baseURL.lowercased())?.host == "api.openai.com" ? "max_completion_tokens" : "max_tokens"
    }

    /// OpenAI 官方推理模型只收默认 temperature（发 0.7 回 400 "Only the default (1) value is supported"）；
    /// 官方 latest-model 指南：推理档不是 none 时去掉 temperature / top_p。依据见 plan-output-token-cap 1-10。
    static func dropsSamplingTemperature(baseURL: String, model: String, reasoningEffort: String) -> Bool {
        guard URL(string: baseURL.lowercased())?.host == "api.openai.com" else { return false }
        if reasoningEffort != "auto", reasoningEffort != "none" { return true }   // 推理档 none = 不推理，照模型本身判断
        if let accepts = ModelCatalog.shared.model(for: model)?.temperature { return !accepts }
        let m = model.lowercased()
        if m.first == "o", m.dropFirst().first?.isNumber == true { return true }
        if m.hasPrefix("gpt-"), let major = Int(m.dropFirst(4).prefix(while: \.isNumber)), major >= 5 { return true }
        return false
    }

    /// OpenRouter 上的 Claude 系模型：顶层 cache_control = OR 的自动缓存模式（断点自动 rolling，
    /// 只路由 Anthropic 直连上游）。其他模型（DeepSeek/OpenAI/Gemini）上游自动缓存，不需要它。
    static func wantsORCacheControl(baseURL: String, model: String, samplingParams: SamplingParams?) -> Bool {
        guard samplingParams?.cacheFriendly == true else { return false }
        let m = model.lowercased()
        return baseURL.lowercased().contains("openrouter")
            && (m.hasPrefix("anthropic/") || m.contains("claude"))
    }

    /// cacheFriendly 时给 OR 指定一方提供商优先（缓存支持最好且最便宜的上游）。只映射已知系列。
    static func orPreferredProviderOrder(baseURL: String, model: String, samplingParams: SamplingParams?) -> [String]? {
        guard samplingParams?.cacheFriendly == true, baseURL.lowercased().contains("openrouter") else { return nil }
        if model.lowercased().hasPrefix("deepseek/") { return ["deepseek"] }
        return nil
    }

    /// 序列内（非首位）system 的能力标记（④b）：只对确认支持的开，其余一律走降级（<system_note> user 块）。
    /// - api.openai.com：Chat Completions 的 messages 对 system（新模型视作 developer）没有位置限制（官方文档）。
    /// - OpenRouter 的 openai/*：上游就是 OpenAI，OR 以 OpenAI Chat 格式为规范透传 messages（待核：没有实打验证）。
    /// - DeepSeek / 硅基流动 / Kimi / 通义 / 智谱 / 豆包 / Groq / xAI / Gemini 兼容层 / Ollama / 各中转：不确定 → false。
    static func supportsInterleavedSystem(baseURL: String, model: String) -> Bool {
        let url = baseURL.lowercased()
        if URL(string: url)?.host == "api.openai.com" { return true }
        return url.contains("openrouter.ai") && model.lowercased().hasPrefix("openai/")
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
        orCacheControl: Bool = false,
        orProviderOrder: [String]? = nil,
        interleavedSystem: Bool,
        maxTokensKey: String = "max_tokens",
        dropTemperature: Bool = false,
        reasoningRoute: ReasoningEffort.Route = .chatCompletions
    ) -> [String: Any] {
        // #089 P0-b：没下发客户端工具时历史退回纯文字 + 〔系统记录〕
        let toolNames = ToolReplay.clientToolNames(tools)
        let plan = PromptWire.plan(ToolReplay.wireOrdered(ordered, toolNames: toolNames),
                                   strategy: interleavedSystem ? .interleaved : .degradeToUserNote)
        return buildRequestBody(
            messages: [], model: model, systemPrompt: plan.systemPrompt,
            samplingParams: samplingParams, tools: tools, toolTurns: toolTurns,
            orCacheControl: orCacheControl, orProviderOrder: orProviderOrder,
            wireMessages: openAIWire(plan.messages, toolNames: toolNames),
            maxTokensKey: maxTokensKey, dropTemperature: dropTemperature, reasoningRoute: reasoningRoute
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
        orCacheControl: Bool = false,
        orProviderOrder: [String]? = nil,
        wireMessages: [[String: Any]]? = nil,   // ④b：有序序列排好的、system 前缀之后的消息（给了就不用 messages / imageMap）
        maxTokensKey: String = "max_tokens",
        dropTemperature: Bool = false,
        reasoningRoute: ReasoningEffort.Route = .chatCompletions
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
            apiMessages.append([
                "role": "assistant", "content": "",
                "tool_calls": turn.calls.map { [
                    "id": $0.id, "type": "function",
                    "function": ["name": $0.name, "arguments": $0.argumentsJSON]
                ] }
            ])
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
        if let p = samplingParams {
            if !dropTemperature {
                if p.temperature != 1.0 { body["temperature"] = p.temperature }
                if p.topP != 1.0 { body["top_p"] = p.topP }
            }
            body[maxTokensKey] = p.maxTokens
            if p.frequencyPenalty != 0 { body["frequency_penalty"] = p.frequencyPenalty }
            if p.presencePenalty != 0 { body["presence_penalty"] = p.presencePenalty }
            if p.seed >= 0 { body["seed"] = p.seed }
            ReasoningEffort.applyChatCompletions(route: reasoningRoute, effort: p.reasoningEffort, to: &body)   // OpenRouter 用 reasoning.effort
            body["stream"] = p.streaming
        }
        if orCacheControl {
            // OR 上 Anthropic 系：显式 per-block 挂标（BP=system 块 + 末 assistant 块，动态段留断点外）。
            // 不用顶层自动模式——它把断点挂到最后一个可缓存块，而[动态上下文]伪段在末尾每轮变，
            // 断点前缀永远对不上 → 每轮写 1.25× 读 0（OR log 实测坐实，比不开还贵 25%）
            // ttl 1h：5min 在"隔几分钟回一条"的真实聊天节奏下存不住（实测 8 分钟空档全量重写 1.25×）。
            // 1h 写 2× 但 rolling 增量写很小，隔断回来稳赚（教程同款取舍）
            let mark: [String: Any] = ["type": "ephemeral", "ttl": "1h"]
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
        if let order = orProviderOrder {
            // OR 缓存路由：默认负载均衡常落到不缓存/贵 3 倍的转售商（实测 GMICloud 读写全 0），
            // 显式指定一方提供商优先（DeepSeek 官方缓存读 ≈1% 原价），不可用再 fallback
            body["provider"] = ["order": order, "allow_fallbacks": true]
        }
        return body
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let budgetDecision = await BudgetPreflight.decision(request)
        requestEstimatedCost = budgetDecision.estimatedCost
        guard budgetDecision.allowed else {
            throw NSError(domain: "BudgetGate", code: -1, userInfo: [NSLocalizedDescriptionKey: "保险闸：本次预计花费超过剩余额度"])
        }
        requestWasSent = true
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            throw NSError(domain: "ChatService", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.extractError(from: data, statusCode: statusCode)])
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

        return NonStreamResult(text: text, toolCalls: calls.markingLastTruncated(hit), usage: usage, hitOutputLimit: hit)
    }

    override func processData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        if httpStatusCode != 0 && httpStatusCode != 200 {
            errorBody += text
            return
        }

        buffer += text

        while let lineEnd = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<lineEnd])
            buffer = String(buffer[buffer.index(after: lineEnd)...])

            if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" {
                    receivedDone = true
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
            if let reasoning = (u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int {
                accumulatedReasoningTokens = reasoning
            }
            gotUsage = true
        }

        let choices = obj["choices"] as? [[String: Any]]
        if choices?.first?["finish_reason"] as? String == "length" { hitOutputLimit = true }
        guard let delta = choices?.first?["delta"] as? [String: Any] else {
            if let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String {
                enqueueCallback { [self] in
                    isStreaming = false
                    error = message
                    onError?(message)
                }
            }
            return
        }

        if let content = delta["content"] as? String {
            enqueueCallback { [self] in
                streamingContent += content
                onToken?(content)
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

    // MARK: cache_control 黑名单（有些中转对 cache_control 报 4xx，记下来之后降级无标透传）

    private static let cacheBlacklistKey = "anthropicCacheHostBlacklist"

    static func cacheBlacklistContains(_ baseURL: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: cacheBlacklistKey) ?? []).contains(baseURL)
    }

    static func addToCacheBlacklist(_ baseURL: String) {
        var list = UserDefaults.standard.stringArray(forKey: cacheBlacklistKey) ?? []
        guard !list.contains(baseURL) else { return }
        list.append(baseURL)
        UserDefaults.standard.set(list, forKey: cacheBlacklistKey)
    }

    /// sticky 路由 id：固定不变，防中转负载均衡把缓存写/读打到不同后端（只写不读 = 命中永远 0）
    static var cacheUserId: String {
        let key = "anthropicCacheUserId"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = "memorypalace-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    override func onHTTPError() {
        // 挂了标且 4xx 且错误信息提到 cache → 该 host 不吃 cache_control，拉黑降级（下次请求无标）
        guard (400...499).contains(httpStatusCode), let host = cacheMarkedHost,
              errorBody.lowercased().contains("cache") else { return }
        Self.addToCacheBlacklist(host)
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
        enqueueCallback { [self] in MainActor.assumeIsolated { streamingWebSources = [] } }

        let allowCache = !Self.cacheBlacklistContains(baseURL)
        let body: [String: Any]
        if let ordered {
            body = Self.buildRequestBody(
                ordered: ordered, model: model, samplingParams: samplingParams,
                tools: tools, toolTurns: toolTurns, allowCacheControl: allowCache
            )
        } else {
            body = Self.buildRequestBody(
                messages: messages, model: model, systemPrompt: systemPrompt,
                samplingParams: samplingParams, imageMap: imageMap,
                tools: tools, toolTurns: toolTurns, allowCacheControl: allowCache
            )
        }
        #if DEBUG
        RequestBodyTap.emit(body)
        #endif
        cacheMarkedHost = (samplingParams?.cacheFriendly == true && allowCache) ? baseURL : nil

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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
        allowCacheControl: Bool = true
    ) -> [String: Any] {
        // #089 P0-b：没下发客户端工具时 API 不收工具块 → 历史退回纯文字 + 〔系统记录〕
        let toolNames = ToolReplay.clientToolNames(tools)
        let plan = PromptWire.plan(ToolReplay.wireOrdered(ordered, toolNames: toolNames), strategy: .degradeToUserNote)
        return buildRequestBody(
            messages: [], model: model, systemPrompt: plan.systemPrompt,
            samplingParams: samplingParams, tools: tools, toolTurns: toolTurns,
            allowCacheControl: allowCacheControl,
            wireMessages: anthropicWire(plan.messages, toolNames: toolNames)
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
        wireMessages: [[String: Any]]? = nil   // ④b：有序序列排好的消息（给了就不用 messages / imageMap）
    ) -> [String: Any] {
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
                "content": turn.calls.map { call -> [String: Any] in
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                    return ["type": "tool_use", "id": call.id, "name": call.name, "input": input]
                }
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
        let limits = ReasoningEffort.anthropicThinking(
            route: ReasoningEffort.needsAdaptive(model) ? .anthropicAdaptive : .anthropicBudget,
            effort: samplingParams?.reasoningEffort ?? "auto",
            visible: samplingParams?.maxTokens ?? OutputTokenCap.fallback,
            limit: OutputTokenCap.modelLimit(model)
        )
        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": limits.maxTokens,
            "stream": true,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            WebSearchProbe.log("[anthropic-body] tools=\(WebSearchProbe.summarizeTools(tools))")
        } else {
            WebSearchProbe.log("[anthropic-body] tools=<nil-or-empty>")
        }
        if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        if let p = samplingParams {
            // Opus 4.7+ / 5 系：temperature / top_p / top_k 一律 400「deprecated for this model」（10-11 实测，开不开思考都拒）
            let samplingDeprecated = ReasoningEffort.needsAdaptive(model)
            if let thinking = limits.thinking {
                body["thinking"] = thinking
                if let config = limits.outputConfig { body["output_config"] = config }
                if !samplingDeprecated, p.topP >= 0.95 && p.topP < 1.0 { body["top_p"] = p.topP }
            } else if !samplingDeprecated {
                if p.temperature != 1.0 { body["temperature"] = p.temperature }
                if p.topP != 1.0 { body["top_p"] = p.topP }
                if p.topK > 0 { body["top_k"] = p.topK }
            }
            body["stream"] = p.streaming
        }

        // ── prompt cache 显式挂标（cacheFriendly 开关，缓存读 0.1×）──
        if samplingParams?.cacheFriendly == true && allowCacheControl {
            // BP1：整段 system。易变内容已被组装层下沉进 messages 的[动态上下文]段，system 全段逐轮稳定
            if let sys = body["system"] as? String, !sys.isEmpty {
                body["system"] = [["type": "text", "text": sys, "cache_control": ["type": "ephemeral"]] as [String: Any]]
            }
            // BP4 rolling：最后一条 assistant 消息末块挂标，把之前全部历史纳进缓存（长会话命中主力）。
            // 不挂倒数第二条 user——cacheFriendly 下那是每轮都变的[动态上下文]伪段，挂上等于没挂
            if let idx = apiMessages.lastIndex(where: { ($0["role"] as? String) == "assistant" }) {
                var msg = apiMessages[idx]
                if let text = msg["content"] as? String {
                    msg["content"] = [["type": "text", "text": text, "cache_control": ["type": "ephemeral"]] as [String: Any]]
                } else if var blocks = msg["content"] as? [[String: Any]], var last = blocks.last {
                    last["cache_control"] = ["type": "ephemeral"]
                    blocks[blocks.count - 1] = last
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let budgetDecision = await BudgetPreflight.decision(request)
        requestEstimatedCost = budgetDecision.estimatedCost
        guard budgetDecision.allowed else {
            throw NSError(domain: "BudgetGate", code: -1, userInfo: [NSLocalizedDescriptionKey: "保险闸：本次预计花费超过剩余额度"])
        }
        requestWasSent = true
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            throw NSError(domain: "ChatService", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.extractError(from: data, statusCode: statusCode)])
        }

        // 和聊天的非流式同一个解析：拼全部 text 块（以前只取第一块，第一块是 thinking 就报「无法解析响应」）
        let parsed = try parseNonStreamBody(data)
        return (parsed.text, parsed.usage)
    }

    /// 非流式整包：content[] 的 text / tool_use / web_search_tool_result + usage（含 cache 两字段）+ stop_reason；
    /// thinking 块跳过（流式路径也不处理 thinking_delta，保持一致）
    override func parseNonStreamBody(_ data: Data) throws -> NonStreamResult {
        guard let obj = Self.nonStreamObject(data),
              let blocks = obj["content"] as? [[String: Any]] else {
            throw Self.unparsableBody(data)
        }
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
        guard let text = String(data: data, encoding: .utf8) else { return }

        if httpStatusCode != 0 && httpStatusCode != 200 {
            errorBody += text
            return
        }

        buffer += text

        while let lineEnd = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<lineEnd])
            buffer = String(buffer[buffer.index(after: lineEnd)...])

            if line.hasPrefix("event: ") {
                currentEventType = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                handleAnthropicEvent(type: currentEventType, data: payload)
            }
        }
    }

    private func captureBillingDimensions(_ usage: [String: Any]) {
        if let input = usage["input_tokens"] as? Int { accumulatedInputTokens = input }
        if let read = usage["cache_read_input_tokens"] as? Int { accumulatedCacheReadTokens = read }
        if let write = usage["cache_creation_input_tokens"] as? Int { accumulatedCacheWriteTokens = write }
        let buckets = usage["cache_creation"] as? [String: Any]
        let five = buckets?["ephemeral_5m_input_tokens"] as? Int
        let hour = buckets?["ephemeral_1h_input_tokens"] as? Int
        if let hour { accumulatedCacheWrite1hTokens = hour }
        if five != nil || hour != nil {
            accumulatedCacheWriteTokens = usage["cache_creation_input_tokens"] as? Int ?? (five ?? 0) + (hour ?? 0)
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
                if let text = delta["text"] as? String {
                    enqueueCallback { [self] in
                        streamingContent += text
                        onToken?(text)
                    }
                } else if let partial = delta["partial_json"] as? String {
                    let idx = obj["index"] as? Int ?? 0
                    if var entry = toolUseAccum[idx] { entry.json += partial; toolUseAccum[idx] = entry }
                }
            }

        case "message_delta":
            // { "type": "message_delta", "delta": { "stop_reason": ... }, "usage": { "output_tokens": N } }
            if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                stopReason = sr
                hitOutputLimit = sr == "max_tokens"
            }
            if let u = obj["usage"] as? [String: Any] {
                captureBillingDimensions(u)
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

    private var openAIProvider = OpenAICompatibleProvider()
    private var anthropicProvider = AnthropicProvider()
    private var ccBridgeProvider = CCBridgeProvider()
    private var chatgptOAuthProvider = ChatGPTOAuthProvider()
    private var localProvider = LocalChatProvider()
    #if (DEBUG || PERF_BENCH) && os(iOS)
    /// 纵切 6 脚本流（perf P0 §6.6）：只在严格测量角色下创建（let 不进观察）；对象本身可观察，进 isStreaming 的 OR 链
    let perfScripted: PerfScriptedStream? = PerfHarness.strictMeasure ? PerfScriptedStream() : nil
    #endif

    var isStreaming: Bool {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure, perfScripted?.isStreaming == true { return true }
        #endif
        return openAIProvider.isStreaming || anthropicProvider.isStreaming || ccBridgeProvider.isStreaming || chatgptOAuthProvider.isStreaming
            || localProvider.isStreaming
    }

    /// 当前 anthropic 流累积的 web search sources（server tool 解出来的）。
    /// finalize 时 CV 取这里写 MessageNode.webSourcesData。
    @MainActor
    var currentWebSources: [WebSearchSource] {
        anthropicProvider.streamingWebSources
    }

    var streamingContent: String {
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
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void,
        onToolCalls: (([ToolCallBlock], TokenUsage?) -> Void)? = nil
    ) {
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
        let samplingParams = samplingParams.map { OutputTokenCap.resolved($0, modelId: model.modelId) }
        lastUsageRecord = nil
        lastReplyHitOutputLimit = false
        lastRequestedMaxTokens = samplingParams?.maxTokens
        guard let provider = providerManager.provider(for: model) else {
            onError("找不到提供商: \(model.credentialId)")
            return
        }

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
                    row.budgetChargeUSD = row.budgetCost(estimatedCost: wireEstimate ?? estimatedCost)
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
                onError("未设置 \(provider.name) 的 API Key")
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
            onError("这张 API 卡的类型当前版本不支持（\(provider.unknownTypeRaw ?? "未知")），请更新 app 或换一张卡")
            return
        }

        BreadcrumbLog.shared.add("🌐", "请求 \(provider.name)/\(model.modelId) · \(messages.count)条 · 工具\(tools?.count ?? 0) · sys \(systemPrompt?.count ?? 0)字")
        let mergedHeaders = provider.extraHeaders.merging(additionalHeaders) { _, new in new }
        let forwardedToolCalls = toolRoundFinished.map { callback in
            { [weak chatProvider] calls in
                callback(calls, chatProvider?.finalUsage)
            }
        }
        // 上限越界（N1）：上游嫌输出上限太大 → 降到 8192 同参数重试一次；重试那次已是 8192，不会再进来
        let capAwareFailed: (String) -> Void = { [weak self, weak chatProvider] message in
            if let self, let sp = samplingParams, sp.maxTokens > OutputTokenCap.retryCap,
               chatProvider?.streamingContent.isEmpty == true, OutputTokenCap.mentionsOutputLimit(message) {
                _ = record(nil, .error)
                BreadcrumbLog.shared.add("✂️", "输出上限 \(sp.maxTokens) 被拒，降到 \(OutputTokenCap.retryCap) 重试")
                var retry = sp
                retry.maxTokens = OutputTokenCap.retryCap
                self.sendStreaming(
                    model: model, messages: messages, systemPrompt: systemPrompt, providerManager: providerManager,
                    samplingParams: retry, imageMap: imageMap, additionalHeaders: additionalHeaders,
                    tools: tools, toolTurns: toolTurns, ordered: ordered,
                    onToken: onToken, onComplete: onComplete, onError: onError, onToolCalls: onToolCalls
                )
                return
            }
            requestFailed(OutputTokenCap.annotateLimitError(message, cap: samplingParams?.maxTokens))
        }
        MainActor.assumeIsolated { settlement.freezeKey(apiKey, host: URL(string: provider.baseURL)?.host ?? "") }
        chatProvider.onRequestSent = sentRequestRecorder(model: model, round: toolTurns.count, secrets: [apiKey])
        pendingUsageOnCancel = { [weak chatProvider] in
            _ = record(chatProvider?.finalUsage, .error)
        }
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
            onError: capAwareFailed,
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
                          userInfo: [NSLocalizedDescriptionKey: "找不到提供商: \(model.credentialId)"])
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
                              userInfo: [NSLocalizedDescriptionKey: "未设置 \(provider.name) 的 API Key"])
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
                          userInfo: [NSLocalizedDescriptionKey: "这张 API 卡的类型当前版本不支持（\(provider.unknownTypeRaw ?? "未知")），请更新 app 或换一张卡"])
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
        let samplingParams = samplingParams.map { OutputTokenCap.resolved($0, modelId: model.modelId) }
        guard let provider = providerManager.provider(for: model) else { return nil }
        switch provider.type {
        case .openaiCompatible:
            let tokenKey = OpenAICompatibleProvider.maxTokensKey(baseURL: provider.baseURL)
            let dropTemp = OpenAICompatibleProvider.dropsSamplingTemperature(
                baseURL: provider.baseURL, model: model.modelId, reasoningEffort: samplingParams?.reasoningEffort ?? "auto")
            let reasoningRouteHere = ReasoningEffort.route(providerType: .openaiCompatible, credentialId: "",
                                                           baseURL: provider.baseURL, modelId: model.modelId)
            if let ordered {
                return OpenAICompatibleProvider.buildRequestBody(
                    ordered: ordered, model: model.modelId, samplingParams: samplingParams,
                    tools: tools,
                    orCacheControl: OpenAICompatibleProvider.wantsORCacheControl(
                        baseURL: provider.baseURL, model: model.modelId, samplingParams: samplingParams),
                    orProviderOrder: OpenAICompatibleProvider.orPreferredProviderOrder(
                        baseURL: provider.baseURL, model: model.modelId, samplingParams: samplingParams),
                    interleavedSystem: OpenAICompatibleProvider.supportsInterleavedSystem(
                        baseURL: provider.baseURL, model: model.modelId),
                    maxTokensKey: tokenKey, dropTemperature: dropTemp, reasoningRoute: reasoningRouteHere
                )
            }
            return OpenAICompatibleProvider.buildRequestBody(
                messages: messages, model: model.modelId,
                systemPrompt: systemPrompt, samplingParams: samplingParams,
                tools: tools,
                orCacheControl: OpenAICompatibleProvider.wantsORCacheControl(
                    baseURL: provider.baseURL, model: model.modelId, samplingParams: samplingParams),
                orProviderOrder: OpenAICompatibleProvider.orPreferredProviderOrder(
                    baseURL: provider.baseURL, model: model.modelId, samplingParams: samplingParams),
                maxTokensKey: tokenKey, dropTemperature: dropTemp, reasoningRoute: reasoningRouteHere
            )
        case .anthropic:
            // 与实发同口径：拉黑的中转不挂 cache_control
            let allowCache = !AnthropicProvider.cacheBlacklistContains(provider.baseURL)
            if let ordered {
                return AnthropicProvider.buildRequestBody(
                    ordered: ordered, model: model.modelId, samplingParams: samplingParams, tools: tools,
                    allowCacheControl: allowCache)
            }
            return AnthropicProvider.buildRequestBody(
                messages: messages, model: model.modelId,
                systemPrompt: systemPrompt, samplingParams: samplingParams,
                tools: tools, allowCacheControl: allowCache
            )
        case .ccBridge, .localMLX:
            return nil
        case .unsupported:
            return nil   // 不支持的卡类型：预览也不构造 body（绝不降级到某个默认 provider）
        case .chatgptOAuth:
            return ChatGPTOAuthProvider.buildRequestBody(
                messages: messages, model: model.modelId,
                systemPrompt: systemPrompt, samplingParams: samplingParams,
                tools: tools, toolTurns: []
            )
        }
    }

    /// 检查器「实发」说明（④b）：这个 provider 把非前缀 system 怎么发。nil = 没有非前缀 system（与旧形态一致）
    static func previewSystemPlacementNote(model: ProviderModel, ordered: [PromptMessage], providerManager: ProviderManager) -> String? {
        guard let provider = providerManager.provider(for: model) else { return nil }
        let inPlace = PromptWire.plan(ordered, strategy: .interleaved).inPlaceSystemCount
        guard inPlace > 0 else { return nil }
        switch provider.type {
        case .openaiCompatible where OpenAICompatibleProvider.supportsInterleavedSystem(baseURL: provider.baseURL, model: model.modelId):
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
