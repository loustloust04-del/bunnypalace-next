import XCTest
import SwiftData
@testable import 记忆花园

/// 时间线串起来（粟粟 2026-09-24，参考 Mastodon）：一个楼层就是一个站（先纯本地）。
/// 「本站」看这层所有账号自己发的推，「关注」看当前账号 + 它关注的号。
/// 楼层 AI 自动有一个号（名字头像跟 AI 资料同步），还能自己再开号；AI 的号不出现在你的账号切换里。
@MainActor
final class TwitterTownTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let floorA = "xctest-town-a"
    private let floorB = "xctest-town-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self, TwitterBookmarkFolder.self,
            TwitterFollow.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil; container = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func account(_ id: String, _ handle: String, floor: String? = nil, ai: Bool = false) -> TwitterArchiveAccount {
        let a = TwitterArchiveAccount(profileId: floor ?? floorA, accountId: id, screenName: handle, displayName: handle)
        if ai { a.ownerKind = TwitterAccounts.ownerAI }
        context.insert(a)
        return a
    }

    private func post(_ id: String, by accountId: String, at: TimeInterval, floor: String? = nil,
                      author: String? = nil) {
        let t = TweetEntry(profileId: floor ?? floorA, tweetId: id, text: id, createdAt: Date(timeIntervalSince1970: at))
        t.accountId = accountId
        t.authorScreenName = author
        context.insert(t)
    }

    /// 两个我的号 + 一个 AI 号，各发一条；另有一条是从 X 拉来的书签（别人的推）
    private func town() throws -> (me: TwitterArchiveAccount, alt: TwitterArchiveAccount, ai: TwitterArchiveAccount) {
        let me = account("me", "susu"), alt = account("alt", "susu_alt"), ai = account("ai", "lily", ai: true)
        try TwitterAccounts.activate(me, context: context)
        post("m1", by: "me", at: 10)
        post("a1", by: "alt", at: 20)
        post("ai1", by: "ai", at: 30)
        post("x1", by: "me", at: 40, author: "AndrewYNg")
        account("other-floor", "far", floor: floorB)
        post("f1", by: "other-floor", at: 50, floor: floorB)
        try context.save()
        return (me, alt, ai)
    }

    private func vm() -> TwitterPanelViewModel {
        let m = TwitterPanelViewModel(context: context, profileId: floorA, pageSize: 100)
        m.reload()
        return m
    }

    // MARK: - 本站 / 关注

    func testLocalTimelineShowsEveryAccountOnThisFloor() throws {
        try town()
        let m = vm()
        m.apply(.local)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["ai1", "a1", "m1"],
                       "本站：这层所有账号自己发的，新的在前；别人的推（书签）和别的楼层都不算")
    }

    func testFollowingTimelineIsMeAndWhoIFollow() throws {
        let (me, _, ai) = try town()
        let m = vm()
        m.apply(.following)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["m1"], "还没关注谁：只有自己的")
        try TwitterFollows.follow(ai, by: me, context: context)
        m.apply(.following)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["ai1", "m1"])
    }

    func testFollowingIsPerAccount() throws {
        let (me, alt, ai) = try town()
        try TwitterFollows.follow(ai, by: alt, context: context)
        let m = vm()
        m.apply(.following)
        XCTAssertFalse(m.tweets.contains { $0.tweetId == "ai1" }, "alt 关注了 AI，不等于 me 也关注了")
        try TwitterAccounts.activate(alt, context: context)
        m.apply(.following)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["ai1", "a1"])
        _ = me
    }

    func testFollowUnfollowAndSelf() throws {
        let (me, alt, _) = try town()
        try TwitterFollows.follow(alt, by: me, context: context)
        try TwitterFollows.follow(alt, by: me, context: context)
        XCTAssertEqual(TwitterFollows.followees(of: me, context: context), ["alt"], "重复关注不重复记")
        XCTAssertTrue(TwitterFollows.isFollowing(alt, by: me, context: context))
        try TwitterFollows.unfollow(alt, by: me, context: context)
        XCTAssertFalse(TwitterFollows.isFollowing(alt, by: me, context: context))
        try TwitterFollows.follow(me, by: me, context: context)
        XCTAssertTrue(TwitterFollows.followees(of: me, context: context).isEmpty, "不能关注自己")
    }

    func testFollowersAndFollowingListsAndCounts() throws {
        // 粟粟 2026-09-25：主页要有关注数 / 粉丝数，点进去是列表
        let me = account("me", "susu"), a = account("a", "alice"), b = account("b", "bob")
        let other = account("x", "x", floor: floorB)
        try TwitterFollows.follow(a, by: me, context: context)
        try TwitterFollows.follow(b, by: me, context: context)
        try TwitterFollows.follow(me, by: a, context: context)
        try TwitterFollows.follow(me, by: other, context: context)   // 别的楼层，不串
        XCTAssertEqual(TwitterFollows.followees(of: me, context: context), ["a", "b"])
        XCTAssertEqual(TwitterFollows.followers(of: me, context: context), ["a"])
        XCTAssertEqual(TwitterFollows.followers(of: b, context: context), ["me"])
        XCTAssertTrue(TwitterFollows.followers(of: other, context: context).isEmpty)
    }

    func testEachRowKnowsItsOwnAccount() throws {
        try town()
        let m = vm()
        m.apply(.local)
        let byTweet = Dictionary(uniqueKeysWithValues: m.tweets.map { ($0.tweetId, m.author(of: $0)?.screenName) })
        XCTAssertEqual(byTweet["ai1"], "lily", "每行显示发推的那个号，不是当前账号")
        XCTAssertEqual(byTweet["a1"], "susu_alt")
    }

    // MARK: - 看别的号的主页

    func testViewingAnotherAccountsProfile() throws {
        let (me, _, ai) = try town()
        let m = vm()
        m.viewAccount(ai.accountId)
        m.apply(.posts)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["ai1"])
        XCTAssertEqual(m.viewedAccount?.screenName, "lily")
        XCTAssertFalse(m.isViewingOwnAccount)
        XCTAssertEqual(m.totalCount, 1, "主页头部的推文数也是那个号的")
        m.viewAccount(nil)
        m.apply(.posts)
        XCTAssertEqual(m.viewedAccount?.accountId, me.accountId, "不指定就是自己")
        XCTAssertTrue(m.isViewingOwnAccount)
    }

    // MARK: - AI 的号

    func testAIAccountsAreNotInMySwitcherAndNeverBecomeActive() throws {
        let ai = account("ai", "lily", ai: true)
        ai.importedAt = Date(timeIntervalSince1970: 0)   // 比我的号还早
        account("me", "susu").importedAt = Date(timeIntervalSince1970: 100)
        try context.save()
        XCTAssertEqual(TwitterAccounts.userAccounts(profileId: floorA, context: context).map(\.accountId), ["me"])
        XCTAssertEqual(TwitterAccounts.active(profileId: floorA, context: context)?.accountId, "me",
                       "当前账号只能是我的号")
    }

    func testEnsureAIAccountCreatesOnceSyncsNameAndIsFollowed() throws {
        let me = account("me", "susu")
        try context.save()
        let a = try TwitterAccounts.ensureAIAccount(name: "莉莉", avatarJPEG: nil, profileId: floorA, context: context,
                                                    mediaDir: FileManager.default.temporaryDirectory)
        XCTAssertEqual(a.ownerKind, TwitterAccounts.ownerAI)
        XCTAssertEqual(a.displayName, "莉莉")
        XCTAssertFalse(a.screenName.isEmpty)
        XCTAssertTrue(TwitterFollows.isFollowing(a, by: me, context: context), "我的号默认关注楼层 AI")
        let again = try TwitterAccounts.ensureAIAccount(name: "莉莉改名", avatarJPEG: nil, profileId: floorA, context: context,
                                                        mediaDir: FileManager.default.temporaryDirectory)
        XCTAssertEqual(again.accountId, a.accountId, "只建一次")
        XCTAssertEqual(again.displayName, "莉莉改名", "名字跟 AI 资料同步")
        XCTAssertEqual(TwitterAccounts.aiAccounts(profileId: floorA, context: context).count, 1)
    }

    func testAICanOpenMoreAccounts() throws {
        _ = try TwitterAccounts.ensureAIAccount(name: "莉莉", avatarJPEG: nil, profileId: floorA, context: context,
                                                mediaDir: FileManager.default.temporaryDirectory)
        let extra = try TwitterAccounts.createAIAccount(displayName: "莉莉的小号", screenName: "lily_alt",
                                                         profileId: floorA, context: context)
        XCTAssertEqual(extra.ownerKind, TwitterAccounts.ownerAI)
        XCTAssertEqual(TwitterAccounts.aiAccounts(profileId: floorA, context: context).count, 2)
        XCTAssertTrue(TwitterAccounts.userAccounts(profileId: floorA, context: context).isEmpty)
    }

    func testPostingAsASpecificAccount() throws {
        let (_, _, ai) = try town()
        let t = try TwitterComposer.post(text: "AI 说话了", as: ai, profileId: floorA, context: context)
        XCTAssertEqual(t.accountId, "ai")
        let m = vm()
        m.apply(.local)
        XCTAssertEqual(m.tweets.first?.tweetId, t.tweetId)
    }

    func testEmptyFloorStillShowsTheImportGuideOnTheLocalTab() {
        // 首页默认「本站」：空楼层也要回到导入引导页，不能进一个空时间线
        let m = TwitterPanelViewModel(context: context, profileId: floorA)
        m.apply(.local)
        XCTAssertTrue(m.isEmpty)
    }
}
