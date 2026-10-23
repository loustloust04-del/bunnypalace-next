import Foundation
import SwiftData

/// 通知箱（粟粟 2026-09-25：「被点赞回复没有通知箱」）。
///
/// 只算**本站里别的号**对「我」（当前账号）做的事：赞、回复、引用、转帖、@、关注。
/// 从 X 拉下来的书签/赞不算——那是 X 上发生的事，不是本站的动静。
/// 不另建通知表：直接从推文、赞、关注里现算，删了推通知也跟着没，不会对不上。
enum TwitterNotifications {

    enum Kind: String { case like, reply, quote, repost, mention, follow }

    struct Item: Identifiable {
        let kind: Kind
        /// 谁干的
        let actorId: String
        let date: Date
        /// 点进去看的那条：回复/引用/@ 是对方那条，赞/转帖是被赞的我那条；关注没有
        let tweet: TweetEntry?
        var id: String { "\(kind.rawValue)|\(actorId)|\(tweet?.tweetId ?? "")|\(date.timeIntervalSince1970)" }
    }

    /// 我（accountId 可以是 ""：楼层还没有账号时，自己发的推就挂在空 id 上）的通知，新的在前。
    static func items(for me: String, handle: String?, profileId: String, context: ModelContext,
                      limit: Int = 200) -> [Item] {
        var out: [Item] = []

        // 本站别的号发的推（id 都是 local- 开头；X 上拉来的不是）
        let prefix = TwitterComposer.localIdPrefix
        let others = (try? context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.profileId == profileId && !$0.isRemoved && $0.accountId != me && $0.tweetId.starts(with: prefix)
        }))) ?? []

        // 它们指向的推里，哪些是我的
        var targetIds = Set<String>()
        for t in others {
            if let p = t.inReplyToTweetId { targetIds.insert(p) }
            if let q = t.quotedTweetId { targetIds.insert(q) }
            if let r = t.repostOfTweetId { targetIds.insert(r) }
        }
        let likes = (try? context.fetch(FetchDescriptor<TwitterLike>(predicate: #Predicate {
            $0.profileId == profileId && $0.accountId != me
        }))) ?? []
        likes.forEach { targetIds.insert($0.tweetId) }
        let targets = fetchByIds(Array(targetIds), profileId: profileId, context: context)
        func mine(_ id: String?) -> TweetEntry? {
            guard let id, let t = targets[id], t.accountId == me, t.originalAuthorHandle == nil else { return nil }
            return t
        }

        let at = handle.flatMap { $0.isEmpty ? nil : "@" + $0.lowercased() }
        for t in others {
            if let r = t.repostOfTweetId {
                if let target = mine(r) { out.append(Item(kind: .repost, actorId: t.accountId, date: t.createdAt, tweet: target)) }
                continue   // 转帖那行是原推的副本，里面的 @ 不是冲我来的
            }
            if mine(t.inReplyToTweetId) != nil {
                out.append(Item(kind: .reply, actorId: t.accountId, date: t.createdAt, tweet: t))
            } else if mine(t.quotedTweetId) != nil {
                out.append(Item(kind: .quote, actorId: t.accountId, date: t.createdAt, tweet: t))
            } else if let at, t.text.lowercased().contains(at) {
                out.append(Item(kind: .mention, actorId: t.accountId, date: t.createdAt, tweet: t))
            }
        }
        for l in likes {
            if let target = mine(l.tweetId) { out.append(Item(kind: .like, actorId: l.accountId, date: l.createdAt, tweet: target)) }
        }
        let follows = (try? context.fetch(FetchDescriptor<TwitterFollow>(predicate: #Predicate {
            $0.profileId == profileId && $0.followeeAccountId == me && $0.followerAccountId != me
        }))) ?? []
        for f in follows where !me.isEmpty {
            out.append(Item(kind: .follow, actorId: f.followerAccountId, date: f.createdAt, tweet: nil))
        }

        out.sort { $0.date > $1.date }
        return Array(out.prefix(limit))
    }

    // MARK: 未读

    private static func seenKey(profileId: String, me: String) -> String { "twitter.notifSeen.\(profileId).\(me)" }

    static func lastSeen(profileId: String, me: String, defaults: UserDefaults = .standard) -> Date {
        defaults.object(forKey: seenKey(profileId: profileId, me: me)) as? Date ?? .distantPast
    }

    static func markSeen(profileId: String, me: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: seenKey(profileId: profileId, me: me))
    }

    static func unreadCount(_ items: [Item], since: Date) -> Int { items.filter { $0.date > since }.count }

    private static func fetchByIds(_ ids: [String], profileId: String, context: ModelContext) -> [String: TweetEntry] {
        guard !ids.isEmpty else { return [:] }
        let rows = (try? context.fetch(TwitterQueries.tweets(profileId: profileId, ids: ids))) ?? []
        return Dictionary(rows.map { ($0.tweetId, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
