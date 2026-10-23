#if os(iOS)
import Foundation
import WebKit

/// web → Swift 的消息。协议 v1，冻结。
/// 加 case 安全；改/删要升 `PROTO_V`（chat-runtime.js 顶部）并做能力协商。
enum ChatWebMessage {
    case ready(capabilities: [String])
    case send(text: String, attachmentIds: [String])
    case action(name: String, nodeId: String)
    case switchBranch(nodeId: String, delta: Int)
    case pickAttachment
    case removeAttachment(id: String)
    case scrolled(atBottom: Bool)
    case probe(vv: Int, offTop: Int, win: Int, atBottom: Bool)
    case errorAck(code: String, message: String)
    /// 卡库 ⑦：HTML 段挂载 / 注销 / 运行 / 收起 / 子文档窄消息（htmlMount / htmlRelease / htmlRun / htmlStop / htmlChild）
    case html(HTMLEmbedMessage)

    init?(body: Any) {
        guard let d = body as? [String: Any], let type = d["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready(capabilities: d["capabilities"] as? [String] ?? [])
        case "send":
            self = .send(text: d["text"] as? String ?? "",
                         attachmentIds: d["attachmentIds"] as? [String] ?? [])
        case "action":
            guard let name = d["name"] as? String, let nodeId = d["nodeId"] as? String else { return nil }
            self = .action(name: name, nodeId: nodeId)
        case "switchBranch":
            guard let nodeId = d["nodeId"] as? String else { return nil }
            self = .switchBranch(nodeId: nodeId, delta: d["delta"] as? Int ?? 1)
        case "pickAttachment":
            self = .pickAttachment
        case "removeAttachment":
            self = .removeAttachment(id: d["id"] as? String ?? "")
        case "scrolled":
            self = .scrolled(atBottom: d["atBottom"] as? Bool ?? true)
        case "probe":
            self = .probe(vv: d["vv"] as? Int ?? -1, offTop: d["offTop"] as? Int ?? -1,
                          win: d["win"] as? Int ?? -1, atBottom: d["atBottom"] as? Bool ?? true)
        case "errorAck":
            self = .errorAck(code: d["code"] as? String ?? "", message: d["message"] as? String ?? "")
        default:
            guard let m = HTMLEmbedMessage(body: d) else { return nil }
            self = .html(m)
        }
    }
}

/// Swift → web。所有出口收敛到这里，别在别处散着写 `evaluateJavaScript`。
@MainActor
struct ChatWebCommander {
    weak var webView: WKWebView?

    func render(_ payload: ChatRenderPayload) { call("render", payload) }
    func patchNode(_ dto: ChatMessageDTO)     { call("patchNode", dto) }
    func attachmentAdded(_ dto: ChatAttachmentDTO) { call("attachmentAdded", dto) }
    func setChips(_ list: [ChatAttachmentDTO])     { call("setChips", list) }
    func removeNode(_ nodeId: String)         { call("removeNode", raw: [js(nodeId)]) }
    func appendDelta(nodeId: String, delta: String) { call("appendDelta", raw: [js(nodeId), js(delta)]) }
    func endStream(nodeId: String, finalText: String?) {
        call("endStream", raw: [js(nodeId), finalText.map(js) ?? "null"])
    }
    func fillInput(_ text: String)   { call("fillInput", raw: [js(text)]) }
    func applySkin(_ css: String)    { call("applySkin", raw: [js(css)]) }
    func applyBase(_ css: String)    { call("applyBase", raw: [js(css)]) }
    func setTheme(_ theme: String)   { call("setTheme", raw: [js(theme)]) }
    func scrollToNode(_ nodeId: String) { call("scrollToNode", raw: [js(nodeId)]) }
    func reportError(code: String, message: String) { call("error", raw: [js(code), js(message)]) }
    /// 卡库第二批 B5：轻提示（/echo、被拒、降级成填输入框）
    func toast(_ text: String)       { call("toast", raw: [js(text)]) }

    // MARK: -

    private func call<T: Encodable>(_ fn: String, _ arg: T) {
        guard let data = try? JSONEncoder().encode(arg),
              let json = String(data: data, encoding: .utf8) else { return }
        eval("window.mp && mp.\(fn)(\(json))")
    }

    private func call(_ fn: String, raw args: [String]) {
        eval("window.mp && mp.\(fn)(\(args.joined(separator: ", ")))")
    }

    /// 字符串进 JS 走 JSON 编码，省得自己转义引号/换行/U+2028
    private func js(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func eval(_ script: String) {
        webView?.evaluateJavaScript(script) { _, err in
            if let err { KBProbe.log("[CSSCHAT] JS 出错: \(err.localizedDescription)") }
        }
    }
}
#endif
