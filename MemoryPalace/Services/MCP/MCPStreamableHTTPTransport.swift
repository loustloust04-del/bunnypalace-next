import Foundation

final class MCPStreamableHTTPTransport: MCPTransport {
    var onMessage: ((Any) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let serverURL: URL
    private let headers: [String: String]
    private var closed = false

    init(serverURL: String, headers: [String: String]) throws {
        guard let url = URL(string: serverURL) else {
            throw MCPError.invalidURL(serverURL)
        }
        self.serverURL = url
        self.headers = headers
    }

    func connect() async throws {
        closed = false
    }

    func send(_ message: [String: Any]) async throws {
        guard !closed else { throw MCPError.connectionClosed }
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPError.serverError("MCP HTTP 请求失败: HTTP \(status) \(body)")
        }

        if let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("text/event-stream") {
            for eventData in Self.parseSSEPayload(String(data: data, encoding: .utf8) ?? "") {
                emit(eventData)
            }
        } else if !data.isEmpty {
            let json = try JSONSerialization.jsonObject(with: data)
            emit(json)
        }
    }

    func close() {
        closed = true
        onClose?(nil)
    }

    private func emit(_ raw: Any) {
        Task { @MainActor in
            self.onMessage?(raw)
        }
    }

    static func parseSSEPayload(_ text: String) -> [Any] {
        var result: [Any] = []
        var dataLines: [String] = []

        func flush() {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return }
            result.append(json)
        }

        // ⚠️ CRLF 在 Swift String 里是单个 grapheme cluster："\r\n" 不会被 split("\n") 切开。
        // FastMCP 等按 HTTP 规范回 \r\n 行尾的 SSE 会整体粘成一行 → 0 events（kiwi 接入实锤踩坑）。
        // 必须先归一化行尾再切。
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return result
    }
}
