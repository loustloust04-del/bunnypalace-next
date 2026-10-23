import Foundation
import Observation
import SwiftData

/// page2「推特」面板的状态机。视图只读它，不自己查库。
@MainActor
@Observable
final class TwitterPanelViewModel {

    enum Filter: Equatable {
        case all
        /// 本站：这层所有账号自己发的
        case local
        /// 关注：当前账号 + 它关注的号
        case following
        case withMedia
        case search(String)
        /// 个人主页的三个 tab
        case posts
        case replies
        case liked
        /// 书签页
        case bookmarks
        /// 某个书签文件夹
        case bookmarkFolder(String)
    }

    private(set) var tweets: [TweetEntry] = []
    /// 本楼层所有账号（我的 + AI 的），按 id。每行显示发推的那个号，不是当前账号
    private(set) var accountsById: [String: TwitterArchiveAccount] = [:]
    func author(of tweet: TweetEntry) -> TwitterArchiveAccount? { accountsById[tweet.accountId] }

    /// 主页在看哪个号。nil = 自己（当前账号）
    private var viewedAccountId: String?
    /// 换主页要看的号。之后 `apply` 主页 tab 就按它筛。
    func viewAccount(_ accountId: String?) {
        viewedAccountId = accountId == account?.accountId ? nil : accountId
    }
    var viewedAccount: TwitterArchiveAccount? { viewedAccountId.flatMap { accountsById[$0] } ?? account }
    var isViewingOwnAccount: Bool { viewedAccountId == nil }
    /// 主页类筛选（帖子/回复/媒体/喜欢）和头部统计按这个号
    private var profileScope: String? { viewedAccount?.accountId ?? scope }
    private(set) var account: TwitterArchiveAccount?
    /// 按哪个账号筛。楼层里还没有账号（只自己发过推）时不分账号
    private var scope: String? { account?.accountId }
    /// 在看书签（全部或某个文件夹）。书签页按加书签的时间排，游标也跟它走
    var isShowingBookmarks: Bool {
        if case .bookmarkFolder = filter { return true }
        return filter == .bookmarks
    }
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var filter: Filter = .all

    /// 没有任何推文 = 还没导过存档，显示导入引导。
    var isEmpty: Bool { tweets.isEmpty && (filter == .all || filter == .local) }

    private let context: ModelContext
    private let profileId: String
    private let pageSize: Int

    init(context: ModelContext, profileId: String, pageSize: Int = 50) {
        self.context = context
        self.profileId = profileId
        self.pageSize = pageSize
    }

    /// 本楼层推文总数。头部要显示全量，不能被 pageSize 截断。
    private(set) var totalCount = 0
    /// 存档的时间跨度（最早 ~ 最晚）。没有推文时为 nil。
    private(set) var span: (earliest: Date, latest: Date)?

    /// 当前已加载这些推文的媒体，按 tweetId 分组。
    /// 跟着页一起取，不在列表行里逐条查库——LazyVStack 里逐行 fetch 会把滚动拖垮。
    func media(for tweetId: String) -> [TweetMedia] { mediaByTweetId[tweetId] ?? [] }

    private var mediaByTweetId: [String: [TweetMedia]] = [:]

    /// 引用推文里被引用的那条。跟媒体一样按页一次取回，不在行里逐条查。
    func quoted(for tweet: TweetEntry) -> TweetEntry? {
        tweet.quotedTweetId.flatMap { quotedById[$0] }
    }

    private var quotedById: [String: TweetEntry] = [:]

    /// 回复数（直接回复），按页一起取。转帖那行显示原推的数。
    func replyCount(for tweet: TweetEntry) -> Int { replyCountById[tweet.repostOfTweetId ?? tweet.tweetId] ?? 0 }

    private var replyCountById: [String: Int] = [:]

    /// 重新从第一页加载（切楼层、导完存档、换筛选都走它）。
    func reload() { load(reset: true) }

    /// 往下翻一页。拉到底或正在加载时是安全的空操作。
    func loadMore() {
        guard hasMore, !isLoading else { return }
        load(reset: false)
    }

    /// 删一条（软删），并从当前列表里摘掉——不整页重载，免得滚动位置跳回顶上。
    func remove(_ tweet: TweetEntry) {
        guard (try? TwitterTweetActions.remove(tweet, context: context)) != nil else { return }
        tweets.removeAll { $0.tweetId == tweet.tweetId }
        totalCount = max(0, totalCount - 1)
    }

    /// 重新取账号面。编辑资料时可能是新建的账号，旧的 nil 缓存要刷掉。
    func refreshAccount() {
        account = TwitterAccounts.active(profileId: profileId, context: context)
    }

    /// 换筛选。**必须从第一页重来**——沿用上一次的游标会拿到错位的结果。
    func apply(_ newFilter: Filter) {
        filter = Self.normalized(newFilter)
        load(reset: true)
    }

    /// 空白搜索词等于没筛选：不然用户清空输入框会看到空列表，像是数据没了。
    private static func normalized(_ f: Filter) -> Filter {
        if case .search(let k) = f,
           k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .all }
        return f
    }

    private func load(reset: Bool) {
        isLoading = true
        defer { isLoading = false }

        if reset {
            // 账号每次重置都重认：可能刚切了账号、刚导了新账号、刚新建了空白账号。
            // 先把多账号之前的老推文归给当前账号，再按账号筛
            try? TwitterAccounts.adoptOrphans(profileId: profileId, context: context)
            account = TwitterAccounts.active(profileId: profileId, context: context)
            accountsById = Dictionary(TwitterAccounts.all(profileId: profileId, context: context).map { ($0.accountId, $0) },
                                      uniquingKeysWith: { a, _ in a })
            if let v = viewedAccountId, accountsById[v] == nil { viewedAccountId = nil }
            tweets = []
            mediaByTweetId = [:]
            quotedById = [:]
            replyCountById = [:]
            hasMore = true
            // 总数和跨度不随翻页变，只在重置时算一次
            totalCount = (try? context.fetchCount(TwitterQueries.countAll(profileId: profileId, account: profileScope))) ?? 0
            let oldest = try? context.fetch(TwitterQueries.edge(profileId: profileId, account: profileScope, newest: false)).first
            let newest = try? context.fetch(TwitterQueries.edge(profileId: profileId, account: profileScope, newest: true)).first
            if let oldest, let newest {
                span = (oldest.createdAt, newest.createdAt)
            } else {
                span = nil
            }
        }
        // 游标取当前最后一条的时间；reset 时没有游标 = 从头拉
        // 书签页按加书签的时间排，游标也跟着它走
        let cursor = reset ? nil : (isShowingBookmarks ? tweets.last?.bookmarkedAt : tweets.last?.createdAt)

        let descriptor: FetchDescriptor<TweetEntry>
        let paginated: Bool
        switch filter {
        case .all:
            descriptor = TwitterQueries.timeline(profileId: profileId, account: scope, before: cursor, limit: pageSize)
            paginated = true
        case .withMedia:
            descriptor = TwitterQueries.withMedia(profileId: profileId, account: profileScope, before: cursor, limit: pageSize)
            paginated = true
        case .local:
            descriptor = TwitterQueries.localTimeline(profileId: profileId, before: cursor, limit: pageSize)
            paginated = true
        case .following:
            if let account {
                let ids = [account.accountId] + TwitterFollows.followees(of: account, context: context)
                descriptor = TwitterQueries.homeTimeline(profileId: profileId, accounts: ids, before: cursor, limit: pageSize)
            } else {
                // 还没有账号（只自己发过推）：跟本站一样
                descriptor = TwitterQueries.localTimeline(profileId: profileId, before: cursor, limit: pageSize)
            }
            paginated = true
        case .posts:
            descriptor = TwitterQueries.posts(profileId: profileId, account: profileScope, before: cursor, limit: pageSize)
            paginated = true
        case .replies:
            descriptor = TwitterQueries.repliesOnly(profileId: profileId, account: profileScope, before: cursor, limit: pageSize)
            paginated = true
        case .bookmarkFolder(let folder):
            descriptor = TwitterQueries.bookmarks(profileId: profileId, account: scope, folder: folder,
                                                  before: cursor, limit: pageSize)
            paginated = true
        case .bookmarks:
            descriptor = TwitterQueries.bookmarks(profileId: profileId, account: scope, before: cursor, limit: pageSize)
            paginated = true
        case .liked:
            descriptor = TwitterQueries.liked(profileId: profileId, account: profileScope, before: cursor, limit: pageSize)
            paginated = true
        case .search(let keyword):
            // 规则：搜索结果不截断，一次给全，所以没有下一页
            descriptor = TwitterQueries.search(profileId: profileId, account: scope, keyword: keyword)
            paginated = false
        }

        let page = (try? context.fetch(descriptor)) ?? []
        tweets += page

        // 这一页的媒体一次取回，按 tweetId 归组
        let ids = page.map(\.tweetId)
        if !ids.isEmpty {
            let rows = (try? context.fetch(TwitterQueries.media(profileId: profileId, tweetIds: ids))) ?? []
            for r in rows { mediaByTweetId[r.tweetId, default: []].append(r) }
        }
        let countIds = page.map { $0.repostOfTweetId ?? $0.tweetId }
        replyCountById.merge(TwitterThread.replyCounts(for: countIds, profileId: profileId, context: context)) { _, new in new }
        let quotedIds = page.compactMap(\.quotedTweetId).filter { quotedById[$0] == nil }
        if !quotedIds.isEmpty {
            let rows = (try? context.fetch(TwitterQueries.tweets(profileId: profileId, ids: quotedIds))) ?? []
            for r in rows { quotedById[r.tweetId] = r }
            // 被引用那条的图也要有，引用卡片里要显示
            let qm = (try? context.fetch(TwitterQueries.media(profileId: profileId, tweetIds: rows.map(\.tweetId)))) ?? []
            // 被引用那条如果本页也有，媒体已经取过了，别重复塞
            for (id, rows) in Dictionary(grouping: qm, by: \.tweetId) where mediaByTweetId[id] == nil {
                mediaByTweetId[id] = rows
            }
        }
        // 不足一页 = 到底了。搜索本来就一次给全，直接落 false
        hasMore = paginated && page.count == pageSize
    }
}
