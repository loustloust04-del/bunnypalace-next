import Foundation
import SwiftData

/// 推特存档的取数口。**所有 fetch 一律从这里出**，保证两条项目硬规则不被绕过
/// （`.claude/rules/swiftdata.md`）：
/// 自己的时间线类查询（时间线/有图/帖子/回复/总数/跨度）只看 `authorScreenName == nil`——
/// 从 X 拉下来的书签和赞是别人的推，只在书签页、「喜欢」和搜索里出现。
/// ① 每个 fetch 都带 `profileId` predicate——跨楼层隔离；推文类的再带可选的 `account`（一楼层多账号，nil = 不分账号）；
/// ② 关键词匹配落进 SQLite predicate，不做内存 filter——库里 20 万+ 行，内存 filter 会拖垮。
enum TwitterQueries {

    private static func newestFirst(
        _ predicate: Predicate<TweetEntry>
    ) -> FetchDescriptor<TweetEntry> {
        FetchDescriptor<TweetEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }

    /// 时间线：按时间倒序，**游标分页**。`before` 传上一页最后一条的 `createdAt`。
    ///
    /// 用游标而不是 `fetchOffset`，两个理由：
    /// ① 偏移量分页越翻越慢（每次都要跳过前 N 行），一份重度存档几万条，翻到后面肉眼可感；
    /// ② `fetchOffset` 是 store 特性——生产的 SQLite store 认（`SidebarView` 在用），
    ///    但**内存 store 忽略它**（实测：offset=1 仍返回头两条），于是分页逻辑测不到。
    ///    游标是 predicate，两种 store 行为一致，测试能真验住。
    static func timeline(profileId: String, account: String? = nil, before: Date? = nil, limit: Int = 50) -> FetchDescriptor<TweetEntry> {
        // 不把 optional 塞进 #Predicate：用哨兵值让表达式保持简单
        let cutoff = before ?? Date.distantFuture
        let acc = account ?? "", anyAccount = account == nil
        var d = newestFirst(#Predicate {
            $0.profileId == profileId && (anyAccount || $0.accountId == acc) && $0.authorScreenName == nil && !$0.isRemoved && $0.createdAt < cutoff
        })
        d.fetchLimit = limit
        return d
    }

    /// 只看有媒体的。靠冗余的 `mediaCount` 走 predicate，不用回表查 TweetMedia。
    /// 同样游标分页——重度存档的有图推文也可能上万条。`limit` 传 nil = 不限量。
    static func withMedia(profileId: String, account: String? = nil, before: Date? = nil, limit: Int? = nil) -> FetchDescriptor<TweetEntry> {
        let cutoff = before ?? Date.distantFuture
        let acc = account ?? "", anyAccount = account == nil
        var d = newestFirst(#Predicate {
            $0.profileId == profileId && (anyAccount || $0.accountId == acc) && $0.authorScreenName == nil && $0.mediaCount > 0 && !$0.isRemoved && $0.createdAt < cutoff
        })
        if let limit { d.fetchLimit = limit }
        return d
    }

    /// 一页推文的媒体，一次取回。**不要在列表行里逐条查**——
    /// LazyVStack 里每行一次 fetch 会把滚动拖垮。
    static func media(profileId: String, tweetIds: [String]) -> FetchDescriptor<TweetMedia> {
        FetchDescriptor<TweetMedia>(
            predicate: #Predicate { $0.profileId == profileId && tweetIds.contains($0.tweetId) }
        )
    }

    /// 本楼层推文总数用的描述符（配 `fetchCount`，不拉行）。
    static func countAll(profileId: String, account: String? = nil) -> FetchDescriptor<TweetEntry> {
        let acc = account ?? "", anyAccount = account == nil
        return FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.profileId == profileId && (anyAccount || $0.accountId == acc) && $0.authorScreenName == nil && !$0.isRemoved
        })
    }

    /// 时间跨度的两个端点，各取一条。
    static func edge(profileId: String, account: String? = nil, newest: Bool) -> FetchDescriptor<TweetEntry> {
        let acc = account ?? "", anyAccount = account == nil
        var d = FetchDescriptor<TweetEntry>(
            predicate: #Predicate { $0.profileId == profileId && (anyAccount || $0.accountId == acc) && $0.authorScreenName == nil && !$0.isRemoved },
            sortBy: [SortDescriptor(\.createdAt, order: newest ? .reverse : .forward)]
        )
        d.fetchLimit = 1
        return d
    }

    /// 本楼层的所有账号，按导入先后。取「当前账号」走 `TwitterAccounts.active`，别直接 `.first`。
    static func accounts(profileId: String) -> FetchDescriptor<TwitterArchiveAccount> {
        FetchDescriptor<TwitterArchiveAccount>(
            predicate: #Predicate { $0.profileId == profileId },
            sortBy: [SortDescriptor(\.importedAt, order: .forward)]
        )
    }

    /// 关键词搜索（正文 + 话题标签）。
    /// **不加 fetchLimit**：规则写明搜索结果不截断，粟粟要完整结果。
    static func search(profileId: String, account: String? = nil, keyword: String) -> FetchDescriptor<TweetEntry> {
        let acc = account ?? "", anyAccount = account == nil
        return newestFirst(#Predicate {
            $0.profileId == profileId && (anyAccount || $0.accountId == acc) && !$0.isRemoved
                && ($0.text.localizedStandardContains(keyword)
                    || $0.hashtagsJoined.localizedStandardContains(keyword))
        })
    }

    /// 全局搜索「推特」标签的一页：每个词都要命中正文或话题标签，
    /// 时间范围 [from, to]，只按时间倒序；「时间 + id」游标翻页（同一秒的推文靠 id 分先后，不重不漏）。
    /// 口径同 `search`：不分账号、带别人的推（书签 / 赞）
    static func searchPage(profileId: String, words: [String], from: Date, to: Date,
                           after cursor: TweetSearchCursor?, limit: Int) -> FetchDescriptor<TweetEntry> {
        var d = FetchDescriptor<TweetEntry>(
            predicate: searchPredicate(profileId: profileId, words: words, from: from, to: to,
                                       beforeDate: cursor?.date ?? .distantFuture, beforeId: cursor?.tweetId ?? ""),
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.tweetId, order: .reverse)]
        )
        d.fetchLimit = limit
        return d
    }

    /// 同一组条件的总数（配 `fetchCount`，不拉行）
    static func searchCount(profileId: String, words: [String], from: Date, to: Date) -> FetchDescriptor<TweetEntry> {
        FetchDescriptor<TweetEntry>(predicate: searchPredicate(profileId: profileId, words: words, from: from, to: to,
                                                               beforeDate: .distantFuture, beforeId: ""))
    }

    /// 一个 #Predicate 塞下全部条件会让编译器类型推断超时，拆成小块再用 evaluate 串起来；每个词一块
    private static func searchPredicate(profileId: String, words: [String], from: Date, to: Date,
                                        beforeDate: Date, beforeId: String) -> Predicate<TweetEntry> {
        let scope = #Predicate<TweetEntry> {
            $0.profileId == profileId && !$0.isRemoved && $0.createdAt >= from && $0.createdAt <= to
        }
        let page = #Predicate<TweetEntry> {
            $0.createdAt < beforeDate || ($0.createdAt == beforeDate && $0.tweetId < beforeId)
        }
        var combined = #Predicate<TweetEntry> { scope.evaluate($0) && page.evaluate($0) }
        for word in words {
            let hit = #Predicate<TweetEntry> {
                $0.text.localizedStandardContains(word) || $0.hashtagsJoined.localizedStandardContains(word)
            }
            let previous = combined
            combined = #Predicate<TweetEntry> { previous.evaluate($0) && hit.evaluate($0) }
        }
        return combined
    }

    /// 查重用：同楼层同 tweetId 是否已存在。
    /// 导入前必须查——SwiftData 的 `insert` 撞 id 不报错而是**改写全部属性**。
    /// 故意不加 fetchLimit：真出现重复时要能看见，不被 limit 掩盖。
    static func existing(profileId: String, tweetId: String) -> FetchDescriptor<TweetEntry> {
        FetchDescriptor<TweetEntry>(
            predicate: #Predicate { $0.profileId == profileId && $0.tweetId == tweetId }
        )
    }

    /// 一条推的回复串（同楼层、未删），按时间**正序**——串是从上往下读的。
    static func replies(profileId: String, to tweetId: String) -> FetchDescriptor<TweetEntry> {
        let parentId: String? = tweetId
        return FetchDescriptor<TweetEntry>(
            predicate: #Predicate {
                $0.profileId == profileId && !$0.isRemoved && $0.inReplyToTweetId == parentId
            },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
    }

    /// 个人主页「帖子」：不是回复的。游标分页同 `timeline`。
    static func posts(profileId: String, account: String? = nil, before: Date? = nil, limit: Int = 50) -> FetchDescriptor<TweetEntry> {
        let cutoff = before ?? Date.distantFuture
        let acc = account ?? "", anyAccount = account == nil
        var d = newestFirst(#Predicate {
            $0.profileId == profileId && (anyAccount || $0.accountId == acc) && $0.authorScreenName == nil && !$0.isRemoved && $0.createdAt < cutoff
                && $0.inReplyToTweetId == nil
        })
        d.fetchLimit = limit
        return d
    }

    /// 个人主页「回复」：回复别人或串自己的。
    static func repliesOnly(profileId: String, account: String? = nil, before: Date? = nil, limit: Int = 50) -> FetchDescriptor<TweetEntry> {
        let cutoff = before ?? Date.distantFuture
        let acc = account ?? "", anyAccount = account == nil
        var d = newestFirst(#Predicate {
            $0.profileId == profileId && (anyAccount || $0.accountId == acc) && $0.authorScreenName == nil && !$0.isRemoved && $0.createdAt < cutoff
                && $0.inReplyToTweetId != nil
        })
        d.fetchLimit = limit
        return d
    }

    /// 个人主页「喜欢」：自己在应用里点过赞的。
    static func liked(profileId: String, account: String? = nil, before: Date? = nil, limit: Int = 50) -> FetchDescriptor<TweetEntry> {
        let cutoff = before ?? Date.distantFuture
        let acc = account ?? "", anyAccount = account == nil
        var d = newestFirst(#Predicate {
            $0.profileId == profileId && (anyAccount || $0.accountId == acc) && !$0.isRemoved && $0.createdAt < cutoff && $0.likedByMe
        })
        d.fetchLimit = limit
        return d
    }

    /// 按 id 批量取（引用卡片用）。未删的才算。
    static func tweets(profileId: String, ids: [String]) -> FetchDescriptor<TweetEntry> {
        FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.profileId == profileId && !$0.isRemoved && ids.contains($0.tweetId)
        })
    }

    /// 书签页：按**加书签的时间**倒序，游标也按它走（推文本身多老不重要）。
    /// `folder` 给了就只看那个书签文件夹。
    static func bookmarks(profileId: String, account: String? = nil, folder: String? = nil,
                          before: Date? = nil, limit: Int = 50) -> FetchDescriptor<TweetEntry> {
        let cutoff = before ?? Date.distantFuture
        let acc = account ?? "", anyAccount = account == nil
        let tag = "|\(folder ?? "")|", anyFolder = folder == nil
        let farPast = Date.distantPast
        var d = FetchDescriptor<TweetEntry>(
            predicate: #Predicate {
                $0.profileId == profileId && (anyAccount || $0.accountId == acc) && !$0.isRemoved
                    && ($0.bookmarkedAt ?? farPast) > farPast && ($0.bookmarkedAt ?? farPast) < cutoff
                    && (anyFolder || $0.bookmarkFolderIds.contains(tag))
            },
            sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]
        )
        d.fetchLimit = limit
        return d
    }

    /// 本楼层某账号的书签文件夹，按 X 上的顺序。
    static func bookmarkFolders(profileId: String, account: String) -> FetchDescriptor<TwitterBookmarkFolder> {
        FetchDescriptor<TwitterBookmarkFolder>(
            predicate: #Predicate { $0.profileId == profileId && $0.accountId == account },
            sortBy: [SortDescriptor(\.order, order: .forward)]
        )
    }

    /// 「本站」：这层所有账号自己发的（别人的推——书签、赞里拉来的——不算），新的在前。游标分页。
    static func localTimeline(profileId: String, before: Date? = nil, limit: Int = 50) -> FetchDescriptor<TweetEntry> {
        let cutoff = before ?? Date.distantFuture
        var d = newestFirst(#Predicate {
            $0.profileId == profileId && $0.authorScreenName == nil && !$0.isRemoved && $0.createdAt < cutoff
        })
        d.fetchLimit = limit
        return d
    }

    /// 「关注」：给定这些号（当前账号 + 它关注的）自己发的。
    static func homeTimeline(profileId: String, accounts: [String], before: Date? = nil,
                             limit: Int = 50) -> FetchDescriptor<TweetEntry> {
        let cutoff = before ?? Date.distantFuture
        var d = newestFirst(#Predicate {
            $0.profileId == profileId && accounts.contains($0.accountId) && $0.authorScreenName == nil
                && !$0.isRemoved && $0.createdAt < cutoff
        })
        d.fetchLimit = limit
        return d
    }
}
