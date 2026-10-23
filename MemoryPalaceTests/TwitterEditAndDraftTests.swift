import XCTest
import SwiftData
@testable import 记忆花园

/// 粟粟 2026-09-27：修改已发的推 + 草稿箱。
@MainActor
final class TwitterEditAndDraftTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var mediaDir: URL!
    private let floor = "xctest-edit"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self, TwitterBookmarkFolder.self,
            TwitterFollow.self, TwitterLike.self, TwitterDraft.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        mediaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-ed-\(UUID().uuidString)")
        let me = TwitterArchiveAccount(profileId: floor, accountId: "me", screenName: "susu", displayName: "禾禾")
        context.insert(me)
        try TwitterAccounts.activate(me, context: context)
        try context.save()
    }

    override func tearDownWithError() throws {
        if let mediaDir { try? FileManager.default.removeItem(at: mediaDir) }
        context = nil; container = nil; mediaDir = nil
        try super.tearDownWithError()
    }

    // MARK: - 修改

    func testEditChangesTextHashtagsAndMarksEdited() throws {
        let t = try TwitterComposer.post(text: "今天好累", profileId: floor, context: context)
        XCTAssertNil(t.editedAt)
        try TwitterTweetActions.edit(t, text: "  今天好累 #日常  ", context: context)
        XCTAssertEqual(t.text, "今天好累 #日常")
        XCTAssertEqual(t.hashtagsJoined, "日常", "改完的标签也要能搜到")
        XCTAssertNotNil(t.editedAt)
    }

    func testEditAlsoUpdatesRepostCopies() throws {
        let t = try TwitterComposer.post(text: "旧", profileId: floor, context: context)
        let copy = try XCTUnwrap(try TwitterTweetActions.toggleRepost(t, context: context))
        try TwitterTweetActions.edit(t, text: "新", context: context)
        XCTAssertEqual(copy.text, "新", "时间线上转帖那行也是改后的")
    }

    func testOnlyMyOwnOriginalsAreEditable() throws {
        let mine = try TwitterComposer.post(text: "我的", profileId: floor, context: context)
        XCTAssertTrue(TwitterTweetActions.canEdit(mine, context: context))

        let bookmarked = TweetEntry(profileId: floor, tweetId: "9", text: "别人的", createdAt: .now)
        bookmarked.authorScreenName = "alice"
        context.insert(bookmarked)
        XCTAssertFalse(TwitterTweetActions.canEdit(bookmarked, context: context))
        XCTAssertThrowsError(try TwitterTweetActions.edit(bookmarked, text: "x", context: context))

        let copy = try XCTUnwrap(try TwitterTweetActions.toggleRepost(mine, context: context))
        XCTAssertFalse(TwitterTweetActions.canEdit(copy, context: context), "转帖行不能改，改原推")

        let ai = try TwitterAccounts.ensureAIAccount(name: "狗狗", avatarJPEG: nil, profileId: floor,
                                                     context: context, mediaDir: mediaDir)
        let aiTweet = try TwitterComposer.post(text: "汪", as: ai, profileId: floor, context: context)
        XCTAssertFalse(TwitterTweetActions.canEdit(aiTweet, context: context), "AI 的推禾禾不能替它改")
    }

    func testEditRejectsEmptyTextWithoutImages() throws {
        let t = try TwitterComposer.post(text: "有字", profileId: floor, context: context)
        XCTAssertThrowsError(try TwitterTweetActions.edit(t, text: "   ", context: context))
        XCTAssertEqual(t.text, "有字")
        let pic = try TwitterComposer.post(text: "图", images: [Data([1])], mediaDir: mediaDir, profileId: floor, context: context)
        XCTAssertNoThrow(try TwitterTweetActions.edit(pic, text: "", context: context), "有图的可以把字删光")
    }

    // MARK: - 草稿

    func testSaveListResumeAndDeleteDraft() throws {
        let parent = try TwitterComposer.post(text: "被回的", profileId: floor, context: context)
        let d = try TwitterDrafts.save(text: "还没想好", images: [Data([7, 8])], replyingTo: parent.tweetId,
                                       quoting: nil, accountId: "me", profileId: floor,
                                       mediaDir: mediaDir, context: context)
        let listed = TwitterDrafts.list(profileId: floor, accountId: "me", context: context)
        XCTAssertEqual(listed.map(\.text), ["还没想好"])
        XCTAssertEqual(listed.first?.replyToTweetId, parent.tweetId, "回复的草稿记着回谁")
        XCTAssertEqual(TwitterDrafts.images(of: d, mediaDir: mediaDir), [Data([7, 8])])
        XCTAssertTrue(TwitterDrafts.list(profileId: floor, accountId: "alt", context: context).isEmpty, "按账号分")

        try TwitterDrafts.delete(d, mediaDir: mediaDir, context: context)
        XCTAssertTrue(TwitterDrafts.list(profileId: floor, accountId: "me", context: context).isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: mediaDir.appendingPathComponent("drafts").path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "草稿的图跟着删")
    }

    func testResavingADraftUpdatesItInsteadOfDuplicating() throws {
        let d = try TwitterDrafts.save(text: "一", images: [], replyingTo: nil, quoting: nil, accountId: "me",
                                       profileId: floor, mediaDir: mediaDir, context: context)
        let d2 = try TwitterDrafts.save(text: "一二", images: [Data([1])], replyingTo: nil, quoting: nil, accountId: "me",
                                        profileId: floor, mediaDir: mediaDir, context: context, existing: d)
        XCTAssertEqual(d2.draftId, d.draftId)
        XCTAssertEqual(TwitterDrafts.list(profileId: floor, accountId: "me", context: context).map(\.text), ["一二"])
        XCTAssertEqual(TwitterDrafts.images(of: d2, mediaDir: mediaDir).count, 1)
    }

    func testEmptyDraftIsRejected() {
        XCTAssertThrowsError(try TwitterDrafts.save(text: "  ", images: [], replyingTo: nil, quoting: nil, accountId: "me",
                                                    profileId: floor, mediaDir: mediaDir, context: context))
    }
}
