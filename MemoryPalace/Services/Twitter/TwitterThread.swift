import Foundation
import SwiftData

/// 回复串（粟粟 2026-09-25：多层回复要「一根线串下来，每条点进去都能看见上级和下级」）。
///
/// 详情页 = 上级链（从最顶上那条一路到父推）→ 这条 → 直接回复；
/// 每条直接回复下面再挂它最早的一条回复，用线连着，更多的点进去看。推特的会话页就是这个形状。
enum TwitterThread {

    /// 从最顶上到父推，按时间正序。链断了（上级被删、或本来就不在本楼层）就停在那。
    static func ancestors(of tweet: TweetEntry, context: ModelContext, maxDepth: Int = 50) -> [TweetEntry] {
        var chain: [TweetEntry] = []
        var seen: Set<String> = [tweet.tweetId]
        var parentId = tweet.inReplyToTweetId
        while let pid = parentId, !seen.contains(pid), chain.count < maxDepth {
            seen.insert(pid)
            guard let parent = (try? context.fetch(TwitterQueries.existing(profileId: tweet.profileId, tweetId: pid)))?
                .first(where: { !$0.isRemoved }) else { break }
            chain.append(parent)
            parentId = parent.inReplyToTweetId
        }
        return chain.reversed()
    }

    /// 每条推有几条直接回复（未删的）。时间线、串里的回复图标旁边显示这个数，跟赞数一样。
    static func replyCounts(for ids: [String], profileId: String, context: ModelContext) -> [String: Int] {
        guard !ids.isEmpty else { return [:] }
        let rows = (try? context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.profileId == profileId && !$0.isRemoved
                && $0.inReplyToTweetId.flatMap { ids.contains($0) } == true
        }))) ?? []
        var out: [String: Int] = [:]
        for r in rows { if let p = r.inReplyToTweetId { out[p, default: 0] += 1 } }
        return out
    }

    struct Branch: Identifiable {
        let reply: TweetEntry
        /// 挂在下面、用线连着的那条（这条回复最早的回复）
        let firstChild: TweetEntry?
        /// 除了 firstChild 还有几条没展开
        let moreCount: Int
        var id: String { reply.tweetId }
    }

    /// 直接回复，每条带它的第一条下级。
    static func branches(under tweet: TweetEntry, context: ModelContext) -> [Branch] {
        let replies = (try? context.fetch(TwitterQueries.replies(profileId: tweet.profileId, to: tweet.tweetId))) ?? []
        return replies.map { r in
            let kids = (try? context.fetch(TwitterQueries.replies(profileId: tweet.profileId, to: r.tweetId))) ?? []
            return Branch(reply: r, firstChild: kids.first, moreCount: max(kids.count - 1, 0))
        }
    }
}
