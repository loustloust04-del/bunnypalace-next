import Foundation

/// 认 400 / 422 报错里点名的参数（#094 plan-param-autoadapt §3.4，抄 magpie gateway.go `refusedOptional` / `unsupportedOptionalField`）。
/// 只认这次真发了的字段；结构化优先（`param` + `code`、`extra_forbidden` + `loc`、`metadata.raw` / 文字里嵌的上游 JSON），再用文字兜。
enum ParamErrorClassifier {
    enum Fix: Hashable {
        /// 采样组整组不发（temperature / top_p / top_k / 两种 penalty，Q1）
        case dropSampling
        /// 不发某一组（ParamCompat.Group：seed / stream_options / reasoning / output_config）
        case drop(String)
        /// 输出上限换键名（max_tokens ↔ max_completion_tokens）
        case renameMaxTokens(to: String)
        /// 输出上限太大 → 降到 8192（原 R8）
        case lowerOutputCap
        /// Anthropic 思考换格式：adaptive / budget
        case thinkingFormat(String)
        /// temperature 和 top_p 只收一个：去掉 top_p（「cannot both be specified」，不是不收，所以不整组去）
        case singleSampler
        /// 要求发某一组（目前只有工具续轮回传思考：DeepSeek「must be passed back」，plan-model-compat-p0 §5.2）
        case require(String)
        /// 「max_tokens must be greater than thinking.budget_tokens」：不降上限，这一次把思考压到最低档重发（中转 R4，不学）
        case fitThinkingBudget

        var isRename: Bool {
            if case .renameMaxTokens = self { return true }
            return false
        }
    }

    enum Verdict: Equatable {
        case fix([Fix])
        /// 认出来了但不该自动改（值不对 / 预填）：说人话，不重试
        case explain(String)
        /// 当轮回传的思考块被拒（签名坏 / 被改过，plan-thinking §3.6）：不学、不记，这一次去掉思考块重发一次
        case thinkingBlocksRejected
        case unknown
    }

    /// 这次实发 body 的形状：顶层键 + 说人话要用的几个值
    struct SentShape: Equatable {
        var keys: Set<String> = []
        var thinkingType: String?
        /// 发了 `thinking.display` 的值（summarized）
        var thinkingDisplay: String?
        var thinkingBudget: Int?
        /// 实发的输出上限（max_tokens / max_completion_tokens，Anthropic 含思考余量，R2）
        var sentMaxTokens: Int?
        var values: [String: String] = [:]
        /// 这次有没有在 assistant 消息里回传思考（reasoning_content / reasoning / reasoning_text / reasoning_details）
        var sentReasoningReplay = false

        /// 这次发了思考预算或思考档（压一档能管用）；都没发 = 中转按模型名自己开的思考
        var sendsThinkingLevel: Bool {
            thinkingBudget != nil || ParamErrorClassifier.reasoningFields.contains { values[$0] != nil }
        }

        /// 发了任何思考参数（thinking / reasoning_effort / reasoning / output_config），哪怕只是 `thinking: adaptive` 没带档（R4）
        var sendsAnyThinking: Bool {
            keys.contains("thinking") || ParamErrorClassifier.reasoningFields.contains { keys.contains($0) }
        }

        init() {}

        init(body: [String: Any]) {
            keys = Set(body.keys)
            thinkingType = (body["thinking"] as? [String: Any])?["type"] as? String
            thinkingDisplay = (body["thinking"] as? [String: Any])?["display"] as? String
            thinkingBudget = (body["thinking"] as? [String: Any])?["budget_tokens"] as? Int
            sentMaxTokens = body["max_tokens"] as? Int ?? body["max_completion_tokens"] as? Int
            for k in ParamErrorClassifier.samplingFields + ["seed", "reasoning_effort"] {
                if let v = body[k] { values[k] = "\(v)" }
            }
            if let effort = (body["reasoning"] as? [String: Any])?["effort"] as? String { values["reasoning"] = effort }
            if let effort = (body["output_config"] as? [String: Any])?["effort"] as? String { values["output_config"] = effort }
            sentReasoningReplay = (body["messages"] as? [[String: Any]] ?? []).contains { message in
                message["role"] as? String == "assistant" && ReasoningCapture.replayFields.contains { message[$0] != nil }
            }
        }
    }

    static let samplingFields = ["temperature", "top_p", "top_k", "frequency_penalty", "presence_penalty"]
    static let reasoningFields = ["reasoning_effort", "reasoning", "output_config"]
    static let limitFields = ["max_tokens", "max_completion_tokens"]
    static let knownFields = samplingFields + ["seed", "stream_options", "thinking"] + reasoningFields + limitFields

    static func isParamRejection(status: Int) -> Bool { status == 400 || status == 422 }

    static func classify(status: Int, body: String, sent: SentShape, host: String) -> Verdict {
        guard isParamRejection(status: status) else { return .unknown }
        let ev = evidence(body)
        let unmasks = ev.texts.map { unmask($0.lowercased(), sent: sent) }
        let texts = unmasks.map(\.text)
        /// 有打码路径认不准是哪条（R3）：文字推出来的改法只说人话、不学
        let maskedUnsure = unmasks.lazy.compactMap(\.unresolved).first
        // thinking 回传 §3.6：思考块被拒 / 只是不认 thinking.display（不能落到下面「thinking 不收 → 整个关思考」）
        if texts.contains(where: rejectsThinkingBlocks) { return .thinkingBlocksRejected }
        // 工具续轮回传思考 §5.2：没回传、被要求回传 → 学会回传（回传过还报就不是这个能治的）
        if !sent.sentReasoningReplay, texts.contains(where: demandsReasoningReplay) {
            return .fix([.require(ParamCompat.Group.reasoningReplay)])
        }
        if sent.thinkingDisplay != nil, texts.contains(where: rejectsThinkingDisplay)
            || ev.objects.contains(where: namesThinkingDisplay) {
            return .fix([.drop(ParamCompat.Group.thinkingDisplay)])
        }
        var unsupported: Set<String> = []
        var valueWrong: Set<String> = []
        /// 结构化数据点过名的字段：文字兜底不再改它们的结论（astra #4）
        var structured: Set<String> = []
        // 采样参数的 unsupported_value 只有明说「只收默认值」才算不收（去掉就对）；其余是值不对，说人话不学
        let onlyDefault = texts.contains { $0.contains("only the default") || $0.contains("only default") }
        var rejectsReasoningReplay = false
        /// 结构化数据（param / loc / extra_forbidden）点过名：打码认不准也照改
        var structuredHit = false

        // 结构化
        for obj in ev.objects {
            let code = (obj["code"] as? String)?.lowercased()
            if let raw = (obj["param"] as? String)?.lowercased(),
               let param = raw.split(separator: ".").first.map(String.init), sent.keys.contains(param) {
                if code == "unsupported_parameter" {
                    unsupported.insert(param)
                    structured.insert(param)
                } else if code == "unsupported_value" {
                    if samplingFields.contains(param), onlyDefault { unsupported.insert(param) } else { valueWrong.insert(param) }
                    structured.insert(param)
                }
            }
            if sent.sentReasoningReplay, (obj["type"] as? String)?.lowercased() == "extra_forbidden", namesReasoningReplay(obj) {
                rejectsReasoningReplay = true
                structuredHit = true
            }
            if let loc = obj["loc"] as? [Any], loc.count >= 2, loc.first as? String == "body",
               let field = (loc[1] as? String)?.lowercased(), sent.keys.contains(field) {
                if (obj["type"] as? String)?.lowercased() == "extra_forbidden" { unsupported.insert(field) } else { valueWrong.insert(field) }
                structured.insert(field)
            }
        }

        // 文字点名消息里回传的思考字段（Mistral 那类，§5.2）
        if sent.sentReasoningReplay, texts.contains(where: refusesReplayedReasoning) { rejectsReasoningReplay = true }

        // 文字（只补结构化没说到的字段）
        for field in knownFields where sent.keys.contains(field) && !structured.contains(field) {
            // 「messages.N.reasoning」说的是消息里回传的思考，不是顶层推理强度
            for text in texts where !(field == "reasoning" && namesMessageReasoning(text)) {
                if matchesUnsupported(field, in: text) {
                    // 拒的是这次发的那个值（「'none' is not supported」/「does not support 0.7」）：值不对，说人话（Q10）；
                    // 采样参数明说只收默认值除外——去掉就对
                    let isSampling = samplingFields.contains(field)
                    if let v = sent.values[field], mentionsValue(v, in: text), !(isSampling && onlyDefault) {
                        valueWrong.insert(field)
                    } else {
                        unsupported.insert(field)
                    }
                } else if matchesValueProblem(field, in: text) {
                    valueWrong.insert(field)
                }
            }
        }
        var fixes: [Fix] = []
        if rejectsReasoningReplay { fixes.append(.drop(ParamCompat.Group.reasoningReplay)) }
        // 「temperature 和 top_p 不能同时给」：两个都真发了才认；只去 top_p，不当成采样组不收
        if sent.keys.contains("temperature"), sent.keys.contains("top_p"), texts.contains(where: saysOnlyOneSampler) {
            fixes.append(.singleSampler)
            unsupported.subtract(["temperature", "top_p"])
            valueWrong.subtract(["temperature", "top_p"])
        }
        valueWrong.subtract(unsupported)
        // 思考预算比上限大：说的是预算，不是上限太大（降上限方向反了，R4）
        let aboutBudget = texts.contains(where: mentionsThinkingBudget)
        if aboutBudget { valueWrong.subtract(limitFields) }

        // 思考格式（Anthropic）。预填的报错（「prefill is not supported with adaptive thinking」）不是在说思考格式，交给后面说人话（astra #3）
        let aboutPrefill = texts.contains { $0.contains("prefill") }
        if sent.keys.contains("thinking"), !aboutPrefill {
            let saysAdaptive = texts.contains { $0.contains("adaptive") }
            if sent.thinkingType == "enabled", saysAdaptive {
                fixes.append(.thinkingFormat("adaptive"))
            } else if sent.thinkingType == "adaptive", texts.contains(where: rejectsAdaptiveType) {
                fixes.append(.thinkingFormat("budget"))
            } else if unsupported.contains("thinking") {
                fixes.append(.drop(ParamCompat.Group.reasoning))
            }
        }
        if !unsupported.isDisjoint(with: samplingFields) { fixes.append(.dropSampling) }
        if unsupported.contains("seed") { fixes.append(.drop(ParamCompat.Group.seed)) }
        if unsupported.contains("stream_options") { fixes.append(.drop(ParamCompat.Group.streamOptions)) }
        if unsupported.contains("reasoning_effort") || unsupported.contains("reasoning") {
            fixes.append(.drop(ParamCompat.Group.reasoning))
        }
        if unsupported.contains("output_config"), !fixes.contains(.thinkingFormat("budget")) {
            fixes.append(.drop(ParamCompat.Group.outputConfig))
        }
        // 输出上限：键名不对 → 改名；数太大 → 降 8192
        let renamed: Fix?
        if sent.keys.contains("max_tokens"),
           unsupported.contains("max_tokens") || texts.contains(where: { $0.contains("use 'max_completion_tokens'") || $0.contains("use max_completion_tokens") }) {
            renamed = .renameMaxTokens(to: "max_completion_tokens")
        } else if sent.keys.contains("max_completion_tokens"), unsupported.contains("max_completion_tokens") {
            renamed = .renameMaxTokens(to: "max_tokens")
        } else {
            renamed = nil
        }
        if let renamed {
            fixes.append(renamed)
        } else if aboutBudget {
            if sent.sendsThinkingLevel { fixes.append(.fitThinkingBudget) }
        } else if !valueWrong.isDisjoint(with: limitFields) || texts.contains(where: mentionsLimitTooLarge) {
            fixes.append(.lowerOutputCap)
        }
        var seen: Set<Fix> = []
        fixes = fixes.filter { seen.insert($0).inserted }
        if !fixes.isEmpty {
            if let token = maskedUnsure, !structuredHit, structured.isEmpty { return .explain(FixJump.maskedParamMessage(token)) }
            return .fix(fixes)
        }

        if aboutBudget { return .explain(FixJump.thinkingBudgetMessage(sentThinking: sent.sendsAnyThinking)) }
        if texts.contains(where: { $0.contains("prefill") }) {
            return .explain("这个模型\(FixJump.prefillPhrase)（预设里深度 0 的 assistant 段 / 续写预填），去预设里关掉")
        }
        let who = host.isEmpty ? "这个接口" : host
        for field in reasoningFields where valueWrong.contains(field) {
            let level = sent.values[field].map { ReasoningEffort.label($0) } ?? "现在这档"
            return .explain("\(who) 上的这个模型\(FixJump.reasoningPhrase)「\(level)」，换一档")
        }
        for field in samplingFields + ["seed"] where valueWrong.contains(field) {
            let value = sent.values[field].map { "（\($0)）" } ?? ""
            return .explain("\(who) \(FixJump.samplingPrefix)\(field) \(FixJump.samplingSuffix)\(value)")
        }
        return .unknown
    }

    // MARK: - 文字规则

    /// 明确在拒「thinking.type = adaptive」这个值：点名 thinking.type，且要么说 adaptive 不支持 / 无效，要么列出只收 enabled / disabled
    static func rejectsAdaptiveType(_ text: String) -> Bool {
        guard text.contains("thinking.type") || text.contains("thinking: input tag") else { return false }
        let namesAdaptive = text.range(of: #"adaptive.{0,40}("# + (rejectionWords + ["invalid", "does not match"]).joined(separator: "|") + ")",
                                       options: .regularExpression) != nil
        let listsEnabled = text.contains("'enabled'") || text.contains("\"enabled\"") || text.contains("`enabled`")
        return namesAdaptive || (listsEnabled && !text.contains("'adaptive'") && !text.contains("\"adaptive\""))
    }

    /// 「messages.1.content.0: thinking blocks cannot be modified…」/「Invalid `signature` in `thinking` block」（后者是文档原文）
    static func rejectsThinkingBlocks(_ text: String) -> Bool {
        if text.contains("thinking") && text.contains("block") && text.contains("cannot be modified") { return true }
        return text.contains("signature") && text.contains("thinking") && (text.contains("invalid") || text.contains("signature verification"))
    }

    /// DeepSeek #388：「The reasoning_content in the thinking mode must be passed back to the API」（magpie；reasoning_text 也见过）
    static func demandsReasoningReplay(_ text: String) -> Bool {
        text.contains("reasoning") && text.contains("must be passed back")
    }

    /// 文字点名消息里回传的思考字段 + 拒收词：「Unknown field: reasoning_content」/「Extra inputs are not permitted: reasoning_details」。
    /// 光秃秃的 `reasoning` 和顶层推理强度同名，只认带 messages 路径的（「messages.2.reasoning: Extra inputs are not permitted」）
    static func refusesReplayedReasoning(_ text: String) -> Bool {
        let refuses = { (field: String) in
            matchesUnsupported(field, in: text) || (text.contains(field) && text.contains("extra inputs are not permitted"))
        }
        if ["reasoning_content", "reasoning_details", "reasoning_text"].contains(where: refuses) { return true }
        return namesMessageReasoning(text) && refuses("reasoning")
    }

    /// 「messages.2.reasoning」/「messages[2].reasoning」：后面不跟 _（reasoning_content 那些另算）
    private static func namesMessageReasoning(_ text: String) -> Bool {
        text.range(of: #"messages(\.|\[)\s*\d+\]?\.reasoning\b"#, options: .regularExpression) != nil
    }

    /// 结构化点名回传的思考字段：`loc: [body, messages, N, reasoning_content]`（FastAPI / Mistral 422）
    private static func namesReasoningReplay(_ obj: [String: Any]) -> Bool {
        guard let loc = obj["loc"] as? [Any], loc.count >= 4, loc[0] as? String == "body",
              (loc[1] as? String)?.lowercased() == "messages", let field = (loc[3] as? String)?.lowercased() else { return false }
        return ReasoningCapture.replayFields.contains(field)
    }

    /// 点名 thinking.display 不收（「thinking.display: Extra inputs are not permitted」/「unknown field display」，措辞是推断）
    static func rejectsThinkingDisplay(_ text: String) -> Bool {
        if text.contains("thinking.display") { return true }
        return text.contains("display") && (matchesUnsupported("display", in: text) || text.contains("extra inputs"))
    }

    /// 结构化点名：`param: thinking.display` / `loc: [body, thinking, display]`
    private static func namesThinkingDisplay(_ obj: [String: Any]) -> Bool {
        if (obj["param"] as? String)?.lowercased() == "thinking.display" { return true }
        guard let loc = obj["loc"] as? [Any], loc.count >= 3 else { return false }
        return (loc[1] as? String)?.lowercased() == "thinking" && (loc[2] as? String)?.lowercased() == "display"
    }

    /// `stop_reason: refusal` 的 `stop_details.category` 说人话（plan-thinking §3.6 / Q8）；别的类别不出提示
    static func refusalNotice(category: String?) -> String? {
        guard category == "reasoning_extraction" else { return nil }
        return "模型拒绝在正文里写出内部推理（reasoning_extraction）。人设 / 预设里要求把思考写进正文的那段可能触发了它"
    }

    /// `temperature` and `top_p` cannot both be specified for this model. Please use only one.
    static func saysOnlyOneSampler(_ text: String) -> Bool {
        guard text.contains("temperature"), text.contains("top_p") else { return false }
        return matchesAny(text, ["cannot both be specified", "can't both be specified", "cannot be specified together",
                                 "cannot be used together", "mutually exclusive", "use only one", "only one of"])
    }

    static let rejectionWords = ["deprecated", "not supported", "unsupported", "does not support", "not permitted",
                                 "not allowed", "no longer supported", "unknown", "unrecognized", "not available"]

    private static func matchesAny(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    /// magpie 三条（unknown name / unsupported parameter / 'x' is not supported）+ 「字段 40 字内跟着拒收词」+ 「Unrecognized request argument supplied: x」
    static func matchesUnsupported(_ field: String, in text: String) -> Bool {
        let f = NSRegularExpression.escapedPattern(for: field)
        let q = #"[\s"'`\\:]*"#
        let patterns = [
            #"unknown (name|field|parameter|argument)s?"# + q + f + #"\b"#,
            #"unsupported (parameter|argument|field)s?"# + q + f + #"\b"#,
            #"unrecognized (request )?(argument|parameter|field)s?( supplied)?"# + q + f + #"\b"#,
            #"\b"# + f + #"\b.{0,40}("# + rejectionWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")",
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// 字段 40 字内跟着「范围 / 必须 / 应当 …」：值不对（Q10 / §3.7）
    static func matchesValueProblem(_ field: String, in text: String) -> Bool {
        let f = NSRegularExpression.escapedPattern(for: field)
        let pattern = #"\b"# + f + #"\b.{0,40}(range|less than|greater than|must be|should be|between|invalid value|out of range|exceed)"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// 报错里带着这次发的那一档（带引号，或「does not support none」「none is not supported」这种不带引号的）
    private static func mentionsValue(_ value: String, in text: String) -> Bool {
        let v = value.lowercased()
        if text.contains("'\(v)'") || text.contains("\"\(v)\"") || text.contains("`\(v)`") { return true }
        let e = NSRegularExpression.escapedPattern(for: v)
        return text.range(of: #"support(s|ed)?\s+"# + e + #"\b|\b"# + e + #"\s+is\s+not\s+supported"#, options: .regularExpression) != nil
    }

    /// 「`max_tokens` must be greater than `thinking.budget_tokens`」：中转改了上限 / 自己按模型名开了思考
    static func mentionsThinkingBudget(_ text: String) -> Bool {
        text.contains("budget_tokens")
    }

    /// 上限太大：`max_tokens is too large` / exceeds / at most / maximum …
    static func mentionsLimitTooLarge(_ text: String) -> Bool {
        guard limitFields.contains(where: { text.contains($0) }) || text.contains("max_output_tokens") else { return false }
        return matchesAny(text, ["too large", "exceed", "at most", "maximum", "less than or equal", "greater than"])
    }

    // MARK: - 去打码（R3）

    /// new-api 会把像域名的点路径打码：`thinking.type.enabled` → `***.***.enabled`（一段一个 ***，段数照留）。
    /// 已知路径 + 几条同形状的「诱饵」（只为判唯一，不还原成它们）
    static let maskablePaths = [
        "thinking.type.adaptive", "thinking.type.enabled", "thinking.type.disabled", "thinking.type", "thinking.display",
        "messages.0.reasoning_content", "messages.0.reasoning_details", "messages.0.reasoning_text", "messages.0.reasoning",
    ]
    private static let maskDecoys = ["tool_choice.type", "response_format.type"]

    /// 只在能唯一定位时还原：段数一样、露出来的段逐个对上（数字段当下标）、前面不是更长路径的一截、
    /// 路径的根这次真发了（sent 给了才查：thinking → 发了 thinking，messages → 回传了思考）、诱饵也算候选且只剩一条。
    /// 网址里的打码（`https://***.com/…`）不管；其余认不准的打码路径原样留着，第一个记进 unresolved
    static func unmask(_ text: String, sent: SentShape? = nil) -> (text: String, unresolved: String?) {
        guard text.contains("***."), let re = try? NSRegularExpression(pattern: #"(?:\*{3}\.)+[a-z0-9_]+(?:\.[a-z0-9_]+)*"#) else { return (text, nil) }
        var out = text
        var unresolved: String?
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let before = range.lowerBound > out.startIndex ? out[out.index(before: range.lowerBound)] : " "
            let after = range.upperBound < out.endIndex ? out[range.upperBound] : " "
            if "/@:".contains(before) || after == "/" { continue }
            let token = String(out[range])
            let segs = token.split(separator: ".").map(String.init)
            let fits = { (known: [String]) in
                known.count == segs.count && zip(known, segs).allSatisfy { k, t in
                    t == "***" || k == t || (k == "0" && t.allSatisfy(\.isNumber))
                }
            }
            let rootSent = { (root: String) in
                guard let sent else { return true }
                return root == "messages" ? sent.sentReasoningReplay : sent.keys.contains(root)
            }
            let candidates = (maskablePaths + maskDecoys).map { $0.split(separator: ".").map(String.init) }
                .filter { fits($0) && rootSent($0[0]) }
            guard !(before.isLetter || before.isNumber || before == "_" || before == "."),
                  candidates.count == 1, let path = candidates.first, maskablePaths.contains(path.joined(separator: ".")) else {
                unresolved = token
                continue
            }
            out.replaceSubrange(range, with: zip(path, segs).map { k, t in t == "***" ? k : t }.joined(separator: "."))
        }
        return (out, unresolved)
    }

    static func unmasked(_ text: String, sent: SentShape? = nil) -> String { unmask(text, sent: sent).text }

    // MARK: - 取证据：递归解 JSON（字典 / 数组 / 字符串里嵌的 JSON）

    struct Evidence {
        var texts: [String] = []
        var objects: [[String: Any]] = []
    }

    static func evidence(_ raw: String) -> Evidence {
        var ev = Evidence()
        collect(string: raw, into: &ev, depth: 0)
        return ev
    }

    private static func collect(string: String, into ev: inout Evidence, depth: Int) {
        guard depth < 8 else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "{" || first == "[", let value = parseJSON(trimmed) {
            collect(value: value, into: &ev, depth: depth + 1)
            return
        }
        guard !trimmed.isEmpty else { return }
        ev.texts.append(trimmed)
        // 中转常把上游 JSON 嵌在文字里：`upstream error: {...} (request id: …)`
        if let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }), let value = parseJSON(String(trimmed[start...])) {
            collect(value: value, into: &ev, depth: depth + 1)
        }
    }

    private static func collect(value: Any, into ev: inout Evidence, depth: Int) {
        guard depth < 8 else { return }
        if let dict = value as? [String: Any] {
            ev.objects.append(dict)
            for key in dict.keys.sorted() {
                guard let v = dict[key] else { continue }
                if let s = v as? String {
                    // 只看说话的字段；type / code 这类枚举值不当文字（防误命中）
                    if ["message", "msg", "detail", "description", "raw", "error", "error_message"].contains(key) {
                        collect(string: s, into: &ev, depth: depth + 1)
                    }
                } else {
                    collect(value: v, into: &ev, depth: depth + 1)
                }
            }
        } else if let array = value as? [Any] {
            for v in array {
                if let s = v as? String { collect(string: s, into: &ev, depth: depth + 1) } else { collect(value: v, into: &ev, depth: depth + 1) }
            }
        }
    }

    private static func parseJSON(_ s: String) -> Any? {
        if let v = try? JSONSerialization.jsonObject(with: Data(s.utf8)) { return v }
        // 尾巴带了文字：截到最后一个同类收括号再试
        let close: Character
        switch s.first {
        case "{": close = "}"
        case "[": close = "]"
        default: return nil
        }
        guard let end = s.lastIndex(of: close) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(s[...end].utf8))
    }

    // MARK: - 脱敏（astra #2）

    /// 分类可以看原文；给人看 / 进日志 / 落盘的一律走这份：这次实际发出去的秘密（key、认证类请求头的值；原文 + JSON 转义形式）换成 `<API key>`，
    /// 文字里的 URL 去掉 query 和 userinfo（中转常把带 `?key=` 的上游地址回显在 metadata.raw 里），
    /// 正文里回显的认证头结构（Authorization / x-api-key / Cookie… 后面的值、Bearer 令牌）也去掉
    static func redacted(_ text: String, secrets: [String]) -> String {
        var out = SentRequestStore.redact(text, secrets: secrets)
        let pattern = #"(https?:(?:\\?/){2})(?:[^\s"'<>/\\@]+@)?([^\s"'<>?#]*)(?:\?[^\s"'<>#\\]*)?"#
        for (pattern, template) in [(pattern, "$1$2"), (authHeaderPattern, "$1$2<已隐去>"), (bearerPattern, "$1 <已隐去>")] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    private static let authHeaderPattern = #"((?:proxy-)?authorization|x-api-key|api[-_]key|x-goog-api-key|x-auth-token|set-cookie|cookie)(\\?["']?\s*[:=]\s*\\?["']?)[^"'\\\r\n]+"#
    private static let bearerPattern = #"\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#

    /// 统一错误出口的秘密清单：key + 实际发出去的认证类请求头的值（自定义认证头、Cookie 等；Bearer 后面那段、Cookie 每个值也单独算）
    static func secrets(apiKey: String, headers: [String: String]) -> [String] {
        [apiKey] + headerSecrets(headers)
    }

    static func headerSecrets(_ headers: [String: String]) -> [String] {
        let words = ["auth", "key", "token", "cookie", "secret", "session", "signature", "password", "credential"]
        var out: [String] = []
        for (name, raw) in headers where words.contains(where: name.lowercased().contains) {
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard value.count >= SecretVault.minScrubLength else { continue }
            out.append(value)
            if let r = value.range(of: #"^(bearer|basic|token)\s+"#, options: [.regularExpression, .caseInsensitive]) {
                out.append(String(value[r.upperBound...]))
            }
            for part in value.split(separator: ";") {
                guard let eq = part.firstIndex(of: "=") else { continue }
                out.append(part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return out.filter { $0.count >= SecretVault.minScrubLength }
    }

    // MARK: - 说人话

    /// 聊天里的小灰字：「这个模型不收 temperature / top_p，已自动去掉」/「这个接口要用 max_completion_tokens，已自动改」
    static func notice(_ fixes: [Fix]) -> String? {
        var drops: [String] = []
        var changes: [String] = []
        for fix in fixes {
            switch fix {
            case .dropSampling: drops.append("temperature / top_p")
            case .drop(let group): drops.append(ParamCompat.groupLabel(group))
            case .renameMaxTokens(let key): changes.append("要用 \(key)")
            case .thinkingFormat(let format): changes.append(format == "adaptive" ? "思考要用 adaptive 格式" : "思考要用 budget_tokens 格式")
            case .singleSampler: changes.append("temperature 和 top_p 只收一个（去掉了 top_p）")
            case .require: changes.append("要在工具续轮回传思考")
            case .lowerOutputCap, .fitThinkingBudget: continue
            }
        }
        if fixes.filter({ $0 != .lowerOutputCap && $0 != .fitThinkingBudget }) == [.singleSampler] {
            return "这个模型 temperature 和 top_p 只收一个，已去掉 top_p"
        }
        if changes.isEmpty, !drops.isEmpty { return "这个模型不收 \(drops.joined(separator: "、"))，已自动去掉" }
        if drops.isEmpty, changes.count == 1, fixes.contains(where: \.isRename) {
            return "这个接口\(changes[0])，已自动改"
        }
        let parts = drops.map { "不收 \($0)" } + changes
        return parts.isEmpty ? nil : "这个模型" + parts.joined(separator: "、") + "，已自动调整"
    }

    /// 要记进记忆表的部分（降上限不记，和原 R8 一样只管这一次）
    static func learned(from fixes: [Fix]) -> ParamCompat.Learned {
        var learned = ParamCompat.Learned()
        for fix in fixes {
            switch fix {
            case .dropSampling: learned.groups.insert(ParamCompat.Group.sampling)
            case .drop(let group): learned.groups.insert(group)
            case .renameMaxTokens(let key): learned.maxTokensKey = key
            case .thinkingFormat(let format): learned.thinkingFormat = format
            case .singleSampler: learned.groups.insert(ParamCompat.Group.singleSampler)
            case .require(let group) where group == ParamCompat.Group.reasoningReplay:
                learned.groups.insert(ParamCompat.Group.reasoningReplayRequired)
            case .require, .lowerOutputCap, .fitThinkingBudget: continue
            }
        }
        return learned
    }
}
