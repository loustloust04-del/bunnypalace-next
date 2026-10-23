import XCTest
import SwiftData
@testable import 记忆花园

/// 给楼层 AI 的本地推特工具（粟粟 2026-09-24，参考 twitter-bridge-mcp）。
/// 一个工具 `local_twitter`，用 action 区分——项目「工具海」教训：能合不拆。先只在聊天里用。
@MainActor
final class TwitterAIToolTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var mediaRoot: URL!
    private let floor = "xctest-aitool"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self, TwitterBookmarkFolder.self,
            TwitterFollow.self, TwitterLike.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        mediaRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-ai-\(UUID().uuidString)")
        let me = TwitterArchiveAccount(profileId: floor, accountId: "me", screenName: "susu", displayName: "禾禾")
        context.insert(me)
        try TwitterAccounts.activate(me, context: context)
        let t = TweetEntry(profileId: floor, tweetId: "100", text: "今天好累 #日常", createdAt: Date(timeIntervalSince1970: 1000),
                           hashtagsJoined: "日常")
        t.accountId = "me"
        context.insert(t)
        try context.save()
    }

    override func tearDownWithError() throws {
        if let mediaRoot { try? FileManager.default.removeItem(at: mediaRoot) }
        context = nil; container = nil; mediaRoot = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func call(_ args: [String: Any]) -> TwitterAITool.Result {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return TwitterAITool.execute(inputJSON: json, profileId: floor, aiName: "莉莉", aiAvatar: nil,
                                     context: context, mediaRoot: mediaRoot)
    }

    private func aiHandle() -> String {
        TwitterAccounts.aiAccounts(profileId: floor, context: context).first { $0.syncsWithAIProfile }!.screenName
    }

    private func localIds() -> [String] {
        let m = TwitterPanelViewModel(context: context, profileId: floor, pageSize: 100)
        m.apply(.local)
        return m.tweets.map(\.tweetId)
    }

    // MARK: - 写

    func testPostCreatesTheAIAccountAndLandsOnTheLocalTimeline() throws {
        let r = call(["action": "post", "text": "你好，我是莉莉"])
        XCTAssertFalse(r.isError, r.text)
        let ai = try XCTUnwrap(TwitterAccounts.aiAccounts(profileId: floor, context: context).first)
        XCTAssertEqual(ai.displayName, "莉莉")
        let posted = try XCTUnwrap(try context.fetch(TwitterQueries.localTimeline(profileId: floor)).first)
        XCTAssertEqual(posted.text, "你好，我是莉莉")
        XCTAssertEqual(posted.accountId, ai.accountId)
        XCTAssertTrue(r.text.contains(posted.tweetId), "回执带新推的 id，AI 后面才能接着引用")
    }

    func testReplyAndQuote() throws {
        XCTAssertFalse(call(["action": "reply", "tweet_id": "100", "text": "抱抱"]).isError)
        let reply = try XCTUnwrap(try context.fetch(TwitterQueries.replies(profileId: floor, to: "100")).first)
        XCTAssertEqual(reply.inReplyToScreenName, "susu", "回的是禾禾的推，@ 的是禾禾")
        XCTAssertFalse(call(["action": "quote", "tweet_id": "100", "text": "她今天真的很累"]).isError)
        XCTAssertTrue(try context.fetch(TwitterQueries.localTimeline(profileId: floor)).contains { $0.quotedTweetId == "100" })
    }

    func testMyReplyToTheAIAddressesTheAI() throws {
        call(["action": "post", "text": "早"])
        let aiTweet = try XCTUnwrap(try context.fetch(TwitterQueries.localTimeline(profileId: floor)).first)
        let mine = try TwitterComposer.post(text: "早呀", replyingTo: aiTweet, profileId: floor, context: context)
        XCTAssertEqual(mine.inReplyToScreenName, aiHandle(), "回 AI 的推要 @ AI，不是 @ 自己")
    }

    func testLikeIsOncePerAccount() throws {
        XCTAssertFalse(call(["action": "like", "tweet_id": "100"]).isError)
        call(["action": "like", "tweet_id": "100"])
        let t = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: floor, tweetId: "100")).first)
        XCTAssertEqual(t.favoriteCount, 1)
        XCTAssertFalse(t.likedByMe, "AI 的赞不算成禾禾点的")
        XCTAssertFalse(call(["action": "unlike", "tweet_id": "100"]).isError)
        XCTAssertEqual(t.favoriteCount, 0)
    }

    func testRepostOnce() throws {
        XCTAssertFalse(call(["action": "repost", "tweet_id": "100"]).isError)
        XCTAssertTrue(call(["action": "repost", "tweet_id": "100"]).text.contains("转过"))
        let copies = try context.fetch(TwitterQueries.localTimeline(profileId: floor)).filter { $0.repostOfTweetId == "100" }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.accountId, TwitterAccounts.aiAccounts(profileId: floor, context: context).first?.accountId)
    }

    func testFollowByHandle() throws {
        XCTAssertFalse(call(["action": "follow", "handle": "@susu"]).isError)
        let ai = try XCTUnwrap(TwitterAccounts.aiAccounts(profileId: floor, context: context).first)
        XCTAssertEqual(TwitterFollows.followees(of: ai, context: context), ["me"])
        XCTAssertTrue(call(["action": "follow", "handle": "nobody"]).isError)
        XCTAssertFalse(call(["action": "unfollow", "handle": "susu"]).isError)
        XCTAssertTrue(TwitterFollows.followees(of: ai, context: context).isEmpty)
    }

    func testAICanOpenAnotherAccountAndPostAsIt() throws {
        XCTAssertFalse(call(["action": "create_account", "name": "莉莉小号", "handle": "lily_alt"]).isError)
        XCTAssertFalse(call(["action": "post", "text": "小号发言", "as": "lily_alt"]).isError)
        let t = try XCTUnwrap(try context.fetch(TwitterQueries.localTimeline(profileId: floor)).first)
        XCTAssertEqual(TwitterAccounts.aiAccounts(profileId: floor, context: context).first { $0.screenName == "lily_alt" }?.accountId,
                       t.accountId)
        let list = call(["action": "accounts"]).text
        XCTAssertTrue(list.contains("@lily_alt") && list.contains("主号"))
        let bad = call(["action": "post", "text": "x", "as": "susu"])
        XCTAssertTrue(bad.isError, "不能冒充禾禾的号发推")
    }

    // MARK: - 读

    func testTimelineShowsIdsHandlesAndText() throws {
        call(["action": "post", "text": "AI 的推"])
        let r = call(["action": "timeline", "feed": "local"])
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("100") && r.text.contains("@susu") && r.text.contains("今天好累"))
        XCTAssertTrue(r.text.contains("AI 的推"))
        let following = call(["action": "timeline", "feed": "following"]).text
        XCTAssertFalse(following.contains("今天好累"), "AI 还没关注禾禾")
    }

    func testSearchViewUserAndMentions() throws {
        XCTAssertTrue(call(["action": "search", "text": "日常"]).text.contains("今天好累"))
        call(["action": "reply", "tweet_id": "100", "text": "抱抱"])
        let view = call(["action": "view", "tweet_id": "100"]).text
        XCTAssertTrue(view.contains("今天好累") && view.contains("抱抱"), "看单条推带回复串")
        let user = call(["action": "user", "handle": "susu"]).text
        XCTAssertTrue(user.contains("禾禾") && user.contains("今天好累"))

        let aiTweet = try XCTUnwrap(try context.fetch(TwitterQueries.localTimeline(profileId: floor)).first)
        _ = try TwitterComposer.post(text: "谢谢你", replyingTo: aiTweet, profileId: floor, context: context)
        _ = try TwitterComposer.post(text: "@\(aiHandle()) 在吗", profileId: floor, context: context)
        let mentions = call(["action": "mentions"]).text
        XCTAssertTrue(mentions.contains("谢谢你") && mentions.contains("在吗"))
    }

    // MARK: - 错误

    func testErrors() {
        XCTAssertTrue(call(["action": "post"]).isError, "没 text")
        XCTAssertTrue(call(["action": "fly"]).isError, "没这个 action")
        XCTAssertTrue(call(["action": "like", "tweet_id": "404"]).isError, "没这条推")
        XCTAssertTrue(TwitterAITool.execute(inputJSON: "not json", profileId: floor, aiName: "莉莉", aiAvatar: nil,
                                            context: context, mediaRoot: mediaRoot).isError)
    }

    func testDefinitionIsOneToolWithActions() {
        let d = TwitterAITool.definition
        XCTAssertEqual(d.name, "local_twitter")
        XCTAssertEqual(d.required, ["action"])
        let actions = ((d.properties["action"] as? [String: Any])?["enum"] as? [String]) ?? []
        for a in ["post", "reply", "quote", "like", "unlike", "repost", "follow", "unfollow", "timeline",
                  "search", "view", "user", "mentions", "accounts", "create_account"] {
            XCTAssertTrue(actions.contains(a), a)
        }
        XCTAssertEqual(PermissionDomain.forTool(named: "local_twitter"), .twitter)
    }
}
