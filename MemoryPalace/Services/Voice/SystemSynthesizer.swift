import AVFoundation

/// 系统音（AVSpeechSynthesizer）：零配置兜底。`write` 渲染成 PCM buffer → 落成 WAV。
/// 不认标签、不流式、没有模型；语速跟「朗读」页的系统语速（`ttsRate`），不吃声音效果里的参数。
struct SystemSynthesizer: VoiceSynthesizer {
    var capabilities: VoiceCapabilities {
        VoiceCapabilities(canFetchVoices: true)
    }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VoiceSynthError.badAudio }
        let utterance = AVSpeechUtterance(string: cleaned)
        let rate = UserDefaults.standard.double(forKey: "ttsRate")
        utterance.rate = Float(rate == 0 ? 0.48 : rate)
        if let voice, let v = AVSpeechSynthesisVoice(identifier: voice) {
            utterance.voice = v
        } else if let language = Locale.preferredLanguages.first {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SystemSpeechRenderer().render(utterance, to: url)
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw VoiceSynthError.badAudio }
        return AudioClip(data: data, format: .wav)
    }

    /// 中文、英文声音排前面，其余按语言名
    func fetchVoices() async throws -> [VoiceOption] {
        let preferred = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "zh"
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            v.language.hasPrefix(preferred) ? 0 : (v.language.hasPrefix("zh") || v.language.hasPrefix("en") ? 1 : 2)
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { (rank($0), $0.language, $0.name) < (rank($1), $1.language, $1.name) }
            .map { VoiceOption(id: $0.identifier, name: $0.name, detail: $0.language) }
    }
}

/// 持有 synthesizer 直到渲染完；零长 buffer 或 didFinish 先到者收尾（只收一次）
private final class SystemSpeechRenderer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    func render(_ utterance: AVSpeechUtterance, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            synthesizer.delegate = self
            synthesizer.write(utterance) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { finish(); return }
                lock.lock(); defer { lock.unlock() }
                guard failure == nil else { return }
                do {
                    if file == nil {
                        // 文件固定 16-bit 交错 PCM（WAV 不收非交错）；buffer 的格式当处理格式，AVAudioFile 负责转换
                        let fileSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: pcm.format.sampleRate,
                            AVNumberOfChannelsKey: pcm.format.channelCount,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsNonInterleaved: false,
                        ]
                        file = try AVAudioFile(forWriting: url, settings: fileSettings,
                                               commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    }
                    try file?.write(from: pcm)
                } catch {
                    failure = error
                }
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }

    private func finish() {
        lock.lock()
        let c = continuation
        continuation = nil
        let err: Error? = failure ?? (file == nil ? VoiceSynthError.badAudio : nil)
        file = nil   // 释放即落盘
        lock.unlock()
        guard let c else { return }
        if let err { c.resume(throwing: err) } else { c.resume() }
    }
}
