import XCTest
import SwiftData
@testable import 记忆花园

/// 粟粟 2026-09-25：通知箱 + 一根线串下来的回复串。
@MainActor
final class TwitterNotificationsAndThreadTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var mediaRoot: URL!
    private let floor = "xctest-notif"
    private var me: TwitterArchiveAccount!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self, TwitterBookmarkFolder.self,
            TwitterFollow.self, TwitterLike.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        mediaRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-nt-\(UUID().uuidString)")
        me = TwitterArchiveAccount(profileId: floor, accountId: "me", screenName: "susu", displayName: "禾禾")
        context.insert(me)
        try TwitterAccounts.activate(me, context: context)
        try context.save()
    }

    override func tearDownWithError() throws {
        if let mediaRoot { try? FileManager.default.removeItem(at: mediaRoot) }
        context = nil; container = nil; mediaRoot = nil; me = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func ai(_ args: [String: Any]) -> TwitterAITool.Result {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return TwitterAITool.execute(inputJSON: json, profileId: floor, aiName: "狗狗", aiAvatar: nil,
                                     context: context, mediaRoot: mediaRoot)
    }

    private func notifs() -> [TwitterNotifications.Item] {
        TwitterNotifications.items(for: "me", handle: "susu", profileId: floor, context: context)
    }

    // MARK: - 通知

    func testAILikeReplyQuoteRepostMentionFollowAllNotify() throws {
        let mine = try TwitterComposer.post(text: "今天好累", profileId: floor, context: context)
        ai(["action": "like", "tweet_id": mine.tweetId])
        ai(["action": "reply", "tweet_id": mine.tweetId, "text": "抱抱"])
        ai(["action": "quote", "tweet_id": mine.tweetId, "text": "她累了"])
        ai(["action": "repost", "tweet_id": mine.tweetId])
        ai(["action": "post", "text": "@susu 早点睡"])
        ai(["action": "follow", "handle": "susu"])
        let kinds = Set(notifs().map(\.kind))
        XCTAssertEqual(kinds, [.like, .reply, .quote, .repost, .mention, .follow])
        let aiId = try XCTUnwrap(TwitterAccounts.aiAccounts(profileId: floor, context: context).first?.accountId)
        XCTAssertTrue(notifs().allSatisfy { $0.actorId == aiId })
        XCTAssertEqual(notifs().first { $0.kind == .like }?.tweet?.tweetId, mine.tweetId, "赞点进去是被赞的那条")
        XCTAssertEqual(notifs().first { $0.kind == .reply }?.tweet?.text, "抱抱", "回复点进去是对方那条")
    }

    func testMyOwnActionsAndOthersTweetsDontNotify() throws {
        let mine = try TwitterComposer.post(text: "自言自语", profileId: floor, context: context)
        _ = try TwitterComposer.post(text: "自己回自己", replyingTo: mine, profileId: floor, context: context)
        ai(["action": "post", "text": "狗狗自己的推"])
        let aiTweet = try XCTUnwrap(try context.fetch(TwitterQueries.localTimeline(profileId: floor)).first { $0.text == "狗狗自己的推" })
        ai(["action": "reply", "tweet_id": aiTweet.tweetId, "text": "狗狗回狗狗"])
        XCTAssertTrue(notifs().isEmpty, "自己干的、别人之间的，都不进我的通知")
    }

    func testRemovedReplyDisappearsAndUnreadCounts() throws {
        let mine = try TwitterComposer.post(text: "在吗", profileId: floor, context: context)
        let before = Date()
        ai(["action": "reply", "tweet_id": mine.tweetId, "text": "在"])
        let items = notifs()
        XCTAssertEqual(TwitterNotifications.unreadCount(items, since: before.addingTimeInterval(-1)), 1)
        XCTAssertEqual(TwitterNotifications.unreadCount(items, since: Date().addingTimeInterval(1)), 0)
        try TwitterTweetActions.remove(try XCTUnwrap(items.first?.tweet), context: context)
        XCTAssertTrue(notifs().isEmpty)
    }

    func testSeenIsPerAccount() {
        let d = UserDefaults(suiteName: "xctest-notif-\(UUID().uuidString)")!
        XCTAssertEqual(TwitterNotifications.lastSeen(profileId: floor, me: "me", defaults: d), .distantPast)
        let now = Date()
        TwitterNotifications.markSeen(profileId: floor, me: "me", at: now, defaults: d)
        XCTAssertEqual(TwitterNotifications.lastSeen(profileId: floor, me: "me", defaults: d), now)
        XCTAssertEqual(TwitterNotifications.lastSeen(profileId: floor, me: "alt", defaults: d), .distantPast)
    }

    // MARK: - 回复串

    func testAncestorsRunTopDownAndBranchesCarryFirstChild() throws {
        let root = try TwitterComposer.post(text: "1 楼", profileId: floor, context: context)
        let r2 = try TwitterComposer.post(text: "2 楼", replyingTo: root, profileId: floor, context: context)
        let r3 = try TwitterComposer.post(text: "3 楼", replyingTo: r2, profileId: floor, context: context)
        let r3b = try TwitterComposer.post(text: "3 楼另一条", replyingTo: r2, profileId: floor, context: context)
        r3b.createdAt = r3.createdAt.addingTimeInterval(5)
        let r4 = try TwitterComposer.post(text: "4 楼", replyingTo: r3, profileId: floor, context: context)
        try context.save()

        XCTAssertEqual(TwitterThread.ancestors(of: r4, context: context).map(\.text), ["1 楼", "2 楼", "3 楼"])
        XCTAssertTrue(TwitterThread.ancestors(of: root, context: context).isEmpty)

        let b = TwitterThread.branches(under: root, context: context)
        XCTAssertEqual(b.map(\.reply.text), ["2 楼"])
        XCTAssertEqual(b.first?.firstChild?.text, "3 楼")
        XCTAssertEqual(b.first?.moreCount, 1, "3 楼另一条收起，点进 2 楼能看见")
    }

    func testReplyCountsLikeTheLikeCount() throws {
        // 粟粟 2026-09-25：没点进去的时候，回复图标旁边也要有数，跟点赞一样
        let a = try TwitterComposer.post(text: "a", profileId: floor, context: context)
        let b = try TwitterComposer.post(text: "b", profileId: floor, context: context)
        let r1 = try TwitterComposer.post(text: "r1", replyingTo: a, profileId: floor, context: context)
        _ = try TwitterComposer.post(text: "r2", replyingTo: a, profileId: floor, context: context)
        _ = try TwitterComposer.post(text: "r1-1", replyingTo: r1, profileId: floor, context: context)
        let gone = try TwitterComposer.post(text: "删了", replyingTo: b, profileId: floor, context: context)
        try TwitterTweetActions.remove(gone, context: context)
        let counts = TwitterThread.replyCounts(for: [a.tweetId, b.tweetId, r1.tweetId], profileId: floor, context: context)
        XCTAssertEqual(counts[a.tweetId], 2, "只数直接回复")
        XCTAssertNil(counts[b.tweetId], "删了的不算")
        XCTAssertEqual(counts[r1.tweetId], 1)
        XCTAssertTrue(TwitterThread.replyCounts(for: [], profileId: floor, context: context).isEmpty)

        let vm = TwitterPanelViewModel(context: context, profileId: floor)
        vm.apply(.local)
        XCTAssertEqual(vm.replyCount(for: a), 2, "时间线按页一起取好，不在行里逐条查")
    }

    func testAncestorChainStopsAtRemovedParent() throws {
        let root = try TwitterComposer.post(text: "1", profileId: floor, context: context)
        let mid = try TwitterComposer.post(text: "2", replyingTo: root, profileId: floor, context: context)
        let leaf = try TwitterComposer.post(text: "3", replyingTo: mid, profileId: floor, context: context)
        try TwitterTweetActions.remove(mid, context: context)
        XCTAssertTrue(TwitterThread.ancestors(of: leaf, context: context).isEmpty)
    }
}
