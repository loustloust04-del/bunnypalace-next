import Foundation
import Network

final class ScriptedHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScriptedHTTPServer")
    private let lock = NSLock()
    private let respond: (Int, Data) -> Response
    private var bodies: [Data] = []

    struct Response {
        var status: Int
        var contentType: String
        var body: Data
        var headers: [String: String] = [:]
        /// 声明的 Content-Length 比实际 body 长 → 发完就断，客户端见到连接中途断开
        var declaredLength: Int? = nil
    }

    convenience init(respond: @escaping (Int, Data) -> (status: Int, contentType: String, body: Data)) throws {
        try self.init(responding: { index, body in
            let r = respond(index, body)
            return Response(status: r.status, contentType: r.contentType, body: r.body)
        })
    }

    /// 带响应头（Retry-After 等）
    init(responding: @escaping (Int, Data) -> Response) throws {
        self.respond = responding
        listener = try NWListener(using: .tcp, on: .any)
    }

    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)/v1" }
    var requestBodies: [Data] { lock.withLock { bodies } }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection, accumulated: Data())
            connection.start(queue: self?.queue ?? .global())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success else { throw URLError(.timedOut) }
    }

    func stop() { listener.cancel() }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = accumulated
            if let data { accumulated.append(data) }
            if let body = Self.completeBody(from: accumulated) {
                let index = self.lock.withLock { () -> Int in
                    self.bodies.append(body)
                    return self.bodies.count - 1
                }
                let r = self.respond(index, body)
                let reason = r.status == 200 ? "OK" : "Bad Request"
                let extra = r.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
                var response = Data("HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\n\(extra)Content-Length: \(r.declaredLength ?? r.body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(r.body)
                connection.send(content: response, completion: .contentProcessed { [queue] _ in
                    // 截断的响应：等客户端把已发的那片读走再断，否则 RST 会连带丢掉没读的数据
                    if r.declaredLength == nil { connection.cancel() } else { queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() } }
                })
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, accumulated: accumulated)
            }
        }
    }

    private static func completeBody(from request: Data) -> Data? {
        guard let headerRange = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
        let length = header.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let start = headerRange.upperBound
        guard request.distance(from: start, to: request.endIndex) >= length else { return nil }
        return request.subdata(in: start..<(start + length))
    }
}
