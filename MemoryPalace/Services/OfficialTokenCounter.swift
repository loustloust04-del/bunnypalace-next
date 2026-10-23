import Foundation

struct OfficialTokenCounter: Sendable {
    var fetch: @Sendable (URLRequest) async throws -> Data = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func supports(_ url: URL?) -> Bool {
        guard url?.scheme == "https" else { return false }
        return ["api.anthropic.com", "api.openai.com"].contains(url?.host?.lowercased() ?? "")
    }

    static func request(from chat: URLRequest) -> URLRequest? {
        guard supports(chat.url), let raw = chat.httpBody,
              let body = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let model = body["model"] as? String else { return nil }
        var payload: [String: Any] = ["model": model]
        let anthropic = chat.url?.host == "api.anthropic.com"
        if anthropic {
            for key in ["messages", "system", "tools", "tool_choice", "thinking"] { payload[key] = body[key] }
        } else {
            guard let messages = body["messages"] as? [[String: Any]] else { return nil }
            var input: [[String: Any]] = []
            for message in messages {
                guard let role = message["role"] as? String else { return nil }
                if role == "tool", let id = message["tool_call_id"] as? String {
                    input.append(["type": "function_call_output", "call_id": id, "output": message["content"] ?? ""])
                    continue
                }
                if let content = message["content"] as? String, !content.isEmpty {
                    input.append(["role": role, "content": content])
                } else if let parts = message["content"] as? [[String: Any]] {
                    var converted: [[String: Any]] = []
                    for part in parts {
                        switch part["type"] as? String {
                        case "text": converted.append(["type": "input_text", "text": part["text"] ?? ""])
                        case "image_url":
                            guard let image = part["image_url"] as? [String: Any], let url = image["url"] as? String else { return nil }
                            converted.append(["type": "input_image", "image_url": url, "detail": image["detail"] ?? "auto"])
                        default: return nil // 无法无损转成 Responses 的输入，回落原启发式。
                        }
                    }
                    input.append(["role": role, "content": converted])
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let function = call["function"] as? [String: Any], let id = call["id"] as? String,
                          let name = function["name"] as? String else { return nil }
                    input.append(["type": "function_call", "call_id": id, "name": name,
                                  "arguments": function["arguments"] ?? "{}"])
                }
            }
            payload["input"] = input
            if let tools = body["tools"] as? [[String: Any]] {
                var converted: [[String: Any]] = []
                for tool in tools {
                    guard tool["type"] as? String == "function", var function = tool["function"] as? [String: Any] else { return nil }
                    function["type"] = "function"
                    converted.append(function)
                }
                payload["tools"] = converted
            }
        }
        let endpoint = anthropic ? "https://api.anthropic.com/v1/messages/count_tokens" : "https://api.openai.com/v1/responses/input_tokens"
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for header in anthropic ? ["x-api-key", "anthropic-version", "anthropic-beta"] : ["Authorization", "OpenAI-Organization", "OpenAI-Project"] {
            request.setValue(chat.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    func count(_ chat: URLRequest) async -> Int? {
        guard let request = Self.request(from: chat) else { return nil }
        do {
            // 请求 timeout 和 resource timeout 都是 2s；真实模型 / 权限 / 图像计数支持待实测。
            let data = try await fetch(request)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = obj["input_tokens"] as? Int, count >= 0 else { return nil }
            return count
        } catch { return nil }
    }
}
