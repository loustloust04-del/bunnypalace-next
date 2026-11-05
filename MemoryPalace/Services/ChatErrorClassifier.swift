import Foundation

/// 聊天请求失败归类（plan-model-compat-p0 §7.2；抄 magpie gw/routing.go failure() 的判定顺序 + omp flags.ts 的超长正则）。
/// 400 / 422 的参数问题仍归 ParamErrorClassifier，这里只管它不管的
enum ChatErrorClassifier {
    enum Kind: Equatable {
        /// 408 / 500 / 502 / 503 / 504 / 529 / overloaded
        case transient
        /// 短时 429
        case rateLimited(retryAfter: TimeInterval?)
        /// 402 / 欠费 / 额度用完 / insufficient_quota
        case quota
        case contextTooLong
        /// 报错正文说被安全策略拦
        case contentFiltered
        /// 中转（new-api）分组里没有这个模型 / 渠道全挂：model_not_found、get_channel_failed、No available channel（R1，不重试）
        case unavailableModel
        /// 这把 key 的分组不能用这个模型（「无权访问 xx 分组」，R5）
        case groupDenied
        /// 还没有任何 HTTP 状态（0）且 NSURLErrorNetworkConnectionLost（Q6）；回了 200 头之后断的不算（上游可能已在生成）
        case connectionLost
        case other
    }

    struct Input {
        var status: Int
        var body: String
        var streamError: String?
        var headers: [String: String] = [:]
        var urlErrorCode: Int?
        /// 流内数字 `error.code` 只有 OpenRouter 约定是上游 HTTP 状态
        var host: KnownHost = .other
    }

    static let maxRetries = 2
    /// Retry-After 上限：inf / 超大值封顶到 1 小时（服务器明说要等很久，当成 nil 会按 2s / 4s 短退避去撞它）；NaN / 负数 = 乱写 = nil
    static let retryAfterCap: TimeInterval = 3600

    static func classify(_ input: Input) -> Kind {
        let ev = parsed(input)
        let text = ev.text
        let status = effectiveStatus(input, ev)

        if [400, 413, 422].contains(status) || input.streamError != nil,
           matchesAny(text, contextPatterns) || !ev.codes.isDisjoint(with: contextCodes),
           !containsAny(text, outputLimitWords), !containsAny(text, throttleWords) {
            return .contextTooLong
        }
        // R1 / R5 的文字兜底让位于明确的结构化原因（坏 key / 限流 / 过载）；model_not_found / get_channel_failed 码照认
        let badKey = status == 401 || !ev.codes.isDisjoint(with: authCodes) || containsAny(text, badKeyWords)
        let throttledOrOverloaded = status == 529 || ev.codes.contains { $0.hasPrefix("rate_limit") || $0 == "overloaded_error" }
        if !ev.codes.isDisjoint(with: unavailableModelCodes)
            || (!badKey && !throttledOrOverloaded && text.contains("no available channel")) { return .unavailableModel }
        let permissionDenied = status == 403 || text.contains("permission") || text.contains("无权")
        if permissionDenied, !badKey, matchesAny(text, groupDeniedPatterns) { return .groupDenied }
        if status == 402 { return .quota }
        // 短时窗口证据优先（每分钟 / retry in N s / RPM …）；「quota / 用量 / 额度」单独出现不算耗尽
        let rateSignal = status == 429 || (input.streamError != nil && !ev.codes.isDisjoint(with: rateCodes))
        let shortWindow = matchesAny(text, shortWindowPatterns) || ev.codes.contains("rate_limit_exceeded")
        if rateSignal, shortWindow { return .rateLimited(retryAfter: retryAfter(input.headers)) }
        if containsAny(text, billingWords) || containsAny(text, exhaustedWords) || !ev.codes.isDisjoint(with: billingCodes) { return .quota }
        if rateSignal { return .rateLimited(retryAfter: retryAfter(input.headers)) }
        if [408, 500, 502, 503, 504, 529].contains(status) { return .transient }
        if input.streamError != nil, !ev.codes.isDisjoint(with: transientTypes) { return .transient }
        if containsAny(text, filterWords) || !ev.codes.isDisjoint(with: filterCodes)
            || ((text.contains("invalid_prompt") || ev.codes.contains("invalid_prompt")) && text.contains("flagged")) {
            return .contentFiltered
        }
        if input.status == 0, input.urlErrorCode == NSURLErrorNetworkConnectionLost { return .connectionLost }
        return .other
    }

    /// 服务器明确拒了这一次（审查 #3）：预算扣 0，和重不重试、是不是最后一次无关。
    /// HTTP 408 / 429 / 5xx 带错误正文，或流内带明确的过载 / 限流 / 欠费类型；连接断开等处理状态不明的照估算记。
    /// 调用方还要保证没出字（出了字 = 已生成）
    static func isExplicitRejection(_ input: Input) -> Bool {
        let ev = parsed(input)
        let status = effectiveStatus(input, ev)
        // 402 / 403 带明确欠费码（含按 max_tokens 预扣的 insufficient_user_quota，R2）：没生成，同样扣 0
        let rejected = status == 408 || status == 429 || (500...599).contains(status)
            || ((status == 402 || status == 403) && !ev.codes.isDisjoint(with: billingCodes))
        guard input.streamError != nil else {
            return rejected && !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return rejected || !ev.codes.isDisjoint(with: transientTypes.union(rateCodes).union(billingCodes))
    }

    /// new-api 按 max_tokens 预扣额度：402 / 403 + insufficient_user_quota（R2）。上限给大了也会这样回，不一定真欠费
    static func isPrepaidQuota(_ input: Input) -> Bool {
        guard input.status == 402 || input.status == 403 else { return false }
        return parsed(input).codes.contains("insufficient_user_quota")
    }

    /// `retry-after-ms` 优先；`retry-after` 是秒数或 HTTP 日期；乱写 = nil；超大 / inf 封顶 retryAfterCap
    static func retryAfter(_ headers: [String: String], now: Date = Date()) -> TimeInterval? {
        if let ms = headers["retry-after-ms"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), let seconds = bounded(ms / 1000) {
            return seconds
        }
        guard let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return bounded(seconds) }
        guard let date = httpDate.date(from: value) else { return nil }
        return bounded(max(0, date.timeIntervalSince(now)))
    }

    /// 给人看的整秒数：不做不受保护的 Double → Int（inf / NaN / 超大值都落在 [1, retryAfterCap]）
    static func wholeSeconds(_ t: TimeInterval) -> Int {
        guard t.isFinite else { return Int(retryAfterCap) }
        return Int(min(max(t, 1), retryAfterCap).rounded(.up))
    }

    private static func bounded(_ seconds: Double) -> TimeInterval? {
        guard !seconds.isNaN, seconds >= 0 else { return nil }
        return min(seconds, retryAfterCap)
    }

    /// 这一次要不要自动重试、等多久（不含 429 的抖动）。retry = 已经重试过几次（Q6 / Q7）
    static func retryWait(_ kind: Kind, retry: Int) -> TimeInterval? {
        guard retry < maxRetries else { return nil }
        switch kind {
        case .transient:
            return [1, 3][retry]
        case .rateLimited(let after):
            guard let after else { return [2, 4][retry] }
            return after <= 8 ? after : nil
        case .connectionLost:
            return retry == 0 ? 1 : nil
        case .quota, .contextTooLong, .contentFiltered, .unavailableModel, .groupDenied, .other:
            return nil
        }
    }

    /// 重试中的小胶囊（§7.5）
    static func retryNotice(_ kind: Kind, wait: TimeInterval, retry: Int) -> String {
        let seconds = wholeSeconds(wait)
        switch kind {
        case .connectionLost:
            return "⏳ 连接断了，马上重试一次"
        case .rateLimited:
            return "⏳ 请求太频繁被限流了，\(seconds) 秒后自动重试（\(retry + 1)/\(maxRetries)）"
        default:
            return "⏳ 服务器有点忙，\(seconds) 秒后自动重试（\(retry + 1)/\(maxRetries)）"
        }
    }

    /// 最终失败时加在原文前的人话（没有 = nil）
    static func plainReason(_ kind: Kind, retried: Int, modelId: String = "") -> String? {
        switch kind {
        case .transient:
            return retried > 0 ? "服务器暂时出问题，已自动重试 \(retried) 次还是不行，过一会儿再发" : "服务器暂时出问题，过一会儿再发"
        case .rateLimited(let after):
            guard let after, after > 0 else { return "被限流了，过一会儿再发" }
            return "被限流了，大约 \(wholeSeconds(after)) 秒后再发"
        case .quota:
            return FixJump.quotaPhrase
        case .contextTooLong:
            return FixJump.contextTooLongPhrase + "。把预设里的「上下文深度」调小，或先压缩一下上下文"
        case .contentFiltered:
            return "这条内容被服务商的安全过滤拦下了"
        case .unavailableModel:
            return FixJump.unavailableModelMessage(modelId)
        case .groupDenied:
            return FixJump.groupDeniedPhrase
        case .connectionLost, .other:
            return nil
        }
    }

    // MARK: - 词表

    private static let contextPatterns = [
        "context_length_exceeded", "prompt is too long", "exceeds the context window", #"maximum context length is \d+"#,
        "input token count.*exceeds the maximum", #"maximum prompt length is \d+"#, "reduce the length of the messages",
        "exceeded model token limit", "model_context_window_exceeded", "context window exceeds limit",
        "range of input length should be", "input is too long for requested model", "token limit exceeded",
        "上下文长度超", "超出.{0,10}上下文", "输入.{0,6}过长",
    ]
    private static let contextCodes: Set<String> = ["context_length_exceeded", "model_context_window_exceeded"]
    private static let outputLimitWords = ["max_tokens", "max_completion_tokens", "max_output_tokens"]
    private static let throttleWords = ["rate limit", "per minute", "tpm", "rpm", "please wait", "try again later", "频繁"]
    /// 短时窗口证据：有它就是限流，哪怕同时提到 quota / 用量（审查 #4）
    private static let shortWindowPatterns = [
        "per minute", #"per min\b"#, "每分钟", #"\btpm\b"#, #"\brpm\b"#, "rate_limit_exceeded", "频繁",
        #"(retry|try again) in \d+(\.\d+)?\s*(ms|s\b|sec|second)"#,
    ]
    /// 明确欠费 / 余额不足
    private static let billingWords = [
        "insufficient_quota", "insufficient balance", "exceeded your current quota", "exceeded_current_quota",
        "credit", "billing", "payment required", "余额不足", "欠费", "账户余额",
    ]
    private static let billingCodes: Set<String> = ["insufficient_quota", "exceeded_current_quota", "insufficient_balance", "billing_hard_limit_reached",
                                                    "insufficient_user_quota"]
    /// 明确用完（日 / 周 / 套餐上限）；「quota / 用量 / 额度」单独出现不算
    private static let exhaustedWords = [
        "daily limit", "weekly limit", "monthly limit", "daily quota", "weekly quota", "usage limit",
        "用完", "用尽", "耗尽",
    ]
    private static let unavailableModelCodes: Set<String> = ["model_not_found", "get_channel_failed"]
    private static let authCodes: Set<String> = ["authentication_error", "invalid_api_key"]
    private static let badKeyWords = ["invalid api key", "invalid_api_key", "incorrect api key", "invalid token", "无效的令牌", "令牌无效"]
    /// 「无权访问 Claude_官api 分组」/「group xx is not allowed」：点名分组 + 无权
    private static let groupDeniedPatterns = [
        "无权.{0,20}分组", "分组.{0,20}(无权|没有权限|不允许)",
        #"\bgroup\b.{0,40}(not allowed|no permission|not permitted|access denied|forbidden|unauthorized)"#,
        #"(not allowed|no permission|not permitted|access denied|unauthorized).{0,40}\bgroup\b"#,
    ]
    private static let rateCodes: Set<String> = ["rate_limit_error", "rate_limit_exceeded"]
    private static let transientTypes: Set<String> = ["overloaded_error", "api_error", "server_error", "service_unavailable"]
    private static let filterWords = ["content_policy_violation", "content_filter", "responsibleaipolicyviolation", "data_inspection_failed", "敏感"]
    private static let filterCodes: Set<String> = ["content_policy_violation", "content_filter", "responsibleaipolicyviolation", "data_inspection_failed"]

    private static func containsAny(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    private static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// 先解码再匹配（审查 #6）：说话的字段（message / detail …，\u 转义已还原）拼成小写正文；type / code 字符串单独放
    private struct Parsed {
        var text: String
        var codes: Set<String>
        /// 流内 `error.code` 是数字、且没有字符串 type（结构化类型优先，审查 #8）
        var numericCode: Int?
    }

    private static func parsed(_ input: Input) -> Parsed {
        let ev = ParamErrorClassifier.evidence(input.streamError ?? input.body)
        var codes = Set<String>()
        for obj in ev.objects {
            for key in ["type", "code"] {
                if let s = obj[key] as? String { codes.insert(s.lowercased()) }
            }
        }
        var numeric: Int?
        if input.streamError != nil, let first = ev.objects.first {
            let err = first["error"] as? [String: Any] ?? first
            if !(err["type"] is String), let code = err["code"] as? Int { numeric = code }
        }
        return Parsed(text: ev.texts.joined(separator: "\n").lowercased(), codes: codes, numericCode: numeric)
    }

    /// OpenRouter 流内 code 是数字 = 上游状态码；别的端点的数字码是业务码，不当状态
    private static func effectiveStatus(_ input: Input, _ ev: Parsed) -> Int {
        if input.host == .openrouter, input.streamError != nil, input.status == 200 || input.status == 0, let code = ev.numericCode {
            return code
        }
        return input.status
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}
