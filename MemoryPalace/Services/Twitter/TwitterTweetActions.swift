import Foundation
import SwiftData

/// 推文上的动作：点赞、删除。回复走 `TwitterComposer.post(replyingTo:)`。
enum TwitterTweetActions {

    /// 点赞 / 取消赞。存档里的赞数是别人给的，自己点一下在上面 ±1，跟推特一样。
    static func toggleLike(_ tweet: TweetEntry, context: ModelContext) throws {
        tweet.likedByMe.toggle()
        tweet.favoriteCount = max(0, tweet.favoriteCount + (tweet.likedByMe ? 1 : -1))
        try context.save()
    }

    /// 转帖 / 撤销转帖。转了返回新生成的那一行，撤销返回 nil。
    ///
    /// 转帖是时间线上**新的一行**（排在最上面、带「已转帖」头），指回原推；原推记 `retweetedByMe`、转推数 +1。
    /// 在转帖那一行上点，作用到它指向的原推。媒体行指向同一批文件，不复制图。
    @discardableResult
    static func toggleRepost(_ tweet: TweetEntry, context: ModelContext) throws -> TweetEntry? {
        let pid = tweet.profileId
        let original: TweetEntry
        if let oid = tweet.repostOfTweetId,
           let o = try context.fetch(TwitterQueries.existing(profileId: pid, tweetId: oid)).first {
            original = o
        } else {
            original = tweet
        }
        let oid = original.tweetId

        if original.retweetedByMe {
            let copies = try context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
                $0.profileId == pid && $0.repostOfTweetId == oid
            }))
            let copyIds = copies.map(\.tweetId)
            for m in try context.fetch(TwitterQueries.media(profileId: pid, tweetIds: copyIds)) { context.delete(m) }
            copies.forEach(context.delete)   // 转帖行是本地生成的，撤销就真删，不留软删的壳
            original.retweetedByMe = false
            original.retweetCount = max(0, original.retweetCount - 1)
            try context.save()
            return nil
        }

        let me = TwitterAccounts.active(profileId: pid, context: context)
        let author = original.originalAuthorHandle == nil ? me : nil
        let copy = TweetEntry(profileId: pid, tweetId: TwitterComposer.localIdPrefix + "rt-" + UUID().uuidString,
                              text: original.text, createdAt: Date(),
                              hashtagsJoined: original.hashtagsJoined, mentionsJoined: original.mentionsJoined,
                              urlsJoined: original.urlsJoined, mediaCount: original.mediaCount)
        copy.repostOfTweetId = oid
        copy.retweetedScreenName = original.originalAuthorHandle ?? author?.screenName
        copy.retweetedName = original.originalAuthorName ?? author?.displayName
        copy.quotedTweetId = original.quotedTweetId
        copy.accountId = me?.accountId ?? original.accountId   // 转帖出现在当前账号的时间线上
        context.insert(copy)
        for m in try context.fetch(TwitterQueries.media(profileId: pid, tweetIds: [oid])) {
            context.insert(TweetMedia(profileId: pid, tweetId: copy.tweetId, mediaId: m.mediaId, kind: m.kind,
                                      fileName: m.fileName, width: m.width, height: m.height))
        }
        original.retweetedByMe = true
        original.retweetCount += 1
        try context.save()
        return copy
    }

    /// 以某个号转帖（AI 用）。已经转过返回 nil。不碰 `retweetedByMe`——那是粟粟自己的转帖标记。
    @discardableResult
    static func repost(_ tweet: TweetEntry, as actor: TwitterArchiveAccount, context: ModelContext) throws -> TweetEntry? {
        let pid = tweet.profileId, aid = actor.accountId
        let oid = tweet.repostOfTweetId ?? tweet.tweetId
        let already = try context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.profileId == pid && $0.accountId == aid && $0.repostOfTweetId == oid
        }))
        guard already.isEmpty,
              let original = try context.fetch(TwitterQueries.existing(profileId: pid, tweetId: oid)).first else { return nil }
        let owner = TwitterAccounts.all(profileId: pid, context: context).first { $0.accountId == original.accountId }
        let copy = TweetEntry(profileId: pid, tweetId: TwitterComposer.localIdPrefix + "rt-" + UUID().uuidString,
                              text: original.text, createdAt: Date(),
                              hashtagsJoined: original.hashtagsJoined, mentionsJoined: original.mentionsJoined,
                              urlsJoined: original.urlsJoined, mediaCount: original.mediaCount)
        copy.repostOfTweetId = oid
        copy.retweetedScreenName = original.originalAuthorHandle ?? owner?.screenName
        copy.retweetedName = original.originalAuthorName ?? owner?.displayName
        copy.quotedTweetId = original.quotedTweetId
        copy.accountId = aid
        context.insert(copy)
        for m in try context.fetch(TwitterQueries.media(profileId: pid, tweetIds: [oid])) {
            context.insert(TweetMedia(profileId: pid, tweetId: copy.tweetId, mediaId: m.mediaId, kind: m.kind,
                                      fileName: m.fileName, width: m.width, height: m.height))
        }
        original.retweetCount += 1
        try context.save()
        return copy
    }

    /// 加书签 / 取消书签。存档不导出书签，这里只收应用里点的。
    static func toggleBookmark(_ tweet: TweetEntry, context: ModelContext) throws {
        tweet.bookmarkedAt = tweet.bookmarkedAt == nil ? Date() : nil
        try context.save()
    }

    /// 删除。**软删**（`isRemoved`），行留在库里：
    /// 重新导入同一份存档时导入器按 id 查重会撞上这一行而跳过，删掉的推就不会复活。
    static func remove(_ tweet: TweetEntry, context: ModelContext) throws {
        tweet.isRemoved = true
        try context.save()
    }

    // MARK: - 修改（粟粟 2026-09-27）

    /// 能不能改：自己号发的原创推。别人的推（书签/赞拉下来的）、转推、转帖行、AI 的号发的都不行。
    static func canEdit(_ tweet: TweetEntry, context: ModelContext) -> Bool {
        let owner = tweet.accountId.isEmpty ? nil
            : TwitterAccounts.all(profileId: tweet.profileId, context: context).first { $0.accountId == tweet.accountId }
        return canEdit(tweet, owner: owner)
    }

    /// 不查库的版本：时间线每行都要判断，发推的号已经在手上了。
    static func canEdit(_ tweet: TweetEntry, owner: TwitterArchiveAccount?) -> Bool {
        !tweet.isRemoved && tweet.authorScreenName == nil && tweet.retweetedScreenName == nil
            && tweet.repostOfTweetId == nil && owner?.ownerKind != TwitterAccounts.ownerAI
    }

    /// 改正文。话题标签跟着重算，时间线上的转帖行也换成新字；记下修改时间（显示「已编辑」）。
    static func edit(_ tweet: TweetEntry, text: String, context: ModelContext) throws {
        guard canEdit(tweet, context: context) else { throw TwitterEditError.notEditable }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || tweet.mediaCount > 0 else { throw TwitterComposerError.emptyText }
        tweet.text = body
        tweet.hashtagsJoined = TwitterComposer.hashtags(in: body).joined(separator: " ")
        tweet.editedAt = Date()
        let pid = tweet.profileId, oid: String? = tweet.tweetId
        for copy in try context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.profileId == pid && $0.repostOfTweetId == oid
        })) {
            copy.text = body
            copy.hashtagsJoined = tweet.hashtagsJoined
        }
        try context.save()
    }
}

enum TwitterEditError: Error, Equatable, LocalizedError {
    case notEditable
    var errorDescription: String? { "这条不能改（只有自己号发的原创推能改）" }
}
