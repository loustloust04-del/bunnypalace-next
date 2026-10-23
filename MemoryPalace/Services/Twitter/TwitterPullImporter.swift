import Foundation
import SwiftData

/// 书签文件夹的取数口。
enum TwitterBookmarkFolders {
    /// 当前账号的书签文件夹。
    static func all(profileId: String, context: ModelContext) -> [TwitterBookmarkFolder] {
        let account = TwitterAccounts.activeId(profileId: profileId, context: context)
        return (try? context.fetch(TwitterQueries.bookmarkFolders(profileId: profileId, account: account))) ?? []
    }
}

/// 从 X 直接拉下来的包（粟粟 2026-09-24：官方导出不含书签）。
///
/// Mac 上 `scripts/twitter-pull.py` 调 OpenCLI 拉书签（含书签文件夹）、点过的赞、自己的新推，
/// 连同媒体打成一个 zip：
/// ```
/// twitter-pull.json          清单：format / version / pulledAt / me / folders / bookmarks / likes / tweets
/// twitter-pull-media/<文件>  媒体，平铺
/// ```
/// 隔空投送到手机，用「导入存档」导进来——导入器认出清单就走这里。
///
/// 规则：
/// - 别人的推记 `authorScreenName`/`authorName`，**不进自己的时间线**，只在书签页、「喜欢」、搜索里出现
/// - 已经有的推（比如存档里自己的推被自己收藏了）不新增，只打标记
/// - X 不给「什么时候加的书签」，只给先后：按顺序倒推一个 `bookmarkedAt`，已经收藏过的不动
/// - 拉的是哪个号（清单里的 `me`）就进哪个号，不看当前选中的账号
enum TwitterPullImporter {
    static let manifestName = "twitter-pull.json"
    static let mediaDirName = "twitter-pull-media"
    static let format = "memorypalace.twitter-pull"
    static let version = 1
    /// 只从 X 拉过、还没导过官方存档的号，accountId 用它打头（X 的数字 id 拉取包里没有）
    static let pulledAccountPrefix = "pull-"

    /// 在包里找清单：根目录或往下一层（zip 外面常多套一层文件夹）。
    static func locateManifest(in root: URL) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent(manifestName)
        if fm.fileExists(atPath: direct.path) { return direct }
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        for sub in subs {
            let candidate = sub.appendingPathComponent(manifestName)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func importPull(manifest: URL, profileId: String, context: ModelContext,
                           mediaRoot: URL) throws -> TwitterImportResult {
        let data = try Data(contentsOf: manifest)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String == format,
              (json["version"] as? Int) == version
        else { throw TwitterArchiveError.unsupportedPullFormat }

        let fm = FileManager.default
        let mediaSource = manifest.deletingLastPathComponent().appendingPathComponent(mediaDirName)
        let mediaDir = mediaRoot.appendingPathComponent(profileId, isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let meInfo = json["me"] as? [String: Any]
        let me = (meInfo?["screenName"] as? String) ?? ""
        let accounts = TwitterAccounts.all(profileId: profileId, context: context)
        var owner = accounts.first { !me.isEmpty && $0.screenName.caseInsensitiveCompare(me) == .orderedSame }
        if owner == nil, !me.isEmpty {
            // App 里还没有这个号（粟粟 2026-09-24 换了会员号登录拉）：新建它，不能塞进别的号。
            // id 用 pull- 前缀占位，以后导入这个号的官方存档时会被接管、换成真 id
            let fresh = TwitterArchiveAccount(profileId: profileId, accountId: pulledAccountPrefix + me.lowercased(),
                                              screenName: me,
                                              displayName: (meInfo?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? me,
                                              sourceName: "从 X 拉取")
            context.insert(fresh)
            owner = fresh
        }
        owner = owner ?? TwitterAccounts.active(profileId: profileId, context: context)
        if let owner { try TwitterAccounts.activate(owner, context: context) }
        let accountId = owner?.accountId ?? ""
        let pulledAt = (json["pulledAt"] as? String).flatMap(TwitterArchiveReader.parseISODate) ?? Date()

        var result = TwitterImportResult()

        func isMe(_ handle: String?) -> Bool {
            guard let handle, !me.isEmpty else { return false }
            return handle.caseInsensitiveCompare(me) == .orderedSame
        }

        /// 有就拿现成的（只补标记），没有就建。`newlyCreated` 告诉调用方是不是新的。
        func upsert(_ t: [String: Any]) throws -> (row: TweetEntry, newlyCreated: Bool)? {
            guard let id = t["id"] as? String, !id.isEmpty else { return nil }
            if let existing = try context.fetch(TwitterQueries.existing(profileId: profileId, tweetId: id)).first {
                return (existing, false)
            }
            let author = t["author"] as? String
            let text = TwitterArchiveReader.unescapeHTML((t["text"] as? String) ?? "")
            let row = TweetEntry(
                profileId: profileId, tweetId: id, text: text,
                createdAt: (t["created_at"] as? String).flatMap(TwitterArchiveReader.parseDate) ?? pulledAt,
                favoriteCount: count(t["likes"]), retweetCount: count(t["retweets"]),
                hashtagsJoined: TwitterComposer.hashtags(in: text).joined(separator: " "))
            row.accountId = accountId
            if let url = t["url"] as? String, !url.isEmpty { row.sourceURL = url }
            if (t["is_retweet"] as? Bool) == true, !isMe(author) {
                // 自己转别人的：跟存档里的转推一样，进自己时间线、带转推头
                row.retweetedScreenName = author
                row.retweetedName = t["name"] as? String
            } else if !isMe(author) {
                row.authorScreenName = author
                row.authorName = t["name"] as? String
            }
            var copied = 0
            for (i, m) in ((t["media"] as? [[String: Any]]) ?? []).enumerated() {
                guard let file = m["file"] as? String, !file.isEmpty, !file.contains("/") else { continue }
                let src = mediaSource.appendingPathComponent(file)
                guard fm.fileExists(atPath: src.path) else { continue }   // 下载失败的图跳过，不挡整包
                let dest = mediaDir.appendingPathComponent(file)
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
                context.insert(TweetMedia(profileId: profileId, tweetId: id, mediaId: "\(i)",
                                          kind: (m["kind"] as? String) ?? "photo", fileName: file))
                copied += 1
            }
            row.mediaCount = copied
            result.mediaCopied += copied
            if let q = t["quoted"] as? [String: Any], let quoted = try upsert(q) {
                row.quotedTweetId = quoted.row.tweetId
            }
            context.insert(row)
            return (row, true)
        }

        // ---- 书签文件夹 ----
        let existingFolders = try context.fetch(TwitterQueries.bookmarkFolders(profileId: profileId, account: accountId))
        for (i, f) in ((json["folders"] as? [[String: Any]]) ?? []).enumerated() {
            guard let fid = f["id"] as? String else { continue }
            let name = (f["name"] as? String) ?? ""
            if let row = existingFolders.first(where: { $0.folderId == fid }) {
                row.name = name
                row.order = i
            } else {
                context.insert(TwitterBookmarkFolder(profileId: profileId, accountId: accountId,
                                                     folderId: fid, name: name, order: i))
            }
        }

        // ---- 书签：X 给的顺序就是收藏先后（新的在前） ----
        for (i, t) in ((json["bookmarks"] as? [[String: Any]]) ?? []).enumerated() {
            guard let (row, _) = try upsert(t) else { continue }
            if row.bookmarkedAt == nil {
                row.bookmarkedAt = pulledAt.addingTimeInterval(-Double(i))
                result.bookmarksImported += 1
            }
            for fid in (t["folderIds"] as? [String]) ?? [] where !row.bookmarkFolderIds.contains("|\(fid)|") {
                row.bookmarkFolderIds += row.bookmarkFolderIds.isEmpty ? "|\(fid)|" : "\(fid)|"
            }
        }

        // ---- 点过的赞（X 的赞数里已经含自己这一个，不再 +1） ----
        for t in (json["likes"] as? [[String: Any]]) ?? [] {
            guard let (row, _) = try upsert(t) else { continue }
            if !row.likedByMe {
                row.likedByMe = true
                result.likesImported += 1
            }
        }

        // ---- 自己的新推：存档里已有的会被查重挡掉 ----
        for t in (json["tweets"] as? [[String: Any]]) ?? [] {
            guard let (_, isNew) = try upsert(t) else { continue }
            if isNew { result.tweetsImported += 1 } else { result.tweetsSkipped += 1 }
        }

        // 显式 save：规则写明主 ctx 不 save，后台 ctx 会读到旧值
        try context.save()
        return result
    }

    /// 计数在 OpenCLI 输出里可能是数字也可能是字符串
    private static func count(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }
}
