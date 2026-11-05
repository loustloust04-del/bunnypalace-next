import XCTest
@testable import 记忆花园

/// 聊天报错归类（plan-model-compat-p0 §7.7）。样本在 `Fixtures/chat-errors/`，`source` 写着是不是实测原文
final class ChatErrorClassifierTests: XCTestCase {
    typealias Kind = ChatErrorClassifier.Kind

    private static var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat-errors")
    }

    private func input(_ name: String) throws -> ChatErrorClassifier.Input {
        let data = try Data(contentsOf: Self.dir.appendingPathComponent(name))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try XCTUnwrap(obj["body"] as? String)
        let stream = obj["stream"] as? Bool ?? false
        return .init(status: try XCTUnwrap(obj["status"] as? Int), body: stream ? "" : body, streamError: stream ? body : nil,
                     headers: obj["headers"] as? [String: String] ?? [:])
    }

    private func classify(_ name: String) throws -> Kind {
        ChatErrorClassifier.classify(try input(name))
    }

    private func classify(status: Int, _ body: String) -> Kind {
        ChatErrorClassifier.classify(.init(status: status, body: body))
    }

    func testRateLimitAndQuotaSamples() throws {
        XCTAssertEqual(try classify("openai-429-rate-limit.json"), .rateLimited(retryAfter: 3), "「Rate limit reached」不算额度用完")
        XCTAssertEqual(try classify("openai-429-insufficient-quota.json"), .quota)
        XCTAssertEqual(try classify("deepseek-402-insufficient-balance.json"), .quota)
        XCTAssertEqual(try classify("kimi-429-engine-overloaded.json"), .rateLimited(retryAfter: nil))
        XCTAssertEqual(try classify("zh-429-too-frequent.json"), .rateLimited(retryAfter: nil))
        XCTAssertEqual(try classify("zh-429-daily-quota.json"), .quota)
        XCTAssertEqual(classify(status: 429, "{}"), .rateLimited(retryAfter: nil), "其余 429 兜底算短时限流")
    }

    func testServerSamples() throws {
        XCTAssertEqual(try classify("anthropic-529-overloaded.json"), .transient)
        XCTAssertEqual(try classify("anthropic-stream-overloaded.json"), .transient, "状态 200 的流内 overloaded_error")
        XCTAssertEqual(try classify("openai-500-server-error.json"), .transient)
        for status in [408, 502, 503, 504] {
            XCTAssertEqual(classify(status: status, "{}"), .transient, "\(status)")
        }
        var orStream = ChatErrorClassifier.Input(status: 200, body: "", streamError: #"{"error":{"code":502,"message":"Provider returned error"}}"#)
        XCTAssertEqual(ChatErrorClassifier.classify(orStream), .other, "数字 code 当状态码只认 OpenRouter（审查 #8）")
        orStream.host = .openrouter
        XCTAssertEqual(ChatErrorClassifier.classify(orStream), .transient, "OpenRouter 流内数字 code 当状态码")
        let typedStream = ChatErrorClassifier.Input(status: 200, body: "",
            streamError: #"{"error":{"type":"authentication_error","code":502,"message":"Invalid API key"}}"#, host: .openrouter)
        XCTAssertEqual(ChatErrorClassifier.classify(typedStream), .other, "结构化 type 优先于数字码")
        let plainStream = ChatErrorClassifier.Input(status: 200, body: "", streamError: #"{"error":{"message":"something odd"}}"#)
        XCTAssertEqual(ChatErrorClassifier.classify(plainStream), .other)
    }

    func testContextTooLong() throws {
        for name in ["openai-400-context-length.json", "anthropic-400-prompt-too-long.json", "kimi-400-token-limit.json",
                     "dashscope-400-input-length.json", "zh-400-context.json"] {
            XCTAssertEqual(try classify(name), .contextTooLong, name)
        }
        XCTAssertNotEqual(classify(status: 400, #"{"error":{"message":"max_tokens is too large: 16384. This model supports at most 8192 completion tokens."}}"#),
                          .contextTooLong, "输出上限归 R8，不是超长")
        XCTAssertNotEqual(classify(status: 400, #"{"error":{"message":"input token count exceeds the maximum, lower max_tokens"}}"#),
                          .contextTooLong, "提到输出上限键名的不算超长")
        XCTAssertEqual(try classify("bedrock-429-too-many-tokens.json"), .rateLimited(retryAfter: nil), "Too many tokens, please wait 是限流")
        XCTAssertNotEqual(classify(status: 400, #"{"message":"Too many tokens, please wait before trying again."}"#), .contextTooLong)
        XCTAssertEqual(classify(status: 500, #"{"error":{"message":"prompt is too long"}}"#), .transient, "超长只认 400 / 413 / 422 / 流内")
    }

    func testContentFilter() throws {
        XCTAssertEqual(try classify("azure-400-content-filter.json"), .contentFiltered)
        XCTAssertEqual(try classify("openai-400-content-policy.json"), .contentFiltered)
        XCTAssertEqual(classify(status: 400, #"{"error":{"code":"invalid_prompt","message":"Your prompt was flagged"}}"#), .contentFiltered)
    }

    func testNetworkErrors() {
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 0, body: "", urlErrorCode: NSURLErrorNetworkConnectionLost)), .connectionLost)
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 200, body: "", urlErrorCode: NSURLErrorNetworkConnectionLost)), .other,
                       "回了 200 头之后断的不算（上游可能已在生成，审查 #2）")
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 0, body: "", urlErrorCode: NSURLErrorTimedOut)), .other, "超时不重试（Q6）")
        XCTAssertEqual(ChatErrorClassifier.classify(.init(status: 0, body: "", urlErrorCode: NSURLErrorNotConnectedToInternet)), .other)
    }

    func testRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after": "3"], now: now), 3)
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after-ms": "1500", "retry-after": "9"], now: now), 1.5)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after": f.string(from: now.addingTimeInterval(10))], now: now), 10)
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after": f.string(from: now.addingTimeInterval(-10))], now: now), 0)
        XCTAssertNil(ChatErrorClassifier.retryAfter(["retry-after": "soon"], now: now))
        XCTAssertNil(ChatErrorClassifier.retryAfter(["retry-after": "-1"], now: now))
        XCTAssertNil(ChatErrorClassifier.retryAfter([:], now: now))
    }

    /// 审查 #7：inf / 超大值封顶 1 小时，NaN = 乱写 = nil；格式化不崩
    func testRetryAfterNonFinite() {
        let cap = ChatErrorClassifier.retryAfterCap
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after": "inf"]), cap)
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after": "1e308"]), cap)
        XCTAssertNil(ChatErrorClassifier.retryAfter(["retry-after": "nan"]))
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after-ms": "inf"]), cap)
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after-ms": "1e300"]), cap)
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after-ms": "nan", "retry-after": "2"]), 2, "ms 乱写退回秒数头")
        XCTAssertEqual(ChatErrorClassifier.retryAfter(["retry-after": "Fri, 31 Dec 9999 23:59:59 GMT"]), cap)
        XCTAssertNil(ChatErrorClassifier.retryWait(.rateLimited(retryAfter: .infinity), retry: 0))
        XCTAssertNil(ChatErrorClassifier.retryWait(.rateLimited(retryAfter: .nan), retry: 0))
        XCTAssertEqual(ChatErrorClassifier.plainReason(.rateLimited(retryAfter: .infinity), retried: 0), "被限流了，大约 3600 秒后再发")
        XCTAssertEqual(ChatErrorClassifier.plainReason(.rateLimited(retryAfter: 1e300), retried: 0), "被限流了，大约 3600 秒后再发")
        XCTAssertEqual(ChatErrorClassifier.plainReason(.rateLimited(retryAfter: .nan), retried: 0), "被限流了，过一会儿再发")
        XCTAssertEqual(ChatErrorClassifier.retryNotice(.rateLimited(retryAfter: nil), wait: .infinity, retry: 0),
                       "⏳ 请求太频繁被限流了，3600 秒后自动重试（1/2）")
        let input = ChatErrorClassifier.Input(status: 429, body: Self.rateBody, headers: ["retry-after": "inf"])
        XCTAssertEqual(ChatErrorClassifier.classify(input), .rateLimited(retryAfter: cap))
    }

    static let rateBody = #"{"error":{"message":"Too many requests","type":"requests"}}"#

    /// 审查 #4：短时窗口证据压过「quota / 用量」泛词；只有明确耗尽 / 欠费才是额度
    func testShortWindowBeatsQuotaWords() {
        let perMinute = #"{"error":{"message":"Quota exceeded for input tokens per minute. Please retry in 2 seconds.","type":"requests","code":"rate_limit_exceeded"}}"#
        XCTAssertEqual(classify(status: 429, perMinute), .rateLimited(retryAfter: nil))
        XCTAssertEqual(classify(status: 429, #"{"error":{"message":"每分钟用量超过限制，请稍后重试"}}"#), .rateLimited(retryAfter: nil))
        XCTAssertEqual(classify(status: 429, #"{"error":{"message":"Quota exceeded, please try again later"}}"#), .rateLimited(retryAfter: nil),
                       "quota 单独出现不算耗尽")
        XCTAssertEqual(classify(status: 429, #"{"error":{"message":"您的额度不够，请稍后"}}"#), .rateLimited(retryAfter: nil), "额度单独出现不算耗尽")
        XCTAssertEqual(classify(status: 429, #"{"error":{"message":"You have reached your daily limit"}}"#), .quota)
        XCTAssertEqual(classify(status: 429, #"{"error":{"message":"本月额度已用完"}}"#), .quota)
        XCTAssertEqual(classify(status: 403, #"{"error":{"message":"账户已欠费"}}"#), .quota)
    }

    /// 审查 #5：HTTP 200 流内的限流类型
    func testStreamRateLimit() {
        let typed = ChatErrorClassifier.Input(status: 200, body: "", streamError: #"{"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}"#,
                                              headers: ["retry-after": "2"])
        XCTAssertEqual(ChatErrorClassifier.classify(typed), .rateLimited(retryAfter: 2))
        let coded = ChatErrorClassifier.Input(status: 200, body: "", streamError: #"{"error":{"code":"rate_limit_exceeded","message":"slow down"}}"#)
        XCTAssertEqual(ChatErrorClassifier.classify(coded), .rateLimited(retryAfter: nil))
        let quota = ChatErrorClassifier.Input(status: 200, body: "", streamError: #"{"error":{"type":"insufficient_quota","message":"You exceeded your current quota"}}"#)
        XCTAssertEqual(ChatErrorClassifier.classify(quota), .quota)
    }

    /// 审查 #6：先解码再匹配，\u 转义的中文也认得
    func testEscapedChineseDecoded() {
        let escaped = #"{"error":{"message":"\u8f93\u5165\u5185\u5bb9\u8fc7\u957f"}}"#   // 输入内容过长
        XCTAssertEqual(classify(status: 400, escaped), .contextTooLong)
        XCTAssertEqual(classify(status: 403, #"{"error":{"message":"\u8d26\u6237\u5df2\u6b20\u8d39"}}"#), .quota, "账户已欠费")
        XCTAssertEqual(classify(status: 400, #"{"error":{"message":"\u542b\u6709\u654f\u611f\u5185\u5bb9"}}"#), .contentFiltered, "含有敏感内容")
        XCTAssertEqual(classify(status: 429, #"{"error":{"message":"\u6bcf\u5206\u949f\u7528\u91cf\u8d85\u8fc7\u9650\u5236"}}"#),
                       .rateLimited(retryAfter: nil), "每分钟用量超过限制")
    }

    /// 审查 #2 / #3：明确被拒才免预算；连接断开处理状态不明
    func testExplicitRejection() {
        for status in [408, 429, 500, 503, 529] {
            XCTAssertTrue(ChatErrorClassifier.isExplicitRejection(.init(status: status, body: Self.rateBody)), "\(status)")
        }
        XCTAssertFalse(ChatErrorClassifier.isExplicitRejection(.init(status: 503, body: "  ")), "没有错误正文")
        XCTAssertFalse(ChatErrorClassifier.isExplicitRejection(.init(status: 0, body: "", urlErrorCode: NSURLErrorNetworkConnectionLost)))
        XCTAssertFalse(ChatErrorClassifier.isExplicitRejection(.init(status: 200, body: "", urlErrorCode: NSURLErrorNetworkConnectionLost)))
        XCTAssertFalse(ChatErrorClassifier.isExplicitRejection(.init(status: 400, body: Self.rateBody)), "400 归参数自愈那边管")
        XCTAssertTrue(ChatErrorClassifier.isExplicitRejection(.init(status: 200, body: "",
            streamError: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)))
        XCTAssertFalse(ChatErrorClassifier.isExplicitRejection(.init(status: 200, body: "", streamError: #"{"error":{"message":"something odd"}}"#)))
        XCTAssertTrue(ChatErrorClassifier.isExplicitRejection(.init(status: 200, body: "",
            streamError: #"{"error":{"code":503,"message":"Provider returned error"}}"#, host: .openrouter)))
    }

    func testRetryWait() {
        XCTAssertEqual(ChatErrorClassifier.retryWait(.transient, retry: 0), 1)
        XCTAssertEqual(ChatErrorClassifier.retryWait(.transient, retry: 1), 3)
        XCTAssertNil(ChatErrorClassifier.retryWait(.transient, retry: 2))
        XCTAssertEqual(ChatErrorClassifier.retryWait(.rateLimited(retryAfter: nil), retry: 0), 2)
        XCTAssertEqual(ChatErrorClassifier.retryWait(.rateLimited(retryAfter: nil), retry: 1), 4)
        XCTAssertEqual(ChatErrorClassifier.retryWait(.rateLimited(retryAfter: 8), retry: 0), 8)
        XCTAssertNil(ChatErrorClassifier.retryWait(.rateLimited(retryAfter: 9), retry: 0), "> 8 秒不等")
        XCTAssertEqual(ChatErrorClassifier.retryWait(.connectionLost, retry: 0), 1)
        XCTAssertNil(ChatErrorClassifier.retryWait(.connectionLost, retry: 1), "连接断开只重试一次")
        for kind: Kind in [.quota, .contextTooLong, .contentFiltered, .other] {
            XCTAssertNil(ChatErrorClassifier.retryWait(kind, retry: 0))
        }
    }
}
