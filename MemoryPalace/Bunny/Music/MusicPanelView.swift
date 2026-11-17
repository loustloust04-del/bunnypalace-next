#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 音乐页：歌单 + 播放器 + 逐句歌词。
/// 「一起听」不是他听见声波，是他知道你在听什么、记得这首歌你们之间的事。
struct MusicPanelView: View {
    let profileId: String

    @Environment(\.modelContext) private var context
    @Query private var allSongs: [Song]
    @State private var player = MusicPlayer.shared
    @State private var showImporter = false
    @State private var tab = 0          // 正在听 / 曲库 / 本地

    private var songs: [Song] {
        allSongs.filter { $0.profileId == profileId && !$0.isRemote }
            .sorted { ($0.lastPlayedAt ?? $0.addedAt) > ($1.lastPlayedAt ?? $1.addedAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("正在听").tag(0)
                Text("曲库").tag(1)
                Text("本地").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14).padding(.top, 10)

            if tab == 0 {
                MusicListeningView(profileId: profileId, player: player) { tab = 1 }
            } else if tab == 1 {
                CloudMusicView(profileId: profileId)
            } else {
                if songs.isEmpty { emptyState } else { list }
            }
            if tab != 0 && player.currentSong != nil { miniPlayer }
        }
        .background(Theme.sidebarBg.ignoresSafeArea())
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onAppear {
            let pid = profileId
            player.urlResolver = { s in MusicPanelView.resolve(s, profileId: pid) }
            // 预取：远端且没缓存的下一首，提前换新直链（直链有时效）并落 MusicCache
            player.prefetcher = { s in
                guard s.isRemote, !s.remoteId.isEmpty, !MusicCache.has(songId: s.remoteId) else { return }
                Task {
                    if let d = await MusicLibraryClient.detail(songId: s.remoteId),
                       let fresh = d.url, let u = URL(string: fresh) {
                        await MainActor.run { s.source = fresh }
                        MusicCache.store(songId: s.remoteId, from: u)
                    }
                }
            }
            player.onSongStarted = { s in
                s.playCount += 1
                s.lastPlayedAt = Date()
                try? context.save()
                Task { await NowPlayingReporter.report(song: s) }
                LivelineReporter.report(.music, "兔兔在听《\(s.title)》— \(s.displayArtist)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 30)).foregroundColor(ConsoleView.green.opacity(0.5))
            Text("还没有歌\n先拖几首进来（mp3 / m4a）")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button("导入音乐") { showImporter = true }
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(ConsoleView.greenDeep)
            Text("歌词：把同名 .lrc 文件一起拖进来")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(songs) { s in
                Button {
                    MusicPanelView.playRemoteSafely(s, list: songs, profileId: profileId,
                                                    player: player, context: context)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: player.currentSong?.id == s.id
                              ? (player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                              : "music.note")
                            .font(.system(size: 12))
                            .foregroundColor(player.currentSong?.id == s.id ? ConsoleView.greenDeep : Theme.textMuted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.system(size: Theme.F.body)).foregroundColor(Theme.textPrimary)
                            HStack(spacing: 6) {
                                Text(s.displayArtist)
                                if s.playCount > 0 { Text("· 听过 \(s.playCount) 次") }
                                if !s.lyrics.isEmpty { Image(systemName: "text.quote").font(.system(size: 8)) }
                            }
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
                .contextMenu {
                    Button {
                        player.playNext(s)
                        HapticService.shared.longPress()
                    } label: { Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") }
                }
            }
            .onDelete { idx in
                for i in idx { context.delete(songs[i]) }
                try? context.save()
            }
            Button("导入音乐") { showImporter = true }
                .font(.system(size: Theme.F.caption))
                .foregroundColor(ConsoleView.greenDeep)
                .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var miniPlayer: some View {
        HStack(spacing: 8) {
            Button { tab = 0 } label: {
                HStack(spacing: 10) {
                    MusicArtwork(url: player.currentSong?.artworkURL, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.currentSong?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(player.currentSong?.displayArtist ?? "").font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("打开正在听")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            Button { player.next { MusicPanelView.resolve($0, profileId: profileId) } } label: {
                Image(systemName: "forward.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel("下一首")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textPrimary)
        .padding(10)
        .background(ConsoleView.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let rel = "music/\(url.lastPathComponent)"
            guard let dest = FileLibraryStore.absoluteURL(rel, profileId: profileId) else { continue }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? data.write(to: dest)

            var lrc = ""
            let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
            if let d = try? Data(contentsOf: lrcURL) { lrc = String(data: d, encoding: .utf8) ?? "" }

            var title = name, artist = ""
            if let r = name.range(of: " - ") {
                artist = String(name[..<r.lowerBound])
                title = String(name[r.upperBound...])
            }
            context.insert(Song(profileId: profileId, title: title, artist: artist,
                                source: rel, lyrics: lrc))
        }
        try? context.save()
    }

    /// 本地缓存优先 → 本地文件 → 上次的直链（可能已过期，由 refreshIfStale 兜底换新）
    static func resolve(_ s: Song, profileId: String) -> URL? {
        if s.isRemote {
            if let cached = MusicCache.localURL(songId: s.remoteId) { return cached }
            return URL(string: s.source)
        }
        return FileLibraryStore.absoluteURL(s.source, profileId: profileId)
    }

    /// 远端歌且没缓存时，去换一条新直链再播（直链有时效，隔天点会没声音）
    static func playRemoteSafely(_ s: Song, list: [Song], profileId: String,
                                 player: MusicPlayer, context: ModelContext) {
        if !s.isRemote || MusicCache.has(songId: s.remoteId) {
            player.play(song: s, in: list) { resolve($0, profileId: profileId) }
            return
        }
        Task {
            if !s.remoteId.isEmpty, let d = await MusicLibraryClient.detail(songId: s.remoteId),
               let fresh = d.url {
                await MainActor.run {
                    s.source = fresh
                    if !d.lyric.isEmpty { s.lyrics = d.lyric }
                    try? context.save()
                }
                MusicCache.store(songId: s.remoteId, from: URL(string: fresh)!)
            }
            await MainActor.run {
                player.play(song: s, in: list) { resolve($0, profileId: profileId) }
            }
        }
    }
}

/// 全屏歌词：逐句高亮跟唱，点某句跳到那儿，长按发给他
struct LyricsSheet: View {
    let player: MusicPlayer
    var onClose: () -> Void
    @State private var followsPlayback = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        if player.lyrics.isEmpty {
                            Text("这首歌暂时没有歌词")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                                .multilineTextAlignment(.center)
                                .padding(.top, 60)
                        }
                        ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { i, l in
                            Text(l.text)
                                .font(.title3.weight(.semibold))
                                .foregroundColor(i == player.currentLyricIndex ? ConsoleView.greenDeep : Theme.textMuted)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(i)
                                .onTapGesture { if l.time >= 0 { player.seek(to: l.time) } }
                                .contextMenu {
                                    Button { sendLine(l.text) } label: {
                                        Label("指着这句跟他说", systemImage: "bubble.left")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 40)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in followsPlayback = false })
                .onAppear {
                    if let idx = player.currentLyricIndex { proxy.scrollTo(idx, anchor: .center) }
                }
                .onChange(of: followsPlayback) { _, follows in
                    if follows, let idx = player.currentLyricIndex {
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
                .onChange(of: player.currentSong?.id) { _, _ in followsPlayback = true }
                .onChange(of: player.currentLyricIndex) { _, idx in
                    guard followsPlayback, let idx else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(idx, anchor: .center) }
                }
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle(player.currentSong?.title ?? "歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(followsPlayback ? "正在跟随" : "跟随当前") { followsPlayback = true }
                        .disabled(followsPlayback)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("收起") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }

    private func sendLine(_ text: String) {
        guard let s = player.currentSong else { return }
        let payload = """
        〈她在听歌〉《\(s.title)》— \(s.displayArtist)，正放到这句，她指着它给你看：

        「\(text)」
        """
        // T3（plan-listen-together-v2 D1）：改道主对话。原来发进 music-<songId> 的
        // 独立会话——她指一句，他在一个她从来不看的会话里回，情话全打了水漂。
        // 主对话 id 从最近一次 CC 发送记下的 lastCCChatId 取；一次都没聊过才回落老路。
        let mainChat = UserDefaults.standard.string(forKey: "lastCCChatId")
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: mainChat ?? "music-\(s.id)", messageId: UUID().uuidString, content: payload) { _ in }
    }
}

extension NowPlayingReporter {
    /// liveline 事件直投（单曲循环等心情信号用；节流在网关侧按 kind 管）
    static func livelineEvent(kind: String, text: String) async {
        let base = BunnyGateway.baseURL
        guard let url = URL(string: "\(base)/api/liveline") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if case let tk = BunnyGateway.token, !tk.isEmpty {
            req.setValue("Bearer \(tk)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 6
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": kind, "text": text])
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// T2 共听开关（网关 /listen/start|stop；路由随下次网关重启生效，之前静默失败无副作用）
enum ListenTogetherClient {
    static func set(on: Bool, title: String?, artist: String?) async -> Bool {
        let base = BunnyGateway.baseURL
        guard let url = URL(string: "\(base)/listen/\(on ? "start" : "stop")?key=\(BunnyGateway.tokenQuery)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let artist { body["artist"] = artist }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return result["ok"] as? Bool == true
        } catch { return false }
    }
}

/// 开播/心跳把「她在听什么·听到哪儿」报给网关（Caelum 的 now_playing 工具读的就是它）
enum NowPlayingReporter {
    static func report(song: Song) async {
        await beat(title: song.title, artist: song.artist, album: song.album,
                   position: 0, duration: song.durationSec, line: nil, state: "playing")
    }

    /// T1 共听心跳：进度 + 当前 LRC 行 + 播放状态（plan-listen-together-v2）
    static func beat(title: String, artist: String?, album: String?,
                     position: Double, duration: Double, line: String?, state: String) async {
        let base = BunnyGateway.baseURL
        guard let url = URL(string: "\(base)/now-playing?key=\(BunnyGateway.tokenQuery)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        var body: [String: Any] = [
            "title": title, "position": position, "duration": duration, "state": state,
        ]
        if let artist { body["artist"] = artist }
        if let album { body["album"] = album }
        if let line { body["line"] = line }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
#endif
