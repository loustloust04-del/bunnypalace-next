import Foundation
import SwiftData

enum TwitterComposerError: Error, Equatable {
    case emptyText
    /// 推特一条最多四张图
    case tooManyImages
}

/// 自己发一条推。
enum TwitterComposer {
    static let localIdPrefix = "local-"

    static let maxImages = 4

    /// 发一条。`replyingTo` 给了就是回复那一条（串起来显示在详情页下面）；
    /// `quoting` 给了就是引用那一条；`images` 最多四张，写进 `mediaDir`（调用方负责先压缩）。
    ///
    /// id 走 `local-` 前缀，**不能长得像存档 id**（存档是纯数字雪花号）：
    /// 两边混进同一个命名空间的话，重新导入存档时自发推可能被当成重复而覆盖。
    @discardableResult
    static func post(text: String, images: [Data] = [], mediaDir: URL? = nil,
                     replyingTo parent: TweetEntry? = nil, quoting quoted: TweetEntry? = nil,
                     as author: TwitterArchiveAccount? = nil,
                     profileId: String, context: ModelContext) throws -> TweetEntry {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 推特可以只发图不写字
        guard !body.isEmpty || !images.isEmpty else { throw TwitterComposerError.emptyText }
        guard images.count <= maxImages else { throw TwitterComposerError.tooManyImages }

        let tweetId = localIdPrefix + UUID().uuidString

        // 先写图再动库：写盘失败时库里不留指向不存在文件的行
        var media: [TweetMedia] = []
        if !images.isEmpty {
            let dir = mediaDir ?? TwitterArchiveImporter.defaultMediaRoot()
                .appendingPathComponent(profileId, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, data) in images.enumerated() {
                let name = "\(tweetId)-\(i).jpg"
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                media.append(TweetMedia(profileId: profileId, tweetId: tweetId, mediaId: "\(i)", fileName: name))
            }
        }

        let entry = TweetEntry(
            profileId: profileId,
            tweetId: tweetId,
            text: body,
            createdAt: Date(),
            hashtagsJoined: hashtags(in: body).joined(separator: " "),
            mediaCount: media.count)
        if let parent {
            // 回存档里的转推 = 回原作者；否则回的是自己的推
            entry.inReplyToTweetId = parent.tweetId
            // 回的是谁：X 上别人的推 / 转推 → 原作者；本楼层某个号的推（比如 AI 的）→ 那个号；都没有才算自己
            let handle = parent.originalAuthorHandle
                ?? TwitterAccounts.all(profileId: profileId, context: context).first { $0.accountId == parent.accountId }?.screenName
                ?? TwitterAccounts.active(profileId: profileId, context: context)?.screenName
            entry.inReplyToScreenName = (handle?.isEmpty == false) ? handle : nil
        }
        entry.quotedTweetId = quoted?.tweetId
        // 发在当前账号名下（一楼层多账号）
        entry.accountId = author?.accountId ?? TwitterAccounts.activeId(profileId: profileId, context: context)
        context.insert(entry)
        media.forEach(context.insert)
        // 显式 save：规则写明主 ctx 不 save，后台 ctx 会读到旧值
        try context.save()
        return entry
    }

    /// 从正文里摘话题标签，落进扁平字段——不然自己发的推搜不到。
    /// 标签终止于空白或标点，中文标签常紧跟标点，所以不能只按空白切。
    static func hashtags(in text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for ch in text {
            if ch == "#" {
                current = ""
            } else if var tag = current {
                if ch.isWhitespace || (ch.isPunctuation && ch != "_") {
                    if !tag.isEmpty { found.append(tag) }
                    current = nil
                } else {
                    tag.append(ch)
                    current = tag
                }
            }
        }
        if let tail = current, !tail.isEmpty { found.append(tail) }
        return found
    }
}
