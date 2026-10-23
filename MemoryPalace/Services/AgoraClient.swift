import Foundation

enum AgoraClientError: Error, Equatable, LocalizedError {
    case missingHubToken
    case invalidHubURL
    case disconnected
    case requestTimedOut
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingHubToken: "缺少 CC Hub token"
        case .invalidHubURL: "CC Hub 地址无效"
        case .disconnected: "中庭连接已断开"
        case .requestTimedOut: "中庭请求超时"
        case .malformedResponse: "中庭返回了无法解析的数据"
        }
    }
}

@MainActor
final class AgoraClient: NSObject, AgoraClientProtocol {
    var eventHandler: ((AgoraEvent) -> Void)?
    var reconnectHandler: (() -> Void)?
    var connectionStateHandler: ((AgoraConnectionState) -> Void)?

    private(set) var connectionState: AgoraConnectionState = .disconnected

    private struct PendingRequest {
        let timeoutTask: Task<Void, Never>
        let completion: (Result<Data, Error>) -> Void
    }

    private let configuredBaseURLs: [URL]?
    private let tokenProvider: () -> String?
    private let sessionConfiguration: URLSessionConfiguration
    private let requestTimeoutNanoseconds: UInt64
    private var urls: [URL] = []
    private var currentURLIndex = 0
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: UInt64 = 1
    private var pendingRequests: [String: PendingRequest] = [:]
    private var connectionWaiters: [CheckedContinuation<Void, Error>] = []
    private var manualDisconnect = false
    private var openingIsReconnect = false
    private var resumeCursors: [String: Int] = [:]
    private var resumeCursorOrder: [String] = []

    init(
        baseURLs: [URL]? = nil,
        tokenProvider: @escaping () -> String? = { HubTokenStore.get() },
        sessionConfiguration: URLSessionConfiguration = .default,
        requestTimeout: TimeInterval = 10
    ) {
        self.configuredBaseURLs = baseURLs
        self.tokenProvider = tokenProvider
        self.sessionConfiguration = sessionConfiguration
        self.requestTimeoutNanoseconds = UInt64(max(0.01, requestTimeout) * 1_000_000_000)
        super.init()
    }

    /// 不含中继：中继一期只转 /cc 和 /health（#068）
    static func configuredCCURLs(defaults: UserDefaults = .standard) -> [URL] {
        CCBridgeEndpoints.configuredURLs(includeRelay: false, defaults: defaults)
    }

    static func deriveAgoraURLs(from baseURLs: [URL], token: String) -> [URL] {
        var seen = Set<String>()
        return baseURLs.compactMap { baseURL in
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.path = "/agora"
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "token" || $0.name == "bundle" }
            items.append(URLQueryItem(name: "token", value: token))
            // 同 /cc：hub 按 MP_CC_ALLOWED_BUNDLES 只放行自己的 app
            if let bundle = Bundle.main.bundleIdentifier { items.append(URLQueryItem(name: "bundle", value: bundle)) }
            components.queryItems = items
            guard let url = components.url else { return nil }
            let key = "\(components.scheme ?? "")://\(components.host ?? ""):\(components.port.map(String.init) ?? "")\(components.path)"
            guard seen.insert(key).inserted else { return nil }
            return url
        }
    }

    func connect() async throws {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.quietNetwork { PerfGuardrails.suppress("agora"); throw CancellationError() }   // 测量角色不连 /agora（perf P0 §3.1）
        #endif
        if connectionState == .connected { return }

        if connectionState == .connecting || connectionState == .reconnecting {
            return try await waitForConnection()
        }

        guard let token = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            setConnectionState(.failed(AgoraClientError.missingHubToken.localizedDescription))
            throw AgoraClientError.missingHubToken
        }
        let bases = configuredBaseURLs ?? Self.configuredCCURLs()
        urls = Self.deriveAgoraURLs(from: bases, token: token)
        guard !urls.isEmpty else {
            setConnectionState(.failed(AgoraClientError.invalidHubURL.localizedDescription))
            throw AgoraClientError.invalidHubURL
        }

        manualDisconnect = false
        currentURLIndex = 0
        reconnectDelay = 1
        startSocket(isReconnect: false)
        try await waitForConnection()
    }

    func disconnect() {
        manualDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPing()
        let oldTask = task
        task = nil
        oldTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        failPendingRequests(with: AgoraClientError.disconnected)
        resumeConnectionWaiters(with: .failure(AgoraClientError.disconnected))
        setConnectionState(.disconnected)
    }

    func listActors() async throws -> [AgoraActorSummary] {
        let response: ActorListResponse = try await request(action: "actor.list", payload: EmptyPayload())
        return response.actors
    }

    func upsertCCActor(sessionName: String) async throws -> AgoraActorSummary {
        let response: ActorResponse = try await request(
            action: "actor.upsert_cc",
            payload: SessionPayload(sessionName: sessionName)
        )
        return response.actor
    }

    func listRooms(floorId: String) async throws -> [AgoraRoomSummary] {
        let response: RoomListResponse = try await request(
            action: "room.list",
            payload: FloorPayload(floorId: floorId)
        )
        return response.rooms
    }

    func createRoom(_ input: AgoraCreateRoomInput) async throws -> AgoraRoomCreateResult {
        try await request(action: "room.create", payload: input)
    }

    func openRoom(roomId: String, beforeSeq: Int?, limit: Int) async throws -> AgoraRoomOpenResult {
        let result: AgoraRoomOpenResult = try await request(
            action: "room.open",
            payload: OpenRoomPayload(roomId: roomId, beforeSeq: beforeSeq, limit: limit)
        )
        remember(messages: result.messages)
        return result
    }

    func messagesAfter(roomId: String, afterSeq: Int, limit: Int) async throws -> AgoraMessagePage {
        let result: AgoraMessagePage = try await request(
            action: "message.after",
            payload: MessagesAfterPayload(roomId: roomId, afterSeq: afterSeq, limit: limit)
        )
        remember(messages: result.messages)
        return result
    }

    func postMessage(roomId: String, clientMessageId: String, content: String) async throws -> AgoraPostResult {
        let result: AgoraPostResult = try await request(
            action: "message.post",
            payload: PostMessagePayload(roomId: roomId, clientMessageId: clientMessageId, content: content)
        )
        remember(message: result.message)
        return result
    }

    func editMessage(id: String, content: String) async throws -> AgoraMessage {
        let response: MessageResponse = try await request(
            action: "message.edit",
            payload: EditMessagePayload(messageId: id, content: content)
        )
        return response.message
    }

    func deleteMessage(id: String) async throws -> AgoraMessage {
        let response: MessageResponse = try await request(
            action: "message.delete",
            payload: DeleteMessagePayload(messageId: id)
        )
        return response.message
    }

    func setTyping(roomId: String, isTyping: Bool) async throws -> AgoraTypingPresence {
        let response: TypingResponse = try await request(
            action: isTyping ? "typing.start" : "typing.stop",
            payload: RoomPayload(roomId: roomId)
        )
        return response.typing
    }

    func startBridge(_ input: AgoraBridgeStartInput) async throws -> AgoraBridgeStartResult {
        try await request(action: "bridge.start", payload: input)
    }

    func stopBridge(id: String) async throws -> AgoraBridgeState {
        let response: BridgeStateResponse = try await request(
            action: "bridge.stop",
            payload: BridgeStopPayload(bridgeId: id)
        )
        return response.state
    }

    func bridgeStatus(roomId: String) async throws -> AgoraBridgeState? {
        let response: BridgeStatusResponse = try await request(
            action: "bridge.status",
            payload: RoomPayload(roomId: roomId)
        )
        return response.bridgeState
    }

    func listMentions(roomId: String, state: AgoraMentionState?, limit: Int) async throws -> [AgoraMention] {
        let response: MentionListResponse = try await request(
            action: "mention.list",
            payload: MentionListPayload(roomId: roomId, state: state, limit: limit)
        )
        return response.mentions
    }

    func retryMention(id: String) async throws -> AgoraMention {
        let response: MentionResponse = try await request(
            action: "mention.retry",
            payload: MentionRetryPayload(mentionId: id)
        )
        return response.mention
    }

    func getSettings() async throws -> AgoraSettings {
        try await request(action: "settings.get", payload: EmptyPayload())
    }

    func setSpeechMode(_ mode: AgoraSpeechMode) async throws -> AgoraSettings {
        try await request(
            action: "settings.update",
            payload: SpeechModePayload(speechMode: mode)
        )
    }

    func setMinSpeakInterval(ms: Int) async throws -> AgoraSettings {
        try await request(
            action: "settings.update",
            payload: MinSpeakIntervalPayload(minSpeakIntervalMs: ms)
        )
    }

    private func waitForConnection() async throws {
        if connectionState == .connected { return }
        try await withCheckedThrowingContinuation { continuation in
            connectionWaiters.append(continuation)
        }
    }

    private func startSocket(isReconnect: Bool) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.quietNetwork { PerfGuardrails.suppress("agora"); return }   // 重连 / 回前台 nudge 的唯一收口
        #endif
        guard !manualDisconnect else { return }
        // 每次起 socket（含重连）都现取 token 重算 URL——否则配对/换 token 后重连永远失败
        //（审计 #6：重连 token 冻结，07-19 粟粟真机踩中群聊全哑）
        if let token = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            let bases = configuredBaseURLs ?? Self.configuredCCURLs()
            let fresh = Self.deriveAgoraURLs(from: bases, token: token)
            if !fresh.isEmpty { urls = fresh }
        }
        guard urls.indices.contains(currentURLIndex) else { currentURLIndex = 0; return }
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPing()

        let oldTask = task
        task = nil
        oldTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()

        openingIsReconnect = isReconnect
        setConnectionState(isReconnect ? .reconnecting : .connecting)
        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
        let socket = session.webSocketTask(with: urls[currentURLIndex])
        self.session = session
        self.task = socket
        socket.resume()
    }

    private func beginReceiving(from socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            Task { @MainActor in
                guard let self, let socket, socket === self.task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.beginReceiving(from: socket)
                case .failure(let error):
                    self.handleSocketEnded(socket, error: error)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return
        }

        guard let probe = try? JSONDecoder().decode(IncomingProbe.self, from: data) else { return }
        switch probe.type {
        case "agora_response":
            guard let requestId = probe.requestId,
                  let pending = pendingRequests.removeValue(forKey: requestId) else { return }
            pending.timeoutTask.cancel()
            pending.completion(.success(data))
        case "agora_event":
            guard let event = try? AgoraJSON.decoder().decode(AgoraEvent.self, from: data) else { return }
            if case .message(let message) = event.data { remember(message: message) }
            eventHandler?(event)
        default:
            return
        }
    }

    private func handleSocketEnded(_ socket: URLSessionWebSocketTask, error: Error?) {
        guard socket === task else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        stopPing()
        let failure = error ?? AgoraClientError.disconnected
        failPendingRequests(with: failure)
        resumeConnectionWaiters(with: .failure(failure))
        guard !manualDisconnect else {
            setConnectionState(.disconnected)
            return
        }
        scheduleReconnect()
    }

    /// 前台恢复/用户动作时调：打断指数退避立即重连（切后台 socket 死 → 回前台最坏干等 30s 的修复）。
    func nudgeReconnect() {
        guard !manualDisconnect, connectionState != .connected, connectionState != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDelay = 1
        startSocket(isReconnect: true)
    }

    private func scheduleReconnect() {
        guard !urls.isEmpty, reconnectTask == nil else { return }
        setConnectionState(.reconnecting)
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        currentURLIndex = (currentURLIndex + 1) % urls.count
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled, !self.manualDisconnect else { return }
            self.reconnectTask = nil
            self.startSocket(isReconnect: true)
        }
    }

    private func startPing(for socket: URLSessionWebSocketTask) {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self, weak socket] _ in
            guard let self, let socket else { return }
            socket.sendPing { error in
                guard let error else { return }
                Task { @MainActor in self.handleSocketEnded(socket, error: error) }
            }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func remember(messages: [AgoraMessage]) {
        for message in messages { remember(message: message) }
    }

    private func remember(message: AgoraMessage) {
        if resumeCursors[message.roomId] == nil {
            resumeCursorOrder.append(message.roomId)
            if resumeCursorOrder.count > 100 {
                let expired = resumeCursorOrder.removeFirst()
                resumeCursors.removeValue(forKey: expired)
            }
        }
        resumeCursors[message.roomId] = max(resumeCursors[message.roomId] ?? 0, message.seq)
    }

    private func resumeMissedEvents() async throws {
        guard !resumeCursors.isEmpty else { return }
        var hasMore = true
        while hasMore, connectionState == .connected {
            let response: ResumeResponse = try await request(
                action: "sync.resume",
                payload: ResumePayload(cursors: resumeCursors)
            )
            hasMore = response.hasMore
        }
    }

    private func setConnectionState(_ state: AgoraConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        connectionStateHandler?(state)
    }

    private func failPendingRequests(with error: Error) {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.completion(.failure(error))
        }
    }

    private func resumeConnectionWaiters(with result: Result<Void, Error>) {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private func timeoutRequest(id: String) {
        guard let request = pendingRequests.removeValue(forKey: id) else { return }
        request.completion(.failure(AgoraClientError.requestTimedOut))
    }

    private func cancelRequest(id: String) {
        guard let request = pendingRequests.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.completion(.failure(CancellationError()))
    }

    private func request<Payload: Encodable, Response: Decodable>(
        action: String,
        payload: Payload
    ) async throws -> Response {
        guard connectionState == .connected, let socket = task else {
            throw AgoraClientError.disconnected
        }
        let requestId = UUID().uuidString.lowercased()
        let envelope = RequestEnvelope(requestId: requestId, action: action, payload: payload)
        let encoded = try AgoraJSON.encoder().encode(envelope)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw AgoraClientError.malformedResponse
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: self?.requestTimeoutNanoseconds ?? 0)
                    guard !Task.isCancelled else { return }
                    self?.timeoutRequest(id: requestId)
                }
                pendingRequests[requestId] = PendingRequest(
                    timeoutTask: timeoutTask,
                    completion: { result in
                        do {
                            let data = try result.get()
                            let envelope = try AgoraJSON.decoder().decode(ResponseEnvelope<Response>.self, from: data)
                            guard envelope.requestId == requestId else { throw AgoraClientError.malformedResponse }
                            if let error = envelope.error { throw error }
                            guard let value = envelope.data else { throw AgoraClientError.malformedResponse }
                            continuation.resume(returning: value)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                )
                socket.send(.string(text)) { [weak self, weak socket] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        if let pending = self.pendingRequests.removeValue(forKey: requestId) {
                            pending.timeoutTask.cancel()
                            pending.completion(.failure(error))
                        }
                        if let socket { self.handleSocketEnded(socket, error: error) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id: requestId) }
        }
    }
}

extension AgoraClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.task else { return }
            let reconnected = self.openingIsReconnect
            self.reconnectDelay = 1
            self.setConnectionState(.connected)
            self.resumeConnectionWaiters(with: .success(()))
            self.beginReceiving(from: webSocketTask)
            self.startPing(for: webSocketTask)
            if reconnected {
                try? await self.resumeMissedEvents()
                if self.connectionState == .connected { self.reconnectHandler?() }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            self?.handleSocketEnded(webSocketTask, error: AgoraClientError.disconnected)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let socket = task as? URLSessionWebSocketTask, let error else { return }
        Task { @MainActor [weak self] in
            self?.handleSocketEnded(socket, error: error)
        }
    }
}

private struct RequestEnvelope<Payload: Encodable>: Encodable {
    let type = "agora_request"
    let requestId: String
    let action: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case type, action, payload
        case requestId = "request_id"
    }
}

private struct ResponseEnvelope<Response: Decodable>: Decodable {
    let requestId: String
    let ok: Bool
    let data: Response?
    let error: AgoraProtocolError?

    enum CodingKeys: String, CodingKey {
        case ok, data, error
        case requestId = "request_id"
    }
}

private struct IncomingProbe: Decodable {
    let type: String
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
    }
}

private struct EmptyPayload: Encodable {}
private struct ActorListResponse: Decodable { let actors: [AgoraActorSummary] }
private struct ActorResponse: Decodable { let actor: AgoraActorSummary }
private struct RoomListResponse: Decodable { let rooms: [AgoraRoomSummary] }
private struct MentionListResponse: Decodable { let mentions: [AgoraMention] }
private struct MentionResponse: Decodable { let mention: AgoraMention }
private struct MessageResponse: Decodable { let message: AgoraMessage }
private struct TypingResponse: Decodable { let typing: AgoraTypingPresence }
private struct BridgeStateResponse: Decodable {
    let bridge: AgoraBridge
    let currentTurn: AgoraBridgeTurn?

    enum CodingKeys: String, CodingKey {
        case bridge
        case currentTurn = "current_turn"
    }

    var state: AgoraBridgeState { AgoraBridgeState(bridge: bridge, currentTurn: currentTurn) }
}
private struct BridgeStatusResponse: Decodable {
    let bridgeState: AgoraBridgeState?
    enum CodingKeys: String, CodingKey { case bridgeState = "bridge_state" }
}
private struct ResumePayload: Encodable { let cursors: [String: Int] }
private struct ResumeResponse: Decodable {
    let replayedCount: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case replayedCount = "replayed_count"
        case hasMore = "has_more"
    }
}

private struct SessionPayload: Encodable {
    let sessionName: String
    enum CodingKeys: String, CodingKey { case sessionName = "session_name" }
}

private struct FloorPayload: Encodable {
    let floorId: String
    enum CodingKeys: String, CodingKey { case floorId = "floor_id" }
}

private struct RoomPayload: Encodable {
    let roomId: String
    enum CodingKeys: String, CodingKey { case roomId = "room_id" }
}

private struct OpenRoomPayload: Encodable {
    let roomId: String
    let beforeSeq: Int?
    let limit: Int
    enum CodingKeys: String, CodingKey {
        case limit
        case roomId = "room_id"
        case beforeSeq = "before_seq"
    }
}

private struct MessagesAfterPayload: Encodable {
    let roomId: String
    let afterSeq: Int
    let limit: Int
    enum CodingKeys: String, CodingKey {
        case limit
        case roomId = "room_id"
        case afterSeq = "after_seq"
    }
}

private struct PostMessagePayload: Encodable {
    let roomId: String
    let clientMessageId: String
    let content: String
    enum CodingKeys: String, CodingKey {
        case content
        case roomId = "room_id"
        case clientMessageId = "client_message_id"
    }
}

private struct EditMessagePayload: Encodable {
    let messageId: String
    let content: String
    enum CodingKeys: String, CodingKey {
        case content
        case messageId = "message_id"
    }
}

private struct DeleteMessagePayload: Encodable {
    let messageId: String
    enum CodingKeys: String, CodingKey { case messageId = "message_id" }
}

private struct BridgeStopPayload: Encodable {
    let bridgeId: String
    enum CodingKeys: String, CodingKey { case bridgeId = "bridge_id" }
}

private struct MentionListPayload: Encodable {
    let roomId: String
    let state: AgoraMentionState?
    let limit: Int
    enum CodingKeys: String, CodingKey {
        case state, limit
        case roomId = "room_id"
    }
}

private struct MentionRetryPayload: Encodable {
    let mentionId: String
    enum CodingKeys: String, CodingKey { case mentionId = "mention_id" }
}

private struct SpeechModePayload: Encodable {
    let speechMode: AgoraSpeechMode
    enum CodingKeys: String, CodingKey { case speechMode = "speech_mode" }
}

private struct MinSpeakIntervalPayload: Encodable {
    let minSpeakIntervalMs: Int
    enum CodingKeys: String, CodingKey { case minSpeakIntervalMs = "min_speak_interval_ms" }
}
