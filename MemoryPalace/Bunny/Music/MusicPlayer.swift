#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import Foundation
import AVFoundation
import Observation
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// 音乐播放器：后台播放 + 锁屏控制 + 歌词同步。
/// 与语音条播放器分开：那个是"一次一条短音频"，这个要列表、后台、锁屏、进度拖动。
/// 用 AVPlayer 而非 AVAudioPlayer——远端直链（音源服务器）要流式播放。
@MainActor
@Observable
final class MusicPlayer: NSObject {
    static let shared = MusicPlayer()

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var lyrics: [LyricLine] = []
    private(set) var queue: [Song] = []
    private var queueIndex = 0

    /// 播放模式（播放器本体优化①）：顺序循环 / 单曲循环 / 随机。落 AppStorage 记住习惯。
    enum PlayMode: String { case sequence, repeatOne, shuffle }
    var playMode: PlayMode = PlayMode(rawValue: UserDefaults.standard.string(forKey: "musicPlayMode") ?? "") ?? .sequence {
        didSet { UserDefaults.standard.set(playMode.rawValue, forKey: "musicPlayMode") }
    }

    /// 单曲循环 = 心情信号：同一首连放 ≥3 遍推他一条（liveline kind=music_loop，
    /// 每首歌一场只报一次）。换歌会报、循环不报——而循环才是最重的那种信号。
    private var loopPlayCount = 0
    private var loopSignalSent = false

    private var player: AVPlayer?
    private var timeObserver: Any?

    /// 当前唱到第几句（歌词视图跟随用）
    var currentLyricIndex: Int? { LyricParser.currentIndex(lyrics, at: currentTime) }
    var currentLyricText: String? {
        currentLyricIndex.map { lyrics[$0].text }
    }

    /// 每首歌开播时回调（挂账在场记录用）
    var onSongStarted: ((Song) -> Void)?

    // MARK: - 睡眠定时器（播放器本体优化③——她是听着歌睡觉的人）
    private(set) var sleepTimerEndsAt: Date?
    private(set) var stopAfterCurrent = false
    private var sleepTask: Task<Void, Never>?

    /// minutes=nil 取消。到点：4 秒淡出→暂停→报 paused→liveline「她大概听着歌睡着了」
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel(); sleepTask = nil
        stopAfterCurrent = false
        guard let minutes else { sleepTimerEndsAt = nil; return }
        let ends = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEndsAt = ends
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            await self?.sleepTimerFired()
        }
    }

    /// 「听完这首停」：不设时钟，本首自然结束时停
    func toggleStopAfterCurrent() {
        stopAfterCurrent.toggle()
        if stopAfterCurrent { sleepTask?.cancel(); sleepTask = nil; sleepTimerEndsAt = nil }
    }

    private func sleepTimerFired() async {
        // 兔兔 09-02 拍板：到点不掐歌——一首歌被腰斩着停最难受。改成
        // 「到点后放完当前这首、自然收尾时停」（stopAfterCurrent 既有通路），
        // 最后 4 秒轻轻淡出收边。定时器到点时如果本来就暂停着，直接算停。
        sleepTimerEndsAt = nil
        guard let song = currentSong else { return }
        guard isPlaying else {
            lastBeatAt = Date()
            sendBeat(song: song, state: "paused")
            return
        }
        stopAfterCurrent = true
        // 歌尾淡出：等到 remaining ≤4s 再开始压音量，压到自然结束
        // （Task 在 @MainActor 方法里创建，继承主 actor，直读状态无竞态）
        let p = player
        Task { [weak self] in
            while let self, self.stopAfterCurrent, self.isPlaying, self.duration > 0,
                  (self.duration - self.currentTime) > 4 {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, self.stopAfterCurrent, let p else { return }
            for step in stride(from: 1.0, through: 0.2, by: -0.1) {
                p.volume = Float(step)
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    // MARK: - 预取（播放器本体优化②）
    // 切歌卡顿的根：下一首要现场换直链+起下载。放到 15s（或 30% 时长）就把
    // 「计划中的下一首」交给 prefetcher（面板侧负责换新直链→MusicCache 落盘），
    // 到点切歌直接命中本地文件。随机模式提前抽签并锁定，保证预取的就是要放的。
    var prefetcher: ((Song) -> Void)?
    private var prefetchedForSongId: String?
    private var plannedShuffleIndex: Int?

    private func prefetchTick() {
        guard let cur = currentSong, prefetchedForSongId != cur.id,
              duration > 0, currentTime > Swift.min(15, duration * 0.3) else { return }
        prefetchedForSongId = cur.id
        guard let nxt = plannedNextSong() else { return }
        prefetcher?(nxt)
    }

    private func plannedNextSong() -> Song? {
        guard !queue.isEmpty else { return nil }
        switch playMode {
        case .repeatOne:
            return nil   // 就是这首，已经在放
        case .sequence:
            let n = queue[(queueIndex + 1) % queue.count]
            return n.id == currentSong?.id ? nil : n
        case .shuffle:
            var i = Int.random(in: 0..<queue.count)
            if queue.count > 1 && i == queueIndex { i = (i + 1) % queue.count }
            plannedShuffleIndex = i
            return queue[i]
        }
    }

    // MARK: - T1 共听心跳（plan-listen-together-v2）
    // 「他说得出唱到哪句」：LRC 行变化才报（≥5s 节流，信息量最高最省电），
    // 无歌词/歌词间隙 30s 保底；暂停/停止各补一发 state。失败静默不打断播放。
    private var lastBeatAt: Date = .distantPast
    private var lastBeatLine: String?

    private func heartbeatTick() {
        guard let song = currentSong else { return }
        let line = currentLyricText
        let elapsed = Date().timeIntervalSince(lastBeatAt)
        let lineChanged = line != nil && line != lastBeatLine && elapsed >= 5
        guard lineChanged || elapsed >= 30 else { return }
        lastBeatAt = Date(); lastBeatLine = line
        sendBeat(song: song, state: isPlaying ? "playing" : "paused")
    }

    private func sendBeat(song: Song, state: String) {
        let pos = currentTime, dur = duration, line = currentLyricText
        Task.detached(priority: .utility) {
            await NowPlayingReporter.beat(
                title: song.title, artist: song.artist, album: song.album,
                position: pos, duration: dur,
                line: state == "stopped" ? nil : line, state: state)
        }
    }

    // MARK: - 播放

    /// 添加到下一首（兔兔 09-02 点名）：插到当前播放位之后。
    /// 已在队列里的挪位不复制；没在放歌时直接开播。连点多首按点选顺序排在后面。
    private var playNextInsertions = 0
    func playNext(_ song: Song) {
        guard currentSong != nil, !queue.isEmpty else {
            if let r = urlResolver { play(song: song, in: [song], resolveURL: r) }
            return
        }
        if song.id == currentSong?.id { return }
        if let existing = queue.firstIndex(where: { $0.id == song.id }) {
            let moved = queue.remove(at: existing)
            if existing < queueIndex { queueIndex -= 1 }
            if existing == queueIndex { queueIndex = max(0, queueIndex) }
            queue.insert(moved, at: min(queueIndex + 1, queue.count))
        } else {
            // 连点三首 A/B/C → 顺序 A、B、C（各自排在上一次插入之后）
            let at = min(queueIndex + 1 + playNextInsertions, queue.count)
            queue.insert(song, at: at)
            playNextInsertions += 1
        }
    }

    func play(song: Song, in list: [Song] = [], resolveURL: (Song) -> URL?) {
        queue = list.isEmpty ? [song] : list
        queueIndex = queue.firstIndex(where: { $0.id == song.id }) ?? 0
        start(song, resolveURL: resolveURL)
    }

    private func start(_ song: Song, resolveURL: (Song) -> URL?) {
        guard let url = resolveURL(song) else { return }
        trackLoop(song)
        configureSession()
        teardownObserver()

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        currentSong = song
        lyrics = LyricParser.parse(song.lyrics)
        currentTime = 0
        duration = song.durationSec

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = t.seconds
                if self.duration <= 0, let d = self.player?.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
                self.updateNowPlayingInfo()
                self.heartbeatTick()
                self.prefetchTick()
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidEnd),
            name: .AVPlayerItemDidPlayToEndTime, object: item)

        player?.play()
        isPlaying = true
        playNextInsertions = 0
        prefetchedForSongId = nil
        plannedShuffleIndex = nil
        setupRemoteCommands()
        updateNowPlayingInfo()
        onSongStarted?(song)
    }

    /// 连放计数：同一首再次开播 +1，换歌清零
    private var lastStartedSongId: String?
    private func trackLoop(_ song: Song) {
        if song.id == lastStartedSongId {
            loopPlayCount += 1
            if loopPlayCount >= 3 && !loopSignalSent {
                loopSignalSent = true
                let title = song.title, artist = song.artist
                Task.detached(priority: .utility) {
                    await NowPlayingReporter.livelineEvent(
                        kind: "music_loop",
                        text: "兔兔把《\(title)》\(artist.isEmpty ? "" : "（\(artist)）")单曲循环了 \(3) 遍还在继续——这种时候这首歌里有事。")
                }
            }
        } else {
            lastStartedSongId = song.id
            loopPlayCount = 1
            loopSignalSent = false
        }
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
        updateNowPlayingInfo()
        // 暂停/续播即时报一发（他那头「暂停着」与否是在场感的一部分）
        if let song = currentSong {
            lastBeatAt = Date()
            sendBeat(song: song, state: isPlaying ? "playing" : "paused")
        }
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlayingInfo()
    }

    func next(resolveURL: (Song) -> URL?) {
        guard !queue.isEmpty else { return }
        queueIndex = (queueIndex + 1) % queue.count
        start(queue[queueIndex], resolveURL: resolveURL)
    }

    func previous(resolveURL: (Song) -> URL?) {
        guard !queue.isEmpty else { return }
        // 播过 3 秒以上先回到开头（通用习惯）
        if currentTime > 3 { seek(to: 0); return }
        queueIndex = (queueIndex - 1 + queue.count) % queue.count
        start(queue[queueIndex], resolveURL: resolveURL)
    }

    func stop() {
        if let song = currentSong { sendBeat(song: song, state: "stopped") }
        teardownObserver()
        player?.pause()
        player = nil
        isPlaying = false
        currentSong = nil
        currentTime = 0
        lyrics = []
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    /// 下一首的回调需要外部提供 URL 解析，这里存一份给锁屏按钮用
    var urlResolver: ((Song) -> URL?)?

    @objc private func itemDidEnd() {
        Task { @MainActor in
            guard let r = urlResolver else { isPlaying = false; return }
            switch playMode {
            case .repeatOne:
                if stopAfterCurrent { stopAfterCurrent = false; await sleepStopAtSongEnd(); return }
                if let song = currentSong { start(song, resolveURL: r) }
            case .shuffle:
                if stopAfterCurrent { stopAfterCurrent = false; await sleepStopAtSongEnd(); return }
                guard !queue.isEmpty else { isPlaying = false; return }
                // 预取阶段抽过签就用那个（保证预取命中）；没抽过再抽，避开立刻重复
                if let planned = plannedShuffleIndex, queue.indices.contains(planned) {
                    queueIndex = planned
                } else {
                    var i = Int.random(in: 0..<queue.count)
                    if queue.count > 1 && i == queueIndex { i = (i + 1) % queue.count }
                    queueIndex = i
                }
                start(queue[queueIndex], resolveURL: r)
            case .sequence:
                if stopAfterCurrent { stopAfterCurrent = false; await sleepStopAtSongEnd(); return }
                next(resolveURL: r)
            }
        }
    }

    /// 「听完这首停」到站：歌自然收尾（尾段已淡出）即停 + 晚安信号
    private func sleepStopAtSongEnd() async {
        let title = currentSong?.title ?? ""
        isPlaying = false
        player?.volume = 1.0   // 归位，别让明早第一首静音
        updateNowPlayingInfo()
        if let song = currentSong { lastBeatAt = Date(); sendBeat(song: song, state: "paused") }
        Task.detached(priority: .utility) {
            await NowPlayingReporter.livelineEvent(
                kind: "music_sleep",
                text: "《\(title)》放完，按她定的「听完这首停」停下了——她大概听着歌睡着了。这会儿轻一点。")
        }
    }

    private func teardownObserver() {
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    private func configureSession() {
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        observeInterruptions()
        #endif
    }

    #if canImport(UIKit)
    /// 来电/闹钟打断（播放器本体优化②的暂停过滤，Duetto 同款教训）：
    /// 系统打断的暂停也要如实报 state=paused——否则他对着静音的耳机说「这句唱得真好」。
    /// 打断结束系统允许续播就续，并报回 playing。
    private var interruptionObserved = false
    private func observeInterruptions() {
        guard !interruptionObserved else { return }
        interruptionObserved = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let song = self.currentSong,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.isPlaying = false
                    self.lastBeatAt = Date()
                    self.sendBeat(song: song, state: "paused")
                case .ended:
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if opts.contains(.shouldResume) {
                        self.player?.play()
                        self.isPlaying = true
                        self.lastBeatAt = Date()
                        self.sendBeat(song: song, state: "playing")
                    }
                @unknown default: break
                }
            }
        }
    }
    #endif

    // MARK: - 锁屏

    private var remoteConfigured = false

    private func setupRemoteCommands() {
        #if canImport(MediaPlayer)
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.toggle() } }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in if let r = self?.urlResolver { self?.next(resolveURL: r) } }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in if let r = self?.urlResolver { self?.previous(resolveURL: r) } }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
        #endif
    }

    private func updateNowPlayingInfo() {
        #if canImport(MediaPlayer)
        guard let s = currentSong else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: s.displayArtist,
            MPMediaItemPropertyAlbumTitle: s.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        #endif
    }
}
#endif
