import Foundation
import AVFoundation
import MediaToolbox
import Observation

/// 播放器自己的真实状态（TASK page1-卡片-03）：来电被系统停了、断网在等数据，都要让按钮跟着变
enum MusicEngineState: Equatable { case playing, waiting, paused }

/// 音乐卡播放器（research-chat-cards §10.2）：一次只放一首；开播停语音条、暂停听书（互斥）；本地模式立即停。
/// 引擎回调带代号：旧音轨迟到的失败 / 结束不影响新音轨（R5 U3）。
@MainActor
protocol MusicEngine: AnyObject {
    var onTime: ((Int, Double, Double) -> Void)? { get set }   // (代号, 当前秒, 总秒)
    var onEnd: ((Int) -> Void)? { get set }
    var onFail: ((Int) -> Void)? { get set }
    var onState: ((Int, MusicEngineState) -> Void)? { get set }
    /// 返回本次加载的代号
    func load(_ url: URL) -> Int
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
    func setVolume(_ volume: Float)
    /// 实时音量 0...1（外链歌曲从音频处理回调算；拿不到时 nil）
    func currentLevel() -> Float?
}

/// 正在放的歌从哪来（切到别的对话时顶部玻璃胶囊用它回去，粟粟 09-27）
struct MusicOrigin: Equatable {
    let conversationId: String
    let nodeId: String
    let title: String
    /// 那张音乐卡本身（长按顶栏岛弹出预览时复用 MusicCardView）
    var card: MusicCard? = nil
}

/// 顶部「正在播放」胶囊：在放（含暂停）且当前看的不是那首歌所在的对话时出现
enum MusicNowPlaying {
    static func shouldShow(origin: MusicOrigin?, isActive: Bool, currentConversationId: String?) -> Bool {
        guard isActive, let origin else { return false }
        return origin.conversationId != currentConversationId
    }
}

@MainActor
@Observable
final class MusicCardPlayer {
    /// `.playing` 表示播放意图（缓冲中也算）
    enum Phase: Equatable { case idle, loading, playing, paused, failed }

    static let shared: MusicCardPlayer = {
        let player = MusicCardPlayer(engine: AVMusicEngine(), isOffline: { LocalMode.isOn }, willPlay: {
            VoiceMessagePlayer.shared.stop()
        }, builtinFile: { await BuiltinMusic.fileURL(for: $0) }, levels: { await BuiltinMusic.levels(forFile: $0) })
        player.observeLocalMode()
        return player
    }()

    private(set) var currentKey: String?
    private(set) var origin: MusicOrigin?
    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    /// 0...1，本次运行有效（§10.6）
    private(set) var volume: Double = 1
    private var phase: Phase = .idle
    private var generation = 0
    /// 当前这首是本地文件（内置曲）：不受本地模式限制
    private var currentIsLocal = false
    @ObservationIgnored private var currentURL: URL?
    /// 内置曲首次播放要先合成：合成中的那张卡（算「加载中」）
    private(set) var preparingKey: String?
    @ObservationIgnored private(set) var builtinTask: Task<Void, Never>?
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private let builtinFile: (BuiltinTrack) async -> URL?
    @ObservationIgnored private let levelsProvider: (URL) async -> [Float]?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastTick = Date.distantPast
    /// 拖动后要去的位置：落地前播放器还会报几次旧位置，不跟着跳回去（TASK page1-卡片-03）
    @ObservationIgnored private var seekTarget: (time: Double, at: Date)?
    static let seekSettleWindow: TimeInterval = 3
    /// 当前这首的音量表（内置曲才有；每秒 BuiltinMusic.levelsPerSecond 格）
    private(set) var levels: [Float]?
    @ObservationIgnored private let engine: MusicEngine
    @ObservationIgnored private let isOffline: () -> Bool
    @ObservationIgnored private let willPlay: @MainActor () -> Void
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    init(engine: MusicEngine, isOffline: @escaping () -> Bool, willPlay: @escaping @MainActor () -> Void,
         builtinFile: @escaping (BuiltinTrack) async -> URL? = { _ in nil },
         levels: @escaping (URL) async -> [Float]? = { _ in nil },
         now: @escaping () -> Date = Date.init) {
        self.levelsProvider = levels
        self.now = now
        self.engine = engine
        self.isOffline = isOffline
        self.willPlay = willPlay
        self.builtinFile = builtinFile
        engine.onTime = { [weak self] gen, cur, dur in
            guard let self, gen == self.generation, self.currentKey != nil else { return }
            if let target = self.seekTarget {
                if abs(cur - target.time) > 1.5, self.now().timeIntervalSince(target.at) < Self.seekSettleWindow { return }
                self.seekTarget = nil
            }
            self.current = cur
            self.lastTick = self.now()
            if dur.isFinite, dur > 0 { self.duration = dur }
            // 直播流没有总时长：进度在走就算在放
            if self.phase == .loading, self.duration > 0 || cur > 0 { self.phase = .playing }
        }
        engine.onState = { [weak self] gen, state in
            guard let self, gen == self.generation, self.currentKey != nil else { return }
            switch (state, self.phase) {
            case (.playing, .loading): self.phase = .playing; self.lastTick = self.now()
            case (.waiting, .playing): self.phase = .loading                  // 断网 / 缓冲：显示加载中
            case (.paused, .playing), (.paused, .loading): self.phase = .paused // 来电等被系统停了
            default: break                                                      // 自己点的暂停不被翻回去
            }
        }
        engine.onEnd = { [weak self] gen in
            guard let self, gen == self.generation, self.currentKey != nil else { return }
            self.stop()                                         // 播完释放引擎（R5 U4）
        }
        engine.onFail = { [weak self] gen in
            guard let self, gen == self.generation, self.currentKey != nil else { return }
            self.engine.stop()
            self.generation = -1                                // 之后迟到的结束 / 进度都不认（保住「播放失败」）
            self.phase = .failed
        }
    }

    /// 有一首占着（加载中 / 在放 / 暂停）；听书收尾时据此决定要不要停用音频会话
    var isActive: Bool { currentKey != nil && phase != .failed }

    func phase(for key: String) -> Phase {
        if preparingKey == key { return .loading }
        return currentKey == key ? phase : .idle
    }

    func isPreparing(key: String) -> Bool { preparingKey == key }

    /// 波形跟着鼓点弹用的音量：内置曲查合成时算好的表，外链歌曲用引擎的实时音量；不在放 = 0
    func level(at date: Date) -> Double {
        guard currentKey != nil, phase == .playing else { return 0 }
        if let levels {
            return Double(MusicWave.level(levels, perSecond: BuiltinMusic.levelsPerSecond, at: estimatedTime(at: date)))
        }
        return Double(engine.currentLevel() ?? 0)
    }

    /// 两次时间回调（0.25 秒一次）之间按真实时间外推，波形每帧都跟得上鼓点
    func estimatedTime(at date: Date) -> Double {
        guard currentKey != nil, phase == .playing else { return current }
        let t = current + max(0, date.timeIntervalSince(lastTick))
        return duration > 0 ? min(t, duration) : t
    }

    /// 内置曲：已加载过就暂停 / 继续；否则先合成（同一首只合成一次），合成完时若期间被别的歌顶掉 / 被停掉就不播（终审 I2）
    func toggleBuiltin(key: String, track: BuiltinTrack, origin: MusicOrigin? = nil) {
        if currentKey == key, [.playing, .loading, .paused].contains(phase), let url = currentURL {
            toggle(key: key, url: url)
            return
        }
        guard preparingKey != key else { return }
        cancelPreparing()
        ticket += 1
        let mine = ticket
        preparingKey = key
        builtinTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let url = await self.builtinFile(track)
            guard self.ticket == mine, self.preparingKey == key else { return }
            self.preparingKey = nil
            guard let url else { self.markFailed(key: key); return }
            self.toggle(key: key, url: url, origin: origin)
        }
    }

    private func cancelPreparing() {
        preparingKey = nil
        ticket += 1
    }

    private func markFailed(key: String) {
        if currentKey != nil { engine.stop() }
        currentKey = key
        currentURL = nil
        generation = -1
        phase = .failed
    }

    /// 胶囊上的暂停 / 继续：只管当前这首
    func togglePauseCurrent() {
        guard let key = currentKey, let url = currentURL, phase != .failed else { return }
        toggle(key: key, url: url)
    }

    func toggle(key: String, url: URL, origin: MusicOrigin? = nil) {
        if preparingKey != nil { cancelPreparing() }
        guard url.isFileURL || !isOffline() else { stop(); return }
        if currentKey == key {
            switch phase {
            case .playing, .loading: engine.pause(); phase = .paused; return
            case .paused: willPlay(); engine.play(); phase = .playing; lastTick = now(); return
            case .failed, .idle: break
            }
        }
        if currentKey != nil { engine.stop() }
        willPlay()
        currentKey = key
        self.origin = origin
        currentURL = url
        levels = nil
        if url.isFileURL {
            Task { @MainActor [weak self] in
                guard let self, let table = await self.levelsProvider(url), self.currentURL == url else { return }
                self.levels = table
            }
        }
        currentIsLocal = url.isFileURL
        seekTarget = nil
        current = 0
        duration = 0
        phase = .loading
        generation = engine.load(url)
        engine.play()
    }

    func seek(fraction: Double) {
        guard currentKey != nil, duration > 0 else { return }
        current = min(max(fraction, 0), 1) * duration
        lastTick = now()
        seekTarget = (current, lastTick)
        engine.seek(to: current)
    }

    func stop() {
        if preparingKey != nil { cancelPreparing() }
        guard currentKey != nil else { return }
        engine.stop()
        currentKey = nil
        origin = nil
        levels = nil
        current = 0
        duration = 0
        phase = .idle
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        engine.setVolume(Float(volume))
    }

    /// 只停这一首（卡片变旧版本时，R5 U2）
    func stop(key: String) {
        if preparingKey == key { cancelPreparing() }
        if currentKey == key { stop() }
    }

    /// 本地模式打开 → 立即停止并释放（R5 U1）
    func recheckOffline() {
        if isOffline(), !currentIsLocal { stop() }
    }

    private func observeLocalMode() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckOffline() }
        }
    }
}

/// 生产引擎：AVPlayer（远程 https 直链）
@MainActor
final class AVMusicEngine: MusicEngine {
    var onTime: ((Int, Double, Double) -> Void)?
    var onEnd: ((Int) -> Void)?
    var onFail: ((Int) -> Void)?
    var onState: ((Int, MusicEngineState) -> Void)?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var generation = 0
    private var volume: Float = 1
    private var meter: MusicMeter?

    func currentLevel() -> Float? { meter?.level }

    func setVolume(_ volume: Float) {
        self.volume = volume
        player?.volume = volume
    }

    func load(_ url: URL) -> Int {
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let gen = generation
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = volume
        player = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.onTime?(gen, t.seconds, p.currentItem?.duration.seconds ?? 0)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd?(gen) }
        }
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.onFail?(gen) }
        }
        // 真实播放状态（来电 / 断网）：回到主线程时现读，不用 KVO 那一刻的值（自己刚点的播放 / 暂停以现在为准）
        controlObservation = p.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.player === p else { return }
                let state: MusicEngineState
                switch p.timeControlStatus {
                case .playing: state = .playing
                case .waitingToPlayAtSpecifiedRate: state = .waiting
                case .paused: state = .paused
                @unknown default: return
                }
                self.onState?(gen, state)
            }
        }
        if !url.isFileURL {                                   // 内置曲有现成的音量表，不必再接
            let meter = MusicMeter()
            self.meter = meter
            Task { await MusicMeter.attach(meter, to: item) }
        }
        return gen
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }

    func stop() {
        generation += 1                                     // 之前排队的回调全部作废
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation = nil
        controlObservation = nil
        meter = nil
        timeObserver = nil
        endObserver = nil
        player = nil
    }
}

/// 进度条拖动：只在水平位移 / 速度占优时接管，纵向交给聊天列表滚动（终审 C1）
enum MusicScrub {
    static func accepts(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    /// 时间浮标中心：跟着播放头，但整个浮标不出波形两端
    static func tipCenter(progress: Double, width: CGFloat, tipWidth: CGFloat) -> CGFloat {
        let x = width * CGFloat(min(max(progress, 0), 1))
        guard width > tipWidth else { return width / 2 }
        return min(max(x, tipWidth / 2), width - tipWidth / 2)
    }
}

/// 音量归一：用一个慢慢回落的峰值做分母——安静的歌也能弹起来，响的歌不会一直顶满
struct LevelNormalizer {
    private var peak: Float = 0
    /// 每次推入的回落系数（音频回调约 40 次 / 秒 → 峰值半衰期约 3 秒）
    var decay: Float = 0.995

    mutating func push(_ rms: Float) -> Float {
        peak = max(rms, peak * decay)
        guard peak > 1e-4 else { return 0 }
        return min(1, rms / peak)
    }
}

/// 外链歌曲的实时音量：接在 AVPlayerItem 的音频处理回调上（音频线程写、主线程读，加锁）
final class MusicMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var normalizer = LevelNormalizer()
    private var value: Float = 0
    private var isFloat = true

    var level: Float { lock.lock(); defer { lock.unlock() }; return value }

    func push(rms: Float) {
        lock.lock(); value = normalizer.push(rms); lock.unlock()
    }

    fileprivate func setFormat(isFloat: Bool) { lock.lock(); self.isFloat = isFloat; lock.unlock() }
    fileprivate var acceptsFloat: Bool { lock.lock(); defer { lock.unlock() }; return isFloat }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// 给 item 挂 MTAudioProcessingTap：只读不改声音，按每个缓冲算一次 RMS
    @MainActor
    static func attach(_ meter: MusicMeter, to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        let info = Unmanaged.passRetained(meter).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: info,
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<MusicMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let meter = Unmanaged<MusicMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.setFormat(isFloat: format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let meter = Unmanaged<MusicMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard meter.acceptsFloat else { return }
                var sum: Float = 0
                var count = 0
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buffer.mData else { continue }
                    let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let p = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<n { sum += p[i] * p[i] }
                    count += n
                }
                if count > 0 { meter.push(rms: (sum / Float(count)).squareRoot()) }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged<MusicMeter>.fromOpaque(info).release()
            return
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }
}

/// 播放时间文字（m:ss）
enum MusicTime {
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 音乐卡封面（R5 U8）：本地模式 / 非公网不拉；≤3MB；重定向到非公网拒绝；内存缓存；拉回来时已离线则丢弃
@MainActor
final class MusicCoverLoader {
    static let shared = MusicCoverLoader(isOffline: { LocalMode.isOn }, fetch: MusicCoverLoader.fetchCapped)
    nonisolated static let maxBytes = 3 * 1024 * 1024        // 同外链卡 LinkPreviewStore.maxImageBytes

    private let isOffline: () -> Bool
    private let fetch: (URL) async -> Data?
    private var cache: [URL: Data] = [:]
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    init(isOffline: @escaping () -> Bool, fetch: @escaping (URL) async -> Data?) {
        self.isOffline = isOffline
        self.fetch = fetch
    }

    func cached(_ url: URL) -> Data? { isOffline() ? nil : cache[url] }

    func load(_ url: URL) async -> Data? {
        guard !isOffline(), LinkPreviewStore.isPublicTarget(url) else { return nil }
        if let hit = cache[url] { return hit }
        let task = inFlight[url] ?? Task { await fetch(url) }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        guard !isOffline(), let data else { return nil }
        cache[url] = data
        return data
    }

    nonisolated private static let session = URLSession(configuration: .ephemeral, delegate: PublicRedirectGuard(), delegateQueue: nil)

    nonisolated static func fetchCapped(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType?.hasPrefix("image/") == true,
              http.expectedContentLength <= Int64(maxBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch { return nil }
        return data
    }
}

/// 重定向只跟到公网目标
private final class PublicRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https", LinkPreviewStore.isPublicTarget(url) else { return nil }
        return request
    }
}
