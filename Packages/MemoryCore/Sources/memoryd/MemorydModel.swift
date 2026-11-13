import Foundation
import MemoryCore

/// memoryd 调模型的那一头：一次 system + user，不带工具。两种接口形状：
/// Anthropic Messages（默认）和 OpenAI 兼容的 chat/completions（DeepSeek 这类）。
/// key 只从环境变量读，不进命令行参数、日志、落盘；抛出去的错误先把 key 抹掉
struct MemorydModel: Sendable {
    enum Wire: String, Sendable {
        case anthropic
        case openai
    }

    /// 一组环境变量名：被测模型用 `MEMORYD_MODEL_*`，裁判用 `MEMORYD_JUDGE_*`
    struct Variables: Sendable {
        let key: String
        let url: String
        let wire: String

        static let model = Variables(key: "MEMORYD_MODEL_KEY", url: "MEMORYD_MODEL_URL", wire: "MEMORYD_MODEL_WIRE")
        static let judge = Variables(key: "MEMORYD_JUDGE_KEY", url: "MEMORYD_JUDGE_URL", wire: "MEMORYD_JUDGE_WIRE")
    }

    static let keyVariable = Variables.model.key
    static let urlVariable = Variables.model.url
    static let defaultBase = "https://api.anthropic.com"
    /// 带思考的模型思考也算在输出里，给小了会只剩思考没正文、或者把 JSON 截断
    static let maxTokens = 16000

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    var base: URL
    var modelId: String
    var key: String
    var wire: Wire = .anthropic
    var maxTokens = MemorydModel.maxTokens
    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    var ref: MemoryBenchModelRef {
        MemoryBenchModelRef(credentialId: "memoryd", modelId: modelId, name: modelId)
    }

    /// 没给模型 id 或环境里没 key = 没接（nil）。OpenAI 兼容接口必须给地址（没有默认的）
    static func fromEnvironment(modelId: String?, variables: Variables = .model,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> MemorydModel? {
        guard let modelId, !modelId.isEmpty,
              let key = environment[variables.key]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        let wire = environment[variables.wire].flatMap { Wire(rawValue: $0.lowercased()) } ?? .anthropic
        let address = environment[variables.url].flatMap { $0.isEmpty ? nil : $0 } ?? (wire == .anthropic ? defaultBase : nil)
        guard let address, let base = URL(string: address) else { return nil }
        return MemorydModel(base: base, modelId: modelId, key: key, wire: wire)
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// 地址给到 `…/v1` 或不带都认
    var endpoint: URL {
        let root = base.lastPathComponent == "v1" ? base : base.appendingPathComponent("v1")
        switch wire {
        case .anthropic: return root.appendingPathComponent("messages")
        case .openai: return root.appendingPathComponent("chat").appendingPathComponent("completions")
        }
    }

    func request(system: String, user: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = ["model": modelId, "max_tokens": maxTokens]
        switch wire {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["messages"] = [["role": "user", "content": user]]
            if !system.isEmpty { body["system"] = system }
        case .openai:
            request.setValue("Bearer " + key, forHTTPHeaderField: "authorization")
            var messages: [[String: String]] = []
            if !system.isEmpty { messages.append(["role": "system", "content": system]) }
            messages.append(["role": "user", "content": user])
            body["messages"] = messages
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct AnthropicReply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        let content: [Block]
        let usage: Usage?
        let stop_reason: String?
    }

    private struct OpenAIReply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let choices: [Choice]
        let usage: Usage?
    }

    func complete(system: String, user: String) async throws -> MemoryBenchCallResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(try request(system: system, user: user))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(message: redacted(error.localizedDescription))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let head = String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure(message: redacted("模型接口回了 \(status)：\(head)"))
        }
        let text: String
        let stop: String?
        var usage: MemoryBenchUsage?
        switch wire {
        case .anthropic:
            guard let reply = try? JSONDecoder().decode(AnthropicReply.self, from: data) else {
                throw Failure(message: "模型回包读不懂")
            }
            text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
            stop = reply.stop_reason
            if let input = reply.usage?.input_tokens, let output = reply.usage?.output_tokens {
                usage = MemoryBenchUsage(input: input, output: output)
            }
        case .openai:
            guard let reply = try? JSONDecoder().decode(OpenAIReply.self, from: data) else {
                throw Failure(message: "模型回包读不懂")
            }
            text = reply.choices.first?.message.content ?? ""
            stop = reply.choices.first?.finish_reason
            if let input = reply.usage?.prompt_tokens, let output = reply.usage?.completion_tokens {
                usage = MemoryBenchUsage(input: input, output: output)
            }
        }
        // 没正文要说清为什么（拒答 / 写到上限），不能悄悄当成「没回」
        if text.isEmpty { throw Failure(message: "模型没回正文（stop_reason：\(stop ?? "没给")）") }
        // 没有价目表：金额未知，不是 $0
        return MemoryBenchCallResult(text: text, usage: usage, usd: nil, costSource: .unpriced)
    }

    func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: key, with: "•••")
    }

    var caller: MemoryBenchCaller {
        { _, prompt in try await complete(system: prompt.system, user: prompt.user) }
    }
}
