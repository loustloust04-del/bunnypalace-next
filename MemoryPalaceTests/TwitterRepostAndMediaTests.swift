import XCTest
import SwiftData
@testable import 记忆花园

/// 粟粟 2026-09-24：「不能转发、发贴也不能带图」。
/// 转发 = 推特的「转帖」（原样转一次，可撤销）+「引用」（带自己的话）；发帖最多四张图。
@MainActor
final class TwitterRepostAndMediaTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var mediaDir: URL!
    private let floorA = "xctest-rp-a"
    private let floorB = "xctest-rp-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        mediaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-rp-\(UUID().uuidString)")
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "1", screenName: "susu", displayName: "禾禾"))
        try context.save()
    }

    override func tearDownWithError() throws {
        if let mediaDir { try? FileManager.default.removeItem(at: mediaDir) }
        context = nil; container = nil; mediaDir = nil
        try super.tearDownWithError()
    }

    private func original(id: String = "o1", retweets: Int = 2, media: Int = 0, at: TimeInterval = 100) throws -> TweetEntry {
        let t = TweetEntry(profileId: floorA, tweetId: id, text: "原推", createdAt: Date(timeIntervalSince1970: at),
                           retweetCount: retweets, mediaCount: media)
        context.insert(t)
        for i in 0..<media {
            context.insert(TweetMedia(profileId: floorA, tweetId: id, mediaId: "m\(i)", fileName: "\(id)-\(i).jpg"))
        }
        try context.save()
        return t
    }

    private func timeline() throws -> [TweetEntry] {
        try context.fetch(TwitterQueries.timeline(profileId: floorA, limit: 100))
    }

    // MARK: 转帖

    func testRepostPutsACopyOnTopOfTheTimeline() throws {
        let o = try original()
        let r = try XCTUnwrap(try TwitterTweetActions.toggleRepost(o, context: context))
        XCTAssertEqual(try timeline().first?.tweetId, r.tweetId, "转帖是新的一条，排在最上面")
        XCTAssertEqual(r.repostOfTweetId, "o1")
        XCTAssertEqual(r.text, "原推")
        XCTAssertEqual(r.retweetedScreenName, "susu", "转自己的推，转推头上的作者就是自己")
        XCTAssertTrue(o.retweetedByMe)
        XCTAssertEqual(o.retweetCount, 3)
    }

    func testRepostCarriesTheMedia() throws {
        let o = try original(media: 2)
        let r = try XCTUnwrap(try TwitterTweetActions.toggleRepost(o, context: context))
        XCTAssertEqual(r.mediaCount, 2)
        let rows = try context.fetch(TwitterQueries.media(profileId: floorA, tweetIds: [r.tweetId]))
        XCTAssertEqual(Set(rows.map(\.fileName)), ["o1-0.jpg", "o1-1.jpg"], "指向同一批文件，不复制图")
    }

    func testRepostAgainUndoes() throws {
        let o = try original()
        _ = try TwitterTweetActions.toggleRepost(o, context: context)
        let undone = try TwitterTweetActions.toggleRepost(o, context: context)
        XCTAssertNil(undone)
        XCTAssertEqual(try timeline().map(\.tweetId), ["o1"])
        XCTAssertFalse(o.retweetedByMe)
        XCTAssertEqual(o.retweetCount, 2)
    }

    func testRepostingTheRepostRowActsOnTheOriginal() throws {
        // 时间线上点的可能是转帖那一行，撤销要作用在原推上
        let o = try original()
        let r = try XCTUnwrap(try TwitterTweetActions.toggleRepost(o, context: context))
        XCTAssertNil(try TwitterTweetActions.toggleRepost(r, context: context))
        XCTAssertEqual(try timeline().map(\.tweetId), ["o1"])
        XCTAssertFalse(o.retweetedByMe)
    }

    func testRepostOfArchiveRetweetKeepsTheOriginalAuthor() throws {
        let o = try original()
        o.retweetedScreenName = "alice"
        o.retweetedName = "爱丽丝"
        let r = try XCTUnwrap(try TwitterTweetActions.toggleRepost(o, context: context))
        XCTAssertEqual(r.retweetedScreenName, "alice")
        XCTAssertEqual(r.retweetedName, "爱丽丝")
    }

    // MARK: 引用

    func testQuoteLinksToTheQuotedTweet() throws {
        let o = try original()
        let q = try TwitterComposer.post(text: "说两句", quoting: o, profileId: floorA, context: context)
        XCTAssertEqual(q.quotedTweetId, "o1")
    }

    func testPanelLoadsQuotedTweetsWithThePage() throws {
        let o = try original(at: 1)
        let q = try TwitterComposer.post(text: "说两句", quoting: o, profileId: floorA, context: context)
        let vm = TwitterPanelViewModel(context: context, profileId: floorA)
        vm.reload()
        XCTAssertEqual(vm.quoted(for: q)?.tweetId, "o1", "被引用的推跟着页一起取，不在行里逐条查库")
        XCTAssertNil(vm.quoted(for: o))
    }

    // MARK: 带图发推

    func testPostWithImagesWritesFilesAndMediaRows() throws {
        let t = try TwitterComposer.post(text: "看图", images: [Data([1]), Data([2])], mediaDir: mediaDir,
                                         profileId: floorA, context: context)
        XCTAssertEqual(t.mediaCount, 2)
        let rows = try context.fetch(TwitterQueries.media(profileId: floorA, tweetIds: [t.tweetId]))
        XCTAssertEqual(rows.count, 2)
        for r in rows {
            XCTAssertTrue(FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(r.fileName).path))
        }
        XCTAssertEqual(try context.fetch(TwitterQueries.withMedia(profileId: floorA)).map(\.tweetId), [t.tweetId],
                       "带图的推要进「有图」")
    }

    func testImageOnlyPostIsAllowed() throws {
        // 推特可以只发图不写字
        let t = try TwitterComposer.post(text: "  ", images: [Data([1])], mediaDir: mediaDir,
                                         profileId: floorA, context: context)
        XCTAssertEqual(t.text, "")
        XCTAssertEqual(t.mediaCount, 1)
    }

    func testRejectsMoreThanFourImages() {
        XCTAssertThrowsError(try TwitterComposer.post(text: "x", images: Array(repeating: Data([1]), count: 5),
                                                      mediaDir: mediaDir, profileId: floorA, context: context)) {
            XCTAssertEqual($0 as? TwitterComposerError, .tooManyImages)
        }
    }

    func testReplyToArchiveRetweetAddressesItsAuthor() throws {
        let o = try original()
        o.retweetedScreenName = "alice"
        let r = try TwitterComposer.post(text: "嗯", replyingTo: o, profileId: floorA, context: context)
        XCTAssertEqual(r.inReplyToScreenName, "alice")
    }
}
