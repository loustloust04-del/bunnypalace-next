import XCTest
import SwiftData
@testable import 记忆花园

/// 面板状态机：空态判定、游标翻页、筛选切换。
/// 视图本身不测（SwiftUI 视图单测性价比低），逻辑全压在这里。
@MainActor
final class TwitterPanelViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let floorA = "xctest-vm-a"
    private let floorB = "xctest-vm-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil; container = nil
        try super.tearDownWithError()
    }

    private func seed(_ floor: String, id: String, text: String = "正文", at: TimeInterval,
                      media: Int = 0, tags: String = "") {
        context.insert(TweetEntry(profileId: floor, tweetId: id, text: text,
                                  createdAt: Date(timeIntervalSince1970: at),
                                  hashtagsJoined: tags, mediaCount: media))
    }

    private func vm(_ floor: String, pageSize: Int = 2) -> TwitterPanelViewModel {
        TwitterPanelViewModel(context: context, profileId: floor, pageSize: pageSize)
    }

    func testStartsEmptyWhenNothingImported() {
        let m = vm(floorA)
        m.reload()
        XCTAssertTrue(m.isEmpty, "没有任何推文时要显示导入引导")
        XCTAssertTrue(m.tweets.isEmpty)
    }

    func testReloadLoadsFirstPageNewestFirst() {
        for i in 0..<5 { seed(floorA, id: "t\(i)", at: TimeInterval(i)) }
        let m = vm(floorA)
        m.reload()
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["t4", "t3"])
        XCTAssertTrue(m.hasMore)
    }

    func testLoadMoreAppendsNextPageWithoutDuplicating() {
        for i in 0..<5 { seed(floorA, id: "t\(i)", at: TimeInterval(i)) }
        let m = vm(floorA)
        m.reload()
        m.loadMore()
        XCTAssertEqual(m.tweets.map(\.tweetId), ["t4", "t3", "t2", "t1"])
        XCTAssertEqual(Set(m.tweets.map(\.tweetId)).count, 4, "翻页不能把上一页最后一条再吐一遍")
    }

    func testLoadMoreStopsAtTheEnd() {
        for i in 0..<3 { seed(floorA, id: "t\(i)", at: TimeInterval(i)) }
        let m = vm(floorA)
        m.reload()
        m.loadMore()          // t0 —— 不足一页
        XCTAssertEqual(m.tweets.count, 3)
        XCTAssertFalse(m.hasMore, "拉到底了要落下 hasMore")
        m.loadMore()          // 再点不能出事
        XCTAssertEqual(m.tweets.count, 3)
    }

    func testWithMediaFilterShowsOnlyMediaTweets() {
        seed(floorA, id: "plain", at: 100)
        seed(floorA, id: "pic", at: 200, media: 1)
        let m = vm(floorA)
        m.apply(.withMedia)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["pic"])
    }

    func testSearchFilterMatchesTextAndTags() {
        seed(floorA, id: "hit", text: "今天去看了海", at: 100)
        seed(floorA, id: "tagged", text: "无关", at: 200, tags: "海边")
        seed(floorA, id: "miss", text: "完全无关", at: 300)
        let m = vm(floorA)
        m.apply(.search("海"))
        XCTAssertEqual(Set(m.tweets.map(\.tweetId)), ["hit", "tagged"])
    }

    func testSearchResultsAreNotTruncatedByPageSize() {
        // 规则：搜索结果不截断，粟粟要完整结果
        for i in 0..<7 { seed(floorA, id: "s\(i)", text: "关键词 \(i)", at: TimeInterval(i)) }
        let m = vm(floorA, pageSize: 2)
        m.apply(.search("关键词"))
        XCTAssertEqual(m.tweets.count, 7)
        XCTAssertFalse(m.hasMore, "搜索是一次给全，没有下一页")
    }

    func testEmptySearchFallsBackToAll() {
        for i in 0..<3 { seed(floorA, id: "t\(i)", at: TimeInterval(i)) }
        let m = vm(floorA)
        m.apply(.search("   "))
        XCTAssertEqual(m.tweets.map(\.tweetId), ["t2", "t1"], "空搜索词等于不筛选，回到分页的全部")
    }

    func testSwitchingFilterResetsPaging() {
        for i in 0..<5 { seed(floorA, id: "t\(i)", at: TimeInterval(i), media: 1) }
        let m = vm(floorA)
        m.reload()
        m.loadMore()
        XCTAssertEqual(m.tweets.count, 4)
        m.apply(.withMedia)
        XCTAssertEqual(m.tweets.count, 2, "换筛选要从第一页重新来，不能接着上一次的游标")
    }

    func testIsIsolatedByFloor() {
        seed(floorA, id: "a", at: 100)
        seed(floorB, id: "b", at: 200)
        let m = vm(floorB)
        m.reload()
        XCTAssertEqual(m.tweets.map(\.tweetId), ["b"])
    }

    func testLoadsMediaForTheLoadedPage() {
        seed(floorA, id: "pic", at: 100, media: 2)
        context.insert(TweetMedia(profileId: floorA, tweetId: "pic", mediaId: "m1", fileName: "a.jpg"))
        context.insert(TweetMedia(profileId: floorA, tweetId: "pic", mediaId: "m2", fileName: "b.jpg"))
        let m = vm(floorA)
        m.reload()
        // 不能在 LazyVStack 里逐行查库，媒体要跟着页一起取出来
        XCTAssertEqual(m.media(for: "pic").map(\.fileName).sorted(), ["a.jpg", "b.jpg"])
    }

    func testMediaIsEmptyForTweetsWithout() {
        seed(floorA, id: "plain", at: 100)
        let m = vm(floorA)
        m.reload()
        XCTAssertTrue(m.media(for: "plain").isEmpty)
    }

    func testMediaDoesNotLeakAcrossFloors() {
        seed(floorA, id: "same", at: 100, media: 1)
        seed(floorB, id: "same", at: 100, media: 1)
        context.insert(TweetMedia(profileId: floorA, tweetId: "same", mediaId: "a", fileName: "a.jpg"))
        context.insert(TweetMedia(profileId: floorB, tweetId: "same", mediaId: "b", fileName: "b.jpg"))
        let m = vm(floorB)
        m.reload()
        XCTAssertEqual(m.media(for: "same").map(\.fileName), ["b.jpg"], "同 id 不同楼层不能串")
    }

    func testTotalCountIgnoresPagingAndFilter() {
        for i in 0..<5 { seed(floorA, id: "t\(i)", at: TimeInterval(i)) }
        let m = vm(floorA)   // pageSize = 2
        m.reload()
        XCTAssertEqual(m.tweets.count, 2, "列表是分页的")
        XCTAssertEqual(m.totalCount, 5, "但头部显示的总数要是全量，不能被 pageSize 截断")
    }

    func testSpanIsEarliestToLatest() {
        seed(floorA, id: "a", at: 100)
        seed(floorA, id: "b", at: 900)
        seed(floorA, id: "c", at: 500)
        let m = vm(floorA)
        m.reload()
        XCTAssertEqual(m.span?.earliest.timeIntervalSince1970, 100)
        XCTAssertEqual(m.span?.latest.timeIntervalSince1970, 900)
    }

    func testSpanIsNilWhenNothingImported() {
        let m = vm(floorA)
        m.reload()
        XCTAssertNil(m.span)
    }

    func testLoadsAccountWhenPresent() {
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "1",
                                             screenName: "susu_test", displayName: "禾禾"))
        seed(floorA, id: "t", at: 100)
        let m = vm(floorA)
        m.reload()
        XCTAssertEqual(m.account?.screenName, "susu_test")
    }

    func testRemoveDropsRowAndDecrementsTotal() {
        for i in 0..<3 { seed(floorA, id: "t\(i)", at: TimeInterval(i)) }
        let m = vm(floorA, pageSize: 10)
        m.reload()
        m.remove(m.tweets[0])
        XCTAssertEqual(m.tweets.map(\.tweetId), ["t1", "t0"])
        XCTAssertEqual(m.totalCount, 2)
    }

    func testRefreshAccountPicksUpNewlyCreatedAccount() throws {
        // 没导过存档、第一次编辑资料时账号是新建的，面板要能认到
        seed(floorA, id: "t", at: 1)
        let m = vm(floorA)
        m.reload()
        XCTAssertNil(m.account)
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "local",
                                             screenName: "", displayName: "禾禾"))
        m.refreshAccount()
        XCTAssertEqual(m.account?.displayName, "禾禾")
    }

    // MARK: 个人主页的 帖子 / 回复 / 喜欢

    private func seedProfileMix() {
        seed(floorA, id: "post-old", at: 1)
        seed(floorA, id: "post-new", at: 4)
        for (id, at) in [("reply-a", 2.0), ("reply-b", 3.0)] {
            seed(floorA, id: id, at: at)
        }
        let rows = try! context.fetch(TwitterQueries.timeline(profileId: floorA, limit: 100))
        for r in rows where r.tweetId.hasPrefix("reply") { r.inReplyToTweetId = "post-old" }
        for r in rows where ["post-old", "reply-b"].contains(r.tweetId) { r.likedByMe = true }
        seed(floorB, id: "b-liked", at: 9)
        try! context.save()
    }

    func testPostsFilterHidesReplies() {
        seedProfileMix()
        let m = vm(floorA, pageSize: 10)
        m.apply(.posts)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["post-new", "post-old"])
    }

    func testRepliesFilterShowsOnlyReplies() {
        seedProfileMix()
        let m = vm(floorA, pageSize: 10)
        m.apply(.replies)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["reply-b", "reply-a"])
    }

    func testLikedFilterShowsWhatIHearted() {
        seedProfileMix()
        let m = vm(floorA, pageSize: 10)
        m.apply(.liked)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["reply-b", "post-old"])
    }

    func testProfileFiltersPageWithCursor() {
        seedProfileMix()
        let m = vm(floorA, pageSize: 1)
        m.apply(.posts)
        XCTAssertTrue(m.hasMore)
        m.loadMore()
        XCTAssertEqual(m.tweets.map(\.tweetId), ["post-new", "post-old"])
        m.loadMore()
        XCTAssertFalse(m.hasMore)
    }
}
