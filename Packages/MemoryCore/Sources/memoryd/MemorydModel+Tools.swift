import Foundation
import MemoryCore

/// memoryd 的带工具调用：Anthropic `tool_use` / `tool_result`，OpenAI 兼容 `tool_calls` / `role: tool`。
/// 和不带工具的 `complete` 用同一套地址、key、抹 key 规矩
extension MemorydModel: ToolModelCaller {
    private static func object(_ json: String) -> Any {
        (json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [String: Any]()
    }

    private static func text(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func toolRequest(system: String, turns: [AgentTurn], tools: [AgentToolSpec]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = ["model": modelId, "max_tokens": maxTokens]
        switch wire {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // 系统提示和工具定义每轮都一样：打缓存断点
            body["system"] = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]] as [String: Any]]
            var specs = tools.map { ["name": $0.name, "description": $0.description, "input_schema": Self.object($0.schema)] as [String: Any] }
            if !specs.isEmpty { specs[specs.count - 1]["cache_control"] = ["type": "ephemeral"] }
            body["tools"] = specs
            var messages = turns.map { turn -> [String: Any] in
                switch turn {
                case .user(let text):
                    return ["role": "user", "content": [["type": "text", "text": text] as [String: Any]]]
                case .assistant(let text, let calls, _):
                    var blocks: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
                    blocks += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": Self.object($0.arguments)] }
                    return ["role": "assistant", "content": blocks]
                case .toolResults(let results):
                    return ["role": "user", "content": results.map {
                        ["type": "tool_result", "tool_use_id": $0.callId, "content": $0.content, "is_error": $0.isError] as [String: Any]
                    }]
                }
            }
            // 对话越滚越长：在最后一段上再打一个断点，下一轮前面的都能命中
            if var last = messages.last, var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
                last["content"] = blocks
                messages[messages.count - 1] = last
            }
            body["messages"] = messages
        case .openai:
            request.setValue("Bearer " + key, forHTTPHeaderField: "authorization")
            var messages: [[String: Any]] = [["role": "system", "content": system]]
            for turn in turns {
                switch turn {
                case .user(let text):
                    messages.append(["role": "user", "content": text])
                case .assistant(let text, let calls, let reasoning):
                    var message: [String: Any] = ["role": "assistant", "content": text]
                    if let reasoning { message["reasoning_content"] = reasoning }
                    if !calls.isEmpty {
                        message["tool_calls"] = calls.map {
                            ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any]
                        }
                    }
                    messages.append(message)
                case .toolResults(let results):
                    for result in results {
                        messages.append(["role": "tool", "tool_call_id": result.callId, "content": result.content])
                    }
                }
            }
            body["messages"] = messages
            body["tools"] = tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": Self.object($0.schema)]] as [String: Any]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func step(system: String, turns: [AgentTurn], tools: [AgentToolSpec]) async throws -> AgentStep {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(try toolRequest(system: system, turns: turns, tools: tools))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(message: redacted(error.localizedDescription))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(message: redacted("模型接口回了 \(status)：\(String(decoding: data.prefix(400), as: UTF8.self))"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "模型回包读不懂")
        }
        var step = AgentStep()
        switch wire {
        case .anthropic:
            for block in root["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text": step.text += block["text"] as? String ?? ""
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    step.calls.append(AgentToolCall(id: id, name: name, arguments: Self.text(block["input"] ?? [String: Any]())))
                default: continue
                }
            }
            step.stop = root["stop_reason"] as? String
            if let usage = root["usage"] as? [String: Any] {
                let read = usage["cache_read_input_tokens"] as? Int ?? 0
                let write = usage["cache_creation_input_tokens"] as? Int ?? 0
                step.usage = AgentUsage(input: (usage["input_tokens"] as? Int ?? 0) + read + write,
                                        output: usage["output_tokens"] as? Int ?? 0, cacheRead: read)
            }
        case .openai:
            let choice = (root["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any] ?? [:]
            step.text = message["content"] as? String ?? ""
            step.reasoning = message["reasoning_content"] as? String
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                guard let id = call["id"] as? String, let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                step.calls.append(AgentToolCall(id: id, name: name, arguments: function["arguments"] as? String ?? "{}"))
            }
            step.stop = choice?["finish_reason"] as? String
            if let usage = root["usage"] as? [String: Any] {
                let details = usage["prompt_tokens_details"] as? [String: Any]
                step.usage = AgentUsage(input: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0,
                                        cacheRead: (details?["cached_tokens"] as? Int) ?? (usage["prompt_cache_hit_tokens"] as? Int))
            }
        }
        // 输出写到上限被截断、什么都没交上：不算出错，交给循环去提醒它分批
        if step.text.isEmpty, step.calls.isEmpty, step.stop == "max_tokens" || step.stop == "length" { return step }
        if step.text.isEmpty, step.calls.isEmpty {
            throw Failure(message: "模型这一轮既没说话也没调工具（stop：\(step.stop ?? "没给")）")
        }
        return step
    }
}
