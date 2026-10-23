import XCTest
import SwiftData
@testable import 记忆花园

/// 切换账号 + 书签（粟粟 2026-09-24）。
/// 一个楼层可以有多个推特账号，各自一条时间线、互不串；书签只收应用里点的（存档不导出书签）。
@MainActor
final class TwitterAccountsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sandbox: URL!
    private let floorA = "xctest-acc-a"
    private let floorB = "xctest-acc-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-acc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        context = nil; container = nil; sandbox = nil
        try super.tearDownWithError()
    }

    private var fixture: URL {
        get throws { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-archive", withExtension: nil)) }
    }

    /// 造一份另一个账号的小存档：accountId 不同、推文 id 不同
    private func secondArchive(id: String = "999", handle: String = "alt", tweets: Int = 2) throws -> URL {
        let data = sandbox.appendingPathComponent("alt-\(id)/data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(#"window.YTD.account.part0 = [{"account":{"accountId":"\#(id)","username":"\#(handle)","accountDisplayName":"小号"}}]"#.utf8)
            .write(to: data.appendingPathComponent("account.js"))
        let rows = (0..<tweets).map { i in
            #"{"tweet":{"id_str":"\#(id)00\#(i)","full_text":"小号第\#(i)条","created_at":"Wed Oct 10 20:19:2\#(i) +0000 2018","favorite_count":"0","retweet_count":"0"}}"#
        }.joined(separator: ",")
        try Data("window.YTD.tweets.part0 = [\(rows)]".utf8).write(to: data.appendingPathComponent("tweets.js"))
        return data.deletingLastPathComponent()
    }

    private func importArchive(_ url: URL, floor: String? = nil) async throws {
        _ = try await TwitterArchiveImporter.importArchive(at: url, profileId: floor ?? floorA,
                                                           context: context, mediaRoot: sandbox)
    }

    private func vm(_ floor: String? = nil) -> TwitterPanelViewModel {
        let m = TwitterPanelViewModel(context: context, profileId: floor ?? floorA, pageSize: 100)
        m.reload()
        return m
    }

    // MARK: - 导入与账号

    func testImportTagsTweetsWithTheArchiveAccountAndMakesItActive() async throws {
        try await importArchive(try fixture)
        let acc = try XCTUnwrap(TwitterAccounts.active(profileId: floorA, context: context))
        XCTAssertEqual(acc.accountId, "1234567890")
        XCTAssertEqual(Set(vm().tweets.map(\.accountId)), ["1234567890"])
    }

    func testImportingAnotherAccountAddsASecondAccountAndSwitchesToIt() async throws {
        try await importArchive(try fixture)
        try await importArchive(try secondArchive())
        let all = TwitterAccounts.all(profileId: floorA, context: context)
        XCTAssertEqual(Set(all.map(\.accountId)), ["1234567890", "999"], "另一个账号的存档是新账号，不能盖掉第一个")
        XCTAssertEqual(TwitterAccounts.active(profileId: floorA, context: context)?.accountId, "999")
        XCTAssertEqual(vm().tweets.map(\.text).sorted(), ["小号第0条", "小号第1条"], "时间线只看当前账号")
    }

    func testSwitchingAccountSwitchesTimelineAndHeader() async throws {
        try await importArchive(try fixture)
        try await importArchive(try secondArchive())
        let main = try XCTUnwrap(TwitterAccounts.all(profileId: floorA, context: context).first { $0.accountId == "1234567890" })
        try TwitterAccounts.activate(main, context: context)
        let m = vm()
        XCTAssertEqual(m.account?.screenName, "susu_test")
        XCTAssertEqual(m.totalCount, 3, "总数也按账号算")
        XCTAssertFalse(m.tweets.contains { $0.text.hasPrefix("小号") })
    }

    func testReimportingTheSameAccountDoesNotAddAnother() async throws {
        try await importArchive(try fixture)
        try await importArchive(try fixture)
        XCTAssertEqual(TwitterAccounts.all(profileId: floorA, context: context).count, 1)
    }

    func testImportTakesOverTheDemoAccount() async throws {
        // 只装过示例就导真存档：示例账号被真账号接管，不多出一个「示例账号」
        try TwitterDemoSeed.install(profileId: floorA, context: context, mediaRoot: sandbox)
        try await importArchive(try fixture)
        let all = TwitterAccounts.all(profileId: floorA, context: context)
        XCTAssertEqual(all.map(\.accountId), ["1234567890"])
        XCTAssertTrue(vm().tweets.contains { $0.tweetId.hasPrefix("demo-") }, "示例推文跟着接管过来，还能「清掉示例」")
    }

    func testLegacyTweetsWithoutAccountAreAdoptedByTheActiveAccount() throws {
        // 粟粟手机上已经导过一次：那批推文没有 accountId
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "1234567890",
                                             screenName: "susu", displayName: "禾禾"))
        context.insert(TweetEntry(profileId: floorA, tweetId: "old", text: "老数据", createdAt: Date()))
        try context.save()
        XCTAssertEqual(vm().tweets.map(\.tweetId), ["old"], "面板启动时把老数据归给当前账号")
    }

    func testFloorsAreIndependent() async throws {
        try await importArchive(try fixture, floor: floorA)
        try await importArchive(try secondArchive(), floor: floorB)
        XCTAssertEqual(TwitterAccounts.all(profileId: floorA, context: context).map(\.accountId), ["1234567890"])
        XCTAssertEqual(TwitterAccounts.all(profileId: floorB, context: context).map(\.accountId), ["999"])
    }

    // MARK: - 新建空白账号 / 作用于当前账号

    func testCreateLocalAccountStartsEmptyAndPostsGoThere() async throws {
        try await importArchive(try fixture)
        let fresh = try TwitterAccounts.createLocal(displayName: "新号", screenName: "fresh",
                                                     profileId: floorA, context: context)
        XCTAssertEqual(TwitterAccounts.active(profileId: floorA, context: context)?.accountId, fresh.accountId)
        XCTAssertTrue(vm().tweets.isEmpty, "新号是空的")
        try TwitterComposer.post(text: "新号第一条", profileId: floorA, context: context)
        XCTAssertEqual(vm().tweets.map(\.text), ["新号第一条"])
    }

    func testCreateLocalRejectsEmptyName() {
        XCTAssertThrowsError(try TwitterAccounts.createLocal(displayName: "  ", screenName: "x",
                                                              profileId: floorA, context: context))
    }

    func testProfileEditorEditsTheActiveAccountOnly() async throws {
        try await importArchive(try fixture)
        try await importArchive(try secondArchive())
        try TwitterProfileEditor.save(
            TwitterProfileDraft(displayName: "小号改名", screenName: "alt", bio: "", location: "", website: ""),
            profileId: floorA, context: context, mediaDir: sandbox)
        let byId = Dictionary(uniqueKeysWithValues: TwitterAccounts.all(profileId: floorA, context: context)
            .map { ($0.accountId, $0.displayName) })
        XCTAssertEqual(byId["999"], "小号改名")
        XCTAssertEqual(byId["1234567890"], "禾禾", "别的账号不能被改到")
    }

    func testRepostLandsOnTheActiveAccount() async throws {
        try await importArchive(try fixture)
        try await importArchive(try secondArchive())
        let alt = try XCTUnwrap(vm().tweets.first)
        let copy = try XCTUnwrap(try TwitterTweetActions.toggleRepost(alt, context: context))
        XCTAssertEqual(copy.accountId, "999")
    }

    // MARK: - 书签

    func testBookmarkToggles() throws {
        let t = TweetEntry(profileId: floorA, tweetId: "t", text: "x", createdAt: Date())
        context.insert(t)
        try TwitterTweetActions.toggleBookmark(t, context: context)
        XCTAssertNotNil(t.bookmarkedAt)
        try TwitterTweetActions.toggleBookmark(t, context: context)
        XCTAssertNil(t.bookmarkedAt)
    }

    func testBookmarksListIsNewestBookmarkFirstAndPerAccount() async throws {
        try await importArchive(try fixture)
        let main = vm().tweets
        let oldest = try XCTUnwrap(main.last), newest = try XCTUnwrap(main.first)
        try TwitterTweetActions.toggleBookmark(newest, context: context)
        oldest.bookmarkedAt = Date().addingTimeInterval(10)   // 后收藏的排前面，不管推文本身多老
        try context.save()

        let m = vm()
        m.apply(.bookmarks)
        XCTAssertEqual(m.tweets.map(\.tweetId), [oldest.tweetId, newest.tweetId])

        try await importArchive(try secondArchive())
        let alt = vm()
        alt.apply(.bookmarks)
        XCTAssertTrue(alt.tweets.isEmpty, "书签也按账号分")
    }

    func testBookmarksPageWithCursor() throws {
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "a", screenName: "a", displayName: "A"))
        for i in 0..<3 {
            let t = TweetEntry(profileId: floorA, tweetId: "b\(i)", text: "x", createdAt: Date())
            t.accountId = "a"
            t.bookmarkedAt = Date(timeIntervalSince1970: TimeInterval(100 + i))
            context.insert(t)
        }
        try context.save()
        let m = TwitterPanelViewModel(context: context, profileId: floorA, pageSize: 2)
        m.reload()
        m.apply(.bookmarks)
        XCTAssertEqual(m.tweets.map(\.tweetId), ["b2", "b1"])
        XCTAssertTrue(m.hasMore)
        m.loadMore()
        XCTAssertEqual(m.tweets.map(\.tweetId), ["b2", "b1", "b0"])
    }
}
