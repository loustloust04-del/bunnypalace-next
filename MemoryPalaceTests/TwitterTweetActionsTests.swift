import XCTest
import SwiftData
@testable import 记忆花园

/// 推文上的动作：点赞、删除、回复、看回复串。
final class TwitterTweetActionsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let floorA = "xctest-act-a"
    private let floorB = "xctest-act-b"

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

    private func tweet(_ floor: String = "xctest-act-a", id: String, likes: Int = 0,
                       at: TimeInterval = 0) -> TweetEntry {
        let t = TweetEntry(profileId: floor, tweetId: id, text: "正文",
                           createdAt: Date(timeIntervalSince1970: at), favoriteCount: likes)
        context.insert(t)
        return t
    }

    // MARK: 点赞

    func testLikeBumpsCountAndUnlikeRestoresIt() throws {
        let t = tweet(id: "1", likes: 7)
        try TwitterTweetActions.toggleLike(t, context: context)
        XCTAssertTrue(t.likedByMe)
        XCTAssertEqual(t.favoriteCount, 8)
        try TwitterTweetActions.toggleLike(t, context: context)
        XCTAssertFalse(t.likedByMe)
        XCTAssertEqual(t.favoriteCount, 7, "取消赞要回到原数，不能多减也不能少减")
    }

    // MARK: 删除

    func testRemoveHidesTweetFromTimelineAndCount() throws {
        let t = tweet(id: "1")
        _ = tweet(id: "2", at: 1)
        try TwitterTweetActions.remove(t, context: context)
        XCTAssertEqual(try context.fetch(TwitterQueries.timeline(profileId: floorA)).map(\.tweetId), ["2"])
        XCTAssertEqual(try context.fetchCount(TwitterQueries.countAll(profileId: floorA)), 1)
    }

    func testRemovedArchiveTweetStaysGoneAfterReimport() async throws {
        // 删掉的存档推文，重新导入同一份存档不能又冒出来
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tw-act-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-archive", withExtension: nil))

        _ = try await TwitterArchiveImporter.importArchive(at: fixture, profileId: floorA,
                                                           context: context, mediaRoot: sandbox)
        let victim = try XCTUnwrap(try context.fetch(TwitterQueries.timeline(profileId: floorA)).first)
        let victimId = victim.tweetId
        try TwitterTweetActions.remove(victim, context: context)

        _ = try await TwitterArchiveImporter.importArchive(at: fixture, profileId: floorA,
                                                           context: context, mediaRoot: sandbox)
        let ids = try context.fetch(TwitterQueries.timeline(profileId: floorA)).map(\.tweetId)
        XCTAssertFalse(ids.contains(victimId))
        XCTAssertEqual(ids.count, 2)
    }

    // MARK: 回复

    func testReplyLinksToParentAndAuthor() throws {
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "1",
                                             screenName: "susu", displayName: "禾禾"))
        let parent = tweet(id: "p")
        let reply = try TwitterComposer.post(text: "补一句", replyingTo: parent,
                                             profileId: floorA, context: context)
        XCTAssertEqual(reply.inReplyToTweetId, "p")
        XCTAssertEqual(reply.inReplyToScreenName, "susu", "自己回自己，回复行显示自己的 handle")
    }

    func testRepliesQueryIsOldestFirstAndScopedToParent() throws {
        _ = tweet(id: "p")
        for (id, at) in [("r2", 20.0), ("r1", 10.0)] {
            let r = tweet(id: id, at: at)
            r.inReplyToTweetId = "p"
        }
        let other = tweet(id: "x", at: 30)
        other.inReplyToTweetId = "someone-else"
        let gone = tweet(id: "r3", at: 40)
        gone.inReplyToTweetId = "p"
        gone.isRemoved = true
        let otherFloor = tweet(floorB, id: "b1", at: 50)
        otherFloor.inReplyToTweetId = "p"
        try context.save()

        let ids = try context.fetch(TwitterQueries.replies(profileId: floorA, to: "p")).map(\.tweetId)
        XCTAssertEqual(ids, ["r1", "r2"], "回复串按时间正序读，删掉的和别的楼层都不算")
    }
}
