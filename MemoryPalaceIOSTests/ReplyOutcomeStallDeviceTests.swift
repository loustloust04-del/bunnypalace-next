import Network
import XCTest
@testable import 记忆花园

/// 11-07 iPhone 14 真机：卡住看门狗在真网络栈下的表现（plan-reply-error-report-1106 第 2 步）。
/// 上游是本机 NWListener 假 SSE 服务，只连 127.0.0.1，不访问外网、不用真 key。
/// 车头用 TEST_RUNNER_MP_STALL_DEVICE=1 注入才跑，否则整类跳过。
///
/// 用自带的假上游而不是 ScriptedHTTPServer：后者每条响应固定 `Connection: close`、发完即断，
/// 既不能按秒滴帧，也不能在 90 秒空闲超时前把连接撑住；三条用例都要求长连接。
@MainActor
final class ReplyOutcomeStallDeviceTests: XCTestCase {

    private var manager: ProviderManager?
    private var credentialId: String?
    private var server: HoldingSSEServer?

    override func setUp() async throws {
        guard Self.env("MP_STALL_DEVICE") == "1" else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STALL_DEVICE=1，不上设备跑卡住看门狗")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "ReplyOutcomeStallDevice", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 900
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        credentialId = nil
    }

    // MARK: - 1. 出过增量后不动：默认阈值 45 秒提示 / 180 秒硬停

    func testMidStreamStallRealThresholdsOnDevice() async throws {
        let server = try startServer(.midStream(firstChunk: Self.content("你好"), keepAliveEvery: 10))
        let (router, model) = try makeRouter(baseURL: server.baseURL)
        let recorder = Recorder()
        let started = Date()
        let done = expectation(description: "settle")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "写一段话")],
            systemPrompt: nil,
            providerManager: try XCTUnwrap(manager),
            onToken: { recorder.addToken($0) },
            onComplete: { text, _ in
                recorder.addCompletion(text)
                if recorder.claimSettle() { done.fulfill() }
            },
            onError: { message in
                recorder.addError(message)
                if recorder.claimSettle() { done.fulfill() }
            },
            onStallNotice: { recorder.addNotice($0) }
        )
        await fulfillment(of: [done], timeout: 210)
        Self.report("testMidStreamStallRealThresholdsOnDevice", since: started, recorder: recorder,
                    outcome: router.lastReplyOutcome)

        let notice = try XCTUnwrap(recorder.notices.first, "没收到「上游中途停住了」")
        let complete = try XCTUnwrap(recorder.completions.first, "硬停后没有 onComplete")
        XCTAssertEqual(recorder.notices.count, 1, "提示只来一次")
        XCTAssertEqual(notice.text, "上游中途停住了")
        let noticeAt = notice.at.timeIntervalSince(started)
        XCTAssertTrue((40...55).contains(noticeAt), "提示时间 \(noticeAt)s 不在 40–55 秒")
        let completeAt = complete.at.timeIntervalSince(started)
        XCTAssertTrue((175...195).contains(completeAt), "硬停时间 \(completeAt)s 不在 175–195 秒")
        XCTAssertEqual(recorder.completions.count, 1)
        XCTAssertTrue(complete.text.contains("你好"), "已出的正文要保留：\(complete.text)")
        XCTAssertEqual(router.lastReplyOutcome, .stalledMidStream)
        XCTAssertTrue(recorder.errors.isEmpty, "keep-alive 在续，90 秒空闲超时不能触发：\(recorder.errors.map(\.text))")
    }

    // MARK: - 2. 只有 keep-alive：注入 5 秒提示 / 20 秒硬停

    func testFirstByteStallScaledThresholdsOnDevice() async throws {
        let server = try startServer(.firstByte(keepAliveEvery: 3))
        let (router, model) = try makeRouter(baseURL: server.baseURL)
        var config = StallWatchdogConfig()
        config.tick = 0.5
        config.firstByteNotice = 5
        config.firstByteHardStop = 20
        router.stallWatchdogConfig = config
        let recorder = Recorder()
        let started = Date()
        let done = expectation(description: "settle")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "写一段话")],
            systemPrompt: nil,
            providerManager: try XCTUnwrap(manager),
            onToken: { recorder.addToken($0) },
            onComplete: { text, _ in
                recorder.addCompletion(text)
                if recorder.claimSettle() { done.fulfill() }
            },
            onError: { message in
                recorder.addError(message)
                if recorder.claimSettle() { done.fulfill() }
            },
            onStallNotice: { recorder.addNotice($0) }
        )
        await fulfillment(of: [done], timeout: 40)
        Self.report("testFirstByteStallScaledThresholdsOnDevice", since: started, recorder: recorder,
                    outcome: router.lastReplyOutcome)

        let notice = try XCTUnwrap(recorder.notices.first, "没收到「已连上，上游在排队」")
        let complete = try XCTUnwrap(recorder.completions.first, "硬停后没有 onComplete")
        XCTAssertEqual(notice.text, "已连上，上游在排队")
        let noticeAt = notice.at.timeIntervalSince(started)
        XCTAssertTrue((4...8).contains(noticeAt), "提示时间 \(noticeAt)s 不在 4–8 秒")
        let completeAt = complete.at.timeIntervalSince(started)
        XCTAssertTrue((18...25).contains(completeAt), "硬停时间 \(completeAt)s 不在 18–25 秒")
        XCTAssertEqual(complete.text, "", "一个增量都没有，正文必须为空")
        XCTAssertEqual(router.lastReplyOutcome, .stalledFirstByte)
        XCTAssertTrue(recorder.errors.isEmpty, "硬停不是报错：\(recorder.errors.map(\.text))")
    }

    // MARK: - 3. 一个字节都没有：回完 200 + SSE 头就静默，90 秒空闲超时

    func testNoBytesHitsNinetySecondTimeoutOnDevice() async throws {
        let server = try startServer(.silent)
        let (router, model) = try makeRouter(baseURL: server.baseURL)
        let recorder = Recorder()
        let started = Date()
        let done = expectation(description: "settle")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "写一段话")],
            systemPrompt: nil,
            providerManager: try XCTUnwrap(manager),
            onToken: { recorder.addToken($0) },
            onComplete: { text, _ in
                recorder.addCompletion(text)
                if recorder.claimSettle() { done.fulfill() }
            },
            onError: { message in
                recorder.addError(message)
                if recorder.claimSettle() { done.fulfill() }
            },
            onStallNotice: { recorder.addNotice($0) }
        )
        await fulfillment(of: [done], timeout: 120)
        Self.report("testNoBytesHitsNinetySecondTimeoutOnDevice", since: started, recorder: recorder,
                    outcome: router.lastReplyOutcome)

        let error = try XCTUnwrap(recorder.errors.first, "90 秒空闲超时没有报错")
        let errorAt = error.at.timeIntervalSince(started)
        XCTAssertTrue((85...100).contains(errorAt), "超时时间 \(errorAt)s 不在 85–100 秒")
        XCTAssertEqual(error.text, "上游太久没回，请求超时了")
        XCTAssertTrue(recorder.completions.isEmpty)
        XCTAssertTrue(recorder.notices.isEmpty, "一个字节都没收到，不该有「已连上」提示")
    }

    // MARK: - 夹具

    private static func env(_ name: String) -> String? {
        getenv(name).flatMap { String(cString: $0) }
    }

    private static func content(_ text: String) -> Data {
        Data(#"data: {"choices":[{"delta":{"content":"\#(text)"}}]}"#.appending("\n\n").utf8)
    }

    private static func report(_ name: String, since start: Date, recorder: Recorder, outcome: ReplyOutcome) {
        func stamp(_ date: Date?) -> String {
            guard let date else { return "@none" }
            return String(format: "@%.1fs", date.timeIntervalSince(start))
        }
        print("[STALL-DEVICE] \(name) notice\(stamp(recorder.notices.first?.at))"
            + " complete\(stamp(recorder.completions.first?.at))"
            + " error\(stamp(recorder.errors.first?.at))"
            + " outcome=\(outcome.rawValue)")
    }

    private func startServer(_ mode: HoldingSSEServer.Mode) throws -> HoldingSSEServer {
        let server = try HoldingSSEServer(mode: mode)
        try server.start()
        self.server = server
        return server
    }

    private func makeRouter(baseURL: String) throws -> (ProviderRouter, ProviderModel) {
        let id = "xctest-stall-device-\(UUID().uuidString)"
        credentialId = id
        let model = ProviderModel(credentialId: id, modelId: "stall-device-model", name: "本地假上游")
        let manager = ProviderManager()
        self.manager = manager
        manager.addCredential(APICredential(id: id, name: "本地假上游", emoji: "", type: .openaiCompatible,
                                            baseURL: baseURL, models: [model], toolsSupported: false))
        XCTAssertTrue(manager.setApiKey("stall-device-fake-key", for: id), "测试钥匙串写不进假 key")
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-device-\(UUID().uuidString).jsonl"))
        return (router, model)
    }
}

/// 回调可能来自 URLSession delegate 队列，记录与「只结算一次」都加锁
private final class Recorder {
    private let lock = NSLock()
    private var _tokens: [String] = []
    private var _notices: [(text: String, at: Date)] = []
    private var _completions: [(text: String, at: Date)] = []
    private var _errors: [(text: String, at: Date)] = []
    private var _settled = false

    func addToken(_ token: String) { lock.withLock { _tokens.append(token) } }
    func addNotice(_ text: String) { let now = Date(); lock.withLock { _notices.append((text, now)) } }
    func addCompletion(_ text: String) { let now = Date(); lock.withLock { _completions.append((text, now)) } }
    func addError(_ message: String) { let now = Date(); lock.withLock { _errors.append((message, now)) } }

    func claimSettle() -> Bool {
        lock.withLock {
            guard !_settled else { return false }
            _settled = true
            return true
        }
    }

    var tokens: [String] { lock.withLock { _tokens } }
    var notices: [(text: String, at: Date)] { lock.withLock { _notices } }
    var completions: [(text: String, at: Date)] { lock.withLock { _completions } }
    var errors: [(text: String, at: Date)] { lock.withLock { _errors } }
}

/// 会按秒滴帧、并且永不主动断开的本机假 SSE 上游（只绑 127.0.0.1）。
private final class HoldingSSEServer {
    enum Mode {
        /// 先给一帧正文，之后每 keepAliveEvery 秒一行 `: keep-alive`；不发 [DONE]，连接一直开着
        case midStream(firstChunk: Data, keepAliveEvery: TimeInterval)
        /// 只发 `: keep-alive`
        case firstByte(keepAliveEvery: TimeInterval)
        /// 回完响应头就静默
        case silent
    }

    private static let keepAlive = Data(": keep-alive\n\n".utf8)

    private let listener: NWListener
    private let mode: Mode
    private let queue = DispatchQueue(label: "StallDeviceSSEServer")
    private var connections: [NWConnection] = []
    private var stopped = false

    init(mode: Mode) throws {
        self.mode = mode
        listener = try NWListener(using: .tcp, on: .any)
    }

    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)/v1" }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.queue.async {
                guard !self.stopped else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receiveRequest(on: connection, accumulated: Data())
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success else { throw URLError(.timedOut) }
    }

    func stop() {
        queue.sync {
            stopped = true
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener.cancel()
        }
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = accumulated
            if let data { accumulated.append(data) }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, accumulated: accumulated)
        }
    }

    private func respond(on connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        switch mode {
        case .midStream(let firstChunk, let keepAliveEvery):
            sendChunk(firstChunk, on: connection)
            scheduleKeepAlive(on: connection, every: keepAliveEvery)
        case .firstByte(let keepAliveEvery):
            sendChunk(Self.keepAlive, on: connection)
            scheduleKeepAlive(on: connection, every: keepAliveEvery)
        case .silent:
            break
        }
    }

    private func sendChunk(_ payload: Data, on connection: NWConnection) {
        var frame = Data(String(payload.count, radix: 16).utf8)
        frame.append(Data("\r\n".utf8))
        frame.append(payload)
        frame.append(Data("\r\n".utf8))
        connection.send(content: frame, completion: .idempotent)
    }

    private func scheduleKeepAlive(on connection: NWConnection, every interval: TimeInterval) {
        queue.asyncAfter(deadline: .now() + interval) { [weak self, weak connection] in
            guard let self, let connection, !self.stopped else { return }
            self.sendChunk(Self.keepAlive, on: connection)
            self.scheduleKeepAlive(on: connection, every: interval)
        }
    }
}
