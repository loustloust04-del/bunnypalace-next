#if os(iOS)
import Foundation
import AVFoundation
import QuartzCore

/// 她发语音条的录音器（plan-voice-note M2）：AVAudioRecorder m4a / AAC 单声道 22.05k + metering。
/// 每帧（display link）读一次平均功率换成 0…1 电平（-50dB 记 0），同时喂声纹采样（`VoicePeakSampler`，≤200 峰值）。
/// 只管录和交文件；手势 / 动画 / 发送在 `VoiceRecordController`。
@MainActor
final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
    /// 最长 10 分钟（粟粟 10-04），到点由 controller 停进预览
    static let maxDuration: TimeInterval = 600
    enum StartResult { case started, failed }

    struct Recording {
        let url: URL
        let duration: Double
        let peaks: [Double]
        var analysisBucket: String? = nil
    }

    /// 最新电平 0…1（逐帧读，不被观察）
    private(set) var level: Double = 0
    private(set) var sampler = VoicePeakSampler()
    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }
    var isRecording: Bool { recorder != nil }

    /// 每帧回调（电平已更新）；到 10 分钟上限 / 被打断由 controller 接
    var onTick: (() -> Void)?
    var onLimitReached: (() -> Void)?
    /// 系统打断（来电 / Siri）开始
    var onInterrupted: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var link: CADisplayLink?
    private var interruptionObserver: NSObjectProtocol?
    private var analysisBucket: String?

    private func currentAnalysisBucket() -> String? {
        guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        return "v1.default.\(input.portType.rawValue).\(input.uid).\(input.selectedDataSource?.dataSourceID.stringValue ?? "default")"
    }

    /// 开录前让出（单向互斥，照 VoiceMessagePlayer.beforePlay / CallAudioSessionController.begin）
    private func yieldOtherAudio() {
        VoiceMessagePlayer.shared.stop()
        MusicCardPlayer.shared.stop()
        SpeechService.shared.stop()
    }

    func start() -> StartResult {
        stopLink()
        recorder?.stop()
        recorder = nil
        yieldOtherAudio()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            return .failed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
            deactivateSession()
            return .failed
        }
        r.delegate = self
        r.isMeteringEnabled = true
        guard r.prepareToRecord(), r.record() else {
            try? FileManager.default.removeItem(at: url)
            deactivateSession()
            return .failed
        }
        recorder = r
        analysisBucket = currentAnalysisBucket()
        level = 0
        sampler = VoicePeakSampler()
        observeInterruptions()
        startLink()
        return .started
    }

    /// 停录交文件（时长取停之前的 currentTime）。没在录 = nil
    func stop() -> Recording? {
        guard let r = recorder else { return nil }
        let duration = r.currentTime
        let bucket = analysisBucket == currentAnalysisBucket() ? analysisBucket : nil
        teardown()
        r.stop()
        deactivateSession()
        return Recording(url: r.url, duration: duration, peaks: sampler.peaks, analysisBucket: bucket)
    }

    /// 取消：停录并删掉临时文件
    func cancel() {
        guard let r = recorder else { return }
        teardown()
        r.stop()
        r.deleteRecording()
        deactivateSession()
    }

    private func teardown() {
        stopLink()
        recorder = nil
        if let o = interruptionObserver {
            NotificationCenter.default.removeObserver(o)
            interruptionObserver = nil
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startLink() {
        let l = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick() {
        guard let r = recorder else { return }
        r.updateMeters()
        level = VoiceWave.level(decibels: Double(r.averagePower(forChannel: 0)))
        sampler.push(level)
        onTick?()
        if r.currentTime >= Self.maxDuration { onLimitReached?() }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.onInterrupted?() }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.onInterrupted?() }
    }

    /// CADisplayLink 强持 target：用弱代理，录音器释放时 link 不拖住它
    private final class LinkProxy: NSObject {
        weak var owner: VoiceNoteRecorder?
        init(_ owner: VoiceNoteRecorder) { self.owner = owner }
        @objc func tick() {
            MainActor.assumeIsolated { owner?.tick() }
        }
    }
}
#endif
