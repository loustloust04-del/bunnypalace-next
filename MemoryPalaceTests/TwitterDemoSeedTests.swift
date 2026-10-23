import XCTest
import SwiftData
@testable import 记忆花园

/// 示例数据：没有真存档时也能看见界面长什么样。
/// 最要命的一条是「清示例不能误删真数据」，重点测它。
final class TwitterDemoSeedTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sandbox: URL!
    private let floorA = "xctest-demo-a"
    private let floorB = "xctest-demo-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tw-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        context = nil; container = nil; sandbox = nil
        try super.tearDownWithError()
    }

    private func seed(_ floor: String) throws {
        try TwitterDemoSeed.install(profileId: floor, context: context, mediaRoot: sandbox)
    }

    private func count(_ floor: String) throws -> Int {
        try context.fetchCount(FetchDescriptor<TweetEntry>(predicate: #Predicate { $0.profileId == floor }))
    }

    func testInstallsSampleTweets() throws {
        try seed(floorA)
        XCTAssertGreaterThanOrEqual(try count(floorA), 5, "示例要够铺满一屏，不然看不出时间线的样子")
    }

    func testSampleCoversTheInterestingShapes() throws {
        try seed(floorA)
        let rows = try context.fetch(FetchDescriptor<TweetEntry>(
            predicate: #Predicate { $0.profileId == floorA }))
        XCTAssertTrue(rows.contains { $0.mediaCount > 0 }, "要有带图的，否则看不到媒体布局")
        XCTAssertTrue(rows.contains { $0.inReplyToScreenName != nil }, "要有回复，否则看不到回复样式")
        XCTAssertTrue(rows.contains { !$0.hashtagsJoined.isEmpty }, "要有话题标签")
        XCTAssertTrue(rows.contains { $0.favoriteCount > 0 }, "要有赞数，否则看不到那行小字")
    }

    func testWritesPlaceholderImageSoMediaActuallyRenders() throws {
        try seed(floorA)
        let media = try XCTUnwrap(try context.fetch(FetchDescriptor<TweetMedia>()).first)
        let onDisk = sandbox.appendingPathComponent(floorA).appendingPathComponent(media.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path),
                      "示例图要真落盘，不然媒体位置是空白块")
    }

    func testInstallsAnAccountWhenThereIsNone() throws {
        try seed(floorA)
        let acc = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first)
        XCTAssertFalse(acc.displayName.isEmpty)
    }

    func testDoesNotOverwriteARealAccount() throws {
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "real-1",
                                             screenName: "susu_real", displayName: "真的禾禾"))
        try seed(floorA)
        let accounts = try context.fetch(FetchDescriptor<TwitterArchiveAccount>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.screenName, "susu_real", "已经有真账号就别动它")
    }

    func testIsIdempotent() throws {
        try seed(floorA)
        let first = try count(floorA)
        try seed(floorA)
        XCTAssertEqual(try count(floorA), first, "重复点「看看样子」不能越点越多")
    }

    func testRemoveTakesOnlyTheSamples() throws {
        // 真数据：一条导入来的推
        context.insert(TweetEntry(profileId: floorA, tweetId: "1000000000000000001",
                                  text: "这是真的", createdAt: Date(timeIntervalSince1970: 1)))
        try seed(floorA)
        XCTAssertGreaterThan(try count(floorA), 1)

        try TwitterDemoSeed.remove(profileId: floorA, context: context)
        let left = try context.fetch(FetchDescriptor<TweetEntry>(
            predicate: #Predicate { $0.profileId == floorA }))
        XCTAssertEqual(left.map(\.tweetId), ["1000000000000000001"], "清示例绝不能碰真数据")
        XCTAssertTrue(try context.fetch(FetchDescriptor<TweetMedia>()).isEmpty, "示例的媒体也要一起清")
    }

    func testRemoveKeepsARealAccount() throws {
        context.insert(TwitterArchiveAccount(profileId: floorA, accountId: "real-1",
                                             screenName: "susu_real", displayName: "真的禾禾"))
        try seed(floorA)
        try TwitterDemoSeed.remove(profileId: floorA, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).count, 1,
                       "真账号要留着")
    }

    func testRemoveDropsTheDemoAccountItCreated() throws {
        try seed(floorA)
        try TwitterDemoSeed.remove(profileId: floorA, context: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).isEmpty,
                      "示例自己造的账号要跟着清掉")
    }

    func testRemoveKeepsTheDemoAccountOnceItWasHandEdited() throws {
        // 装着示例时改了资料 → 那已经是粟粟自己的账号了，清示例不能把她改的一起删掉
        try seed(floorA)
        try TwitterProfileEditor.save(
            TwitterProfileDraft(displayName: "我自己", screenName: "me", bio: "", location: "", website: ""),
            profileId: floorA, context: context, mediaDir: sandbox.appendingPathComponent(floorA))
        try TwitterDemoSeed.remove(profileId: floorA, context: context)
        let rows = try context.fetch(TwitterQueries.accounts(profileId: floorA))
        XCTAssertEqual(rows.map(\.displayName), ["我自己"])
        XCTAssertNotEqual(rows.first?.accountId, TwitterDemoSeed.demoAccountId,
                          "要脱掉示例身份，不然下次清示例又会被当成示例")
    }

    @MainActor
    func testRemovingSamplesKeepsWhatIPostedUnderTheDemoAccount() throws {
        // 装着示例时自己发的推挂在示例账号上；清示例不能让它们跟着「没主」而看不见
        // 改过资料的示例账号会留下、换成新 id——推文要跟着换，不然挂在旧 id 上谁也看不见
        try seed(floorA)
        try TwitterComposer.post(text: "我自己写的", profileId: floorA, context: context)
        try TwitterProfileEditor.save(
            TwitterProfileDraft(displayName: "我", screenName: "me", bio: "", location: "", website: ""),
            profileId: floorA, context: context, mediaDir: sandbox)
        try TwitterDemoSeed.remove(profileId: floorA, context: context)
        let vm = TwitterPanelViewModel(context: context, profileId: floorA)
        vm.reload()
        XCTAssertEqual(vm.tweets.map(\.text), ["我自己写的"])
    }

    func testIsIsolatedByFloor() throws {
        try seed(floorA)
        XCTAssertEqual(try count(floorB), 0)
        try TwitterDemoSeed.remove(profileId: floorB, context: context)
        XCTAssertGreaterThan(try count(floorA), 0, "清 B 楼层的示例不能把 A 的带走")
    }

    func testDetectsWhetherSamplesArePresent() throws {
        XCTAssertFalse(try TwitterDemoSeed.isInstalled(profileId: floorA, context: context))
        try seed(floorA)
        XCTAssertTrue(try TwitterDemoSeed.isInstalled(profileId: floorA, context: context))
    }
}
