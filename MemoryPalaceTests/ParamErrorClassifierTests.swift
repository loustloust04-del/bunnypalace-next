import XCTest
@testable import 记忆花园

/// #094 认报错（plan-param-autoadapt §4.1）：各家 400 / 422 样本 → 认出的参数
final class ParamErrorClassifierTests: XCTestCase {

    func testSentShapeFromBody() {
        let body: [String: Any] = [
            "model": "gpt-5", "temperature": 0.7, "top_p": 0.95, "max_tokens": 16384, "stream_options": ["include_usage": true],
            "reasoning_effort": "none", "thinking": ["type": "enabled", "budget_tokens": 1024],
        ]
        let shape = ParamErrorClassifier.SentShape(body: body)
        XCTAssertEqual(shape.keys, ["model", "temperature", "top_p", "max_tokens", "stream_options", "reasoning_effort", "thinking"])
        XCTAssertEqual(shape.thinkingType, "enabled")
        XCTAssertEqual(shape.values["temperature"], "0.7")
        XCTAssertEqual(shape.values["reasoning_effort"], "none")
    }

    // MARK: - 样本 → 识别结果（§4.1 全表；措辞标「未查证」的见 review）

    typealias Fix = ParamErrorClassifier.Fix

    private static var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/param-errors")
    }

    private func sample(_ name: String) throws -> String {
        try String(contentsOf: Self.dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// OpenAI 兼容口默认预设实发的样子
    private let openAISent = ParamErrorClassifier.SentShape(body: [
        "model": "m", "messages": [], "stream": true, "stream_options": ["include_usage": true],
        "temperature": 0.7, "top_p": 0.95, "max_tokens": 16384,
    ])

    private func classify(_ name: String, status: Int = 400, sent: ParamErrorClassifier.SentShape? = nil,
                          host: String = "relay.example.com") throws -> ParamErrorClassifier.Verdict {
        ParamErrorClassifier.classify(status: status, body: try sample(name), sent: sent ?? openAISent, host: host)
    }

    func testOpenAISamples() throws {
        XCTAssertEqual(try classify("openai-temperature-unsupported-value.json"), .fix([.dropSampling]),
                       "Only the default (1)：去掉采样组就对")
        XCTAssertEqual(try classify("openai-max-tokens-unsupported.json"), .fix([.renameMaxTokens(to: "max_completion_tokens")]),
                       "改键名，不降 8192")
        XCTAssertEqual(try classify("max-tokens-too-large.json"), .fix([.lowerOutputCap]), "上限太大：原 R8")
        XCTAssertEqual(try classify("stream-options-unrecognized.json"), .fix([.drop(ParamCompat.Group.streamOptions)]))
    }

    /// 粟粟 10-14：Opus 4.6 默认预设（0.7 + 0.95）原文。只去 top_p，不整组去
    func testTemperatureAndTopPBothSpecified() throws {
        let plain = ParamErrorClassifier.SentShape(body: [
            "model": "claude-opus-4-6", "messages": [], "max_tokens": 16384, "stream": true, "temperature": 0.7, "top_p": 0.95,
        ])
        let verdict = try classify("anthropic-temperature-top-p-both.json", sent: plain)
        XCTAssertEqual(verdict, .fix([.singleSampler]))
        XCTAssertEqual(ParamErrorClassifier.learned(from: [.singleSampler]).groups, [ParamCompat.Group.singleSampler])
        XCTAssertEqual(ParamErrorClassifier.notice([.singleSampler]), "这个模型 temperature 和 top_p 只收一个，已去掉 top_p")
        let onlyTemperature = ParamErrorClassifier.SentShape(body: ["model": "m", "messages": [], "temperature": 0.7])
        XCTAssertEqual(try classify("anthropic-temperature-top-p-both.json", sent: onlyTemperature), .unknown, "两个都真发了才认")
    }

    func testAnthropicSamples() throws {
        let plain = ParamErrorClassifier.SentShape(body: [
            "model": "m", "messages": [], "max_tokens": 16384, "stream": true, "temperature": 0.7, "top_p": 0.95, "top_k": 40,
        ])
        XCTAssertEqual(try classify("anthropic-temperature-deprecated.json", sent: plain), .fix([.dropSampling]))
        guard case .explain(let prefill) = try classify("anthropic-prefill.json", sent: plain) else { return XCTFail("预填不重试") }
        XCTAssertTrue(prefill.contains("预填"), prefill)

        let thinking = ParamErrorClassifier.SentShape(body: [
            "model": "m", "messages": [], "max_tokens": 26384, "stream": true, "thinking": ["type": "enabled", "budget_tokens": 10000],
        ])
        XCTAssertEqual(try classify("anthropic-thinking-enabled.json", sent: thinking), .fix([.thinkingFormat("adaptive")]))

        var hot = plain
        hot.values["temperature"] = "1.5"
        guard case .explain(let range) = try classify("anthropic-temperature-range.json", sent: hot, host: "api.anthropic.com") else {
            return XCTFail("值不对不重试")
        }
        XCTAssertEqual(range, "api.anthropic.com 不收参数 temperature 现在的值（1.5）")
    }

    func testWrappedSamples() throws {
        XCTAssertEqual(try classify("openrouter-metadata-raw.json"), .fix([.dropSampling]), "OpenRouter metadata.raw 里层")
        XCTAssertEqual(try classify("relay-embedded-upstream.json"), .fix([.dropSampling]), "文字里嵌的上游 JSON")
        XCTAssertEqual(try classify("fastapi-extra-forbidden.json", status: 422), .fix([.dropSampling]), "FastAPI / vLLM 422")
        var seeded = openAISent
        seeded.keys.insert("seed")
        XCTAssertEqual(try classify("gemini-array-unknown-name.json", sent: seeded), .fix([.drop(ParamCompat.Group.seed)]), "Gemini 顶层数组")
    }

    func testValueProblemsExplainNotRetry() throws {
        var hot = openAISent
        hot.values["temperature"] = "3.0"
        guard case .explain(let loc) = try classify("loc-value-error.json", status: 422, sent: hot) else { return XCTFail() }
        XCTAssertEqual(loc, "relay.example.com 不收参数 temperature 现在的值（3.0）")

        var effort = openAISent
        effort.keys.insert("reasoning_effort")
        effort.values["reasoning_effort"] = "none"
        guard case .explain(let none) = try classify("reasoning-effort-none.json", sent: effort) else { return XCTFail("Q10：不自动换档") }
        XCTAssertEqual(none, "relay.example.com 上的这个模型不收推理强度「关」，换一档")
    }

    func testUnknownCases() throws {
        var noTemp = openAISent
        noTemp.keys.remove("temperature")
        noTemp.keys.remove("top_p")
        XCTAssertEqual(try classify("openai-temperature-unsupported-value.json", sent: noTemp), .unknown, "只认真发了的字段")
        XCTAssertEqual(try classify("cloudflare-400.html"), .unknown)
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: "", sent: openAISent, host: "x"), .unknown)
        XCTAssertEqual(try classify("openai-temperature-unsupported-value.json", status: 500), .unknown, "非 400 / 422 不碰")
        XCTAssertEqual(try classify("openai-temperature-unsupported-value.json", status: 429), .unknown)
    }

    func testNoticeAndLearned() {
        XCTAssertEqual(ParamErrorClassifier.notice([.dropSampling]), "这个模型不收 temperature / top_p，已自动去掉")
        XCTAssertEqual(ParamErrorClassifier.notice([.renameMaxTokens(to: "max_completion_tokens")]),
                       "这个接口要用 max_completion_tokens，已自动改")
        XCTAssertEqual(ParamErrorClassifier.notice([.dropSampling, .renameMaxTokens(to: "max_completion_tokens")]),
                       "这个模型不收 temperature / top_p、要用 max_completion_tokens，已自动调整")
        XCTAssertNil(ParamErrorClassifier.notice([.lowerOutputCap]))

        let learned = ParamErrorClassifier.learned(from: [.dropSampling, .drop(ParamCompat.Group.seed), .lowerOutputCap,
                                                          .renameMaxTokens(to: "max_completion_tokens"), .thinkingFormat("adaptive")])
        XCTAssertEqual(learned, ParamCompat.Learned(groups: [ParamCompat.Group.sampling, ParamCompat.Group.seed],
                                                    maxTokensKey: "max_completion_tokens", thinkingFormat: "adaptive"))
    }

    // MARK: - §3.7 说人话

    func testErrorMessageShapes() throws {
        func msg(_ name: String) throws -> String {
            BaseChatProvider.errorMessage(from: Data(try sample(name).utf8), statusCode: 400)
        }
        XCTAssertEqual(try msg("openai-max-tokens-unsupported.json"),
                       "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.", "老形状不变")
        XCTAssertEqual(try msg("gemini-array-unknown-name.json"), "Invalid JSON payload received. Unknown name \"seed\": Cannot find field.")
        XCTAssertEqual(try msg("fastapi-extra-forbidden.json"), "body.top_p: Extra inputs are not permitted")
        XCTAssertEqual(try msg("openrouter-metadata-raw.json"), "Provider returned error：`temperature` is deprecated for this model.")
        XCTAssertEqual(BaseChatProvider.errorMessage(from: Data(#"{"detail":"Not Found"}"#.utf8), statusCode: 404), "Not Found")
        XCTAssertEqual(try msg("cloudflare-400.html"), "API 错误 (400)")
        XCTAssertEqual(BaseChatProvider.errorMessage(from: Data(#"{"error":"bad key"}"#.utf8), statusCode: 401), "bad key")
    }

    func testFailureMessage() throws {
        let sent = openAISent
        func fail(_ body: String, status: Int = 400, learned: ParamCompat.Learned = .init()) -> String {
            ProviderRouter.failureMessage("原文", status: status, host: "relay.example.com", modelId: "m", cap: nil, sent: sent,
                                          errorBody: body, providerType: .openaiCompatible, learnedNow: learned)
        }
        XCTAssertEqual(fail(try sample("cloudflare-400.html")), "原文（relay.example.com · m · HTTP 400）")
        // plan-api-draft-and-fix-jump §3.3：有状态码的失败一律带尾巴（「去改」靠它认 401 / 404）
        XCTAssertEqual(fail(try sample("cloudflare-400.html"), status: 500), "原文（relay.example.com · m · HTTP 500）")
        XCTAssertEqual(fail("{}", status: 429), "原文（relay.example.com · m · HTTP 429）", "429 只加尾巴不加话")
        XCTAssertEqual(fail("{}", status: 401), "key 不对或没有权限。原文：原文（relay.example.com · m · HTTP 401）")
        XCTAssertEqual(fail("{}", status: 403), "key 不对或没有权限。原文：原文（relay.example.com · m · HTTP 403）")
        XCTAssertEqual(fail("{}", status: 404), "地址不对，检查 Base URL。原文：原文（relay.example.com · m · HTTP 404）")
        XCTAssertEqual(fail("{}", status: 0), "原文", "没收到 HTTP 状态（网络错）不加尾巴")
        XCTAssertTrue(fail(try sample("anthropic-prefill.json")).hasPrefix("这个模型不收预填"))
        XCTAssertTrue(fail(try sample("anthropic-prefill.json")).hasSuffix("。原文：原文（relay.example.com · m · HTTP 400）"), "认出来的 .explain 也带尾巴")
        XCTAssertEqual(fail(try sample("openai-temperature-unsupported-value.json"), learned: .init(groups: [ParamCompat.Group.sampling])),
                       "原文（relay.example.com · m · HTTP 400）\n（已记住：不发 temperature、top_p，下次自动照办）")
        let tailed = ProviderRouter.failureMessage("原文（relay.example.com · m · HTTP 400）", status: 400, host: "relay.example.com", modelId: "m",
                                                   cap: nil, sent: sent, errorBody: "{}", providerType: .openaiCompatible, learnedNow: .init())
        XCTAssertEqual(tailed, "原文（relay.example.com · m · HTTP 400）", "已经带了不重复加")
    }

    // MARK: - astra #2 脱敏

    func testRedactedStripsKeyAndURLQuery() {
        let secret = "sk-abc/def+123"
        let text = #"bad key sk-abc/def+123 and escaped sk-abc\/def+123; upstream https://user:pw@up.example/v1/chat?key=SECRET&x=1 done"#
        let out = ParamErrorClassifier.redacted(text, secrets: [secret])
        XCTAssertFalse(out.contains("sk-abc"), out)
        XCTAssertFalse(out.contains("SECRET"), out)
        XCTAssertFalse(out.contains("user:pw"), out)
        XCTAssertTrue(out.contains("https://up.example/v1/chat done"), out)
        XCTAssertTrue(out.contains(SentRequestStore.redactedKey), out)
    }

    /// astra（60f9ea823 #5）：统一错误出口连实际发出去的认证类请求头值一起脱敏，正文里回显的认证头结构也去掉
    func testRedactedCoversSensitiveHeadersAndAuthStructures() {
        let headers = ["X-Relay-Auth": "relay-SECRET-777", "Cookie": "sid=COOKIE-SECRET-1; theme=dark", "HTTP-Referer": "https://memorypalace.example",
                       "Authorization": "Bearer BEARER-SECRET-12345"]
        let secrets = ParamErrorClassifier.secrets(apiKey: "sk-main-key", headers: headers)
        XCTAssertTrue(secrets.contains("relay-SECRET-777"))
        XCTAssertTrue(secrets.contains("COOKIE-SECRET-1"))
        XCTAssertTrue(secrets.contains("BEARER-SECRET-12345"))
        XCTAssertFalse(secrets.contains("https://memorypalace.example"), "不是认证类的头不算")
        let echoed = #"prompt is too long; got headers x-relay-auth=relay-SECRET-777 sid COOKIE-SECRET-1 key sk-main-key BEARER-SECRET-12345"#
        let shown = ParamErrorClassifier.redacted(echoed, secrets: secrets)
        for secret in ["relay-SECRET-777", "COOKIE-SECRET-1", "sk-main-key", "BEARER-SECRET-12345"] { XCTAssertFalse(shown.contains(secret), shown) }
        XCTAssertTrue(shown.contains("prompt is too long"))
        let structured = #"{"error":{"message":"bad","request":{"headers":{"Authorization":"Bearer OTHER-TOKEN-999","Cookie":"a=UNKNOWN-1; b=2","x-api-key":"UNSEEN-KEY"}}}} Authorization: Bearer LINE-TOKEN-0001"#
        let cleaned = ParamErrorClassifier.redacted(structured, secrets: [])
        for leak in ["OTHER-TOKEN-999", "UNKNOWN-1", "UNSEEN-KEY", "LINE-TOKEN-0001"] { XCTAssertFalse(cleaned.contains(leak), cleaned) }
        XCTAssertTrue(cleaned.contains("bad"))
        XCTAssertEqual(ParamErrorClassifier.redacted("Invalid api_key provided; authorization failed", secrets: []), "Invalid api_key provided; authorization failed", "没有值的提法不动")
        XCTAssertEqual(CatalogSeedPrompts.providerText("原文：x"), "x", "providerText 只截取，不负责脱敏")
    }

    func testRedactedMetadataRawWithQueryKey() {
        let raw = #"{"error":{"message":"Provider returned error","metadata":{"raw":"{\"error\":{\"message\":\"upstream https://gw.example/v1beta/models?key=AIzaSECRET failed\"}}"}}}"#
        let shown = ParamErrorClassifier.redacted(BaseChatProvider.errorMessage(from: Data(raw.utf8), statusCode: 400), secrets: [])
        XCTAssertFalse(shown.contains("AIzaSECRET"), shown)
        XCTAssertTrue(shown.contains("https://gw.example/v1beta/models"), shown)
        XCTAssertFalse(ParamErrorClassifier.redacted(raw, secrets: []).contains("AIzaSECRET"), "原文落盘 / 日志那份也去掉")
    }

    // MARK: - astra #3 adaptive → budget 只认明确在拒 thinking.type 的

    private var adaptiveSent: ParamErrorClassifier.SentShape {
        ParamErrorClassifier.SentShape(body: [
            "model": "m", "messages": [], "max_tokens": 26384, "stream": true,
            "thinking": ["type": "adaptive"], "output_config": ["effort": "high"],
        ])
    }

    func testPrefillWithAdaptiveIsNotThinkingFormat() throws {
        guard case .explain(let text) = try classify("anthropic-prefill-adaptive.json", sent: adaptiveSent) else {
            return XCTFail("预填：说人话、不学、不重试")
        }
        XCTAssertTrue(text.hasPrefix("这个模型不收预填"), text)
    }

    func testAdaptiveTypeRejectedSwitchesToBudget() throws {
        XCTAssertEqual(try classify("anthropic-thinking-adaptive-rejected.json", sent: adaptiveSent), .fix([.thinkingFormat("budget")]))
        let named = #"{"type":"error","error":{"type":"invalid_request_error","message":"thinking.type: 'adaptive' is not supported for this model"}}"#
        XCTAssertEqual(ParamErrorClassifier.classify(status: 400, body: named, sent: adaptiveSent, host: "x"), .fix([.thinkingFormat("budget")]))
        let vague = #"{"type":"error","error":{"type":"invalid_request_error","message":"adaptive mode is not supported on this tier"}}"#
        XCTAssertNotEqual(ParamErrorClassifier.classify(status: 400, body: vague, sent: adaptiveSent, host: "x"), .fix([.thinkingFormat("budget")]),
                          "没点名 thinking.type 不换格式")
    }

    // MARK: - astra #4 结构化优先、采样值错误不学

    func testStructuredValueErrorBeatsText() throws {
        var effort = openAISent
        effort.keys.insert("reasoning_effort")
        effort.values["reasoning_effort"] = "none"
        guard case .explain(let none) = try classify("reasoning-effort-none-unquoted.json", sent: effort) else {
            return XCTFail("Q10：不学、不重试")
        }
        XCTAssertEqual(none, "relay.example.com 上的这个模型不收推理强度「关」，换一档")

        guard case .explain(let range) = try classify("openai-temperature-range-unsupported-value.json") else {
            return XCTFail("采样参数值不对、没说只收默认值 → 说人话不学")
        }
        XCTAssertEqual(range, "relay.example.com 不收参数 temperature 现在的值（0.7）")
        XCTAssertEqual(try classify("openai-temperature-unsupported-value.json"), .fix([.dropSampling]), "明说只收默认值才整组去")
    }

    // MARK: - thinking 回传 §3.6（样本措辞除「Invalid `signature` in `thinking` block」外是推断）

    private let opusThinkingSent = ParamErrorClassifier.SentShape(body: [
        "model": "claude-opus-5-5", "messages": [], "max_tokens": 36864, "stream": true,
        "thinking": ["type": "adaptive", "display": "summarized"],
    ])

    func testThinkingDisplayRejectedOnlyDropsDisplay() throws {
        XCTAssertEqual(opusThinkingSent.thinkingDisplay, "summarized")
        XCTAssertEqual(try classify("anthropic-thinking-display-extra.json", sent: opusThinkingSent),
                       .fix([.drop(ParamCompat.Group.thinkingDisplay)]), "不能落到「thinking 不收 → 整个关思考」")
        XCTAssertEqual(try classify("fastapi-thinking-display-forbidden.json", status: 422, sent: opusThinkingSent),
                       .fix([.drop(ParamCompat.Group.thinkingDisplay)]))
        XCTAssertEqual(ParamErrorClassifier.learned(from: [.drop(ParamCompat.Group.thinkingDisplay)]).groups, [ParamCompat.Group.thinkingDisplay])
        XCTAssertEqual(ParamErrorClassifier.notice([.drop(ParamCompat.Group.thinkingDisplay)]), "这个模型不收 思考摘要参数（thinking.display），已自动去掉")
        let noDisplay = ParamErrorClassifier.SentShape(body: ["model": "m", "messages": [], "thinking": ["type": "adaptive"]])
        XCTAssertNotEqual(try classify("anthropic-thinking-display-extra.json", sent: noDisplay), .fix([.drop(ParamCompat.Group.thinkingDisplay)]),
                          "没发 display 不认")
    }

    func testThinkingBlocksRejectedIsNotLearned() throws {
        XCTAssertEqual(try classify("anthropic-thinking-signature-invalid.json", sent: opusThinkingSent), .thinkingBlocksRejected)
        XCTAssertEqual(try classify("anthropic-thinking-blocks-modified.json", sent: opusThinkingSent), .thinkingBlocksRejected)
        XCTAssertEqual(try classify("anthropic-thinking-signature-invalid.json", status: 500, sent: opusThinkingSent), .unknown)
    }

    func testRefusalNotice() {
        XCTAssertEqual(ParamErrorClassifier.refusalNotice(category: "reasoning_extraction")?.hasPrefix("模型拒绝在正文里写出内部推理"), true)
        XCTAssertNil(ParamErrorClassifier.refusalNotice(category: "cyber"))
        XCTAssertNil(ParamErrorClassifier.refusalNotice(category: nil))
    }
}

