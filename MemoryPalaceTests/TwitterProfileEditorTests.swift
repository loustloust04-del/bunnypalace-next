import XCTest
import SwiftData
@testable import 记忆花园

/// 编辑个人资料：名字 / @handle / 简介 / 地点 / 网站 / 头像 / 横幅。
/// 推特的「编辑个人资料」就这几样，这里照着来。
final class TwitterProfileEditorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var mediaDir: URL!
    private let floorA = "xctest-edit-a"
    private let floorB = "xctest-edit-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        mediaDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tw-edit-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let mediaDir { try? FileManager.default.removeItem(at: mediaDir) }
        context = nil; container = nil; mediaDir = nil
        try super.tearDownWithError()
    }

    private func accounts(_ floor: String) throws -> [TwitterArchiveAccount] {
        try context.fetch(TwitterQueries.accounts(profileId: floor))
    }

    private func draft(name: String = "禾禾", handle: String = "susu", bio: String = "",
                       location: String = "", website: String = "") -> TwitterProfileDraft {
        TwitterProfileDraft(displayName: name, screenName: handle, bio: bio,
                            location: location, website: website)
    }

    func testCreatesAccountWhenFloorHasNone() throws {
        // 没导过存档、只自己发推的人，也要能设头像和名字
        try TwitterProfileEditor.save(draft(bio: "你好"), profileId: floorA,
                                      context: context, mediaDir: mediaDir)
        let acc = try XCTUnwrap(try accounts(floorA).first)
        XCTAssertEqual(acc.displayName, "禾禾")
        XCTAssertEqual(acc.screenName, "susu")
        XCTAssertEqual(acc.bio, "你好")
        XCTAssertNotNil(acc.editedAt, "要标记为手动改过，重新导入才知道别覆盖")
    }

    func testUpdatesExistingAccountInsteadOfAddingOne() throws {
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "42",
                                             screenName: "old", displayName: "旧名"))
        try context.save()
        try TwitterProfileEditor.save(draft(name: "新名", handle: "old", bio: "新简介"),
                                      profileId: floorA, context: context, mediaDir: mediaDir)
        let rows = try accounts(floorA)
        XCTAssertEqual(rows.count, 1, "一楼层一条账号，编辑不能多出一条")
        XCTAssertEqual(rows[0].displayName, "新名")
        XCTAssertEqual(rows[0].bio, "新简介")
        XCTAssertEqual(rows[0].accountId, "42", "存档里的账号 id 不能被编辑冲掉")
    }

    func testTrimsWhitespaceAndLeadingAt() throws {
        try TwitterProfileEditor.save(draft(name: "  禾禾 \n", handle: " @susu ", bio: " 嗨 "),
                                      profileId: floorA, context: context, mediaDir: mediaDir)
        let acc = try XCTUnwrap(try accounts(floorA).first)
        XCTAssertEqual(acc.displayName, "禾禾")
        XCTAssertEqual(acc.screenName, "susu")
        XCTAssertEqual(acc.bio, "嗨")
    }

    func testRejectsEmptyName() {
        // 推特不允许名字为空
        XCTAssertThrowsError(try TwitterProfileEditor.save(draft(name: "   "), profileId: floorA,
                                                           context: context, mediaDir: mediaDir)) {
            XCTAssertEqual($0 as? TwitterProfileEditorError, .emptyName)
        }
        XCTAssertTrue((try? accounts(floorA))?.isEmpty ?? false, "报错时不能留半截数据")
    }

    func testClampsFieldsToTwitterLimits() throws {
        let long = String(repeating: "字", count: 400)
        try TwitterProfileEditor.save(draft(name: long, bio: long, location: long, website: long),
                                      profileId: floorA, context: context, mediaDir: mediaDir)
        let acc = try XCTUnwrap(try accounts(floorA).first)
        XCTAssertEqual(acc.displayName.count, TwitterProfileEditor.Limit.name)
        XCTAssertEqual(acc.bio.count, TwitterProfileEditor.Limit.bio)
        XCTAssertEqual(acc.location.count, TwitterProfileEditor.Limit.location)
        XCTAssertEqual(acc.website.count, TwitterProfileEditor.Limit.website)
    }

    func testWritesNewAvatarAndBannerUnderFreshNames() throws {
        try TwitterProfileEditor.save(draft(), avatar: Data([1, 2, 3]), banner: Data([4, 5]),
                                      profileId: floorA, context: context, mediaDir: mediaDir)
        let acc = try XCTUnwrap(try accounts(floorA).first)
        let avatar = try XCTUnwrap(acc.avatarFileName)
        let banner = try XCTUnwrap(acc.bannerFileName)
        XCTAssertEqual(try Data(contentsOf: mediaDir.appendingPathComponent(avatar)), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: mediaDir.appendingPathComponent(banner)), Data([4, 5]))

        // 再换一次：文件名必须变，不然按 URL 缓存的图片视图不会重读，看起来像没换成
        try TwitterProfileEditor.save(draft(), avatar: Data([9]), profileId: floorA,
                                      context: context, mediaDir: mediaDir)
        XCTAssertNotEqual(acc.avatarFileName, avatar)
        XCTAssertEqual(acc.bannerFileName, banner, "没传横幅就不动横幅")
    }

    func testCanRemoveBanner() throws {
        try TwitterProfileEditor.save(draft(), banner: Data([4]), profileId: floorA,
                                      context: context, mediaDir: mediaDir)
        try TwitterProfileEditor.save(draft(), removeBanner: true, profileId: floorA,
                                      context: context, mediaDir: mediaDir)
        XCTAssertNil(try XCTUnwrap(try accounts(floorA).first).bannerFileName)
    }

    func testFloorsAreIndependent() throws {
        try TwitterProfileEditor.save(draft(name: "A"), profileId: floorA, context: context, mediaDir: mediaDir)
        try TwitterProfileEditor.save(draft(name: "B"), profileId: floorB, context: context, mediaDir: mediaDir)
        XCTAssertEqual(try accounts(floorA).map(\.displayName), ["A"])
        XCTAssertEqual(try accounts(floorB).map(\.displayName), ["B"])
    }

    func testLoadReturnsCurrentValuesOrBlank() throws {
        XCTAssertEqual(TwitterProfileEditor.load(profileId: floorA, context: context),
                       TwitterProfileDraft(displayName: "", screenName: "", bio: "", location: "", website: ""))
        try TwitterProfileEditor.save(draft(bio: "嗨", location: "上海"), profileId: floorA,
                                      context: context, mediaDir: mediaDir)
        XCTAssertEqual(TwitterProfileEditor.load(profileId: floorA, context: context),
                       draft(bio: "嗨", location: "上海"))
    }
}
