import Foundation

/// 副调用走流式（铲屎二期刀 4 返修，research-非流式长请求断线）：边收边攒 SSE 事件，最后拼回和非流式同形的整包，
/// 交给各家现成的 `parseNonStreamBody`——截断标志 / 用量 / stop_reason 和非流式走同一个解析
struct SideStreamAssembler {
    enum Format { case openAI, anthropic }

    enum Failure: Error, Equatable {
        /// 流里来了 error 事件（原样 payload，调用方按 errorMessage 说人话、去 key）
        case upstream(String)
        /// 连接正常关了，但没见到结束标记 / 停止原因
        case incomplete
    }

    let format: Format
    private var sawEvent = false
    private var finished = false
    /// 中转没理 `stream: true`、回的是整包 JSON：原样留着
    private var plain: [String] = []
    // OpenAI 兼容
    private var id: String?
    private var text = ""
    private var finishReason: String?
    private var usage: [String: Any]?
    // Anthropic
    private var message: [String: Any] = [:]
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]

    init(format: Format) { self.format = format }

    mutating func feed(_ line: String) throws {
        guard line.hasPrefix("data:") else {
            if line.hasPrefix("event:") || line.hasPrefix(":") || line.hasPrefix("id:") || line.hasPrefix("retry:") {
                sawEvent = true
            } else {
                plain.append(line)
            }
            return
        }
        sawEvent = true
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            finished = true
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        if obj["type"] as? String == "error" || obj["error"] is [String: Any] || obj["error"] is String {
            throw Failure.upstream(payload)
        }
        switch format {
        case .openAI: absorbOpenAI(obj)
        case .anthropic: absorbAnthropic(obj)
        }
    }

    /// 非流式同形的回包
    func body() throws -> Data {
        guard sawEvent else { return Data(plain.joined(separator: "\n").utf8) }
        guard finished else { throw Failure.incomplete }
        var obj: [String: Any]
        switch format {
        case .openAI:
            obj = ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": finishReason as Any? ?? NSNull()]]]
            if let id { obj["id"] = id }
            if let usage { obj["usage"] = usage }
        case .anthropic:
            obj = message
            obj["content"] = blocks.keys.sorted().compactMap { blocks[$0] }
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private mutating func absorbOpenAI(_ obj: [String: Any]) {
        if id == nil { id = obj["id"] as? String }
        if let u = obj["usage"] as? [String: Any] { usage = u }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return }
        if let content = (choice["delta"] as? [String: Any])?["content"] as? String { text += content }
        if let reason = choice["finish_reason"] as? String {
            finishReason = reason
            finished = true
        }
    }

    private mutating func absorbAnthropic(_ obj: [String: Any]) {
        let index = obj["index"] as? Int ?? 0
        switch obj["type"] as? String {
        case "message_start":
            message = obj["message"] as? [String: Any] ?? [:]
            message["content"] = nil
        case "content_block_start":
            blocks[index] = obj["content_block"] as? [String: Any] ?? [:]
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any] else { return }
            var block = blocks[index] ?? [:]
            switch delta["type"] as? String {
            case "text_delta": block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
            case "thinking_delta": block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta": block["signature"] = delta["signature"]
            case "input_json_delta": partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
            blocks[index] = block
        case "content_block_stop":
            if let json = partialJSON.removeValue(forKey: index), !json.isEmpty {
                blocks[index]?["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
            }
        case "message_delta":
            for (k, v) in obj["delta"] as? [String: Any] ?? [:] { message[k] = v }
            if message["stop_reason"] is String { finished = true }
            // 中转的 start 常是占位、真值在 delta；delta 里的 0 不抹掉 start 的真值（同流式 captureBillingDimensions R10）
            var merged = message["usage"] as? [String: Any] ?? [:]
            for (k, v) in obj["usage"] as? [String: Any] ?? [:] where !((v as? Int) == 0 && merged[k] != nil) { merged[k] = v }
            if !merged.isEmpty { message["usage"] = merged }
        case "message_stop":
            finished = true
        default:
            break
        }
    }
}
