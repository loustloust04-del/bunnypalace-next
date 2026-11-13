import Foundation
import Network

/// 服务器只要一个能回响应的对象：生产是 `MemorydService`，测试可以塞一个慢的
protocol HTTPResponder: Sendable {
    func respond(_ request: HTTPRequest) async -> HTTPResponse
    func bind(port: UInt16)
}

/// 200 行的小 HTTP/1.1：只监听 127.0.0.1、只 GET / POST、Content-Length 定长、一请求一连接。
final class HTTPServer {
    private let service: any HTTPResponder
    private let listener: NWListener
    private let readTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.susu.memoryd.http", qos: .userInitiated)
    private let lock = NSLock()
    private var ready = false
    private var startError: Error?
    private var boundPort: UInt16 = 0

    init(port: UInt16, service: any HTTPResponder, readTimeout: TimeInterval = 10) throws {
        self.service = service
        self.readTimeout = readTimeout
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let local = NWEndpoint.Port(rawValue: port) else { throw MemorydServerError.badPort(port) }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: local)
        listener = try NWListener(using: parameters)
    }

    /// 起监听并等到 ready；返回实际端口（`--port 0` 时由系统分配）
    func start(timeout: TimeInterval = 10) throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.boundPort = self.listener.port?.rawValue ?? 0
                self.ready = true
                self.lock.unlock()
            case .failed(let error):
                self.lock.lock()
                self.startError = error
                self.ready = true
                self.lock.unlock()
            case .cancelled:
                self.lock.lock()
                self.ready = true
                self.lock.unlock()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            let done = ready
            let error = startError
            let port = boundPort
            lock.unlock()
            if let error { throw error }
            if done, port != 0 {
                service.bind(port: port)
                return port
            }
            if Date() > deadline { throw MemorydServerError.startTimeout }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { [service, readTimeout] in
            // 读请求期限只盖读这一段：连上不说话、头发一半、体发一半都不让它一直挂着。
            // 读完立刻撤——跑批可能跑几十秒，不能把处理和回响应也算进期限里
            let deadline = Task {
                do { try await Task.sleep(nanoseconds: UInt64(readTimeout * 1_000_000_000)) } catch { return }
                connection.cancel()
            }
            let request: HTTPRequest?
            do {
                request = try await Self.readRequest(connection)
            } catch {
                deadline.cancel()
                let response = HTTPResponse.error(400, "\(error)")
                try? await Self.send(response.encoded(), on: connection)
                connection.cancel()
                return
            }
            deadline.cancel()
            guard let request else {
                connection.cancel()
                return
            }
            do {
                let response = await service.respond(request)
                try await Self.send(response.encoded(), on: connection)
            } catch {
                let response = HTTPResponse.error(400, "\(error)")
                try? await Self.send(response.encoded(), on: connection)
            }
            connection.cancel()
        }
    }

    private static func readRequest(_ connection: NWConnection) async throws -> HTTPRequest? {
        var parser = HTTPRequestParser()
        while true {
            let chunk = try await receive(connection)
            if chunk.isEmpty { return nil }
            if let request = try parser.append(chunk) { return request }
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    _ = isComplete
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

enum MemorydServerError: LocalizedError {
    case badPort(UInt16)
    case startTimeout

    var errorDescription: String? {
        switch self {
        case .badPort(let port): return "端口不合法：\(port)"
        case .startTimeout: return "监听起不来（10 秒没 ready）"
        }
    }
}
