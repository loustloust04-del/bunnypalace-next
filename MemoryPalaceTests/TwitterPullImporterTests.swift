import XCTest
import SwiftData
@testable import 记忆花园

/// 从 X 直接拉下来的东西（书签 + 书签文件夹、点过的赞、自己的新推）——粟粟 2026-09-24：
/// 官方导出不含书签；Mac 上用 OpenCLI 拉，打成 `twitter-pull.json` + `twitter-pull-media/` 的包，隔空投送进来导入。
@MainActor
final class TwitterPullImporterTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sandbox: URL!
    private let floorA = "xctest-pull-a"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self, TwitterBookmarkFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-pull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        context = nil; container = nil; sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - 造包

    private func tweet(_ id: String, author: String = "AndrewYNg", name: String = "Andrew Ng",
                       text: String = "别人的推", at: String = "Wed Oct 10 20:19:24 +0000 2018",
                       media: [[String: String]] = [], extra: [String: Any] = [:]) -> [String: Any] {
        var t: [String: Any] = ["id": id, "author": author, "name": name, "text": text,
                                "likes": 10, "retweets": 2, "created_at": at,
                                "url": "https://x.com/\(author)/status/\(id)", "media": media]
        for (k, v) in extra { t[k] = v }
        return t
    }

    private func bundle(bookmarks: [[String: Any]] = [], likes: [[String: Any]] = [],
                        tweets: [[String: Any]] = [], folders: [[String: String]] = [],
                        me: String = "susu_test", mediaFiles: [String] = []) throws -> URL {
        let root = sandbox.appendingPathComponent("pull-\(UUID().uuidString)")
        let media = root.appendingPathComponent("twitter-pull-media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for f in mediaFiles { try Data([0xFF, 0xD8, 0xFF]).write(to: media.appendingPathComponent(f)) }
        let json: [String: Any] = [
            "format": "memorypalace.twitter-pull", "version": 1,
            "pulledAt": "2026-09-24T08:00:00Z",
            "me": ["screenName": me, "name": "禾禾"],
            "folders": folders, "bookmarks": bookmarks, "likes": likes, "tweets": tweets,
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("twitter-pull.json"))
        return root
    }

    @discardableResult
    private func run(_ url: URL) async throws -> TwitterImportResult {
        try await TwitterArchiveImporter.importArchive(at: url, profileId: floorA, context: context, mediaRoot: sandbox)
    }

    private func vm() -> TwitterPanelViewModel {
        let m = TwitterPanelViewModel(context: context, profileId: floorA, pageSize: 100)
        m.reload()
        return m
    }

    private func me() throws {
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "1", screenName: "susu_test", displayName: "禾禾"))
        try context.save()
    }

    // MARK: - 书签

    func testImportsBookmarksKeepingXOrder() async throws {
        try me()
        let r = try await run(try bundle(bookmarks: [tweet("b1", text: "最新收藏的"), tweet("b2", text: "早一点收藏的")]))
        XCTAssertEqual(r.bookmarksImported, 2)
        let m = vm()
        m.apply(.bookmarks)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["b1", "b2"], "X 给的就是收藏先后，照原样排")
        XCTAssertEqual(m.tweets.first?.authorScreenName, "AndrewYNg")
        XCTAssertEqual(m.tweets.first?.authorName, "Andrew Ng")
    }

    func testOthersTweetsStayOutOfMyTimeline() async throws {
        try me()
        try await run(try bundle(bookmarks: [tweet("b1")], likes: [tweet("l1")]))
        let m = vm()
        XCTAssertTrue(m.tweets.isEmpty, "别人的推只在书签页和「喜欢」里，不混进自己的时间线")
        XCTAssertEqual(m.totalCount, 0, "推文总数只数自己的")
    }

    func testBookmarkFolders() async throws {
        try me()
        try await run(try bundle(bookmarks: [tweet("b1", extra: ["folderIds": ["f1"]]), tweet("b2")],
                                 folders: [["id": "f1", "name": "学习"]]))
        let folders = TwitterBookmarkFolders.all(profileId: floorA, context: context)
        XCTAssertEqual(folders.map(\.name), ["学习"])
        let m = vm()
        m.apply(.bookmarkFolder("f1"))
        XCTAssertEqual(m.tweets.map(\.tweetId), ["b1"])
    }

    func testBookmarkingMyOwnArchivedTweetFlagsTheExistingRow() async throws {
        try me()
        let mine = TweetEntry(profileId: floorA, tweetId: "own1", text: "我自己的", createdAt: Date())
        mine.accountId = "1"
        context.insert(mine)
        try context.save()
        try await run(try bundle(bookmarks: [tweet("own1", author: "susu_test", name: "禾禾")]))
        let rows = try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "own1"))
        XCTAssertEqual(rows.count, 1, "不能多出一条")
        XCTAssertNotNil(rows[0].bookmarkedAt)
        XCTAssertNil(rows[0].authorScreenName, "还是自己的推")
    }

    func testRepullIsIdempotentAndKeepsBookmarkTime() async throws {
        try me()
        let b = try bundle(bookmarks: [tweet("b1")])
        try await run(b)
        let first = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1")).first?.bookmarkedAt)
        let second = try await run(b)
        XCTAssertEqual(second.bookmarksImported, 0)
        let rows = try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1"))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bookmarkedAt, first)
    }

    // MARK: - 赞 / 自己的新推

    func testLikesGoToTheLikesTab() async throws {
        try me()
        let r = try await run(try bundle(likes: [tweet("l1"), tweet("l2", at: "Thu Oct 11 20:19:24 +0000 2018")]))
        XCTAssertEqual(r.likesImported, 2)
        let m = vm()
        m.apply(.liked)
        XCTAssertEqual(Set(m.tweets.map(\.tweetId)), ["l1", "l2"])
        XCTAssertTrue(m.tweets.allSatisfy(\.likedByMe))
    }

    func testMyNewTweetsJoinTheTimelineWithoutDuplicatingArchive() async throws {
        try me()
        let old = TweetEntry(profileId: floorA, tweetId: "t-old", text: "存档里就有", createdAt: Date(timeIntervalSince1970: 1))
        old.accountId = "1"
        context.insert(old)
        try context.save()
        let r = try await run(try bundle(tweets: [
            tweet("t-new", author: "susu_test", name: "禾禾", text: "导出之后发的", at: "Tue Sep 22 20:19:24 +0000 2026"),
            tweet("t-old", author: "susu_test", name: "禾禾", text: "存档里就有"),
        ]))
        XCTAssertEqual(r.tweetsImported, 1)
        XCTAssertEqual(vm().tweets.map(\.tweetId), ["t-new", "t-old"])
        XCTAssertNil(vm().tweets.first?.authorScreenName, "自己的推不挂作者")
    }

    func testPullAttachesToTheMatchingAccount() async throws {
        // 拉的是哪个号就进哪个号，不看当前选中的是谁
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "1", screenName: "susu_test", displayName: "禾禾"))
        let alt = TwitterArchiveAccount(profileId: floorA, accountId: "2", screenName: "alt", displayName: "小号")
        context.insert(alt)
        try TwitterAccounts.activate(alt, context: context)
        try await run(try bundle(bookmarks: [tweet("b1")], me: "susu_test"))
        let row = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1")).first)
        XCTAssertEqual(row.accountId, "1")
    }

    func testPullForAnAccountTheAppDoesNotHaveCreatesItAndSwitches() async throws {
        // 粟粟 2026-09-24 换了个会员号登录拉：不能塞进原来那个号
        try me()
        try await run(try bundle(bookmarks: [tweet("b1")], me: "susu_space"))
        let all = TwitterAccounts.all(profileId: floorA, context: context)
        XCTAssertEqual(Set(all.map(\.screenName)), ["susu_test", "susu_space"])
        let active = try XCTUnwrap(TwitterAccounts.active(profileId: floorA, context: context))
        XCTAssertEqual(active.screenName, "susu_space")
        let row = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1")).first)
        XCTAssertEqual(row.accountId, active.accountId)
    }

    func testLaterArchiveOfThePulledAccountTakesItOverInsteadOfDuplicating() async throws {
        // 先拉了 @susu_test，后来又导了它的官方存档：还是一个号，拉来的书签跟着走
        try await run(try bundle(bookmarks: [tweet("b1")], me: "susu_test"))
        let archive = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-archive", withExtension: nil))
        try await run(archive)
        let all = TwitterAccounts.all(profileId: floorA, context: context)
        XCTAssertEqual(all.map(\.accountId), ["1234567890"])
        let m = vm()
        m.apply(.bookmarks)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["b1"])
    }

    func testArchiveEnrichesMyTweetsThatCameFromAPullFirst() async throws {
        // 粟粟 2026-09-24：先导了拉取包，官方存档后到。存档里同一条推信息更全（回复关系、长推全文、媒体），
        // 不能因为 id 重复就跳过；书签、赞这些标记要保住
        try await run(try bundle(
            bookmarks: [tweet("1000000000000000002", author: "susu_test", name: "禾禾", text: "简版")],
            tweets: [tweet("1000000000000000002", author: "susu_test", name: "禾禾", text: "简版"),
                     tweet("1000000000000000003", author: "susu_test", name: "禾禾", text: "带图的推文")],
            me: "susu_test"))
        let archive = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-archive", withExtension: nil))
        try await run(archive)

        let reply = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "1000000000000000002")).first)
        XCTAssertEqual(reply.text, "回复别人的推文，其实后面还有很长一段 & 结尾", "用存档的长推全文")
        XCTAssertEqual(reply.inReplyToTweetId, "1000000000000000001", "补上回复关系")
        XCTAssertNotNil(reply.bookmarkedAt, "书签标记要保住")
        XCTAssertEqual(reply.sourceURL, "https://x.com/susu_test/status/1000000000000000002", "原帖链接也保住")

        let pic = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "1000000000000000003")).first)
        XCTAssertEqual(pic.mediaCount, 1, "拉取时没图的，用存档的图补上")
        XCTAssertEqual(try context.fetch(TwitterQueries.media(profileId: floorA, tweetIds: [pic.tweetId])).count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TweetEntry>(predicate: #Predicate {
            $0.tweetId == "1000000000000000002" })), 1, "还是一条")
    }

    // MARK: - 媒体 / 引用

    func testCopiesMedia() async throws {
        try me()
        try await run(try bundle(bookmarks: [tweet("b1", media: [["file": "b1-0.jpg", "kind": "photo"],
                                                                 ["file": "b1-1.mp4", "kind": "video"]])],
                                 mediaFiles: ["b1-0.jpg", "b1-1.mp4"]))
        let rows = try context.fetch(TwitterQueries.media(profileId: floorA, tweetIds: ["b1"]))
        XCTAssertEqual(Set(rows.map(\.fileName)), ["b1-0.jpg", "b1-1.mp4"])
        XCTAssertEqual(Set(rows.map(\.kind)), ["photo", "video"])
        for r in rows {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: sandbox.appendingPathComponent(floorA).appendingPathComponent(r.fileName).path))
        }
        XCTAssertEqual(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1")).first?.mediaCount, 2)
    }

    func testMissingMediaFileIsSkippedNotFatal() async throws {
        try me()
        try await run(try bundle(bookmarks: [tweet("b1", media: [["file": "gone.jpg", "kind": "photo"]])]))
        XCTAssertTrue(try context.fetch(TwitterQueries.media(profileId: floorA, tweetIds: ["b1"])).isEmpty)
    }

    func testQuotedTweetIsStoredAndLinked() async throws {
        try me()
        try await run(try bundle(bookmarks: [tweet("b1", extra: ["quoted": tweet("q1", author: "someone", text: "被引用的")])]))
        let row = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1")).first)
        XCTAssertEqual(row.quotedTweetId, "q1")
        let m = vm()
        m.apply(.bookmarks)
        XCTAssertEqual(m.quoted(for: row)?.text, "被引用的")
    }

    // MARK: - 别人的推上的动作

    func testReplyToSomeoneElsesTweetAddressesTheAuthor() async throws {
        try me()
        try await run(try bundle(bookmarks: [tweet("b1")]))
        let b = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1")).first)
        let r = try TwitterComposer.post(text: "学到了", replyingTo: b, profileId: floorA, context: context)
        XCTAssertEqual(r.inReplyToScreenName, "AndrewYNg")
    }

    func testRepostingSomeoneElsesTweetShowsTheAuthorAndLandsInMyTimeline() async throws {
        try me()
        try await run(try bundle(bookmarks: [tweet("b1")]))
        let b = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "b1")).first)
        let copy = try XCTUnwrap(try TwitterTweetActions.toggleRepost(b, context: context))
        XCTAssertEqual(copy.retweetedScreenName, "AndrewYNg")
        XCTAssertEqual(copy.retweetedName, "Andrew Ng")
        XCTAssertNil(copy.authorScreenName, "转帖这一行是自己时间线上的")
        XCTAssertEqual(vm().tweets.map(\.tweetId), [copy.tweetId])
    }

    // MARK: - 包的识别

    func testRejectsUnknownFormat() async throws {
        let root = sandbox.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"format":"something-else"}"#.utf8).write(to: root.appendingPathComponent("twitter-pull.json"))
        do {
            try await run(root)
            XCTFail("认不出的包要报错")
        } catch {
            XCTAssertEqual(error as? TwitterArchiveError, .unsupportedPullFormat)
        }
    }

    func testImportsAZipMadeByThePythonScript() async throws {
        // 端到端：scripts/twitter-pull.py 用 Python zipfile 打包，App 端解压器是自写的——得认得
        try me()
        let zip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-zip", withExtension: nil))
            .appendingPathComponent("pull-sample.zip")
        let r = try await run(zip)
        XCTAssertEqual(r.bookmarksImported, 1)
        XCTAssertEqual(r.mediaCopied, 1)
        let row = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floorA, tweetId: "900")).first)
        XCTAssertEqual(row.text, "Learn & build")
        XCTAssertEqual(row.bookmarkFolderIds, "|f1|")
    }

    func testZipFilterLetsPullBundleThrough() {
        XCTAssertTrue(TwitterZipExtractor.neededForImport("twitter-pull.json"))
        XCTAssertTrue(TwitterZipExtractor.neededForImport("pull-2026/twitter-pull.json"))
        XCTAssertTrue(TwitterZipExtractor.neededForImport("twitter-pull-media/b1-0.jpg"))
        XCTAssertFalse(TwitterZipExtractor.neededForImport("twitter-pull-media/sub/x.jpg"))
    }
}
