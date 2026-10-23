#if PERSONAL_APPS
#if DEBUG
import Foundation
import SwiftData
import AVFoundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - PlaybackIdentity
// 不可变身份。AudiobookPlayer 不直接持有 @Model（避免切楼层时 invalid context）。
// save 时按 (profileId, bookId) 在主 ctx fetch 写。

struct PlaybackIdentity: Equatable, Hashable {
    let profileId: String
    let bookId: UUID
    let fileName: String
    let totalDuration: Double
}

// MARK: - AudiobookPlayer
//
// 双轨续播策略（plan 第 5 步）：
// - 1s fastCheckpointTimer → UserDefaults（survive SIGKILL/force quit）
// - 5s slowDbSaveTimer → SwiftData（持久化"真"值给列表展示）
// - pause / seek / teardown / 进后台 / willTerminate 立即 save
//
// profile race 防护：save 前 fetch book，对比 book.profileId == identity.profileId。

@MainActor
@Observable
final class AudiobookPlayer {

    static let shared = AudiobookPlayer()

    // MARK: Observable state

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var identity: PlaybackIdentity?

    // MARK: Internal

    private var player: AVAudioPlayer?
    private var fastCheckpointTimer: Timer?
    private var slowDbSaveTimer: Timer?
    private weak var modelContext: ModelContext?

    private init() {
        registerLifecycleObservers()
    }

    // MARK: - Load

    /// 切书：清前一本，装新一本，currentTime 取 max(db, checkpoint)。
    func load(identity: PlaybackIdentity, context: ModelContext) throws {
        teardown()

        self.modelContext = context
        self.identity = identity

        let url = AudiobookFileManager.audioURL(fileName: identity.fileName, profileId: identity.profileId)
        let p = try AVAudioPlayer(contentsOf: url)
        p.prepareToPlay()

        let dbT = currentTimeFromDB(profileId: identity.profileId, bookId: identity.bookId)
        let cpT = PlaybackCheckpointStore.read(profileId: identity.profileId, bookId: identity.bookId)?.timestamp ?? 0
        let resumeT = max(dbT, cpT)
        // 不要直接 resume 到结尾（否则 player 立刻 finish），保留 0.5s 安全 margin
        let safeMax = max(0, p.duration - 0.5)
        p.currentTime = min(resumeT, safeMax)

        self.player = p
        self.duration = p.duration
        self.currentTime = p.currentTime
        self.isPlaying = false

        configureAudioSession()
    }

    private func currentTimeFromDB(profileId: String, bookId: UUID) -> Double {
        guard let ctx = modelContext else { return 0 }
        var fd = FetchDescriptor<AudiobookItem>(predicate: #Predicate { $0.id == bookId })
        fd.fetchLimit = 1
        let result = try? ctx.fetch(fd)
        return result?.first?.currentTime ?? 0
    }

    // MARK: - Controls

    func play() {
        guard let p = player else { return }
        MusicCardPlayer.shared.stop()           // 与音乐卡互斥（research-chat-cards §10.2，R5 U9）
        p.play()
        isPlaying = p.isPlaying
        startTimers()
    }

    func pause() {
        guard let p = player else { return }
        p.pause()
        currentTime = p.currentTime
        isPlaying = false
        stopTimers()
        saveImmediately()
    }

    func seek(to seconds: Double) {
        guard let p = player else { return }
        let clamped = min(max(0, seconds), p.duration)
        p.currentTime = clamped
        currentTime = clamped
        saveImmediately()
    }

    func skip(by seconds: Double) {
        guard let p = player else { return }
        seek(to: p.currentTime + seconds)
    }

    // MARK: - Save

    private func saveImmediately() {
        guard identity != nil else { return }
        saveCheckpointOnly()
        saveToDb()
    }

    private func saveCheckpointOnly() {
        guard let id = identity else { return }
        PlaybackCheckpointStore.write(profileId: id.profileId, bookId: id.bookId, timestamp: currentTime)
    }

    private func saveToDb() {
        guard let id = identity, let ctx = modelContext else { return }
        let bookId = id.bookId
        var fd = FetchDescriptor<AudiobookItem>(predicate: #Predicate { $0.id == bookId })
        fd.fetchLimit = 1
        guard let book = (try? ctx.fetch(fd))?.first else { return }
        // race assert：identity 与 DB 里的 profileId 必须一致才写
        guard book.profileId == id.profileId else { return }
        book.currentTime = currentTime
        book.lastPlayedAt = Date()
        try? ctx.save()
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        fastCheckpointTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFast() }
        }
        slowDbSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSlow() }
        }
    }

    private func stopTimers() {
        fastCheckpointTimer?.invalidate(); fastCheckpointTimer = nil
        slowDbSaveTimer?.invalidate(); slowDbSaveTimer = nil
    }

    private func tickFast() {
        guard let p = player, p.isPlaying else { return }
        currentTime = p.currentTime
        saveCheckpointOnly()
    }

    private func tickSlow() {
        guard let p = player, p.isPlaying else { return }
        currentTime = p.currentTime
        saveToDb()
    }

    // MARK: - Teardown

    /// 同步！切楼层时 ProfileManager will-change 必须等这个完成再切。
    func teardown() {
        stopTimers()
        if player != nil {
            saveImmediately()
        }
        player?.stop()
        player = nil
        isPlaying = false
        duration = 0
        currentTime = 0
        identity = nil
        deactivateAudioSession()
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        #if os(iOS)
        let sess = AVAudioSession.sharedInstance()
        do {
            try sess.setCategory(.playback, mode: .spokenAudio)
            try sess.setActive(true)
        } catch {
        }
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        guard !MusicCardPlayer.shared.isActive else { return }   // 音乐卡还占着会话就别停（R5 U9）
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    // MARK: - Lifecycle observers

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default

        // 切楼层：ProfileManager 同步派发 .profileWillSwitch，必须同步 teardown
        // 否则 timer 可能再 fire 一次写到旧楼层 UserDefaults key（虽然 race 已被 identity guard 兜底，但同步更稳）
        nc.addObserver(self, selector: #selector(handleProfileWillSwitch),
                       name: .profileWillSwitch, object: nil)

        #if os(iOS)
        nc.addObserver(self, selector: #selector(handleEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWillTerminate),
                       name: UIApplication.willTerminateNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        #elseif os(macOS)
        nc.addObserver(self, selector: #selector(handleEnterBackground),
                       name: NSApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWillTerminate),
                       name: NSApplication.willTerminateNotification, object: nil)
        #endif
    }

    @objc nonisolated private func handleProfileWillSwitch() {
        // ProfileManager 用 queue:nil 同步派发，理应在 main thread。
        // assumeIsolated 同步执行 teardown（在 ProfileManager 切 currentProfile 之前完成）。
        MainActor.assumeIsolated {
            self.teardown()
        }
    }

    @objc nonisolated private func handleEnterBackground() {
        Task { @MainActor in
            let playing = self.player?.isPlaying ?? false
            self.saveImmediately()
        }
    }

    @objc nonisolated private func handleWillTerminate() {
        // 1s fastTimer 已兜底，这里再写一次尽量补最近 ~1s 的进度
        Task { @MainActor in self.saveCheckpointOnly() }
    }

    #if os(iOS)
    @objc nonisolated private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                self.pause()
            case .ended:
                break  // phase 1 不自动恢复
            @unknown default: break
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            Task { @MainActor in self.pause() }
        }
    }
    #endif
}
#endif
#endif
