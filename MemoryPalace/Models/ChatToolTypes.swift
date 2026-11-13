import Foundation

/// 文件库工具循环用的结构化块。只在带工具的对话里出现，纯聊天路径不碰这些类型。

/// 模型本轮发起的一次工具调用。
struct ToolCallBlock {
    let id: String
    let name: String
    /// 原始 JSON 字符串（流式拼接得到）；审批卡上改过命令时换成改过的（粟粟 10-03）
    var argumentsJSON: String
    /// 输出上限截断时最后一个调用写到一半（plan-output-token-cap 2-1）：不执行，回灌说明
    var truncated = false
}

extension Array where Element == ToolCallBlock {
    /// 生成是顺序的，截断只可能落在最后一个调用上
    func markingLastTruncated(_ hit: Bool) -> [ToolCallBlock] {
        guard hit, !isEmpty else { return self }
        var calls = self
        calls[calls.count - 1].truncated = true
        return calls
    }
}

/// app 执行工具后的结果，回灌给模型。
struct ToolResultBlock {
    let toolUseId: String
    let text: String
    let isError: Bool
}

/// 一个工具回合：模型本轮的 tool_use(s) + app 执行后的 result(s)。
/// 按发生顺序追加在原始 messages 之后喂给下一轮请求（保持 use→result 严格配对）。
struct ToolTurn {
    let calls: [ToolCallBlock]
    var results: [ToolResultBlock]
    /// thinking 回传（plan-thinking §3.3）：这一次回复的全部内容块原样（思考 / redacted / 正文 / server 块 / tool_use）。
    /// nil = 只发 tool_use（OpenAI 兼容、老调用点、测试夹具）
    var assistantContent: [[String: Any]]? = nil
    /// 那一次回复的 thinking_tokens（usage.output_tokens_details）：回传时按输入计，保险闸估钱用；不知道 = nil
    var thinkingTokens: Int? = nil
    /// OpenAI 兼容路那一次回复的思考（plan-model-compat-p0 §5）：开关开时按来源字段名回传
    var reasoning: ReasoningCapture? = nil
    /// 这一轮跟着工具调用一起说的正文（种子 checkpoint 存下来原样回灌；主聊天不填 = 老形状）
    var text: String? = nil
    /// 回执之后、下一个工具回合之前：模型只回了字（没调工具）和随后补的提醒，按顺序接在回执后面（C3 整理 / 种子用；主聊天不填）
    var followUps: [ToolFollowUp] = []
    /// 这个回合最后一条回执上已经接过一条收尾提醒（CatalogAgent.remind 的 reply = nil 路径）：再来一条不再叠
    var reminded = false

    /// 去掉当轮的思考 / redacted 块（预算收尾 tools 变了、思考块被拒重发那一次）。
    /// thinkingTokens 跟着清掉（不回传就不按输入计，同改前）；reasoning 不去：DeepSeek 预算收尾那次照样要回传
    func droppingThinking() -> ToolTurn {
        guard let content = assistantContent else { return self }
        var turn = self
        turn.assistantContent = content.filter { !ReplyBlock.isThinking($0) }
        turn.thinkingTokens = nil
        return turn
    }

    var thinkingBlockCount: Int { assistantContent?.filter(ReplyBlock.isThinking).count ?? 0 }
}

/// 工具回合之后的一来一回：assistant = 模型那段纯文字回复（原样；空 = 没说话，只发提醒），user = app 补的提醒
struct ToolFollowUp: Equatable {
    var reply: String
    var note: String

    /// 这段回复要不要发成一条 assistant 消息（空白不发：Anthropic 不收空 text 块）
    var hasReply: Bool { !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Anthropic 一次回复里的一个内容块，原样（JSON 对象，plan-thinking §3.1）。
/// complete = 收到 content_block_stop（思考块还要有签名）；不完整的只拿来显示，绝不回传
struct ReplyBlock {
    var raw: [String: Any]
    var complete: Bool

    var type: String { raw["type"] as? String ?? "" }

    static func isThinking(_ raw: [String: Any]) -> Bool {
        let type = raw["type"] as? String
        return type == "thinking" || type == "redacted_thinking"
    }
}

extension Array where Element == ReplyBlock {
    /// 回传给下一次请求的块：只要完整的；空正文块去掉（API 不收空 text）。没有块 = nil（走只发 tool_use）
    var wireContent: [[String: Any]]? {
        let blocks = filter { $0.complete }.map(\.raw).filter { raw in
            !(raw["type"] as? String == "text" && (raw["text"] as? String ?? "").isEmpty)
        }
        return blocks.isEmpty ? nil : blocks
    }

    /// 思考块 → 存进节点的段（顺序照回复）。不完整的思考块只留文字、签名 nil；redacted 存 data
    var thinkingSegments: [MessageSegment] {
        compactMap { $0.thinkingSegment }
    }
}

extension ReplyBlock {
    var thinkingSegment: MessageSegment? {
        switch type {
        case "thinking":
            let text = raw["thinking"] as? String ?? ""
            guard complete || !text.isEmpty else { return nil }
            let signature = (raw["signature"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .thinking(text: text, signature: complete ? signature : nil)
        case "redacted_thinking":
            guard complete, let data = raw["data"] as? String else { return nil }
            return .thinking(text: "", signature: nil, redactedData: data)
        default:
            return nil
        }
    }
}

/// OpenAI 兼容路这一次回复的思考（plan-model-compat-p0 §4）。来源字段名照记，回传时写回同一个字段（抄 omp「签名里存来源字段名」）
struct ReasoningCapture {
    static let textFields = ["reasoning_content", "reasoning", "reasoning_text"]
    static let detailsField = "reasoning_details"
    static let thinkTag = "think_tag"
    /// 回传时可能写进 assistant 消息的字段
    static let replayFields = textFields + [detailsField]

    /// reasoning_content / reasoning / reasoning_text / reasoning_details / think_tag
    var field: String?
    var text = ""
    /// OpenRouter reasoning_details 原样（按 index 合并分片后），回传时整串照发、不改顺序
    var details: [[String: Any]] = []

    var isEmpty: Bool { text.isEmpty && details.isEmpty }
    /// 收到过原生思考字段（收到了就不再拆正文开头的 <think>）
    var hasNative: Bool { field != nil && field != Self.thinkTag }
    /// 存段：有文字才存（只有密文的 reasoning.encrypted 不存段，但仍可回传）
    var segment: MessageSegment? { text.isEmpty ? nil : .thinking(text: text, signature: nil) }

    /// 流式一片 delta：文字按字段顺序取第一个非空字符串（中转会把同一段同时放两个名字下）；
    /// reasoning_details 按 index 合并；这一片没取到文字才从 details 补
    mutating func absorbDelta(_ delta: [String: Any]) {
        let gotText = absorbText(delta)
        guard let items = delta[Self.detailsField] as? [[String: Any]], !items.isEmpty else { return }
        supersedeTag()
        for item in items {
            mergeDetail(item)
            if !gotText { text += Self.detailText(item) }
        }
        field = Self.detailsField
    }

    /// 非流式整包 message：details 已经是完整的，原样收
    mutating func absorbMessage(_ message: [String: Any]) {
        let gotText = absorbText(message)
        guard let items = message[Self.detailsField] as? [[String: Any]], !items.isEmpty else { return }
        supersedeTag()
        details = items
        if !gotText { text += items.map(Self.detailText).joined() }
        field = Self.detailsField
    }

    /// 还没收到过原生思考时，纯空白的一片不算收到（中转会发 reasoning_content: "\n"，R7）；开始之后的空白照拼
    private mutating func absorbText(_ obj: [String: Any]) -> Bool {
        for key in Self.textFields {
            guard let s = obj[key] as? String, !s.isEmpty else { continue }
            if !hasNative, s.allSatisfy(\.isWhitespace) { continue }
            supersedeTag()
            text += s
            if field == nil { field = key }
            return true
        }
        return false
    }

    /// 原生优先：已经从正文 <think> 拆了一段、原生思考才到 → 拆出来的那段作废（splitter 下一片 / 收尾时把原文还给正文）
    private mutating func supersedeTag() {
        guard field == Self.thinkTag else { return }
        field = nil
        text = ""
    }

    private static func detailText(_ item: [String: Any]) -> String {
        switch item["type"] as? String {
        case "reasoning.text": return item["text"] as? String ?? ""
        case "reasoning.summary": return item["summary"] as? String ?? ""
        default: return ""
        }
    }

    /// 同 index 的分片拼 text / summary / data，signature / id / format 取最后一个非空；
    /// 没有 index 见 continuesWithoutIndex
    private mutating func mergeDetail(_ item: [String: Any]) {
        let target: Int?
        if let index = item["index"] as? Int {
            target = details.lastIndex { $0["index"] as? Int == index }
        } else if let last = details.indices.last, Self.continuesWithoutIndex(details[last], item) {
            target = last
        } else {
            target = nil
        }
        guard let target else {
            details.append(item)
            return
        }
        var merged = details[target]
        for (key, value) in item {
            switch key {
            case "text", "summary", "data":
                merged[key] = (merged[key] as? String ?? "") + (value as? String ?? "")
            case "signature", "id", "format":
                if let s = value as? String, !s.isEmpty { merged[key] = s }
            default:
                if merged[key] == nil { merged[key] = value }
            }
        }
        details[target] = merged
    }

    /// 没 index 的一项算不算上一项（也没 index、同 type）的后续分片：两边都有 id 就看 id 是否相同（不同 id = 不同块）；
    /// 缺 id 时密文不拼（整块不透明，拼了就坏），文字 / 摘要块上一项还没签名才接着拼
    private static func continuesWithoutIndex(_ last: [String: Any], _ item: [String: Any]) -> Bool {
        guard last["index"] == nil, last["type"] as? String == item["type"] as? String else { return false }
        func nonEmpty(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let lastId = nonEmpty(last["id"]), let id = nonEmpty(item["id"]) { return lastId == id }
        guard item["type"] as? String != "reasoning.encrypted" else { return false }
        return nonEmpty(last["signature"]) == nil
    }
}

/// OpenAI 兼容路：回复开头（去掉空白后）就是 `<think>` 的那段拆成思考，到 `</think>` 为止（plan-model-compat-p0 §4.2 / Q3）。
/// 正文中间的 `<think>` 不动；标签切在两片之间先压着（同 ThinkTagConverter 的压尾巴写法）。
/// 原生优先：拆到一半（正文还没开始）原生思考才到 → 拆出来的那段原文整段还给正文，同「先收到原生就不拆」；
/// 正文已经开始才到的，拆出来的思考作废（ReasoningCapture.supersedeTag），原文已经回不到正文前面
struct LeadingThinkTagSplitter {
    private enum State { case undecided, thinking, afterThink, passthrough }
    private static let open = "<think>"
    private static let close = "</think>"
    private var state = State.undecided
    private var held = ""
    /// 进入「思考中」以来的原文（含开头空白和 `<think>`），原生思考迟到时还给正文
    private var raw = ""

    /// 进来一片正文，返回该进正文的部分；拆出来的思考写进 capture。enabled = false（开关关 / 已收到原生思考）时直接放行
    mutating func feed(_ piece: String, into capture: inout ReasoningCapture, enabled: Bool) -> String {
        if state == .thinking || state == .afterThink {
            raw += piece
            if !enabled || capture.hasNative { return giveBack() }
        }
        return step(piece, into: &capture, enabled: enabled)
    }

    private mutating func step(_ piece: String, into capture: inout ReasoningCapture, enabled: Bool) -> String {
        switch state {
        case .passthrough:
            return piece
        case .undecided:
            held += piece
            guard enabled else { return release() }
            let lead = held.drop(while: \.isWhitespace)
            if lead.isEmpty || (lead.count < Self.open.count && Self.open.hasPrefix(lead)) { return "" }
            guard lead.hasPrefix(Self.open) else { return release() }
            state = .thinking
            if capture.field == nil { capture.field = ReasoningCapture.thinkTag }
            let rest = String(lead.dropFirst(Self.open.count))
            raw = held
            held = ""
            return step(rest, into: &capture, enabled: enabled)
        case .thinking:
            held += piece
            if let r = held.range(of: Self.close) {
                capture.text = (capture.text + held[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = String(held[r.upperBound...])
                held = ""
                state = .afterThink
                return step(rest, into: &capture, enabled: enabled)
            }
            var keep = 0
            for len in stride(from: min(held.count, Self.close.count - 1), through: 1, by: -1)
                where Self.close.hasPrefix(String(held.suffix(len))) {
                keep = len
                break
            }
            capture.text += held.dropLast(keep)
            held = String(held.suffix(keep))
            return ""
        case .afterThink:
            let body = piece.drop(while: \.isWhitespace)
            guard !body.isEmpty else { return "" }
            state = .passthrough
            raw = ""
            return String(body)
        }
    }

    /// 流结束：还在等开头的压着的部分还给正文；`</think>` 没等到就整段算思考
    mutating func flush(into capture: inout ReasoningCapture) -> String {
        defer { state = .passthrough }
        switch state {
        case .undecided:
            return release()
        case .thinking where capture.hasNative, .afterThink where capture.hasNative:
            return giveBack()
        case .thinking:
            capture.text = (capture.text + held).trimmingCharacters(in: .whitespacesAndNewlines)
            held = ""
            return ""
        case .afterThink, .passthrough:
            return ""
        }
    }

    private mutating func release() -> String {
        state = .passthrough
        defer { held = "" }
        return held
    }

    private mutating func giveBack() -> String {
        state = .passthrough
        held = ""
        defer { raw = "" }
        return raw
    }
}
