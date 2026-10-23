import XCTest
import SwiftData
@testable import 记忆花园

/// 取数口的特征测试。两条项目硬规则要靠它们兜住：
/// 跨楼层隔离（每个 fetch 带 profileId）、关键词匹配落 predicate（不做内存 filter）。
final class TwitterQueriesTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let floorA = "xctest-tw-a"
    private let floorB = "xctest-tw-b"

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    private func seed(_ profileId: String, id: String, text: String = "",
                      at: TimeInterval, media: Int = 0, tags: String = "") {
        context.insert(TweetEntry(profileId: profileId, tweetId: id, text: text,
                                  createdAt: Date(timeIntervalSince1970: at),
                                  hashtagsJoined: tags, mediaCount: media))
    }

    func testTimelineIsIsolatedByProfileId() throws {
        seed(floorA, id: "a1", at: 100)
        seed(floorB, id: "b1", at: 200)
        let rows = try context.fetch(TwitterQueries.timeline(profileId: floorA))
        XCTAssertEqual(rows.map(\.tweetId), ["a1"], "B 楼层的推文不该出现在 A 的时间线里")
    }

    func testTimelineIsNewestFirst() throws {
        seed(floorA, id: "old", at: 100)
        seed(floorA, id: "new", at: 300)
        seed(floorA, id: "mid", at: 200)
        let rows = try context.fetch(TwitterQueries.timeline(profileId: floorA))
        XCTAssertEqual(rows.map(\.tweetId), ["new", "mid", "old"])
    }

    func testTimelinePaginatesByCursor() throws {
        for i in 0..<5 { seed(floorA, id: "t\(i)", at: TimeInterval(i)) }
        // 倒序后是 t4 t3 t2 t1 t0
        let first = try context.fetch(TwitterQueries.timeline(profileId: floorA, limit: 2))
        XCTAssertEqual(first.map(\.tweetId), ["t4", "t3"])

        let cursor = try XCTUnwrap(first.last?.createdAt)
        let second = try context.fetch(TwitterQueries.timeline(profileId: floorA, before: cursor, limit: 2))
        XCTAssertEqual(second.map(\.tweetId), ["t2", "t1"], "游标要严格小于，不能把上一页最后一条再吐一遍")

        let cursor2 = try XCTUnwrap(second.last?.createdAt)
        let third = try context.fetch(TwitterQueries.timeline(profileId: floorA, before: cursor2, limit: 2))
        XCTAssertEqual(third.map(\.tweetId), ["t0"], "最后一页不足 limit 也要正确收尾")
    }

    func testWithMediaFiltersInPredicate() throws {
        seed(floorA, id: "plain", at: 100, media: 0)
        seed(floorA, id: "photo", at: 200, media: 2)
        seed(floorB, id: "other", at: 300, media: 5)
        let rows = try context.fetch(TwitterQueries.withMedia(profileId: floorA))
        XCTAssertEqual(rows.map(\.tweetId), ["photo"])
    }

    func testWithMediaPaginatesByCursorToo() throws {
        // 重度存档的有图推文也可能上万条，不能一次全拉
        for i in 0..<5 { seed(floorA, id: "m\(i)", at: TimeInterval(i), media: 1) }
        let first = try context.fetch(TwitterQueries.withMedia(profileId: floorA, limit: 2))
        XCTAssertEqual(first.map(\.tweetId), ["m4", "m3"])
        let cursor = try XCTUnwrap(first.last?.createdAt)
        let second = try context.fetch(TwitterQueries.withMedia(profileId: floorA, before: cursor, limit: 2))
        XCTAssertEqual(second.map(\.tweetId), ["m2", "m1"])
    }

    func testSearchMatchesTextInPredicate() throws {
        seed(floorA, id: "hit", text: "今天去看了海", at: 100)
        seed(floorA, id: "miss", text: "完全无关", at: 200)
        let rows = try context.fetch(TwitterQueries.search(profileId: floorA, keyword: "海"))
        XCTAssertEqual(rows.map(\.tweetId), ["hit"])
    }

    func testSearchAlsoMatchesHashtags() throws {
        seed(floorA, id: "tagged", text: "正文没有", at: 100, tags: "测试 swift")
        seed(floorA, id: "untagged", text: "正文没有", at: 200, tags: "")
        let rows = try context.fetch(TwitterQueries.search(profileId: floorA, keyword: "swift"))
        XCTAssertEqual(rows.map(\.tweetId), ["tagged"])
    }

    func testSearchIsIsolatedByProfileId() throws {
        seed(floorA, id: "a", text: "同样的词", at: 100)
        seed(floorB, id: "b", text: "同样的词", at: 200)
        let rows = try context.fetch(TwitterQueries.search(profileId: floorA, keyword: "同样"))
        XCTAssertEqual(rows.map(\.tweetId), ["a"])
    }

    func testExistingFindsOnlySameFloorSameId() throws {
        seed(floorA, id: "dup", at: 100)
        seed(floorB, id: "dup", at: 200)
        let inA = try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "dup"))
        XCTAssertEqual(inA.count, 1)
        XCTAssertEqual(inA.first?.profileId, floorA)
        let missing = try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "nope"))
        XCTAssertTrue(missing.isEmpty)
    }

    // MARK: - 全局搜索「推特」标签（S3-2）：时间 + id 游标，同一秒的推文不重不漏

    func testSearchPagesByTimeAndIdCursor() throws {
        for i in 0..<5 { seed(floorA, id: "s\(i)", text: "薄荷 \(i)", at: 100) }
        for i in 5..<8 { seed(floorA, id: "s\(i)", text: "薄荷 \(i)", at: TimeInterval(100 + i)) }
        seed(floorA, id: "other", text: "别的", at: 500)
        seed(floorB, id: "b", text: "薄荷", at: 500)
        let words = ["薄荷"]
        var seen: [String] = []
        var cursor: TweetSearchCursor?
        repeat {
            let page = try context.fetch(TwitterQueries.searchPage(profileId: floorA, words: words, from: .distantPast,
                                                                   to: .distantFuture, after: cursor, limit: 3))
            seen += page.map(\.tweetId)
            cursor = page.count == 3 ? page.last.map { TweetSearchCursor(date: $0.createdAt, tweetId: $0.tweetId) } : nil
        } while cursor != nil
        XCTAssertEqual(seen, ["s7", "s6", "s5", "s4", "s3", "s2", "s1", "s0"], "新的在前；同一秒按 id 倒序，翻页不重不漏")
        let total = try context.fetchCount(TwitterQueries.searchCount(profileId: floorA, words: words,
                                                                      from: .distantPast, to: .distantFuture))
        XCTAssertEqual(total, 8)
    }

    func testSearchNeedsEveryWordAndRespectsTimeRange() throws {
        seed(floorA, id: "both", text: "薄荷 布局", at: 100)
        seed(floorA, id: "tag", text: "薄荷", at: 200, tags: "布局")
        seed(floorA, id: "one", text: "薄荷", at: 300)
        let rows = try context.fetch(TwitterQueries.searchPage(profileId: floorA, words: ["薄荷", "布局"], from: .distantPast,
                                                               to: .distantFuture, after: nil, limit: 100))
        XCTAssertEqual(rows.map(\.tweetId), ["tag", "both"], "每个词都要在正文或话题标签里")
        let ranged = try context.fetch(TwitterQueries.searchPage(profileId: floorA, words: ["薄荷"],
                                                                 from: Date(timeIntervalSince1970: 150),
                                                                 to: Date(timeIntervalSince1970: 250), after: nil, limit: 100))
        XCTAssertEqual(ranged.map(\.tweetId), ["tag"])
    }
}
