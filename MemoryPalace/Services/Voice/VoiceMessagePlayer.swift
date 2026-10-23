import Foundation
import AVFoundation
import Observation

/// 语音条播放器：一次只播一条（播 B 自动停 A），开播停音乐卡、暂停听书（语音条短，单向让出）。
/// id 用 audioRef 的 path（同一文件同一条）。
@MainActor
@Observable
final class VoiceMessagePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoiceMessagePlayer()

    enum State: Equatable { case idle, playing, paused }

    private(set) var playingId: String? = nil
    /// 暂停中（playingId 仍是这条，位置保留；research-chat-cards §11）
    private(set) var isPaused = false
    private var player: AVAudioPlayer? = nil
    /// 只在播放时跑：发现系统打断（来电 / Siri）让播放器自己停了，就改成「已暂停」（终审 I-3）
    private var timer: Timer? = nil
    /// 开播前让出：停音乐卡、暂停听书（research-chat-cards §10.2 互斥；测试可换 spy）
    @ObservationIgnored var beforePlay: @MainActor () -> Void = {
        MusicCardPlayer.shared.stop()
    }

    var isTicking: Bool { timer != nil }

    func state(for id: String) -> State {
        guard playingId == id else { return .idle }
        return isPaused ? .paused : .playing
    }

    /// 这条的播放进度（逐帧读）；不是这条 = nil
    func fraction(for id: String) -> Double? {
        guard playingId == id, let p = player, p.duration > 0 else { return nil }
        return min(1, p.currentTime / p.duration)
    }

    func toggle(url: URL, id: String) {
        if playingId == id, let p = player {                    // 同一条：暂停 / 继续（不再从头播）
            if isPaused {
                beforePlay()
                configureSession()
                p.play()
                isPaused = false
                startTicking()
            } else {
                p.pause()
                isPaused = true
                stopTicking()
            }
            return
        }
        stop()
        beforePlay()
        configureSession()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.delegate = self
        p.play()
        playingId = id
        startTicking()
    }

    func stop() {
        stopTicking()
        player?.stop()
        player = nil
        playingId = nil
        isPaused = false
    }

    /// 只停这一条（「换一版」替换了文件、消息被删时，终审 I-3）
    func stop(id: String) {
        if playingId == id { stop() }
    }

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let p = player, !isPaused, !p.isPlaying else { return }
        isPaused = true                                          // 被系统打断：显示为暂停，点一下就继续
        stopTicking()
    }

    private func configureSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            // 迟到的回调不误停刚点开的下一条（终审 M-6）
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }
}
