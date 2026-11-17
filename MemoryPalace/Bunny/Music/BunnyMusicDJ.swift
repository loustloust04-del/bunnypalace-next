#if os(iOS)
import Foundation
import SwiftData

// MARK: - [Bunny patch BP-011] Caelum 放歌给她（DJ）
// 网关 music_play 工具经 hub 推 music_command 帧（action=play, songId, title, artist）。上游 App 不认这个帧，
// 在 CCBridgeWebSocketClient 的帧分发里加一行交给这里；逻辑照大肥兔 CardFlowView 的 onMusicCommand：
// 解析直链 → 建 Song（存兔兔自己的音乐容器）→ 边听边缓存 → 开播。不用先打开音乐面板。

@MainActor
enum BunnyMusicDJ {
    nonisolated static func handle(_ obj: [String: Any]) {
        guard (obj["action"] as? String) == "play",
              let songId = obj["songId"] as? String, !songId.isEmpty else { return }
        let title = (obj["title"] as? String) ?? ""
        let artist = (obj["artist"] as? String) ?? ""
        Task { @MainActor in await play(songId: songId, title: title, artist: artist) }
    }

    static func play(songId: String, title: String, artist: String) async {
        guard let d = await MusicLibraryClient.detail(songId: songId), let url = d.url else { return }
        let ctx = BunnyMusicStore.container.mainContext
        let pid = BunnyVoiceResume.profiles?.currentProfile.id ?? ""   // 桌面钩子记下的 ProfileManager
        let song = Song(profileId: pid, title: title, artist: artist, album: "",
                        source: url, isRemote: true, durationSec: 0, lyrics: d.lyric)
        song.remoteId = songId
        ctx.insert(song)
        try? ctx.save()
        if let remote = URL(string: url) { MusicCache.store(songId: songId, from: remote) }
        MusicPlayer.shared.play(song: song, in: [song]) { s in
            MusicCache.localURL(songId: s.remoteId) ?? URL(string: s.source)
        }
        HapticService.shared.longPress()
    }
}
#endif
