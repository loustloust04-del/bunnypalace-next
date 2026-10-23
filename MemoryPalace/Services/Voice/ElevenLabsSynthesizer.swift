import Foundation

/// ElevenLabs（plan-voice-providers V2a）：按模型分流
/// - `eleven_v4` / `eleven_v4_turbo`：对话接口 `POST /v1/text-to-dialogue`（`inputs[{text,voice_id}]` + `settings{stability, similarity}`）
/// - `eleven_v4_turbo` 另有 `openStream`：WSS `/v1/text-to-dialogue/stream-input`，边收边播 PCM 24k
/// - `eleven_v3`：老 TTS 接口 `/v1/text-to-speech/{voice}`，带 style / speed（保持原行为）
struct ElevenLabsSynthesizer: VoiceSynthesizer {
    static let v4 = "eleven_v4"
    static let v4Turbo = "eleven_v4_turbo"
    static let v3 = "eleven_v3"
    static let apiBase = URL(string: "https://api.elevenlabs.io/v1")!
    static let streamBase = URL(string: "wss://api.elevenlabs.io/v1")!
    static let fileFormat = "mp3_44100_128"
    static let streamFormat = "pcm_24000"
    static let streamSampleRate = 24_000
    /// 单次请求上限：对话接口（v4 系）官方 2000 字；v3 老接口取保守 3000
    static let dialogueTextLimit = 2_000
    static let v3TextLimit = 3_000
    static let contextLimit = 100
    /// 整段路线预连接：不带 key 的 HEAD，只为连接进池（响应码不管）
    static let prewarmURL = URL(string: "https://api.elevenlabs.io/")!
    static let prewarmInterval: TimeInterval = 20

    /// 懒读：设置页每次渲染都要 capabilities，别为它碰钥匙串
    let keyProvider: () -> String?
    var session: URLSession = .shared
    /// 测试注入假 WebSocket
    var transportFactory: (URL) -> any VoiceWebSocketTransport = { URLSessionWebSocketTransport(url: $0) }
    /// 拷贝共用一把：Route 持有的实例 = 一通电话一把
    var prewarmThrottle = PrewarmThrottle(interval: ElevenLabsSynthesizer.prewarmInterval)

    var capabilities: VoiceCapabilities {
        let v4Tunables: [VoiceTunable] = [.stability, .similarity]
        return VoiceCapabilities(
            supportsTags: true,
            supportsStreaming: true,
            canFetchVoices: true,
            tunables: v4Tunables,
            models: [
                VoiceModelOption(id: Self.v4, name: "Eleven v4", tunables: v4Tunables),
                VoiceModelOption(id: Self.v4Turbo, name: "Eleven v4 Turbo", tunables: v4Tunables, streaming: true),
                VoiceModelOption(id: Self.v3, name: "Eleven v3", tunables: [.stability, .similarity, .style, .speed]),
            ]
        )
    }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
        try await synthesize(text: text, voice: voice, model: model, tuning: tuning, context: nil)
    }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings,
                    context: VoiceSynthesisContext?) async throws -> AudioClip {
        guard let apiKey = keyProvider() else { throw VoiceSynthError.missingKey }
        guard let voice, !voice.isEmpty else { throw VoiceSynthError.missingVoice }
        let resolved = capabilities.resolvedModel(model) ?? Self.v4
        try VoiceHTTP.ensureLength(text, limit: resolved == Self.v3 ? Self.v3TextLimit : Self.dialogueTextLimit)
        var req = try Self.synthesizeRequest(text: text, voice: voice, model: resolved, tuning: tuning, context: context)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await VoiceHTTP.send(req, session: session, delegate: VoiceRequestMetricsProbe.shared)
        try VoiceHTTP.check(resp, body: data, secrets: [apiKey])
        guard !data.isEmpty else { throw VoiceSynthError.badAudio }
        return AudioClip(data: data, format: .mp3, sampleRate: 44_100)
    }

    /// 不含 key 的请求（key 由调用方补 header）。
    /// context 只给对话接口（v4 系）：`previous_text` / `future_text` 官方单边上限 100 字；
    /// v3 老接口不带——官方说 eleven_v3 不支持请求拼接（previous_text / next_text）
    static func synthesizeRequest(text: String, voice: String, model: String, tuning: VoiceTuning.Settings,
                                  context: VoiceSynthesisContext? = nil) throws -> URLRequest {
        if model == v3 {
            let url = withFormat(apiBase.appendingPathComponent("text-to-speech/\(voice)"), fileFormat)
            return try VoiceHTTP.jsonRequest(url, body: [
                "text": text,
                "model_id": v3,
                "voice_settings": [
                    "stability": v3Stability(tuning.stability),
                    "similarity_boost": tuning.similarityBoost,
                    "style": tuning.style,
                    "speed": tuning.speed,
                ],
            ])
        }
        let url = withFormat(apiBase.appendingPathComponent("text-to-dialogue"), fileFormat)
        var body: [String: Any] = [
            "inputs": [["text": text, "voice_id": voice]],
            "model_id": model,
            "settings": ["stability": tuning.stability, "similarity": tuning.similarityBoost],
        ]
        if let previous = context?.previous.map({ String($0.suffix(contextLimit)) }), !previous.isEmpty { body["previous_text"] = previous }
        if let next = context?.next.map({ String($0.prefix(contextLimit)) }), !next.isEmpty { body["future_text"] = next }
        return try VoiceHTTP.jsonRequest(url, body: body)
    }

    /// v3 的 stability 只认三档（0 奔放 / 0.5 自然 / 1 沉稳）；v4 是连续值（V0 探针），共用一个设置，v3 时钳到最近档
    static func v3Stability(_ value: Double) -> Double {
        value < 0.25 ? 0.0 : (value < 0.75 ? 0.5 : 1.0)
    }

    func fetchVoices() async throws -> [VoiceOption] {
        guard let apiKey = keyProvider() else { throw VoiceSynthError.missingKey }
        var req = URLRequest(url: Self.apiBase.appendingPathComponent("voices"))
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await VoiceHTTP.send(req, session: session)
        try VoiceHTTP.check(resp, body: data, secrets: [apiKey])
        struct VoicesResponse: Decodable {
            struct V: Decodable {
                let voice_id: String
                let name: String
                let preview_url: String?
                let category: String?
            }
            let voices: [V]
        }
        guard let decoded = try? JSONDecoder().decode(VoicesResponse.self, from: data) else {
            throw VoiceSynthError.server(resp?.statusCode ?? 200, "声音列表格式不对")
        }
        return decoded.voices.map {
            VoiceOption(id: $0.voice_id, name: $0.name, previewURL: $0.preview_url.flatMap(URL.init(string:)),
                        detail: $0.category)
        }
    }

    /// 同一个 session 上对 api.elevenlabs.io 发 HEAD：不带 `xi-api-key`、不读钥匙串、不计费，
    /// 只让 DNS / TCP / TLS 先走完，后面的整段 POST 复用池里的连接。`prewarmInterval` 内只发一次
    func prewarmConnection() {
        guard prewarmThrottle.claim() else { return }
        var req = URLRequest(url: Self.prewarmURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let session = self.session
        Task.detached { _ = try? await session.data(for: req) }
    }

    /// 只有能流式的模型（v4 Turbo）给会话；连接在第一次 send / flush 时才开（不说话不花钱）
    func openStream(voice: String?, model: String?) -> (any VoiceStream)? {
        let resolved = capabilities.resolvedModel(model) ?? Self.v4
        guard capabilities.models.first(where: { $0.id == resolved })?.streaming == true,
              let voice, !voice.isEmpty else { return nil }
        return ElevenLabsDialogueStream(
            url: ElevenLabsDialogueFrames.streamURL(model: resolved),
            voiceId: voice, keyProvider: keyProvider, transportFactory: transportFactory
        )
    }

    private static func withFormat(_ url: URL, _ format: String) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "output_format", value: format)]
        return comps.url!
    }
}

/// 预连接效果探针：整段合成请求有没有复用连接（`.debug`，平时不落盘）。只记 metrics，不记 URL 参数 / header
final class VoiceRequestMetricsProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = VoiceRequestMetricsProbe()

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last else { return }
        func ms(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "-" }
            return String(Int((end.timeIntervalSince(start) * 1000).rounded()))
        }
        callLog.debug("""
            ElevenLabs 整段请求 reused=\(t.isReusedConnection, privacy: .public) proto=\(t.networkProtocolName ?? "-", privacy: .public) \
            connect=\(ms(t.connectStartDate, t.connectEndDate), privacy: .public)ms ttfb=\(ms(t.requestStartDate, t.responseStartDate), privacy: .public)ms
            """)
    }
}

/// 预连接节流：`interval` 秒内只放行一次
final class PrewarmThrottle: @unchecked Sendable {
    let interval: TimeInterval
    private let lock = NSLock()
    private var last: Date?

    init(interval: TimeInterval) { self.interval = interval }

    func claim(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }
}

// MARK: - WebSocket 帧（纯函数，可测）

enum ElevenLabsDialogueFrames {
    struct Incoming: Equatable {
        var audio: Data?
        var isFinal = false
        var error: String?
    }

    static func streamURL(model: String, base: URL = ElevenLabsSynthesizer.streamBase,
                          outputFormat: String = ElevenLabsSynthesizer.streamFormat) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("text-to-dialogue/stream-input"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "model_id", value: model),
                            URLQueryItem(name: "output_format", value: outputFormat)]
        return comps.url!
    }

    /// 首帧：注册声音 + key（Turbo 只能 1 个声音）
    static func initFrame(voiceId: String, apiKey: String) -> String {
        encode(["voices": [voiceId], "xi_api_key": apiKey])
    }

    static func textFrame(_ text: String, voiceId: String) -> String {
        encode(["inputs": [["text": text, "voice_id": voiceId]]])
    }

    static let flushFrame = #"{"flush":true}"#
    static let keepAliveFrame = #"{"keep_alive":true}"#
    static let closeFrame = #"{"close_socket":true}"#

    /// 回包：`audio`（base64 PCM）、`is_final`、`error`（字符串或对象）；认不出来的字段忽略
    static func decode(_ text: String) -> Incoming {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return Incoming(error: "回包不是 JSON")
        }
        var out = Incoming()
        if let b64 = obj["audio"] as? String, !b64.isEmpty {
            out.audio = Data(base64Encoded: b64)
            if out.audio == nil { out.error = "音频块解不开" }
        }
        out.isFinal = (obj["is_final"] as? Bool) ?? ((obj["isFinal"] as? Bool) ?? false)
        // 错误帧形如 {"error":"invalid_api_key","message":"…"} 或 {"error":{"message":…}}
        let message = obj["message"] as? String
        if let e = obj["error"] as? String, !e.isEmpty {
            out.error = [e, message].compactMap { $0 }.joined(separator: ": ")
        } else if let e = obj["error"] as? [String: Any] {
            out.error = (e["message"] as? String) ?? (e["code"] as? String) ?? message ?? "服务端报错"
        }
        return out
    }

    /// 服务端错误文字 → 统一错误（key / 额度能认出来的认出来）；带出去的文字先用本次 key 去敏再截
    static func mapError(_ message: String, secrets: [String]) -> VoiceSynthError {
        let m = message.lowercased()
        if m.contains("api key") || m.contains("api_key") || m.contains("unauthorized") || m.contains("invalid_api") {
            return .invalidKey
        }
        if m.contains("quota") || m.contains("rate limit") || m.contains("too many") {
            return .quotaOrRateLimited
        }
        return .server(0, VoiceHTTP.clip(message, secrets: secrets))
    }

    private static func encode(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - WebSocket 传输（测试注入假实现）

protocol VoiceWebSocketTransport: AnyObject {
    func connect()
    func send(_ text: String) async throws
    /// 下一条文本帧；连接关了返回 nil
    func receive() async throws -> String?
    func close()
}

final class URLSessionWebSocketTransport: VoiceWebSocketTransport {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
    }

    func connect() { task.resume() }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return nil
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}

// MARK: - 流式会话

/// 通话预建连（V4 `CallSpeechPipeline` 的约定）：没连 → 建连 + 首帧注册声音（不发字、不计费）；已连 → 发一帧 `keep_alive`
extension ElevenLabsDialogueStream: VoiceStreamKeepAlive {
    func keepAlive() async throws {
        if isConnected {
            try await write(ElevenLabsDialogueFrames.keepAliveFrame)
        } else {
            _ = try await connectIfNeeded()
        }
    }
}

/// v4 Turbo 对话 WebSocket 会话：首个 send / `keepAlive()` 时连接并发首帧；每句一帧；`flush` 已连才发；
/// 闲 10 秒自动 `keep_alive`（服务端 20 秒没消息会断）；`finish` 发 `close_socket` 后等 `is_final` 结束 `chunks`。
final class ElevenLabsDialogueStream: VoiceStream, @unchecked Sendable {
    static let keepAliveInterval: TimeInterval = 10

    let chunks: AsyncThrowingStream<AudioClip, Error>
    private let continuation: AsyncThrowingStream<AudioClip, Error>.Continuation
    private let url: URL
    private let voiceId: String
    private let keyProvider: () -> String?
    private let transportFactory: (URL) -> any VoiceWebSocketTransport
    private let keepAliveInterval: TimeInterval

    private let lock = NSLock()
    private var transport: (any VoiceWebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var lastSentAt = Date()
    private var ended = false
    /// 建连时用的 key：错误帧去敏用这一把（会话期间服务换了 key 也抹得掉）
    private var activeKey: String?

    init(url: URL, voiceId: String, keyProvider: @escaping () -> String?,
         transportFactory: @escaping (URL) -> any VoiceWebSocketTransport,
         keepAliveInterval: TimeInterval = ElevenLabsDialogueStream.keepAliveInterval) {
        self.url = url
        self.voiceId = voiceId
        self.keyProvider = keyProvider
        self.transportFactory = transportFactory
        self.keepAliveInterval = keepAliveInterval
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: AudioClip.self)
    }

    deinit { cancel() }

    func send(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await write(ElevenLabsDialogueFrames.textFrame(trimmed, voiceId: voiceId))
    }

    func flush() async throws {
        guard isConnected else { return }
        try await write(ElevenLabsDialogueFrames.flushFrame)
    }

    func finish() async throws {
        guard isConnected else {
            end(nil)
            return
        }
        try await write(ElevenLabsDialogueFrames.closeFrame)
    }

    func cancel() {
        end(nil)
    }

    // MARK: private

    fileprivate var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return transport != nil && !ended
    }

    fileprivate func write(_ frame: String) async throws {
        let t = try await connectIfNeeded()
        do {
            try await t.send(frame)
        } catch {
            end(VoiceSynthError.network)
            throw VoiceSynthError.network
        }
        lock.lock(); lastSentAt = Date(); lock.unlock()
    }

    fileprivate func connectIfNeeded() async throws -> any VoiceWebSocketTransport {
        lock.lock()
        if ended {
            lock.unlock()
            throw VoiceSynthError.network
        }
        if let t = transport {
            lock.unlock()
            return t
        }
        guard let apiKey = keyProvider() else {
            lock.unlock()
            throw VoiceSynthError.missingKey
        }
        let t = transportFactory(url)
        transport = t
        activeKey = apiKey
        lock.unlock()

        t.connect()
        do {
            try await t.send(ElevenLabsDialogueFrames.initFrame(voiceId: voiceId, apiKey: apiKey))
        } catch {
            end(VoiceSynthError.network)
            throw VoiceSynthError.network
        }
        lock.lock()
        lastSentAt = Date()
        receiveTask = Task { [weak self] in await self?.receiveLoop(t) }
        let step = max(0.05, keepAliveInterval / 4)
        // 每轮弱引用：调用方忘了 cancel 时会话能释放（释放即断开），别被保活循环吊住
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard let self, await self.keepAliveTick(t) else { return }
            }
        }
        lock.unlock()
        return t
    }

    private func receiveLoop(_ t: any VoiceWebSocketTransport) async {
        while !Task.isCancelled {
            let text: String?
            do {
                text = try await t.receive()
            } catch {
                end(isEnded ? nil : VoiceSynthError.network)
                return
            }
            guard let text else {
                end(nil)
                return
            }
            let msg = ElevenLabsDialogueFrames.decode(text)
            if let error = msg.error {
                lock.lock()
                let secrets = activeKey.map { [$0] } ?? []
                lock.unlock()
                end(ElevenLabsDialogueFrames.mapError(error, secrets: secrets))
                return
            }
            if let audio = msg.audio, !audio.isEmpty {
                continuation.yield(AudioClip(data: audio, format: .pcm16,
                                             sampleRate: ElevenLabsSynthesizer.streamSampleRate))
            }
            if msg.isFinal {
                end(nil)
                return
            }
        }
    }

    /// 闲够 `keepAliveInterval` 就发一帧保活；会话结束返回 false
    private func keepAliveTick(_ t: any VoiceWebSocketTransport) async -> Bool {
        lock.lock()
        let idle = Date().timeIntervalSince(lastSentAt)
        let done = ended
        lock.unlock()
        if done { return false }
        if idle >= keepAliveInterval {
            try? await t.send(ElevenLabsDialogueFrames.keepAliveFrame)
            lock.lock(); lastSentAt = Date(); lock.unlock()
        }
        return true
    }

    private var isEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    private func end(_ error: Error?) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        let t = transport
        let r = receiveTask
        let k = keepAliveTask
        lock.unlock()
        k?.cancel()
        r?.cancel()
        t?.close()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
