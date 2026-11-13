import Foundation

/// 一次回复为什么结束（plan-reply-error-report-1106 §1.1）。
/// rawValue 会写进 MessageNode.replyOutcome，必须稳定；新值只能加，不能改老值。
/// HTTP 报错和用户点停止不进这个枚举（继续走现有的红色胶囊 /「（已停止）」）。
enum ReplyOutcome: String, Equatable, CaseIterable {
    case normal = "normal"
    /// finish_reason=length / stop_reason=max_tokens
    case truncatedLength = "length"
    /// finish_reason=content_filter / stop_reason=refusal
    case filtered = "filtered"
    /// finish_reason=insufficient_system_resource
    case noResource = "no_resource"
    /// finish_reason=aborted
    case aborted = "aborted"
    /// 正常收尾，但正文为空（只有思考也算）
    case emptyReply = "empty_reply"
    /// 连接正常结束，既没见过 [DONE] / message_stop，也没见过 finish_reason / stop_reason
    case streamCut = "stream_cut"
    /// 第 2 步看门狗：只收到 keep-alive，一直没出正文 / 思考
    case stalledFirstByte = "stalled_first_byte"
    /// 第 2 步看门狗：已经出过增量，之后长时间没有新增量
    case stalledMidStream = "stalled_mid_stream"

    /// OpenAI 兼容的 finish_reason：认不出的值算 normal，原串另行存进 finishReason 方便以后查。
    init(finishReason: String?) {
        switch finishReason {
        case "length": self = .truncatedLength
        case "content_filter": self = .filtered
        case "insufficient_system_resource": self = .noResource
        case "aborted": self = .aborted
        default: self = .normal
        }
    }

    /// Anthropic 的 stop_reason。
    init(anthropicStopReason: String?) {
        switch anthropicStopReason {
        case "max_tokens": self = .truncatedLength
        case "refusal": self = .filtered
        default: self = .normal
        }
    }

    var isAbnormal: Bool { self != .normal }
}

/// 气泡下面那条灰胶囊的呈现。抽成纯数据，方便单测「文案 / 按钮 / 历史节点没按钮」。
struct ReplyOutcomePresentation: Equatable {
    let text: String
    let actionTitle: String?
    let secondaryTitle: String?

    static func make(outcome: ReplyOutcome, isLatestAssistant: Bool, isStreaming: Bool) -> ReplyOutcomePresentation {
        let interactive = isLatestAssistant && !isStreaming
        let retry = interactive ? "重试" : nil
        switch outcome {
        case .normal:
            return ReplyOutcomePresentation(text: "", actionTitle: nil, secondaryTitle: nil)
        case .truncatedLength:
            return ReplyOutcomePresentation(text: "到输出上限，被截断了",
                                            actionTitle: interactive ? "继续" : nil,
                                            secondaryTitle: retry)
        case .filtered:
            return ReplyOutcomePresentation(text: "被服务商的审核拦下了", actionTitle: retry, secondaryTitle: nil)
        case .noResource:
            return ReplyOutcomePresentation(text: "上游资源不足，中断了", actionTitle: retry, secondaryTitle: nil)
        case .aborted:
            return ReplyOutcomePresentation(text: "上游中止了这条回复", actionTitle: retry, secondaryTitle: nil)
        case .emptyReply:
            return ReplyOutcomePresentation(text: "上游这次什么都没回", actionTitle: retry, secondaryTitle: nil)
        case .streamCut:
            return ReplyOutcomePresentation(text: "连接断了，回复可能不完整", actionTitle: retry, secondaryTitle: nil)
        case .stalledFirstByte:
            return ReplyOutcomePresentation(text: "上游排队太久，没开始回", actionTitle: retry, secondaryTitle: nil)
        case .stalledMidStream:
            return ReplyOutcomePresentation(text: "上游中途卡住，停了", actionTitle: retry, secondaryTitle: nil)
        }
    }
}
