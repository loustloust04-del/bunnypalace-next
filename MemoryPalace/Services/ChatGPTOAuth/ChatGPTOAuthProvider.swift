import Foundation

// MARK: - ChatGPT OAuth Provider (Codex Responses API)
//
// 调 chatgpt.com/backend-api/codex/responses。请求/响应格式跟 OpenAI Chat Completions
// 完全不一样（Responses API）。本类负责：
//   - 把 internal `messages` + systemPrompt 映射成 Responses API 的 input + instructions
//   - 把 internal tools（OpenAI Chat Completions 格式）转 Responses API tools 格式
//   - SSE 解析（output_text.delta / function_call / completed 等）
//   - JWT 抠 chatgpt_account_id 当 header
//
// 调用前提：apiKey 参数是已经检查过 / 刷新过的裸 access_token，不是 OAuth JSON。
// Token 刷新放在 ProviderRouter（async path）里做，省得这里再嵌一层 async。

final class ChatGPTOAuthProvider: BaseChatProvider {

    // 流式累积的 function_call（按 item_id）
    private var fnCallAccum: [String: (callId: String, name: String, args: String)] = [:]

    // MARK: - Streaming

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
        ordered: [PromptMessage]? = nil,   // ④b 有序序列不用：Responses 接口暂维持旧行为（system 前缀）
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void,
        onToolCalls: (([ToolCallBlock]) -> Void)? = nil
    ) {
        resetState(onToken: onToken, onComplete: onComplete, onError: onError)
        self.onToolCalls = onToolCalls
        fnCallAccum = [:]

        let body = Self.buildRequestBody(
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            samplingParams: samplingParams,
            tools: tools,
            toolTurns: toolTurns
        )
        #if DEBUG
        RequestBodyTap.emit(body)
        #endif

        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + ChatGPTOAuthConfig.responsesPath) else {
            onError("Codex 端点 URL 无效: \(trimmedBase)")
            isStreaming = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in Self.codexHeaders(accessToken: apiKey).merging(extraHeaders, uniquingKeysWith: { _, new in new }) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        startRequest(request)
    }

    // MARK: - Non-streaming (后台 agent)

    override func sendNonStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        images: [PendingChatAttachment] = []
    ) async throws -> (String, TokenUsage?) {
        let body = Self.buildRequestBody(
            messages: messages, model: model, systemPrompt: systemPrompt,
            samplingParams: nil, tools: nil, toolTurns: [],
            streaming: false
        )
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + ChatGPTOAuthConfig.responsesPath) else {
            throw NSError(domain: "ChatGPTOAuth", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Codex 端点 URL 无效"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        for (k, v) in Self.codexHeaders(accessToken: apiKey).merging(extraHeaders, uniquingKeysWith: { _, new in new }) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")   // 非流式覆盖 SSE Accept
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ChatGPTOAuth", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Codex 请求失败 (\(code))：\(bodyText.prefix(200))"])
        }
        // 非流式返回是 JSON `{output: [{content:[{type:"output_text", text:"..."}]}]}`
        let text = Self.extractTextFromNonStreamingResponse(data)
        return (text, nil)
    }

    // MARK: - SSE 解析（BaseChatProvider hook）

    override func processData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        buffer += chunk

        // SSE 按 \n\n 切 event。流式可能跨包，留尾部到下次。
        while let range = buffer.range(of: "\n\n") {
            let rawEvent = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            handleEvent(rawEvent)
        }
    }

    override func onHTTPError() {
        // codex 401 = token 失效，提示重新登录
        // 上游会自动 handleErrorBody，这里不抢
    }

    private func handleEvent(_ event: String) {
        // 每个 event 可能多行：event: ... / data: ... / id: ...
        // 我们只关心 `data: {json}` 那一行
        var jsonLine = ""
        for line in event.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("data:") {
                jsonLine = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !jsonLine.isEmpty, jsonLine != "[DONE]" else {
            if jsonLine == "[DONE]" {
                receivedDone = true
                enqueueCallback {
                    self.isStreaming = false
                    self.onComplete?(self.streamingContent, self.finalUsage)
                }
            }
            return
        }
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        // 主要 event：output_text.delta（增量文本）
        if type.hasSuffix("output_text.delta") || type.contains(".output_text.delta") {
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                streamingContent += delta
                enqueueCallback {
                    self.onToken?(delta)
                }
            }
            return
        }

        // 工具调用增量（function_call）：累积到 fnCallAccum，response.completed 时一次性 emit
        if type.contains(".function_call.") || type.contains(".tool_call.") {
            collectFunctionCallEvent(obj)
            return
        }

        // 完成（response.completed / response.done）：发 tool_calls + usage
        if type == "response.completed" || type == "response.done" || type.hasSuffix(".completed") {
            extractUsage(from: obj)
            emitCollectedToolCalls()
            // [DONE] 通常会跟着来；这里不主动 onComplete，等 [DONE] 或 didCompleteWithError
            return
        }

        // 错误事件
        if type.contains(".error") {
            if let msg = (obj["error"] as? [String: Any])?["message"] as? String {
                enqueueCallback { self.onError?(msg) }
            }
        }
    }

    private func collectFunctionCallEvent(_ obj: [String: Any]) {
        // Responses API function_call event 大致结构：
        //   {type: "response.function_call.arguments.delta", item_id: "fc_xxx", delta: "..."}
        //   {type: "response.function_call.added", item: {id, call_id, name, ...}}
        let itemId = (obj["item_id"] as? String) ?? ((obj["item"] as? [String: Any])?["id"] as? String) ?? ""
        guard !itemId.isEmpty else { return }

        if let item = obj["item"] as? [String: Any] {
            let callId = item["call_id"] as? String ?? itemId
            let name = item["name"] as? String ?? ""
            var existing = fnCallAccum[itemId] ?? (callId: callId, name: name, args: "")
            if !callId.isEmpty { existing.callId = callId }
            if !name.isEmpty { existing.name = name }
            fnCallAccum[itemId] = existing
        }
        if let delta = obj["delta"] as? String {
            var existing = fnCallAccum[itemId] ?? (callId: itemId, name: "", args: "")
            existing.args += delta
            fnCallAccum[itemId] = existing
        }
    }

    private func emitCollectedToolCalls() {
        guard !fnCallAccum.isEmpty, let cb = onToolCalls else { return }
        let blocks: [ToolCallBlock] = fnCallAccum.values.compactMap { entry in
            guard !entry.name.isEmpty else { return nil }
            return ToolCallBlock(id: entry.callId, name: entry.name, argumentsJSON: entry.args)
        }
        if !blocks.isEmpty {
            enqueueCallback { cb(blocks) }
        }
        fnCallAccum = [:]
    }

    private func extractUsage(from obj: [String: Any]) {
        // response.completed 的 obj 里可能有 response.usage
        let usage: [String: Any]?
        if let resp = obj["response"] as? [String: Any], let u = resp["usage"] as? [String: Any] {
            usage = u
        } else if let u = obj["usage"] as? [String: Any] {
            usage = u
        } else {
            usage = nil
        }
        guard let usage else { return }
        if usage["input_tokens"] is Int, usage["output_tokens"] is Int {
            finalEventUsageState = .complete
        } else {
            finalEventUsageState = usage["input_tokens"] is Int || usage["output_tokens"] is Int ? .snapshot : .missing
        }
        // codex 用 input_tokens / output_tokens 命名
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        // cache 字段可能在 input_tokens_details 里（OpenAI Responses 标准）
        var cacheRead: Int? = nil
        if let det = usage["input_tokens_details"] as? [String: Any] {
            cacheRead = det["cached_tokens"] as? Int
        }
        accumulatedInputTokens = input
        accumulatedOutputTokens = output
        accumulatedCacheReadTokens = cacheRead
        accumulatedReasoningTokens = (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        gotUsage = true
    }

    // MARK: - Request body 构造

    /// 把 internal messages + tools 映射成 Codex Responses API payload。
    /// - history 多条 → input: [{role, content:[{type:"input_text", text:...}]}]
    /// - systemPrompt → instructions
    /// - tools (OpenAI Chat Completions style: {type:"function", function:{name, description, parameters}}) →
    ///   Responses API tools: {type:"function", name, description, parameters}（顶层平铺）
    static func buildRequestBody(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        samplingParams: SamplingParams?,
        tools: [[String: Any]]?,
        toolTurns: [ToolTurn],
        streaming: Bool = true
    ) -> [String: Any] {
        var input: [[String: Any]] = []
        for msg in messages {
            input.append([
                "role": msg.role,
                "content": [
                    [
                        "type": msg.role == "assistant" ? "output_text" : "input_text",
                        "text": msg.content,
                    ]
                ]
            ])
        }

        // toolTurns：把历史里的 assistant tool_call + tool result 转成 Responses input 项
        // function_call item: {type:"function_call", call_id, name, arguments}
        // function_call_output item: {type:"function_call_output", call_id, output}
        for turn in toolTurns {
            for call in turn.calls {
                input.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.name,
                    "arguments": call.argumentsJSON,
                ])
            }
            for result in turn.results {
                input.append([
                    "type": "function_call_output",
                    "call_id": result.toolUseId,
                    "output": result.text,
                ])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": streaming,
            "store": false,
        ]
        if let sys = systemPrompt, !sys.isEmpty {
            body["instructions"] = sys
        }

        // Tools mapping：OpenAI Chat Completions {type:"function", function:{...}} →
        // Responses API {type:"function", name, description, parameters}
        if let tools, !tools.isEmpty {
            let mapped: [[String: Any]] = tools.compactMap { t in
                guard let fn = t["function"] as? [String: Any] else {
                    // 已经是 Responses 格式
                    return t
                }
                var out: [String: Any] = ["type": "function"]
                if let name = fn["name"] { out["name"] = name }
                if let desc = fn["description"] { out["description"] = desc }
                if let params = fn["parameters"] { out["parameters"] = params }
                return out
            }
            if !mapped.isEmpty {
                body["tools"] = mapped
            }
        }

        // reasoning effort（GPT-5 / o3 等 reasoning 模型）
        if let p = samplingParams, p.reasoningEffort != "auto" {
            body["reasoning"] = ["effort": p.reasoningEffort]
        }
        // codex 不接受 chat completions 风格的 temperature / top_p（Responses API 也有自己的，
        // 但为安全本轮先不透传 sampling，等到实测哪些参数被接受再加）

        return body
    }

    // MARK: - Headers

    static func codexHeaders(accessToken: String) -> [String: String] {
        var h: [String: String] = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
            "User-Agent": ChatGPTOAuthConfig.userAgent,
            "originator": ChatGPTOAuthConfig.originator,
        ]
        let accountId = OAuthTokenSet.extractChatGPTAccountId(from: accessToken)
        if !accountId.isEmpty {
            h["ChatGPT-Account-ID"] = accountId
        }
        return h
    }

    // MARK: - Non-streaming response 解析

    static func extractTextFromNonStreamingResponse(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        // 直接 output_text 字段（部分 SDK 给）
        if let s = obj["output_text"] as? String { return s }
        // 嵌套 output 数组
        if let output = obj["output"] as? [[String: Any]] {
            var parts: [String] = []
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let t = part["type"] as? String,
                       (t == "output_text" || t == "text"),
                       let s = part["text"] as? String {
                        parts.append(s)
                    }
                }
            }
            if !parts.isEmpty { return parts.joined() }
        }
        return ""
    }
}
