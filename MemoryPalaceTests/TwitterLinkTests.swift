import XCTest
import SwiftData
@testable import 记忆花园

/// 每条推带原帖链接（粟粟 2026-09-24）。
/// X 上真有的推才给链接：存档的、从 X 拉的；App 里自己发的、示例的，X 上没有，不给假链接。
final class TwitterLinkTests: XCTestCase {

    private func tweet(_ id: String) -> TweetEntry {
        TweetEntry(profileId: "p", tweetId: id, text: "x", createdAt: Date())
    }

    func testArchiveTweetLinksToMyStatus() {
        XCTAssertEqual(tweet("1000").xURL(ownHandle: "Aeris_Neko")?.absoluteString,
                       "https://x.com/Aeris_Neko/status/1000")
    }

    func testSomeoneElsesTweetLinksToTheirStatus() {
        let t = tweet("2000")
        t.authorScreenName = "AndrewYNg"
        XCTAssertEqual(t.xURL(ownHandle: "Aeris_Neko")?.absoluteString, "https://x.com/AndrewYNg/status/2000")
    }

    func testArchiveRetweetLinksToTheOriginalAuthor() {
        let t = tweet("3000")
        t.retweetedScreenName = "alice"
        XCTAssertEqual(t.xURL(ownHandle: "me")?.absoluteString, "https://x.com/alice/status/3000")
    }

    func testPulledURLWinsWhenPresent() {
        let t = tweet("4000")
        t.sourceURL = "https://x.com/someone/status/4000"
        XCTAssertEqual(t.xURL(ownHandle: "me")?.absoluteString, "https://x.com/someone/status/4000")
    }

    func testWithoutAHandleStillUsesXsGenericStatusPath() {
        // 没导过账号也能打开：x.com/i/status/<id> 会自己跳到正确的作者
        XCTAssertEqual(tweet("5000").xURL(ownHandle: nil)?.absoluteString, "https://x.com/i/status/5000")
    }

    func testLocalAndDemoTweetsHaveNoLink() {
        XCTAssertNil(tweet(TwitterComposer.localIdPrefix + "abc").xURL(ownHandle: "me"))
        XCTAssertNil(tweet("demo-3").xURL(ownHandle: "me"))
    }

    func testRepostRowLinksToTheOriginal() {
        let t = tweet(TwitterComposer.localIdPrefix + "rt-xyz")
        t.repostOfTweetId = "6000"
        t.retweetedScreenName = "bob"
        XCTAssertEqual(t.xURL(ownHandle: "me")?.absoluteString, "https://x.com/bob/status/6000")
    }

    func testRepostOfALocalTweetHasNoLink() {
        let t = tweet(TwitterComposer.localIdPrefix + "rt-xyz")
        t.repostOfTweetId = TwitterComposer.localIdPrefix + "mine"
        XCTAssertNil(t.xURL(ownHandle: "me"))
    }

    @MainActor
    func testPullImportKeepsTheURL() async throws {
        let container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self, TwitterBookmarkFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "format": "memorypalace.twitter-pull", "version": 1, "pulledAt": "2026-09-24T08:00:00Z",
            "me": ["screenName": "me", "name": "我"], "folders": [], "likes": [], "tweets": [],
            "bookmarks": [["id": "7000", "author": "carol", "name": "Carol", "text": "hi",
                           "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                           "url": "https://x.com/carol/status/7000", "media": []]],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("twitter-pull.json"))
        _ = try await TwitterArchiveImporter.importArchive(at: dir, profileId: "p", context: context, mediaRoot: dir)
        let row = try XCTUnwrap(try context.fetch(TwitterQueries.existing(profileId: "p", tweetId: "7000")).first)
        XCTAssertEqual(row.sourceURL, "https://x.com/carol/status/7000")
    }
}
