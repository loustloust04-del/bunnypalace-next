import Foundation
import SwiftData

/// 关注（纯本地，一个楼层就是一个站）。「关注」时间线 = 当前账号 + 它关注的号。
enum TwitterFollows {

    private static func rows(_ followee: TwitterArchiveAccount, by follower: TwitterArchiveAccount,
                             context: ModelContext) -> [TwitterFollow] {
        let pid = follower.profileId, from = follower.accountId, to = followee.accountId
        return (try? context.fetch(FetchDescriptor<TwitterFollow>(predicate: #Predicate {
            $0.profileId == pid && $0.followerAccountId == from && $0.followeeAccountId == to
        }))) ?? []
    }

    /// 关注。重复关注不重复记；不能关注自己。
    static func follow(_ followee: TwitterArchiveAccount, by follower: TwitterArchiveAccount, context: ModelContext) throws {
        guard followee.accountId != follower.accountId,
              rows(followee, by: follower, context: context).isEmpty else { return }
        context.insert(TwitterFollow(profileId: follower.profileId, followerAccountId: follower.accountId,
                                     followeeAccountId: followee.accountId))
        try context.save()
    }

    static func unfollow(_ followee: TwitterArchiveAccount, by follower: TwitterArchiveAccount, context: ModelContext) throws {
        for r in rows(followee, by: follower, context: context) { context.delete(r) }
        try context.save()
    }

    static func isFollowing(_ followee: TwitterArchiveAccount, by follower: TwitterArchiveAccount, context: ModelContext) -> Bool {
        !rows(followee, by: follower, context: context).isEmpty
    }

    /// 这个号关注的所有号的 accountId。
    static func followees(of follower: TwitterArchiveAccount, context: ModelContext) -> [String] {
        let pid = follower.profileId, from = follower.accountId
        let list = (try? context.fetch(FetchDescriptor<TwitterFollow>(predicate: #Predicate {
            $0.profileId == pid && $0.followerAccountId == from
        }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return list.map(\.followeeAccountId)
    }

    /// 关注这个号的所有号的 accountId（主页的「关注者」）。
    static func followers(of followee: TwitterArchiveAccount, context: ModelContext) -> [String] {
        let pid = followee.profileId, to = followee.accountId
        let list = (try? context.fetch(FetchDescriptor<TwitterFollow>(predicate: #Predicate {
            $0.profileId == pid && $0.followeeAccountId == to
        }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return list.map(\.followerAccountId)
    }
}
