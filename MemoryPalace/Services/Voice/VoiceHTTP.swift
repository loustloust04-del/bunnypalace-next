import Foundation

/// 各家语音合成共用的 HTTP 小件：发请求、状态码 → `VoiceSynthError`。
/// 服务端错误正文先用**本次请求实际用的 key** 整段去敏，再截一小段带进错误（界面显示前还有第二道 `VoiceServiceStore.redact`）。
enum VoiceHTTP {
    static func send(_ req: URLRequest, session: URLSession,
                     delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, HTTPURLResponse?) {
        do {
            let (data, resp) = try await session.data(for: req, delegate: delegate)
            return (data, resp as? HTTPURLResponse)
        } catch {
            throw VoiceSynthError.network
        }
    }

    static let detailLimit = 160

    /// 2xx 放行；401/403 key 无效；402/429 额度 / 限流；其余带（去敏后的）正文片段
    static func check(_ resp: HTTPURLResponse?, body: Data, secrets: [String]) throws {
        guard let resp else { return }
        switch resp.statusCode {
        case 200..<300: return
        case 401, 403: throw VoiceSynthError.invalidKey
        case 402, 429: throw VoiceSynthError.quotaOrRateLimited
        default: throw VoiceSynthError.server(resp.statusCode, detail(body, secrets: secrets))
        }
    }

    /// 错误正文：优先取 JSON 里常见的 message / detail 字段，否则原文；都先整段去敏再截前 160 字
    static func detail(_ body: Data, secrets: [String]) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let msg = message(in: obj) {
            return clip(msg, secrets: secrets)
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : clip(text, secrets: secrets)
    }

    /// 先整段去敏、后截断：key 落在截断点上也不会漏出前半截
    static func clip(_ text: String, secrets: [String], limit: Int = detailLimit) -> String {
        String(VoiceServiceStore.redact(text, secrets: secrets).prefix(limit))
    }

    /// 合成入口守单次请求上限（字数）
    static func ensureLength(_ text: String, limit: Int) throws {
        if text.count > limit { throw VoiceSynthError.textTooLong(limit) }
    }

    private static func message(in obj: [String: Any]) -> String? {
        for key in ["message", "detail", "error", "status_msg"] {
            if let s = obj[key] as? String, !s.isEmpty { return s }
            if let nested = obj[key] as? [String: Any], let s = message(in: nested) { return s }
        }
        return nil
    }

    static func jsonRequest(_ url: URL, body: [String: Any], timeout: TimeInterval = 60) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 用户填的地址拼路径：去掉结尾的 `/`
    static func url(base: String, path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + "/" + path)
    }
}
