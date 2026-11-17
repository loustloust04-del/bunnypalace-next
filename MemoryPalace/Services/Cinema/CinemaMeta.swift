import Foundation

/// 片库的补料（plan-cinema-app §2）：第一次打开回填、B 站封面 / 标题 / 时长
@MainActor
enum CinemaMeta {
    /// 第一次打开影院：浏览历史（每个身份）+ 每个对话一起看记下的网址，认得出是视频的补进片库
    static func backfillOnce(_ log: WatchLog? = nil, defaults: UserDefaults = .standard) {
        let log = log ?? .shared
        guard !defaults.bool(forKey: WatchLog.backfillKey) else { return }
        var seen: [(url: String, title: String, date: Date)] = []
        for identity in BrowserIdentityStore.load() {
            seen += BrowsingHistoryStore.load(identity: identity.id).map { ($0.url, $0.title, $0.date) }
        }
        seen += ChatWatchStore.all(defaults).values.compactMap { s in s.url.map { ($0, "", s.updatedAt) } }
        log.backfill(seen)
        defaults.set(true, forKey: WatchLog.backfillKey)
    }

    /// 本次打开已经查过的（查不到的别每次进来都查）
    private static var tried = Set<String>()

    /// 缺标题 / 封面的去站方公开接口补（都不用登录）：B 站 view 接口（标题 / 封面 / 时长），YouTube oEmbed（标题）。
    /// 一次最多 20 条，一条一条来
    static func enrichMissing(_ log: WatchLog? = nil) async {
        let log = log ?? .shared
        let todo = log.entries.filter { entry in
            guard !tried.contains(entry.id) else { return false }
            switch entry.source {
            case .bilibili: return entry.cover == nil || WatchLog.isGenericTitle(entry.title) || entry.duration == nil
            case .youtube: return WatchLog.isGenericTitle(entry.title)
            default: return false
            }
        }
        for entry in todo.prefix(20) {
            tried.insert(entry.id)
            guard let ref = URL(string: entry.url).flatMap(ChatWatchPerception.videoRef) else { continue }
            let meta = ref.site == .bilibili ? await bilibili(bvid: ref.id, part: ref.part) : await youtube(ref.pageURL)
            guard let meta else { continue }
            log.enrich(entry.id, title: meta.title, cover: meta.cover, duration: meta.duration)
        }
    }

    struct Meta: Equatable {
        var title: String
        var cover: String?
        var duration: Double?
    }

    static func bilibili(bvid: String, part: Int) async -> Meta? {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(WebUserAgent.platformDefault, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parseBilibili(data, part: part)
    }

    static func youtube(_ page: URL) async -> Meta? {
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [URLQueryItem(name: "url", value: page.absoluteString), URLQueryItem(name: "format", value: "json")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let title = d["title"] as? String, !title.isEmpty else { return nil }
        return Meta(title: title, cover: nil, duration: nil)
    }

    /// `data.title / pic / duration / pages[]`；分 P 用那一 P 的时长，标题带上分 P 名
    nonisolated static func parseBilibili(_ data: Data, part: Int) -> Meta? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 0,
              let d = root["data"] as? [String: Any], let title = d["title"] as? String else { return nil }
        let pages = d["pages"] as? [[String: Any]] ?? []
        let page = pages.first { ($0["page"] as? NSNumber)?.intValue == part }
        var cover = d["pic"] as? String
        if cover?.hasPrefix("http://") == true { cover = "https://" + cover!.dropFirst(7) }
        let duration = ((page?["duration"] ?? d["duration"]) as? NSNumber)?.doubleValue
        let partName = pages.count > 1 ? (page?["part"] as? String).map { " · \($0)" } ?? "" : ""
        return Meta(title: title + partName, cover: cover, duration: duration)
    }
}

/// 片库里的进度 / 日期字样
enum CinemaText {
    static func ratio(_ e: WatchLogEntry) -> Double {
        guard let d = e.duration, d > 0, let p = e.position else { return 0 }
        return min(max(p / d, 0), 1)
    }

    static func progress(_ e: WatchLogEntry) -> String {
        guard let p = e.position else { return "" }
        let total = e.duration.map { " / \(ChatWatchPerception.clock($0))" } ?? ""
        return "看到 \(ChatWatchPerception.clock(p))\(total)"
    }

    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "昨天" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month(.defaultDigits).day().year(sameYear ? .omitted : .defaultDigits))
    }
}
