#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import SwiftUI
import SwiftData

/// 云端曲库：我的歌单 + 搜索。点一首就播（直链现取，有时效）。
struct CloudMusicView: View {
    let profileId: String
    @Environment(\.modelContext) private var context
    @State private var player = MusicPlayer.shared

    @State private var browser = MusicLibraryBrowser()
    @State private var searchText = ""
    @State private var loadingSongId: String?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .task(id: profileId) {
            searchText = ""
            browser.start()
        }
        .onChange(of: searchText) { _, text in browser.inputChanged(text) }
        .onDisappear { browser.stop() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.textMuted)
            TextField("搜歌名、歌手", text: $searchText)
                .font(.system(size: Theme.F.body))
                .submitLabel(.search)
                .onSubmit { browser.runSearch(searchText) }
            if !searchText.isEmpty {
                Button { searchText = ""; browser.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textMuted)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.mainBg))
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let query = browser.submittedQuery {
            switch browser.search {
            case .idle, .loading:
                loadingState("正在搜索…")
            case .loaded(let songs):
                if songs.isEmpty {
                    messageState("没有找到相关歌曲", detail: "试试换个歌名或歌手，或清空搜索返回歌单。", icon: "magnifyingglass")
                } else { songList(songs, title: "“\(query)”的搜索结果") }
            case .failed(let message):
                messageState("搜索暂时没完成", detail: message, icon: "wifi.exclamationmark", retry: { browser.runSearch(query) })
            }
        } else if let list = browser.openedList {
            VStack(spacing: 0) {
                HStack {
                    Button { browser.closePlaylist() } label: {
                        Label("返回歌单", systemImage: "chevron.left")
                            .font(.system(size: Theme.F.caption)).frame(minHeight: 44)
                    }
                    .foregroundColor(ConsoleView.greenDeep)
                    Spacer()
                    Text(list.name).font(.subheadline).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                .padding(.horizontal, 16)
                switch browser.playlist {
                case .idle, .loading:
                    loadingState("正在加载歌曲…")
                case .loaded(let songs):
                    if songs.isEmpty {
                        messageState("这张歌单还没有歌曲", detail: "可以返回选另一张，或直接搜索喜欢的歌。", icon: "music.note.list")
                    } else { songList(songs, title: nil) }
                case .failed(let message):
                    messageState("歌单暂时没加载出来", detail: message, icon: "wifi.exclamationmark", retry: { browser.open(list) })
                }
            }
        } else {
            switch browser.catalogue {
            case .idle, .loading:
                loadingState("正在连接曲库…")
            case .failed(let message):
                messageState("暂时连接不上曲库", detail: message, icon: "wifi.exclamationmark", retry: { browser.reloadCatalogue() })
            case .loaded(let catalogue):
                if !catalogue.status.loggedIn {
                    messageState("音源需要重新登录", detail: "登录状态已失效，重新扫码后再试。", icon: "person.crop.circle.badge.exclamationmark", retry: { browser.reloadCatalogue() })
                } else if catalogue.playlists.isEmpty {
                    messageState("还没有歌单", detail: "可以在上方搜索歌名或歌手。", icon: "music.note.list")
                } else { playlistGrid(catalogue) }
            }
        }
    }

    private func loadingState(_ title: String) -> some View {
        ProgressView(title).tint(ConsoleView.greenDeep)
            .font(.subheadline).foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageState(_ title: String, detail: String, icon: String, retry: (() -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(ConsoleView.greenDeep)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.subheadline).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
            if let retry {
                Button("重新试试", action: retry).buttonStyle(.bordered).tint(ConsoleView.greenDeep)
                    .frame(minHeight: 44)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playlistGrid(_ catalogue: MusicLibraryBrowser.Catalogue) -> some View {
        List {
            Section {
                ForEach(catalogue.playlists) { p in
                    Button { searchText = ""; browser.open(p) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 13)).foregroundColor(ConsoleView.greenDeep).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: Theme.F.body)).foregroundColor(Theme.textPrimary)
                                Text("\(p.count) 首").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                        }
                    }
                    .buttonStyle(.plain).listRowBackground(Theme.mainBg)
                }
            } header: { Text("\(catalogue.status.nickname ?? "我")的歌单") }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
    }

    private func songList(_ songs: [MusicLibraryClient.RemoteSong], title: String?) -> some View {
        List {
            Section {
                ForEach(songs) { s in
                    Button { playRemote(s, in: songs) } label: {
                        HStack(spacing: 10) {
                            MusicArtwork(url: s.cover, size: 44)
                                .overlay {
                                    if loadingSongId == s.id { ProgressView().tint(ConsoleView.greenDeep) }
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: Theme.F.body))
                                    .foregroundColor(Theme.textPrimary).lineLimit(1)
                                Text(s.artist).font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted).lineLimit(1)
                            }
                            Spacer()
                            if player.currentSong?.remoteId == s.id {
                                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                    .foregroundStyle(ConsoleView.greenDeep)
                                    .accessibilityLabel("当前歌曲")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.mainBg)
                    .contextMenu {
                        Button {
                            queueNext(r: s)
                        } label: { Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    }
                }
            } header: { if let t = title { Text(t) } }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 动作

    /// 云端歌曲：现取直链和歌词 → 落成本地 Song（带 isRemote）→ 交给播放器
    /// 云端歌「下一首播放」：解析直链→建 Song（边听边存照旧）→插队；没在放歌就直接开播
    private func queueNext(r: MusicLibraryClient.RemoteSong) {
        Task {
            guard let d = await MusicLibraryClient.detail(songId: r.id), let url = d.url else { return }
            let song = Song(profileId: profileId, title: r.title, artist: r.artist, album: r.album,
                            source: url, isRemote: true, durationSec: Double(r.duration), lyrics: d.lyric)
            song.remoteId = r.id
            song.artworkURL = r.cover
            context.insert(song)
            try? context.save()
            if let remote = URL(string: url) { MusicCache.store(songId: r.id, from: remote) }
            await MainActor.run {
                player.playNext(song)
                HapticService.shared.longPress()
            }
        }
    }

    private func playRemote(_ r: MusicLibraryClient.RemoteSong, in list: [MusicLibraryClient.RemoteSong]) {
        loadingSongId = r.id
        Task {
            defer { loadingSongId = nil }
            guard let d = await MusicLibraryClient.detail(songId: r.id), let url = d.url else { return }
            let song = Song(profileId: profileId, title: r.title, artist: r.artist, album: r.album,
                            source: url, isRemote: true, durationSec: Double(r.duration), lyrics: d.lyric)
            song.remoteId = r.id
            song.artworkURL = r.cover
            context.insert(song)
            try? context.save()
            // 边听边存，下次就是本地文件
            if let remote = URL(string: url) { MusicCache.store(songId: r.id, from: remote) }
            player.play(song: song, in: [song]) { s in
                MusicCache.localURL(songId: s.remoteId) ?? URL(string: s.source)
            }
        }
    }
}
#endif
