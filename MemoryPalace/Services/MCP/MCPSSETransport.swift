import Foundation

final class MCPSSETransport: MCPTransport {
    var onMessage: ((Any) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let serverURL: URL
    private let headers: [String: String]
    private var messageEndpoint: URL?
    private var streamTask: Task<Void, Never>?
    private var closed = false
    private var endpointContinuation: CheckedContinuation<Void, Error>?
    /// endpointContinuation 会被三方触碰（SSE 流线程的 processEvent、超时 Task、close()），
    /// 取出-置空必须互斥，否则两方同时过 guard 就是 checked continuation double-resume crash。
    private let endpointLock = NSLock()

    init(serverURL: String, headers: [String: String]) throws {
        guard let url = URL(string: serverURL) else {
            throw MCPError.invalidURL(serverURL)
        }
        self.serverURL = url
        self.headers = headers
    }

    func connect() async throws {
        guard streamTask == nil else { return }
        closed = false
        let url = Self.appendingSessionId(to: serverURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw MCPError.serverError("MCP SSE 连接失败: HTTP \(http.statusCode)")
                }
                var eventName = ""
                var dataLines: [String] = []
                var lineBuffer = [UInt8]()

                func handleLine(_ rawLine: String) {
                    let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    if line.isEmpty {
                        self.processEvent(name: eventName, data: dataLines.joined(separator: "\n"))
                        eventName = ""
                        dataLines.removeAll()
                    } else if line.hasPrefix("event:") {
                        eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    }
                }

                // 不能用 bytes.lines：AsyncLineSequence 会吞掉空行，而 SSE 靠空行分隔 event。
                // 手动按 \n 切字节，连续 \n 产生的空行才能被识别并触发 processEvent。
                for try await byte in bytes {
                    if Task.isCancelled || self.closed { break }
                    if byte == 0x0A {
                        handleLine(String(decoding: lineBuffer, as: UTF8.self))
                        lineBuffer.removeAll(keepingCapacity: true)
                    } else {
                        lineBuffer.append(byte)
                    }
                }
                self.finishEndpointIfNeeded(error: MCPError.connectionClosed)
                if !self.closed {
                    await MainActor.run { self.onClose?(nil) }
                }
            } catch {
                self.finishEndpointIfNeeded(error: error)
                if !self.closed {
                    await MainActor.run { self.onClose?(error) }
                }
            }
        }

        // 超时实现注意（P0-3）：同 MCPClient.sendRequest——TaskGroup 双子任务模式在超时后
        // 要等 continuation 子任务结束，但没人 resume 它 → server 200 但不发 endpoint 事件时
        // connect() 永挂、状态卡 connecting 无报错。改为超时 Task 主动走
        // finishEndpointIfNeeded（取出-置空有锁互斥，重复调用是 no-op）。
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishEndpointIfNeeded(error: MCPError.endpointTimeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            endpointLock.lock()
            endpointContinuation = continuation
            endpointLock.unlock()
        }
    }

    func send(_ message: [String: Any]) async throws {
        guard !closed, let endpoint = messageEndpoint else {
            throw MCPError.connectionClosed
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 202 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPError.serverError("MCP 消息投递失败: HTTP \(status) \(body)")
        }
    }

    func close() {
        closed = true
        streamTask?.cancel()
        streamTask = nil
        finishEndpointIfNeeded(error: MCPError.connectionClosed)
    }

    private func processEvent(name: String, data: String) {
        guard !data.isEmpty else { return }
        if name == "endpoint" {
            messageEndpoint = constructEndpoint(data)
            finishEndpointIfNeeded(error: nil)
            return
        }

        guard let payloadData = data.data(using: .utf8) else { return }
        if let json = try? JSONSerialization.jsonObject(with: payloadData) {
            Task { @MainActor in
                self.onMessage?(json)
            }
        } else {
            Task { @MainActor in
                self.onMessage?(data)
            }
        }
    }

    private func constructEndpoint(_ endpointPath: String) -> URL? {
        if let absolute = URL(string: endpointPath), absolute.scheme != nil {
            return absolute
        }
        if endpointPath.hasPrefix("/") {
            var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            if let endpointComponents = URLComponents(string: endpointPath) {
                components?.path = endpointComponents.path
                components?.query = endpointComponents.query
            } else {
                components?.path = endpointPath
            }
            return components?.url
        }
        return URL(string: endpointPath, relativeTo: serverURL)?.absoluteURL
    }

    private func finishEndpointIfNeeded(error: Error?) {
        endpointLock.lock()
        let continuation = endpointContinuation
        endpointContinuation = nil
        endpointLock.unlock()
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private static func appendingSessionId(to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "session_id" }) {
            items.append(URLQueryItem(name: "session_id", value: UUID().uuidString))
        }
        components.queryItems = items
        return components.url ?? url
    }
}
