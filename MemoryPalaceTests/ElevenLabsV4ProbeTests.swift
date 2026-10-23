import XCTest
@testable import 记忆花园

/// 语音聊天 v2 · P2 的 V0 探针（docs/plan-voice-v4.md）：真打 ElevenLabs，验证 v4 对话接口 / Turbo WebSocket 的实际行为。
/// 只在 MP_ELEVEN_PROBE=1 时跑（`TEST_RUNNER_MP_ELEVEN_PROBE=1 xcodebuild test-without-building …`）；key 只从钥匙串读，任何输出都不含 key。
final class ElevenLabsV4ProbeTests: XCTestCase {

    private static let base = "https://api.elevenlabs.io"
    private static let reportPath = "/private/tmp/claude-501/-Users-susu-Desktop-susu-project------MemoryPalace/4e819c9b-295f-494c-9dde-12a8d18636d6/scratchpad/v4probe.txt"

    private var key = ""
    private var lines: [String] = []
    private let session = URLSession(configuration: .ephemeral)

    func testV0Probe() async throws {
        guard ProcessInfo.processInfo.environment["MP_ELEVEN_PROBE"] == "1" else {
            throw XCTSkip("未设 MP_ELEVEN_PROBE=1，不打网络")
        }
        guard let k = KeychainStore.get(account: VoiceTuning.keychainAccount), !k.isEmpty else {
            throw XCTSkip("Mac 钥匙串里没有 ElevenLabs key")
        }
        key = k
        try? FileManager.default.removeItem(atPath: Self.reportPath)

        guard let voice = await firstVoice() else {
            log("voices: 取不到声音，探针中止")
            return
        }
        let voiceId = voice.0
        log("voice: \(voice.1)")

        let line = "今天好累啊……不过见到你就好多了。"

        // 1. v4 对话接口 × stability
        for s in [0.0, 0.3, 0.5, 1.0] {
            await dialogue(tag: "P1 v4 stability=\(s)", model: "eleven_v4", voiceId: voiceId, text: line,
                           settings: ["stability": s, "similarity": 0.75])
        }
        // 2. 多塞 style / speed
        await dialogue(tag: "P2 v4 +style+speed", model: "eleven_v4", voiceId: voiceId, text: line,
                       settings: ["stability": 0.5, "similarity": 0.75, "style": 0.88, "speed": 1.1])
        // 3. 老 TTS 接口带 v4 model
        for m in ["eleven_v4", "eleven_v4_turbo"] {
            await legacyTTS(tag: "P3 TTS model=\(m)", model: m, voiceId: voiceId, text: line)
        }
        // 4. v3 走对话接口
        await dialogue(tag: "P4 v3 dialogue", model: "eleven_v3", voiceId: voiceId, text: line,
                       settings: ["stability": 0.5, "similarity": 0.75])
        // 7.（plan V0-3）标签 + 拟声词能否生成
        await dialogue(tag: "P7 v4 tags", model: "eleven_v4", voiceId: voiceId,
                       text: "[whispering] 嗯……你靠近一点嘛。[laughs softly] 哈啊……好啦好啦。",
                       settings: ["stability": 0.5, "similarity": 0.75])

        // 5. Turbo WSS，格式依次回退
        var okFormat: String?
        for fmt in ["pcm_24000", "pcm_22050", "mp3_44100_128"] {
            let ok = await streamProbe(tag: "P5 turbo \(fmt)", model: "eleven_v4_turbo", format: fmt, voiceId: voiceId)
            if ok { okFormat = fmt; break }
        }
        log("P5 可用格式: \(okFormat ?? "无")")
        // 6. 非 turbo 对比
        _ = await streamProbe(tag: "P6 v4 \(okFormat ?? "pcm_24000")", model: "eleven_v4",
                              format: okFormat ?? "pcm_24000", voiceId: voiceId)
    }

    // MARK: - HTTP

    private func firstVoice() async -> (String, String)? {
        var req = URLRequest(url: URL(string: "\(Self.base)/v1/voices")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voices = obj["voices"] as? [[String: Any]],
                  let first = voices.first,
                  let id = first["voice_id"] as? String else {
                log("voices: status=\(code) body=\(snippet(data))")
                return nil
            }
            return (id, first["name"] as? String ?? "?")
        } catch {
            log("voices: error=\(error.localizedDescription)")
            return nil
        }
    }

    private func dialogue(tag: String, model: String, voiceId: String, text: String, settings: [String: Double]) async {
        let body: [String: Any] = [
            "inputs": [["text": text, "voice_id": voiceId]],
            "model_id": model,
            "settings": settings,
        ]
        await post(tag: tag, path: "/v1/text-to-dialogue?output_format=mp3_44100_128", body: body)
    }

    private func legacyTTS(tag: String, model: String, voiceId: String, text: String) async {
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ]
        await post(tag: tag, path: "/v1/text-to-speech/\(voiceId)?output_format=mp3_44100_128", body: body)
    }

    private func post(tag: String, path: String, body: [String: Any]) async {
        var req = URLRequest(url: URL(string: Self.base + path)!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                log("\(tag): status=200 bytes=\(data.count) ms=\(ms)")
            } else {
                log("\(tag): status=\(code) ms=\(ms) body=\(snippet(data))")
            }
        } catch {
            log("\(tag): error=\(error.localizedDescription)")
        }
    }

    // MARK: - WebSocket

    /// 返回是否收到了音频。
    private func streamProbe(tag: String, model: String, format: String, voiceId: String) async -> Bool {
        let url = URL(string: "wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input?model_id=\(model)&output_format=\(format)")!
        let ws = session.webSocketTask(with: url)
        ws.resume()

        let frames: [[String: Any]] = [
            ["voices": [voiceId], "xi_api_key": key],
            ["inputs": [["text": "你回来啦，今天路上堵不堵呀？我一直在等你呢。", "voice_id": voiceId]]],
            ["inputs": [["text": "先去洗个热水澡吧，饭我已经帮你热好了哦。", "voice_id": voiceId]]],
            ["close_socket": true],
        ]

        let t0 = Date()
        var firstAudioMs: Int?
        var audioBytes = 0
        var msgCount = 0
        var gotFinal = false
        var notes: [String] = []

        let timeout = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }

        do {
            for f in frames {
                let data = try JSONSerialization.data(withJSONObject: f)
                try await ws.send(.string(String(decoding: data, as: UTF8.self)))
            }
        } catch {
            notes.append("send error=\(error.localizedDescription)")
        }

        while !gotFinal {
            let msg: URLSessionWebSocketTask.Message
            do {
                msg = try await ws.receive()
            } catch {
                notes.append("recv end: \(error.localizedDescription)")
                break
            }
            msgCount += 1
            let raw: Data
            switch msg {
            case .string(let s): raw = Data(s.utf8)
            case .data(let d): raw = d
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                notes.append("non-json msg \(raw.count)B")
                continue
            }
            if let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64), !pcm.isEmpty {
                if firstAudioMs == nil { firstAudioMs = Int(Date().timeIntervalSince(t0) * 1000) }
                audioBytes += pcm.count
            }
            if (obj["is_final"] as? Bool) == true || (obj["isFinal"] as? Bool) == true { gotFinal = true }
            if obj["error"] != nil || obj["message"] != nil || obj["audio"] == nil {
                var meta = obj
                meta.removeValue(forKey: "audio")
                meta.removeValue(forKey: "alignment")
                meta.removeValue(forKey: "normalizedAlignment")
                if let d = try? JSONSerialization.data(withJSONObject: meta) { notes.append("msg: \(snippet(d))") }
            }
            if msgCount == 1 { notes.append("keys[1]=\(obj.keys.sorted().joined(separator: ","))") }
        }
        let http = (ws.response as? HTTPURLResponse)?.statusCode
        let close = ws.closeCode.rawValue
        let reason = ws.closeReason.map { snippet($0) } ?? ""
        ws.cancel(with: .normalClosure, reason: nil)

        log("\(tag): firstAudioMs=\(firstAudioMs.map(String.init) ?? "-") audioBytes=\(audioBytes) msgs=\(msgCount) isFinal=\(gotFinal) totalMs=\(Int(Date().timeIntervalSince(t0) * 1000)) http=\(http.map(String.init) ?? "-") close=\(close) reason=\(reason) | \(notes.joined(separator: " ; "))")
        return audioBytes > 0
    }

    // MARK: - 输出（任何文本先抹 key）

    /// 先抹 key 再截：key 落在截断点上也不漏前半截
    private func snippet(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let clean = key.isEmpty ? text : text.replacingOccurrences(of: key, with: "<redacted>")
        return String(clean.prefix(600)).replacingOccurrences(of: "\n", with: " ")
    }

    private func log(_ s: String) {
        let clean = key.isEmpty ? s : s.replacingOccurrences(of: key, with: "<redacted>")
        let line = "[V4PROBE] \(clean)"
        print(line)
        lines.append(line)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: Self.reportPath, atomically: true, encoding: .utf8)
    }
}
