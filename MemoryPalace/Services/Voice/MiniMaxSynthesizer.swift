import Foundation

/// MiniMax（plan-voice-providers V2c）：`POST {baseURL}/t2a_v2`，Bearer，`stream: true` 走 SSE，
/// 每个事件 `data.audio` 是 hex 编码的音频片段，拼起来就是整段 mp3。
/// 坑（官方文档 + Kelivo）：HTTP 200 也可能是业务错误，每个事件都要查 `base_resp.status_code`（0 = 成功）。
/// 声音列表：`POST {baseURL}/get_voice`（`voice_type: all`，系统声音 + 自己克隆 / 生成的）。
/// 官方现在不要 GroupId；老账号填了就照旧带在 query 上。
struct MiniMaxSynthesizer: VoiceSynthesizer {
    static let models = ["speech-2.8-hd", "speech-2.8-turbo", "speech-2.6-hd", "speech-2.6-turbo", "speech-02-hd", "speech-02-turbo"]
    static let sampleRate = 32_000
    /// 官方：text 长度小于 10000 字
    static let textLimit = 9_999

    let service: VoiceService
    let keyProvider: () -> String?
    var session: URLSession = .shared

    var capabilities: VoiceCapabilities {
        VoiceCapabilities(canFetchVoices: true, tunables: [.speed],
                          models: Self.models.map { VoiceModelOption(id: $0, name: $0) })
    }

    var baseURL: String { service.trimmedBaseURL ?? MiniMaxOptions.defaultBaseURL }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
        guard let apiKey = keyProvider() else { throw VoiceSynthError.missingKey }
        guard let voice, !voice.isEmpty else { throw VoiceSynthError.missingVoice }
        try VoiceHTTP.ensureLength(text, limit: Self.textLimit)
        guard let url = endpoint("t2a_v2") else { throw VoiceSynthError.notSupported }
        var req = try VoiceHTTP.jsonRequest(url, body: [
            "model": capabilities.resolvedModel(model) ?? Self.models[0],
            "text": text,
            "stream": true,
            "output_format": "hex",
            "stream_options": ["exclude_aggregated_audio": true],
            "voice_setting": [
                "voice_id": voice,
                "speed": min(2, max(0.5, tuning.speed)),
                "vol": 1,
                "pitch": 0,
            ],
            "audio_setting": [
                "sample_rate": Self.sampleRate,
                "bitrate": 128_000,
                "format": "mp3",
                "channel": 1,
            ],
        ])
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (data, resp) = try await VoiceHTTP.send(req, session: session)
        try VoiceHTTP.check(resp, body: data, secrets: [apiKey])
        let audio = try Self.decodeAudio(data, secrets: [apiKey])
        guard !audio.isEmpty else { throw VoiceSynthError.badAudio }
        return AudioClip(data: audio, format: .mp3, sampleRate: Self.sampleRate)
    }

    func fetchVoices() async throws -> [VoiceOption] {
        guard let apiKey = keyProvider() else { throw VoiceSynthError.missingKey }
        guard let url = endpoint("get_voice") else { throw VoiceSynthError.notSupported }
        var req = try VoiceHTTP.jsonRequest(url, body: ["voice_type": "all"], timeout: 30)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await VoiceHTTP.send(req, session: session)
        try VoiceHTTP.check(resp, body: data, secrets: [apiKey])
        return try Self.decodeVoices(data, secrets: [apiKey])
    }

    private func endpoint(_ path: String) -> URL? {
        guard let url = VoiceHTTP.url(base: baseURL, path: path) else { return nil }
        let groupId = service.miniMaxOptions.groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupId.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = [URLQueryItem(name: "GroupId", value: groupId)]
        return comps.url
    }

    // MARK: - 解码（纯函数，可测）

    /// SSE（`data: {...}` 事件，空行分隔）或单个 JSON（非流式 / 出错时）→ 拼好的音频字节
    static func decodeAudio(_ body: Data, secrets: [String]) throws -> Data {
        var audio = Data()
        for payload in events(in: body) where payload != "[DONE]" {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
                throw VoiceSynthError.server(200, "回包格式不对")
            }
            try checkBusiness(obj, secrets: secrets)
            guard let hex = (obj["data"] as? [String: Any])?["audio"] as? String, !hex.isEmpty else { continue }
            guard let chunk = hexDecode(hex) else { throw VoiceSynthError.badAudio }
            audio.append(chunk)
        }
        return audio
    }

    static func decodeVoices(_ body: Data, secrets: [String]) throws -> [VoiceOption] {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw VoiceSynthError.server(200, "声音列表格式不对")
        }
        try checkBusiness(obj, secrets: secrets)
        func list(_ key: String) -> [[String: Any]] { obj[key] as? [[String: Any]] ?? [] }
        func describe(_ v: [String: Any]) -> String? {
            (v["description"] as? [String])?.filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty
        }
        var out: [VoiceOption] = []
        for v in list("voice_cloning") {
            guard let id = v["voice_id"] as? String else { continue }
            out.append(VoiceOption(id: id, name: id, detail: describe(v) ?? "克隆"))
        }
        for v in list("voice_generation") {
            guard let id = v["voice_id"] as? String else { continue }
            out.append(VoiceOption(id: id, name: id, detail: describe(v) ?? "生成"))
        }
        for v in list("system_voice") {
            guard let id = v["voice_id"] as? String else { continue }
            out.append(VoiceOption(id: id, name: (v["voice_name"] as? String)?.nilIfEmpty ?? id, detail: describe(v)))
        }
        return out
    }

    /// `base_resp.status_code` 非 0 = 业务错误（1004 鉴权失败；1002/1039 限流；1008 余额不足）
    static func checkBusiness(_ obj: [String: Any], secrets: [String]) throws {
        guard let base = obj["base_resp"] as? [String: Any] else { return }
        let code = (base["status_code"] as? Int) ?? (base["status_code"] as? NSNumber)?.intValue ?? 0
        guard code != 0 else { return }
        switch code {
        case 1004: throw VoiceSynthError.invalidKey
        case 1002, 1008, 1039: throw VoiceSynthError.quotaOrRateLimited
        default: throw VoiceSynthError.server(code, (base["status_msg"] as? String).map { VoiceHTTP.clip($0, secrets: secrets) })
        }
    }

    /// 事件负载：整段是 JSON 就当一个事件；否则按 SSE 取 `data:` 行（同一事件多行用换行拼）
    static func events(in body: Data) -> [String] {
        let text = String(decoding: body, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return [trimmed] }
        var out: [String] = []
        var buffer: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if !buffer.isEmpty { out.append(buffer.joined(separator: "\n")); buffer = [] }
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            buffer.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
        }
        if !buffer.isEmpty { out.append(buffer.joined(separator: "\n")) }
        return out
    }

    static func hexDecode(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var out = Data(capacity: bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
