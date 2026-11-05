import XCTest
@testable import 记忆花园

/// 中转站兼容（plan-relay-compat R1–R10）。样本是 2026-10-16 三家 new-api 中转的原始字节（`Fixtures/relay/`，id 已固定化），不发真请求
final class RelayCompatTests: XCTestCase {
    static var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/relay")
    }

    static func raw(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    struct Meta {
        var status: Int
        var requestBody: [String: Any]
    }

    static func meta(_ name: String) throws -> Meta {
        let base = (name as NSString).deletingPathExtension
        let data = try Data(contentsOf: dir.appendingPathComponent(base + ".meta.json"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Meta(status: try XCTUnwrap(obj["status"] as? Int), requestBody: try XCTUnwrap(obj["request_body"] as? [String: Any]))
    }

    private func classify(_ name: String) throws -> ChatErrorClassifier.Kind {
        ChatErrorClassifier.classify(.init(status: try Self.meta(name).status, body: try Self.raw(name)))
    }

    private func failure(_ name: String, kind: ChatErrorClassifier.Kind, sent: [String: Any]? = nil) throws -> String {
        let meta = try Self.meta(name)
        return ProviderRouter.failureMessage("原文", status: meta.status, host: "relay.example.com",
                                             modelId: meta.requestBody["model"] as? String ?? "", cap: nil,
                                             sent: ParamErrorClassifier.SentShape(body: sent ?? meta.requestBody),
                                             errorBody: try Self.raw(name), providerType: .openaiCompatible, learnedNow: .init(), kind: kind)
    }

    // MARK: R1 无渠道

    func testNoChannelIsUnavailableModelNotRetried() throws {
        for name in ["ekanw-err_nonexistent_model.json", "msuicode-stream_claude-sonnet-4-6.sse"] {
            let kind = try classify(name)
            XCTAssertEqual(kind, .unavailableModel, name)
            XCTAssertNil(ChatErrorClassifier.retryWait(kind, retry: 0), "不白重试：\(name)")
        }
        let channel = #"{"error":{"code":"get_channel_failed","message":"获取渠道失败","type":"new_api_error"}}"#
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 500, body: channel)), .unavailableModel)

        let text = try failure("msuicode-stream_claude-sonnet-4-6.sse", kind: .unavailableModel)
        XCTAssertTrue(text.hasPrefix("这个中转的当前分组里没有可用的「claude-sonnet-4-6」渠道，换个模型或去中转后台看分组"), text)
        XCTAssertEqual(FixJump.kind(for: text), .unavailableModel)
        XCTAssertEqual(FixJump.Kind.unavailableModel.buttonTitle, "去改")
    }

    /// 审查 #6：结构化的过载 / 限流 / 坏 key 证据压过「No available channel」「分组」文字兜底（构造响应）
    func testStructuredReasonBeatsRelayWording() {
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"No available channel, please try again later"}}"#
        let kind = ChatErrorClassifier.classify(.init(status: 503, body: overloaded))
        XCTAssertEqual(kind, .transient, "过载照常重试")
        XCTAssertNotNil(ChatErrorClassifier.retryWait(kind, retry: 0))
        let throttled = #"{"error":{"type":"rate_limit_error","message":"No available channel for model x under group default"}}"#
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 429, body: throttled)), .rateLimited(retryAfter: nil))

        let badKey = #"{"type":"error","error":{"type":"authentication_error","message":"Invalid API key: unauthorized access to group default"}}"#
        let badKeyKind = ChatErrorClassifier.classify(.init(status: 401, body: badKey))
        XCTAssertEqual(badKeyKind, .other, "不是分组无权")
        let text = ProviderRouter.failureMessage("原文", status: 401, host: "relay.example.com", modelId: "m", cap: nil,
                                                 sent: .init(), errorBody: badKey, providerType: .anthropic, learnedNow: .init(),
                                                 kind: badKeyKind)
        XCTAssertTrue(text.hasPrefix(FixJump.badKeyPhrase), text)
        XCTAssertEqual(FixJump.kind(for: text), .badKey, "留着改 key 按钮")
        XCTAssertNotEqual(ChatErrorClassifier.classify(.init(status: 403, body: #"{"error":{"type":"authentication_error","message":"无权访问 vip 分组"}}"#)),
                          .groupDenied, "有坏 key 证据不认分组")
        XCTAssertNotEqual(ChatErrorClassifier.classify(.init(status: 400, body: #"{"error":{"message":"group vip is not allowed to use this model"}}"#)),
                          .groupDenied, "不是权限拒绝（403 / permission / 无权）不认分组")
    }

    // MARK: R2 预扣型余额不足

    func testPrepaidQuotaSays403IsQuotaNotKey() throws {
        let name = "ekanw-err_huge_max_tokens.json"
        XCTAssertEqual(try classify(name), .quota)
        XCTAssertTrue(ChatErrorClassifier.isPrepaidQuota(.init(status: 403, body: try Self.raw(name))))
        XCTAssertFalse(ChatErrorClassifier.isPrepaidQuota(.init(status: 429, body: try Self.raw(name))), "只认 402 / 403")
        XCTAssertFalse(ChatErrorClassifier.isPrepaidQuota(.init(status: 403, body: #"{"error":{"message":"余额不足"}}"#)), "要 insufficient_user_quota")

        let text = try failure(name, kind: .quota)
        XCTAssertTrue(text.hasPrefix(FixJump.quotaPhrase + FixJump.prepaidQuotaNote), text)
        XCTAssertFalse(text.contains(FixJump.badKeyPhrase), text)
        XCTAssertEqual(FixJump.kind(for: text), .quota)
        XCTAssertTrue(ChatErrorClassifier.isExplicitRejection(.init(status: 403, body: try Self.raw(name))), "预扣拒收 = 没生成，预算扣 0")
    }

    /// 审查 #4：按实发上限（含思考余量）算，重发后实发 ≤ 8192、可见上限不升、budget < max_tokens
    func testPrepaidRetryUsesSentCap() {
        func s(_ visible: Int, _ effort: String) -> SamplingParams {
            var p = SamplingParams()
            p.maxTokens = visible
            p.maxTokensAuto = false
            p.reasoningEffort = effort
            return p
        }
        XCTAssertNil(OutputTokenCap.prepaidRetry(s(4096, "auto"), sentMaxTokens: 4096), "实发不大：不重发")
        XCTAssertEqual(OutputTokenCap.prepaidRetry(s(20_000, "auto"), sentMaxTokens: 20_000)?.maxTokens, 8192)

        let high = OutputTokenCap.prepaidRetry(s(4096, "high"), sentMaxTokens: 14_096)
        XCTAssertEqual(high?.reasoningEffort, "low", "high 的余量占不下：压到 low")
        XCTAssertEqual(high?.maxTokens, 4096, "可见上限不升")
        let wire = ReasoningEffort.anthropicThinking(route: .anthropicBudget, effort: high?.reasoningEffort ?? "", visible: high?.maxTokens ?? 0, limit: nil)
        XCTAssertEqual(wire.maxTokens, 5120)
        XCTAssertEqual(wire.thinking?["budget_tokens"] as? Int, 1024)

        let medium = OutputTokenCap.prepaidRetry(s(20_000, "medium"), sentMaxTokens: 24_096)
        XCTAssertEqual(medium?.reasoningEffort, "medium")
        XCTAssertEqual(medium?.maxTokens, 4096, "4096 + 4096 = 8192")

        let byDefault = OutputTokenCap.prepaidRetry(s(4096, "auto"), sentMaxTokens: 4096 + 10_000)
        XCTAssertEqual(byDefault?.reasoningEffort, "low", "默认档的余量不知道多大：明确压到 low")
        XCTAssertEqual(byDefault?.maxTokens, 4096)
    }

    // MARK: R3 报错文字被打码

    func testMaskedThinkingPathStillRecognized() throws {
        let name = "msuicode-anth_thinking_claude-opus-5-5.sse"
        let meta = try Self.meta(name)
        let body = try Self.raw(name)
        XCTAssertTrue(body.contains("***.***.enabled"))
        let enabled = ParamErrorClassifier.SentShape(body: meta.requestBody)
        XCTAssertEqual(enabled.thinkingType, "enabled")
        XCTAssertEqual(ParamErrorClassifier.classify(status: meta.status, body: body, sent: enabled, host: "x"), .fix([.thinkingFormat("adaptive")]))

        // 同一条打码报错反过来拒 adaptive：rejectsAdaptiveType 要点名 thinking.type，打码后只有还原了才认得
        let swapped = body.replacingOccurrences(of: "***.***.enabled", with: "@@").replacingOccurrences(of: "***.***.adaptive", with: "***.***.enabled")
            .replacingOccurrences(of: "@@", with: "***.***.adaptive")
        var adaptiveBody = meta.requestBody
        adaptiveBody["thinking"] = ["type": "adaptive"]
        let adaptive = ParamErrorClassifier.SentShape(body: adaptiveBody)
        XCTAssertFalse(ParamErrorClassifier.rejectsAdaptiveType(swapped.lowercased()), "打码原文直接认不出")
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: swapped, sent: adaptive, host: "x"), .fix([.thinkingFormat("budget")]))
    }

    func testUnmaskOnlyWhenUnique() {
        let thinking = ParamErrorClassifier.SentShape(body: ["thinking": ["type": "enabled", "budget_tokens": 2048]])
        let replay = ParamErrorClassifier.SentShape(body: ["messages": [["role": "assistant", "content": "", "reasoning_content": "想"]]])
        XCTAssertEqual(ParamErrorClassifier.unmasked(#""***.***.enabled" is not supported"#, sent: thinking), #""thinking.type.enabled" is not supported"#)
        XCTAssertEqual(ParamErrorClassifier.unmasked("***.type: input should be 'enabled'", sent: thinking), "thinking.type: input should be 'enabled'")
        XCTAssertEqual(ParamErrorClassifier.unmasked("***.***.reasoning_content: extra inputs", sent: replay), "messages.0.reasoning_content: extra inputs")
        XCTAssertEqual(ParamErrorClassifier.unmasked("***.3.reasoning: extra inputs", sent: replay), "messages.3.reasoning: extra inputs", "露出来的下标照留")
        XCTAssertNil(ParamErrorClassifier.unmask("see https://***.com/***/***").unresolved, "网址里的打码不管")
        XCTAssertEqual(ParamErrorClassifier.unmasked("thinking.display: x"), "thinking.display: x")

        // 认不准的不还原：段数对不上 / 根没发 / 同形状不止一条 / 前面还有一截路径
        XCTAssertEqual(ParamErrorClassifier.unmask("***.reasoning: extra inputs", sent: replay).unresolved, "***.reasoning", "两段对不上 messages.N.reasoning")
        XCTAssertEqual(ParamErrorClassifier.unmask("***.***.enabled is not supported", sent: replay).unresolved, "***.***.enabled", "没发 thinking")
        let both = ParamErrorClassifier.SentShape(body: ["thinking": ["type": "adaptive"], "tool_choice": ["type": "auto"]])
        XCTAssertEqual(ParamErrorClassifier.unmask("***.type: input should be 'enabled'", sent: both).unresolved, "***.type", "thinking.type / tool_choice.type 都可能")
        XCTAssertEqual(ParamErrorClassifier.unmask("body.***.***.enabled: x", sent: thinking).unresolved, "***.***.enabled")

        let sent = ParamErrorClassifier.SentShape(body: ["model": "m", "messages": [["role": "assistant", "content": "", "reasoning": "想"]]])
        let masked = #"{"error":{"message":"***.***.reasoning: Extra inputs are not permitted","type":"<nil>"}}"#
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: masked, sent: sent, host: "x"), .fix([.drop(ParamCompat.Group.reasoningReplay)]))
    }

    /// 审查 #3 反例：顶层 reasoning + 历史思考回传都发了，报错「***.reasoning」认不准是哪个 → 只说人话、不学
    func testAmbiguousMaskedPathExplainsWithoutLearning() {
        let sent = ParamErrorClassifier.SentShape(body: ["model": "m", "reasoning": ["effort": "high"],
                                                         "messages": [["role": "assistant", "content": "", "reasoning": "想"]]])
        let masked = #"{"error":{"message":"***.reasoning: Extra inputs are not permitted","type":"<nil>"}}"#
        let verdict = ParamErrorClassifier.classify(status: 400, body: masked, sent: sent, host: "x")
        XCTAssertEqual(verdict, .explain(FixJump.maskedParamMessage("***.reasoning")), "不学（只有 .fix 才进学习表）")
        let text = ProviderRouter.failureMessage("原文", status: 400, host: "x", modelId: "m", cap: nil, sent: sent, errorBody: masked,
                                                 providerType: .openaiCompatible, learnedNow: .init())
        XCTAssertTrue(text.hasPrefix(FixJump.maskedParamMessage("***.reasoning")), text)

        // 结构化点了名：打码认不准也照改
        let structured = #"{"error":{"message":"***.reasoning: unsupported","param":"reasoning","code":"unsupported_parameter"}}"#
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: structured, sent: sent, host: "x"), .fix([.drop(ParamCompat.Group.reasoning)]))
    }

    // MARK: R4 思考预算比上限大

    func testThinkingBudgetErrorDoesNotLowerCap() throws {
        let name = "ekanw-stream_claude-opus-4-6-thinking-单间.sse"
        let meta = try Self.meta(name)
        let body = try Self.raw(name)
        XCTAssertTrue(ParamErrorClassifier.evidence(body).texts.contains { $0.contains("budget_tokens") }, "嵌套的上游 JSON 截断了也取得到文字")

        // 中转按模型名自己开的思考（我们没发预算 / 档）：不降上限、不重发，说人话
        let relayInjected = ParamErrorClassifier.SentShape(body: meta.requestBody)
        XCTAssertEqual(ParamErrorClassifier.classify(status: meta.status, body: body, sent: relayInjected, host: "x"),
                       .explain(FixJump.thinkingBudgetMessage(sentThinking: false)))
        // 发了预算：压预算，不是降上限
        var withBudget = meta.requestBody
        withBudget["thinking"] = ["type": "enabled", "budget_tokens": 10000]
        XCTAssertEqual(ParamErrorClassifier.classify(status: meta.status, body: body, sent: .init(body: withBudget), host: "x"), .fix([.fitThinkingBudget]))
        XCTAssertTrue(ParamErrorClassifier.learned(from: [.fitThinkingBudget]) == ParamCompat.Learned(), "不学")

        let message = "`max_tokens` must be greater than `thinking.budget_tokens`."
        XCTAssertFalse(OutputTokenCap.mentionsOutputLimit(message))
        XCTAssertEqual(OutputTokenCap.annotateLimitError(message, cap: 1024), message, "不提示把上限调小")
        let text = try failure(name, kind: .other)
        XCTAssertTrue(text.hasPrefix(FixJump.thinkingBudgetMessage(sentThinking: false)), text)
        XCTAssertTrue(text.contains("可能是中转"), "没发思考参数：只说可能，不下定论")
        XCTAssertFalse(text.contains("调小"), text)
        XCTAssertFalse(text.contains("1024"), "不承诺预算数")

        // 发了 thinking: adaptive 但没带档：不算「中转自开」，也没法压档
        var adaptive = meta.requestBody
        adaptive["thinking"] = ["type": "adaptive"]
        XCTAssertEqual(ParamErrorClassifier.classify(status: meta.status, body: body, sent: .init(body: adaptive), host: "x"),
                       .explain(FixJump.thinkingBudgetMessage(sentThinking: true)))
        XCTAssertFalse(FixJump.thinkingBudgetMessage(sentThinking: true).contains("中转"))
    }

    // MARK: R5 分组无权

    func testGroupDeniedIsNotBadKey() throws {
        let name = "treegpt-ns_kimi-k3.json"
        XCTAssertEqual(try classify(name), .groupDenied)
        XCTAssertNil(ChatErrorClassifier.retryWait(.groupDenied, retry: 0))
        let text = try failure(name, kind: .groupDenied)
        XCTAssertTrue(text.hasPrefix(FixJump.groupDeniedPhrase), text)
        XCTAssertFalse(text.contains(FixJump.badKeyPhrase), text)
        XCTAssertNil(FixJump.kind(for: text), "不跳去改 key")
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 403, body: #"{"error":{"message":"group vip is not allowed to use this model"}}"#)), .groupDenied)
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 401, body: #"{"error":{"message":"Invalid token"}}"#)), .other, "错 key 照旧")
        XCTAssertNotEqual(try classify("ekanw-err_nonexistent_model.json"), .groupDenied, "「under group default」是没渠道，不是无权")
    }

    // MARK: R6 Gemini 经中转藏在 total 里的思考

    func testHiddenReasoningFromTotal() throws {
        let streamed = try OpenAIFeed.run(try Self.raw("ekanw-stream_gemini-3.8-flash-high.sse"))
        XCTAssertEqual(streamed.content, "1 + 1 = 2")
        let usage = try XCTUnwrap(streamed.usage)
        XCTAssertEqual(usage.inputTokens, 5)
        XCTAssertEqual(usage.reasoningTokens, 71, "83 − 5 − 7")
        XCTAssertEqual(usage.outputTokens, 78, "思考并进输出计费")

        let whole = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try Self.raw("ekanw-ns_gemini-3.8-flash-high.json").utf8)) as? [String: Any])
        let ns = try XCTUnwrap(APIUsageParser.openAI(whole, baseURL: "https://ekanw.example/v1"))
        XCTAssertEqual(ns.outputTokens, 81, "非流式 total = prompt + completion：不加")
        XCTAssertEqual(ns.reasoningTokens, 0)

        let reported: [String: Any] = ["usage": ["prompt_tokens": 5, "completion_tokens": 80, "total_tokens": 100,
                                  "completion_tokens_details": ["reasoning_tokens": 70]]]
        XCTAssertEqual(APIUsageParser.openAI(reported, baseURL: "https://x.example/v1")?.outputTokens, 80, "报了思考数就不按差值")

        // 审查 #8：Gemini 原生分桶明说思考 0，不让对不上的 total 差值覆盖
        let native: [String: Any] = ["usage": ["prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 83],
                                     "usageMetadata": ["candidatesTokenCount": 7, "thoughtsTokenCount": 0]]
        let gemini = try XCTUnwrap(APIUsageParser.openAI(native, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"))
        XCTAssertEqual(gemini.outputTokens, 7)
        XCTAssertEqual(gemini.reasoningTokens, 0)
    }

    // MARK: R7 纯空白思考

    func testWhitespaceReasoningIsNotThinking() throws {
        let r = try OpenAIFeed.run(try Self.raw("msuicode-tool_claude-opus-5-5_T0.sse"))
        XCTAssertTrue(r.reasoning.isEmpty)
        XCTAssertNil(r.reasoning.field, "不占「原生思考」位")
        XCTAssertFalse(r.reasoning.hasNative)
        XCTAssertNil(r.reasoning.segment)
        XCTAssertEqual(r.toolCalls.map(\.name), ["get_time"])

        let real = try OpenAIFeed.run(try Self.raw("ekanw-tool_claude-thinking_T0.sse"))
        XCTAssertEqual(real.reasoning.field, "reasoning_content")
        XCTAssertTrue(real.reasoning.text.hasPrefix("The user is asking for the current time"), real.reasoning.text)

        var capture = ReasoningCapture()
        capture.absorbDelta(["reasoning_content": "\n"])
        XCTAssertNil(capture.field)
        capture.absorbDelta(["reasoning_content": "先"])
        capture.absorbDelta(["reasoning_content": " "])
        capture.absorbDelta(["reasoning_content": "想"])
        XCTAssertEqual(capture.text, "先 想", "开始之后的空白照拼")
    }

    // MARK: R8 中转注入的工具参数

    func testUndeclaredToolArgumentsDroppedForExecution() throws {
        for name in ["msuicode-tool_claude-opus-5-5_T0.sse", "ekanw-tool_claude-thinking_T0.sse"] {
            let call = try XCTUnwrap(try OpenAIFeed.run(try Self.raw(name)).toolCalls.first, name)
            let tools = try XCTUnwrap(try Self.meta(name).requestBody["tools"] as? [[String: Any]])
            let schema = try XCTUnwrap((tools.first?["function"] as? [String: Any])?["parameters"] as? [String: Any])
            XCTAssertTrue(call.argumentsJSON.contains("_call") || call.argumentsJSON.contains("reason"), call.argumentsJSON)
            XCTAssertEqual(ToolCallPreflight.droppingUndeclared(call.argumentsJSON, schema: schema), "{}", name)
        }
        let args = #"{"path":"a.md","_call":"x"}"#
        let fileSchema: [String: Any] = ["type": "object", "properties": ["path": ["type": "string"]]]
        XCTAssertEqual(ToolCallPreflight.droppingUndeclared(args, schema: fileSchema), #"{"path":"a.md"}"#)
        XCTAssertEqual(ToolCallPreflight.droppingUndeclared(args, schema: ["input_schema": fileSchema]), #"{"path":"a.md"}"#, "Anthropic 形状")
        var open = fileSchema
        open["additionalProperties"] = true
        XCTAssertEqual(ToolCallPreflight.droppingUndeclared(args, schema: open), args)
        XCTAssertEqual(ToolCallPreflight.droppingUndeclared(args, schema: nil), args)
        XCTAssertEqual(ToolCallPreflight.droppingUndeclared(args, schema: ["type": "object"]), args, "没有 properties 不过滤")
        let clean = #"{ "path" : "a.md" }"#
        XCTAssertEqual(ToolCallPreflight.droppingUndeclared(clean, schema: fileSchema), clean, "没多余键原样，不重排")
    }

    /// 审查 #2：tool_invoke 包着的 MCP 调用按真实工具的 schema 过滤内层参数
    func testToolInvokeInnerArgumentsFilteredByRealSchema() throws {
        let tool = MCPToolConfig(enabled: true, name: "web_fetch", description: "", params: [],
                                 schema: ["type": .string("object"), "properties": .object(["url": .object(["type": .string("string")])])])
        let inner: [String: Any] = ["url": "https://example.com", "_call": "relay"]
        let json = ConversationViewModel.invokeInnerJSON(inner, schema: tool.schemaAny())
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(args.keys), ["url"])
        XCTAssertTrue(ConversationViewModel.invokeInnerJSON(inner, schema: nil).contains("_call"), "查不到 schema 原样")
    }

    // MARK: R10 Anthropic message_start 占位 usage

    func testAnthropicPlaceholderUsageOverriddenByDelta() throws {
        let usage = try XCTUnwrap(AnthropicFeed.run(try Self.raw("ekanw-anth_xapikey_claude-opus-4-6-K.sse")))
        XCTAssertEqual(usage.inputTokens, 4169, "start 的 1 是占位")
        XCTAssertEqual(usage.outputTokens, 1)

        let zeroDelta = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":500,"output_tokens":1,"cache_read_input_tokens":300}}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let kept = try XCTUnwrap(AnthropicFeed.run(zeroDelta))
        XCTAssertEqual(kept.inputTokens, 500, "delta 的 0 不抹掉 start 的真值")
        XCTAssertEqual(kept.cacheReadTokens, 300)
        XCTAssertEqual(kept.outputTokens, 9)

        // 审查 #9：官方直连字段在就覆盖，终态的 0 是真值
        let official = try XCTUnwrap(AnthropicFeed.run(zeroDelta, baseURL: "https://api.anthropic.com/v1"))
        XCTAssertEqual(official.inputTokens, 0)
        XCTAssertEqual(official.cacheReadTokens, 0)
        XCTAssertEqual(official.outputTokens, 9)
    }
}

/// 把整段 SSE 喂给 provider（不发请求）
enum OpenAIFeed {
    struct Result {
        var content: String
        var usage: TokenUsage?
        var reasoning: ReasoningCapture
        var toolCalls: [ToolCallBlock]
    }

    static func run(_ sse: String) throws -> Result {
        let p = OpenAICompatibleProvider()
        var calls: [ToolCallBlock] = []
        p.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in })
        p.onToolCalls = { calls = $0 }
        p.processData(Data(sse.utf8))
        drainMain()
        return Result(content: p.streamingContent, usage: p.finalUsage, reasoning: p.reasoning, toolCalls: calls)
    }
}

enum AnthropicFeed {
    static func run(_ sse: String, baseURL: String = "") -> TokenUsage? {
        let p = AnthropicProvider()
        p.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { _ in })
        p.usageBaseURL = baseURL
        p.processData(Data(sse.utf8))
        drainMain()
        return p.finalUsage
    }
}

/// provider 的回调排在主队列上：排一个哨兵，转主 run loop 到它跑完
private func drainMain() {
    var drained = false
    DispatchQueue.main.async { drained = true }
    while !drained { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

/// 路由层：本机假服务器回中转原始字节，看重不重发、重发时改了什么
@MainActor
final class RelayCompatRouterTests: XCTestCase {
    typealias Server = OutputTokenCapTests.ScriptedHTTPServer
    typealias Response = Server.Response

    private var cleanups: [() -> Void] = []

    override func tearDown() async throws {
        cleanups.forEach { $0() }
        cleanups = []
    }

    private func relay(_ name: String, status: Int? = nil) throws -> Response {
        let meta = try RelayCompatTests.meta(name)
        let isStream = name.hasSuffix(".sse") && (status ?? meta.status) == 200
        return Response(status: status ?? meta.status, contentType: isStream ? "text/event-stream" : "application/json",
                         body: Data(try RelayCompatTests.raw(name).utf8))
    }

    private func fixture(_ server: Server, modelId: String, type: ProviderType = .openaiCompatible) -> (ProviderRouter, ProviderManager, ProviderModel) {
        let credentialId = "xctest-relay-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: modelId, name: "Relay Test")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "中转测试卡", emoji: "🔀", type: type,
                                       baseURL: server.baseURL, models: [model], toolsSupported: true))
        pm.setApiKey("test-key", for: credentialId)
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString).jsonl"))
        router.retryDelay = { _ in 0 }
        let baseURL = pm.provider(for: model)?.baseURL ?? server.baseURL
        cleanups.append {
            pm.removeCredential(id: credentialId)
            ParamAdaptStore.shared.remove(key: ParamAdaptStore.key(providerType: type, baseURL: baseURL, modelId: modelId))
            server.stop()
        }
        return (router, pm, model)
    }

    private enum Outcome: Equatable { case ok(String), error(String) }

    private func send(_ router: ProviderRouter, _ pm: ProviderManager, _ model: ProviderModel, sampling: SamplingParams) async -> (Outcome, [String]) {
        let done = expectation(description: "done")
        done.assertForOverFulfill = false
        var outcome = Outcome.error("没回调")
        var notices: [String] = []
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "1+1=?")], systemPrompt: nil,
            providerManager: pm, samplingParams: sampling,
            onToken: { _ in }, onComplete: { t, _ in outcome = .ok(t); done.fulfill() },
            onError: { outcome = .error($0); done.fulfill() },
            onRetry: { notices.append($0) }
        )
        await fulfillment(of: [done], timeout: 5)
        return (outcome, notices)
    }

    private func sampling(maxTokens: Int, effort: String = "auto") -> SamplingParams {
        var s = SamplingParams()
        s.maxTokens = maxTokens
        s.maxTokensAuto = false
        s.reasoningEffort = effort
        return s
    }

    private func body(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNoChannelSendsOnce() async throws {
        let response = try relay("msuicode-stream_claude-sonnet-4-6.sse")
        let server = try Server(responding: { _, _ in response })
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-sonnet-4-6")

        let (outcome, notices) = await send(router, pm, model, sampling: sampling(maxTokens: 1024))
        guard case .error(let message) = outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 1, "不白重试")
        XCTAssertTrue(notices.isEmpty)
        XCTAssertTrue(message.hasPrefix(FixJump.unavailableModelMessage("claude-sonnet-4-6")), message)
        XCTAssertEqual(router.ledger.load().map(\.budgetChargeUSD), [0])
    }

    func testPrepaidQuotaLowersCapOnceThenSucceeds() async throws {
        let rejected = try relay("ekanw-err_huge_max_tokens.json")
        let server = try Server(responding: { index, _ in
            index == 0 ? rejected : Response(status: 200, contentType: "text/event-stream", body: OutputTokenCapTests.okText)
        })
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "按量K-claude-opus-4-6")

        let (outcome, _) = await send(router, pm, model, sampling: sampling(maxTokens: 20_000))
        XCTAssertEqual(outcome, .ok("ok"))
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertEqual(try body(server.requestBodies[0])["max_tokens"] as? Int, 20_000)
        XCTAssertEqual(try body(server.requestBodies[1])["max_tokens"] as? Int, OutputTokenCap.retryCap)
        let baseURL = try XCTUnwrap(pm.provider(for: model)?.baseURL)
        XCTAssertNil(ParamAdaptStore.shared.entry(providerType: .openaiCompatible, baseURL: baseURL, modelId: model.modelId), "不学")
    }

    func testPrepaidQuotaStillFailingSaysQuota() async throws {
        let rejected = try relay("ekanw-err_huge_max_tokens.json")
        let server = try Server(responding: { _, _ in rejected })
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "按量K-claude-opus-4-6")

        let (outcome, _) = await send(router, pm, model, sampling: sampling(maxTokens: 20_000))
        guard case .error(let message) = outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 2, "降一次就停")
        XCTAssertTrue(message.hasPrefix(FixJump.quotaPhrase + FixJump.prepaidQuotaNote), message)
        XCTAssertEqual(FixJump.kind(for: message), .quota)
        XCTAssertEqual(router.ledger.load().map(\.budgetChargeUSD), [0, 0], "预扣拒收没生成：重发那次和最终失败都不扣预算（审查 #5）")

        let small = try Server(responding: { _, _ in rejected })
        try small.start()
        let (router2, pm2, model2) = fixture(small, modelId: "按量K-claude-opus-4-6")
        _ = await send(router2, pm2, model2, sampling: sampling(maxTokens: 4000))
        XCTAssertEqual(small.requestBodies.count, 1, "上限本来就不大：不降")
        XCTAssertEqual(router2.ledger.load().map(\.budgetChargeUSD), [0], "一次就终止也不扣")
    }

    /// 审查 #4：Anthropic high 档可见 4096、实发 14096 → 预扣被拒按实发判，重发实发 ≤ 8192（压到 low），可见上限不升
    func testPrepaidQuotaAnthropicHighLowersSentCap() async throws {
        let rejected = try relay("ekanw-err_huge_max_tokens.json")
        let ok = try relay("ekanw-anth_xapikey_claude-opus-4-6-K.sse")
        let server = try Server(responding: { index, _ in index == 0 ? rejected : ok })
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-opus-4-6", type: .anthropic)

        let (outcome, _) = await send(router, pm, model, sampling: sampling(maxTokens: 4096, effort: "high"))
        XCTAssertEqual(outcome, .ok("2"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let first = try body(server.requestBodies[0]), second = try body(server.requestBodies[1])
        XCTAssertEqual(first["max_tokens"] as? Int, 4096 + 10_000)
        let sentCap = try XCTUnwrap(second["max_tokens"] as? Int)
        let budget = try XCTUnwrap((second["thinking"] as? [String: Any])?["budget_tokens"] as? Int)
        XCTAssertLessThanOrEqual(sentCap, OutputTokenCap.retryCap, "实发真的降了")
        XCTAssertEqual(sentCap, 4096 + 1024, "可见 4096 不动，思考压到 low")
        XCTAssertLessThan(budget, sentCap, "budget_tokens < max_tokens")
    }

    /// 审查 #7：OpenAI 兼容路降档发的是 reasoning_effort: low（中转怎么折算预算不保证）；再失败说人话、不下定论
    func testThinkingBudgetOpenAICompatRetriesWithLow() async throws {
        let rejected = try relay("ekanw-stream_claude-opus-4-6-thinking-单间.sse")
        let server = try Server(responding: { _, _ in rejected })
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "单间-claude-opus-4-6-thinking")

        let (outcome, _) = await send(router, pm, model, sampling: sampling(maxTokens: 4096, effort: "high"))
        guard case .error(let message) = outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 2, "降一档重发一次就停")
        XCTAssertEqual(try body(server.requestBodies[0])["reasoning_effort"] as? String, "high")
        XCTAssertEqual(try body(server.requestBodies[1])["reasoning_effort"] as? String, "low")
        XCTAssertEqual(try body(server.requestBodies[1])["max_tokens"] as? Int, 4096, "不降上限")
        XCTAssertTrue(message.hasPrefix(FixJump.thinkingBudgetMessage(sentThinking: true)), message)
        XCTAssertFalse(message.contains("1024"), message)
    }

    func testThinkingBudgetRetriesWithLowestTier() async throws {
        let rejected = try relay("ekanw-stream_claude-opus-4-6-thinking-单间.sse")
        let ok = try relay("ekanw-anth_xapikey_claude-opus-4-6-K.sse")
        let server = try Server(responding: { index, _ in index == 0 ? rejected : ok })
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "claude-opus-4-6", type: .anthropic)

        let (outcome, _) = await send(router, pm, model, sampling: sampling(maxTokens: 4096, effort: "high"))
        XCTAssertEqual(outcome, .ok("2"))
        XCTAssertEqual(server.requestBodies.count, 2)
        let first = try body(server.requestBodies[0]), second = try body(server.requestBodies[1])
        XCTAssertEqual((first["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 10_000)
        XCTAssertEqual((second["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 1024, "不关思考，压到最低档")
        XCTAssertEqual(second["max_tokens"] as? Int, 4096 + 1024, "可见上限不降")
        XCTAssertEqual(router.consumeParamAdaptation(), "思考预算比输出上限大，这一次把思考压到最低档")
        XCTAssertEqual(router.ledger.load().last?.input, 4169, "占位 usage 被 message_delta 覆盖（R10）")
    }

    func testRelayInjectedBudgetDoesNotLowerCap() async throws {
        let rejected = try relay("ekanw-stream_claude-opus-4-6-thinking-单间.sse")
        let server = try Server(responding: { _, _ in rejected })
        try server.start()
        let (router, pm, model) = fixture(server, modelId: "单间-claude-opus-4-6-thinking")

        let (outcome, _) = await send(router, pm, model, sampling: sampling(maxTokens: 16_384))
        guard case .error(let message) = outcome else { return XCTFail("不该成功") }
        XCTAssertEqual(server.requestBodies.count, 1, "以前会当上限太大降到 8192 重发")
        XCTAssertTrue(message.hasPrefix(FixJump.thinkingBudgetMessage(sentThinking: false)), message)
    }

    /// R9：中转响应里的 model（claude-opus-4-6 / K-claude-opus-4-6-7）和请求的不一样，账本 / 学习表按请求的记
    func testLedgerUsesRequestedModelId() async throws {
        let ok = try relay("ekanw-stream_claude-opus-4-6-K.sse")
        let server = try Server(responding: { _, _ in ok })
        try server.start()
        let requested = "按量K-claude-opus-4-6"
        let (router, pm, model) = fixture(server, modelId: requested)

        let (outcome, _) = await send(router, pm, model, sampling: sampling(maxTokens: 1024))
        XCTAssertEqual(outcome, .ok("2"))
        let row = try XCTUnwrap(router.ledger.load().last)
        XCTAssertEqual(row.model, requested)
        XCTAssertEqual(row.input, 4169)
        XCTAssertEqual(try body(server.requestBodies[0])["model"] as? String, requested)
    }
}
