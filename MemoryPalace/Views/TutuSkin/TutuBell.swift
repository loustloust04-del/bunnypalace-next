#if PERSONAL_APPS
#if os(iOS)
import AVFoundation
import UIKit

/// Owns the unlock bell's engine, not a recording or an algorithmic reverb preset.
/// The caller supplies SkinState.sound through enabled and calls stop on teardown.
@MainActor
final class TutuBell {
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled {
                suspendEngine()
            } else if wantsEngine {
                resumeIfPossible()
            }
        }
    }
    private(set) var lastError: Error?
    private var engine: AVAudioEngine?
    private var synth: TutuBellSynth?
    private var observers: [NSObjectProtocol] = []
    private var wantsEngine = false
    private var foreground: Bool
    private var interrupted = false
    private var idleTask: Task<Void, Never>?
    private var idleDeadline: TimeInterval = 0
    private var hasPlayedEvent = false

    init(enabled: Bool = true) {
        self.enabled = enabled
        foreground = UIApplication.shared.applicationState != .background
        observe(.tutuSkinSoundChanged) { bell, _ in
            bell.enabled = SkinState.shared.sound
        }
        observe(.tutuSkinActivationChanged) { bell, _ in
            if !SkinState.shared.active { bell.stop() }
        }
        observe(UIApplication.didEnterBackgroundNotification) { bell, _ in
            bell.foreground = false
            bell.suspendEngine()
        }
        observe(UIApplication.willEnterForegroundNotification) { bell, _ in
            bell.foreground = true
            bell.resumeIfPossible()
        }
        observe(AVAudioSession.interruptionNotification) { bell, notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                bell.interrupted = true
                bell.suspendEngine()
            } else {
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                bell.interrupted = false
                if options.contains(.shouldResume) { bell.resumeIfPossible() }
            }
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { bell, _ in
            bell.suspendEngine()
            bell.interrupted = false
            bell.resumeIfPossible()
        }
        observe(.AVAudioEngineConfigurationChange) { bell, notification in
            guard let changed = notification.object as? AVAudioEngine, changed === bell.engine else { return }
            bell.suspendEngine()
            bell.resumeIfPossible()
        }
    }

    deinit {
        idleTask?.cancel()
        engine?.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Prewarms the FFT kernels and engine off the audio callback. Ambient respects
    /// the silent switch and mixes with other applications rather than ducking them.
    func prepare() throws {
        wantsEngine = true
        guard enabled, foreground, !interrupted, engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard sampleRate >= 24_000,
                  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                throw BellError.unsupportedOutputFormat
            }
            let synth = TutuBellSynth(sampleRate: sampleRate, seed: UInt32.random(in: 1...UInt32.max))
            let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count == 2,
                      let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                    for buffer in buffers {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    return noErr
                }
                synth.render(frameCount: Int(frameCount), left: left, right: right)
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            self.synth = synth
            self.engine = engine
            lastError = nil
            // Preparing or returning to the foreground must not leave a silent
            // engine spinning forever if the view never issues another event.
            extendIdleDeadline(seconds: TutuBellSynth.Event.dang.tailSeconds)
        } catch {
            lastError = error
            if session.category == .ambient {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            throw error
        }
    }

    @discardableResult
    func play(event: String) -> Bool {
        guard enabled, foreground, !interrupted,
              let event = TutuBellSynth.Event(name: event) else { return false }
        do { try prepare() } catch { return false }
        guard let synth, synth.enqueue(event: event) else { return false }
        if !hasPlayedEvent { idleDeadline = 0 }
        hasPlayedEvent = true
        extendIdleDeadline(seconds: event.tailSeconds)
        return true
    }

    /// Releases the graph, source-node closure, oscillator pool and convolution IR.
    /// A subsequent prepare/play creates a fresh engine with no stale event queue.
    func stop() {
        wantsEngine = false
        suspendEngine()
    }

    private func observe(_ name: Notification.Name, handler: @escaping @MainActor (TutuBell, Notification) -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                handler(self, notification)
            }
        }
        observers.append(token)
    }

    private func resumeIfPossible() {
        guard wantsEngine, enabled, foreground, !interrupted else { return }
        do { try prepare() } catch { lastError = error }
    }

    private func suspendEngine() {
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = 0
        hasPlayedEvent = false
        engine?.stop()
        engine = nil
        synth = nil
        let session = AVAudioSession.sharedInstance()
        if session.category == .ambient {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func extendIdleDeadline(seconds: Double) {
        idleDeadline = max(idleDeadline, ProcessInfo.processInfo.systemUptime + seconds)
        idleTask?.cancel()
        let nanoseconds = UInt64(max(0, idleDeadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000)
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            self?.suspendEngine()
        }
    }

    private enum BellError: Error {
        case unsupportedOutputFormat
    }
}
#endif
#endif
