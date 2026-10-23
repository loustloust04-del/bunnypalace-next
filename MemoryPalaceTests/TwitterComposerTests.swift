import XCTest
import SwiftData
@testable import 记忆花园

/// 自己发一条推。数据层当初就是按可写设计的，这里兑现：写进同一张表，不另起炉灶。
final class TwitterComposerTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let floorA = "xctest-compose-a"
    private let floorB = "xctest-compose-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil; container = nil
        try super.tearDownWithError()
    }

    func testPostsATweet() throws {
        let t = try TwitterComposer.post(text: "今天天气不错", profileId: floorA, context: context)
        XCTAssertEqual(t.text, "今天天气不错")
        XCTAssertEqual(t.profileId, floorA)
        XCTAssertEqual(t.favoriteCount, 0)
        XCTAssertEqual(t.retweetCount, 0)
    }

    func testPostedTweetIsTimestampedNow() throws {
        let before = Date()
        let t = try TwitterComposer.post(text: "x", profileId: floorA, context: context)
        XCTAssertGreaterThanOrEqual(t.createdAt, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(t.createdAt, Date().addingTimeInterval(1))
    }

    func testPostedTweetSitsAtTheTopOfTheTimeline() throws {
        context.insert(TweetEntry(profileId: floorA, tweetId: "old", text: "很久以前",
                                  createdAt: Date(timeIntervalSince1970: 1)))
        _ = try TwitterComposer.post(text: "刚刚", profileId: floorA, context: context)
        let rows = try context.fetch(TwitterQueries.timeline(profileId: floorA, limit: 10))
        XCTAssertEqual(rows.first?.text, "刚刚", "新发的要在最上面")
    }

    func testRejectsBlankText() throws {
        XCTAssertThrowsError(try TwitterComposer.post(text: "   \n ", profileId: floorA, context: context)) {
            XCTAssertEqual($0 as? TwitterComposerError, .emptyText)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TweetEntry>()), 0, "空内容不能落库")
    }

    func testExtractsHashtagsSoSearchFindsThem() throws {
        let t = try TwitterComposer.post(text: "去了海边 #散步 #周末", profileId: floorA, context: context)
        XCTAssertEqual(t.hashtagsJoined, "散步 周末")
        let hits = try context.fetch(TwitterQueries.search(profileId: floorA, keyword: "周末"))
        XCTAssertEqual(hits.map(\.tweetId), [t.tweetId], "自己发的推也要能被搜到")
    }

    func testEachPostGetsItsOwnId() throws {
        let a = try TwitterComposer.post(text: "一", profileId: floorA, context: context)
        let b = try TwitterComposer.post(text: "二", profileId: floorA, context: context)
        XCTAssertNotEqual(a.tweetId, b.tweetId)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TweetEntry>()), 2)
    }

    func testPostedIdsCannotCollideWithArchiveIds() throws {
        let t = try TwitterComposer.post(text: "x", profileId: floorA, context: context)
        // 存档的 id 是纯数字雪花号；自己发的必须落在另一个命名空间里，
        // 否则重新导入存档时可能被当成重复而覆盖
        XCTAssertFalse(t.tweetId.allSatisfy(\.isNumber), "自发推的 id 不能长得像存档 id")
        XCTAssertTrue(t.tweetId.hasPrefix(TwitterComposer.localIdPrefix))
    }

    func testIsIsolatedByFloor() throws {
        _ = try TwitterComposer.post(text: "A 楼层的", profileId: floorA, context: context)
        XCTAssertEqual(try context.fetchCount(TwitterQueries.countAll(profileId: floorB)), 0)
    }

    func testTrimsSurroundingWhitespace() throws {
        let t = try TwitterComposer.post(text: "  前后有空白  ", profileId: floorA, context: context)
        XCTAssertEqual(t.text, "前后有空白")
    }
}
