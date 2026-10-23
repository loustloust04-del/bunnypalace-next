import Foundation

/// ElevenLabs 账户下的一个 voice（/v1/voices 列表项）
struct ElevenVoice: Identifiable, Equatable {
    let voiceId: String
    let name: String
    let previewURL: URL?
    var id: String { voiceId }
}

enum ElevenLabsError: Error {
    case invalidKey
    case quotaOrRateLimited
    case server(Int)
    case network

    /// 语音条失败行用的短语
    var shortPhrase: String {
        switch self {
        case .invalidKey: return "key 无效"
        case .quotaOrRateLimited: return "额度不够或请求太频繁"
        case .server(let code): return "服务端出错 \(code)"
        case .network: return "网络不行"
        }
    }
}

/// ElevenLabs REST 薄客户端（非流式）。语音条是短音频存文件，不碰 SSE。
struct ElevenLabsClient {
    static let apiBase = URL(string: "https://api.elevenlabs.io/v1")!
    /// 测试经 URLProtocol mock 注入
    var session: URLSession = .shared

    func fetchVoices(apiKey: String) async throws -> [ElevenVoice] {
        var req = URLRequest(url: Self.apiBase.appendingPathComponent("voices"))
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await run(req)
        try Self.check(resp)
        struct VoicesResponse: Decodable {
            struct V: Decodable {
                let voice_id: String
                let name: String
                let preview_url: String?
            }
            let voices: [V]
        }
        let decoded = try JSONDecoder().decode(VoicesResponse.self, from: data)
        return decoded.voices.map {
            ElevenVoice(voiceId: $0.voice_id, name: $0.name,
                        previewURL: $0.preview_url.flatMap(URL.init(string:)))
        }
    }

    /// 表演脚本 → mp3 字节（eleven_v3 + Audio Tags）
    func synthesize(
        script: String, voiceId: String, apiKey: String,
        settings: VoiceTuning.Settings = VoiceTuning.current()
    ) async throws -> Data {
        var comps = URLComponents(
            url: Self.apiBase.appendingPathComponent("text-to-speech/\(voiceId)"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": script,
            "model_id": "eleven_v3",
            "voice_settings": [
                "stability": settings.stability,
                "similarity_boost": settings.similarityBoost,
                "style": settings.style,
                "speed": settings.speed,
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await run(req)
        try Self.check(resp)
        return data
    }

    private func run(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch { throw ElevenLabsError.network }
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw ElevenLabsError.invalidKey
        case 402, 429: throw ElevenLabsError.quotaOrRateLimited
        default: throw ElevenLabsError.server(http.statusCode)
        }
    }
}
