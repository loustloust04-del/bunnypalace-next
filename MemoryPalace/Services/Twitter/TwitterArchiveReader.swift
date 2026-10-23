import Foundation

enum TwitterArchiveError: Error, Equatable {
    /// 负载既不是 `window.YTD.<name>.partN = <JSON>`，也不是裸 JSON
    case malformedWrapper
    /// 选进来的东西里找不到存档的 data/ 目录
    case noArchiveData
    /// 有 twitter-pull.json 但格式/版本认不出（不是我们的拉取脚本出的）
    case unsupportedPullFormat
}

/// 推特（X）导出包解析。
///
/// 存档的 `data/*.js` 不是 JS，是**一句 JS 赋值包着一段 JSON**：
/// `window.YTD.tweets.part0 = [ {"tweet": {…}}, … ]`。
enum TwitterArchiveReader {

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
    private static func isJSONOpener(_ b: UInt8) -> Bool { b == 0x5B /* [ */ || b == 0x7B /* { */ }

    /// 剥掉 `window.YTD.<name>.partN = ` 前缀，返回裸 JSON。
    ///
    /// 全程按字节走、不解成 `String`：重度用户单个 `tweets.js` 能到一两百 MB，
    /// 多一份 String 拷贝在 iOS 上就是一次 OOM。
    ///
    /// 只切**第一个** `=`——正文里的 `a=b&c=d`（URL query、颜文字）不能被二次切断。
    /// 已经是裸 JSON 的原样放行（有人会自己先剥壳），**且在找 `=` 之前就返回**，
    /// 否则裸 JSON 正文里的 `=` 会把自己切坏。
    static func stripJSWrapper(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var start = bytes.starts(with: bom) ? bom.count : 0
        while start < bytes.count, isSpace(bytes[start]) { start += 1 }

        var end = bytes.count
        while end > start, isSpace(bytes[end - 1]) { end -= 1 }
        guard start < end else { throw TwitterArchiveError.malformedWrapper }

        // 裸 JSON：必须先于找 `=` 判定
        if isJSONOpener(bytes[start]) { return Data(bytes[start..<end]) }

        guard let eq = bytes[start..<end].firstIndex(of: 0x3D /* = */) else {
            throw TwitterArchiveError.malformedWrapper
        }
        var payload = eq + 1
        while payload < end, isSpace(bytes[payload]) { payload += 1 }
        guard payload < end, isJSONOpener(bytes[payload]) else {
            throw TwitterArchiveError.malformedWrapper
        }
        return Data(bytes[payload..<end])
    }

    /// 推特 `created_at` 的格式（Twitter v1.1）：`"Wed Oct 10 20:19:24 +0000 2018"`。
    ///
    /// `en_US_POSIX` 不能省：月份名和星期名是英文字面量，设备切到中文/日文/阿拉伯历时
    /// 系统 locale 会让它们对不上 → `date(from:)` 静默返回 nil → 整份存档的时间线全空。
    /// 一份缓存的 formatter 复用：一次导入要解几万个时间戳，每次新建是实打实的开销。
    private static let createdAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f
    }()

    /// 解析推特的 `created_at`。解不动返回 nil（坏一条跳一条，不中断整批）。
    static func parseDate(_ raw: String) -> Date? {
        createdAtFormatter.date(from: raw)
    }

    private static let fm = FileManager.default

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 看起来像存档的 data/：里面有 tweets.js 或 account.js。
    /// 只认名字不够——存档外层也可能有叫 data 的无关目录。
    private static func looksLikeArchiveData(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent("tweets.js").path)
            || fm.fileExists(atPath: url.appendingPathComponent("account.js").path)
    }

    /// 定位存档里的 `data/` 目录。
    ///
    /// 解压出来的形状不统一：有时 zip 根就是 `data/` 的父目录，有时会多套一层
    /// （`Your archive/data/`）。限深 3 层广度优先，找不到返回 nil。
    static func locateDataDirectory(in root: URL) -> URL? {
        if looksLikeArchiveData(root) { return root }
        var frontier = [root]
        for _ in 0..<3 {
            var next: [URL] = []
            for dir in frontier {
                let candidate = dir.appendingPathComponent("data", isDirectory: true)
                if isDirectory(candidate), looksLikeArchiveData(candidate) { return candidate }
                let subs = (try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                next += subs.filter(isDirectory)
            }
            if next.isEmpty { break }
            frontier = next
        }
        return nil
    }

    /// `data/` 里的 tweets part 文件，**按 part 序号**排序。
    ///
    /// 不能按字典序：`tweets-part1.js` 会排到 `tweets.js` 前面，
    /// 导致时间线开头缺一大段。`tweets.js` 就是 part 0。
    static func tweetPartFiles(in dataDir: URL) -> [URL] {
        let files = (try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            if name == "tweets.js" { return (0, url) }
            guard name.hasPrefix("tweets-part"), name.hasSuffix(".js"),
                  let n = Int(name.dropFirst("tweets-part".count).dropLast(".js".count))
            else { return nil }
            return (n, url)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    /// 读 `data/<name>.js` 并解出顶层数组里第一条的 `key` 字典。
    private static func firstObject(_ fileName: String, key: String, in dataDir: URL) -> [String: Any]? {
        let url = dataDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let bare = try? stripJSWrapper(data),
              let rows = try? JSONSerialization.jsonObject(with: bare) as? [[String: Any]]
        else { return nil }
        return rows.first?[key] as? [String: Any]
    }

    /// 解析 `account.js`。
    static func parseAccount(in dataDir: URL) -> ParsedAccount? {
        guard let a = firstObject("account.js", key: "account", in: dataDir),
              let id = a["accountId"] as? String else { return nil }
        return ParsedAccount(
            accountId: id,
            screenName: (a["username"] as? String) ?? "",
            displayName: (a["accountDisplayName"] as? String) ?? "",
            createdAt: (a["createdAt"] as? String).flatMap(parseISODate)
        )
    }

    /// 解析 `profile.js`。
    static func parseProfile(in dataDir: URL) -> ParsedProfile? {
        guard let p = firstObject("profile.js", key: "profile", in: dataDir) else { return nil }
        let d = p["description"] as? [String: Any]
        return ParsedProfile(
            bio: (d?["bio"] as? String) ?? "",
            location: (d?["location"] as? String) ?? "",
            website: (d?["website"] as? String) ?? "",
            avatarURL: p["avatarMediaUrl"] as? String,
            bannerURL: p["headerMediaUrl"] as? String
        )
    }

    /// 计数字段在真实存档里**两种形状都出现过**：`"favorite_count":"12"`（字符串）
    /// 和 `"favorite_count":7`（数字）。两种都要吃，吃不动返回 nil。
    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func parseMedia(_ raw: Any?, tweetId: String) -> [ParsedMedia] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let mediaId = m["id_str"] as? String else { return nil }
            let large = (m["sizes"] as? [String: Any])?["large"] as? [String: Any]
            // 真存档里文件叫 <tweetId>-<媒体 URL 的文件名>（2026-09-24 对粟粟真存档核实）；
            // 视频/动图的文件是某个 mp4 码率的文件名。<tweetId>-<mediaId> 是早先的猜测，留作兜底。
            var stems: [String] = []
            func add(_ url: String?) {
                guard let url, let u = URL(string: url) else { return }
                let stem = u.deletingPathExtension().lastPathComponent
                if !stem.isEmpty, !stems.contains("\(tweetId)-\(stem)") { stems.append("\(tweetId)-\(stem)") }
            }
            add(m["media_url_https"] as? String ?? m["media_url"] as? String)
            let variants = ((m["video_info"] as? [String: Any])?["variants"] as? [[String: Any]]) ?? []
            for v in variants {
                guard let url = v["url"] as? String, URL(string: url)?.pathExtension.lowercased() == "mp4" else { continue }
                add(url)
            }
            stems.append("\(tweetId)-\(mediaId)")
            return ParsedMedia(
                id: mediaId,
                kind: (m["type"] as? String) ?? "photo",
                fileNameStems: stems,
                width: intValue(large?["w"]) ?? 0,
                height: intValue(large?["h"]) ?? 0
            )
        }
    }

    /// 解析一个 tweets part 文件（带壳）。
    ///
    /// **坏一条跳一条**：缺 `id_str` / 日期解不动的条目直接跳过，不中断整批——
    /// 一份存档几万条，为一条脏数据丢掉全部不可接受。
    /// 用 `JSONSerialization` 而非 `Codable`：计数字段字符串/数字混形，
    /// Codable 要写一堆 `init(from:)` 样板才能吃下，得不偿失。
    static func parseTweets(_ data: Data) throws -> [ParsedTweet] {
        let bare = try stripJSWrapper(data)
        guard let rows = try JSONSerialization.jsonObject(with: bare) as? [[String: Any]] else {
            throw TwitterArchiveError.malformedWrapper
        }
        return rows.compactMap { row -> ParsedTweet? in
            guard let t = row["tweet"] as? [String: Any],
                  let id = t["id_str"] as? String,
                  let createdAt = parseDate((t["created_at"] as? String) ?? "")
            else { return nil }

            let entities = t["entities"] as? [String: Any]
            let mediaList = (t["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]]
                ?? (entities?["media"] as? [[String: Any]]) ?? []
            var text = displayText((t["full_text"] as? String) ?? "",
                                   urls: (entities?["urls"] as? [[String: Any]]) ?? [],
                                   media: mediaList)
            // 转推：存档里只有「RT @原作者: 截断的原文」，没有原推本体
            var rtHandle: String?
            var rtName: String?
            if text.hasPrefix("RT @"),
               let first = (entities?["user_mentions"] as? [[String: Any]])?.first,
               let handle = first["screen_name"] as? String,
               text.hasPrefix("RT @\(handle):") {
                rtHandle = handle
                rtName = first["name"] as? String
                text = String(text.dropFirst("RT @\(handle):".count)).trimmingCharacters(in: .whitespaces)
            }
            return ParsedTweet(
                id: id,
                text: text,
                createdAt: createdAt,
                favoriteCount: intValue(t["favorite_count"]) ?? 0,
                retweetCount: intValue(t["retweet_count"]) ?? 0,
                inReplyToTweetId: t["in_reply_to_status_id_str"] as? String,
                inReplyToScreenName: t["in_reply_to_screen_name"] as? String,
                hashtags: (entities?["hashtags"] as? [[String: Any]])?
                    .compactMap { $0["text"] as? String } ?? [],
                mentions: (entities?["user_mentions"] as? [[String: Any]])?
                    .compactMap { $0["screen_name"] as? String } ?? [],
                urls: (entities?["urls"] as? [[String: Any]])?
                    .compactMap { $0["expanded_url"] as? String } ?? [],
                media: parseMedia((t["extended_entities"] as? [String: Any])?["media"], tweetId: id),
                retweetedScreenName: rtHandle,
                retweetedName: rtName
            )
        }
    }
}

extension TwitterArchiveReader {

    /// 存档正文 → 推特界面上看到的样子：
    /// ① 反 HTML 转义（存档里是 `&lt;` `&amp;`）；
    /// ② 链接的 t.co 换成 display_url；③ 媒体那条 t.co 去掉（图就在下面）。
    /// entity 里没给 `url` 的不动——不知道对应正文里哪一段，宁可原样。
    static func displayText(_ raw: String, urls: [[String: Any]], media: [[String: Any]]) -> String {
        var s = raw
        for u in urls {
            guard let short = u["url"] as? String, !short.isEmpty else { continue }
            let shown = (u["display_url"] as? String) ?? (u["expanded_url"] as? String) ?? short
            s = s.replacingOccurrences(of: short, with: shown)
        }
        for m in media {
            guard let short = m["url"] as? String, !short.isEmpty else { continue }
            s = s.replacingOccurrences(of: short, with: "")
        }
        s = unescapeHTML(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只处理推特实际会转义的三个；`&amp;` 放最后，免得 `&amp;lt;` 被连解两层。
    static func unescapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 带或不带毫秒的 ISO8601（存档是 `2026-03-02T04:19:47.577Z`，默认格式器吃不下毫秒）。
    static func parseISODate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// 解析 `note-tweet.js`（长推全文）。坏一条跳一条。
    static func parseNoteTweets(_ data: Data) throws -> [ParsedNoteTweet] {
        let bare = try stripJSWrapper(data)
        guard let rows = try JSONSerialization.jsonObject(with: bare) as? [[String: Any]] else {
            throw TwitterArchiveError.malformedWrapper
        }
        return rows.compactMap { row in
            guard let n = row["noteTweet"] as? [String: Any],
                  let text = (n["core"] as? [String: Any])?["text"] as? String,
                  let at = (n["createdAt"] as? String).flatMap(parseISODate)
            else { return nil }
            return ParsedNoteTweet(text: unescapeHTML(text), createdAt: at)
        }
    }

    /// 长推配回 tweets.js 里那条截断的：**存档没给关联 id**，只能按发推时刻配。
    /// ±2 秒内只有一条就是它；有好几条再用正文开头挑。返回 `tweetId → 全文`。
    static func matchNotes(_ notes: [ParsedNoteTweet],
                           to tweets: [(id: String, text: String, createdAt: Date)]) -> [String: String] {
        var out: [String: String] = [:]
        for note in notes {
            let near = tweets.filter { abs($0.createdAt.timeIntervalSince(note.createdAt)) <= 2 }
            if near.count == 1 {
                out[near[0].id] = note.text
                continue
            }
            let hits = near.filter { t in
                let head = t.text.replacingOccurrences(of: #"\s*https://t\.co/\S+"#, with: "",
                                                       options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespaces))
                return !head.isEmpty && note.text.hasPrefix(String(head.prefix(20)))
            }
            if hits.count == 1 { out[hits[0].id] = note.text }
        }
        return out
    }
}

struct ParsedMedia: Equatable {
    let id: String
    let kind: String
    /// `tweets_media/` 里可能的文件名主干，按优先级
    let fileNameStems: [String]
    let width: Int
    let height: Int
}

struct ParsedTweet: Equatable {
    let id: String
    /// var：长推要用 note-tweet.js 的全文替换
    var text: String
    let createdAt: Date
    let favoriteCount: Int
    let retweetCount: Int
    let inReplyToTweetId: String?
    let inReplyToScreenName: String?
    let hashtags: [String]
    let mentions: [String]
    let urls: [String]
    let media: [ParsedMedia]
    var retweetedScreenName: String? = nil
    var retweetedName: String? = nil
}

/// `note-tweet.js` 里的长推全文。tweets.js 里同一条只有截断的前半截。
struct ParsedNoteTweet: Equatable {
    let text: String
    let createdAt: Date
}

struct ParsedAccount: Equatable {
    let accountId: String
    let screenName: String
    let displayName: String
    let createdAt: Date?
}

struct ParsedProfile: Equatable {
    let bio: String
    let location: String
    let website: String
    let avatarURL: String?
    let bannerURL: String?
}
