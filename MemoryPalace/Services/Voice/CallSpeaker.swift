#if os(iOS)
import AVFoundation

/// 通话播放端（plan-voice-providers V4b，`CallSpeechPipeline` 的 `CallAudioOutput`）：
/// - 流式 PCM → AVAudioEngine + AVAudioPlayerNode.scheduleBuffer 边收边播
/// - 整段 mp3 / wav → AVAudioPlayer，await 到播完
/// - 系统音 → AVSpeechSynthesizer，await 到念完
/// 挂断：`stop()` 清掉排着的；`shutdown()` 再停引擎。
@MainActor
final class CallSpeaker: NSObject, CallAudioOutput {

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var nodeFormat: AVAudioFormat?
    /// 跨块落单的半个采样
    private var pcmRemainder = Data()
    private var pendingBuffers = 0
    /// stop 后 +1，旧 buffer 的完成回调对不上就丢
    private var epoch = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private let synthesizer = AVSpeechSynthesizer()
    private var synthDelegate: SynthDelegate?

    // MARK: - PCM（流式）

    func schedulePCM(_ clip: AudioClip) throws {
        let channels = max(1, clip.channels)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(clip.sampleRate ?? 24_000),
                                         channels: AVAudioChannelCount(channels)) else { throw VoiceSynthError.badAudio }
        var bytes = pcmRemainder + clip.data
        let frameBytes = 2 * channels
        let frames = bytes.count / frameBytes
        pcmRemainder = bytes.suffix(bytes.count - frames * frameBytes)
        bytes = bytes.prefix(frames * frameBytes)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            for f in 0..<frames {
                for c in 0..<channels {
                    let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (f * channels + c) * 2, as: Int16.self))
                    out[c][f] = Float(v) / 32_768
                }
            }
        }
        try prepareEngine(format)
        pendingBuffers += 1
        let epoch = self.epoch
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(epoch: epoch) }
        }
        if !node.isPlaying { node.play() }
    }

    func waitPCMDrained() async {
        guard pendingBuffers > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func prepareEngine(_ format: AVAudioFormat) throws {
        if nodeFormat != format {
            if nodeFormat != nil {
                node.stop()
                engine.disconnectNodeOutput(node)
            } else {
                engine.attach(node)
            }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodeFormat = format
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func bufferPlayed(epoch: Int) {
        guard epoch == self.epoch else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if pendingBuffers == 0 { resumeDrainWaiters() }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - 整段（await 到 didFinish；兜底超时 = 时长 + 3s）

    func play(_ clip: AudioClip) async throws {
        let player = try AVAudioPlayer(data: clip.playableData)
        let playbackEpoch = epoch
        self.player = player
        let duration = player.duration
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let delegate = PlayerDelegate { cont.resume() }
                delegate.armTimeout(seconds: duration + 3)
                playerDelegate = delegate
                player.delegate = delegate
                if !player.play() { delegate.fire() }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.stopClip()
            }
        }
        if epoch == playbackEpoch, self.player === player {
            self.player = nil
            playerDelegate = nil
        }
    }

    private func stopClip() {
        player?.stop()
        player = nil
        let delegate = playerDelegate
        playerDelegate = nil
        delegate?.fire()
    }

    // MARK: - 系统音

    func speakSystem(_ text: String, voice: String?) async {
        let playbackEpoch = epoch
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let utterance = AVSpeechUtterance(string: text)
                let delegate = SynthDelegate(utterance: utterance) { cont.resume() }
                synthDelegate = delegate
                synthesizer.delegate = delegate
                if let voice, let v = AVSpeechSynthesisVoice(identifier: voice) {
                    utterance.voice = v
                } else {
                    utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "zh-CN")
                }
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == playbackEpoch else { return }
                self.stopSystem()
            }
        }
        if epoch == playbackEpoch { synthDelegate = nil }
    }

    private func stopSystem() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let delegate = synthDelegate
        synthDelegate = nil
        delegate?.fire()
    }

    // MARK: - 急停

    func stop() {
        epoch += 1
        if nodeFormat != nil { node.stop() }
        pendingBuffers = 0
        pcmRemainder = Data()
        resumeDrainWaiters()
        stopClip()
        stopSystem()
    }

    /// 挂断：急停 + 关引擎
    func shutdown() {
        stop()
        if engine.isRunning { engine.stop() }
    }

    // MARK: - 一次性 delegate（fire 幂等，超时 / 取消 / 正常结束共用出口）

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        private var onDone: (() -> Void)?
        private var timeout: Task<Void, Never>?
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func armTimeout(seconds: TimeInterval) {
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.fire()
            }
        }
        func fire() {
            timeout?.cancel(); timeout = nil
            onDone?(); onDone = nil
        }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in self.fire() }
        }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Task { @MainActor in self.fire() }
        }
    }

    private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
        private var onDone: (() -> Void)?
        private let expectedUtterance: AVSpeechUtterance
        init(utterance: AVSpeechUtterance, onDone: @escaping () -> Void) {
            expectedUtterance = utterance
            self.onDone = onDone
        }
        func fire() { onDone?(); onDone = nil }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            guard utterance === expectedUtterance else { return }
            Task { @MainActor in self.fire() }
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            guard utterance === expectedUtterance else { return }
            Task { @MainActor in self.fire() }
        }
    }
}

// MARK: - 通话音频会话（call 级，不随半双工开合——deactivate 会掐断正在播的 TTS）

@MainActor
enum CallAudioSessionController {
    /// 进通话：playAndRecord + voiceChat（系统回声消除）+ 外放；先停听书（学 VoiceMessagePlayer 单向互斥）
    static func begin(systemManaged: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        if !systemManaged { try? session.setActive(true) }
    }

    static func end(systemManaged: Bool = false) {
        guard !systemManaged else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
#endif
