import Foundation

/// OpenAI 兼容（plan-voice-providers V2b）：`POST {baseURL}/audio/speech`，Bearer，
/// `{model, input, voice, response_format}`（mp3 / wav，服务里可选；Groq 地址默认 wav）。一家覆盖 OpenAI、Groq、硅基流动等兼容接口。
/// 回来的字节按文件头认格式（RIFF = wav），认不出按请求的格式。
/// 声音列表 = OpenAI 内置声音常量（其他家的声音名在选择器里手填）。
struct OpenAICompatibleSynthesizer: VoiceSynthesizer {
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let builtinVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
    /// 单次上限：OpenAI 官方 4096 字；Groq Orpheus 模型 200 字
    static let textLimit = 4_096
    static let orpheusTextLimit = 200

    static func textLimit(model: String) -> Int {
        model.lowercased().contains("orpheus") ? orpheusTextLimit : textLimit
    }

    let service: VoiceService
    let keyProvider: () -> String?
    var session: URLSession = .shared

    var capabilities: VoiceCapabilities {
        VoiceCapabilities(canFetchVoices: true,
                          models: service.openAICompatibleOptions.models.map { VoiceModelOption(id: $0, name: $0) })
    }

    var baseURL: String { service.trimmedBaseURL ?? Self.defaultBaseURL }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
        guard let apiKey = keyProvider() else { throw VoiceSynthError.missingKey }
        guard let voice, !voice.isEmpty else { throw VoiceSynthError.missingVoice }
        guard let modelId = capabilities.resolvedModel(model),
              let url = VoiceHTTP.url(base: baseURL, path: "audio/speech") else { throw VoiceSynthError.notSupported }
        try VoiceHTTP.ensureLength(text, limit: Self.textLimit(model: modelId))
        let format = service.openAICompatibleOptions.effectiveFormat(baseURL: service.trimmedBaseURL)
        var req = try VoiceHTTP.jsonRequest(url, body: [
            "model": modelId,
            "input": text,
            "voice": voice,
            "response_format": format,
        ])
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await VoiceHTTP.send(req, session: session)
        try VoiceHTTP.check(resp, body: data, secrets: [apiKey])
        // 有的兼容服务 200 也回 JSON 错误
        if resp?.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true {
            throw VoiceSynthError.server(resp?.statusCode ?? 200, VoiceHTTP.detail(data, secrets: [apiKey]))
        }
        guard !data.isEmpty else { throw VoiceSynthError.badAudio }
        return AudioClip(data: data, format: Self.sniffFormat(data, requested: format))
    }

    /// 文件头认格式：`RIFF....WAVE` = wav；`ID3` / MPEG 帧同步 = mp3；都不像按请求的
    static func sniffFormat(_ data: Data, requested: String) -> AudioFormat {
        let head = [UInt8](data.prefix(12))
        if head.count >= 12, head[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]), head[8...11].elementsEqual([0x57, 0x41, 0x56, 0x45]) { return .wav }
        if head.count >= 3, head[0...2].elementsEqual([0x49, 0x44, 0x33]) { return .mp3 }
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return .mp3 }
        return requested == "wav" ? .wav : .mp3
    }

    func fetchVoices() async throws -> [VoiceOption] {
        Self.builtinVoices.map { VoiceOption(id: $0, name: $0) }
    }
}
