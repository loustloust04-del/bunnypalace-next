#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import Foundation
import SwiftData

/// 一首歌 + 你们俩关于它的记录。
/// 「一起听」的实质不是他听见声波，是他记得你和这首歌的事：
/// 听过几次、第一次是什么时候、以前听这首时你说过什么。
@Model
final class Song {
    #Index<Song>([\.profileId], [\.profileId, \.lastPlayedAt])

    var id: String = UUID().uuidString
    var profileId: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    /// 可选封面；旧歌曲与本地音频使用唱片占位图。
    var artworkURL: String?
    /// 文件库相对路径（本地文件）；远端歌这里存的是**上次的直链**，仅作兜底
    var source: String = ""
    var isRemote: Bool = false
    /// 远端歌的曲库 ID。直链有时效（几小时失效），所以真正该留的是这个——
    /// 播放时先看本地缓存，没有再拿 ID 去换一条新链接。
    var remoteId: String = ""
    var durationSec: Double = 0
    /// LRC 歌词原文（可空）
    var lyrics: String = ""

    var addedAt: Date = Date()
    var lastPlayedAt: Date?
    /// 一起听过几次
    var playCount: Int = 0
    /// 她听这首时说过的话（滚动保留最近若干条）
    var notes: [String] = []
    /// 攒够后合成的一小段"这首歌对我们的意义"
    var memory: String = ""

    init(profileId: String, title: String, artist: String = "", album: String = "",
         source: String, isRemote: Bool = false, durationSec: Double = 0, lyrics: String = "") {
        self.id = UUID().uuidString
        self.profileId = profileId
        self.title = title
        self.artist = artist
        self.album = album
        self.source = source
        self.isRemote = isRemote
        self.durationSec = durationSec
        self.lyrics = lyrics
        self.addedAt = Date()
    }

    var displayArtist: String { artist.isEmpty ? "未知歌手" : artist }
    var key: String { artist.isEmpty ? title : "\(title) - \(artist)" }
}

/// LRC 歌词一行
struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: Double      // 秒
    let text: String
}

enum LyricParser {
    /// 解析 LRC：[mm:ss.xx] 文本；无时间戳的行按纯文本处理（time = -1）
    static func parse(_ lrc: String) -> [LyricLine] {
        guard !lrc.isEmpty else { return [] }
        var out: [LyricLine] = []
        let re = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = re?.matches(in: raw, range: NSRange(location: 0, length: ns.length)) ?? []
            guard !ms.isEmpty else {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !t.hasPrefix("[") { out.append(LyricLine(time: -1, text: t)) }
                continue
            }
            let lastEnd = ms.last!.range.location + ms.last!.range.length
            let text = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for m in ms {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append(LyricLine(time: mm * 60 + ss + frac, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// 当前时刻唱到哪一行
    static func currentIndex(_ lines: [LyricLine], at t: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var idx: Int? = nil
        for (i, l) in lines.enumerated() where l.time >= 0 && l.time <= t { idx = i }
        return idx
    }
}
#endif
