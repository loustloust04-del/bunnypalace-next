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

    /// 非 JSON 的事件丢弃
    static func parseSSEPayload(_ text: String) -> [Any] {
        let events = (try? SSEEventAssembler.events(in: Data(text.utf8))) ?? []
        return events.compactMap { try? JSONSerialization.jsonObject(with: Data($0.data.utf8)) }
    }
}
