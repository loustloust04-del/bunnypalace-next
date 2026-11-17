#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import SwiftUI
import SwiftData

/// 奶白与薄荷色的听歌空间；沿用同一个播放器，不创建第二条音频通路。
struct MusicListeningView: View {
    let profileId: String
    let player: MusicPlayer
    var browse: () -> Void
    @AppStorage("listenTogetherOn") private var together = false
    @State private var sending = false
    @State private var showError = false
    @State private var showLyrics = false
    @State private var showQueue = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("一起听").font(.title2.weight(.semibold))
                            Text("给这一刻，配一首歌").font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Image(systemName: "headphones").font(.title2).foregroundStyle(ConsoleView.greenDeep)
                    }
                    if let song = player.currentSong {
                        MusicArtwork(url: song.artworkURL, size: min(240, max(120, min(geometry.size.width - 48, geometry.size.height * 0.34))))
                            .shadow(color: ConsoleView.greenDeep.opacity(0.12), radius: 18, y: 10)
                            .padding(.vertical, 6)
                        VStack(spacing: 6) {
                            Text(song.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).textSelection(.enabled)
                            Text(song.displayArtist).font(.subheadline).foregroundStyle(Theme.textMuted)
                        }
                        MusicPlaybackTimeline(player: player)
                        transport
                        HStack(spacing: 12) {
                            Button { showLyrics = true } label: {
                                Label("歌词", systemImage: "text.quote").frame(maxWidth: .infinity, minHeight: 44)
                            }
                            Button { showQueue = true } label: {
                                Label("待播 · \(player.queue.count)", systemImage: "list.bullet").frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 16))
                        togetherCard
                        sleepMenu
                    } else {
                        MusicArtwork(url: nil, size: 160).padding(.top, 16)
                        Text("音乐还没响起").font(.title3.weight(.semibold))
                        Text("从曲库选一首，或去「本地」导入喜欢的歌。")
                            .font(.subheadline).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                        Button("去选一首歌", action: browse).buttonStyle(.borderedProminent).tint(ConsoleView.greenDeep)
                    }
                }
                .frame(maxWidth: 480)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(ConsoleView.greenDeep)
        .sheet(isPresented: $showLyrics) { LyricsSheet(player: player) { showLyrics = false } }
        .sheet(isPresented: $showQueue) { MusicQueueSheet(profileId: profileId, player: player) }
        .alert("共听分享暂时没有连接上", isPresented: $showError) {
            Button("知道了", role: .cancel) {}
        } message: { Text("已保留原来的开关状态，请稍后再试。") }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            Menu {
                Button("列表循环") { player.playMode = .sequence }
                Button("单曲循环") { player.playMode = .repeatOne }
                Button("随机播放") { player.playMode = .shuffle }
            } label: {
                Image(systemName: player.playMode == .repeatOne ? "repeat.1" : player.playMode == .shuffle ? "shuffle" : "repeat")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("播放模式")
            .accessibilityValue(player.playMode == .repeatOne ? "单曲循环" : player.playMode == .shuffle ? "随机播放" : "列表循环")
            Spacer(minLength: 0)
            Button { player.previous { MusicPanelView.resolve($0, profileId: profileId) } } label: {
                Image(systemName: "backward.fill").font(.title2).frame(width: 44, height: 44)
            }.accessibilityLabel("上一首")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Theme.mainBg)
                    .frame(width: 68, height: 68)
                    .background(ConsoleView.greenDeep, in: Circle())
            }.accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            Button { player.next { MusicPanelView.resolve($0, profileId: profileId) } } label: {
                Image(systemName: "forward.fill").font(.title2).frame(width: 44, height: 44)
            }.accessibilityLabel("下一首")
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .buttonStyle(.plain)
    }

    private var togetherCard: some View {
        Button {
            guard !sending else { return }
            let desired = !together
            let title = player.currentSong?.title
            let artist = player.currentSong?.artist
            sending = true
            Task {
                let succeeded = await ListenTogetherClient.set(on: desired, title: title, artist: artist)
                if succeeded { together = desired } else { showError = true }
                sending = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: together ? "person.2.fill" : "person.2").font(.title3)
                    .frame(width: 44, height: 44).background(ConsoleView.green.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(together ? "共听分享已开启" : "和 Caelum 一起听").font(.subheadline.weight(.semibold))
                    Text(together ? "把正在听的歌分享给他 · 点按关闭" : "让他知道，你此刻在听哪首歌")
                        .font(.caption).foregroundStyle(Theme.textMuted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if sending { ProgressView() } else { Image(systemName: together ? "checkmark" : "plus") }
            }
            .padding(14)
            .background(ConsoleView.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain).disabled(sending)
    }

    private var sleepMenu: some View {
        Menu {
            ForEach([15, 30, 60], id: \.self) { minutes in
                Button("\(minutes) 分钟后，听完当前这首停") { player.setSleepTimer(minutes: minutes) }
            }
            Button("听完这首停") { player.toggleStopAfterCurrent() }
            if player.sleepTimerEndsAt != nil || player.stopAfterCurrent {
                Button("取消定时", role: .destructive) { player.setSleepTimer(minutes: nil) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                if let end = player.sleepTimerEndsAt {
                    Text(end, style: .time)
                    Text("后听完当前这首停")
                } else { Text(player.stopAfterCurrent ? "听完这首就休息" : "睡眠定时") }
            }
            .font(.caption).foregroundStyle(Theme.textMuted).frame(minHeight: 44)
        }
    }
}

/// 把每秒更新的进度读数留在独立视图中，拖动结束才真正 seek。
private struct MusicPlaybackTimeline: View {
    let player: MusicPlayer
    @State private var scrubbing = false
    @State private var position: Double = 0
    private var duration: Double { player.duration.isFinite ? max(0, player.duration) : 0 }
    private var current: Double { player.currentTime.isFinite ? min(max(0, player.currentTime), duration) : 0 }
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { scrubbing ? min(position, max(1, duration)) : current }, set: { position = $0 }),
                   in: 0...max(1, duration), onEditingChanged: { editing in
                if editing { position = current; scrubbing = true }
                else { scrubbing = false; if duration > 0 { player.seek(to: min(max(0, position), duration)) } }
            })
            .disabled(duration <= 0).accessibilityLabel("播放进度")
            HStack {
                Text(clock(scrubbing ? position : current))
                Spacer()
                Text(duration > 0 ? clock(duration) : "--:--")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textMuted)
        }
        .onChange(of: player.currentSong?.id) { _, _ in scrubbing = false; position = 0 }
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(min(max(0, value), 604800))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct MusicArtwork: View {
    let url: String?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.09))
        .accessibilityHidden(true)
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [ConsoleView.green.opacity(0.24), Theme.mainBg], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(ConsoleView.greenDeep.opacity(0.14)).padding(size * 0.12)
            ForEach([0.20, 0.27, 0.34], id: \.self) { inset in
                Circle().stroke(ConsoleView.greenDeep.opacity(0.15), lineWidth: 1).padding(size * inset)
            }
            Image(systemName: "music.note").font(.system(size: size * 0.18, weight: .light)).foregroundStyle(ConsoleView.greenDeep)
        }
    }
}

private struct MusicQueueSheet: View {
    let profileId: String
    let player: MusicPlayer
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if player.queue.isEmpty {
                    Text("还没有待播歌曲，在曲库长按歌曲可选「下一首播放」。").foregroundStyle(Theme.textMuted)
                }
                ForEach(Array(player.queue.enumerated()), id: \.offset) { _, song in
                    Button {
                        MusicPanelView.playRemoteSafely(song, list: player.queue, profileId: profileId, player: player, context: context)
                    } label: {
                        HStack(spacing: 12) {
                            MusicArtwork(url: song.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title).font(.body).foregroundStyle(Theme.textPrimary)
                                Text(song.displayArtist).font(.caption).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            if song.id == player.currentSong?.id {
                                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill").foregroundStyle(ConsoleView.greenDeep)
                                    .accessibilityLabel("当前歌曲")
                            }
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                    .contextMenu { Button("下一首播放") { player.playNext(song) } }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.sidebarBg)
            .navigationTitle("待播列表").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(ConsoleView.greenDeep)
    }
}
#endif
