import Foundation
import Observation

/// 影院片库的一条（docs/plan-cinema-app.md §2）：一部片子一条，key = 规范化的视频 id
struct WatchLogEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case bilibili, youtube, web, link, file

        /// 以后加的来源（夸克等）在老版本里当网页读，别让整份片库解不出来
        init(from decoder: Decoder) throws {
            self = Source(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .web
        }
    }

    /// `bili:BV…#p` / `yt:<id>` / `url:<网址去参数>` / `file:<文件名>`
    let id: String
    var title: String
    var source: Source
    /// 原视频页 / 直链 / 影院目录里的文件名
    var url: String
    /// 本地封面文件名（影院封面目录里）或网址
    var cover: String?
    var duration: Double?
    var position: Double?
    var lastWatched: Date
    var plays: Int
    /// 在哪些对话里一起看过（最近的在前）
    var conversations: [String]

    /// 看到一半：过了 5%、没过 95%
    var inProgress: Bool {
        guard let duration, duration > 0, let position else { return false }
        let ratio = position / duration
        return ratio >= 0.05 && ratio < 0.95
    }

    var sourceLabel: String {
        switch source {
        case .bilibili: return "B 站"
        case .youtube: return "YouTube"
        case .web: return URL(string: url)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "网页"
        case .link: return "链接"
        case .file: return "文件"
        }
    }
}

/// 片库：一个 JSON 文件（不碰 SwiftData），最多 1000 条，旧的自动删。
/// 一起看小窗和影院放映页都往这写进度（每 10 秒、暂停、切走、关）
@MainActor
@Observable
final class WatchLog {
    static let shared = WatchLog()
    static let limit = 1000
    /// 隔这么久再看算又看了一次
    static let newSessionGap: TimeInterval = 30 * 60
    static let backfillKey = "cinema.backfilled.v1"

    private(set) var entries: [WatchLogEntry] = []
    @ObservationIgnored let directory: URL

    init(directory: URL = AppPaths.checked(AppPaths.applicationSupport.appendingPathComponent("MemoryPalace/Cinema", isDirectory: true))) {
        self.directory = directory
        entries = (try? Data(contentsOf: fileURL)).flatMap { try? Self.decoder.decode([WatchLogEntry].self, from: $0) } ?? []
    }

    private var fileURL: URL { directory.appendingPathComponent("watch-log.json") }
    /// 封面（截下来的画面）
    var coverDirectory: URL { directory.appendingPathComponent("Covers", isDirectory: true) }
    /// 从「文件」选进来的视频
    var filesDirectory: URL { directory.appendingPathComponent("Files", isDirectory: true) }

    var continueWatching: [WatchLogEntry] { entries.filter(\.inProgress) }

    func entry(_ id: String) -> WatchLogEntry? { entries.first { $0.id == id } }

    /// 记一笔：没有就新建，有就更新标题 / 时长 / 进度 / 时间。frame = 这一刻的画面（没封面时存成封面）
    func record(_ item: Item, position: Double?, duration: Double?, conversationId: String? = nil,
                frame: Data? = nil, at now: Date = Date()) {
        var entry = Self.upsert(entries.first { $0.id == item.key }, item: item, position: position, duration: duration,
                                conversationId: conversationId, at: now)
        if let frame, entry.cover == nil || entry.cover?.hasPrefix("http") == true {
            let name = Self.fileName(for: entry.id) + ".jpg"
            try? FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
            if (try? frame.write(to: coverDirectory.appendingPathComponent(name), options: .atomic)) != nil { entry.cover = name }
        }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries = Array(entries.prefix(Self.limit)) }
        save()
    }

    /// 补上网上查到的标题 / 封面 / 时长（不动进度和时间）
    func enrich(_ id: String, title: String?, cover: String?, duration: Double?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty, Self.isGenericTitle(entries[i].title) || entries[i].title == entries[i].url { entries[i].title = title }
        if let cover, entries[i].cover == nil { entries[i].cover = cover }
        if let duration, duration > 0, entries[i].duration == nil { entries[i].duration = duration }
        save()
    }

    func remove(_ id: String) {
        guard let entry = entry(id) else { return }
        if let cover = entry.cover, !cover.hasPrefix("http") { try? FileManager.default.removeItem(at: coverDirectory.appendingPathComponent(cover)) }
        if entry.source == .file { try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(entry.url)) }
        entries.removeAll { $0.id == id }
        save()
    }

    /// 回填（plan §2）：浏览历史和一起看记下的网址里认得出的视频，只有标题、没有进度。已有的不动
    func backfill(_ seen: [(url: String, title: String, date: Date)]) {
        var known = Set(entries.map(\.id))
        var added: [WatchLogEntry] = []
        for s in seen {
            guard let url = URL(string: s.url), let item = Self.item(for: url, title: s.title), item.source != .web,
                  known.insert(item.key).inserted else { continue }
            added.append(WatchLogEntry(id: item.key, title: item.title, source: item.source, url: item.url, cover: item.defaultCover,
                                       duration: nil, position: nil, lastWatched: s.date, plays: 1, conversations: []))
        }
        guard !added.isEmpty else { return }
        entries = Array((entries + added).sorted { $0.lastWatched > $1.lastWatched }.prefix(Self.limit))
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

// MARK: - 认片（纯函数，单测）

extension WatchLog {
    /// 一部片子的身份：key + 怎么显示、怎么放
    struct Item: Equatable {
        let key: String
        let source: WatchLogEntry.Source
        /// 原视频页 / 直链 / 文件名
        let url: String
        var title: String

        /// 不联网就有的封面：YouTube 缩略图地址
        var defaultCover: String? {
            guard source == .youtube, let id = key.split(separator: ":").last else { return nil }
            return "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
        }
    }

    static let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8", "webm", "mkv"]

    /// 认得出的片子：B 站 / YouTube 视频页（含嵌入页）、视频直链；网页里放着的别的视频传 pageWithVideo = true 记成 `url:`
    static func item(for url: URL, title: String = "", pageWithVideo: Bool = false) -> Item? {
        let title = cleanTitle(title)
        if let ref = ChatWatchPerception.videoRef(url) {
            return Item(key: ref.key, source: ref.site == .bilibili ? .bilibili : .youtube, url: ref.pageURL.absoluteString, title: title)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host()?.lowercased() else { return nil }
        let bare = "\(host)\(url.path())"
        if mediaExtensions.contains(url.pathExtension.lowercased()) {
            return Item(key: "url:\(bare)", source: .link, url: url.absoluteString, title: title.isEmpty ? url.lastPathComponent : title)
        }
        guard pageWithVideo else { return nil }
        return Item(key: "url:\(bare)", source: .web, url: url.absoluteString, title: title)
    }

    static func fileItem(name: String, title: String? = nil) -> Item {
        Item(key: "file:\(name)", source: .file, url: name, title: title ?? (name as NSString).deletingPathExtension)
    }

    /// 网页标题去掉站名尾巴；只有站名 / 播放器名的当没有标题（等片库去站方接口补）
    static func cleanTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["_哔哩哔哩_bilibili", "_哔哩哔哩bilibili", " - YouTube", " - 哔哩哔哩"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return isGenericTitle(t) ? "" : t
    }

    /// 浏览历史里常见的假标题（11-12 sim 实测）：YouTube 单页换页时还是「YouTube」，B 站手机嵌入页叫「wplayer embedded player」
    static func isGenericTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty || ["youtube", "bilibili", "哔哩哔哩", "哔哩哔哩 (゜-゜)つロ 干杯~-bilibili"].contains(t) || t.contains("embedded player")
    }

    static func upsert(_ old: WatchLogEntry?, item: Item, position: Double?, duration: Double?,
                       conversationId: String?, at now: Date) -> WatchLogEntry {
        var e = old ?? WatchLogEntry(id: item.key, title: item.title, source: item.source, url: item.url, cover: item.defaultCover,
                                     duration: nil, position: nil, lastWatched: now, plays: 0, conversations: [])
        if old == nil || now.timeIntervalSince(e.lastWatched) > newSessionGap { e.plays += 1 }
        if !item.title.isEmpty { e.title = item.title }
        if let duration, duration > 0 { e.duration = duration }
        if let position, position >= 0 { e.position = position }
        if let conversationId {
            e.conversations.removeAll { $0 == conversationId }
            e.conversations.insert(conversationId, at: 0)
            e.conversations = Array(e.conversations.prefix(20))
        }
        e.lastWatched = now
        return e
    }

    /// key 做文件名：只留字母数字
    static func fileName(for key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}
