import Foundation
import SwiftData

/// 导入的阶段。大存档要导好几分钟，UI 靠它给反馈。
enum TwitterImportPhase: String, Equatable, Sendable {
    case unzip      // 解包（仅 zip 入口有）
    case parse      // 逐 part 解析 + 写库
    case finish     // 收尾
}

struct TwitterImportResult: Equatable {
    var tweetsImported = 0
    var tweetsSkipped = 0
    var mediaCopied = 0
    var accountImported = false
    /// 拉取包（twitter-pull.json）才有
    var bookmarksImported = 0
    var likesImported = 0
}

/// 推特存档导入管线：解包 → 定位 data/ → 逐 part 解析 → 分批写库 → 媒体落盘。
enum TwitterArchiveImporter {

    /// 媒体落盘根目录。照 `StickerFileManager.stickerDirectory` 的先例：
    /// `Application Support/MemoryPalace/twitter/`，再按 profileId 分子目录。
    static func defaultMediaRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("twitter", isDirectory: true)
    }

    /// 一批写一次库。太小则 save 太频（每次 save 都要落盘），太大则峰值内存高。
    private static let batchSize = 500

    /// 导入一份存档。`source` 可以是 `.zip`，也可以是已解压的文件夹。
    /// `mediaRoot` 可注入——测试传临时目录，免得往粟粟真实 Application Support 里写。
    static func importArchive(at source: URL,
                              profileId: String,
                              context: ModelContext,
                              mediaRoot: URL? = nil,
                              onProgress: (@Sendable (TwitterImportPhase, Double) -> Void)? = nil) async throws -> TwitterImportResult {

        // 沙箱外的 URL（文件选择器给的）必须开权限再读
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var workRoot = source
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }

        if source.pathExtension.lowercased() == "zip" {
            onProgress?(.unzip, 0)
            let tmp = fm.temporaryDirectory.appendingPathComponent("tw-unzip-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            scratch = tmp
            // 不用 ZIPFoundation：它读推特的 ZIP64 包是 0 个文件，见 TwitterZipExtractor 的注释。
            // 只解导入要用的，私信之类的不落盘。
            // 解压是纯文件读写、不碰 SwiftData，放后台线程：拉取包近 1GB，放主线程上界面会整个卡死、进度条也不动
            try await Task.detached(priority: .userInitiated) {
                try TwitterZipExtractor.extract(source, to: tmp, include: TwitterZipExtractor.neededForImport,
                                                onProgress: { onProgress?(.unzip, $0) })
            }.value
            workRoot = tmp
            onProgress?(.unzip, 1)
        }

        // 从 X 拉的包，不是官方导出：走另一条导入
        if let pull = TwitterPullImporter.locateManifest(in: workRoot) {
            onProgress?(.parse, 0)
            let r = try TwitterPullImporter.importPull(manifest: pull, profileId: profileId, context: context,
                                                       mediaRoot: mediaRoot ?? defaultMediaRoot())
            onProgress?(.finish, 1)
            return r
        }

        guard let dataDir = TwitterArchiveReader.locateDataDirectory(in: workRoot) else {
            throw TwitterArchiveError.noArchiveData
        }

        var result = TwitterImportResult()

        // ---- 媒体：先把 tweets_media/ 建成 stem → 文件 的索引，避免逐条扫目录 ----
        let mediaDir = (mediaRoot ?? defaultMediaRoot()).appendingPathComponent(profileId, isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let mediaSource = dataDir.appendingPathComponent("tweets_media", isDirectory: true)
        var mediaByStem: [String: URL] = [:]
        for f in (try? fm.contentsOfDirectory(at: mediaSource, includingPropertiesForKeys: nil)) ?? [] {
            mediaByStem[f.deletingPathExtension().lastPathComponent] = f
        }

        // ---- 账号 + 资料 ----
        // 一楼层可以有多个账号（粟粟 2026-09-24）。认账号的规则：
        // ① 同一个 accountId → 更新那一条；①′ 同名的「只从 X 拉过」的号 → 接管（换成真 id）；
        // ② 楼层里只有示例账号 → 真账号接管它（示例推文一起带过来）；
        // ③ 否则是另一个账号 → 新建一条。导完切到这个账号。
        // 推文都打上这个 accountId；存档没有 account.js 时挂到当前账号上。
        var tweetOwner = TwitterAccounts.activeId(profileId: profileId, context: context)
        if let account = TwitterArchiveReader.parseAccount(in: dataDir) {
            let profile = TwitterArchiveReader.parseProfile(in: dataDir)
            let rows = TwitterAccounts.all(profileId: profileId, context: context)
            let row: TwitterArchiveAccount
            if let same = rows.first(where: { $0.accountId == account.accountId }) {
                row = same
            } else if let pulled = rows.first(where: {
                $0.accountId.hasPrefix(TwitterPullImporter.pulledAccountPrefix)
                    && $0.screenName.caseInsensitiveCompare(account.screenName) == .orderedSame
            }) {
                // 这个号之前只从 X 拉过（占位 id）：接管它，拉来的书签、赞、文件夹都换挂到真 id 上
                row = pulled
                let oldId = pulled.accountId
                for t in try context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
                    $0.profileId == profileId && $0.accountId == oldId
                })) { t.accountId = account.accountId }
                for f in try context.fetch(FetchDescriptor<TwitterBookmarkFolder>(predicate: #Predicate {
                    $0.profileId == profileId && $0.accountId == oldId
                })) { f.accountId = account.accountId }
            } else if rows.count == 1, rows[0].accountId == TwitterDemoSeed.demoAccountId {
                row = rows[0]
                let demoId = TwitterDemoSeed.demoAccountId
                for t in try context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
                    $0.profileId == profileId && $0.accountId == demoId
                })) { t.accountId = account.accountId }
            } else {
                row = TwitterArchiveAccount(profileId: profileId, accountId: account.accountId,
                                            screenName: account.screenName, displayName: account.displayName)
                context.insert(row)
            }
            // 手改保护只护同一个账号：示例账号上改过的，导真存档时存档优先
            // （粟粟 2026-09-24 真机：先在示例上试过编辑，真存档的名字/简介/头像/横幅全被挡掉）
            let sameAccount = row.accountId == account.accountId
            row.accountId = account.accountId
            row.accountCreatedAt = account.createdAt
            row.sourceName = source.lastPathComponent
            tweetOwner = account.accountId
            try TwitterAccounts.activate(row, context: context)
            result.accountImported = true

            // 头像/横幅：profile.js 只给远端 URL，本地原图在 data/profile_media/。
            // 不联网，所以只能从这儿认：按远端 URL 的文件名主干去匹配本地文件
            // （本地名形如 `<accountId>-avatar.jpg`，远端是 `…/avatar.jpg`）。
            let pmFiles = (try? fm.contentsOfDirectory(
                at: dataDir.appendingPathComponent("profile_media", isDirectory: true),
                includingPropertiesForKeys: nil)) ?? []
            func adopt(_ remote: String?) -> String? {
                guard let remote,
                      let stem = URL(string: remote)?.deletingPathExtension().lastPathComponent,
                      !stem.isEmpty,
                      let src = pmFiles.first(where: {
                          $0.deletingPathExtension().lastPathComponent.hasSuffix(stem)
                      })
                else { return nil }
                let name = src.lastPathComponent
                let dest = mediaDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: src, to: dest) }
                return name
            }
            // 存档原样另存一份：之后手改了也能一键恢复，不用再导一次
            row.archiveScreenName = account.screenName
            row.archiveDisplayName = account.displayName
            row.archiveBio = profile?.bio ?? ""
            row.archiveLocation = profile?.location ?? ""
            row.archiveWebsite = profile?.website ?? ""
            row.archiveAvatarFileName = adopt(profile?.avatarURL)
            row.archiveBannerFileName = adopt(profile?.bannerURL)

            if row.editedAt == nil || !sameAccount {
                TwitterProfileEditor.applyArchiveProfile(to: row)
            }
        }

        // ---- 逐 part 解析 + 分批写库 ----
        // 查重按批一次 `IN` 查询，而不是逐条查：几万条存档逐条查是几万次 fetch。
        // 也不能一次把全楼层的 id 拉出来——规则禁止无条件全量 fetch。
        var pending: [ParsedTweet] = []
        var seenInThisRun = Set<String>()   // 同一份存档里自带的重复，批内也要挡住

        func flush() throws {
            guard !pending.isEmpty else { return }
            let ids = pending.map(\.id)
            let existing = try context.fetch(FetchDescriptor<TweetEntry>(
                predicate: #Predicate { $0.profileId == profileId && ids.contains($0.tweetId) }))
            let existingIds = Set(existing.map(\.tweetId))
            let existingById = Dictionary(existing.map { ($0.tweetId, $0) }, uniquingKeysWith: { a, _ in a })

            /// 媒体落盘 + 建行，返回建了几条
            func adoptMedia(_ t: ParsedTweet) -> Int {
                var n = 0
                for m in t.media {
                    guard let src = m.fileNameStems.lazy.compactMap({ mediaByStem[$0] }).first else { continue }
                    let name = src.lastPathComponent
                    let dest = mediaDir.appendingPathComponent(name)
                    if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: src, to: dest) }
                    context.insert(TweetMedia(profileId: profileId, tweetId: t.id, mediaId: m.id,
                                              kind: m.kind, fileName: name,
                                              width: m.width, height: m.height))
                    n += 1
                }
                result.mediaCopied += n
                return n
            }

            for t in pending {
                // 先从 X 拉过、后导官方存档的自己的推（粟粟 2026-09-24）：存档信息更全，用它补全；
                // 书签、赞、原帖链接这些标记不动。认法：自己的推（没作者）且带 sourceURL（只有拉取包会写）
                if let row = existingById[t.id], row.sourceURL != nil, row.authorScreenName == nil,
                   !seenInThisRun.contains(t.id) {
                    seenInThisRun.insert(t.id)
                    // 在应用里改过的正文不拿存档原文盖回去
                    if row.editedAt == nil {
                        row.text = t.text
                        row.hashtagsJoined = t.hashtags.joined(separator: " ")
                    }
                    row.createdAt = t.createdAt
                    row.favoriteCount = max(row.favoriteCount, t.favoriteCount)
                    row.retweetCount = max(row.retweetCount, t.retweetCount)
                    row.inReplyToTweetId = t.inReplyToTweetId
                    row.inReplyToScreenName = t.inReplyToScreenName
                    row.mentionsJoined = t.mentions.joined(separator: " ")
                    row.urlsJoined = t.urls.joined(separator: " ")
                    row.retweetedScreenName = t.retweetedScreenName ?? row.retweetedScreenName
                    row.retweetedName = t.retweetedName ?? row.retweetedName
                    // 拉取时一张图都没下到的才补存档的图——已经有的不重复建
                    if row.mediaCount == 0 { row.mediaCount = adoptMedia(t) }
                    result.tweetsSkipped += 1
                    continue
                }
                guard !existingIds.contains(t.id), !seenInThisRun.contains(t.id) else {
                    result.tweetsSkipped += 1
                    continue
                }
                seenInThisRun.insert(t.id)
                let entry = TweetEntry(
                    profileId: profileId, tweetId: t.id, text: t.text, createdAt: t.createdAt,
                    favoriteCount: t.favoriteCount, retweetCount: t.retweetCount,
                    inReplyToTweetId: t.inReplyToTweetId, inReplyToScreenName: t.inReplyToScreenName,
                    hashtagsJoined: t.hashtags.joined(separator: " "),
                    mentionsJoined: t.mentions.joined(separator: " "),
                    urlsJoined: t.urls.joined(separator: " "),
                    mediaCount: t.media.count)
                entry.accountId = tweetOwner
                entry.retweetedScreenName = t.retweetedScreenName
                entry.retweetedName = t.retweetedName
                context.insert(entry)
                result.tweetsImported += 1
                _ = adoptMedia(t)
            }
            // 显式 save：规则写明主 ctx 不 save 会让后台 ctx 读到旧值
            try context.save()
            pending.removeAll(keepingCapacity: true)
        }

        let parts = TwitterArchiveReader.tweetPartFiles(in: dataDir)
        // 先打一发 0：保证 .parse 这个阶段一定出现在序列里（哪怕存档一条推都没有），
        // UI 的阶段文案才不会跳过中间直接从「解包」蹦到「完成」
        onProgress?(.parse, 0)
        func reportParse(_ partsDone: Double) {
            onProgress?(.parse, min(1, partsDone / Double(max(parts.count, 1))))
        }

        // 长推全文（note-tweet.js）：tweets.js 里同一条只有截断的前半截。没有这个文件就算了
        let notes = (try? Data(contentsOf: dataDir.appendingPathComponent("note-tweet.js")))
            .flatMap { try? TwitterArchiveReader.parseNoteTweets($0) } ?? []

        for (idx, part) in parts.enumerated() {
            var parsed = try TwitterArchiveReader.parseTweets(Data(contentsOf: part))
            if !notes.isEmpty {
                let full = TwitterArchiveReader.matchNotes(notes, to: parsed.map { ($0.id, $0.text, $0.createdAt) })
                for i in parsed.indices { if let text = full[parsed[i].id] { parsed[i].text = text } }
            }
            var doneInPart = 0
            for t in parsed {
                pending.append(t)
                if pending.count >= batchSize {
                    try flush()
                    doneInPart += batchSize
                    reportParse(Double(idx) + Double(doneInPart) / Double(max(parsed.count, 1)))
                }
            }
            try flush()
            reportParse(Double(idx + 1))
        }
        // 满格收尾：不给这一下，进度条会永远停在差一点的位置
        onProgress?(.finish, 1)
        return result
    }
}
