#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import Foundation

/// 歌曲本地缓存：听过一遍就存下来，之后秒播、离线也能听、还省流量。
///
/// 顺带修一个 bug：网易云的播放直链是**有时效的**（几小时失效），
/// 之前把它当永久地址存进 Song.source，隔天再点就没声音。
/// 现在远端歌只存 songId，播放时先看本地有没有；没有才去要一条新链接，
/// 边播边下，下完存起来——下次就是本地文件了。
enum MusicCache {

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("music", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 缓存上限，超了从最久没听的开始删
    static let maxBytes: Int64 = 2_000_000_000   // 2 GB

    static func fileURL(songId: String) -> URL {
        dir.appendingPathComponent("\(songId).mp3")
    }

    static func has(songId: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(songId: songId).path)
    }

    /// 本地有就返回本地文件（播放器直接用），没有返回 nil
    static func localURL(songId: String) -> URL? {
        let u = fileURL(songId: songId)
        guard FileManager.default.fileExists(atPath: u.path),
              let size = try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int,
              size > 10_000 else { return nil }     // 太小的当下载失败
        touch(u)
        return u
    }

    /// 后台下载并存起来（已存在就跳过）
    static func store(songId: String, from remote: URL) {
        guard !has(songId: songId) else { return }
        Task.detached(priority: .utility) {
            guard let (tmp, resp) = try? await URLSession.shared.download(from: remote),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let dest = fileURL(songId: songId)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tmp, to: dest)
            await prune()
        }
    }

    /// 记一下"刚听过"，淘汰时保住常听的
    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// 超上限就从最久没听的开始删
    static func prune() async {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var items: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for f in files {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let s = v.fileSize, let d = v.contentModificationDate else { continue }
            items.append((f, Int64(s), d)); total += Int64(s)
        }
        guard total > maxBytes else { return }
        for it in items.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: it.url)
            total -= it.size
            if total <= maxBytes * 8 / 10 { break }   // 删到 80% 为止
        }
    }

    static func cachedSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { acc, f in
            acc + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
#endif
