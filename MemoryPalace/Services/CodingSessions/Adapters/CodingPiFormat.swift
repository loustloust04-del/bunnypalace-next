#if os(macOS)
import Foundation

/// pi-ai 消息形状的共用渲染核心（Wake `pi_format.rs`）：Pi / Oh My Pi 的 `<ts>_<uuid>.jsonl` 与 OpenClaw 的转录条目同族——
/// `{role:user|assistant|toolResult, content:[…]}`，assistant 块 text / thinking / toolCall，toolResult 独立 role 按 toolCallId 回填，
/// 连续 assistant（中间只隔 toolResult）合并成一条。合并与截断只此一份，两家差异全在 `Options`
struct CodingPiRender {
    struct Options {
        /// assistant 的 thinking 块进 thinking（Pi 不落盘 thinking，OpenClaw 落）
        var thinkingBlocks = false
        /// user 行带 `runtimeContextCarrier:true` 是运行时注入的上下文，归 Meta
        var metaCarrier = false
        /// toolResult 正文走 toolResultParts（未知对象保留 JSON 原文）而非 contentParts
        var rawToolResults = false
    }

    private(set) var messages: [CodingMessage] = []
    /// OpenClaw 的 model_change 条目直接改写
    var model: String?
    private(set) var tokensUsed: Int64?
    private let options: Options
    /// toolCallId → (消息下标, 工具下标)
    private var toolIndex: [String: (Int, Int)] = [:]

    init(_ options: Options = Options()) {
        self.options = options
    }

    /// 非 message 条目（OpenClaw 的 compaction 摘要等）按位置插进消息流
    mutating func append(_ message: CodingMessage) {
        messages.append(message)
    }

    /// 一条 `{role,content,…}`；未知 role 回 false（调用方计 unknown）
    mutating func push(_ msg: CodingParse.JSON, ts: Int64) -> Bool {
        let content = msg["content"]
        switch msg["role"] as? String {
        case "user":
            let parsed = CodingParse.contentParts(content)
            if parsed.text.isEmpty && parsed.images.isEmpty { return true }
            var message = CodingParse.textMessage(.user, parsed.text, ts: ts)
            message.images = parsed.images
            message.imageCount = parsed.imageCount
            if options.metaCarrier, msg["runtimeContextCarrier"] as? Bool == true { message.kind = .meta }
            messages.append(message)
        case "assistant":
            pushAssistant(msg, content, ts)
        case "toolResult":
            guard let callId = msg["toolCallId"] as? String, let (mi, ti) = toolIndex[callId] else { return true }
            let parsed = options.rawToolResults ? CodingParse.toolResultParts(content) : CodingParse.contentParts(content)
            if !parsed.text.isEmpty { messages[mi].toolCalls[ti].output = CodingParse.clip(parsed.text, CodingLimits.maxToolIO).0 }
            if CodingParse.bool(msg["isError"]) { messages[mi].toolCalls[ti].isError = true }
            messages[mi].images += parsed.images
            messages[mi].imageCount += parsed.imageCount
        default:
            return false
        }
        return true
    }

    private mutating func pushAssistant(_ msg: CodingParse.JSON, _ content: Any?, _ ts: Int64) {
        let parsed = CodingParse.contentParts(content)
        var tools: [CodingToolCall] = []
        var thinking = ""
        for case let block as CodingParse.JSON in (content as? [Any]) ?? [] {
            switch block["type"] as? String {
            case "toolCall":
                tools.append(CodingParse.toolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                                                  input: block["arguments"] ?? NSNull()))
            case "thinking" where options.thinkingBlocks:
                let text = CodingParse.trimmed(block["thinking"] as? String ?? "")
                if !text.isEmpty { thinking += (thinking.isEmpty ? "" : "\n\n") + text }
            default:
                break
            }
        }
        if parsed.text.isEmpty && tools.isEmpty && parsed.images.isEmpty && thinking.isEmpty { return }
        let model = msg["model"] as? String
        if let model { self.model = model }
        if let usage = msg["usage"] as? CodingParse.JSON, let total = usage["totalTokens"] as? NSNumber,
           CFGetTypeID(total) != CFBooleanGetTypeID() {
            tokensUsed = total.int64Value
        }
        // 连续 assistant（中间只隔 toolResult）合并成一条：详情页每个回合一条助手消息
        if messages.last?.role != .assistant { messages.append(CodingParse.textMessage(.assistant, "", ts: ts)) }
        let base = messages.count - 1
        // 合并后统一压正文上限（整个回合并成一条，不能靠单行的 textMessage clip）
        if !parsed.text.isEmpty || !parsed.images.isEmpty {
            if messages[base].text.utf8.count < CodingLimits.maxMessageText, !parsed.text.isEmpty {
                messages[base].text += (messages[base].text.isEmpty ? "" : "\n\n") + parsed.text
            }
            messages[base].images += parsed.images
            messages[base].imageCount += parsed.imageCount
            if messages[base].text.utf8.count > CodingLimits.maxMessageText {
                messages[base].text = CodingParse.clip(messages[base].text, CodingLimits.maxMessageText).0
                messages[base].truncated = true
            }
        }
        if !thinking.isEmpty {
            // 与正文 / 工具 IO 同一上限：长推理合并后也不能无限增长
            let merged = messages[base].thinking.map { $0 + "\n\n" + thinking } ?? thinking
            messages[base].thinking = CodingParse.clip(merged, CodingLimits.maxToolIO).0
        }
        if model != nil { messages[base].model = model }
        for call in tools {
            toolIndex[call.id] = (base, messages[base].toolCalls.count)
            messages[base].toolCalls.append(call)
        }
    }
}
#endif
