#if os(iOS)
import AVKit
import SwiftUI
import WebKit

/// 影院放映页（plan-cinema-app §1）：B 站 / YouTube 用站方嵌入播放器，直链和本地文件用系统播放器（画中画、后台出声）。
/// 从上次的位置接着放；每 10 秒、暂停、退出时往片库写进度
struct CinemaPlayerView: View {
    let entry: WatchLogEntry
    /// 「一起看…」：带着现在的进度去选对话
    var onWatchTogether: (WatchLogEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress = CinemaProgress()

    private var isWeb: Bool { entry.source == .bilibili || entry.source == .youtube || entry.source == .web }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                Text(entry.title.isEmpty ? entry.url : entry.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.source != .file {
                    Button {
                        progress.flush()
                        let latest = WatchLog.shared.entry(entry.id) ?? entry
                        dismiss()
                        onWatchTogether(latest)
                    } label: {
                        Label("一起看…", systemImage: "bubble.left.and.text.bubble.right").font(.system(size: 14))
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .environment(\.colorScheme, .dark)

            Group {
                if isWeb {
                    CinemaWebPlayer(entry: entry, progress: progress)
                } else if let url = playURL {
                    CinemaNativePlayer(url: url, start: entry.position, progress: progress)
                } else {
                    Text("找不到这个文件了").foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { progress.item = item }
        .onDisappear { progress.flush() }
    }

    private var playURL: URL? {
        if entry.source == .file {
            let url = WatchLog.shared.filesDirectory.appendingPathComponent(entry.url)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return URL(string: entry.url)
    }

    private var item: WatchLog.Item {
        WatchLog.Item(key: entry.id, source: entry.source, url: entry.url, title: entry.title)
    }
}

/// 两种播放器共用的进度记账：最近一次读到的位置 / 时长，到点写片库
@MainActor
final class CinemaProgress {
    var item: WatchLog.Item?
    var position: Double?
    var duration: Double?
    var frame: Data?
    private var lastWrite = Date.distantPast
    private var lastPaused = true

    func update(position: Double, duration: Double?, paused: Bool) {
        self.position = position
        if let duration, duration > 0 { self.duration = duration }
        if (paused && !lastPaused) || (!paused && Date().timeIntervalSince(lastWrite) >= 10) { flush() }
        lastPaused = paused
    }

    func flush() {
        guard let item, let position, position > 0 else { return }
        lastWrite = Date()
        WatchLog.shared.record(item, position: position, duration: duration, frame: frame)
        frame = nil
    }
}

// MARK: - 站方嵌入播放器

private struct CinemaWebPlayer: UIViewRepresentable {
    let entry: WatchLogEntry
    let progress: CinemaProgress

    func makeCoordinator() -> Coordinator { Coordinator(progress: progress, resume: entry.position) }

    func makeUIView(context: Context) -> WKWebView {
        let target = URL(string: entry.url).flatMap { url in
            ChatWatchPerception.videoRef(url).map { $0.embedURL(start: entry.position) } ?? url
        } ?? URL(string: "about:blank")!
        let webView = BrowserWebView(initialURL: target, controller: context.coordinator.controller,
                                     identity: BrowserIdentityStore.current(), autoplay: true).makeWebView()
        webView.scrollView.refreshControl = nil
        webView.backgroundColor = .black
        webView.isOpaque = false
        context.coordinator.start(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator {
        let controller = MiniBrowserController()
        let progress: CinemaProgress
        private var resume: Double?
        private var ticker: Task<Void, Never>?
        private var tick = 0

        init(progress: CinemaProgress, resume: Double?) {
            self.progress = progress
            self.resume = resume.flatMap { $0 > 5 ? $0 : nil }
        }

        func start(_ webView: WKWebView) {
            ticker = Task { @MainActor [weak self, weak webView] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, let webView else { return }
                    await self.sample(webView)
                }
            }
        }

        func stop() {
            ticker?.cancel()
            progress.flush()
        }

        private func sample(_ webView: WKWebView) async {
            tick += 1
            guard let json = try? await webView.evaluateJavaScript(ChatWatchPerception.probeJS) as? String,
                  let now = ChatWatchPerception.parseProbe(json), now.hasVideo else { return }
            if !now.filled { _ = try? await webView.evaluateJavaScript(ChatWatchPerception.fillJS(true)) }
            // B 站嵌入页不认起点参数：视频出来后跳一次
            if let resume, now.duration > 0 {
                if abs(now.time - resume) > 5, let args = ChatWatchPerception.controlArgs(action: "seek", seconds: resume, rate: nil) {
                    _ = try? await webView.callAsyncJavaScript(ChatWatchPerception.controlJS, arguments: args, contentWorld: .page)
                }
                self.resume = nil
                return
            }
            guard now.time > 0 else { return }
            // 没封面时截一张当封面（每分钟最多一次）
            if progress.frame == nil, tick % 60 == 5, now.rect.width > 40 {
                let config = WKSnapshotConfiguration()
                config.rect = now.rect
                config.snapshotWidth = 512
                if let image = try? await webView.takeSnapshot(configuration: config) { progress.frame = image.jpegData(compressionQuality: 0.7) }
            }
            progress.update(position: now.time, duration: now.duration, paused: now.paused)
        }
    }
}

// MARK: - 系统播放器（直链 / 本地文件）

private struct CinemaNativePlayer: UIViewControllerRepresentable {
    let url: URL
    let start: Double?
    let progress: CinemaProgress

    func makeCoordinator() -> Coordinator { Coordinator(progress: progress) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.player = context.coordinator.start(url: url, from: start)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        let progress: CinemaProgress
        private var player: AVPlayer?
        private var timeObserver: Any?
        private var statusObserver: NSKeyValueObservation?
        private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

        init(progress: CinemaProgress) { self.progress = progress }

        func start(url: URL, from start: Double?) -> AVPlayer {
            // 后台继续出声 / 画中画要 playback 类别；退出时还原
            let session = AVAudioSession.sharedInstance()
            previousAudio = (session.category, session.mode, session.categoryOptions)
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)

            let player = AVPlayer(url: url)
            self.player = player
            if let start, start > 5 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            statusObserver = player.observe(\.timeControlStatus) { [weak self] _, _ in
                Task { @MainActor in self?.report() }
            }
            player.play()
            return player
        }

        private func report() {
            guard let player, let item = player.currentItem else { return }
            let t = player.currentTime().seconds
            guard t.isFinite else { return }
            let d = item.duration.seconds
            progress.update(position: t, duration: d.isFinite ? d : nil, paused: player.timeControlStatus == .paused)
        }

        func stop() {
            report()
            progress.flush()
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            statusObserver?.invalidate()
            player?.pause()
            player = nil
            if let previousAudio {
                try? AVAudioSession.sharedInstance().setCategory(previousAudio.0, mode: previousAudio.1, options: previousAudio.2)
            }
        }
    }
}
#endif
